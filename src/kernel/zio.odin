package kernel
// zio.odin -- our analogue of reference Lua's `lzio.h` / `lzio.c`.
//
// A minimal buffered input stream. Both the lexer (reading source text) and the
// undumper (reading bytecode) pull their input through this one abstraction, so
// they don't care whether bytes come from a file, a string, or a custom reader.
// It also carries the growable `Mbuffer` scratch buffer the lexer accumulates
// tokens into.

import "core:mem"

// End-of-stream marker returned by `zio_getc` / `zio_fill`. Reference Lua's `EOZ`
// is `-1`; we keep it as an `int` so it never collides with a real byte value
// (0..255), exactly like reference's `zgetc` returning an int.
EOZ :: -1

// The reader callback an embedder supplies to feed bytes into a stream. It mirrors
// reference Lua's `lua_Reader`: each call hands back a pointer to a fresh block of
// input and writes its length through `size`. Returning a zero length (or nil)
// signals end of input. The block must stay valid until the next reader call.
// The calling convention is C because embedders written in C provide these.
Reader :: #type proc "c" (L: ^State, data: rawptr, size: ^uint) -> [^]u8

// `Zio` is one buffered input stream -- reference Lua's `struct Zio`. It remembers
// how many bytes remain in the current block (`n`), where we are within it (`p`),
// and the reader that refills it when the block runs dry. `L` rides along because
// the reader is called with it.
//
// A note on the index-vs-pointer rule: `p` here is a raw pointer into the reader's
// *own* buffer, not into anything Lua owns or moves, so retaining it is safe. This
// is input the embedder is streaming to us; the GC never touches it.
Zio :: struct {
	n:      uint, // bytes still unread in the current block
	p:      [^]u8, // current position within that block
	reader: Reader, // supplies the next block on demand
	data:   rawptr, // opaque state handed back to the reader
	L:      ^State, // owning thread (passed to the reader)
}

// Prepare a stream to read through `reader`/`data`. It starts empty (`n == 0`), so
// the very first byte request triggers a fill. Reference Lua's `luaZ_init`.
zio_init :: proc(L: ^State, z: ^Zio, reader: Reader, data: rawptr) {
	z.L = L
	z.reader = reader
	z.data = data
	z.n = 0
	z.p = nil
}

// Refill an exhausted stream and return its next byte, or `EOZ` at end of input --
// reference Lua's `luaZ_fill`. We ask the reader for another block; a nil/empty
// block means the stream is done. On success we consume the first byte of the new
// block right here (leaving `n`/`p` pointing at the remainder), because the only
// caller, `zio_getc`, calls us precisely when it needs that byte.
zio_fill :: proc(z: ^Zio) -> int {
	size: uint
	buff := z.reader(z.L, z.data, &size)
	if buff == nil || size == 0 {
		return EOZ
	}
	z.n = size - 1 // one byte is about to be consumed below
	z.p = buff[1:] // advance past that first byte
	return int(buff[0])
}

// Return the next byte of the stream as an int in 0..255, or `EOZ`. Mirrors
// reference Lua's `zgetc` macro: serve from the current block if it has bytes
// left, otherwise fall through to a refill.
zio_getc :: proc(z: ^Zio) -> int {
	if z.n > 0 {
		z.n -= 1
		c := int(z.p[0])
		z.p = z.p[1:]
		return c
	}
	return zio_fill(z)
}

// Read up to `count` bytes into `dest`, returning how many bytes could NOT be read
// (i.e. 0 on a full read, or the shortfall if the stream ended early) -- reference
// Lua's `luaZ_read`. It drains whatever is buffered, refilling as needed, exactly
// like the reference loop; the undumper leans on the "bytes still missing" return
// to detect a truncated chunk.
zio_read :: proc(z: ^Zio, dest: rawptr, count: uint) -> uint {
	remaining := count
	out := ([^]u8)(dest)
	for remaining > 0 {
		if z.n == 0 { 	// current block drained?
			// Peek one byte to force a refill, then push it back logically by
			// re-widening the block. This matches reference Lua, which calls
			// 'luaZ_fill' and then steps 'p' back by one so the byte it consumed
			// is included in the copy below.
			if zio_fill(z) == EOZ {
				return remaining // stream ended short
			}
			z.n += 1
			z.p = z.p[-1:]
		}
		m := remaining if remaining <= z.n else z.n
		mem.copy(&out[count - remaining], z.p, int(m))
		z.n -= m
		z.p = z.p[m:]
		remaining -= m
	}
	return 0
}

// ---------------------------------------------------------------------------
// Mbuffer -- the lexer's growable scratch buffer
// ---------------------------------------------------------------------------

// `Mbuffer` is a resizable byte buffer the lexer accumulates a token's characters
// into before interning it -- reference Lua's `Mbuffer`. `buffer` is the backing
// allocation, `buffsize` its capacity, and `n` how much is currently in use. It is
// owned by the kernel, so it grows through the state-aware allocator to keep the
// GC's byte accounting honest.
Mbuffer :: struct {
	buffer:   [^]u8,
	n:        uint, // bytes currently in use
	buffsize: uint, // allocated capacity
}

// Start an Mbuffer empty (no allocation yet). Reference `luaZ_initbuffer`.
mbuffer_init :: proc "contextless" (b: ^Mbuffer) {
	b.buffer = nil
	b.n = 0
	b.buffsize = 0
}

// Resize the buffer to exactly `size` bytes, routing through the state allocator.
// A size of zero frees it. Reference `luaZ_resizebuffer`.
mbuffer_resize :: proc(L: ^State, b: ^Mbuffer, size: uint) {
	newblock := state_realloc(L, b.buffer, b.buffsize, size)
	if newblock == nil && size > 0 {
		// Out of memory while growing the token buffer: raise through the active
		// protected boundary rather than truncating silently.
		throw(L, .Err_Mem)
		return
	}
	b.buffer = ([^]u8)(newblock)
	b.buffsize = size
}

// Release the buffer's memory. Reference `luaZ_freebuffer`.
mbuffer_free :: proc(L: ^State, b: ^Mbuffer) {
	mbuffer_resize(L, b, 0)
}

// Forget the buffer's contents without freeing it, so it can be reused for the
// next token. Reference `luaZ_resetbuffer`.
mbuffer_reset :: proc "contextless" (b: ^Mbuffer) {
	b.n = 0
}
