package tests

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import stream "lang:stream"

@(test)
stream_nested_read_and_flush_paths :: proc(t: ^testing.T) {
	s := stream.tmpfile()
	if !testing.expect(t, s != nil, "open temporary stream") do return
	defer stream.close(s)
	testing.expect(t, stream.write(s, []u8{'1', '2', 'x', '\n'}) == 4)
	buf: [4]u8
	testing.expect(t, stream.read(s, buf[:1]) == 0 && stream.feof(s), "read after write flushes and reaches EOF")
	_, ok := stream.seek(s, 0, .Start)
	testing.expect(t, ok && !stream.feof(s))
	testing.expect(t, stream.getc(s) == '1')
	testing.expect(t, stream.ungetc('X', s) == 'X')
	testing.expect(t, stream.read(s, buf[:]) == 4 && string(buf[:]) == "X2x\n", "bulk read consumes pushback")
	testing.expect(t, stream.read(s, buf[:1]) == 0 && stream.feof(s))
	stream.clearerr(s)
	testing.expect(t, !stream.feof(s) && !stream.ferror(s))
}

@(test)
stream_nested_text_translation_paths :: proc(t: ^testing.T) {
	temp, err := os.create_temp_file("", "lang-text-lock-*")
	if !testing.expect(t, err == nil, "create temporary file") do return
	path := strings.clone(os.name(temp))
	os.close(temp)
	defer delete(path)
	defer os.remove(path)
	s := stream.open(path, "wb")
	if !testing.expect(t, s != nil) do return
	testing.expect(t, stream.write(s, []u8{'a', '\r', '\n', '\r', 'b', 0x1a, 'c'}) == 7)
	reopened := stream.reopen(path, "r", s)
	if !testing.expect(t, reopened != nil, "reopen in text mode") {
		stream.close(s)
		return
	}
	defer stream.close(reopened)
	buf: [8]u8
	n := stream.read(reopened, buf[:])
	when ODIN_OS == .Windows {
		testing.expect(t, n == 4 && string(buf[:n]) == "a\n\rb", "CRLF, lone CR and text EOF")
	} else {
		testing.expect(t, n == 7 && string(buf[:n]) == "a\r\n\rb\x1ac", "untranslated text")
	}
	testing.expect(t, stream.feof(reopened))
	testing.expect(t, stream.write(reopened, []u8{'x'}) == 0 && stream.ferror(reopened))
	stream.clearerr(reopened)
	testing.expect(t, !stream.feof(reopened) && !stream.ferror(reopened))
}

@(test)
stream_single_byte_read_matches_getc :: proc(t: ^testing.T) {
	temp, err := os.create_temp_file("", "lang-byte-read-*")
	if !testing.expect(t, err == nil) do return
	path := strings.clone(os.name(temp))
	os.close(temp)
	defer delete(path)
	defer os.remove(path)
	w := stream.open(path, "wb")
	if !testing.expect(t, w != nil) do return
	testing.expect(t, stream.write(w, []u8{'a', 'b', '\r', '\n', '\r', 'x', 0x1a, 'z'}) == 8)
	testing.expect(t, stream.close(w))
	a := stream.open(path, "r")
	b := stream.open(path, "r")
	if !testing.expect(t, a != nil && b != nil) {
		if a != nil do stream.close(a)
		if b != nil do stream.close(b)
		return
	}
	defer stream.close(a)
	defer stream.close(b)
	// Small buffers force refills and split CRLF on Windows text streams.
	testing.expect(t, stream.setvbuf(a, .Full, 3))
	testing.expect(t, stream.setvbuf(b, .Full, 3))
	byte: [1]u8
	for {
		expected := stream.getc(a)
		n := stream.read(b, byte[:])
		if expected == stream.EOF {
			testing.expect(t, n == 0 && stream.feof(a) && stream.feof(b))
			break
		}
		if !testing.expect(t, n == 1 && i32(byte[0]) == expected) do break
		pa, oka := stream.tell(a)
		pb, okb := stream.tell(b)
		testing.expect(t, oka && okb && pa == pb, "position after reading")
		// Exercise the pushback path between successive ordinary buffered reads.
		testing.expect(t, stream.ungetc('Q', a) == 'Q' && stream.ungetc('Q', b) == 'Q')
		testing.expect(t, stream.getc(a) == 'Q' && stream.read(b, byte[:]) == 1 && byte[0] == 'Q')
		pa, oka = stream.tell(a)
		pb, okb = stream.tell(b)
		testing.expect(t, oka && okb && pa == pb, "position after pushback")
	}
}

@(test)
stream_read_until_matches_getc :: proc(t: ^testing.T) {
	temp, err := os.create_temp_file("", "lang-until-*")
	if !testing.expect(t, err == nil) do return
	path := strings.clone(os.name(temp))
	os.close(temp)
	defer delete(path)
	defer os.remove(path)
	w := stream.open(path, "wb")
	if !testing.expect(t, w != nil) do return
	data := []u8{'a', '\n', '\r', '\n', 'b', '\r', 'c', 0x1a, '\n', 'd'}
	testing.expect(t, stream.write(w, data) == len(data))
	testing.expect(t, stream.close(w))
	modes := []string{"rb", "r"}
	delimiters := []u8{'\n', '\r', 0x1a, 'b', 'z'}
	sizes := []int{1, 2, 7}
	for mode in modes {
		for delimiter in delimiters {
			for size in sizes {
				a, b := stream.open(path, mode), stream.open(path, mode)
				if !testing.expect(t, a != nil && b != nil) {
					if a != nil do stream.close(a)
					if b != nil do stream.close(b)
					return
				}
				testing.expect(t, stream.setvbuf(a, .Full, 5) && stream.setvbuf(b, .Full, 5))
				for {
					actual, expected: [7]u8
					n, found := stream.read_until(a, actual[:size], delimiter)
					count := 0
					want_found := false
					for count < size {
						c := stream.getc(b)
						if c == stream.EOF do break
						expected[count] = u8(c)
						count += 1
						if u8(c) == delimiter {
							want_found = true
							break
						}
					}
					if !testing.expect(t, n == count && found == want_found && string(actual[:n]) == string(expected[:count]), "bulk delimiter matches getc") do break
					pa, oka := stream.tell(a)
					pb, okb := stream.tell(b)
					testing.expect(t, oka && okb && pa == pb && stream.feof(a) == stream.feof(b), "bulk position and EOF match getc")
					if n == 0 do break
					last := i32(expected[count - 1])
					testing.expect(t, stream.ungetc(last, a) == last && stream.ungetc(last, b) == last)
					pa, oka = stream.tell(a)
					pb, okb = stream.tell(b)
					testing.expect(t, oka && okb && pa == pb, "bulk pushback position matches getc")
					testing.expect(t, stream.getc(a) == last && stream.getc(b) == last)
				}
				testing.expect(t, stream.close(a))
				testing.expect(t, stream.close(b))
			}
		}
	}
}

Stream_Flag_Observer :: struct {
	barrier: ^sync.Barrier,
	stream:  ^stream.Stream,
}

@(test)
stream_flags_during_reopen :: proc(t: ^testing.T) {
	when thread.IS_SUPPORTED {
		temp, err := os.create_temp_file("", "lang-flags-*")
		if !testing.expect(t, err == nil) do return
		path := strings.clone(os.name(temp))
		os.close(temp)
		defer delete(path)
		defer os.remove(path)
		s := stream.open(path, "r")
		if !testing.expect(t, s != nil) do return
		defer stream.close(s)

		WORKERS :: 4
		barrier: sync.Barrier
		sync.barrier_init(&barrier, WORKERS + 1)
		observers: [WORKERS]Stream_Flag_Observer
		threads: [WORKERS]^thread.Thread
		for i in 0..<WORKERS {
			observers[i] = {&barrier, s}
			threads[i] = thread.create(proc(th: ^thread.Thread) {
				observer := (^Stream_Flag_Observer)(th.data)
				sync.barrier_wait(observer.barrier)
				for _ in 0..<100000 {
					_ = stream.feof(observer.stream)
					_ = stream.ferror(observer.stream)
				}
			})
			threads[i].data = &observers[i]
		}
		for th in threads do thread.start(th)
		sync.barrier_wait(&barrier)
		for _ in 0..<300 {
			if !testing.expect(t, stream.write(s, []u8{'x'}) == 0 && stream.ferror(s)) do break
			if !testing.expect(t, stream.getc(s) == stream.EOF && stream.feof(s)) do break
			stream.clearerr(s)
			if !testing.expect(t, !stream.ferror(s) && !stream.feof(s)) do break
			if !testing.expect(t, stream.reopen(path, "r", s) == s) do break
		}
		for th in threads do thread.destroy(th)
	}
}
