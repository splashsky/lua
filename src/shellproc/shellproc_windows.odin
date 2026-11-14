#+build windows
#+build !freestanding

package shellproc

import "core:os"
import "core:sync"
import win "core:sys/windows"
import stream "lang:stream"

platform_error :: proc() -> os.Error {
	// core:os does not expose its private GetLastError converter. Keep the
	// failure honest without manufacturing an ABI-dependent union value.
	return os.General_Error.Invalid_File
}

open :: proc(command, mode: string) -> Open_Result {
	h, alloc_err := new(Handle)
	if alloc_err != nil {
		return {err = os.General_Error.Invalid_File}
	}
	// CreatePipe's handles are inheritable immediately, including before the
	// parent end can be cleared. Cover that whole window and the child's close.
	sync.mutex_lock(&spawn_mutex)
	defer sync.mutex_unlock(&spawn_mutex)
	read_end, write_end, err := os.pipe()
	if err != nil {
		free(h)
		return {err = err}
	}

	reading := mode[0] == 'r'
	parent_end := read_end if reading else write_end
	child_end := write_end if reading else read_end

	// CreatePipe makes both handles inheritable. That is convenient for the end
	// the child needs, but disastrous for the parent's end: if the child inherits
	// a spare writer, a parent reading the pipe can wait forever because Windows
	// still sees one writer alive. Clear inheritance on exactly the parent end.
	parent_handle := win.HANDLE(os.fd(parent_end))
	if win.SetHandleInformation(
		parent_handle,
		win.HANDLE_FLAG_INHERIT,
		0,
	) == win.FALSE {
		err = platform_error()
		os.close(read_end)
		os.close(write_end)
		free(h)
		return {err = err}
	}

	text_mode := len(mode) == 1 || mode[1] != 'b'
	s := stream.from_file(parent_end, true, reading, !reading, text_mode)
	if s == nil {
		err = stream.last_error()
		os.close(child_end)
		free(h)
		return {err = err}
	}

	desc := os.Process_Desc {
		command = []string{"cmd.exe", "/c", command},
		stdin = child_end if !reading else os.stdin,
		stdout = child_end if reading else os.stdout,
		stderr = os.stderr,
	}
	process, start_err := os.process_start(desc)

	// The parent must close its copy of the child's end immediately after
	// CreateProcess. Keeping that copy open is indistinguishable from the child
	// keeping it open and is the classic cause of popen reads that never see EOF.
	os.close(child_end)
	if start_err != nil {
		stream.close(s)
		free(h)
		return {err = start_err}
	}

	h.process = process
	return {stream = s, handle = h}
}

wait_process :: proc(process: os.Process) -> Wait_Result {
	state, err := os.process_wait(process)
	if err != nil {
		return {err = err}
	}
	// Windows process exit codes are already the values exposed by _pclose.
	// There is no POSIX-style wait status to classify as a signal termination.
	return {code = i32(state.exit_code)}
}

wait :: proc(h: ^Handle) -> Wait_Result {
	process := h.process
	free(h)
	return wait_process(process)
}
