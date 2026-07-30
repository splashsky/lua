#+build freestanding

package host

restore_terminal :: proc() {}

fatal_exit :: proc(status: int) -> ! {
	for {}
}
