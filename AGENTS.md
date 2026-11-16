# Working in this repository

lua-odin reimplements Lua 5.5.1 in standard-library-only Odin. Correctness comes
first: the vendored PUC-Rio suite and the unit tests are the oracle, and a
performance change that weakens either is not a change we want. Start with
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the kernel works and
[docs/FUTURE_WORK.md](docs/FUTURE_WORK.md) for what is open, planned and already
tried. [HANDOFF.md](HANDOFF.md), when present, says where the last session left
off.

## Build, test, generate

- Scripts live in `build/`; run them with `bash` from the repo root.
  [BUILDING.md](BUILDING.md) has every option.
- `VM_THREADED` selects the interpreter: unset means the default (threaded on
  amd64/arm64), `1` threaded, `0` switch.
- The switch opcode bodies in `src/kernel/vm.odin` generate the threaded
  handlers. After changing an opcode body, or a helper a threaded specialization
  mirrors, run `bash build/generate-threaded.sh` and commit the regenerated
  region with the change. If the generator reports that a guarded body changed,
  review the threaded specialization against it before updating its hash.
- Threaded-only code belongs in `vm_threaded_fast.odin` or
  `vm_threaded_concat.odin`, not in `vm.odin`, whose layout affects the switch.

## Gates

Run these before merging anything that touches `src/kernel` or the generator,
in **both** interpreters (`VM_THREADED` unset and `=0`), one heavy job at a time:

```sh
bash build/check.sh                       # must print no warnings
bash build/test.sh                        # also with --stress, --asan, --stress --asan
bash build/puc.sh                         # also STRESS=1, ASAN=1, STRESS=1 ASAN=1;
                                          # each must end with "final OK !!!"
REFLUAC=/path/to/luac bash build/clitest.sh
bash build/rebrand-smoke.sh
bash build/build.sh all && bash build/build.sh freestanding
```

For changes confined to `src/stdlib` or `src/stream`, run the full list with
`VM_THREADED` unset, plus check, plain and stress+ASan tests, and plain and
stress+ASan PUC with `VM_THREADED=0`. Every commit must at least pass
`build/check.sh` and `build/test.sh` in both interpreters. Windows code must keep
type-checking (`build/check.sh` covers it) even though it cannot be run here.

## Measuring

- **Instruction counts decide**: `perf stat -e instructions:u`, callgrind, and
  `REFLUA=<reference lua> CPU=<idle core> bash build/vm-compare.sh 5`. Cycle
  figures from a shared or loaded machine are approximate; label them so and do
  not base a decision on a small cycle difference.
- Hash seeds, GC, environment layout and I/O vary some counts; compare
  distributions over several runs for those.
- Reference is Lua 5.5.1 from <https://www.lua.org/ftp/>, built with `make`. A
  second copy built with `make MYCFLAGS=-g` gives callgrind function names.
- Before proposing an optimization, check the dead ends in
  [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md#dead-ends). Record new ones there,
  with numbers.

## Invariants that are easy to break

- The rules every threaded specialization follows, in
  [ARCHITECTURE.md](docs/ARCHITECTURE.md#tail-call-threaded-dispatch): contextless
  hits never allocate, re-enter Lua or move a stack; misses get the original
  context; stores skip a barrier only when it would do nothing; slots are
  re-resolved after anything that can collect.
- `longjmp` skips `defer`: never free a raw allocation in a `defer` a throw can
  cross (Decision 2).
- Persistent references to stack slots or frames are indices, never pointers
  (Decision 3).
- A native callback may skip building a Context only when its fast path calls
  only contextless code (Native callbacks and the embedding API).
- `CLOSURE` keeps its upvalue barrier.
- The PUC-Rio suite under `tests/puc` is never modified.

## Workflow

- One branch per task, each in its own git worktree with its own `TMPDIR`
  (`build/bench.sh`, `build/vm-compare.sh` and `build/rebrand-smoke.sh` write
  there). Never build or commit in another task's worktree.
- Commit small and often: one logical change per commit, each one passing the
  per-commit checks above. Never commit build output.
- Commit messages: `area: lowercase summary` (`vm:`, `api:`, `os:`, `io:`,
  `string:`, `docs:`, `bench:`, `build:`, `tests:`...), then a wrapped body saying
  why, with before/after instruction counts for performance work, and the same
  `Co-authored-by` trailer as recent commits.
- Keep `docs/ARCHITECTURE.md` accurate for the code you change, in its own docs
  commit. Update `docs/FUTURE_WORK.md` when a gap closes or a lever fails.
- Before merging, rebase onto `master`, regenerate the threaded region if it
  conflicts, and rerun the gates. When done, remove the worktree and temporary
  files and kill anything you started.
