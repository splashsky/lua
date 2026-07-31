#+build !freestanding
#+build !windows

package lua

// The hosted convenience allocator deliberately lives outside mem.odin. A real
// operating system can supply a process heap, but a freestanding machine cannot:
// there may not even be RAM discovery or an address-space policy yet. Keeping
// this declaration out of freestanding builds makes accidental use fail at
// compile time and leaves lua.new_state(Allocator{...}) as the only honest path.

import "base:runtime"
import "core:mem"
import "core:os"

// The allocator callback uses the C ABI, so Odin does not hand it a caller
// context. We used to solve that by rebuilding runtime.default_context() for
// every allocation. That is a surprisingly large structure (allocator,
// temporary allocator, logger, assertion handler, random generator, and user
// pointers), and this callback sits under every table, closure, and string.
// The change that introduced that work dropped the 2,000,000-empty-table test
// from 8,658,009 tables/s to 5,830,904 tables/s. Build the ordinary hosted
// context once instead. Non-Windows hosts still need it to call Odin's portable
// heap adapter; Windows has a separate file that skips the adapter altogether.
@(private = "file")
default_alloc_context: runtime.Context

@(init)
init_default_alloc_context :: proc "contextless" () {
	default_alloc_context = runtime.default_context()
}

// The faithful twin of reference Lua's `l_alloc` (lauxlib.c), backed by Odin's
// platform heap rather than the C heap. The non-zeroing resize matches C
// realloc. Keep this portable fallback for hosted systems whose native heap API
// is not wrapped here directly; the hot Windows implementation lives beside it.
default_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize: uint, nsize: uint) -> rawptr {
	context = default_alloc_context
	if nsize == 0 {
		if ptr != nil {
			_ = mem.free(ptr, os.heap_allocator())
		}
		return nil
	}
	if nsize > uint(max(int)) || (ptr != nil && osize > uint(max(int))) {
		return nil
	}
	old_size := ptr == nil ? 0 : int(osize)
	resized, err := mem.resize_non_zeroed(
		ptr,
		old_size,
		int(nsize),
		mem.DEFAULT_ALIGNMENT,
		os.heap_allocator(),
	)
	if err != nil {
		return nil
	}
	return resized
}

// A ready-made allocator for hosted programs. Freestanding embedders must pass
// their own callback and userdata directly to lua.new_state instead.
default_allocator :: proc "contextless" () -> Allocator {
	return Allocator{alloc = default_alloc, ud = nil}
}
