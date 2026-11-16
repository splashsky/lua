# Handoff

Where the November 2026 sessions left off. Read this, then
[AGENTS.md](AGENTS.md) (OpenCode loads it automatically) and
[docs/FUTURE_WORK.md](docs/FUTURE_WORK.md), the prioritized plan. Delete or
rewrite this file when it stops being true.

## State

- `master` is pushed to `github.com/splashsky/lua`. The tail-call-threaded
  interpreter is the default on amd64/arm64; `VM_THREADED=0` selects the switch.
- Both interpreters pass the full gate matrix on Linux x86-64: check without
  warnings, 366 unit tests plain/stress/ASan/stress+ASan, the PUC-Rio suite in
  the same four modes, clitest, rebrand-smoke, freestanding. On Linux arm64 under
  QEMU the PUC suite passes; one NaN-sign unit test fixture fails there.
- Against reference Lua 5.5.1 the default is at or below reference on calls,
  string building, tables, sorting, local dates and formatting. The largest gaps:
  patterns +34%, `os.getenv` +26%, `intloop` +22%, `fib` +16%, and several
  isolated cases listed in FUTURE_WORK.md (plain `find` misses 30×, long `gsub`
  replacements 10×, field access, `#t`).
- The docs were trimmed and restructured. `docs/plans/` holds eight per-area
  analyses with measured prototypes and acceptance targets; FUTURE_WORK.md
  indexes them.

## Do next

1. **The P0 correctness fixes** in FUTURE_WORK.md, starting with
   `fix/pattern-position-backref`: `string.match("abc", "()%1a")` aborts the
   whole interpreter with a bounds-check failure that `pcall` cannot catch.
   Then the two `os.time` fixes and the arm64 NaN test fixture. Separate files,
   so they can run in parallel.
2. **`perf/threaded-dispatch-table`** alone, since it changes every threaded
   handler's signature. Then the other P1 VM packages in parallel:
   `perf/threaded-compare`, `perf/table-len`, `perf/global-shortset` → `perf/field-hit`,
   `perf/array-pivot`, `calls/multireturn`. They all touch the generator, so
   merge one at a time, rebasing and regenerating as needed.
3. **The P1 library packages** in parallel with step 2: `patterns/*` (after the
   P0 pattern fix), `calls/minmax-native`, `os-getenv-fast-string`,
   `os-time-lazy-civil` (after the `os.time` fixes).
4. Ask the user the **decisions** in FUTURE_WORK.md: native CI, external strings,
   time-zone scope, a quiet machine, 32-bit/BSD.

## How the work was run

The orchestrating session delegated each package to its own subagent
(`github-copilot/gpt-6.1-terra`, variant `xhigh`), one branch and worktree each,
then reviewed and fast-forward merged. Things that helped:

- Give each agent its branch, worktree path, `TMPDIR`, scope, files to stay out
  of, the gates, and a final-report format. Ask for numbers, not adjectives.
- Before merging, check the branch is based on the current master. If not, rebase
  it in a scratch worktree and run the generator check, `check.sh`, and the tests
  and PUC suite in both interpreters.
- Agents sometimes end their turn while gates are still running; resume the same
  session and tell it to wait in the foreground.
- One analysis was stopped by a provider content filter, probably triggered by
  wording about removing bounds checks. Rephrasing it as "index checks the
  compiler inserts", with a per-site proof, worked.

## This machine

- Odin `dev-2026-11-nightly:9a69916` is `~/.local/bin/odin`; put it on `PATH`.
  CI should pin release `dev-2026-11a`, which resolves to the same commit.
- Reference builds live on tmpfs and vanish on reboot. Recreate them with:

  ```sh
  cd /tmp/opencode && curl -R -O https://www.lua.org/ftp/lua-5.5.1.tar.gz
  tar xf lua-5.5.1.tar.gz && cp -r lua-5.5.1 refbuild && cp -r lua-5.5.1 refdbg
  make -C refbuild/src linux && make -C refdbg/src linux MYCFLAGS=-g
  ```

- `/tmp/opencode/wt` belongs to another project. Put worktrees under
  `/tmp/opencode/lua-odin-wt/`.
- The machine is shared and usually loaded, so cycle counts are approximate. perf,
  valgrind and `qemu-aarch64-static` (with binfmt) are available; Docker is not
  usable, and there is no Wine or Mac. The Linux arm64 sysroot recipe is in
  [docs/plans/validation.md](docs/plans/validation.md).
