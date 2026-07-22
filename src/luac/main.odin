package main

// luac/main.odin -- the standalone `luac` bytecode compiler, our analogue of
// `luac.c`.
//
// `luac` compiles Lua source into a precompiled chunk: it parses to a `Proto`,
// optionally lists the bytecode (`-l`), optionally strips debug info, and dumps
// the result (`-o`). It shares the kernel's compiler and `dump` with the runtime
// -- so byte-for-byte compatibility with reference `luac` output falls out of
// getting `dump` right (see docs/ARCHITECTURE.md, Decision 5).
//
// At this scaffolding stage it just announces itself, proving this second
// `package main` also builds and links against the kernel.

import "core:fmt"
import lua "luao:lua"

main :: proc() {
	fmt.printfln("luac (%s) -- not yet implemented", lua.RELEASE)

	// TODO(phase-10): argument parsing (-l/-o/-s/-p/-- and inputs), compiling
	// each input to a Proto, combining multiple inputs into a main chunk,
	// optional listing, stripping, and dumping via the kernel's `dump`.
}
