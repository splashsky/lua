#+build linux
#+build !freestanding

package shellproc

import "core:os"
import linux "core:sys/linux"
import stream "lang:stream"

linux_error :: proc(errno: linux.Errno) -> os.Error {
	#partial switch errno {
	case .ENOMEM:
		return os.General_Error.Invalid_File
	case .EBADF:
		return os.General_Error.Invalid_File
	case:
		return os.General_Error.Invalid_File
	}
}

open :: proc(command, mode: string) -> Open_Result {
	h, alloc_err := new(Handle)
	if alloc_err != nil {
		return {err = os.General_Error.Invalid_File}
	}
	read_end, write_end, err := os.pipe()
	if err != nil {
		free(h)
		return {err = err}
	}

	reading := mode[0] == 'r'
	parent_end := read_end if reading else write_end
	child_end := write_end if reading else read_end
	s := stream.from_file(parent_end, true, reading, !reading, true)
	if s == nil {
		err = stream.last_error()
		os.close(child_end)
		free(h)
		return {err = err}
	}

	// core:os implements this path with Linux pipe2/fork/dup2/execve syscalls.
	// Supplying /bin/sh -c gives the same shell boundary as POSIX popen while
	// retaining the project's existing, libc-free process-spawning machinery.
	desc := os.Process_Desc {
		command = []string{"/bin/sh", "-c", command},
		stdin = child_end if !reading else os.stdin,
		stdout = child_end if reading else os.stdout,
		stderr = os.stderr,
	}
	process, start_err := os.process_start(desc)

	// As on Windows, the parent's duplicate of the child end must disappear now.
	// Otherwise the kernel cannot report EOF to a reader (or EOF on stdin to the
	// child in write mode), and close can deadlock waiting for an event that the
	// still-open descriptor itself prevents.
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
	status: u32
	errno := linux.Errno.EINTR
	for errno == .EINTR {
		_, errno = linux.waitpid(linux.Pid(process.pid), &status, {}, nil)
	}

	// process_start owns a pidfd on Linux. Because we reap with waitpid to retain
	// the raw wait status (and therefore signal-vs-exit fidelity), close that pidfd
	// directly instead of asking core:os to perform a second wait.
	if process.handle != 0 && process.handle != ~uintptr(0) {
		_ = linux.close(linux.Fd(process.handle))
	}
	if errno != .NONE {
		return {err = linux_error(errno)}
	}

	signal := i32(status & 0x7f)
	if signal != 0 {
		return {code = signal, signaled = true}
	}
	return {code = i32((status >> 8) & 0xff)}
}

wait :: proc(h: ^Handle) -> Wait_Result {
	process := h.process
	free(h)
	return wait_process(process)
}
