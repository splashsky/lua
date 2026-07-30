#+build !windows
#+build !linux
#+build !freestanding

package shellproc

import "core:io"
import "core:os"

open :: proc(command, mode: string) -> Open_Result {
	return {err = io.Error.Unsupported}
}

wait :: proc(h: ^Handle) -> Wait_Result {
	return {err = io.Error.Unsupported}
}

wait_process :: proc(process: os.Process) -> Wait_Result {
	state, err := os.process_wait(process)
	return {code = i32(state.exit_code), err = err}
}
