#+build !windows
#+build !linux
#+build !freestanding

package host

// Darwin and the BSDs intentionally use the plain REPL reader for now. Their
// ioctl request numbers and termios layouts differ from Linux; guessing them
// would let an editor scribble past the saved-mode object.
enter_terminal :: proc() -> bool {
	return false
}

restore_terminal :: proc() {}
