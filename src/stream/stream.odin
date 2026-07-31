#+build !freestanding

package stream

// stream.odin is the small stdio replacement shared by the Lua library and the
// two command-line programs.  The OS handle is deliberately the only thing below
// this layer: core:os maps it directly to ReadFile/WriteFile on Windows and to the
// platform file syscalls elsewhere, so none of this code needs the C runtime.
//
// Reads use a raw-byte buffer.  Keeping that buffer raw, rather than buffering
// already translated characters, is important in Windows text mode: one logical
// '\n' can consume two raw bytes.  `logical_pos` is therefore an stdio-style
// cookie (a raw file offset), while `raw_cursor` follows bytes consumed from the
// raw buffer.  This makes ftell and seek correct even though the OS handle itself
// may be several kilobytes ahead because of read-ahead.
//
// One byte of logical pushback is guaranteed.  Lua only ever pushes back its
// single look-ahead character (`read_number`, `test_eof`, and the loader), which
// is also the minimum guarantee made by C's ungetc.

import "base:runtime"
import "core:bytes"
import "core:io"
import "core:os"
import "core:strings"

EOF :: -1
DEFAULT_BUFFER_SIZE :: 8192

Buffer_Mode :: enum {
	Unbuffered,
	Full,
	Line,
}

Seek_From :: enum {
	Start,
	Current,
	End,
}

Direction :: enum {
	None,
	Read,
	Write,
}

Stream :: struct {
	file:              ^os.File,
	owns_file:         bool,
	readable:          bool,
	writable:          bool,
	append_mode:       bool,
	text_mode:         bool,
	mode:              Buffer_Mode,
	buffer_size:       int,
	read_buffer:       []u8,
	read_index:        int,
	read_count:        int,
	write_buffer:      []u8,
	write_count:       int,
	raw_cursor:        i64,
	logical_pos:       i64,
	direction:         Direction,
	eof_flag:          bool,
	error_flag:        bool,
	text_eof:          bool,
	raw_saved:         bool,
	raw_saved_byte:    u8,
	raw_saved_before:  i64,
	raw_saved_after:   i64,
	pushback:          bool,
	pushback_byte:     u8,
	pushback_after:    i64,
	last_before:       i64,
	last_after:        i64,
	temp_path:         string,
	next:              ^Stream,
}

@(private = "file")
stream_head: ^Stream
@(private = "file")
last_os_error: os.Error
@(private = "file")
standard_input: ^Stream
@(private = "file")
standard_output: ^Stream
@(private = "file")
standard_error: ^Stream

@(private = "file")
set_error :: proc(err: os.Error) {
	last_os_error = err
}

last_error :: proc() -> os.Error {
	return last_os_error
}

clear_error :: proc() {
	last_os_error = nil
}

@(private = "file")
fail :: proc(s: ^Stream, err: os.Error) -> bool {
	s.error_flag = true
	set_error(err)
	return false
}

@(private = "file")
link_stream :: proc(s: ^Stream) {
	s.next = stream_head
	stream_head = s
}

@(private = "file")
unlink_stream :: proc(s: ^Stream) {
	p := &stream_head
	for p^ != nil {
		if p^ == s {
			p^ = s.next
			return
		}
		p = &p^.next
	}
}

@(private = "file")
resize_buffers :: proc(s: ^Stream, size: int) -> bool {
	actual_size := size
	if actual_size < 1 {
		actual_size = 1
	}
	new_read, err1 := make([]u8, actual_size)
	if err1 != nil {
		set_error(os.Error(err1))
		return false
	}
	new_write, err2 := make([]u8, actual_size)
	if err2 != nil {
		delete(new_read)
		set_error(os.Error(err2))
		return false
	}
	if s.read_buffer != nil {
		delete(s.read_buffer)
	}
	if s.write_buffer != nil {
		delete(s.write_buffer)
	}
	s.read_buffer = new_read
	s.write_buffer = new_write
	s.buffer_size = actual_size
	s.read_index = 0
	s.read_count = 0
	s.write_count = 0
	return true
}

@(private = "file")
make_stream :: proc(f: ^os.File, owns: bool, readable, writable, append_mode, text_mode: bool) -> ^Stream {
	s, alloc_err := new(Stream)
	if alloc_err != nil {
		set_error(os.Error(alloc_err))
		if owns && f != nil {
			os.close(f)
		}
		return nil
	}
	s.file = f
	s.owns_file = owns
	s.readable = readable
	s.writable = writable
	s.append_mode = append_mode
	s.text_mode = text_mode
	s.mode = .Full
	if !resize_buffers(s, DEFAULT_BUFFER_SIZE) {
		if owns {
			os.close(f)
		}
		free(s)
		return nil
	}
	pos, err := os.seek(f, 0, .Current)
	if err != nil {
		// Pipes and terminals are not seekable.  Their cookie starts at zero and
		// still advances consistently as bytes pass through this stream.
		pos = 0
	}
	if append_mode {
		if end, end_err := os.seek(f, 0, .End); end_err == nil {
			pos = end
		}
	}
	s.raw_cursor = pos
	s.logical_pos = pos
	link_stream(s)
	return s
}

// Wrap an already-open OS file in the buffered stream machinery. Process pipes
// are created by the platform layer rather than by `open`, but from this point
// onward they should behave exactly like every other Lua stream.
from_file :: proc(f: ^os.File, owns, readable, writable, text_mode: bool) -> ^Stream {
	if f == nil {
		set_error(os.Error(os.General_Error.Invalid_File))
		return nil
	}
	return make_stream(f, owns, readable, writable, false, text_mode)
}

@(private = "file")
ensure_standard_streams :: proc() {
	if standard_input != nil {
		return
	}
	standard_input = make_stream(os.stdin, false, true, false, false, true)
	standard_output = make_stream(os.stdout, false, false, true, false, true)
	standard_error = make_stream(os.stderr, false, false, true, false, true)
	if standard_output != nil {
		standard_output.mode = os.is_tty(os.stdout) ? .Line : .Full
	}
	if standard_input != nil && os.is_tty(os.stdin) {
		// A terminal has one input owner. The native editor reads console events
		// (Windows) or raw bytes (Linux) directly, while io.read uses this Stream.
		// Keeping terminal stdin unbuffered from its first use prevents an earlier
		// LUA_INIT, -e chunk, or script from reading 8192 bytes ahead and stranding
		// bytes that the later editor could no longer see. We never discard bytes
		// from a non-seekable terminal to switch owners.
		standard_input.mode = .Unbuffered
	}
	if standard_error != nil {
		standard_error.mode = .Unbuffered
	}
}

stdin :: proc() -> ^Stream {
	ensure_standard_streams()
	return standard_input
}

stdout :: proc() -> ^Stream {
	ensure_standard_streams()
	return standard_output
}

stderr :: proc() -> ^Stream {
	ensure_standard_streams()
	return standard_error
}

open :: proc(path, mode: string) -> ^Stream {
	readable, writable, append_mode, text_mode := false, false, false, true
	if len(mode) == 0 {
		set_error(os.Error(os.General_Error.Invalid_Path))
		return nil
	}
	switch mode[0] {
	case 'r':
		readable = true
	case 'w':
		writable = true
	case 'a':
		writable = true
		append_mode = true
	case:
		set_error(os.Error(os.General_Error.Invalid_Path))
		return nil
	}
	for c in mode[1:] {
		if c == '+' {
			readable, writable = true, true
		} else if c == 'b' {
			text_mode = false
		}
	}
	flags: os.File_Flags
	if readable {
		flags += {.Read}
	}
	if writable {
		flags += {.Write}
	}
	switch mode[0] {
	case 'w':
		flags += {.Create, .Trunc}
	case 'a':
		flags += {.Create, .Append}
	}
	f, err := os.open(path, flags, os.Permissions_Default_File)
	if err != nil {
		set_error(err)
		return nil
	}
	return make_stream(f, true, readable, writable, append_mode, text_mode)
}

tmpfile :: proc() -> ^Stream {
	f, err := os.create_temp_file("", "lua-odin-*")
	if err != nil {
		set_error(err)
		return nil
	}
	s := make_stream(f, true, true, true, false, false)
	if s == nil {
		return nil
	}
	path := os.name(f)
	s.temp_path = strings.clone(path)
	return s
}

@(private = "file")
raw_write_all :: proc(s: ^Stream, data: []u8) -> bool {
	done := 0
	for done < len(data) {
		n, err := os.write(s.file, data[done:])
		if n > 0 {
			done += n
		}
		if err != nil {
			return fail(s, err)
		}
		if n == 0 {
			return fail(s, os.Error(io.Error.Short_Write))
		}
	}
	return true
}

@(private = "file")
write_translated :: proc(s: ^Stream, data: []u8) -> bool {
	// The Microsoft CRT's text streams turn every LF into CRLF, even when the LF
	// was already preceded by CR.  Doing the conversion here (rather than asking
	// core:os) is what keeps "w" byte-faithful to reference Lua while "wb" stays
	// completely raw.
	when ODIN_OS == .Windows {
		if s.text_mode {
			// Translating by writing each plain run and then each CRLF separately
			// looks pleasantly simple, but every raw write is a WriteFile syscall.
			// A normal buffered flush can contain hundreds of newlines, so that
			// approach accidentally made one flush perform a syscall per newline.
			//
			// Translate into stack scratch instead.  There is no hot-path heap
			// allocation, and the usual 8 KiB stream buffer expands into one raw
			// write.  Every input byte can be an LF and become two output bytes,
			// so the scratch is deliberately twice DEFAULT_BUFFER_SIZE.  A stream
			// may use a larger setvbuf buffer, therefore fullness is checked by
			// output bytes and the translation is emitted in bounded chunks.
			scratch: [DEFAULT_BUFFER_SIZE * 2]u8
			used := 0
			for c in data {
				needed := c == '\n' ? 2 : 1
				if used + needed > len(scratch) {
					if !raw_write_all(s, scratch[:used]) {
						return false
					}
					used = 0
				}
				if c == '\n' {
					scratch[used] = '\r'
					used += 1
				}
				scratch[used] = c
				used += 1
			}
			if used > 0 {
				return raw_write_all(s, scratch[:used])
			}
			return true
		}
	}
	return raw_write_all(s, data)
}

flush :: proc(s: ^Stream) -> bool {
	if s == nil {
		return false
	}
	if s.write_count > 0 {
		if !write_translated(s, s.write_buffer[:s.write_count]) {
			return false
		}
		s.write_count = 0
	}
	return true
}

flush_all :: proc() -> bool {
	ok := true
	for s := stream_head; s != nil; s = s.next {
		if !flush(s) {
			ok = false
		}
	}
	return ok
}

@(private = "file")
discard_read_ahead :: proc(s: ^Stream) -> bool {
	if s.read_count != 0 || s.raw_saved || s.text_eof {
		if _, err := os.seek(s.file, s.logical_pos, .Start); err != nil {
			return fail(s, err)
		}
	}
	s.read_index = 0
	s.read_count = 0
	s.raw_saved = false
	s.text_eof = false
	s.raw_cursor = s.logical_pos
	return true
}

@(private = "file")
prepare_read :: proc(s: ^Stream) -> bool {
	if !s.readable {
		set_error(os.Error(os.General_Error.Invalid_File))
		s.error_flag = true
		return false
	}
	if s.direction == .Write {
		if !flush(s) {
			return false
		}
		s.raw_cursor = s.logical_pos
	}
	s.direction = .Read
	return true
}

@(private = "file")
prepare_write :: proc(s: ^Stream) -> bool {
	if !s.writable {
		set_error(os.Error(os.General_Error.Invalid_File))
		s.error_flag = true
		return false
	}
	if s.direction == .Read {
		if !discard_read_ahead(s) {
			return false
		}
	}
	s.direction = .Write
	return true
}

@(private = "file")
refill_read_buffer :: proc(s: ^Stream) -> bool {
	if s.read_index >= s.read_count {
		size := s.buffer_size
		if s.mode == .Unbuffered {
			size = 1
		}
		n, err := os.read(s.file, s.read_buffer[:size])
		s.read_index = 0
		s.read_count = n
		if n == 0 {
			// Windows reports ERROR_BROKEN_PIPE when the writing end of an
			// anonymous pipe closes after its final bytes.  For a reader that is
			// precisely ordinary EOF, and the CRT likewise presents it as EOF.
			if err != nil && err != io.Error.EOF && err != os.General_Error.Broken_Pipe {
				fail(s, err)
			}
			return false
		}
	}
	return true
}

@(private = "file")
raw_next :: proc(s: ^Stream) -> (u8, i64, i64, bool) {
	if s.raw_saved {
		s.raw_saved = false
		s.raw_cursor = s.raw_saved_after
		return s.raw_saved_byte, s.raw_saved_before, s.raw_saved_after, true
	}
	if !refill_read_buffer(s) {
		return 0, s.raw_cursor, s.raw_cursor, false
	}
	before := s.raw_cursor
	b := s.read_buffer[s.read_index]
	s.read_index += 1
	s.raw_cursor += 1
	return b, before, s.raw_cursor, true
}

getc :: proc(s: ^Stream) -> i32 {
	if s == nil || !prepare_read(s) {
		return EOF
	}
	if s.pushback {
		s.pushback = false
		s.last_before = s.logical_pos
		s.logical_pos = s.pushback_after
		s.last_after = s.logical_pos
		return i32(s.pushback_byte)
	}
	if s.text_eof {
		s.eof_flag = true
		return EOF
	}
	b, before, after, ok := raw_next(s)
	if !ok {
		s.eof_flag = true
		return EOF
	}
	when ODIN_OS == .Windows {
		if s.text_mode {
			// MSVCRT text input collapses CRLF and treats Ctrl-Z as an end marker.
			// A lone CR remains a CR; the one-byte raw save slot prevents its
			// look-ahead character from being lost.
			if b == 0x1a {
				s.text_eof = true
				s.logical_pos = before
				s.eof_flag = true
				return EOF
			}
			if b == '\r' {
				n, nbefore, nafter, nok := raw_next(s)
				if nok && n == '\n' {
					b = '\n'
					after = nafter
				} else if nok {
					s.raw_saved = true
					s.raw_saved_byte = n
					s.raw_saved_before = nbefore
					s.raw_saved_after = nafter
					s.raw_cursor = nbefore
				}
			}
		}
	}
	s.last_before = before
	s.last_after = after
	s.logical_pos = after
	return i32(b)
}

ungetc :: proc(c: i32, s: ^Stream) -> i32 {
	if s == nil || c == EOF || s.pushback {
		return EOF
	}
	s.pushback = true
	s.pushback_byte = u8(c)
	s.pushback_after = s.last_after
	s.logical_pos = s.last_before
	s.eof_flag = false
	return c
}

// Copy logical input bytes into `dst`, optionally stopping just after a delimiter.
//
// This operation exists because a C `getc` in the reference interpreter is a
// macro that usually advances a pointer inside FILE. Calling an Odin procedure
// for every byte cannot compete with that, especially when a line contains tens
// of bytes between newlines. The ordinary case below scans the current stream
// buffer once and copies the whole run at once; refilling and the comparatively
// rare special characters still go through the stream layer.
//
// There are two details that are easy to get subtly wrong here. First, pushback
// is logical input and must precede even bytes already waiting in the raw buffer,
// so it is always consumed through `getc` before the fast path starts. Second,
// Windows text streams cannot bulk-copy raw data across CR or Ctrl-Z: CRLF is one
// logical newline and Ctrl-Z is logical EOF. The text-mode path scans only as far
// as one of those bytes, then lets `getc` perform the existing translation. A
// lone CR's saved look-ahead byte is handled the same way. Thus the fast path is
// merely batching bytes for which translation is provably a no-op.
@(private = "file")
read_bulk :: proc(s: ^Stream, dst: []u8, stop_at_delimiter: bool, delimiter: u8) -> (n: int, found: bool) {
	if s == nil || !prepare_read(s) {
		return
	}
	for n < len(dst) {
		// `raw_saved` is the look-ahead after a lone CR. Like pushback, it must
		// pass through getc so raw_cursor/logical_pos retain their exact cookies.
		if s.pushback || s.raw_saved {
			c := getc(s)
			if c == EOF {
				return
			}
			dst[n] = u8(c)
			n += 1
			if stop_at_delimiter && u8(c) == delimiter {
				found = true
				return
			}
			continue
		}
		if s.text_eof {
			s.eof_flag = true
			return
		}
		if !refill_read_buffer(s) {
			s.eof_flag = true
			return
		}

		available := min(s.read_count - s.read_index, len(dst) - n)
		take := available
		special := false
		span := s.read_buffer[s.read_index:s.read_index + available]
		if stop_at_delimiter {
			if i := bytes.index_byte(span, delimiter); i >= 0 {
				take = i
				special = true
			}
		}
		when ODIN_OS == .Windows {
			if s.text_mode {
				// Search only before an already-found delimiter. In the usual
				// line-reading case that is a few dozen bytes, rather than
				// rescanning the rest of an 8 KiB buffer for every line.
				text_span := span[:take]
				if i := bytes.index_byte(text_span, '\r'); i >= 0 {
					take = i
					special = true
					text_span = text_span[:i]
				}
				if i := bytes.index_byte(text_span, 0x1a); i >= 0 {
					take = i
					special = true
				}
			}
		}

		if take > 0 {
			before := s.raw_cursor
			copy(dst[n:n + take], s.read_buffer[s.read_index:s.read_index + take])
			s.read_index += take
			s.raw_cursor += i64(take)
			s.logical_pos = s.raw_cursor
			s.last_before = before + i64(take) - 1
			s.last_after = s.raw_cursor
			n += take
		}
		if n == len(dst) {
			return
		}
		if special {
			when ODIN_OS == .Windows {
				if s.text_mode &&
				   s.read_buffer[s.read_index] == '\r' &&
				   s.read_index + 1 < s.read_count &&
				   s.read_buffer[s.read_index + 1] == '\n' {
					// CRLF wholly inside this raw buffer is the overwhelmingly
					// common Windows line ending. We already stopped before the
					// CR, so collapse the pair here instead of taking another
					// procedure-call round trip through getc. The position cookie
					// still advances by both raw bytes, while ungetc metadata
					// describes the one logical newline exactly as getc would.
					before := s.raw_cursor
					s.read_index += 2
					s.raw_cursor += 2
					s.last_before = before
					s.last_after = s.raw_cursor
					s.logical_pos = s.raw_cursor
					dst[n] = '\n'
					n += 1
					if stop_at_delimiter && delimiter == '\n' {
						found = true
						return
					}
					continue
				}
			}
			// getc consumes the delimiter itself and performs CRLF/Ctrl-Z
			// translation when the raw byte was special only because of text mode.
			c := getc(s)
			if c == EOF {
				return
			}
			dst[n] = u8(c)
			n += 1
			if stop_at_delimiter && u8(c) == delimiter {
				found = true
				return
			}
		}
	}
	return
}

// Read up to and including `delimiter`. If the delimiter is not in the current
// raw buffer, the operation copies that whole translated run, refills, and keeps
// going until `dst` is full or input ends.
read_until :: proc(s: ^Stream, dst: []u8, delimiter: u8) -> (n: int, found: bool) {
	return read_bulk(s, dst, true, delimiter)
}

read :: proc(s: ^Stream, dst: []u8) -> int {
	n, _ := read_bulk(s, dst, false, 0)
	return n
}

@(private = "file")
logical_raw_size :: proc(s: ^Stream, data: []u8) -> i64 {
	n := i64(len(data))
	when ODIN_OS == .Windows {
		if s.text_mode {
			for c in data {
				if c == '\n' {
					n += 1
				}
			}
		}
	}
	return n
}

write :: proc(s: ^Stream, data: []u8) -> int {
	if s == nil || !prepare_write(s) {
		return 0
	}
	// Unbuffered mode reaches the handle immediately. Full mode flushes only when
	// its caller-selected buffer fills (or on an explicit flush/seek/close). Line
	// mode uses the same buffer but flushes after accepting a newline, which is
	// what makes terminal prompts and print output appear at the expected time.
	written := 0
	for written < len(data) {
		if s.mode == .Unbuffered {
			if !write_translated(s, data[written:written + 1]) {
				break
			}
			s.logical_pos += logical_raw_size(s, data[written:written + 1])
			s.raw_cursor = s.logical_pos
			written += 1
			continue
		}
		room := s.buffer_size - s.write_count
		if room == 0 {
			if !flush(s) {
				break
			}
			room = s.buffer_size
		}
		take := min(room, len(data) - written)
		copy(s.write_buffer[s.write_count:s.write_count + take], data[written:written + take])
		s.write_count += take
		s.logical_pos += logical_raw_size(s, data[written:written + take])
		written += take
		if s.mode == .Line {
			has_newline := false
			for c in data[written - take:written] {
				if c == '\n' {
					has_newline = true
				}
			}
			if has_newline && !flush(s) {
				break
			}
		}
	}
	return written
}

seek :: proc(s: ^Stream, offset: i64, from: Seek_From) -> (i64, bool) {
	if s == nil || !flush(s) {
		return 0, false
	}
	if s.direction == .Read && !discard_read_ahead(s) {
		return 0, false
	}
	target_from: io.Seek_From
	target := offset
	switch from {
	case .Start:
		target_from = .Start
	case .Current:
		target_from = .Start
		target = s.logical_pos + offset
	case .End:
		target_from = .End
	}
	pos, err := os.seek(s.file, target, target_from)
	if err != nil {
		return 0, fail(s, err)
	}
	s.logical_pos = pos
	s.raw_cursor = pos
	s.read_index = 0
	s.read_count = 0
	s.raw_saved = false
	s.pushback = false
	s.text_eof = false
	s.eof_flag = false
	s.direction = .None
	return pos, true
}

tell :: proc(s: ^Stream) -> (i64, bool) {
	if s == nil {
		set_error(os.Error(os.General_Error.Invalid_File))
		return 0, false
	}
	return s.logical_pos, true
}

setvbuf :: proc(s: ^Stream, mode: Buffer_Mode, size: int) -> bool {
	// Changing buffering first reconciles the old buffer with the logical file
	// position. We allocate both sides to the requested size so later reads and
	// writes obey the new policy without borrowing memory from the Lua state.
	if s == nil || size < 0 || !flush(s) {
		set_error(os.Error(os.General_Error.Invalid_File))
		return false
	}
	if s.direction == .Read && !discard_read_ahead(s) {
		return false
	}
	if !resize_buffers(s, size) {
		s.error_flag = true
		return false
	}
	s.mode = mode
	s.direction = .None
	return true
}

feof :: proc(s: ^Stream) -> bool {
	return s != nil && s.eof_flag
}

ferror :: proc(s: ^Stream) -> bool {
	return s != nil && s.error_flag
}

clearerr :: proc(s: ^Stream) {
	if s != nil {
		s.eof_flag = false
		s.error_flag = false
	}
}

// Direct terminal input is permitted only at a clean boundary in an unbuffered
// stream. These operations intentionally expose the ownership transition rather
// than letting the editor reach into Stream fields. In particular, a pending
// ungetc byte is real input and must make the editor fall back; silently dropping
// it on a non-seekable console would be data loss.
prepare_direct_read :: proc(s: ^Stream) -> bool {
	if s == nil || !prepare_read(s) || s.mode != .Unbuffered {
		return false
	}
	return s.read_index == s.read_count &&
		!s.raw_saved &&
		!s.pushback &&
		!s.text_eof
}

finish_direct_read :: proc(s: ^Stream) {
	if s == nil {
		return
	}
	s.direction = .Read
	s.eof_flag = false
}

close :: proc(s: ^Stream) -> bool {
	if s == nil {
		return true
	}
	ok := flush(s)
	if s.owns_file {
		if err := os.close(s.file); err != nil {
			set_error(err)
			ok = false
		}
	}
	if s.temp_path != "" {
		os.remove(s.temp_path)
		delete(s.temp_path)
	}
	unlink_stream(s)
	delete(s.read_buffer)
	delete(s.write_buffer)
	free(s)
	return ok
}

reopen :: proc(path, mode: string, s: ^Stream) -> ^Stream {
	if s == nil {
		return nil
	}
	// freopen closes the old association even when opening the replacement fails.
	flush(s)
	if s.owns_file {
		os.close(s.file)
	}
	replacement := open(path, mode)
	if replacement == nil {
		s.file = nil
		s.readable = false
		s.writable = false
		s.error_flag = true
		return nil
	}
	unlink_stream(replacement)
	next := s.next
	read_buffer := s.read_buffer
	write_buffer := s.write_buffer
	s^ = replacement^
	s.next = next
	delete(read_buffer)
	delete(write_buffer)
	free(replacement)
	return s
}
