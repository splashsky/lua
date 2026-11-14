#+build linux

package tests

import "core:os"
import "core:testing"
import linux "core:sys/linux"
import stream "lang:stream"

@(test)
stream_failed_flush_paths :: proc(t: ^testing.T) {
	if !os.exists("/dev/full") || !os.exists("/dev/null") {
		return
	}
	s := stream.open("/dev/full", "w")
	if !testing.expect(t, s != nil, "open /dev/full") {
		return
	}
	testing.expect(t, stream.write(s, []u8{'a', 'b'}) == 2)
	testing.expect(t, !stream.flush(s), "buffered flush fails")
	testing.expect(t, stream.ferror(s), "flush sets the persistent stream error")
	code, ok := os.is_platform_error(stream.last_error())
	testing.expect(t, ok && code == 28, "flush preserves ENOSPC")
	testing.expect(t, stream.write(s, []u8{'c'}) == 1, "ferror does not prevent buffering")
	testing.expect(t, !stream.flush(s))
	testing.expect(t, stream.flush(s), "failed flush discarded its bytes")
	testing.expect(t, stream.ferror(s), "successful flush does not clear ferror")
	stream.clearerr(s)
	testing.expect(t, !stream.ferror(s), "clearerr clears ferror")
	testing.expect(t, stream.close(s), "close has no stale bytes to retry")

	s = stream.open("/dev/full", "w")
	if !testing.expect(t, s != nil) {
		return
	}
	testing.expect(t, stream.setvbuf(s, .Full, 4))
	testing.expect(t, stream.write(s, []u8{'1', '2', '3', '4'}) == 4)
	testing.expect(t, stream.write(s, []u8{'5'}) == 0, "overflow exposes failed flush")
	testing.expect(t, stream.ferror(s))
	testing.expect(t, stream.write(s, []u8{'6'}) == 1, "overflow discarded old buffer")
	testing.expect(t, !stream.flush(s))
	testing.expect(t, stream.close(s))

	s = stream.open("/dev/full", "w")
	if !testing.expect(t, s != nil) {
		return
	}
	testing.expect(t, stream.write(s, []u8{'x'}) == 1)
	_, seek_ok := stream.seek(s, 0, .Start)
	testing.expect(t, !seek_ok && stream.ferror(s), "seek exposes failed flush")
	testing.expect(t, stream.close(s), "seek discarded failed buffer")

	s = stream.open("/dev/full", "w")
	if !testing.expect(t, s != nil) {
		return
	}
	testing.expect(t, stream.write(s, []u8{'x'}) == 1)
	testing.expect(t, !stream.setvbuf(s, .Full, 8), "setvbuf exposes failed flush")
	code, ok = os.is_platform_error(stream.last_error())
	testing.expect(t, ok && code == 28, "setvbuf preserves the flush error")
	testing.expect(t, stream.close(s), "setvbuf discarded failed buffer")

	s = stream.open("/dev/full", "w")
	if !testing.expect(t, s != nil) {
		return
	}
	testing.expect(t, stream.write(s, []u8{'x'}) == 1)
	testing.expect(t, !stream.close(s), "close reports a new flush failure")

	s = stream.open("/dev/full", "w")
	if !testing.expect(t, s != nil) {
		return
	}
	testing.expect(t, stream.write(s, []u8{'x'}) == 1)
	reopened := stream.reopen("/dev/null", "w", s)
	testing.expect(t, reopened == s, "reopen replaces the association after a flush error")
	if reopened != nil {
		testing.expect(t, !stream.ferror(s), "reopen resets the error indicator")
		testing.expect(t, stream.write(s, []u8{'y'}) == 1)
		testing.expect(t, stream.close(s))
	} else {
		stream.close(s)
	}
}

@(test)
stream_partial_flush_discards_whole_buffer :: proc(t: ^testing.T) {
	// A nonblocking pipe accepts a partial write and then returns EAGAIN. After
	// draining its accepted prefix, a second flush must not resend the tail.
	fds: [2]linux.Fd
	err := linux.pipe2(&fds, {.NONBLOCK})
	if !testing.expect(t, err == .NONE, "create nonblocking pipe") {
		return
	}
	reader := os.new_file(uintptr(fds[0]), "pipe-reader")
	writer := os.new_file(uintptr(fds[1]), "pipe-writer")
	if reader == nil || writer == nil {
		testing.expect(t, false, "wrap pipe descriptors")
		if reader != nil {
			os.close(reader)
		} else {
			_ = linux.close(fds[0])
		}
		if writer != nil {
			os.close(writer)
		} else {
			_ = linux.close(fds[1])
		}
		return
	}
	defer os.close(reader)
	capacity, cap_err := linux.fcntl_getpipe_sz(fds[1], linux.F_GETPIPE_SZ)
	if !testing.expect(t, cap_err == .NONE && capacity > 0, "get pipe capacity") {
		os.close(writer)
		return
	}
	s := stream.from_file(writer, true, false, true, false)
	if !testing.expect(t, s != nil, "wrap pipe writer") {
		return
	}
	defer stream.close(s)
	data := make([]u8, int(capacity)*2)
	defer delete(data)
	for &b in data {
		b = 'x'
	}
	testing.expect(t, stream.setvbuf(s, .Full, len(data)))
	testing.expect(t, stream.write(s, data) == len(data))
	testing.expect(t, !stream.flush(s), "partial write then EAGAIN fails flush")
	testing.expect(t, stream.ferror(s))
	n, read_err := os.read(reader, data[:int(capacity)])
	if !testing.expect(t, read_err == nil && n == int(capacity), "read the accepted prefix") {
		return
	}
	testing.expect(t, stream.flush(s), "unwritten tail was discarded")
	testing.expect(t, stream.write(s, []u8{'z'}) == 1 && stream.flush(s))
	n, read_err = os.read(reader, data[:int(capacity)])
	testing.expect(t, read_err == nil && n == 1 && data[0] == 'z', "only new data reaches the pipe")
}
