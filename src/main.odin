package main

// main.odin -- the standalone `lua` interpreter, our analogue of `lua.c`.
//
// This is the command-line front end most people mean when they say "lua": it
// parses arguments, runs scripts or `-e` chunks, loads libraries with `-l`, and
// drops into a REPL when asked. All of that arrives in Phase 10, once the kernel
// and standard library exist for it to drive.
//
// For now it's a deliberately tiny but *real* program: it prints the version
// banner. Its actual job at this stage is to prove the scaffolding hangs
// together -- that `package main` here can import and link against the kernel
// package (`luao:lua`) through our build collection.

import "core:fmt"
import lua "luao:lua"

main :: proc() {
	// Reference Lua's banner is exactly its LUA_COPYRIGHT string. We pull it
	// from the kernel's single source of version truth so the CLI, the
	// `_VERSION` global, and the bytecode header can never disagree.
	fmt.println(lua.COPYRIGHT)

	// TODO(phase-10): argument parsing (-e/-l/-i/-v/-- and script + args),
	// chunk loading and protected execution, and the interactive REPL.
}
