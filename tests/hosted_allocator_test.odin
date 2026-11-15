package tests

import "core:testing"
import kernel "lang:kernel"

// Kernel blocks are not Odin-allocator blocks. Test the callback contract
// directly, including a rejected resize that must leave the original intact.
@(test)
hosted_allocator_resize_contract :: proc(t: ^testing.T) {
	a := kernel.default_allocator()
	p := a.alloc(a.ud, nil, max(uint), 64) // osize is a tag for a new block
	testing.expect(t, p != nil)
	if p == nil {
		return
	}
	testing.expect(t, uintptr(p) % 8 == 0)
	data := ([^]u8)(p)
	for i in 0 ..< 64 {
		data[i] = u8(i)
	}

	testing.expect(t, a.alloc(a.ud, p, 64, uint(max(int)) + 1) == nil)
	testing.expect(t, a.alloc(a.ud, p, uint(max(int)) + 1, 128) == nil)
	for i in 0 ..< 64 {
		testing.expect_value(t, data[i], u8(i))
	}

	q := a.alloc(a.ud, p, 64, 128)
	testing.expect(t, q != nil)
	if q == nil {
		a.alloc(a.ud, p, 64, 0)
		return
	}
	testing.expect(t, uintptr(q) % 8 == 0)
	for i in 0 ..< 64 {
		testing.expect_value(t, ([^]u8)(q)[i], u8(i))
	}
	r := a.alloc(a.ud, q, 128, 32)
	testing.expect(t, r != nil)
	if r == nil {
		a.alloc(a.ud, q, 128, 0)
		return
	}
	for i in 0 ..< 32 {
		testing.expect_value(t, ([^]u8)(r)[i], u8(i))
	}
	testing.expect(t, a.alloc(a.ud, r, 32, 0) == nil)
	testing.expect(t, a.alloc(a.ud, nil, 0, 0) == nil)
	for n in 1 ..= 32 {
		small := a.alloc(a.ud, nil, 0, uint(n))
		testing.expect(t, small != nil)
		if small != nil {
			testing.expect(t, uintptr(small) % 8 == 0)
			a.alloc(a.ud, small, uint(n), 0)
		}
	}
}

Object_Alloc_Probe :: struct {
	count:    Counting_Allocator,
	failures: int,
	attempts: int,
}

object_alloc_probe :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: uint) -> rawptr {
	p := (^Object_Alloc_Probe)(ud)
	if ptr == nil && osize == uint(kernel.TTABLE) && nsize != 0 {
		p.attempts += 1
		if p.failures > 0 {
			p.failures -= 1
			return nil
		}
	}
	return counting_alloc(&p.count, ptr, osize, nsize)
}

// Fresh object allocation carries a type tag to the embedder, does not account
// for it as bytes, and retries once only when emergency collection is allowed.
@(test)
object_allocator_retry_and_accounting :: proc(t: ^testing.T) {
	probe: Object_Alloc_Probe
	L := kernel.new_state(kernel.Allocator{alloc = object_alloc_probe, ud = &probe})
	testing.expect(t, L != nil)
	if L == nil {
		return
	}
	probe.attempts = 0 // disregard state construction
	before := kernel.gettotalbytes(L.g)
	testing.expect(t, kernel.gc_newobj(L, kernel.VTABLE, 0) == nil)
	testing.expect_value(t, probe.attempts, 0)
	testing.expect_value(t, kernel.gettotalbytes(L.g), before)

	probe.failures = 1
	L.g.gcstopem = 1
	testing.expect(t, kernel.gc_newobj(L, kernel.VTABLE, size_of(kernel.Table)) == nil)
	testing.expect_value(t, probe.attempts, 1)
	testing.expect_value(t, kernel.gettotalbytes(L.g), before)
	L.g.gcstopem = 0

	probe.attempts = 0
	probe.failures = 1
	p := kernel.gc_newobj(L, kernel.VTABLE, size_of(kernel.Table))
	testing.expect(t, p != nil)
	testing.expect_value(t, probe.attempts, 2)
	testing.expect_value(t, kernel.gettotalbytes(L.g), kernel.L_Mem(probe.count.outstanding))
	if p != nil {
		// This test only exercises the header, so unlink it before any GC can
		// interpret the deliberately uninitialized table body.
		L.g.allgc = p.next
		kernel.state_free(L, p, size_of(kernel.Table))
	}
	kernel.close_state(L)
	testing.expect_value(t, probe.count.outstanding, 0)
}

Resize_Alloc_Probe :: struct {
	count:    Counting_Allocator,
	target:   rawptr,
	failures: int,
	attempts: int,
}

resize_alloc_probe :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: uint) -> rawptr {
	p := (^Resize_Alloc_Probe)(ud)
	if ptr != nil && ptr == p.target && nsize != 0 {
		p.attempts += 1
		if p.failures > 0 {
			p.failures -= 1
			return nil
		}
	}
	return counting_alloc(&p.count, ptr, osize, nsize)
}

@(test)
state_resize_retry_preserves_original :: proc(t: ^testing.T) {
	probe: Resize_Alloc_Probe
	L := kernel.new_state(kernel.Allocator{alloc = resize_alloc_probe, ud = &probe})
	testing.expect(t, L != nil)
	if L == nil {
		return
	}
	p := kernel.state_realloc(L, nil, 0, 64)
	testing.expect(t, p != nil)
	if p == nil {
		kernel.close_state(L)
		return
	}
	for i in 0 ..< 64 {
		([^]u8)(p)[i] = u8(i)
	}
	probe.target = p
	probe.failures = 1
	L.g.gcstopem = 1
	before := kernel.gettotalbytes(L.g)
	testing.expect(t, kernel.state_realloc(L, p, 64, 128) == nil)
	testing.expect_value(t, probe.attempts, 1)
	testing.expect_value(t, kernel.gettotalbytes(L.g), before)
	for i in 0 ..< 64 {
		testing.expect_value(t, ([^]u8)(p)[i], u8(i))
	}
	L.g.gcstopem = 0
	probe.attempts = 0
	probe.failures = 1
	q := kernel.state_realloc(L, p, 64, 128)
	testing.expect(t, q != nil)
	testing.expect_value(t, probe.attempts, 2)
	if q != nil {
		for i in 0 ..< 64 {
			testing.expect_value(t, ([^]u8)(q)[i], u8(i))
		}
		kernel.state_free(L, q, 128)
	} else {
		kernel.state_free(L, p, 64)
	}
	kernel.close_state(L)
	testing.expect_value(t, probe.count.outstanding, 0)
}
