package lua

// zio.odin -- our analogue of reference Lua's `lzio.h` / `lzio.c`.
//
// A minimal buffered input stream. Both the lexer (reading source text) and the
// undumper (reading bytecode) pull their input through this one abstraction, so
// they don't care whether bytes come from a file, a string, or a custom reader.
// It also carries the growable `Mbuffer` scratch buffer the lexer accumulates
// tokens into.
//
// TODO(phase-3): the reader abstraction (ZIO), the fill/getc/read operations,
// and the Mbuffer scratch buffer.
