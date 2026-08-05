#+build freestanding

package freestanding

// This tiny exported surface gives Odin's object-file backend real roots. With
// no executable entry point, an optimizing build would otherwise prove that the
// whole library is unreachable and emit an almost-empty object. These are also
// useful firmware-facing conveniences: construct a state from the embedder's
// allocator, open exactly the freestanding libraries, and close it again.

import "base:runtime"
import kernel "lang:kernel"
import stdlib "lang:stdlib"

@(export)
lang_freestanding_newstate :: proc "c" (
	alloc: kernel.Alloc_Proc,
	ud: rawptr,
) -> ^kernel.State {
	context = runtime.default_context()
	if alloc == nil {
		return nil
	}
	L := kernel.new_state(kernel.Allocator{alloc = alloc, ud = ud})
	if L != nil {
		stdlib.aux_openlibs(L)
	}
	return L
}

@(export)
lang_freestanding_close :: proc "c" (L: ^kernel.State) {
	context = runtime.default_context()
	if L != nil {
		kernel.close_state(L)
	}
}
