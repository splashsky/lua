package stdlib

// tablib.odin -- our analogue of reference Lua's `ltablib.c`.
//
// The table library: insert/remove/move/concat/pack/unpack/sort, plus the
// 5.5 additions `table.create`. Everything is written against the public API so
// it works uniformly on real tables and on objects that *behave* like tables via
// __index/__newindex/__len metamethods (see `checktab`).
//
// `sort` is a faithful port of reference's quicksort, including the randomized
// pivot fallback that guards against adversarial inputs and the "invalid order
// function" checks that detect an inconsistent comparator.

import "base:runtime"
import kernel "lang:kernel"

@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^kernel.State {
	return (^kernel.State)(Lp)
}

// Capability flags an argument must provide to stand in for a table -- reference
// TAB_R/TAB_W/TAB_L. `sort`/`insert`/`remove` need read+write+length; `concat`
// needs read+length; `move` needs read on the source and write on the target.
@(private = "file")
TAB_R :: 1
@(private = "file")
TAB_W :: 2
@(private = "file")
TAB_L :: 4
@(private = "file")
TAB_RW :: TAB_R | TAB_W

// Push `key`, raw-get it from the table `n` slots down, and report whether the
// result is non-nil -- reference `checkfield`.
@(private = "file")
checkfield :: proc(L: ^kernel.State, key: string, n: int) -> bool {
	kernel.api_pushstring(L, key)
	return kernel.api_rawget(L, -n) != kernel.TNIL
}

// Verify `arg` is a table, or an object that emulates one via the metamethods
// implied by `what` -- reference `checktab`. The `n` bookkeeping mirrors the C
// source: each tested metamethod is left on the stack and counted so the final
// `lua_pop(n)` removes the metatable and every probe. (Odin has no comma
// operator, so the C `++n` folded into the short-circuit chain is spelled out.)
@(private = "file")
checktab :: proc(L: ^kernel.State, arg: int, what: int) {
	tp := kernel.api_type(L, arg)
	if tp != kernel.TTABLE {
		n := 1 // number of elements to pop
		ok := kernel.api_getmetatable(L, arg) // must have a metatable
		if ok && what & TAB_R != 0 {
			n += 1
			ok = checkfield(L, "__index", n)
		}
		if ok && what & TAB_W != 0 {
			n += 1
			ok = checkfield(L, "__newindex", n)
		}
		if ok && what & TAB_L != 0 && tp != kernel.TSTRING {
			n += 1
			ok = checkfield(L, "__len", n)
		}
		if ok {
			kernel.api_pop(L, n) // pop metatable and tested metamethods
		} else {
			aux_checktype(L, arg, kernel.TTABLE) // force a "table expected" error
		}
	}
}

// `aux_getn` -- reference macro: assert the argument is a length-capable table
// and return its border length.
@(private = "file")
aux_getn :: proc(L: ^kernel.State, n: int, w: int) -> kernel.Integer {
	checktab(L, n, w | TAB_L)
	return aux_len(L, n)
}

// --------------------------------------------------------------------------------
// create / insert / remove / move / concat
// --------------------------------------------------------------------------------

// `table.create(nseq [, nrest])` -- preallocate a table with room for `nseq`
// sequence slots and `nrest` other slots. Reference `tcreate`.
table_create :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	sizeseq := kernel.Unsigned(aux_checkinteger(L, 1))
	sizerest := kernel.Unsigned(aux_optinteger(L, 2, 0))
	aux_argcheck(L, sizeseq <= kernel.Unsigned(max(i32)), 1, "out of range")
	aux_argcheck(L, sizerest <= kernel.Unsigned(max(i32)), 2, "out of range")
	kernel.api_createtable(L, int(sizeseq), int(sizerest))
	return 1
}

// `table.insert(t, [pos,] v)` -- reference `tinsert`.
table_insert :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	e := aux_getn(L, 1, TAB_RW)
	e = kernel.Integer(kernel.Unsigned(e) + 1) // first empty element (wrapping like luaL_intop)
	pos: kernel.Integer
	switch kernel.api_gettop(L) {
	case 2: // table.insert(t, v): append
		pos = e
	case 3: // table.insert(t, pos, v)
		pos = aux_checkinteger(L, 2)
		// pos must be in [1, e]
		aux_argcheck(L, kernel.Unsigned(pos) - 1 < kernel.Unsigned(e), 2, "position out of bounds")
		for i := e; i > pos; i -= 1 {
			kernel.api_geti(L, 1, i - 1)
			kernel.api_seti(L, 1, i) // t[i] = t[i - 1]
		}
	case:
		aux_error(L, "wrong number of arguments to 'insert'")
	}
	kernel.api_seti(L, 1, pos) // t[pos] = v
	return 0
}

// `table.remove(t [, pos])` -- reference `tremove`.
table_remove :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	size := aux_getn(L, 1, TAB_RW)
	pos := aux_optinteger(L, 2, size)
	if pos != size { // validate an explicit pos: must be in [1, size + 1]
		aux_argcheck(L, kernel.Unsigned(pos) - 1 <= kernel.Unsigned(size), 2, "position out of bounds")
	}
	kernel.api_geti(L, 1, pos) // result = t[pos]
	for ; pos < size; pos += 1 {
		kernel.api_geti(L, 1, pos + 1)
		kernel.api_seti(L, 1, pos) // t[pos] = t[pos + 1]
	}
	kernel.api_pushnil(L)
	kernel.api_seti(L, 1, pos) // t[pos] = nil (erase the vacated slot)
	return 1
}

// `table.move(a1, f, e, t [, a2])` -- copy the range a1[f..e] into a2[t..].
// Reference `tmove`. The direction of the copy is chosen so overlapping ranges
// within a single table never clobber a not-yet-read element.
table_move :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	f := aux_checkinteger(L, 2)
	e := aux_checkinteger(L, 3)
	t := aux_checkinteger(L, 4)
	tt := !kernel.api_isnoneornil(L, 5) ? 5 : 1 // destination table index
	checktab(L, 1, TAB_R)
	checktab(L, tt, TAB_W)
	if e >= f { // otherwise there is nothing to move
		aux_argcheck(L, f > 0 || e < kernel.MAX_INTEGER + f, 3, "too many elements to move")
		n := e - f + 1 // number of elements to move
		aux_argcheck(L, t <= kernel.MAX_INTEGER - n + 1, 4, "destination wrap around")
		if t > e || t <= f || (tt != 1 && !kernel.api_compare(L, 1, tt, kernel.OPEQ)) {
			for i: kernel.Integer = 0; i < n; i += 1 {
				kernel.api_geti(L, 1, f + i)
				kernel.api_seti(L, tt, t + i)
			}
		} else {
			for i := n - 1; i >= 0; i -= 1 {
				kernel.api_geti(L, 1, f + i)
				kernel.api_seti(L, tt, t + i)
			}
		}
	}
	kernel.api_pushvalue(L, tt) // return the destination table
	return 1
}

// Append t[i] to the concat buffer, erroring if it is not string-coercible --
// reference `addfield`.
@(private = "file")
addfield :: proc(L: ^kernel.State, b: ^Buffer, i: kernel.Integer) {
	kernel.api_geti(L, 1, i)
	if !kernel.api_isstring(L, -1) {
		aux_error(
			L,
			"invalid value (%s) at index %I in table for 'concat'",
			aux_typename(L, -1),
			i,
		)
	}
	aux_addvalue(b)
}

// `table.concat(t [, sep [, i [, j]]])` -- reference `tconcat`.
table_concat :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	b: Buffer
	last := aux_getn(L, 1, TAB_R)
	sep := aux_optlstring(L, 2, "")
	i := aux_optinteger(L, 3, 1)
	last = aux_optinteger(L, 4, last)
	aux_buffinit(L, &b)
	for ; i < last; i += 1 {
		addfield(L, &b, i)
		aux_addlstring(&b, transmute([]u8)sep)
	}
	if i == last { // add the last value (when the interval was non-empty)
		addfield(L, &b, i)
	}
	aux_pushresult(&b)
	return 1
}

// --------------------------------------------------------------------------------
// pack / unpack
// --------------------------------------------------------------------------------

// `table.pack(...)` -> a table holding the varargs plus an `n` field with the
// count. Reference `tpack`.
table_pack :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := int(kernel.api_gettop(L)) // number of elements to pack
	kernel.api_createtable(L, n, 1)
	kernel.api_insert(L, 1) // put the result table at index 1
	for i := n; i >= 1; i -= 1 {
		kernel.api_seti(L, 1, kernel.Integer(i))
	}
	kernel.api_pushinteger(L, kernel.Integer(n))
	kernel.api_setfield(L, 1, "n") // t.n = number of elements
	return 1
}

// `table.unpack(t [, i [, j]])` -> the elements t[i], ..., t[j]. Reference
// `tunpack`. Guards against pushing more results than the stack (or an int) can
// hold.
table_unpack :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	size := aux_getn(L, 1, TAB_R)
	i := aux_optinteger(L, 2, 1)
	e := aux_optinteger(L, 3, size)
	if i > e {
		return 0 // empty range
	}
	n := kernel.Unsigned(e) - kernel.Unsigned(i) // number of elements minus 1
	if n >= kernel.Unsigned(max(u32)) || !kernel.api_checkstack(L, int(n + 1)) {
		aux_error(L, "too many results to unpack")
	}
	n += 1
	for ; i < e; i += 1 { // push arg[i..e-1] (last pushed separately to avoid overflow)
		kernel.api_geti(L, 1, i)
	}
	kernel.api_geti(L, 1, e) // push the last element
	return i32(n)
}

// --------------------------------------------------------------------------------
// sort (quicksort with randomized-pivot fallback)
// --------------------------------------------------------------------------------

// Array indices in sort are bounded by INT_MAX, so an unsigned 32-bit index is
// enough -- reference `IdxT`.
@(private = "file")
IdxT :: u32

// Arrays larger than this may switch to randomized pivots -- reference RANLIMIT.
@(private = "file")
RANLIMIT :: 100

@(private = "file")
geti_idx :: #force_inline proc(L: ^kernel.State, idt: int, idx: IdxT) -> int {
	return kernel.api_geti(L, idt, kernel.Integer(idx))
}

@(private = "file")
seti_idx :: #force_inline proc(L: ^kernel.State, idt: int, idx: IdxT) {
	kernel.api_seti(L, idt, kernel.Integer(idx))
}

// Store the top two stack values into t[i] and t[j] -- reference `set2`. The
// values are consumed in the order they sit on the stack (i first, then j).
@(private = "file")
set2 :: proc(L: ^kernel.State, i: IdxT, j: IdxT) {
	seti_idx(L, 1, i)
	seti_idx(L, 1, j)
}

// Is the value at stack index `a` less than the value at `b` under the sort's
// order? Reference `sort_comp`. With no comparator we use the language's `<`;
// with one we call it. The `a-1`/`b-2` offsets compensate for the extra values
// pushed onto the stack during the comparator call.
@(private = "file")
sort_comp :: proc(L: ^kernel.State, a: int, b: int) -> bool {
	if kernel.api_isnil(L, 2) { // no function?
		return kernel.api_compare(L, a, b, kernel.OPLT) // a < b
	}
	kernel.api_pushvalue(L, 2) // push comparator
	kernel.api_pushvalue(L, a - 1) // -1 to compensate for the function
	kernel.api_pushvalue(L, b - 2) // -2 to compensate for the function and 'a'
	kernel.api_call(L, 2, 1)
	res := kernel.api_toboolean(L, -1)
	kernel.api_pop(L, 1)
	return res
}

// Partition around the pivot at the top of the stack -- reference `partition`.
@(private = "file")
partition :: proc(L: ^kernel.State, lo: IdxT, up: IdxT) -> IdxT {
	i := lo // incremented before first use
	j := up - 1 // decremented before first use
	for {
		// repeat ++i while a[i] < P
		i += 1
		geti_idx(L, 1, i)
		for sort_comp(L, -1, -2) {
			if i == up - 1 { // a[up-1] < P == a[up-1]
				aux_error(L, "invalid order function for sorting")
			}
			kernel.api_pop(L, 1) // remove a[i]
			i += 1
			geti_idx(L, 1, i)
		}
		// after the loop, a[i] >= P and a[lo .. i-1] < P
		// repeat --j while P < a[j]
		j -= 1
		geti_idx(L, 1, j)
		for sort_comp(L, -3, -1) {
			if j < i { // j <= i-1 and a[j] > P contradicts the invariant
				aux_error(L, "invalid order function for sorting")
			}
			kernel.api_pop(L, 1) // remove a[j]
			j -= 1
			geti_idx(L, 1, j)
		}
		// after the loop, a[j] <= P and a[j+1 .. up] >= P
		if j < i { // nothing out of place?
			kernel.api_pop(L, 1) // pop a[j]
			set2(L, up - 1, i) // swap pivot (a[up-1]) with a[i]
			return i
		}
		set2(L, i, j) // swap a[i]/a[j] and repeat
	}
}

// Choose a "randomized" pivot in the middle two quarters of [lo, up] -- reference
// `choosePivot`.
@(private = "file")
choosePivot :: proc(lo: IdxT, up: IdxT, rnd: u32) -> IdxT {
	r4 := (up - lo) / 4 // range / 4
	return (rnd ~ lo ~ up) % (r4 * 2) + (lo + r4)
}

// Recursive quicksort with tail-call flattening -- reference `auxsort`.
@(private = "file")
auxsort :: proc(L: ^kernel.State, lo0: IdxT, up0: IdxT, rnd0: u32) {
	lo := lo0
	up := up0
	rnd := rnd0
	for lo < up { // loop for the tail-recursive interval
		// sort elements lo, p, up: first order the endpoints
		geti_idx(L, 1, lo)
		geti_idx(L, 1, up)
		if sort_comp(L, -1, -2) { // a[up] < a[lo]?
			set2(L, lo, up)
		} else {
			kernel.api_pop(L, 2)
		}
		if up - lo == 1 { // only 2 elements: already sorted
			return
		}
		p: IdxT
		if up - lo < RANLIMIT || rnd == 0 { // small interval or no randomization
			p = (lo + up) / 2 // the middle element is a good pivot
		} else {
			p = choosePivot(lo, up, rnd)
		}
		geti_idx(L, 1, p)
		geti_idx(L, 1, lo)
		if sort_comp(L, -2, -1) { // a[p] < a[lo]?
			set2(L, p, lo)
		} else {
			kernel.api_pop(L, 1) // remove a[lo]
			geti_idx(L, 1, up)
			if sort_comp(L, -1, -2) { // a[up] < a[p]?
				set2(L, p, up)
			} else {
				kernel.api_pop(L, 2)
			}
		}
		if up - lo == 2 { // only 3 elements: already sorted
			return
		}
		geti_idx(L, 1, p) // get the middle element (pivot)
		kernel.api_pushvalue(L, -1) // push a copy of the pivot
		geti_idx(L, 1, up - 1) // push a[up-1]
		set2(L, p, up - 1) // swap pivot (a[p]) with a[up-1]
		p = partition(L, lo, up)
		// a[lo .. p-1] <= a[p] == P <= a[p+1 .. up]
		n: IdxT
		if p - lo < up - p { // lower interval smaller?
			auxsort(L, lo, p - 1, rnd) // recurse on the lower interval
			n = p - lo
			lo = p + 1 // tail-loop over the upper interval
		} else {
			auxsort(L, p + 1, up, rnd) // recurse on the upper interval
			n = up - p
			up = p - 1 // tail-loop over the lower interval
		}
		if (up - lo) / 128 > n { // partition too imbalanced?
			rnd = aux_makeseed(L) // draw a fresh randomization
		}
	}
}

// `table.sort(t [, comp])` -- reference `sort`.
table_sort :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := aux_getn(L, 1, TAB_RW)
	if n > 1 { // non-trivial interval?
		aux_argcheck(L, n < kernel.Integer(max(i32)), 1, "array too big")
		if !kernel.api_isnoneornil(L, 2) { // a comparator was supplied?
			aux_checktype(L, 2, kernel.TFUNCTION)
		}
		kernel.api_settop(L, 2) // ensure exactly two arguments (t, comp)
		auxsort(L, 1, IdxT(n), 0)
	}
	return 0
}

// --------------------------------------------------------------------------------
// Library table and opener
// --------------------------------------------------------------------------------

@(private = "file")
tab_funcs := []Reg {
	{"concat", table_concat},
	{"create", table_create},
	{"insert", table_insert},
	{"pack", table_pack},
	{"unpack", table_unpack},
	{"remove", table_remove},
	{"move", table_move},
	{"sort", table_sort},
}

// `luaopen_table` -- build and return the table library.
open_table :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_newlib(L, tab_funcs)
	return 1
}
