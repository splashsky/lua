package kernel
// jmp.odin -- the tiny, libc-free machine-state jump used by protected calls.
//
// C describes setjmp as a function that "returns twice": once normally and once
// when longjmp resumes its saved call site. LLVM understands that attribute for
// C's intrinsic, but Odin cannot currently put it on a procedure. Consequently
// the machine entry points below MUST remain #force_no_inline. This is load-bearing,
// not an optimization preference: if jmp_set is inlined, the stack slot we read as
// its return address belongs to some enclosing procedure and the eventual jump
// corrupts the stack. The protected-boundary tests deliberately exercise speed
// builds, deep stacks, nested catches, and live locals to make that mistake loud.
//
// Each body is one inline-assembly block which returns (or branches) itself.
// The set templates have an impossible conditional fallthrough so Odin and LLVM
// see an ordinary returning procedure instead of inferring that it never returns.
// jmp_set uses the C ABI with a naked, no-argument declaration: Odin otherwise
// spills declared parameters even in naked procedures, which LLVM rejects. Its
// caller casts it to the actual C signature and passes the buffer in the ABI's
// first argument register. This keeps the save at the true entry SP even without
// optimization. jmp_long can have a prologue because it installs the saved SP
// and branches, without running a compiler epilogue afterward.

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
		jmp_set :: #force_no_inline proc "naked" () -> i32 {
			return asm() -> (result: i32) [
				result = %eax, #preserve %rcx, #clobber memory, #volatile,
				#preserve %rbx, #preserve %rbp, #preserve %rdi, #preserve %rsi,
				#preserve %r12, #preserve %r13, #preserve %r14, #preserve %r15,
				#preserve %xmm6, #preserve %xmm7, #preserve %xmm8, #preserve %xmm9,
				#preserve %xmm10, #preserve %xmm11, #preserve %xmm12,
				#preserve %xmm13, #preserve %xmm14, #preserve %xmm15,
			] {
				mov [%rcx +   0]:u64, %rbx
				mov [%rcx +   8]:u64, %rbp
				mov [%rcx +  16]:u64, %rdi
				mov [%rcx +  24]:u64, %rsi
				mov [%rcx +  32]:u64, %r12
				mov [%rcx +  40]:u64, %r13
				mov [%rcx +  48]:u64, %r14
				mov [%rcx +  56]:u64, %r15
				lea %rax, [%rsp + 8]
				mov [%rcx +  64]:u64, %rax
				mov %rax, [%rsp]:u64
				mov [%rcx +  72]:u64, %rax
				movdqu [%rcx +  80], %xmm6
				movdqu [%rcx +  96], %xmm7
				movdqu [%rcx + 112], %xmm8
				movdqu [%rcx + 128], %xmm9
				movdqu [%rcx + 144], %xmm10
				movdqu [%rcx + 160], %xmm11
				movdqu [%rcx + 176], %xmm12
				movdqu [%rcx + 192], %xmm13
				movdqu [%rcx + 208], %xmm14
				movdqu [%rcx + 224], %xmm15
				xor result, result
				jnz .end
				ret
			.end:
			}()
		}

		// Win64's second integer argument is EDX. Restore every nonvolatile
		// register, map a requested zero result to one as C longjmp does, then
		// install the saved stack and branch instead of returning normally.
		jmp_long :: #force_no_inline proc "c" (buf: ^Jmp_Buf, value: i32) -> ! {
			asm(buf: ^Jmp_Buf, value: i32) -> ! [
				buf = %rcx, value = %edx, #clobber memory, #volatile,
			] {
				movdqu %xmm6,  [buf +  80]
				movdqu %xmm7,  [buf +  96]
				movdqu %xmm8,  [buf + 112]
				movdqu %xmm9,  [buf + 128]
				movdqu %xmm10, [buf + 144]
				movdqu %xmm11, [buf + 160]
				movdqu %xmm12, [buf + 176]
				movdqu %xmm13, [buf + 192]
				movdqu %xmm14, [buf + 208]
				movdqu %xmm15, [buf + 224]
				mov %rbx, [buf +  0]:u64
				mov %rbp, [buf +  8]:u64
				mov %rdi, [buf + 16]:u64
				mov %rsi, [buf + 24]:u64
				mov %r12, [buf + 32]:u64
				mov %r13, [buf + 40]:u64
				mov %r14, [buf + 48]:u64
				mov %r15, [buf + 56]:u64
				mov %eax, value
				test %eax, %eax
				jnz .nonzero
				mov %eax, 1
			.nonzero:
				mov %rsp, [buf + 64]:u64
				jmp [buf + 72]:u64
			}(buf, value)
		}
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .Freestanding {
		// The x86-64 SysV ABI, including freestanding_amd64_sysv, preserves
		// RBX, RBP, and R12-R15. RDI/RSI and
		// every vector register are caller-saved here, so unlike Win64 they
		// must not be restored by a callee and do not belong in this buffer.
		// The final two slots are the caller's post-return RSP and the return
		// address read from the entry stack.
		Jmp_Buf :: [8]u64

		jmp_set :: #force_no_inline proc "naked" () -> i32 {
			return asm() -> (result: i32) [
				result = %eax, #preserve %rdi, #clobber memory, #volatile,
				#preserve %rbx, #preserve %rbp, #preserve %r12,
				#preserve %r13, #preserve %r14, #preserve %r15,
			] {
				mov [%rdi +  0]:u64, %rbx
				mov [%rdi +  8]:u64, %rbp
				mov [%rdi + 16]:u64, %r12
				mov [%rdi + 24]:u64, %r13
				mov [%rdi + 32]:u64, %r14
				mov [%rdi + 40]:u64, %r15
				lea %rax, [%rsp + 8]
				mov [%rdi + 48]:u64, %rax
				mov %rax, [%rsp]:u64
				mov [%rdi + 56]:u64, %rax
				xor result, result
				jnz .end
				ret
			.end:
			}()
		}

		jmp_long :: #force_no_inline proc "c" (buf: ^Jmp_Buf, value: i32) -> ! {
			asm(buf: ^Jmp_Buf, value: i32) -> ! [
				buf = %rdi, value = %esi, #clobber memory, #volatile,
			] {
				mov %rbx, [buf +  0]:u64
				mov %rbp, [buf +  8]:u64
				mov %r12, [buf + 16]:u64
				mov %r13, [buf + 24]:u64
				mov %r14, [buf + 32]:u64
				mov %r15, [buf + 40]:u64
				mov %eax, value
				test %eax, %eax
				jnz .nonzero
				mov %eax, 1
			.nonzero:
				mov %rsp, [buf + 48]:u64
				jmp [buf + 56]:u64
			}(buf, value)
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
	// This compiler recognizes %v8-%v15 but not their scalar %d aliases; #byte
	// emits the corresponding little-endian A64 stp/ldp instructions directly.
	// Their base is X0, the ABI's buffer argument register.
	jmp_set :: #force_no_inline proc "naked" () -> i32 {
		return asm() -> (result: i32) [
			result = %w0, #preserve %x0, #clobber memory, #volatile,
			#preserve %x19, #preserve %x20, #preserve %x21, #preserve %x22,
			#preserve %x23, #preserve %x24, #preserve %x25, #preserve %x26,
			#preserve %x27, #preserve %x28, #preserve %x29, #preserve %x30, #preserve %sp,
		] {
			stp %x19, %x20, [%x0 +   0]
			stp %x21, %x22, [%x0 +  16]
			stp %x23, %x24, [%x0 +  32]
			stp %x25, %x26, [%x0 +  48]
			stp %x27, %x28, [%x0 +  64]
			stp %x29, %x30, [%x0 +  80]
			mov %x9, %sp
			str %x9, [%x0 + 96]
			#byte 0x08, 0xa4, 0x06, 0x6d // stp d8,  d9,  [x0, #104]
			#byte 0x0a, 0xac, 0x07, 0x6d // stp d10, d11, [x0, #120]
			#byte 0x0c, 0xb4, 0x08, 0x6d // stp d12, d13, [x0, #136]
			#byte 0x0e, 0xbc, 0x09, 0x6d // stp d14, d15, [x0, #152]
			mov result, %wzr
			cbnz result, .end
			ret
		.end:
		}()
	}

	// X0 and W1 carry the two arguments. X16 is an ABI scratch register, so it
	// keeps the saved SP until all buffer reads finish; the restored LR itself
	// is the branch target. Only then do we place longjmp's result in W0.
	jmp_long :: #force_no_inline proc "c" (buf: ^Jmp_Buf, value: i32) -> ! {
		asm(buf: ^Jmp_Buf, value: i32) -> ! [
			buf = %x0, value = %w1, #clobber memory, #volatile,
		] {
			ldp %x19, %x20, [buf +   0]
			ldp %x21, %x22, [buf +  16]
			ldp %x23, %x24, [buf +  32]
			ldp %x25, %x26, [buf +  48]
			ldp %x27, %x28, [buf +  64]
			ldp %x29, %x30, [buf +  80]
			ldr %x16, [buf +  96]
			#byte 0x08, 0xa4, 0x46, 0x6d // ldp d8,  d9,  [x0, #104]
			#byte 0x0a, 0xac, 0x47, 0x6d // ldp d10, d11, [x0, #120]
			#byte 0x0c, 0xb4, 0x48, 0x6d // ldp d12, d13, [x0, #136]
			#byte 0x0e, 0xbc, 0x49, 0x6d // ldp d14, d15, [x0, #152]
			mov %w0, value
			cbnz %w0, .nonzero
			mov %w0, 1
		.nonzero:
			mov %sp, %x16
			br %x30
		}(buf, value)
	}
} else {
	#panic(PROGNAME + ": libc-free setjmp is implemented only for amd64 and arm64")
}
