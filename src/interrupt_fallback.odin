#+build !windows
#+build !linux
#+build !freestanding

package main

// Deliberate safe fallback for Darwin/BSD and other hosted targets. Their
// sigaction structures, trampolines, and syscall numbers are not Linux's; no
// interrupt handling is better than returning through a guessed signal ABI.
platform_interrupt_init :: proc() {}
platform_interrupt_arm :: proc() {}
platform_interrupt_disarm :: proc() {}
