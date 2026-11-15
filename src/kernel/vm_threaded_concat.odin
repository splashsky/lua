package kernel

import "base:runtime"
import "core:mem"

// Threaded CONCAT's common all-coercible run. This deliberately mirrors the
// string creation, GC-object linking and debt accounting in string.odin,
// gc.odin and mem.odin; the generator guards those source routines for review.
// The switch VM and the public concatenation API keep their ordinary helpers.
when VM_THREADED {
	// Restore the activation's context for every operation that can run Lua,
	// collect, resize the intern table, or raise. These wrappers must not defer
	// cleanup across a possible longjmp.
	vm_thread_concat_retry :: #force_no_inline proc "contextless" (L: ^State, tag, size: uint, ctx: ^runtime.Context) -> rawptr {
		context = ctx^
		return state_tryagain(L, nil, tag, size)
	}

	vm_thread_concat_resize :: #force_no_inline proc "contextless" (L: ^State, size: int, ctx: ^runtime.Context) {
		context = ctx^
		string_resize(L, size)
	}

	vm_thread_concat_memerror :: #force_no_inline proc "contextless" (L: ^State, ctx: ^runtime.Context) {
		context = ctx^
		throw(L, .Err_Mem)
	}

	vm_thread_concat_overflow :: #force_no_inline proc "contextless" (L: ^State, ctx: ^runtime.Context) {
		context = ctx^
		debug_runerror(L, "string length overflow")
	}

	vm_thread_concat_gc :: #force_no_inline proc "contextless" (L: ^State, ctx: ^runtime.Context) {
		context = ctx^
		gc_step(L)
	}

	vm_thread_concat_meta :: #force_no_inline proc "contextless" (L: ^State, ctx: ^runtime.Context) {
		context = ctx^
		tm_tryconcatTM(L)
	}

	vm_thread_concat_newobj :: proc "contextless" (L: ^State, len: uint, tag: Byte, hash: u32, ctx: ^runtime.Context) -> ^TString {
		g := L.g
		size := sizelstring(len)
		typ := uint(no_variant(tag))
		// Fresh string allocations are nonzero and the allocator callback has a
		// C ABI. This is raw_realloc's normal path; on failure state_tryagain
		// performs the same emergency collection and single retry as before.
		p := g.alloc.alloc(g.alloc.ud, nil, typ, size)
		if p == nil {
			p = vm_thread_concat_retry(L, typ, size, ctx)
			if p == nil do return nil
		}
		g.gc_debt -= L_Mem(size)
		o := (^GCObject)(p)
		o.marked = gc_white(g)
		o.tt = tag
		o.next = g.allgc
		g.allgc = o
		ts := (^TString)(o)
		ts.hash = hash
		ts.extra = 0
		ts.len = len
		ts.hnext = nil
		str_bytes(ts)[len] = 0
		return ts
	}

	vm_thread_concat_intern :: proc "contextless" (L: ^State, bytes: [^]u8, len: uint, ctx: ^runtime.Context) -> ^TString {
		g := L.g
		tb := &g.strt
		h := string_hash(bytes, len, g.seed)
		list := &tb.hash[str_mod(h, tb.size)]
		for ts := list^; ts != nil; ts = ts.hnext {
			if len == ts.len && mem_eq(bytes, str_bytes(ts), len) {
				if is_dead(g, obj2gco(ts)) do change_white(obj2gco(ts))
				return ts
			}
		}
		if tb.nuse >= tb.size {
			if tb.size <= MAXSTRTB / 2 do vm_thread_concat_resize(L, tb.size * 2, ctx)
			list = &tb.hash[str_mod(h, tb.size)]
		}
		ts := vm_thread_concat_newobj(L, len, VSHRSTR, h, ctx)
		if ts == nil do return nil
		mem.copy(str_bytes(ts), bytes, int(len))
		ts.hnext = list^
		list^ = ts
		tb.nuse += 1
		return ts
	}

	vm_thread_concat_number :: proc "contextless" (L: ^State, idx: int, ctx: ^runtime.Context) {
		buf: [N2S_BUFF_SZ]u8
		n := number_to_str(stack_value(L, idx), buf[:])
		ts: ^TString
		if n <= MAXSHORTLEN {
			ts = vm_thread_concat_intern(L, raw_data(buf[:]), uint(n), ctx)
		} else {
			ts = vm_thread_concat_newobj(L, uint(n), VLNGSTR, L.g.seed, ctx)
			if ts != nil do mem.copy(str_bytes(ts), raw_data(buf[:]), n)
		}
		if ts == nil do vm_thread_concat_memerror(L, ctx)
		// An emergency retry can move the value stack. Resolve this slot again.
		set_string(stack_value(L, idx), ts)
	}

	// Like vm_concat, fold right-to-left, anchoring each converted number
	// before the next allocation. Non-coercible pairs and empty operands keep
	// the same order and top changes, including across a yielding metamethod.
	vm_thread_concat_run :: #force_no_inline proc "contextless" (L: ^State, total_in: int, ctx: ^runtime.Context) {
		total := total_in
		if total == 1 do return
		for {
			top := L.top
			n := 2
			left := stack_value(L, top - 2)
			right := stack_value(L, top - 1)
			if !(is_string(left) || is_number(left)) || !(is_string(right) || is_number(right)) {
				vm_thread_concat_meta(L, ctx)
			} else {
				if is_number(right) do vm_thread_concat_number(L, top - 1, ctx)
				left = stack_value(L, top - 2)
				right = stack_value(L, top - 1)
				if type_tag(right) == VSHRSTR && str_value(right).len == 0 {
					if is_number(left) do vm_thread_concat_number(L, top - 2, ctx)
				} else if type_tag(left) == VSHRSTR && str_value(left).len == 0 {
					set_obj(left, right)
				} else {
					total_len := uint(str_value(right).len)
					n = 1
					for n < total {
						idx := top - n - 1
						o := stack_value(L, idx)
						if !(is_string(o) || is_number(o)) do break
						if is_number(o) do vm_thread_concat_number(L, idx, ctx)
						len := uint(str_value(stack_value(L, idx)).len)
						if len >= MAX_SIZE - size_of(TString) - total_len {
							L.top = top - total
							vm_thread_concat_overflow(L, ctx)
						}
						total_len += len
						n += 1
					}
					ts: ^TString
					if total_len <= MAXSHORTLEN {
						buf: [MAXSHORTLEN]u8
						pos: uint
						for j := n; j > 0; j -= 1 {
							s := str_value(stack_value(L, top - j))
							if s.len != 0 do mem.copy(&buf[pos], str_bytes(s), int(s.len))
							pos += s.len
						}
						ts = vm_thread_concat_intern(L, raw_data(buf[:]), total_len, ctx)
					} else {
						ts = vm_thread_concat_newobj(L, total_len, VLNGSTR, L.g.seed, ctx)
						if ts == nil do vm_thread_concat_memerror(L, ctx)
						pos: uint
						for j := n; j > 0; j -= 1 {
							s := str_value(stack_value(L, top - j))
							if s.len != 0 do mem.copy(&str_bytes(ts)[pos], str_bytes(s), int(s.len))
							pos += s.len
						}
					}
					if ts == nil do vm_thread_concat_memerror(L, ctx)
					set_string(stack_value(L, top - n), ts)
				}
			}
			total -= n - 1
			L.top -= n - 1
			if total <= 1 do break
		}
	}
}
