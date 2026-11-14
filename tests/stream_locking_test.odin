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
