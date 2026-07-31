#+build windows

package lua

// Windows' process heap is the bottom of Odin's core:os heap allocator too, but
// going through that generic allocator costs us twice on Lua's hottest memory
// path: allocator-interface dispatch, then alignment bookkeeping around every
// block. Before this path was made mechanical through core:mem, allocating
// 2,000,000 empty tables reached 8,658,009 tables/s; afterward it reached only
// 5,830,904 tables/s. Calling HeapAlloc/HeapReAlloc/HeapFree here restores the
// same short route as reference Lua's realloc/free without bringing the CRT
// back. The Win32 heap guarantees 16-byte alignment on 64-bit Windows (8 bytes
// on 32-bit), exactly mem.DEFAULT_ALIGNMENT and enough for every Lua object.
//
// This file is Windows-only on purpose. Freestanding builds never see core:os
// or core:sys/windows and continue to use only the allocator supplied by their
// embedder. Other hosted systems retain the portable implementation in
// mem_hosted.odin.

import win32 "core:sys/windows"

@(private = "file")
default_process_heap: win32.HANDLE

// GetProcessHeap always returns the process's one default heap. Cache that
// handle during package initialization rather than asking Windows for it on
// every tiny Lua allocation. This also means the C-ABI callback below is truly
// contextless: it neither constructs runtime.default_context() nor copies a
// whole context merely to reach memory that the OS already exposes directly.
@(init)
init_default_process_heap :: proc "contextless" () {
	default_process_heap = win32.GetProcessHeap()
}

// The faithful twin of reference Lua's `l_alloc` (lauxlib.c). Failure is
// deliberately just nil: state_realloc performs Lua's emergency-GC retry and
// turns a final failure into LUA_ERRMEM. HeapReAlloc also preserves the original
// block on failure, which is the realloc guarantee Lua relies upon.
default_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize: uint, nsize: uint) -> rawptr {
	if nsize == 0 {
		if ptr != nil {
			_ = win32.HeapFree(default_process_heap, 0, ptr)
		}
		return nil
	}
	// Preserve the old adapter's representability guards exactly, even though
	// Win32 SIZE_T itself is unsigned. In particular, an impossible resize must
	// remain a clean allocation failure rather than reaching platform code.
	if nsize > uint(max(int)) || (ptr != nil && osize > uint(max(int))) {
		return nil
	}
	if ptr == nil {
		return win32.HeapAlloc(default_process_heap, 0, nsize)
	}
	return win32.HeapReAlloc(default_process_heap, 0, ptr, nsize)
}

// A ready-made allocator for hosted programs. Freestanding embedders must pass
// their own callback and userdata directly to lua.new_state instead.
default_allocator :: proc "contextless" () -> Allocator {
	return Allocator{alloc = default_alloc, ud = nil}
}
