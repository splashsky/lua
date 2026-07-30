#+build !freestanding

package host

import "core:os"
import stream "luao:stream"

process_exit :: proc(status: int) -> ! {
	restore_terminal()
	stream.flush_all()
	os.exit(status)
}

fatal_exit :: proc(status: int) -> ! {
	process_exit(status)
}
