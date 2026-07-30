#+build !freestanding

package shellproc

import "core:os"
import stream "luao:stream"

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
