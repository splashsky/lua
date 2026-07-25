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
import "core:c/libc"
import lua "luao:lua"

// --------------------------------------------------------------------------------
// Constants and small shared types
// --------------------------------------------------------------------------------

// The size of the Buffer's inline scratch area. Reference computes this as
// 16*sizeof(void*)*sizeof(lua_Number) == 1024 on a 64-bit build; we hard-code the
// same value so short results never touch the heap.
LUAL_BUFFERSIZE :: 1024

// Reference values for the reference system's two special references.
LUA_NOREF :: -2
LUA_REFNIL :: -1

// Well-known registry sub-table names (reference `LUA_LOADED_TABLE` /
// `LUA_PRELOAD_TABLE`). `require` and module registration key off these.
LUA_LOADED_TABLE :: "_LOADED"
LUA_PRELOAD_TABLE :: "_PRELOAD"

// A single name→function registration record -- reference `luaL_Reg`. Unlike the
// C array (terminated by a `{NULL,NULL}` sentinel) we pass Odin slices, so the
// length is explicit and no sentinel is needed. A `nil` `func` still carries its
// reference meaning: a placeholder that installs `false` (used by libraries that
// reserve a field name for later).
Reg :: struct {
	name: string,
	func: lua.C_Function,
}

// --------------------------------------------------------------------------------
// Small internal string helpers
// --------------------------------------------------------------------------------

// Render a NUL-terminated `short_src` byte array (as filled by `lua_getinfo`) into
// an Odin string for use in formatted messages.
short_src_string :: proc(src: ^[lua.LUA_IDSIZE]u8) -> string {
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
luaL_where :: proc(L: ^lua.Lua_State, level: int) {
	ar: lua.Lua_Debug
	if lua.lua_getstack(L, level, &ar) {
		lua.lua_getinfo(L, "Sl", &ar)
		if ar.currentline > 0 {
			lua.lua_pushfstring(L, "%s:%d: ", short_src_string(&ar.short_src), int(ar.currentline))
			return
		}
	}
	lua.lua_pushfstring(L, "")
}

// Raise a formatted error, prefixed with the caller's `source:line:` -- reference
// `luaL_error`. Diverges (never returns); it longjmps through the active protected
// boundary just like `lua_error`.
luaL_error :: proc(L: ^lua.Lua_State, fmt: string, args: ..any) -> ! {
	luaL_where(L, 1)
	lua.lua_pushfstring(L, fmt, ..args)
	lua.lua_concat(L, 2)
	lua.lua_error(L)
}

// Raise a "bad argument" error for argument #`arg` -- reference `luaL_argerror`.
// We reproduce reference Lua's message shape as faithfully as our debug
// information allows. (Reference 5.5 additionally discounts vararg "extra
// arguments"; our `Lua_Debug` does not yet carry that count, so we omit that
// refinement -- the resulting message is still honest, just without that nuance.)
luaL_argerror :: proc(L: ^lua.Lua_State, arg: int, extramsg: string) -> ! {
	ar: lua.Lua_Debug
	if !lua.lua_getstack(L, 0, &ar) {
		// No stack frame (called outside a function): the simplest form.
		luaL_error(L, "bad argument #%d (%s)", arg, extramsg)
	}
	lua.lua_getinfo(L, "n", &ar)
	a := arg
	if ar.namewhat == "method" {
		a -= 1 // do not count the implicit self argument
		if a == 0 {
			luaL_error(L, "calling '%s' on bad self (%s)", ar.name, extramsg)
		}
	}
	name := ar.name
	if name == "" {
		name = "?"
	}
	luaL_error(L, "bad argument #%d to '%s' (%s)", a, name, extramsg)
}

// Raise a "wrong type" error for argument #`arg`, naming the type we wanted --
// reference `luaL_typeerror`. Honors a userdata's `__name` when present so the
// actual-type portion of the message is as informative as reference Lua's.
luaL_typeerror :: proc(L: ^lua.Lua_State, arg: int, tname: string) -> ! {
	typearg: string
	if luaL_getmetafield(L, arg, "__name") == lua.LUA_TSTRING {
		typearg, _ = lua.lua_tostring(L, -1)
	} else if lua.lua_type(L, arg) == lua.LUA_TLIGHTUSERDATA {
		typearg = "light userdata"
	} else {
		typearg = luaL_typename(L, arg)
	}
	msg := lua.lua_pushfstring(L, "%s expected, got %s", tname, typearg)
	luaL_argerror(L, arg, msg)
}

// The internal "wrong tag" helper used by the checkers -- reference `tag_error`.
tag_error :: proc(L: ^lua.Lua_State, arg: int, tag: int) -> ! {
	luaL_typeerror(L, arg, lua.lua_typename(L, tag))
}

// Assert a boolean argument condition, raising `luaL_argerror` if it fails --
// reference `luaL_argcheck`.
luaL_argcheck :: proc(L: ^lua.Lua_State, cond: bool, arg: int, extramsg: string) {
	if !cond {
		luaL_argerror(L, arg, extramsg)
	}
}

// Assert a condition, raising a `luaL_typeerror` naming `tname` on failure --
// reference `luaL_argexpected`.
luaL_argexpected :: proc(L: ^lua.Lua_State, cond: bool, arg: int, tname: string) {
	if !cond {
		luaL_typeerror(L, arg, tname)
	}
}

// The type name of the value at `idx` -- reference `luaL_typename` macro.
luaL_typename :: proc(L: ^lua.Lua_State, idx: int) -> string {
	return lua.lua_typename(L, lua.lua_type(L, idx))
}

// --------------------------------------------------------------------------------
// Argument checkers
// --------------------------------------------------------------------------------

// Ensure the stack can grow by `space` slots, raising a descriptive stack-overflow
// error otherwise -- reference `luaL_checkstack`.
luaL_checkstack :: proc(L: ^lua.Lua_State, space: int, msg: string) {
	if !lua.lua_checkstack(L, space) {
		if msg != "" {
			luaL_error(L, "stack overflow (%s)", msg)
		} else {
			luaL_error(L, "stack overflow")
		}
	}
}

// Demand that argument #`arg` has exactly type `t` -- reference `luaL_checktype`.
luaL_checktype :: proc(L: ^lua.Lua_State, arg: int, t: int) {
	if lua.lua_type(L, arg) != t {
		tag_error(L, arg, t)
	}
}

// Demand that argument #`arg` exists (is not "none") -- reference `luaL_checkany`.
luaL_checkany :: proc(L: ^lua.Lua_State, arg: int) {
	if lua.lua_type(L, arg) == lua.LUA_TNONE {
		luaL_argerror(L, arg, "value expected")
	}
}

// Check/convert a string argument, returning its bytes (length carried by the Odin
// string) -- reference `luaL_checklstring`. A number is silently accepted and
// stringified, matching reference Lua (the conversion happens in `lua_tolstring`).
luaL_checklstring :: proc(L: ^lua.Lua_State, arg: int) -> string {
	s, ok := lua.lua_tolstring(L, arg)
	if !ok {
		tag_error(L, arg, lua.LUA_TSTRING)
	}
	return s
}

// A string argument with a default when absent/nil -- reference `luaL_optlstring`.
luaL_optlstring :: proc(L: ^lua.Lua_State, arg: int, def: string) -> string {
	if lua.lua_isnoneornil(L, arg) {
		return def
	}
	return luaL_checklstring(L, arg)
}

// Convenience aliases matching reference's `luaL_checkstring` / `luaL_optstring`.
luaL_checkstring :: proc(L: ^lua.Lua_State, arg: int) -> string {
	return luaL_checklstring(L, arg)
}
luaL_optstring :: proc(L: ^lua.Lua_State, arg: int, def: string) -> string {
	return luaL_optlstring(L, arg, def)
}

// Check/convert a number argument -- reference `luaL_checknumber`.
luaL_checknumber :: proc(L: ^lua.Lua_State, arg: int) -> lua.Number {
	d, ok := lua.lua_tonumberx(L, arg)
	if !ok {
		tag_error(L, arg, lua.LUA_TNUMBER)
	}
	return d
}

// A number argument with a default -- reference `luaL_optnumber`.
luaL_optnumber :: proc(L: ^lua.Lua_State, arg: int, def: lua.Number) -> lua.Number {
	if lua.lua_isnoneornil(L, arg) {
		return def
	}
	return luaL_checknumber(L, arg)
}

// The distinct "no integer representation" vs "not a number" split -- reference
// `interror`.
interror :: proc(L: ^lua.Lua_State, arg: int) -> ! {
	if lua.lua_isnumber(L, arg) {
		luaL_argerror(L, arg, "number has no integer representation")
	} else {
		tag_error(L, arg, lua.LUA_TNUMBER)
	}
}

// Check/convert an integer argument -- reference `luaL_checkinteger`.
luaL_checkinteger :: proc(L: ^lua.Lua_State, arg: int) -> lua.Integer {
	d, ok := lua.lua_tointegerx(L, arg)
	if !ok {
		interror(L, arg)
	}
	return d
}

// An integer argument with a default -- reference `luaL_optinteger`.
luaL_optinteger :: proc(L: ^lua.Lua_State, arg: int, def: lua.Integer) -> lua.Integer {
	if lua.lua_isnoneornil(L, arg) {
		return def
	}
	return luaL_checkinteger(L, arg)
}

// Match a string argument against a table of allowed options, returning its index
// -- reference `luaL_checkoption`. Passing `def != ""` makes the argument optional.
luaL_checkoption :: proc(L: ^lua.Lua_State, arg: int, def: string, lst: []string) -> int {
	name := def != "" ? luaL_optstring(L, arg, def) : luaL_checkstring(L, arg)
	for opt, i in lst {
		if opt == name {
			return i
		}
	}
	luaL_argerror(L, arg, lua.lua_pushfstring(L, "invalid option '%s'", name))
}

// --------------------------------------------------------------------------------
// Metatable / metafield helpers
// --------------------------------------------------------------------------------

// Push `obj[metatable][event]` if present, returning its type (or LUA_TNIL and
// nothing pushed) -- reference `luaL_getmetafield`.
luaL_getmetafield :: proc(L: ^lua.Lua_State, obj: int, event: string) -> int {
	if !lua.lua_getmetatable(L, obj) {
		return lua.LUA_TNIL // no metatable at all
	}
	lua.lua_pushstring(L, event)
	tt := lua.lua_rawget(L, -2)
	if tt == lua.LUA_TNIL {
		lua.lua_pop(L, 2) // drop metatable and the nil field
	} else {
		lua.lua_remove(L, -2) // drop just the metatable, keep the field
	}
	return tt
}

// Call `obj`'s metamethod `event` with `obj` as its single argument, leaving the
// result on the stack -- reference `luaL_callmeta`. Returns false (nothing pushed)
// when the metamethod is absent.
luaL_callmeta :: proc(L: ^lua.Lua_State, obj: int, event: string) -> bool {
	o := lua.lua_absindex(L, obj)
	if luaL_getmetafield(L, o, event) == lua.LUA_TNIL {
		return false
	}
	lua.lua_pushvalue(L, o)
	lua.lua_call(L, 1, 1)
	return true
}

// Fetch the registry-stored metatable named `tname` -- reference `luaL_getmetatable`
// macro. Returns the pushed value's type.
luaL_getmetatable :: proc(L: ^lua.Lua_State, tname: string) -> int {
	return lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, tname)
}

// Create (or find) the named metatable in the registry -- reference
// `luaL_newmetatable`. Returns true if it was freshly created (leaving it on the
// stack either way).
luaL_newmetatable :: proc(L: ^lua.Lua_State, tname: string) -> bool {
	if luaL_getmetatable(L, tname) != lua.LUA_TNIL {
		return false // name already registered; leave the existing table on top
	}
	lua.lua_pop(L, 1)
	lua.lua_createtable(L, 0, 2)
	lua.lua_pushstring(L, tname)
	lua.lua_setfield(L, -2, "__name")
	lua.lua_pushvalue(L, -1)
	lua.lua_setfield(L, lua.LUA_REGISTRYINDEX, tname)
	return true
}

// Set the named registry metatable onto the value at the top of the stack --
// reference `luaL_setmetatable`.
luaL_setmetatable :: proc(L: ^lua.Lua_State, tname: string) {
	luaL_getmetatable(L, tname)
	lua.lua_setmetatable(L, -2)
}

// Return the userdata payload pointer at `ud` if it carries metatable `tname`, else
// nil -- reference `luaL_testudata`.
luaL_testudata :: proc(L: ^lua.Lua_State, ud: int, tname: string) -> rawptr {
	p := lua.lua_touserdata(L, ud)
	if p != nil {
		if lua.lua_getmetatable(L, ud) {
			luaL_getmetatable(L, tname)
			same := lua.lua_rawequal(L, -1, -2)
			lua.lua_pop(L, 2)
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
luaL_checkudata :: proc(L: ^lua.Lua_State, ud: int, tname: string) -> rawptr {
	p := luaL_testudata(L, ud, tname)
	luaL_argexpected(L, p != nil, ud, tname)
	return p
}

// --------------------------------------------------------------------------------
// Length and generic tostring
// --------------------------------------------------------------------------------

// The integer length of the value at `idx` (honoring `__len`) -- reference
// `luaL_len`. Raises if the length is not an integer.
luaL_len :: proc(L: ^lua.Lua_State, idx: int) -> lua.Integer {
	lua.lua_len(L, idx)
	i, ok := lua.lua_tointegerx(L, -1)
	if !ok {
		luaL_error(L, "object length is not an integer")
	}
	lua.lua_pop(L, 1)
	return i
}

// Convert any value to a display string (honoring `__tostring` and `__name`),
// pushing the result and also returning it -- reference `luaL_tolstring`.
luaL_tolstring :: proc(L: ^lua.Lua_State, idx: int) -> string {
	if luaL_callmeta(L, idx, "__tostring") {
		if !lua.lua_isstring(L, -1) {
			luaL_error(L, "'__tostring' must return a string")
		}
	} else {
		switch lua.lua_type(L, idx) {
		case lua.LUA_TNUMBER:
			if lua.lua_isinteger(L, idx) {
				lua.lua_pushfstring(L, "%d", lua.lua_tointeger(L, idx))
			} else {
				lua.lua_pushfstring(L, "%f", lua.lua_tonumber(L, idx))
			}
		case lua.LUA_TSTRING:
			lua.lua_pushvalue(L, idx)
		case lua.LUA_TBOOLEAN:
			lua.lua_pushstring(L, lua.lua_toboolean(L, idx) ? "true" : "false")
		case lua.LUA_TNIL:
			lua.lua_pushstring(L, "nil")
		case:
			tt := luaL_getmetafield(L, idx, "__name")
			kind := (tt == lua.LUA_TSTRING) ? luaL_checkstring(L, -1) : luaL_typename(L, idx)
			lua.lua_pushfstring(L, "%s: %p", kind, lua.lua_topointer(L, idx))
			if tt != lua.LUA_TNIL {
				lua.lua_remove(L, -2) // drop the __name string, keep the result
			}
		}
	}
	s, _ := lua.lua_tolstring(L, -1)
	return s
}

// --------------------------------------------------------------------------------
// Reference system
// --------------------------------------------------------------------------------

// Store the value on top of the stack in table `t` and return an integer key that
// retrieves it -- reference `luaL_ref`. Freed references form a freelist whose head
// lives at `t[1]` (this is the 5.5 layout: reference 5.4 used a different slot).
luaL_ref :: proc(L: ^lua.Lua_State, t: int) -> int {
	if lua.lua_isnil(L, -1) {
		lua.lua_pop(L, 1)
		return LUA_REFNIL // nil has a fixed, shared reference
	}
	ta := lua.lua_absindex(L, t)
	ref: int
	if lua.lua_rawgeti(L, ta, 1) == lua.LUA_TNUMBER {
		ref = int(lua.lua_tointeger(L, -1)) // freelist head
	} else {
		// First use of this table: initialize the freelist head to 0 (empty).
		ref = 0
		lua.lua_pushinteger(L, 0)
		lua.lua_rawseti(L, ta, 1)
	}
	lua.lua_pop(L, 1) // pop the freelist head we just read
	if ref != 0 {
		// Reuse a freed slot: unlink it from the freelist.
		lua.lua_rawgeti(L, ta, lua.Integer(ref)) // t[ref] is the next free index
		lua.lua_rawseti(L, ta, 1) // t[1] = t[ref]
	} else {
		ref = int(lua.lua_rawlen(L, ta)) + 1 // fresh slot at the end
	}
	lua.lua_rawseti(L, ta, lua.Integer(ref)) // t[ref] = value (popped)
	return ref
}

// Release a reference obtained from `luaL_ref`, returning its slot to the freelist
// -- reference `luaL_unref`. `LUA_NOREF`/`LUA_REFNIL` are silently ignored.
luaL_unref :: proc(L: ^lua.Lua_State, t: int, ref: int) {
	if ref >= 0 {
		ta := lua.lua_absindex(L, t)
		lua.lua_rawgeti(L, ta, 1) // current freelist head
		lua.lua_rawseti(L, ta, lua.Integer(ref)) // t[ref] = t[1]
		lua.lua_pushinteger(L, lua.Integer(ref))
		lua.lua_rawseti(L, ta, 1) // t[1] = ref
	}
}

// --------------------------------------------------------------------------------
// Module registration
// --------------------------------------------------------------------------------

// Register the functions in `l` into the table on top of the stack, sharing `nup`
// upvalues among them -- reference `luaL_setfuncs`. A `nil` `func` installs `false`
// as a placeholder. On return the upvalues are popped, leaving the table.
luaL_setfuncs :: proc(L: ^lua.Lua_State, l: []Reg, nup: int) {
	luaL_checkstack(L, nup, "too many upvalues")
	for reg in l {
		if reg.func == nil {
			lua.lua_pushboolean(L, false)
		} else {
			// Copy the shared upvalues above the function for each registration.
			for _ in 0 ..< nup {
				lua.lua_pushvalue(L, -nup)
			}
			lua.lua_pushcclosure(L, reg.func, nup)
		}
		lua.lua_setfield(L, -(nup + 2), reg.name)
	}
	lua.lua_pop(L, nup)
}

// Create a fresh table sized for `l` and register `l` into it (no upvalues) --
// reference `luaL_newlib` (combining `newlibtable` + `setfuncs`).
luaL_newlib :: proc(L: ^lua.Lua_State, l: []Reg) {
	lua.lua_createtable(L, 0, len(l))
	luaL_setfuncs(L, l, 0)
}

// Ensure `t[fname]` is a table, creating it if needed; leaves it on the stack and
// returns whether it already existed -- reference `luaL_getsubtable`.
luaL_getsubtable :: proc(L: ^lua.Lua_State, idx: int, fname: string) -> bool {
	if lua.lua_getfield(L, idx, fname) == lua.LUA_TTABLE {
		return true // already there
	}
	lua.lua_pop(L, 1) // drop the non-table value
	ia := lua.lua_absindex(L, idx)
	lua.lua_newtable(L)
	lua.lua_pushvalue(L, -1) // keep a copy to leave on the stack
	lua.lua_setfield(L, ia, fname)
	return false
}

// Ensure module `modname` is loaded via `openf`, registering it in `_LOADED` (and
// optionally as a global) -- reference `luaL_requiref`. Leaves the module on top.
luaL_requiref :: proc(L: ^lua.Lua_State, modname: string, openf: lua.C_Function, glb: bool) {
	luaL_getsubtable(L, lua.LUA_REGISTRYINDEX, LUA_LOADED_TABLE)
	lua.lua_getfield(L, -1, modname) // _LOADED[modname]
	if !lua.lua_toboolean(L, -1) {
		lua.lua_pop(L, 1) // drop the false/nil
		lua.lua_pushcfunction(L, openf)
		lua.lua_pushstring(L, modname) // argument to the opener
		lua.lua_call(L, 1, 1) // call openf(modname)
		lua.lua_pushvalue(L, -1) // keep a copy
		lua.lua_setfield(L, -3, modname) // _LOADED[modname] = module
	}
	if glb {
		lua.lua_pushvalue(L, -1)
		lua.lua_setglobal(L, modname) // _G[modname] = module
	}
	lua.lua_replace(L, -2) // remove _LOADED, leaving the module
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
	L:      ^lua.Lua_State,
	init_b: [LUAL_BUFFERSIZE]u8,
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
resizebox :: proc(L: ^lua.Lua_State, idx: int, newsize: uint) -> rawptr {
	box := (^UBox)(lua.lua_touserdata(L, idx))
	if box.bsize == newsize {
		return box.box
	}
	ud: rawptr
	allocf := lua.lua_getallocf(L, &ud)
	temp := allocf(ud, box.box, box.bsize, newsize)
	if temp == nil && newsize > 0 {
		lua.lua_pushstring(L, "not enough memory")
		lua.lua_error(L)
	}
	box.box = temp
	box.bsize = newsize
	return temp
}

// The box metamethod that frees its buffer (used for both `__gc` and `__close`) --
// reference `boxgc`.
boxgc :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^lua.Lua_State)(Lp)
	resizebox(L, 1, 0)
	return 0
}

// Create a fresh, empty box on top of the stack with its freeing metatable --
// reference `newbox`.
newbox :: proc(L: ^lua.Lua_State) {
	box := (^UBox)(lua.lua_newuserdatauv(L, size_of(UBox), 0))
	box.box = nil
	box.bsize = 0
	if luaL_newmetatable(L, "_UBOX*") {
		mt := []Reg{{"__gc", boxgc}, {"__close", boxgc}}
		luaL_setfuncs(L, mt, 0)
	}
	lua.lua_setmetatable(L, -2)
}

// Compute a new capacity that fits `sz` more bytes plus a terminating NUL --
// reference `newbuffsize`. Grows by 1.5x, guarding against overflow.
newbuffsize :: proc(B: ^Buffer, sz: uint) -> uint {
	max_size := uint(max(int))
	if sz >= max_size - B.n {
		luaL_error(B.L, "resulting string too large")
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
		lua.lua_remove(L, boxidx)
		newbox(L)
		// When `boxidx == -1` the box newbox just pushed is already at the target
		// (the top), so repositioning is a no-op. We skip `lua_insert` in that case
		// because it would be a degenerate 1-element rotation -- reference Lua only
		// gets away with the unconditional call because its api_check compiles out.
		if boxidx != -1 {
			lua.lua_insert(L, boxidx)
		}
		lua.lua_toclose(L, boxidx)
		newbuff = ([^]u8)(resizebox(L, boxidx, newsize))
		runtime.mem_copy(newbuff, B.b, int(B.n))
	}
	B.b = newbuff
	B.size = newsize
	return newbuff[B.n:]
}

// Public "prepare a writable area" entry point -- reference `luaL_prepbuffsize`.
luaL_prepbuffsize :: proc(B: ^Buffer, sz: uint) -> [^]u8 {
	return prepbuffsize(B, sz, -1)
}

// Record that `sz` bytes were just written into the prepared area -- reference the
// `luaL_addsize` macro.
luaL_addsize :: proc(B: ^Buffer, sz: uint) {
	B.n += sz
}

// Append a byte slice -- reference `luaL_addlstring`.
luaL_addlstring :: proc(B: ^Buffer, s: []u8) {
	if len(s) > 0 {
		b := prepbuffsize(B, uint(len(s)), -1)
		runtime.mem_copy(b, raw_data(s), len(s))
		luaL_addsize(B, uint(len(s)))
	}
}

// Append a string -- reference `luaL_addstring`.
luaL_addstring :: proc(B: ^Buffer, s: string) {
	luaL_addlstring(B, transmute([]u8)s)
}

// Append a single byte -- reference `luaL_addchar`.
luaL_addchar :: proc(B: ^Buffer, c: u8) {
	b := prepbuffsize(B, 1, -1)
	b[0] = c
	B.n += 1
}

// Append the value on top of the stack (converted to a string), then pop it --
// reference `luaL_addvalue`. Uses `-2` for the box index because, uniquely, the box
// sits *below* the string being consumed.
luaL_addvalue :: proc(B: ^Buffer) {
	L := B.L
	s, _ := lua.lua_tolstring(L, -1)
	b := prepbuffsize(B, uint(len(s)), -2)
	runtime.mem_copy(b, raw_data(s), len(s))
	luaL_addsize(B, uint(len(s)))
	lua.lua_pop(L, 1)
}

// Initialize an empty buffer, pushing its stack placeholder -- reference
// `luaL_buffinit`.
luaL_buffinit :: proc(L: ^lua.Lua_State, B: ^Buffer) {
	B.L = L
	B.b = &B.init_b[0]
	B.n = 0
	B.size = LUAL_BUFFERSIZE
	lua.lua_pushlightuserdata(L, B) // placeholder marking the buffer's stack slot
}

// Initialize a buffer and immediately return a writable area of at least `sz`
// bytes -- reference `luaL_buffinitsize`.
luaL_buffinitsize :: proc(L: ^lua.Lua_State, B: ^Buffer, sz: uint) -> [^]u8 {
	luaL_buffinit(L, B)
	return prepbuffsize(B, sz, -1)
}

// Finish the buffer, pushing the assembled string and cleaning up any box --
// reference `luaL_pushresult`. We copy the content into a real Lua string (rather
// than handing the box's buffer to the string subsystem) and let the box's
// `__close` free the heap buffer -- still fully error-safe.
luaL_pushresult :: proc(B: ^Buffer) {
	L := B.L
	if !buffonstack(B) {
		lua.lua_pushlstring(L, B.b[:B.n]) // inline case: just copy out
		lua.lua_remove(L, -2) // drop the placeholder, leaving the string
	} else {
		lua.lua_pushlstring(L, B.b[:B.n]) // copy content while the box buffer is alive
		lua.lua_closeslot(L, -2) // run the box __close: frees the heap buffer now
		lua.lua_remove(L, -2) // drop the (closed) box, leaving the string
	}
}

// Record `sz` final bytes then finish -- reference `luaL_pushresultsize`.
luaL_pushresultsize :: proc(B: ^Buffer, sz: uint) {
	luaL_addsize(B, sz)
	luaL_pushresult(B)
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
getS :: proc "c" (L: ^lua.Lua_State, ud: rawptr, size: ^uint) -> [^]u8 {
	ls := (^Load_S)(ud)
	if ls.size == 0 {
		return nil // already delivered the whole buffer
	}
	size^ = ls.size
	ls.size = 0
	return ls.s
}

// Load a chunk from a byte buffer -- reference `luaL_loadbufferx`.
luaL_loadbufferx :: proc(
	L: ^lua.Lua_State,
	buff: []u8,
	name: string,
	mode: string = "",
) -> lua.Thread_Status {
	ls := Load_S{raw_data(buff), uint(len(buff))}
	return lua.lua_load(L, getS, &ls, name, mode)
}

// Load a chunk from a string, using the string itself as the chunk name --
// reference `luaL_loadstring`.
luaL_loadstring :: proc(L: ^lua.Lua_State, s: string) -> lua.Thread_Status {
	return luaL_loadbufferx(L, transmute([]u8)s, s, "")
}

// Reader state for loading from a file -- reference `LoadF`.
Load_F :: struct {
	n:    int, // number of pre-read (pushed-back) bytes still in `buff`
	f:    ^libc.FILE,
	buff: [8192]u8,
}

// The buffered file reader handed to `lua_load` -- reference `getF`.
getF :: proc "c" (L: ^lua.Lua_State, ud: rawptr, size: ^uint) -> [^]u8 {
	context = runtime.default_context()
	lf := (^Load_F)(ud)
	if lf.n > 0 {
		// Deliver the bytes pre-read while sniffing the header (`#!`/BOM).
		size^ = uint(lf.n)
		lf.n = 0
	} else {
		if libc.feof(lf.f) != 0 {
			return nil
		}
		nr := libc.fread(&lf.buff[0], 1, len(lf.buff), lf.f)
		size^ = nr
		if nr == 0 {
			return nil
		}
	}
	return &lf.buff[0]
}

// Skip a UTF-8 BOM and a leading `#!` line before compiling -- reference
// `skipcomment`. Returns the first significant byte via `c`.
skipcomment :: proc(lf: ^Load_F, c: ^i32) {
	bom := [3]i32{0xEF, 0xBB, 0xBF}
	ci := libc.getc(lf.f)
	// Consume a BOM if the first bytes match it exactly.
	i := 0
	for i < 3 && ci == bom[i] {
		lf.buff[lf.n] = u8(ci)
		lf.n += 1
		ci = libc.getc(lf.f)
		i += 1
	}
	if ci == '#' {
		// A `#!` line: skip until end of line, then report the next byte.
		for {
			ci = libc.getc(lf.f)
			if ci == libc.EOF || ci == '\n' {
				break
			}
		}
		// Reset the pre-read buffer -- the shebang line is not part of the chunk.
		lf.n = 0
		c^ = libc.getc(lf.f)
		return
	}
	c^ = ci
}

// Load a chunk from a named file (or stdin when `filename == ""`) -- reference
// `luaL_loadfilex`.
luaL_loadfilex :: proc(
	L: ^lua.Lua_State,
	filename: string,
	mode: string = "",
) -> lua.Thread_Status {
	lf: Load_F
	if filename == "" {
		lua.lua_pushstring(L, "=stdin")
		lf.f = libc.stdin
	} else {
		lua.lua_pushfstring(L, "@%s", filename)
		cname := cstring_from(filename)
		defer delete_cstring(cname)
		lf.f = libc.fopen(cname, "r")
		if lf.f == nil {
			lua.lua_pushfstring(L, "cannot open %s", filename)
			lua.lua_remove(L, -2)
			return .Err_Err
		}
	}
	c: i32
	skipcomment(&lf, &c)
	if c != libc.EOF {
		lf.buff[lf.n] = u8(c)
		lf.n += 1
	}
	chunkname, _ := lua.lua_tostring(L, -1)
	status := lua.lua_load(L, getF, &lf, chunkname, mode)
	readerr := libc.ferror(lf.f) != 0
	if filename != "" {
		libc.fclose(lf.f)
	}
	if readerr {
		lua.lua_settop(L, -2) // remove any partial result
		lua.lua_pushfstring(L, "cannot read %s", filename)
		lua.lua_remove(L, -2)
		return .Err_Err
	}
	lua.lua_remove(L, -2) // remove the chunk name, leaving the result
	return status
}

// --------------------------------------------------------------------------------
// libc string ↔ cstring helpers (kept local so nothing else needs to know)
// --------------------------------------------------------------------------------

// Allocate a NUL-terminated copy of `s` for handing to libc. Freed with
// `delete_cstring`.
cstring_from :: proc(s: string) -> cstring {
	buf := make([]u8, len(s) + 1)
	if len(s) > 0 {
		runtime.mem_copy(raw_data(buf), raw_data(s), len(s))
	}
	buf[len(s)] = 0
	return cstring(raw_data(buf))
}

delete_cstring :: proc(c: cstring) {
	free(rawptr(c))
}

// --------------------------------------------------------------------------------
// State creation, allocator, and the default warning system
// --------------------------------------------------------------------------------

// Create a new Lua state wired to the default allocator and warning handler --
// reference `luaL_newstate`. (Reference also installs a panic function via
// `lua_atpanic`; our top-level driver runs everything under `lua_pcall`, so an
// unhandled panic hook is not needed here.)
luaL_newstate :: proc() -> ^lua.Lua_State {
	L := lua.new_state(lua.default_allocator())
	if L != nil {
		lua.lua_setwarnf(L, warnfon, L)
	}
	return L
}

// `luaL_pushfail` -- reference Lua's `#define luaL_pushfail(L) lua_pushnil(L)`.
// The "fail" value in 5.5 is simply nil; a named helper keeps call sites reading
// like the reference source (and gives us one place to change if that ever moves).
luaL_pushfail :: proc(L: ^lua.Lua_State) {
	lua.lua_pushnil(L)
}

// `luaL_fileresult` -- reference Lua's OS-result reporter. On success it pushes
// `true`; on failure it pushes `fail`, an error string (prefixed with the file
// name if one was given), and the numeric errno. Callers pass `stat = true` for a
// successful C call. The errno is read once up front because subsequent Lua API
// calls may clobber it.
luaL_fileresult :: proc(L: ^lua.Lua_State, stat: bool, fname: string, has_fname: bool) -> i32 {
	en := libc.errno()^ // capture before any Lua API call can change it
	if stat {
		lua.lua_pushboolean(L, true)
		return 1
	}
	luaL_pushfail(L)
	msg := en != 0 ? string(libc.strerror(en)) : "(no extra info)"
	if has_fname {
		lua.lua_pushfstring(L, "%s: %s", fname, msg)
	} else {
		lua.lua_pushstring(L, msg)
	}
	lua.lua_pushinteger(L, lua.Integer(en))
	return 3
}

// `luaL_execresult` -- reference Lua's process-result reporter for os.execute /
// io's pclose. Without POSIX's `l_inspectstat` there is nothing to decode, so the
// termination type is always "exit" and the code is the raw status: success is
// status 0, and we push (true|fail, "exit", code).
luaL_execresult :: proc(L: ^lua.Lua_State, stat: i32) -> i32 {
	if stat != 0 && libc.errno()^ != 0 {
		// A real errno means the command could not be launched at all.
		return luaL_fileresult(L, false, "", false)
	}
	if stat == 0 {
		lua.lua_pushboolean(L, true)
	} else {
		luaL_pushfail(L)
	}
	lua.lua_pushstring(L, "exit")
	lua.lua_pushinteger(L, lua.Integer(stat))
	return 3
}

// `luaL_makeseed` -- reference Lua's seed generator. It mixes a stack address
// (Address Space Layout Randomization, when present) with the current wall-clock
// time and folds the bytes down to an unsigned 32-bit value. The result is
// *deliberately* nondeterministic: it seeds the PRNG and the sort's pivot
// randomization, so faithfulness here means "some unpredictable unsigned int",
// not "these exact bytes". We reproduce the reference's shape (address XOR time,
// folded) without promising bit-for-bit identical output across runs.
luaL_makeseed :: proc(L: ^lua.Lua_State) -> u32 {
	// A local's address supplies ASLR-derived entropy; the clock supplies the rest.
	local: int
	addr := uintptr(&local)
	t := u64(libc.time(nil))
	mixed := u64(addr) ~ (t * 0x9E3779B97F4A7C15) // golden-ratio odd multiplier
	// Fold the 64 bits into 32 by XORing the halves, matching the reference's
	// "xor the buffer words together" reduction.
	return u32(mixed) ~ u32(mixed >> 32)
}


// The warning subsystem's three states -- reference `warnfoff`/`warnfon`/
// `warnfcont`. Control messages ("@on"/"@off") toggle emission; ordinary messages
// are written to stderr, accumulating fragments until a non-continued piece flushes
// a trailing newline.

// Handle a possible "@..." control message; returns true if it was one.
checkcontrol :: proc(L: ^lua.Lua_State, message: string, tocont: bool) -> bool {
	if tocont || len(message) == 0 || message[0] != '@' {
		return false
	}
	body := message[1:]
	if body == "off" {
		lua.lua_setwarnf(L, warnfoff, L)
	} else if body == "on" {
		lua.lua_setwarnf(L, warnfon, L)
	}
	return true
}

warnfoff :: proc "c" (ud: rawptr, msg: cstring, tocont: i32) {
	context = runtime.default_context()
	checkcontrol((^lua.Lua_State)(ud), string(msg), tocont != 0)
}

warnfcont :: proc "c" (ud: rawptr, msg: cstring, tocont: i32) {
	context = runtime.default_context()
	L := (^lua.Lua_State)(ud)
	write_stderr(string(msg))
	if tocont != 0 {
		lua.lua_setwarnf(L, warnfcont, L) // more to come
	} else {
		write_stderr("\n")
		lua.lua_setwarnf(L, warnfon, L) // next call starts a new warning
	}
}

warnfon :: proc "c" (ud: rawptr, msg: cstring, tocont: i32) {
	context = runtime.default_context()
	if checkcontrol((^lua.Lua_State)(ud), string(msg), tocont != 0) {
		return
	}
	write_stderr("Lua warning: ")
	warnfcont(ud, msg, tocont)
}

// Write raw bytes to stderr through libc (matching reference `lua_writestringerror`
// which also goes to the C stderr stream, so io buffering stays consistent).
write_stderr :: proc(s: string) {
	if len(s) > 0 {
		libc.fwrite(raw_data(s), 1, uint(len(s)), libc.stderr)
	}
	libc.fflush(libc.stderr)
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
short_src_str :: proc(ar: ^lua.Lua_Debug) -> string {
	return string(cstring(&ar.short_src[0]))
}

// Search the table at the top of the stack for the value at absolute index
// `objidx`, up to `level` levels of nesting. On success leaves the dotted name on
// the stack and returns true -- reference `findfield`.
@(private = "file")
findfield :: proc(L: ^lua.Lua_State, objidx: int, level: int) -> bool {
	if level == 0 || !lua.lua_istable(L, -1) {
		return false
	}
	lua.lua_pushnil(L) // first key for lua_next
	for lua.lua_next(L, -2) {
		if lua.lua_type(L, -2) == lua.LUA_TSTRING { // ignore non-string keys
			if lua.lua_rawequal(L, objidx, -1) {
				lua.lua_pop(L, 1) // drop value, keep the name
				return true
			} else if findfield(L, objidx, level - 1) {
				// stack: lib_name, lib_table, field_name -- join with a '.'
				lua.lua_pushstring(L, ".")
				lua.lua_replace(L, -3)
				lua.lua_concat(L, 3)
				return true
			}
		}
		lua.lua_pop(L, 1) // drop value, keep key for the next iteration
	}
	return false
}

// Try to name a function by scanning the loaded-modules table -- reference
// `pushglobalfuncname`. On success it leaves the name on the stack and returns
// true.
@(private = "file")
pushglobalfuncname :: proc(L: ^lua.Lua_State, ar: ^lua.Lua_Debug) -> bool {
	top := lua.lua_gettop(L)
	lua.lua_getinfo(L, "f", ar) // push the function being described
	lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, LUA_LOADED_TABLE)
	luaL_checkstack(L, 6, "not enough stack") // slots for findfield's recursion
	if findfield(L, top + 1, 2) {
		name, _ := lua.lua_tostring(L, -1)
		if len(name) >= 3 && name[0:3] == "_G." { // strip a leading "_G."
			lua.lua_pushstring(L, name[3:])
			lua.lua_remove(L, -2)
		}
		lua.lua_copy(L, -1, top + 1) // move the name to its proper slot
		lua.lua_settop(L, top + 1) // drop the loaded table and name copy
		return true
	}
	lua.lua_settop(L, top) // drop the function and the loaded table
	return false
}

// Push a human-readable description of a function frame -- reference `pushfuncname`.
@(private = "file")
pushfuncname :: proc(L: ^lua.Lua_State, ar: ^lua.Lua_Debug) {
	if len(ar.namewhat) > 0 { // a name the code knows about
		lua.lua_pushfstring(L, "%s '%s'", ar.namewhat, ar.name)
	} else if len(ar.what) > 0 && ar.what[0] == 'm' { // the main chunk
		lua.lua_pushstring(L, "main chunk")
	} else if pushglobalfuncname(L, ar) { // a global/module name
		name, _ := lua.lua_tostring(L, -1)
		lua.lua_pushfstring(L, "function '%s'", name)
		lua.lua_remove(L, -2)
	} else if len(ar.what) > 0 && ar.what[0] != 'C' { // a Lua function: file:line
		lua.lua_pushfstring(L, "function <%s:%d>", short_src_str(ar), int(ar.linedefined))
	} else {
		lua.lua_pushstring(L, "?")
	}
}

// Find the index of the last (deepest) stack level -- reference `lastlevel`. Uses
// an exponential probe followed by a binary search.
@(private = "file")
lastlevel :: proc(L: ^lua.Lua_State) -> int {
	ar: lua.Lua_Debug
	li := 1
	le := 1
	for lua.lua_getstack(L, le, &ar) { // find an upper bound
		li = le
		le *= 2
	}
	for li < le { // binary search
		m := (li + le) / 2
		if lua.lua_getstack(L, m, &ar) {
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
luaL_traceback :: proc(
	L: ^lua.Lua_State,
	L1: ^lua.Lua_State,
	msg: string,
	has_msg: bool,
	level: int,
) {
	level := level
	b: Buffer
	ar: lua.Lua_Debug
	last := lastlevel(L1)
	// Only elide when there are more frames than the two shown windows combined.
	limit2show := (last - level > LEVELS1 + LEVELS2) ? LEVELS1 : -1
	luaL_buffinit(L, &b)
	if has_msg {
		luaL_addstring(&b, msg)
		luaL_addchar(&b, '\n')
	}
	luaL_addstring(&b, "stack traceback:")
	for lua.lua_getstack(L1, level, &ar) {
		level += 1
		// Reference tests `limit2show-- == 0`: fire the elision exactly once, when
		// the counter reaches zero, and decrement every iteration regardless.
		do_skip := limit2show == 0
		limit2show -= 1
		if do_skip {
			n := last - level - LEVELS2 + 1 // frames to skip
			lua.lua_pushfstring(L, "\n\t...\t(skipping %d levels)", n)
			luaL_addvalue(&b)
			level += n // jump to the bottom window
		} else {
			lua.lua_getinfo(L1, "Slnt", &ar)
			if ar.currentline <= 0 {
				lua.lua_pushfstring(L, "\n\t%s: in ", short_src_str(&ar))
			} else {
				lua.lua_pushfstring(L, "\n\t%s:%d: in ", short_src_str(&ar), int(ar.currentline))
			}
			luaL_addvalue(&b)
			pushfuncname(L, &ar)
			luaL_addvalue(&b)
			if ar.istailcall != 0 {
				luaL_addstring(&b, "\n\t(...tail calls...)")
			}
		}
	}
	luaL_pushresult(&b)
}
