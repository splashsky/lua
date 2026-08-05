#+build freestanding

package stdlib

// auxlib.odin -- our analogue of reference Lua's `lauxlib.h` / `lauxlib.c`.
//
// The "auxiliary library": the convenience layer that sits on top of the raw
// embedding API. Every other standard library, and most host code, leans on it.
// It is written *purely* against the public `lua` API -- it is the first real
// customer of the kernel/stdlib boundary, and it never reaches into kernel
// internals. That discipline is what keeps the boundary honest.
//
// Faithful port of lauxlib.c, section by section: error/argument reporting, the
// argument checkers (`luaL_check*` / `luaL_opt*`), userdata-metatable helpers, the
// registry-backed reference system, the growable string Buffer, the chunk loaders
// that back `load`/`loadfile`, module registration, and the default state/alloc/
// warning plumbing used by `luaL_newstate`.

import "base:runtime"
import kernel "lang:kernel"

// --------------------------------------------------------------------------------
// Constants and small shared types
// --------------------------------------------------------------------------------

// The size of the Buffer's inline scratch area. Reference computes this as
// 16*sizeof(void*)*sizeof(lua_Number) == 1024 on a 64-bit build; we hard-code the
// same value so short results never touch the heap.
AUX_BUFFERSIZE :: 1024

// Reference values for the reference system's two special references.
NOREF :: -2
REFNIL :: -1

// Well-known registry sub-table names (reference `LUA_LOADED_TABLE` /
// `LUA_PRELOAD_TABLE`). `require` and module registration key off these.
LOADED_TABLE :: "_LOADED"
PRELOAD_TABLE :: "_PRELOAD"

// A single name→function registration record -- reference `luaL_Reg`. Unlike the
// C array (terminated by a `{NULL,NULL}` sentinel) we pass Odin slices, so the
// length is explicit and no sentinel is needed. A `nil` `func` still carries its
// reference meaning: a placeholder that installs `false` (used by libraries that
// reserve a field name for later).
Reg :: struct {
	name: string,
	func: kernel.C_Function,
}

// --------------------------------------------------------------------------------
// Small internal string helpers
// --------------------------------------------------------------------------------

// Render a NUL-terminated `short_src` byte array (as filled by `lua_getinfo`) into
// an Odin string for use in formatted messages.
short_src_string :: proc(src: ^[kernel.IDSIZE]u8) -> string {
	n := 0
	for n < len(src) && src[n] != 0 {
		n += 1
	}
	return string(src[:n])
}

// --------------------------------------------------------------------------------
// Error-report functions
// --------------------------------------------------------------------------------

// Push a `source:line:` location prefix for the function `level` frames up --
// reference `luaL_where`. When no line information is available it pushes the empty
// string, so callers can unconditionally `concat` it in front of a message.
aux_where :: proc(L: ^kernel.State, level: int) {
	ar: kernel.Debug_Info
	if kernel.api_getstack(L, level, &ar) {
		kernel.api_getinfo(L, "Sl", &ar)
		if ar.currentline > 0 {
			kernel.api_pushfstring(L, "%s:%d: ", short_src_string(&ar.short_src), int(ar.currentline))
			return
		}
	}
	kernel.api_pushfstring(L, "")
}

// Raise a formatted error, prefixed with the caller's `source:line:` -- reference
// `luaL_error`. Diverges (never returns); it longjmps through the active protected
// boundary just like `lua_error`.
aux_error :: proc(L: ^kernel.State, fmt: string, args: ..any) -> ! {
	aux_where(L, 1)
	kernel.api_pushfstring(L, fmt, ..args)
	kernel.api_concat(L, 2)
	kernel.api_error(L)
}

// Raise a "bad argument" error for argument #`arg` -- reference `luaL_argerror`.
// We reproduce reference Lua's message shape as faithfully as our debug
// information allows. (Reference 5.5 additionally discounts vararg "extra
// arguments"; our `Lua_Debug` does not yet carry that count, so we omit that
// refinement -- the resulting message is still honest, just without that nuance.)
aux_argerror :: proc(L: ^kernel.State, arg: int, extramsg: string) -> ! {
	ar: kernel.Debug_Info
	if !kernel.api_getstack(L, 0, &ar) {
		// No stack frame (called outside a function): the simplest form.
		aux_error(L, "bad argument #%d (%s)", arg, extramsg)
	}
	kernel.api_getinfo(L, "n", &ar)
	a := arg
	if ar.namewhat == "method" {
		a -= 1 // do not count the implicit self argument
		if a == 0 {
			aux_error(L, "calling '%s' on bad self (%s)", ar.name, extramsg)
		}
	}
	name := ar.name
	if name == "" {
		// Reference falls back to a qualified module name (e.g. "table.sort") by
		// searching package.loaded for the running function before giving up on
		// "?". pushglobalfuncname leaves the name on the stack on success.
		if pushglobalfuncname(L, &ar) {
			name, _ = kernel.api_tostring(L, -1)
		} else {
			name = "?"
		}
	}
	aux_error(L, "bad argument #%d to '%s' (%s)", a, name, extramsg)
}

// Raise a "wrong type" error for argument #`arg`, naming the type we wanted --
// reference `luaL_typeerror`. Honors a userdata's `__name` when present so the
// actual-type portion of the message is as informative as reference Lua's.
aux_typeerror :: proc(L: ^kernel.State, arg: int, tname: string) -> ! {
	typearg: string
	if aux_getmetafield(L, arg, "__name") == kernel.TSTRING {
		typearg, _ = kernel.api_tostring(L, -1)
	} else if kernel.api_type(L, arg) == kernel.TLIGHTUSERDATA {
		typearg = "light userdata"
	} else {
		typearg = aux_typename(L, arg)
	}
	msg := kernel.api_pushfstring(L, "%s expected, got %s", tname, typearg)
	aux_argerror(L, arg, msg)
}

// The internal "wrong tag" helper used by the checkers -- reference `tag_error`.
tag_error :: proc(L: ^kernel.State, arg: int, tag: int) -> ! {
	aux_typeerror(L, arg, kernel.api_typename(L, tag))
}

// Assert a boolean argument condition, raising `luaL_argerror` if it fails --
// reference `luaL_argcheck`.
aux_argcheck :: proc(L: ^kernel.State, cond: bool, arg: int, extramsg: string) {
	if !cond {
		aux_argerror(L, arg, extramsg)
	}
}

// Assert a condition, raising a `luaL_typeerror` naming `tname` on failure --
// reference `luaL_argexpected`.
aux_argexpected :: proc(L: ^kernel.State, cond: bool, arg: int, tname: string) {
	if !cond {
		aux_typeerror(L, arg, tname)
	}
}

// The type name of the value at `idx` -- reference `luaL_typename` macro.
aux_typename :: proc(L: ^kernel.State, idx: int) -> string {
	return kernel.api_typename(L, kernel.api_type(L, idx))
}

// --------------------------------------------------------------------------------
// Argument checkers
// --------------------------------------------------------------------------------

// Ensure the stack can grow by `space` slots, raising a descriptive stack-overflow
// error otherwise -- reference `luaL_checkstack`.
aux_checkstack :: proc(L: ^kernel.State, space: int, msg: string) {
	if !kernel.api_checkstack(L, space) {
		if msg != "" {
			aux_error(L, "stack overflow (%s)", msg)
		} else {
			aux_error(L, "stack overflow")
		}
	}
}

// Demand that argument #`arg` has exactly type `t` -- reference `luaL_checktype`.
aux_checktype :: proc(L: ^kernel.State, arg: int, t: int) {
	if kernel.api_type(L, arg) != t {
		tag_error(L, arg, t)
	}
}

// Demand that argument #`arg` exists (is not "none") -- reference `luaL_checkany`.
aux_checkany :: proc(L: ^kernel.State, arg: int) {
	if kernel.api_type(L, arg) == kernel.TNONE {
		aux_argerror(L, arg, "value expected")
	}
}

// Check/convert a string argument, returning its bytes (length carried by the Odin
// string) -- reference `luaL_checklstring`. A number is silently accepted and
// stringified, matching reference Lua (the conversion happens in `lua_tolstring`).
aux_checklstring :: proc(L: ^kernel.State, arg: int) -> string {
	s, ok := kernel.api_tolstring(L, arg)
	if !ok {
		tag_error(L, arg, kernel.TSTRING)
	}
	return s
}

// A string argument with a default when absent/nil -- reference `luaL_optlstring`.
aux_optlstring :: proc(L: ^kernel.State, arg: int, def: string) -> string {
	if kernel.api_isnoneornil(L, arg) {
		return def
	}
	return aux_checklstring(L, arg)
}

// Convenience aliases matching reference's `luaL_checkstring` / `luaL_optstring`.
aux_checkstring :: proc(L: ^kernel.State, arg: int) -> string {
	return aux_checklstring(L, arg)
}
aux_optstring :: proc(L: ^kernel.State, arg: int, def: string) -> string {
	return aux_optlstring(L, arg, def)
}

// Check/convert a number argument -- reference `luaL_checknumber`.
aux_checknumber :: proc(L: ^kernel.State, arg: int) -> kernel.Number {
	d, ok := kernel.api_tonumberx(L, arg)
	if !ok {
		tag_error(L, arg, kernel.TNUMBER)
	}
	return d
}

// A number argument with a default -- reference `luaL_optnumber`.
aux_optnumber :: proc(L: ^kernel.State, arg: int, def: kernel.Number) -> kernel.Number {
	if kernel.api_isnoneornil(L, arg) {
		return def
	}
	return aux_checknumber(L, arg)
}

// The distinct "no integer representation" vs "not a number" split -- reference
// `interror`.
interror :: proc(L: ^kernel.State, arg: int) -> ! {
	if kernel.api_isnumber(L, arg) {
		aux_argerror(L, arg, "number has no integer representation")
	} else {
		tag_error(L, arg, kernel.TNUMBER)
	}
}

// Check/convert an integer argument -- reference `luaL_checkinteger`.
aux_checkinteger :: proc(L: ^kernel.State, arg: int) -> kernel.Integer {
	d, ok := kernel.api_tointegerx(L, arg)
	if !ok {
		interror(L, arg)
	}
	return d
}

// An integer argument with a default -- reference `luaL_optinteger`.
aux_optinteger :: proc(L: ^kernel.State, arg: int, def: kernel.Integer) -> kernel.Integer {
	if kernel.api_isnoneornil(L, arg) {
		return def
	}
	return aux_checkinteger(L, arg)
}

// Match a string argument against a table of allowed options, returning its index
// -- reference `luaL_checkoption`. Passing `def != ""` makes the argument optional.
aux_checkoption :: proc(L: ^kernel.State, arg: int, def: string, lst: []string) -> int {
	name := def != "" ? aux_optstring(L, arg, def) : aux_checkstring(L, arg)
	for opt, i in lst {
		if opt == name {
			return i
		}
	}
	aux_argerror(L, arg, kernel.api_pushfstring(L, "invalid option '%s'", name))
}

// --------------------------------------------------------------------------------
// Metatable / metafield helpers
// --------------------------------------------------------------------------------

// Push `obj[metatable][event]` if present, returning its type (or LUA_TNIL and
// nothing pushed) -- reference `luaL_getmetafield`.
aux_getmetafield :: proc(L: ^kernel.State, obj: int, event: string) -> int {
	if !kernel.api_getmetatable(L, obj) {
		return kernel.TNIL // no metatable at all
	}
	kernel.api_pushstring(L, event)
	tt := kernel.api_rawget(L, -2)
	if tt == kernel.TNIL {
		kernel.api_pop(L, 2) // drop metatable and the nil field
	} else {
		kernel.api_remove(L, -2) // drop just the metatable, keep the field
	}
	return tt
}

// Call `obj`'s metamethod `event` with `obj` as its single argument, leaving the
// result on the stack -- reference `luaL_callmeta`. Returns false (nothing pushed)
// when the metamethod is absent.
aux_callmeta :: proc(L: ^kernel.State, obj: int, event: string) -> bool {
	o := kernel.api_absindex(L, obj)
	if aux_getmetafield(L, o, event) == kernel.TNIL {
		return false
	}
	kernel.api_pushvalue(L, o)
	kernel.api_call(L, 1, 1)
	return true
}

// Fetch the registry-stored metatable named `tname` -- reference `luaL_getmetatable`
// macro. Returns the pushed value's type.
aux_getmetatable :: proc(L: ^kernel.State, tname: string) -> int {
	return kernel.api_getfield(L, kernel.REGISTRYINDEX, tname)
}

// Create (or find) the named metatable in the registry -- reference
// `luaL_newmetatable`. Returns true if it was freshly created (leaving it on the
// stack either way).
aux_newmetatable :: proc(L: ^kernel.State, tname: string) -> bool {
	if aux_getmetatable(L, tname) != kernel.TNIL {
		return false // name already registered; leave the existing table on top
	}
	kernel.api_pop(L, 1)
	kernel.api_createtable(L, 0, 2)
	kernel.api_pushstring(L, tname)
	kernel.api_setfield(L, -2, "__name")
	kernel.api_pushvalue(L, -1)
	kernel.api_setfield(L, kernel.REGISTRYINDEX, tname)
	return true
}

// Set the named registry metatable onto the value at the top of the stack --
// reference `luaL_setmetatable`.
aux_setmetatable :: proc(L: ^kernel.State, tname: string) {
	aux_getmetatable(L, tname)
	kernel.api_setmetatable(L, -2)
}

// Return the userdata payload pointer at `ud` if it carries metatable `tname`, else
// nil -- reference `luaL_testudata`.
aux_testudata :: proc(L: ^kernel.State, ud: int, tname: string) -> rawptr {
	p := kernel.api_touserdata(L, ud)
	if p != nil {
		if kernel.api_getmetatable(L, ud) {
			aux_getmetatable(L, tname)
			same := kernel.api_rawequal(L, -1, -2)
			kernel.api_pop(L, 2)
			if !same {
				return nil
			}
			return p
		}
	}
	return nil
}

// Like `luaL_testudata` but raises a type error on mismatch -- reference
// `luaL_checkudata`.
aux_checkudata :: proc(L: ^kernel.State, ud: int, tname: string) -> rawptr {
	p := aux_testudata(L, ud, tname)
	aux_argexpected(L, p != nil, ud, tname)
	return p
}

// --------------------------------------------------------------------------------
// Length and generic tostring
// --------------------------------------------------------------------------------

// The integer length of the value at `idx` (honoring `__len`) -- reference
// `luaL_len`. Raises if the length is not an integer.
aux_len :: proc(L: ^kernel.State, idx: int) -> kernel.Integer {
	kernel.api_len(L, idx)
	i, ok := kernel.api_tointegerx(L, -1)
	if !ok {
		aux_error(L, "object length is not an integer")
	}
	kernel.api_pop(L, 1)
	return i
}

// Convert any value to a display string (honoring `__tostring` and `__name`),
// pushing the result and also returning it -- reference `luaL_tolstring`.
aux_tolstring :: proc(L: ^kernel.State, idx: int) -> string {
	if aux_callmeta(L, idx, "__tostring") {
		if !kernel.api_isstring(L, -1) {
			aux_error(L, "'__tostring' must return a string")
		}
	} else {
		switch kernel.api_type(L, idx) {
		case kernel.TNUMBER:
			if kernel.api_isinteger(L, idx) {
				kernel.api_pushfstring(L, "%d", kernel.api_tointeger(L, idx))
			} else {
				kernel.api_pushfstring(L, "%f", kernel.api_tonumber(L, idx))
			}
		case kernel.TSTRING:
			kernel.api_pushvalue(L, idx)
		case kernel.TBOOLEAN:
			kernel.api_pushstring(L, kernel.api_toboolean(L, idx) ? "true" : "false")
		case kernel.TNIL:
			kernel.api_pushstring(L, "nil")
		case:
			tt := aux_getmetafield(L, idx, "__name")
			kind := (tt == kernel.TSTRING) ? aux_checkstring(L, -1) : aux_typename(L, idx)
			kernel.api_pushfstring(L, "%s: %p", kind, kernel.api_topointer(L, idx))
			if tt != kernel.TNIL {
				kernel.api_remove(L, -2) // drop the __name string, keep the result
			}
		}
	}
	s, _ := kernel.api_tolstring(L, -1)
	return s
}

// --------------------------------------------------------------------------------
// Reference system
// --------------------------------------------------------------------------------

// Store the value on top of the stack in table `t` and return an integer key that
// retrieves it -- reference `luaL_ref`. Freed references form a freelist whose head
// lives at `t[1]` (this is the 5.5 layout: reference 5.4 used a different slot).
aux_ref :: proc(L: ^kernel.State, t: int) -> int {
	if kernel.api_isnil(L, -1) {
		kernel.api_pop(L, 1)
		return REFNIL // nil has a fixed, shared reference
	}
	ta := kernel.api_absindex(L, t)
	ref: int
	if kernel.api_rawgeti(L, ta, 1) == kernel.TNUMBER {
		ref = int(kernel.api_tointeger(L, -1)) // freelist head
	} else {
		// First use of this table: initialize the freelist head to 0 (empty).
		ref = 0
		kernel.api_pushinteger(L, 0)
		kernel.api_rawseti(L, ta, 1)
	}
	kernel.api_pop(L, 1) // pop the freelist head we just read
	if ref != 0 {
		// Reuse a freed slot: unlink it from the freelist.
		kernel.api_rawgeti(L, ta, kernel.Integer(ref)) // t[ref] is the next free index
		kernel.api_rawseti(L, ta, 1) // t[1] = t[ref]
	} else {
		ref = int(kernel.api_rawlen(L, ta)) + 1 // fresh slot at the end
	}
	kernel.api_rawseti(L, ta, kernel.Integer(ref)) // t[ref] = value (popped)
	return ref
}

// Release a reference obtained from `luaL_ref`, returning its slot to the freelist
// -- reference `luaL_unref`. `LUA_NOREF`/`LUA_REFNIL` are silently ignored.
aux_unref :: proc(L: ^kernel.State, t: int, ref: int) {
	if ref >= 0 {
		ta := kernel.api_absindex(L, t)
		kernel.api_rawgeti(L, ta, 1) // current freelist head
		kernel.api_rawseti(L, ta, kernel.Integer(ref)) // t[ref] = t[1]
		kernel.api_pushinteger(L, kernel.Integer(ref))
		kernel.api_rawseti(L, ta, 1) // t[1] = ref
	}
}

// --------------------------------------------------------------------------------
// Module registration
// --------------------------------------------------------------------------------

// Register the functions in `l` into the table on top of the stack, sharing `nup`
// upvalues among them -- reference `luaL_setfuncs`. A `nil` `func` installs `false`
// as a placeholder. On return the upvalues are popped, leaving the table.
aux_setfuncs :: proc(L: ^kernel.State, l: []Reg, nup: int) {
	aux_checkstack(L, nup, "too many upvalues")
	for reg in l {
		if reg.func == nil {
			kernel.api_pushboolean(L, false)
		} else {
			// Copy the shared upvalues above the function for each registration.
			for _ in 0 ..< nup {
				kernel.api_pushvalue(L, -nup)
			}
			kernel.api_pushcclosure(L, reg.func, nup)
		}
		kernel.api_setfield(L, -(nup + 2), reg.name)
	}
	kernel.api_pop(L, nup)
}

// Create a fresh table sized for `l` and register `l` into it (no upvalues) --
// reference `luaL_newlib` (combining `newlibtable` + `setfuncs`).
aux_newlib :: proc(L: ^kernel.State, l: []Reg) {
	kernel.api_createtable(L, 0, len(l))
	aux_setfuncs(L, l, 0)
}

// Ensure `t[fname]` is a table, creating it if needed; leaves it on the stack and
// returns whether it already existed -- reference `luaL_getsubtable`.
aux_getsubtable :: proc(L: ^kernel.State, idx: int, fname: string) -> bool {
	if kernel.api_getfield(L, idx, fname) == kernel.TTABLE {
		return true // already there
	}
	kernel.api_pop(L, 1) // drop the non-table value
	ia := kernel.api_absindex(L, idx)
	kernel.api_newtable(L)
	kernel.api_pushvalue(L, -1) // keep a copy to leave on the stack
	kernel.api_setfield(L, ia, fname)
	return false
}

// Ensure module `modname` is loaded via `openf`, registering it in `_LOADED` (and
// optionally as a global) -- reference `luaL_requiref`. Leaves the module on top.
aux_requiref :: proc(L: ^kernel.State, modname: string, openf: kernel.C_Function, glb: bool) {
	aux_getsubtable(L, kernel.REGISTRYINDEX, LOADED_TABLE)
	kernel.api_getfield(L, -1, modname) // _LOADED[modname]
	if !kernel.api_toboolean(L, -1) {
		kernel.api_pop(L, 1) // drop the false/nil
		kernel.api_pushcfunction(L, openf)
		kernel.api_pushstring(L, modname) // argument to the opener
		kernel.api_call(L, 1, 1) // call openf(modname)
		kernel.api_pushvalue(L, -1) // keep a copy
		kernel.api_setfield(L, -3, modname) // _LOADED[modname] = module
	}
	if glb {
		kernel.api_pushvalue(L, -1)
		kernel.api_setglobal(L, modname) // _G[modname] = module
	}
	kernel.api_replace(L, -2) // remove _LOADED, leaving the module
}

// --------------------------------------------------------------------------------
// The growable string Buffer
// --------------------------------------------------------------------------------

// A growable byte buffer used to assemble strings without O(n^2) concatenation --
// reference `luaL_Buffer`. Small results live in the inline `init_b` scratch; once
// they outgrow it we spill to a heap "box" (a userdata on the stack whose `__gc`/
// `__close` frees the buffer, so a mid-assembly error can never leak it).
Buffer :: struct {
	b:      [^]u8, // where bytes are being written (into init_b or the box)
	size:   uint, // capacity of `b`
	n:      uint, // number of bytes used so far
	L:      ^kernel.State,
	init_b: [AUX_BUFFERSIZE]u8,
}

// The heap box's payload -- reference `UBox`. A userdata holding a malloc'd pointer
// and its size; its metamethods free the pointer.
UBox :: struct {
	box:   rawptr,
	bsize: uint,
}

// True when the buffer has spilled to a heap box (its data pointer is no longer the
// inline scratch) -- reference `buffonstack`.
buffonstack :: proc(B: ^Buffer) -> bool {
	return B.b != &B.init_b[0]
}

// Grow or shrink a box's heap buffer through the state allocator -- reference
// `resizebox`. Raises a memory error if a nonzero request fails.
resizebox :: proc(L: ^kernel.State, idx: int, newsize: uint) -> rawptr {
	box := (^UBox)(kernel.api_touserdata(L, idx))
	if box.bsize == newsize {
		return box.box
	}
	ud: rawptr
	allocf := kernel.api_getallocf(L, &ud)
	temp := allocf(ud, box.box, box.bsize, newsize)
	if temp == nil && newsize > 0 {
		kernel.api_pushstring(L, "not enough memory")
		kernel.api_error(L)
	}
	box.box = temp
	box.bsize = newsize
	return temp
}

// The box metamethod that frees its buffer (used for both `__gc` and `__close`) --
// reference `boxgc`.
boxgc :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^kernel.State)(Lp)
	resizebox(L, 1, 0)
	return 0
}

// Create a fresh, empty box on top of the stack with its freeing metatable --
// reference `newbox`.
newbox :: proc(L: ^kernel.State) {
	box := (^UBox)(kernel.api_newuserdatauv(L, size_of(UBox), 0))
	box.box = nil
	box.bsize = 0
	if aux_newmetatable(L, "_UBOX*") {
		mt := []Reg{{"__gc", boxgc}, {"__close", boxgc}}
		aux_setfuncs(L, mt, 0)
	}
	kernel.api_setmetatable(L, -2)
}

// Compute a new capacity that fits `sz` more bytes plus a terminating NUL --
// reference `newbuffsize`. Grows by 1.5x, guarding against overflow.
newbuffsize :: proc(B: ^Buffer, sz: uint) -> uint {
	max_size := uint(max(int))
	if sz >= max_size - B.n {
		aux_error(B.L, "resulting string too large")
	}
	newsize := B.size
	if newsize <= max_size / 3 * 2 {
		newsize += newsize >> 1 // *= 1.5 without overflow
	}
	if newsize < B.n + sz + 1 {
		newsize = B.n + sz + 1
	}
	return newsize
}

// Guarantee at least `sz` free bytes in `B`, returning a pointer to the free area
// -- reference `prepbuffsize`. `boxidx` is where the box/placeholder lives.
prepbuffsize :: proc(B: ^Buffer, sz: uint, boxidx: int) -> [^]u8 {
	if B.size - B.n >= sz {
		return B.b[B.n:]
	}
	L := B.L
	newsize := newbuffsize(B, sz)
	newbuff: [^]u8
	if buffonstack(B) {
		newbuff = ([^]u8)(resizebox(L, boxidx, newsize))
	} else {
		// First spill: swap the light-userdata placeholder for a real box, mark it
		// to-be-closed (so an error still frees it), then copy the inline content in.
		kernel.api_remove(L, boxidx)
		newbox(L)
		// When `boxidx == -1` the box newbox just pushed is already at the target
		// (the top), so repositioning is a no-op. We skip `lua_insert` in that case
		// because it would be a degenerate 1-element rotation -- reference Lua only
		// gets away with the unconditional call because its api_check compiles out.
		if boxidx != -1 {
			kernel.api_insert(L, boxidx)
		}
		kernel.api_toclose(L, boxidx)
		newbuff = ([^]u8)(resizebox(L, boxidx, newsize))
		runtime.mem_copy(newbuff, B.b, int(B.n))
	}
	B.b = newbuff
	B.size = newsize
	return newbuff[B.n:]
}

// Public "prepare a writable area" entry point -- reference `luaL_prepbuffsize`.
aux_prepbuffsize :: proc(B: ^Buffer, sz: uint) -> [^]u8 {
	return prepbuffsize(B, sz, -1)
}

// Record that `sz` bytes were just written into the prepared area -- reference the
// `luaL_addsize` macro.
aux_addsize :: proc(B: ^Buffer, sz: uint) {
	B.n += sz
}

// Append a byte slice -- reference `luaL_addlstring`.
aux_addlstring :: proc(B: ^Buffer, s: []u8) {
	if len(s) > 0 {
		b := prepbuffsize(B, uint(len(s)), -1)
		runtime.mem_copy(b, raw_data(s), len(s))
		aux_addsize(B, uint(len(s)))
	}
}

// Append a string -- reference `luaL_addstring`.
aux_addstring :: proc(B: ^Buffer, s: string) {
	aux_addlstring(B, transmute([]u8)s)
}

// Append a single byte -- reference `luaL_addchar`.
aux_addchar :: proc(B: ^Buffer, c: u8) {
	b := prepbuffsize(B, 1, -1)
	b[0] = c
	B.n += 1
}

// Append the value on top of the stack (converted to a string), then pop it --
// reference `luaL_addvalue`. Uses `-2` for the box index because, uniquely, the box
// sits *below* the string being consumed.
aux_addvalue :: proc(B: ^Buffer) {
	L := B.L
	s, _ := kernel.api_tolstring(L, -1)
	b := prepbuffsize(B, uint(len(s)), -2)
	runtime.mem_copy(b, raw_data(s), len(s))
	aux_addsize(B, uint(len(s)))
	kernel.api_pop(L, 1)
}

// Initialize an empty buffer, pushing its stack placeholder -- reference
// `luaL_buffinit`.
aux_buffinit :: proc(L: ^kernel.State, B: ^Buffer) {
	B.L = L
	B.b = &B.init_b[0]
	B.n = 0
	B.size = AUX_BUFFERSIZE
	kernel.api_pushlightuserdata(L, B) // placeholder marking the buffer's stack slot
}

// Initialize a buffer and immediately return a writable area of at least `sz`
// bytes -- reference `luaL_buffinitsize`.
aux_buffinitsize :: proc(L: ^kernel.State, B: ^Buffer, sz: uint) -> [^]u8 {
	aux_buffinit(L, B)
	return prepbuffsize(B, sz, -1)
}

// Finish the buffer, pushing the assembled string and cleaning up any box --
// reference `luaL_pushresult`. We copy the content into a real Lua string (rather
// than handing the box's buffer to the string subsystem) and let the box's
// `__close` free the heap buffer -- still fully error-safe.
aux_pushresult :: proc(B: ^Buffer) {
	L := B.L
	if !buffonstack(B) {
		kernel.api_pushlstring(L, B.b[:B.n]) // inline case: just copy out
		kernel.api_remove(L, -2) // drop the placeholder, leaving the string
	} else {
		kernel.api_pushlstring(L, B.b[:B.n]) // copy content while the box buffer is alive
		kernel.api_closeslot(L, -2) // run the box __close: frees the heap buffer now
		kernel.api_remove(L, -2) // drop the (closed) box, leaving the string
	}
}

// Record `sz` final bytes then finish -- reference `luaL_pushresultsize`.
aux_pushresultsize :: proc(B: ^Buffer, sz: uint) {
	aux_addsize(B, sz)
	aux_pushresult(B)
}

// Remove the last `n` bytes previously added to the buffer -- reference
// `luaL_buffsub`. Used by the package loader to peel off a trailing separator it
// had optimistically appended between accumulated error messages.
aux_buffsub :: proc(B: ^Buffer, n: uint) {
	B.n -= n
}

// Append `s` to the buffer, but with every occurrence of the literal substring `p`
// replaced by `r` -- reference `luaL_addgsub`. This is a plain (non-pattern) literal
// substitution, used by the package loader to expand path templates ('?' -> module
// name) and to turn dotted module names into directory paths ('.' -> path sep).
aux_addgsub :: proc(B: ^Buffer, s: string, p: string, r: string) {
	s := s
	if len(p) == 0 {
		// Reference relies on strstr never matching an empty needle in this API
		// (callers always pass a non-empty pattern); mirror that by doing nothing
		// but appending the source unchanged.
		aux_addstring(B, s)
		return
	}
	for {
		// Find the next occurrence of `p` in the remaining source.
		wild := -1
		if len(p) <= len(s) {
			for i in 0 ..= len(s) - len(p) {
				if s[i:i + len(p)] == p {
					wild = i
					break
				}
			}
		}
		if wild < 0 {
			break
		}
		aux_addlstring(B, transmute([]u8)s[:wild]) // prefix before the match
		aux_addstring(B, r) // the replacement
		s = s[wild + len(p):] // continue after the matched pattern
	}
	aux_addstring(B, s) // trailing suffix after the last match
}

// Return a copy of `s` with every literal `p` replaced by `r`, pushing it on the
// stack and returning it -- reference `luaL_gsub`.
aux_gsub :: proc(L: ^kernel.State, s: string, p: string, r: string) -> string {
	b: Buffer
	aux_buffinit(L, &b)
	aux_addgsub(&b, s, p, r)
	aux_pushresult(&b)
	res, _ := kernel.api_tolstring(L, -1)
	return res
}

// --------------------------------------------------------------------------------
// Chunk loaders
// --------------------------------------------------------------------------------

// Reader state for loading from an in-memory buffer -- reference `getS`'s data.
Load_S :: struct {
	s:    [^]u8,
	size: uint,
}

// The one-shot in-memory reader handed to `lua_load` -- reference `getS`.
getS :: proc "c" (L: ^kernel.State, ud: rawptr, size: ^uint) -> [^]u8 {
	ls := (^Load_S)(ud)
	if ls.size == 0 {
		return nil // already delivered the whole buffer
	}
	size^ = ls.size
	ls.size = 0
	return ls.s
}

// Load a chunk from a byte buffer -- reference `luaL_loadbufferx`.
aux_loadbufferx :: proc(
	L: ^kernel.State,
	buff: []u8,
	name: string,
	mode: string = "",
) -> kernel.Thread_Status {
	ls := Load_S{raw_data(buff), uint(len(buff))}
	return kernel.api_load(L, getS, &ls, name, mode)
}

// Load a chunk from a string, using the string itself as the chunk name --
// reference `luaL_loadstring`.
aux_loadstring :: proc(L: ^kernel.State, s: string) -> kernel.Thread_Status {
	return aux_loadbufferx(L, transmute([]u8)s, s, "")
}

// Freestanding keeps the auxiliary API that is meaningful without an OS. File
// loading, process-result helpers, console warnings, and luaL_newstate live only
// in auxlib.odin; an embedder creates a state with lua.new_state and its allocator.
aux_pushfail :: proc(L: ^kernel.State) {
	kernel.api_pushnil(L)
}

// There is no required clock source on bare metal. Address mixing preserves the
// reference routine's unsigned seed contract without inventing a platform hook.
aux_makeseed :: proc(L: ^kernel.State) -> u32 {
	local: int
	mixed := u64(uintptr(L)) ~ u64(uintptr(&local))
	mixed *= 0x9E3779B97F4A7C15
	return u32(mixed) ~ u32(mixed >> 32)
}
// Verify the running core is the version the caller was built for -- reference
// `luaL_checkversion`. In a single-binary Odin build there is no separately
// compiled core to disagree with (no shared-library ABI boundary), so the numeric
// version, integer/float widths, and value representation are consistent by
// construction. We still assert the version number matches so the check is a real
// (if always-satisfied) guard rather than a silent no-op.
aux_checkversion :: proc(L: ^kernel.State) {
	assert(kernel.VERSION_NUM == 505, "unexpected " + kernel.BRAND + " version number")
}



// --------------------------------------------------------------------------------
// Traceback support -- reference lauxlib.c's luaL_traceback and its static helpers.
// --------------------------------------------------------------------------------

// How the traceback splits a very deep stack: it shows the top LEVELS1 frames, an
// elision marker, then the bottom LEVELS2 frames -- reference LEVELS1 / LEVELS2.
@(private = "file")
LEVELS1 :: 10
@(private = "file")
LEVELS2 :: 11

// Render a Lua_Debug's short_src (a fixed NUL-terminated byte array) as a string.
@(private = "file")
short_src_str :: proc(ar: ^kernel.Debug_Info) -> string {
	return string(cstring(&ar.short_src[0]))
}

// Search the table at the top of the stack for the value at absolute index
// `objidx`, up to `level` levels of nesting. On success leaves the dotted name on
// the stack and returns true -- reference `findfield`.
@(private = "file")
findfield :: proc(L: ^kernel.State, objidx: int, level: int) -> bool {
	if level == 0 || !kernel.api_istable(L, -1) {
		return false
	}
	kernel.api_pushnil(L) // first key for lua_next
	for kernel.api_next(L, -2) {
		if kernel.api_type(L, -2) == kernel.TSTRING { // ignore non-string keys
			if kernel.api_rawequal(L, objidx, -1) {
				kernel.api_pop(L, 1) // drop value, keep the name
				return true
			} else if findfield(L, objidx, level - 1) {
				// stack: lib_name, lib_table, field_name -- join with a '.'
				kernel.api_pushstring(L, ".")
				kernel.api_replace(L, -3)
				kernel.api_concat(L, 3)
				return true
			}
		}
		kernel.api_pop(L, 1) // drop value, keep key for the next iteration
	}
	return false
}

// Try to name a function by scanning the loaded-modules table -- reference
// `pushglobalfuncname`. On success it leaves the name on the stack and returns
// true.
@(private = "file")
pushglobalfuncname :: proc(L: ^kernel.State, ar: ^kernel.Debug_Info) -> bool {
	top := kernel.api_gettop(L)
	kernel.api_getinfo(L, "f", ar) // push the function being described
	kernel.api_getfield(L, kernel.REGISTRYINDEX, LOADED_TABLE)
	aux_checkstack(L, 6, "not enough stack") // slots for findfield's recursion
	if findfield(L, top + 1, 2) {
		name, _ := kernel.api_tostring(L, -1)
		if len(name) >= 3 && name[0:3] == "_G." { // strip a leading "_G."
			kernel.api_pushstring(L, name[3:])
			kernel.api_remove(L, -2)
		}
		kernel.api_copy(L, -1, top + 1) // move the name to its proper slot
		kernel.api_settop(L, top + 1) // drop the loaded table and name copy
		return true
	}
	kernel.api_settop(L, top) // drop the function and the loaded table
	return false
}

// Push a human-readable description of a function frame -- reference `pushfuncname`.
@(private = "file")
pushfuncname :: proc(L: ^kernel.State, ar: ^kernel.Debug_Info) {
	if len(ar.namewhat) > 0 { // a name the code knows about
		kernel.api_pushfstring(L, "%s '%s'", ar.namewhat, ar.name)
	} else if len(ar.what) > 0 && ar.what[0] == 'm' { // the main chunk
		kernel.api_pushstring(L, "main chunk")
	} else if pushglobalfuncname(L, ar) { // a global/module name
		name, _ := kernel.api_tostring(L, -1)
		kernel.api_pushfstring(L, "function '%s'", name)
		kernel.api_remove(L, -2)
	} else if len(ar.what) > 0 && ar.what[0] != 'C' { // a Lua function: file:line
		kernel.api_pushfstring(L, "function <%s:%d>", short_src_str(ar), int(ar.linedefined))
	} else {
		kernel.api_pushstring(L, "?")
	}
}

// Find the index of the last (deepest) stack level -- reference `lastlevel`. Uses
// an exponential probe followed by a binary search.
@(private = "file")
lastlevel :: proc(L: ^kernel.State) -> int {
	ar: kernel.Debug_Info
	li := 1
	le := 1
	for kernel.api_getstack(L, le, &ar) { // find an upper bound
		li = le
		le *= 2
	}
	for li < le { // binary search
		m := (li + le) / 2
		if kernel.api_getstack(L, m, &ar) {
			li = m + 1
		} else {
			le = m
		}
	}
	return le - 1
}

// Build a stack traceback for thread `L1` into a string pushed on `L` -- reference
// `luaL_traceback`. `has_msg` gates the optional leading message (reference passes
// a NULL `msg` to omit it).
aux_traceback :: proc(
	L: ^kernel.State,
	L1: ^kernel.State,
	msg: string,
	has_msg: bool,
	level: int,
) {
	level := level
	b: Buffer
	ar: kernel.Debug_Info
	last := lastlevel(L1)
	// Only elide when there are more frames than the two shown windows combined.
	limit2show := (last - level > LEVELS1 + LEVELS2) ? LEVELS1 : -1
	aux_buffinit(L, &b)
	if has_msg {
		aux_addstring(&b, msg)
		aux_addchar(&b, '\n')
	}
	aux_addstring(&b, "stack traceback:")
	for kernel.api_getstack(L1, level, &ar) {
		level += 1
		// Reference tests `limit2show-- == 0`: fire the elision exactly once, when
		// the counter reaches zero, and decrement every iteration regardless.
		do_skip := limit2show == 0
		limit2show -= 1
		if do_skip {
			n := last - level - LEVELS2 + 1 // frames to skip
			kernel.api_pushfstring(L, "\n\t...\t(skipping %d levels)", n)
			aux_addvalue(&b)
			level += n // jump to the bottom window
		} else {
			kernel.api_getinfo(L1, "Slnt", &ar)
			if ar.currentline <= 0 {
				kernel.api_pushfstring(L, "\n\t%s: in ", short_src_str(&ar))
			} else {
				kernel.api_pushfstring(L, "\n\t%s:%d: in ", short_src_str(&ar), int(ar.currentline))
			}
			aux_addvalue(&b)
			pushfuncname(L, &ar)
			aux_addvalue(&b)
			if ar.istailcall != 0 {
				aux_addstring(&b, "\n\t(...tail calls...)")
			}
		}
	}
	aux_pushresult(&b)
}
