#+build !freestanding
#+build !windows

package kernel
// The hosted convenience allocator deliberately lives outside mem.odin. A real
// operating system can supply a process heap, but a freestanding machine cannot:
// there may not even be RAM discovery or an address-space policy yet. Keeping
// this declaration out of freestanding builds makes accidental use fail at
// compile time and leaves new_state(Allocator{...}) as the only honest path.

import "base:runtime"

// Like reference Lua's `l_alloc`, use the C heap directly. On Linux, Darwin and
// the BSDs Odin's contextless heap_resize/heap_free call realloc/free. Blocks
// from this callback must go back through this callback, never through an Odin
// allocator, whose blocks have different alignment bookkeeping. Realloc does
// not zero new bytes; on failure it returns nil and leaves the old block intact.
// state_realloc handles the emergency-GC retry.
//
// On 64-bit glibc, musl and macOS the C heap provides 16-byte alignment. BSD
// heaps may align tiny blocks less: FreeBSD's jemalloc can return an 8-aligned
// block for a request of at most 8 bytes. Kernel allocation types need at most
// 8-byte alignment. On 32-bit heaps the usual minimum is 8 bytes, but the kernel
// currently asserts 64-bit layouts and does not claim 32-bit support. Windows
// uses its own process heap.
default_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize: uint, nsize: uint) -> rawptr {
	if nsize == 0 {
		if ptr != nil {
			runtime.heap_free(ptr)
		}
		return nil
	}
	// Retain the old adapter's signed-size guards. For a fresh allocation osize
	// is a type tag, not a byte count, and must not be interpreted as a size.
	if nsize > uint(max(int)) || (ptr != nil && osize > uint(max(int))) {
		return nil
	}
	return runtime.heap_resize(ptr, int(nsize))
}

// A ready-made allocator for hosted programs. Freestanding embedders must pass
// their own callback and userdata directly to new_state instead.
default_allocator :: proc "contextless" () -> Allocator {
	return Allocator{alloc = default_alloc, ud = nil}
}
