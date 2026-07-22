# tests/puc -- vendored PUC-Rio Lua 5.5 test suite

This directory will hold the **official PUC-Rio Lua 5.5 test suite**, vendored
verbatim, plus the Odin runner that drives it against our implementation.

It is currently empty on purpose: the suite is added in **Phase 10**, once the
kernel, standard library, and the standalone `lua` CLI exist to run it. The suite
is the project's final, whole-language correctness oracle — the honest,
un-fitted proof that our reimplementation behaves like real Lua.

When vendored, the files here are third-party and are marked `linguist-vendored`
in `.gitattributes` so they don't skew language stats and are collapsed in diffs.
