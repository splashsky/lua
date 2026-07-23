package lua

// parse.odin -- our analogue of reference Lua's `lparser.h` / `lparser.c`.
//
// The parser, which in Lua is also the front half of the code generator: it's a
// single-pass recursive-descent parser that emits bytecode as it goes rather
// than building a separate AST. It tracks local variables, scopes, upvalue
// capture, and control-flow structure, handing the low-level instruction
// emission off to `code`.
//
// Because it's single-pass, the interplay between parsing and `code`'s
// backpatching/register allocation is intricate -- and it's where the shape of
// our `Proto` output must line up with reference Lua for bytecode compatibility.
//
// TODO(phase-4): the recursive-descent grammar, scope/local/upvalue management,
// and Proto construction driving `code`.

// ---------------------------------------------------------------------------
// Placeholder parser types
// ---------------------------------------------------------------------------
//
// The lexer's `LexState` carries pointers to these two parser-owned structures
// (reference Lua shares one `LexState` across the scanner and parser). The parser
// row will flesh them out into the full `Dyndata` (active locals, pending gotos,
// labels) and `FuncState` (per-function code-generation state) from `lparser.h`.
// For now they exist only so `LexState`'s pointer fields typecheck; the lexer
// never dereferences either one.
Dyndata :: struct {}

FuncState :: struct {}
