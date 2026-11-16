# Plans

Detailed analyses behind the work packages in
[../FUTURE_WORK.md](../FUTURE_WORK.md), one per area, written in November 2026
against master `0738e32`. Each gives fresh measurements against reference Lua
5.5.1, where the instructions go, ranked levers with measured or estimated gains,
and agent-sized work packages with acceptance targets.

They are working notes, not maintained documentation: delete or update a plan as
its packages land. Paths such as `/tmp/opencode/refbuild/src/lua` and
`/tmp/opencode/refdbg/src/lua` refer to the reference builds on the machine the
analysis ran on; build your own as [AGENTS.md](../../AGENTS.md) describes.
Prototype numbers come from throwaway scratch builds that did not run the full
gates.

| Plan | Area |
|---|---|
| [calls.md](calls.md) | Calls, returns, closures, metamethod and native calls |
| [loops-arith.md](loops-arith.md) | The dispatch sequence, arithmetic handlers, numeric loops |
| [tables-globals.md](tables-globals.md) | Global, field, array and length access |
| [strings-gc.md](strings-gc.md) | Peak heap, collector pacing, external strings, string layout |
| [os-io.md](os-io.md) | `os.getenv`, `os.time`, stream locality and locking |
| [patterns.md](patterns.md) | `string.find`/`match`/`gmatch`/`gsub`; probes in [patterns-probes.lua](patterns-probes.lua) |
| [correctness-tz.md](correctness-tz.md) | Local time against glibc; corpus in [tz-corpus.lua](tz-corpus.lua) |
| [validation.md](validation.md) | Linux arm64 under QEMU, native CI draft, measurement protocol, 32-bit and BSD |
