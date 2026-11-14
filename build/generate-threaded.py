#!/usr/bin/env python3
"""Generate the experimental threaded VM from vm_execute's switch bodies.

Run with --check to verify that the generated region is current. The script
deliberately rejects unexpected source shapes instead of silently omitting an
opcode or changing a frame transition.
"""

import argparse
import hashlib
import re
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VM = ROOT / "src/kernel/vm.odin"
OPCODES = ROOT / "src/kernel/opcodes.odin"
MARKER = "// BEGIN GENERATED THREADED VM -- build/generate-threaded.py\n"

# The edge-poll rewrite can only skip to the next fetch when the poll is the
# last action on that path. RETURN0/RETURN1 also have scoped-context rewrites.
# Re-review these bodies before updating the digest; blind regeneration must not
# silently skip newly added work.
EDGE_OPS = {"JMP", "EQ", "LT", "LE", "EQK", "EQI", "LTI", "LEI", "GTI", "GEI",
            "TEST", "TESTSET", "RETURN0", "RETURN1", "FORLOOP", "TFORLOOP"}
EDGE_DIGEST = "df280857be3ce46c7cff5070c0d712050786179e155e71585e4e43854f0c8fdd"
# Entry and fetch are rewritten rather than copied as complete blocks. Changes
# to either must likewise be reviewed before accepting a new digest.
PRELUDE_DIGEST = "f492f3af1b9bcde1ac94d5070d899dad090bd005b88f39938bb2708bbdff9c35"
FETCH_DIGEST = "59b67e0f54e7e8dbcf96b72d33f58742e0fac9cbb26c186a3ee00844a6beb67e"
POLL_DIGEST = "91ef210f2587374768791f00cc6dbdcd0ab10f9b4b4d88d968ce319c036f6003"


def digest(text):
    return hashlib.sha256(text.strip().encode("utf-8")).hexdigest()


def only_replace(text, old, new, count=1):
    actual = text.count(old)
    if actual != count:
        raise ValueError(f"expected {count} occurrences of {old!r}, got {actual}")
    return text.replace(old, new)


def indent(text):
    return textwrap.indent(textwrap.dedent(text).strip("\n"), "\t\t") + "\n"


def generate(src):
    poll = src.split("vm_poll_async_hook ::", 1)[1].split("// Only this activation", 1)[0]
    if digest(poll) != POLL_DIGEST:
        raise ValueError("async poll changed; review threaded polling and update POLL_DIGEST")
    enum = OPCODES.read_text(encoding="utf-8").split("Op_Code :: enum u8 {", 1)[1].split("\n}", 1)[0]
    names = re.findall(r"^\s*([A-Z][A-Z0-9_]*)\s*,", enum, re.MULTILINE)
    if len(names) != 85 or names[-1] != "EXTRAARG":
        raise ValueError("unexpected opcode enumeration; update generator and invalid table")
    vm = src.split("vm_execute :: proc", 1)[1].split("// Which immediate order", 1)[0]
    prelude = vm.split("\tnewframe: for {\n", 1)[0]
    if digest(prelude) != PRELUDE_DIGEST:
        raise ValueError("VM prelude changed; review threaded entry and update PRELUDE_DIGEST")
    entry = vm.split("\tnewframe: for {\n", 1)[1].split("\n\t\t// The dispatch loop.", 1)[0]
    for name in ("base", "regs", "cl", "k", "code", "pc"):
        entry = only_replace(entry, name + " :=", name + " =")
    entry = only_replace(entry, "trap: i32 = 0", "trap = 0")
    fetch = vm.split("\t\tfor {\n", 1)[1].split("\n\t\t\tswitch get_opcode(i)", 1)[0]
    fetch = textwrap.dedent(fetch)
    if digest(fetch) != FETCH_DIGEST:
        raise ValueError("VM fetch changed; review threaded fetch and update FETCH_DIGEST")
    trace = fetch.split("if trap != 0 {\n", 1)[1].split("\n}\n", 1)[0]
    cases = vm.split("\t\t\tswitch get_opcode(i) {", 1)[1]
    matches = list(re.finditer(r"^\t\t\tcase \.([A-Z0-9_]+):\n", cases, re.MULTILINE))
    if [m.group(1) for m in matches] != names:
        raise ValueError("switch cases do not match opcode enumeration")
    bodies = {}
    for i, match in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else cases.index("\n\t\t\t// Spell each unused", match.end())
        bodies[match.group(1)] = cases[match.end():end]
    poll_ops = {name for name, body in bodies.items() if "vm_poll_async_hook(L, trap)" in body}
    if poll_ops != EDGE_OPS | {"CALL", "TAILCALL", "RETURN"}:
        raise ValueError("polling opcode set changed; review threaded edge-poll handling")
    edge_text = "".join(name + "\n" + textwrap.dedent(bodies[name]).strip() + "\n"
                        for name in names if name in EDGE_OPS)
    if hashlib.sha256(edge_text.encode()).hexdigest() != EDGE_DIGEST:
        raise ValueError("edge-poll body changed; review the rewrite and update EDGE_DIGEST")
    invalid = cases.split("Op_Code(125), Op_Code(126), Op_Code(127):\n", 1)[1].split("\n\t\t\t}", 1)[0]
    if "debug_runerror(L, \"invalid opcode\")" not in invalid:
        raise ValueError("missing invalid opcode case")

    sig = ("(L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, "
           "cl_arg: ^LClosure, k_arg: [^]TValue, code_arg: [^]Instruction, "
           "ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32")
    args = "L, pc, regs, cl, k, code, ci_idx, trap, ctx, i"
    next_args = "L, pc, regs, cl, k, code, ci_idx, trap, ctx, next_i"
    locals_ = """context = ctx^
pc := pc_arg
regs := regs_arg
cl := cl_arg
k := k_arg
code := code_arg
base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
ci_idx := ci_idx_arg
trap := trap_arg
i := i_arg
_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
"""
    dispatch_no_trace = "next_i := pc[0]\npc = vm_pc_add(pc, 1)\nreturn #must_tail vm_thread_table[int(get_opcode(next_i))](" + next_args + ")\n"
    dispatch = "if trap != 0 {\n\treturn #must_tail vm_thread_trace(" + args + ")\n}\n" + dispatch_no_trace
    out = [MARKER, "// Do not edit this region; edit the switch and regenerate.\n",
           "when VM_THREADED {\n",
           "\t#assert(ODIN_ARCH == .amd64 || ODIN_ARCH == .arm64)\n",
           "\tVM_Thread_Handler :: proc \"preserve/none\" " + sig + "\n",
           "\tvm_thread_table := [1 << SIZE_OP]VM_Thread_Handler{\n"]
    out.extend("\t\tvm_thread_" + name + ",\n" for name in names)
    out.extend("\t\tvm_thread_invalid,\n" for _ in range(128 - len(names)))
    out.append("\t}\n\n")

    def proc(name, body, scoped_context=False):
        noinline = "#force_no_inline " if name in ("vm_thread_enter", "vm_thread_trace", "vm_thread_poll") else ""
        out.append("\t" + name + " :: " + noinline + "proc \"preserve/none\" " + sig + " {\n")
        out.append(indent(locals_.replace("context = ctx^\n", "") if scoped_context else locals_))
        out.append(indent(body))
        out.append("\t}\n\n")

    entry = only_replace(entry, "do_hookcall(L, ci_idx)", "context = ctx^\n\t\t\t\t\tdo_hookcall(L, ci_idx)")
    proc("vm_thread_enter", textwrap.dedent(entry) + "\n" + dispatch, scoped_context=True)
    proc("vm_thread_trace", textwrap.dedent(trace) + "\n" + dispatch_no_trace)
    proc("vm_thread_poll", "trap = vm_apply_async_hook(L, trap)\n" + dispatch)
    transitions = 0
    fresh_returns = 0
    for name in names:
        body = bodies[name]
        transitions += body.count("continue newframe")
        body = body.replace("continue newframe", "return #must_tail vm_thread_enter(" + args + ")")
        fresh_returns += len(re.findall(r"^\s*return\s*$", body, re.MULTILINE))
        body = re.sub(r"^(\s*)return\s*$", r"\1return 0", body, flags=re.MULTILINE)
        # These edge polls are the last action before the next fetch. Keep the
        # ordinary path contextless; the slow handler applies the request and
        # then fetches. Call and return opcodes have work after their poll and
        # therefore retain the original call in place.
        if name not in ("CALL", "TAILCALL", "RETURN", "RETURN0", "RETURN1"):
            body = body.replace("trap = vm_poll_async_hook(L, trap)",
                                "when ODIN_OS != .Freestanding {\n"
                                "\tif intrinsics.atomic_load(&async_hook_pending) != 0 {\n"
                                "\t\treturn #must_tail vm_thread_poll(" + args + ")\n"
                                "\t}\n}")
        if name in ("RETURN0", "RETURN1"):
            body = only_replace(body, "trap = vm_poll_async_hook(L, trap)",
                                "when ODIN_OS != .Freestanding {\n"
                                "\tif intrinsics.atomic_load(&async_hook_pending) != 0 {\n"
                                "\t\tcontext = ctx^\n"
                                "\t\ttrap = vm_apply_async_hook(L, trap)\n"
                                "\t}\n}")
            body = only_replace(body, "do_poscall(L, ci_idx, ", "context = ctx^\n\t\t\t\t\tdo_poscall(L, ci_idx, ")
        terminal = body.rstrip().endswith("return #must_tail vm_thread_enter(" + args + ")")
        proc("vm_thread_" + name, textwrap.dedent(body) + ("\n" if terminal else "\n" + dispatch),
             scoped_context=name in ("RETURN0", "RETURN1"))
    if transitions != 6 or fresh_returns != 4:
        raise ValueError(f"unexpected frame transitions: {transitions}, returns: {fresh_returns}")
    proc("vm_thread_invalid", textwrap.dedent(invalid) + "\n" + dispatch)
    out.append("}\n// END GENERATED THREADED VM\n")
    return "".join(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = VM.read_text(encoding="utf-8").split(MARKER, 1)[0]
    result = source + generate(source)
    if args.check:
        if VM.read_text(encoding="utf-8") != result:
            raise SystemExit("threaded VM is stale; run python3 build/generate-threaded.py")
    else:
        VM.write_text(result, encoding="utf-8")


if __name__ == "__main__":
    main()
