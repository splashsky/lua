package main

import "core:crypto/hash"
import "core:fmt"
import "core:os"
import "core:strings"

// Generate the threaded handlers from vm_execute. Changes to paths whose
// control flow is rewritten require review rather than blind regeneration.
MARKER :: "// BEGIN GENERATED THREADED VM -- tools/generate_threaded\n"
ARGS :: "L, pc, regs, cl, code, ci_idx, trap, ctx, i"
NEXT_ARGS :: "L, pc, regs, cl, code, ci_idx, trap, ctx, next_i"
SIG :: "(L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32"
LOCALS :: `context = ctx^
pc := pc_arg
regs := regs_arg
cl := cl_arg
k := cl.p.k
code := code_arg
base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
ci_idx := ci_idx_arg
trap := trap_arg
i := i_arg
_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
`

fail :: proc(message: string) -> ! {
	fmt.eprintf("generate_threaded: %s\n", message)
	os.exit(1)
}

read_text :: proc(path: string) -> string {
	b, err := os.read_entire_file(path, context.allocator)
	if err != nil {fail(fmt.tprintf("cannot read %s: %v", path, err))}
	s, _ := strings.replace_all(string(b), "\r\n", "\n")
	return s
}

before :: proc(s, delim: string) -> string {
	i := strings.index(s, delim)
	if i < 0 {fail(fmt.tprintf("missing source delimiter %q", delim))}
	return s[:i]
}

after :: proc(s, delim: string) -> string {
	i := strings.index(s, delim)
	if i < 0 {fail(fmt.tprintf("missing source delimiter %q", delim))}
	return s[i+len(delim):]
}

between :: proc(s, start, end: string) -> string {
	return before(after(s, start), end)
}

replace_exact :: proc(s, old, new: string, count := 1) -> string {
	n := strings.count(s, old)
	if n != count {fail(fmt.tprintf("expected %d occurrences of %q, got %d", count, old, n))}
	r, _ := strings.replace_all(s, old, new)
	return r
}

digest :: proc(s: string) -> string {
	bytes := hash.hash_string(.SHA256, s)
	b := strings.builder_make()
	for x in bytes {fmt.sbprintf(&b, "%02x", x)}
	return strings.to_string(b)
}

review :: proc(s, expected, what: string) {
	if digest(strings.trim_space(s)) != expected {
		fail(fmt.tprintf("%s changed; review its threaded specialization", what))
	}
}

// Python's textwrap.dedent removes the common *literal* whitespace prefix,
// not the same visual width of tabs and spaces. Blank lines become empty.
dedent :: proc(s: string) -> string {
	lines := strings.split(s, "\n")
	prefix := ""
	have_prefix := false
	for line in lines {
		i := 0
		for i < len(line) && (line[i] == ' ' || line[i] == '\t') {i += 1}
		if i == len(line) {continue}
		if !have_prefix {
			prefix = line[:i]
			have_prefix = true
		} else {
			j := 0
			for j < len(prefix) && j < i && prefix[j] == line[j] {j += 1}
			prefix = prefix[:j]
		}
	}
	b := strings.builder_make()
	for line, i in lines {
		if strings.trim(line, " \t") != "" {
			strings.write_string(&b, line[len(prefix):])
		}
		if i + 1 < len(lines) {strings.write_byte(&b, '\n')}
	}
	return strings.to_string(b)
}

emit_indented :: proc(b: ^strings.Builder, s: string) {
	text := strings.trim(dedent(s), "\n")
	for line in strings.split(text, "\n") {
		if strings.trim(line, " \t") != "" {strings.write_string(b, "\t\t")}
		strings.write_string(b, line)
		strings.write_byte(b, '\n')
	}
}

emit_proc :: proc(b: ^strings.Builder, name, body: string, scoped := false) {
	noinline := ""
	if name == "vm_thread_enter" || name == "vm_thread_enternew" || name == "vm_thread_trace" || name == "vm_thread_poll" ||
	   name == "vm_thread_CALL_slow" || name == "vm_thread_CALL_precalled" ||
	   name == "vm_thread_CALL_lcf" || name == "vm_thread_CALL_ccl" ||
	   name == "vm_thread_RETURN0_slow" || name == "vm_thread_RETURN1_slow" ||
	   name == "vm_thread_gettable_miss" || name == "vm_thread_gettable_int" ||
	   name == "vm_thread_gettable_generic" || name == "vm_thread_gettabup_miss" ||
	   name == "vm_thread_gettabup_generic" || name == "vm_thread_settable_slow" ||
	   name == "vm_thread_settable_str" || name == "vm_thread_settable_collect" ||
	   name == "vm_thread_settable_general" ||
	   name == "vm_thread_geti_slow" || name == "vm_thread_seti_slow" || name == "vm_thread_seti_collect" ||
	   name == "vm_thread_concat_meta_op" {
		noinline = "#force_no_inline "
	}
	fmt.sbprintf(b, "\t%s :: %sproc \"preserve/none\" %s {{\n", name, noinline, SIG)
	locals := LOCALS
	if scoped {locals = replace_exact(locals, "context = ctx^\n", "")}
	if name == "vm_thread_enter" {locals = replace_exact(locals, "k := cl.p.k", "k: [^]TValue")}
	emit_indented(b, locals)
	emit_indented(b, body)
	strings.write_string(b, "\t}\n\n")
}

is_edge :: proc(name: string) -> bool {
	switch name {
	case "JMP", "EQ", "LT", "LE", "EQK", "EQI", "LTI", "LEI", "GTI", "GEI",
	     "TEST", "TESTSET", "RETURN0", "RETURN1", "FORLOOP", "TFORLOOP":
		return true
	case: return false
	}
}

rewrite_returns :: proc(s: string, count: ^int) -> string {
	b := strings.builder_make()
	lines := strings.split(s, "\n")
	for line, i in lines {
		if strings.trim_space(line) == "return" {
			count^ += 1
			pos := strings.index(line, "return")
			strings.write_string(&b, line[:pos])
			strings.write_string(&b, "return 0")
		} else {
			strings.write_string(&b, line)
		}
		if i + 1 < len(lines) {strings.write_byte(&b, '\n')}
	}
	return strings.to_string(b)
}

generate :: proc(src, opcode_src, do_src, state_src, tm_src, table_src, gc_src, string_src, mem_src, gc_run_src: string) -> string {
	review(between(src, "vm_finishget :: proc", "// The VM's table read"), "cff1bbd520882786832a21ed0384f86465f24b06c3359529b1c33691aaac40cf", "vm_finishget")
	review(between(src, "vm_gettable :: proc(", "\n// OP_GETI"), "ec9fd4cce26c455e29ebb7114d3d5d3afb0778e5210a77e0cebde1f4ac98b628", "vm_gettable")
	review(between(src, "vm_geti :: #force_inline proc", "// Finish `t[key]"), "e8175bba83c6513e77e7376f03a7782384964eda72bd6b8cae59c0e8713e9d8b", "vm_geti")
	review(between(src, "vm_settable :: proc(", "// OP_SETI"), "a1d4edb3b18fe00ac7cdd73b9d337146a3fd483f85f51fe791975d69cf929b77", "vm_settable")
	review(between(src, "vm_seti :: #force_inline proc", "// ---------------------------------------------------------------------------\n// Length"), "e5368f3f920dd3090fe5515a86cf557df4167612d1e9c3a76cdeca4ab380e9d5", "vm_seti")
	review(between(src, "vm_objlen :: proc", "// Convert a number"), "6dce8953407021af089dcb4488b6b4405f3188d3adaef914be3d5623322f4a5f", "vm_objlen")
	review(between(src, "object_tostring :: proc", "// ---------------------------------------------------------------------------\n// Closures"), "02bc30ebd9b6ec705ede7d28d63829ed0df6563821592934cb8ce452d774de3c", "concatenation helpers")
	review(between(string_src, "growstrtab :: proc", "// Create a string from an Odin string value."), "edf12cbe60c3a58895cf9f46c0fc2cb894d1fb258a2ed1a6faa1d7201f419dc2", "string creation")
	review(between(gc_src, "gc_newobj :: proc", "// Move a freshly created object off the sweep list"), "cb4e6f2110cbb44a5bf484c56ad602a935ad353cdfe871aaae4a05ae9273d5e1", "gc_newobj")
	review(between(mem_src, "raw_realloc :: proc", "// Free a block of"), "b39bc47f29fefdc9a0dd6bbeef573fe153373e17c463c526111d119ecc89cc66", "raw_realloc")
	review(between(mem_src, "state_realloc :: proc", "// Free a block of `osize`"), "c8421fdc396a77286d5d8ad2b4df710279cbf7c8daf5fef99cef13aaf6dcc6ab", "state_realloc")
	review(between(gc_run_src, "gc_checkGC :: proc", "// ---------------------------------------------------------------------------\n// Full collections"), "23d906ad3f9ccd8c4387aa797a268eaf387c4bcd959f821bfa186cece736f2f9", "gc_checkGC")
	review(between(src, "vm_arith :: #force_inline proc", "// ---------------------------------------------------------------------------\n// The interpreter loop"), "8493f193af8288550b22240f2509f0cf3d7a5b866811e8cbf25ebc489a6a26b3", "vm_arith")
	review(between(tm_src, "tm_gettmbyobj :: proc", "// The type name"), "b9d33e4481e049c8858bc8a68c5e0edf619dd19e5d4d0abc9b0fda806cfeeded", "tm_gettmbyobj")
	review(between(tm_src, "tm_tryconcatTM :: proc", "// An ordering metamethod"), "6f33172aa69a529399b2a5d529dedd32227910aa1816d559ebd6b7daed289d71", "tm_tryconcatTM")
	review(between(table_src, "table_get ::", "// Odin does not reliably inline"), "86124ae5d3c25a8ec0c1fc4bcdfa3b576de9b8401b7597f3693f94230ddaab04", "table_get")
	review(between(table_src, "table_getint :: proc", "// This is the Odin equivalent"), "3f43ee7bb008ff2e3bf42367fa07e3a3f84eb5a75484f68a0d0d76408d0cbf20", "table_getint")
	review(between(table_src, "table_fastgeti :: #force_inline proc", "table_getshortstr :: proc"), "9e2ed5c5700ae19c8185bcfb1f6f1e62ede27e1ed89e1c574532ba0eb26d448b", "table_fastgeti")
	review(between(table_src, "table_fastget ::", "// ---------------------------------------------------------------------------\n// Insertion into the hash part"), "8490a704b65daa82efe7a00322f7c5bff9188b22a50549d5f79ac50d2ae846c0", "table_fastget")
	review(between(table_src, "table_psetint :: proc", "// Like `luaH_fastgeti`"), "929c6909217b5914c0ac0303a2eaf59498699811f0dcbfc12dabc714869faf42", "table_psetint")
	review(between(table_src, "table_fastseti :: #force_inline proc", "// Reference's short-string preset"), "38b0e28d813b2d93e29b4b5c9b614b99bd77d3485f3ceec1e50af82517aec017", "table_fastseti")
	review(between(table_src, "table_psetshortstr :: proc", "table_psetstr :: proc"), "f7f146d846e2a8f0750cfada9e307bfd00cbbfd00c9433f95e4cac703d65dafc", "table_psetshortstr")
	review(between(gc_src, "gc_barrierback :: #force_inline proc", "// ---------------------------------------------------------------------------\n// Marking"), "e0cd00545b842118e7412e431990db1781e48a19244480187c41aa845b44dff4", "gc_barrierback")
	review(between(state_src, "keepinvariant :: #force_inline proc", "// True while sweeping"), "cbe4aecaa9c5ae71e9693c95e1f7f99cb10f88c938fb75c046cffd9ba3847a23", "keepinvariant")
	review(between(do_src, "do_precall :: proc(", "\n// Call a function through C"), "3dd0c962e31dea3def02de9441fe585adfa855a6c50b82c0d1fffb393f01fb7c", "do_precall")
	review(between(do_src, "precallC ::", "// Prepare a tail call"), "640f1ca44253255dd033a31cb42d5188a3c0ab420ccde017a234ab7b89aa74e0", "precallC")
	review(between(do_src, "do_poscall ::", "// Allocate and initialize the next call frame"), "8371b825b64d90b22c7a983c4bfd5a74a05f336ed19770ee23cf25622d9f4096", "do_poscall")
	review(between(do_src, "moveresults ::", "// Keep uncommon result counts"), "c78ad0a77d3fa0b06bd4f88744106d176694361c082a07a7f5b8f18551bda6c1", "moveresults")
	review(between(do_src, "prepCallInfo ::", "\n// precall for a C"), "b6609962813d1745fd2680803d830abc3a32f8774fee055b3771e2a851ed4661", "prepCallInfo")
	review(between(do_src, "check_stack_p ::", "\n// ---------------------------------------------------------------------------\n// Debug hooks"), "d35bd7d94a90898de3541ab0e796ba04b6a6a41f3fd58632e675686e4e9a1af4", "check_stack_p")
	review(between(state_src, "next_ci ::", "\n// Point the current frame"), "6891684d769392611bbb1d661f43019221ed501a2349e9d67272637a59295b9b", "next_ci")
	review(between(src, "vm_poll_async_hook ::", "// Only this activation"), "91ef210f2587374768791f00cc6dbdcd0ab10f9b4b4d88d968ce319c036f6003", "async poll")

	names: [dynamic]string
	opcode_list := between(opcode_src, "Op_Code :: enum u8 {", "\n}")
	for raw_line in strings.split(opcode_list, "\n") {
		line := strings.trim_space(raw_line)
		if line == "" {continue}
		name := before(line, ",")
		if len(name) == 0 {fail("empty opcode name")}
		for c in name {
			if !('A' <= c && c <= 'Z') && !('0' <= c && c <= '9') && c != '_' {fail("unexpected opcode name")}
		}
		append(&names, name)
	}
	if len(names) != 85 || names[len(names)-1] != "EXTRAARG" {fail("unexpected opcode enumeration")}

	vm := between(src, "vm_execute :: proc", "// Which immediate order")
	review(before(vm, "\tnewframe: for {\n"), "32340a8a21a1a481d09e46b3a7195ab3778645426030608202fd245973270fdc", "VM prelude")
	entry := between(vm, "\tnewframe: for {\n", "\n\t\t// The dispatch loop.")
	// The hook arm is split into its own tail transition below. Reject added
	// work in that arm until it has been reviewed for the split.
	review(entry, "fa18d5dad0483f6328d171fe8545a521cb65d0e56bf99ff3ba7f5c2779eaacd3", "VM entry")
	for name in ([]string{"base", "regs", "cl", "k", "code", "pc"}) {
		entry = replace_exact(entry, fmt.tprintf("%s :=", name), fmt.tprintf("%s =", name))
	}
	entry = replace_exact(entry, "trap: i32 = 0", "trap = 0")
	fetch := dedent(between(vm, "\t\tfor {\n", "\n\t\t\tswitch get_opcode(i)"))
	review(fetch, "59b67e0f54e7e8dbcf96b72d33f58742e0fac9cbb26c186a3ee00844a6beb67e", "VM fetch")
	trace := between(fetch, "if trap != 0 {\n", "\n}\n")
	cases := after(vm, "\t\t\tswitch get_opcode(i) {")
	parts := strings.split(cases, "\n\t\t\tcase .")
	if len(parts) != len(names) + 1 {fail("switch cases do not match opcode enumeration")}
	bodies := make([]string, len(names))
	for name, i in names {
		part := parts[i+1]
		if before(part, ":\n") != name {fail("switch case order does not match opcode enumeration")}
		body := after(part, ":\n")
		if i == len(names)-1 {
			body = before(body, "\n\t\t\t// Spell each unused")
		} else {
			body = fmt.tprintf("%s\n", body)
		}
		bodies[i] = body
	}
	for name, i in names {
		switch name {
		case "GETUPVAL":
			review(dedent(bodies[i]), "1399351ca0f3cfb5944946ee808d6f46a52e6e6fa120d28c9f7986ec600c467e", name)
		case "SETUPVAL":
			review(dedent(bodies[i]), "d8aabd0aa23242e61c456baa9df849155350805909c659141b91f482c0d7c764", name)
		case "GETTABUP":
			review(dedent(bodies[i]), "f138ebbf35d575849526c5754224da633e610e4c28a60c07d87c43ecba0673de", name)
		case "GETI":
			review(dedent(bodies[i]), "d0bd52a1b573b15681b81234a6e362ea7b8c18198102310f721c8387f50d92f9", name)
		case "SETTABUP":
			review(dedent(bodies[i]), "7eb8ea70cc4784d8da02246440e789cbc8583026e45ed7d6cf5fd7c58250f913", name)
		case "GETFIELD":
			review(dedent(bodies[i]), "cdf4b1f6108a044be29932cc666f802598309aaa05ba8ec5a4a788217309bc9c", name)
		case "GETTABLE":
			review(dedent(bodies[i]), "39e424fc0fd75088480a9c666127dbe3c61276c95fd545dfaa3fc87ad7f390ee", name)
		case "SETTABLE":
			review(dedent(bodies[i]), "e0f68192d60522d4f6fec4cef9ed4ef830f01d593f34ff16e3486ea754471c4f", name)
		case "SETI":
			review(dedent(bodies[i]), "8595bb869920097e3db285b89381b9b06515928cd886d33cd4605829975d9080", name)
		case "CONCAT":
			review(dedent(bodies[i]), "77a16174a48fbd411dcdc831220bf7e79b3c1bf6a6aa6215f52935f4d1882155", name)
		case "SELF":
			review(dedent(bodies[i]), "cd52f22d19525c1dac09131a29cb8f0f1af9627a36336f2fd0fe7fbc8ed61895", name)
		case "CALL":
			review(dedent(bodies[i]), "ac014f541316692f53230d3e9ae24623c87d0904ded4779d2f29ce46b5dbba86", name)
		case "LEN":
			review(dedent(bodies[i]), "7f7bee28051b7d9cab1c261a1f4f9a2a33a256d33e54e4d34adfdb9aa7026e75", name)
		case "FORPREP":
			review(dedent(bodies[i]), "bdf3f6be275b44b3ae6654ab10cbb945211f65c5a6073810ee350ef6fbba8407", name)
		case "MODK":
			review(dedent(bodies[i]), "c93f0decc3d4ee25a7587823c1051ba36e30113aa260f26dd7b811688965baf3", name)
		case "IDIVK":
			review(dedent(bodies[i]), "b344255899646c3cd43b21d4f1f309a452229977f0e0f224a7de6d8d5df8d7c0", name)
		case:
		}
	}
	edge_text := strings.builder_make()
	for name, i in names {
		poll := strings.contains(bodies[i], "vm_poll_async_hook(L, trap)")
		if poll != (is_edge(name) || name == "CALL" || name == "TAILCALL" || name == "RETURN") {
			fail("polling opcode set changed")
		}
		if is_edge(name) {
			fmt.sbprintf(&edge_text, "%s\n%s\n", name, strings.trim_space(dedent(bodies[i])))
		}
	}
	if digest(strings.to_string(edge_text)) != "c3951a1461ec1537a3069a5cd04912b710bc6af8606a02c872f539c15bdb98a6" {fail("edge-poll body changed")}
	invalid := between(cases, "Op_Code(125), Op_Code(126), Op_Code(127):\n", "\n\t\t\t}")
	if !strings.contains(invalid, "debug_runerror(L, \"invalid opcode\")") {fail("missing invalid opcode case")}

	next := "next_i := pc[0]\npc = vm_pc_add(pc, 1)\nreturn #must_tail vm_thread_table[int(get_opcode(next_i))](" + NEXT_ARGS + ")\n"
	dispatch := fmt.tprintf("if trap != 0 {{\n\treturn #must_tail vm_thread_trace(%s)\n}}\n%s", ARGS, next)
	b := strings.builder_make()
	strings.write_string(&b, MARKER)
	strings.write_string(&b, "// Do not edit this region; edit the switch and regenerate.\nwhen VM_THREADED {\n\t#assert(ODIN_ARCH == .amd64 || ODIN_ARCH == .arm64)\n")
	fmt.sbprintf(&b, "\tVM_Thread_Handler :: proc \"preserve/none\" %s\n\tvm_thread_table := [1 << SIZE_OP]VM_Thread_Handler{{\n", SIG)
	for name in names {fmt.sbprintf(&b, "\t\tvm_thread_%s,\n", name)}
	for _ in len(names)..<128 {strings.write_string(&b, "\t\tvm_thread_invalid,\n")}
	strings.write_string(&b, "\t}\n\n")
	entry = replace_exact(entry, `do_hookcall(L, ci_idx) // fire the 'call' hook now
					base = L.frames[ci_idx].func + 1
					regs = ([^]StackValue)(&L.stack[base])`, "return #must_tail vm_thread_enterhook(" + ARGS + ")")
	emit_proc(&b, "vm_thread_enter", fmt.tprintf("%s\n%s", dedent(entry), dispatch), true)
	// An inline Lua precall has initialized a fresh frame, has not called out
	// or moved either array, and already loaded the callee prototype. Its first
	// PC is zero and its trap is clear. Hooked calls take the ordinary entry.
	emit_proc(&b, "vm_thread_enternew", fmt.tprintf(`if L.hookmask != 0 {{
	return #must_tail vm_thread_enter(%s)
}}
base = L.frames[ci_idx].func + 1
regs = ([^]StackValue)(&L.stack[base])
cl = (^LClosure)(regs[-1].val.value_.gc)
pc = code
trap = 0
%s`, ARGS, next), true)
	emit_proc(&b, "vm_thread_enterhook", fmt.tprintf("%s\n%s", `do_hookcall(L, ci_idx)
base = L.frames[ci_idx].func + 1
regs = ([^]StackValue)(&L.stack[base])`, dispatch))
	emit_proc(&b, "vm_thread_trace", fmt.tprintf("%s\n%s", dedent(trace), next))
	emit_proc(&b, "vm_thread_poll", fmt.tprintf("trap = vm_apply_async_hook(L, trap)\n%s", dispatch))
	// Constant short-string global hits do not need a generic key dispatch or
	// ordinary-ABI callout. Preserve generic keys for unvalidated bytecode.
	emit_proc(&b, "vm_thread_gettabup_miss", fmt.tprintf("%s\n%s", `ra := base + getarg_A(i)
upval := upval_value(closure_upvals(cl)[getarg_B(i)])
rc := &k[getarg_C(i)]
trap = vm_thread_getslow(L, ci_idx, vm_pc_index(pc, code), upval, rc, ra, ctx)
`, dispatch), true)
	emit_proc(&b, "vm_thread_gettabup_generic", fmt.tprintf("%s\n%s", `upval := upval_value(closure_upvals(cl)[getarg_B(i)])
rc := &k[getarg_C(i)]
if !vm_thread_tryget(upval, rc, &regs[getarg_A(i)].val) {
	return #must_tail vm_thread_gettabup_miss(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
`, dispatch), true)
	// The hot GETTABLE handler tail-transitions to these cold paths, so the
	// ordinary ABI callouts cannot force it to spill the VM registers on hits.
	emit_proc(&b, "vm_thread_gettable_miss", fmt.tprintf("%s\n%s", `ra := base + getarg_A(i)
rb := &regs[getarg_B(i)].val
rc := &regs[getarg_C(i)].val
trap = vm_thread_getslow(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra, ctx)
`, dispatch), true)
	emit_proc(&b, "vm_thread_gettable_int", fmt.tprintf("%s\n%s", `rb := &regs[getarg_B(i)].val
rc := &regs[getarg_C(i)].val
if tag_is_empty(table_fastgeti((^Table)(rb.value_.gc), int_value(rc), &regs[getarg_A(i)].val)) {
	return #must_tail vm_thread_gettable_miss(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
`, dispatch), true)
	emit_proc(&b, "vm_thread_gettable_generic", fmt.tprintf("%s\n%s", `rb := &regs[getarg_B(i)].val
rc := &regs[getarg_C(i)].val
if tag_is_empty(table_get((^Table)(rb.value_.gc), rc, &regs[getarg_A(i)].val)) {
	return #must_tail vm_thread_gettable_miss(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
`, dispatch), true)
	emit_proc(&b, "vm_thread_geti_slow", fmt.tprintf("%s\n%s", `ra := base + getarg_A(i)
rb := &regs[getarg_B(i)].val
vm_geti(L, ci_idx, vm_pc_index(pc, code), rb, Integer(getarg_C(i)), ra)
trap = L.frames[ci_idx].u.l.trap
`, dispatch))
	emit_proc(&b, "vm_thread_seti_slow", fmt.tprintf("%s\n%s", `ra := &regs[getarg_A(i)].val
rc := &k[getarg_C(i)] if testarg_k(i) != 0 else &regs[getarg_C(i)].val
vm_seti(L, ci_idx, vm_pc_index(pc, code), ra, Integer(getarg_B(i)), rc)
trap = L.frames[ci_idx].u.l.trap
`, dispatch))
	emit_proc(&b, "vm_thread_seti_collect", fmt.tprintf("%s\n%s", `ra := &regs[getarg_A(i)].val
rc := &k[getarg_C(i)] if testarg_k(i) != 0 else &regs[getarg_C(i)].val
h := (^Table)(ra.value_.gc)
if (is_black(obj2gco(h)) && keepinvariant(L.g)) || table_fastseti(h, Integer(getarg_B(i)), rc) != HOK {
	return #must_tail vm_thread_seti_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
`, dispatch), true)
	// Keep ordinary ABI calls off the array and integer-hash write paths.
	emit_proc(&b, "vm_thread_settable_slow", fmt.tprintf("%s\n%s", `ra := &regs[getarg_A(i)].val
rb := &regs[getarg_B(i)].val
rc := &k[getarg_C(i)] if testarg_k(i) != 0 else &regs[getarg_C(i)].val
trap = vm_thread_setslow(L, ci_idx, vm_pc_index(pc, code), ra, rb, rc, ctx)
`, dispatch), true)
	emit_proc(&b, "vm_thread_settable_general", fmt.tprintf("%s\n%s", `ra := &regs[getarg_A(i)].val
rb := &regs[getarg_B(i)].val
rc := &k[getarg_C(i)] if testarg_k(i) != 0 else &regs[getarg_C(i)].val
#force_inline vm_settable(L, ci_idx, vm_pc_index(pc, code), ra, rb, rc)
trap = L.frames[ci_idx].u.l.trap
`, dispatch))
	emit_proc(&b, "vm_thread_settable_str", fmt.tprintf("%s\n%s", `ra := &regs[getarg_A(i)].val
rb := &regs[getarg_B(i)].val
rc := &k[getarg_C(i)] if testarg_k(i) != 0 else &regs[getarg_C(i)].val
if table_psetshortstr((^Table)(ra.value_.gc), str_value(rb), rc) != HOK {
	return #must_tail vm_thread_settable_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
`, dispatch), true)
	emit_proc(&b, "vm_thread_settable_collect", fmt.tprintf("%s\n%s", `ra := &regs[getarg_A(i)].val
rb := &regs[getarg_B(i)].val
rc := &k[getarg_C(i)] if testarg_k(i) != 0 else &regs[getarg_C(i)].val
h := (^Table)(ra.value_.gc)
if (is_black(obj2gco(h)) && keepinvariant(L.g)) || table_fastseti(h, int_value(rb), rc) != HOK {
	return #must_tail vm_thread_settable_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
`, dispatch), true)
	emit_proc(&b, "vm_thread_concat_meta_op", fmt.tprintf("%s\n%s", `ra := base + getarg_A(i)
L.top = ra + 2
L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
tm_tryconcatTM(L)
L.top -= 1
L.top = ra + 1
gc_checkGC(L)
trap = L.frames[ci_idx].u.l.trap
`, dispatch))
	transitions, returns := 0, 0
	for name, i in names {
		body := bodies[i]
		// The current closure travels with the threaded activation and is the
		// same non-moving object held in the function slot below regs. Avoid
		// reloading that slot in upvalue handlers; switch keeps vm_upvals.
		if name == "GETUPVAL" || name == "SETUPVAL" || name == "GETTABUP" || name == "SETTABUP" {
			body = replace_exact(body, "vm_upvals(regs)", "closure_upvals(cl)")
		}
		if name == "GETTABUP" || name == "GETFIELD" || name == "GETTABLE" || name == "SELF" {
			body = replace_exact(body, "thread_ctx := context", "_ = ctx")
			body = replace_exact(body, "ra, &thread_ctx)", "ra, ctx)")
		}
		if name == "GETTABUP" {
			body = `upval := upval_value(closure_upvals(cl)[getarg_B(i)])
rc := &k[getarg_C(i)]
if base_type(upval) != TTABLE {
	return #must_tail vm_thread_gettabup_miss(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
if type_tag(rc) != VSHRSTR {
	return #must_tail vm_thread_gettabup_generic(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
if tag_is_empty(table_getshortstr((^Table)(upval.value_.gc), str_value(rc), &regs[getarg_A(i)].val)) {
	return #must_tail vm_thread_gettabup_miss(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
`
		}
		// Only array and short-string hits stay in this handler. The array
		// range check leaves integer hash lookups for the complete cold path.
		// On a known empty slot, do not repeat the lookup before finishget.
		if name == "GETTABLE" {
			body = `rb := &regs[getarg_B(i)].val
rc := &regs[getarg_C(i)].val
if base_type(rb) != TTABLE {
	return #must_tail vm_thread_gettable_miss(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
h := (^Table)(rb.value_.gc)
if is_integer(rc) {
	key := int_value(rc)
	if Unsigned(key) - 1 >= Unsigned(h.asize) {
		return #must_tail vm_thread_gettable_int(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}
	if tag_is_empty(table_fastgeti(h, key, &regs[getarg_A(i)].val)) {
		return #must_tail vm_thread_gettable_miss(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}
} else if type_tag(rc) == VSHRSTR {
	if tag_is_empty(table_fastget(h, rc, &regs[getarg_A(i)].val)) {
		return #must_tail vm_thread_gettable_miss(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}
} else {
	return #must_tail vm_thread_gettable_generic(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
`
		}
		if name == "GETI" {
			body = `rb := &regs[getarg_B(i)].val
if base_type(rb) != TTABLE || tag_is_empty(table_fastgeti((^Table)(rb.value_.gc), Integer(getarg_C(i)), &regs[getarg_A(i)].val)) {
	return #must_tail vm_thread_geti_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
`
		}
		if name == "SETTABLE" {
			body = `ra := &regs[getarg_A(i)].val
rb := &regs[getarg_B(i)].val
rc := &k[getarg_C(i)] if testarg_k(i) != 0 else &regs[getarg_C(i)].val
if base_type(ra) != TTABLE {
	return #must_tail vm_thread_settable_general(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
if is_collectable(rc) {
	if is_integer(rb) {
		return #must_tail vm_thread_settable_collect(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}
	return #must_tail vm_thread_settable_general(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
if !is_integer(rb) {
	if type_tag(rb) == VSHRSTR {
		return #must_tail vm_thread_settable_str(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}
	return #must_tail vm_thread_settable_general(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
h := (^Table)(ra.value_.gc)
key := int_value(rb)
if Unsigned(key) - 1 >= Unsigned(h.asize) {
	if table_psetint(h, key, rc) != HOK {
		return #must_tail vm_thread_settable_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}
} else if table_fastseti(h, key, rc) != HOK {
	return #must_tail vm_thread_settable_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
`
		}
		if name == "SETI" {
			body = `ra := &regs[getarg_A(i)].val
rc := &k[getarg_C(i)] if testarg_k(i) != 0 else &regs[getarg_C(i)].val
if base_type(ra) != TTABLE {
	return #must_tail vm_thread_seti_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
if is_collectable(rc) {
	return #must_tail vm_thread_seti_collect(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
if table_fastseti((^Table)(ra.value_.gc), Integer(getarg_B(i)), rc) != HOK {
	return #must_tail vm_thread_seti_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}
`
		}
		if name == "CALL" {
			body = replace_exact(body, "thread_ctx := context", "_ = ctx")
			body = replace_exact(body, "nresults, &thread_ctx)", "nresults, ctx)")
			body = replace_exact(body, "trap = vm_poll_async_hook(L, trap)", "when ODIN_OS != .Freestanding {\n\tif intrinsics.atomic_load(&async_hook_pending) != 0 {\n\t\ttrap = vm_thread_pollcall(L, trap, ctx)\n\t}\n}")
		}
		if name == "LEN" {
			body = `ra := base + getarg_A(i)
L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
L.top = L.frames[ci_idx].top
rb := &regs[getarg_B(i)].val
if is_string(rb) {
	set_int(&regs[getarg_A(i)].val, Integer(str_value(rb).len))
} else {
	vm_thread_lenslow(L, ra, rb, ctx)
}
trap = L.frames[ci_idx].u.l.trap
`
		}
		if name == "CONCAT" {
			body = replace_exact(body, "vm_concat(L, n)", "vm_thread_concat_run(L, n, ctx)")
			body = replace_exact(body, "gc_checkGC(L)", "if L.g.gc_debt <= 0 {vm_thread_concat_gc(L, ctx)}")
			body = fmt.tprintf("%s%s", `if getarg_B(i) == 2 {
	a := getarg_A(i)
	left := &regs[a].val
	right := &regs[a + 1].val
	if !(is_string(left) || is_number(left)) || !(is_string(right) || is_number(right)) {
		return #must_tail vm_thread_concat_meta_op(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}
}
`, body)
		}
		// Fetch the integer loop's next instruction before the register updates.
		// The running activation's code is immutable; a poll or trace discards
		// this read and fetches again through the ordinary path.
		if name == "FORLOOP" {
			body = dedent(body)
			body = replace_exact(body, `if count > 0 {
		step := int_value(&regs[ra + 1].val)
		idx := int_value(&regs[ra + 2].val)
		set_int(&regs[ra].val, u2s(count - 1)) // decrement counter
		set_int(&regs[ra + 2].val, int_add(idx, step)) // advance control
		pc = vm_pc_add(pc, -(getarg_Bx(i))) // jump back
		trap = vm_poll_async_hook(L, trap)
	}`, `if count > 0 {
		target := vm_pc_add(pc, -(getarg_Bx(i)))
		next_i := target[0]
		step := int_value(&regs[ra + 1].val)
		idx := int_value(&regs[ra + 2].val)
		set_int(&regs[ra].val, u2s(count - 1))
		set_int(&regs[ra + 2].val, int_add(idx, step))
		pc = target
		when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}`)
		}
		if name == "MODK" || name == "IDIVK" {
			body = replace_exact(body, "vm_arith(", "vm_thread_arith(")
			if name == "MODK" {
				body = replace_exact(body, `debug_runerror(L, "attempt to perform 'n%%0'")`, "vm_thread_aritherror(L, ctx, true)")
			} else {
				body = replace_exact(body, `debug_runerror(L, "attempt to divide by zero")`, "vm_thread_aritherror(L, ctx, false)")
			}
		}
		transitions += strings.count(body, "continue newframe")
		body, _ = strings.replace_all(body, "continue newframe", "return #must_tail vm_thread_enter(" + ARGS + ")")
		body = rewrite_returns(body, &returns)
		if name != "CALL" && name != "TAILCALL" && name != "RETURN" && name != "RETURN0" && name != "RETURN1" {
			body, _ = strings.replace_all(body, "trap = vm_poll_async_hook(L, trap)", "when ODIN_OS != .Freestanding {\n\tif intrinsics.atomic_load(&async_hook_pending) != 0 {\n\t\treturn #must_tail vm_thread_poll(" + ARGS + ")\n\t}\n}")
		}
		if name == "RETURN0" || name == "RETURN1" {
			body = replace_exact(body, "trap = vm_poll_async_hook(L, trap)", "when ODIN_OS != .Freestanding {\n\tif intrinsics.atomic_load(&async_hook_pending) != 0 {\n\t\tcontext = ctx^\n\t\ttrap = vm_apply_async_hook(L, trap)\n\t}\n}")
			body = replace_exact(body, "do_poscall(L, ci_idx, ", "context = ctx^\n\t\t\t\t\tdo_poscall(L, ci_idx, ")
		}
		terminal := strings.has_suffix(strings.trim_right_space(body), "return #must_tail vm_thread_enter(" + ARGS + ")")
		body = fmt.tprintf("%s\n", dedent(body))
		// Keep the hook and async-poll callouts out of the ordinary return
		// handlers. Their complete switch-derived bodies remain on the slow
		// path; the no-hook arms below must mirror those bodies exactly.
		if name == "RETURN0" || name == "RETURN1" {
			emit_proc(&b, fmt.tprintf("vm_thread_%s_slow", name), body, true)
			prefix := fmt.tprintf(`when ODIN_OS != .Freestanding {{
	if intrinsics.atomic_load(&async_hook_pending) != 0 {{
		return #must_tail vm_thread_%s_slow(%s)
	}}
}}
if L.hookmask != 0 {{
	return #must_tail vm_thread_%s_slow(%s)
}}
callstatus := L.frames[ci_idx].callstatus
nres := get_nresults(callstatus)
L.ci = ci_idx - 1
`, name, ARGS, name, ARGS)
			if name == "RETURN0" {
				body = fmt.tprintf("%s%s", prefix, `L.top = base - 1
for nres > 0 {
	set_nil(stack_value(L, L.top))
	L.top += 1
	nres -= 1
}
`)
			} else {
				body = fmt.tprintf("%s%s", prefix, `if nres == 0 {
	L.top = base - 1
} else {
	set_obj(&regs[-1].val, &regs[getarg_A(i)].val)
	L.top = base
	for nres > 1 {
		set_nil(stack_value(L, L.top))
		L.top += 1
		nres -= 1
	}
}
`)
			}
			body = fmt.tprintf(`%sif (callstatus & CIST_FRESH) != 0 {{
	return 0
}}
ci_idx -= 1
return #must_tail vm_thread_enter(%s)
`, body, ARGS)
		}
		// Keep all ABI callouts out of the ordinary Lua-to-Lua call path.
		// The slow handler is the complete switch-derived body. The fast arm
		// checks everything before publishing any part of the new frame.
		if name == "CALL" {
			emit_proc(&b, "vm_thread_CALL_slow", fmt.tprintf("%s%s", body, dispatch), true)
			emit_proc(&b, "vm_thread_CALL_precalled", fmt.tprintf(`ra := base + getarg_A(i)
nresults := getarg_C(i) - 1
newci := vm_thread_precall(L, ra, nresults, ctx)
if newci >= 0 {{
	ci_idx = newci
	return #must_tail vm_thread_enter(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
}}
trap = L.frames[ci_idx].u.l.trap
%s`, dispatch), true)
			// These transitions borrow the frame-index argument for the function
			// slot. Capture the caller's index before the native call and resolve
			// the frame again afterward: hooks and callbacks may move the array.
			// Yields do not return here.
			for variant in ([]string{"lcf", "ccl"}) {
				f := "callee.value_.f"
				if variant == "ccl" {f = "(^CClosure)(callee.value_.gc).f"}
				emit_proc(&b, fmt.tprintf("vm_thread_CALL_%s", variant), fmt.tprintf(`func := ci_idx
callee := &regs[getarg_A(i)].val
ci_idx = L.ci
_ = vm_thread_native_try(L, func, getarg_C(i), %s, ctx)
trap = L.frames[ci_idx].u.l.trap
%s`, f, dispatch), true)
			}
			body = `when HARDSTACKTESTS {
	return #must_tail vm_thread_CALL_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
} else {
	when ODIN_OS != .Freestanding {
		if intrinsics.atomic_load(&async_hook_pending) != 0 {
			return #must_tail vm_thread_CALL_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
	}
	a := getarg_A(i)
	ra := base + a
	b := getarg_B(i)
	top := L.top
	if b != 0 {
		top = ra + b
		L.top = top
	}
	L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
	callee := &regs[a].val
	tag := type_tag(callee)
	if tag == VLCF {
		return #must_tail vm_thread_CALL_lcf(L, pc, regs, cl, code, ra, trap, ctx, i)
	}
	if tag == VCCL {
		return #must_tail vm_thread_CALL_ccl(L, pc, regs, cl, code, ra, trap, ctx, i)
	}
	if tag != VLCL {
		return #must_tail vm_thread_CALL_precalled(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}
	p := (^LClosure)(callee.value_.gc).p
	fsize := int(p.maxstacksize)
	next := L.ci + 1
	if L.stack_size - top <= fsize || next >= L.frames_capacity {
		return #must_tail vm_thread_CALL_precalled(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}
	L.ci = next
	ci := &L.frames[next]
	ci.func = ra
	ci.callstatus = u32(getarg_C(i))
	ci.top = ra + 1 + fsize
	ci.u.l.savedpc = 0
	ci.u.l.nextraargs = 0
	ci.u.l.trap = 0
	end := ra + 1 + int(p.numparams)
	if top < end {
		for top < end {
			set_nil(stack_value(L, top))
			top += 1
		}
		L.top = top
	}
	ci_idx = next
	return #must_tail vm_thread_enternew(L, pc, regs, cl, p.code, ci_idx, trap, ctx, i)
}
`
			terminal = true
		}
		if !terminal {body = fmt.tprintf("%s%s", body, dispatch)}
		emit_proc(&b, fmt.tprintf("vm_thread_%s", name), body, name == "RETURN0" || name == "RETURN1" || name == "GETTABUP" || name == "GETFIELD" || name == "GETTABLE" || name == "GETI" || name == "SETTABLE" || name == "SETI" || name == "SELF" || name == "CALL" || name == "LEN" || name == "CONCAT" || name == "MODK" || name == "IDIVK")
	}
	if transitions != 6 || returns != 4 {fail(fmt.tprintf("unexpected frame transitions: %d, returns: %d", transitions, returns))}
	emit_proc(&b, "vm_thread_invalid", fmt.tprintf("%s\n%s", dedent(invalid), dispatch))
	strings.write_string(&b, "}\n// END GENERATED THREADED VM\n")
	return strings.to_string(b)
}

main :: proc() {
	if len(os.args) < 2 || len(os.args) > 3 || (len(os.args) == 3 && os.args[2] != "--check") {
		fail("usage: generate_threaded <repository-root> [--check]")
	}
	root := os.args[1]
	path := fmt.tprintf("%s/src/kernel/vm.odin", root)
	whole := read_text(path)
	src := before(whole, MARKER)
	generated := generate(
		src,
		read_text(fmt.tprintf("%s/src/kernel/opcodes.odin", root)),
		read_text(fmt.tprintf("%s/src/kernel/do.odin", root)),
		read_text(fmt.tprintf("%s/src/kernel/state.odin", root)),
		read_text(fmt.tprintf("%s/src/kernel/tm.odin", root)),
		read_text(fmt.tprintf("%s/src/kernel/table.odin", root)),
		read_text(fmt.tprintf("%s/src/kernel/gc.odin", root)),
		read_text(fmt.tprintf("%s/src/kernel/string.odin", root)),
		read_text(fmt.tprintf("%s/src/kernel/mem.odin", root)),
		read_text(fmt.tprintf("%s/src/kernel/gc_run.odin", root)),
	)
	result := fmt.tprintf("%s%s", src, generated)
	if len(os.args) == 3 {
		if whole != result {fail("threaded VM is stale; run the generator without --check")}
	} else if err := os.write_entire_file(path, result); err != nil {
		fail(fmt.tprintf("cannot write %s: %v", path, err))
	}
}
