package kernel
// jmp.odin -- the tiny, libc-free machine-state jump used by protected calls.
//
// C describes setjmp as a function that "returns twice": once normally and once
// when longjmp resumes its saved call site. LLVM understands that attribute for
// C's intrinsic, but Odin cannot currently put it on a procedure. Consequently
// both procedures below MUST remain #force_no_inline. This is load-bearing, not
// an optimization preference: if jmp_set is inlined, the stack slot we read as
// its return address belongs to some enclosing procedure and the eventual jump
// corrupts the stack. The protected-boundary tests deliberately exercise speed
// builds, deep stacks, nested catches, and live locals to make that mistake loud.
//
// Each body is one inline-assembly block which returns (or branches) itself.
// There must be no ordinary Odin code on the reachable path after the assembly:
// the compiler is allowed to manufacture a prologue/epilogue, but our saved
// stack pointer describes the state at procedure entry, so running a compiler
// epilogue after restoring it would adjust the caller's stack a second time.

// Odin exposes Freestanding as the OS but does not expose the selected amd64
// sub-ABI as a compile-time constant. SysV is our bare-metal default. The build
// wrappers set this one narrowly-scoped override for the two Win64-ABI target
// triples; ordinary hosted builds and freestanding_amd64_sysv need no define.
FREESTANDING_WIN64_ABI :: #config(FREESTANDING_WIN64_ABI, false)

when ODIN_ARCH == .amd64 {
	when ODIN_OS == .Windows || (ODIN_OS == .Freestanding && FREESTANDING_WIN64_ABI) {
		// Win64 preserves RBX, RBP, RDI, RSI, R12-R15 and XMM6-XMM15 across a
		// call. This condition deliberately tests the ABI, not ODIN_OS: Odin's
		// freestanding_amd64_win64 and freestanding_amd64_mingw targets are bare
		// metal but retain this register contract. A caller may therefore keep
		// live Odin values in any of them across jmp_set. We save all of them,
		// plus the caller's post-return RSP and return address. Skipping the XMM
		// registers would appear to work for integer-heavy Lua code, but would
		// silently violate the ABI whenever the optimizer parked a live float
		// there.
		//
		// Layout: 8 integer registers, RSP, return address, then ten 16-byte
		// XMM values. movdqu intentionally permits the buffer's 8-byte
		// alignment; no hidden stronger alignment requirement leaks outward.
		Jmp_Buf :: [30]u64

		// Win64's first argument is RCX. At entry [RSP] is our return address;
		// RSP+8 is exactly the caller stack pointer to resume with.
		jmp_set :: #force_no_inline proc "c" (buf: ^Jmp_Buf) -> i32 {
			return asm(^Jmp_Buf) -> i32 {
				`movq %rbx,   0(%rcx)
				 movq %rbp,   8(%rcx)
				 movq %rdi,  16(%rcx)
				 movq %rsi,  24(%rcx)
				 movq %r12,  32(%rcx)
				 movq %r13,  40(%rcx)
				 movq %r14,  48(%rcx)
				 movq %r15,  56(%rcx)
				 leaq 8(%rsp), %rax
				 movq %rax,  64(%rcx)
				 movq (%rsp), %rax
				 movq %rax,  72(%rcx)
				 movdqu %xmm6,   80(%rcx)
				 movdqu %xmm7,   96(%rcx)
				 movdqu %xmm8,  112(%rcx)
				 movdqu %xmm9,  128(%rcx)
				 movdqu %xmm10, 144(%rcx)
				 movdqu %xmm11, 160(%rcx)
				 movdqu %xmm12, 176(%rcx)
				 movdqu %xmm13, 192(%rcx)
				 movdqu %xmm14, 208(%rcx)
				 movdqu %xmm15, 224(%rcx)
				 xorl %eax, %eax
				 ret`,
				"={eax},{rcx},~{memory}",
			}(buf)
		}

		// Win64's second integer argument is EDX. Restore every nonvolatile
		// register, map a requested zero result to one as C longjmp does, then
		// install the saved stack and branch instead of returning normally.
		jmp_long :: #force_no_inline proc "c" (buf: ^Jmp_Buf, value: i32) -> ! {
			asm(^Jmp_Buf, i32) {
				`movdqu   80(%rcx), %xmm6
				 movdqu   96(%rcx), %xmm7
				 movdqu  112(%rcx), %xmm8
				 movdqu  128(%rcx), %xmm9
				 movdqu  144(%rcx), %xmm10
				 movdqu  160(%rcx), %xmm11
				 movdqu  176(%rcx), %xmm12
				 movdqu  192(%rcx), %xmm13
				 movdqu  208(%rcx), %xmm14
				 movdqu  224(%rcx), %xmm15
				 movq   0(%rcx), %rbx
				 movq   8(%rcx), %rbp
				 movq  16(%rcx), %rdi
				 movq  24(%rcx), %rsi
				 movq  32(%rcx), %r12
				 movq  40(%rcx), %r13
				 movq  48(%rcx), %r14
				 movq  56(%rcx), %r15
				 movl %edx, %eax
				 testl %eax, %eax
				 jnz 1f
				 movl $$1, %eax
				 1:
				 movq 64(%rcx), %rsp
				 jmpq *72(%rcx)`,
				"{rcx},{edx},~{memory}",
			}(buf, value)
			for {}
		}
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .Freestanding {
		// The x86-64 SysV ABI, including freestanding_amd64_sysv, preserves
		// RBX, RBP, and R12-R15. RDI/RSI and
		// every vector register are caller-saved here, so unlike Win64 they
		// must not be restored by a callee and do not belong in this buffer.
		// The final two slots are the caller's post-return RSP and the return
		// address read from the entry stack.
		Jmp_Buf :: [8]u64

		jmp_set :: #force_no_inline proc "c" (buf: ^Jmp_Buf) -> i32 {
			return asm(^Jmp_Buf) -> i32 {
				`movq %rbx,  0(%rdi)
				 movq %rbp,  8(%rdi)
				 movq %r12, 16(%rdi)
				 movq %r13, 24(%rdi)
				 movq %r14, 32(%rdi)
				 movq %r15, 40(%rdi)
				 leaq 8(%rsp), %rax
				 movq %rax, 48(%rdi)
				 movq (%rsp), %rax
				 movq %rax, 56(%rdi)
				 xorl %eax, %eax
				 ret`,
				"={eax},{rdi},~{memory}",
			}(buf)
		}

		jmp_long :: #force_no_inline proc "c" (buf: ^Jmp_Buf, value: i32) -> ! {
			asm(^Jmp_Buf, i32) {
				`movq  0(%rdi), %rbx
				 movq  8(%rdi), %rbp
				 movq 16(%rdi), %r12
				 movq 24(%rdi), %r13
				 movq 32(%rdi), %r14
				 movq 40(%rdi), %r15
				 movl %esi, %eax
				 testl %eax, %eax
				 jnz 1f
				 movl $$1, %eax
				 1:
				 movq 48(%rdi), %rsp
				 jmpq *56(%rdi)`,
				"{rdi},{esi},~{memory}",
			}(buf, value)
			for {}
		}
	} else {
		#panic(PROGNAME + ": libc-free setjmp is not implemented for amd64 on this operating system")
	}
} else when ODIN_ARCH == .arm64 {
	// AAPCS64 preserves X19-X28, FP (X29), LR (X30), SP, and the low 64 bits
	// of D8-D15. That rule is shared by the arm64 ABIs used by Windows, Linux,
	// and macOS. LR already contains the direct caller's resume address, so
	// arm64 does not need to recover it from the stack as x86-64 does.
	//
	// Layout: X19-X28, FP, LR, SP, then D8-D15, all as 64-bit slots.
	Jmp_Buf :: [21]u64

	// AAPCS64 passes the buffer in X0. As above, #force_no_inline is essential:
	// Odin cannot tell LLVM this call returns twice.
	jmp_set :: #force_no_inline proc "c" (buf: ^Jmp_Buf) -> i32 {
		return asm(^Jmp_Buf) -> i32 {
			`stp x19, x20, [x0, #0]
			 stp x21, x22, [x0, #16]
			 stp x23, x24, [x0, #32]
			 stp x25, x26, [x0, #48]
			 stp x27, x28, [x0, #64]
			 stp x29, x30, [x0, #80]
			 mov x9, sp
			 str x9, [x0, #96]
			 stp d8, d9, [x0, #104]
			 stp d10, d11, [x0, #120]
			 stp d12, d13, [x0, #136]
			 stp d14, d15, [x0, #152]
			 mov w0, wzr
			 ret`,
			"={w0},{x0},~{x9},~{memory}",
		}(buf)
	}

	// X0 and W1 carry the two arguments. X16 is an ABI scratch register, so it
	// keeps the saved SP until all buffer reads finish; the restored LR itself
	// is the branch target. Only then do we place longjmp's result in W0.
	jmp_long :: #force_no_inline proc "c" (buf: ^Jmp_Buf, value: i32) -> ! {
		asm(^Jmp_Buf, i32) {
			`ldp x19, x20, [x0, #0]
			 ldp x21, x22, [x0, #16]
			 ldp x23, x24, [x0, #32]
			 ldp x25, x26, [x0, #48]
			 ldp x27, x28, [x0, #64]
			 ldp x29, x30, [x0, #80]
			 ldr x16, [x0, #96]
			 ldp d8, d9, [x0, #104]
			 ldp d10, d11, [x0, #120]
			 ldp d12, d13, [x0, #136]
			 ldp d14, d15, [x0, #152]
			 mov w0, w1
			 cbnz w0, 1f
			 mov w0, #1
			 1:
			 mov sp, x16
			 br x30`,
			"{x0},{w1},~{x16},~{memory}",
		}(buf, value)
		for {}
	}
} else {
	#panic(PROGNAME + ": libc-free setjmp is implemented only for amd64 and arm64")
}
