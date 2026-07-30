#+build linux
#+build !freestanding

package main

import linux "core:sys/linux"
import lua "luao:lua"

// Linux is the only POSIX ABI implemented here. Odin's core syscall wrapper
// supplies the architecture-correct rt_sigaction layout and restorer without
// libc. Darwin and the BSDs intentionally use the fallback file below: guessing
// that their signal frame matches Linux would corrupt the returning thread.
linux_interrupt_handler :: proc "c" (signal: linux.Signal) {
	// Match reference's immediate SIG_DFL reset. A second SIGINT is consequently
	// handled by the kernel's default action, while this first one merely
	// publishes the lock-free mailbox consumed by the interpreter thread.
	action := linux.Sig_Action{}
	action.special = .SIG_DFL
	_ = linux.rt_sigaction(.SIGINT, &action, nil)
	lua.lua_request_async_hook(&interrupt_request)
}

platform_interrupt_init :: proc() {}

platform_interrupt_arm :: proc() {
	action := linux.Sig_Action{}
	action.handler = linux_interrupt_handler
	_ = linux.rt_sigaction(.SIGINT, &action, nil)
}

platform_interrupt_disarm :: proc() {
	action := linux.Sig_Action{}
	action.special = .SIG_DFL
	_ = linux.rt_sigaction(.SIGINT, &action, nil)
}
