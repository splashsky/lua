#+build windows
#+build !freestanding

package main

import "base:intrinsics"
import win "core:sys/windows"
import host "luao:host"
import lua "luao:lua"

// Windows does not deliver Ctrl-C on the interpreter thread. It creates a fresh
// control-handler thread, often while the VM is halfway through mutating a
// frame. Calling lua_sethook there would therefore be a real data race, not just
// the usual signal-handler austerity. The first event performs one atomic
// publication; the VM notices it at an instruction boundary and installs lstop
// itself. `2` means the first Ctrl-C has already been accepted.
interrupt_stage: i32
interrupt_handler_installed: bool

console_control_handler :: proc "system" (kind: win.DWORD) -> win.BOOL {
	switch kind {
	case win.CTRL_C_EVENT, win.CTRL_BREAK_EVENT:
		if intrinsics.atomic_load(&interrupt_stage) == 1 {
			_, won := intrinsics.atomic_compare_exchange_strong(&interrupt_stage, i32(1), i32(2))
			if won {
				lua.lua_request_async_hook(&interrupt_request)
				return win.TRUE
			}
		}
		// Reference restores SIG_DFL after the first interrupt. Keeping our tiny
		// callback installed is the Windows equivalent: a second Ctrl-C/BREAK
		// terminates immediately, but first repairs any active raw console mode.
		host.emergency_process_exit(130)
	case win.CTRL_CLOSE_EVENT, win.CTRL_LOGOFF_EVENT, win.CTRL_SHUTDOWN_EVENT:
		// These are shutdown requests, never Lua errors. Returning from CLOSE is
		// not a promise that Windows lets the process continue, so restore and
		// leave synchronously instead.
		host.emergency_process_exit(1)
	case:
		return win.FALSE
	}
}

platform_interrupt_init :: proc() {
	interrupt_handler_installed =
		win.SetConsoleCtrlHandler(console_control_handler, win.TRUE) != win.FALSE
}

platform_interrupt_arm :: proc() {
	if interrupt_handler_installed {
		intrinsics.atomic_store(&interrupt_stage, i32(1))
	}
}

platform_interrupt_disarm :: proc() {
	intrinsics.atomic_store(&interrupt_stage, i32(0))
}
