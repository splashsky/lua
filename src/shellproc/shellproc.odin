#+build !freestanding

package shellproc

import "core:os"
import "core:sync"
import stream "lang:stream"

when ODIN_OS == .Windows {
	@(private)
	spawn_mutex: sync.Mutex
}

// Windows process_start inherits every inheritable handle. Coordinate os.execute
// with popen while the latter has its child pipe end temporarily inheritable.
start_process :: proc(desc: os.Process_Desc) -> (os.Process, os.Error) {
	when ODIN_OS == .Windows {
		sync.mutex_lock(&spawn_mutex)
		defer sync.mutex_unlock(&spawn_mutex)
	}
	return os.process_start(desc)
}

// A popen handle deliberately keeps process ownership separate from stream
// ownership. The stream closes the parent's pipe end; only after that happens is
// it safe to wait, especially in write mode where closing the pipe is how the
// child learns that stdin reached EOF.
Handle :: struct {
	process: os.Process,
}

Wait_Result :: struct {
	code:     i32,
	signaled: bool,
	err:      os.Error,
}

Open_Result :: struct {
	stream: ^stream.Stream,
	handle: ^Handle,
	err:    os.Error,
}
