#+build !freestanding

package lua

// The hosted convenience allocator deliberately lives outside mem.odin. A real
// operating system can supply a process heap, but a freestanding machine cannot:
// there may not even be RAM discovery or an address-space policy yet. Keeping
// this declaration out of freestanding builds makes accidental use fail at
// compile time and leaves lua.new_state(Allocator{...}) as the only honest path.

import "base:runtime"
import "core:mem"
import "core:os"

// The faithful twin of reference Lua's `l_alloc` (lauxlib.c), backed by Odin's
// platform heap rather than the C heap. On Windows core:os uses the Win32 heap,
// so this remains CRT-free. The non-zeroing resize matches C realloc.
default_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize: uint, nsize: uint) -> rawptr {
	context = runtime.default_context()
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
