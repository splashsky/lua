## Time-zone correctness: summary

- Found **13 behavioral families** below: four bugs (A1–A4), five useful glibc
  compatibility gaps (B1–B5), three documented policy differences (C1–C3),
  and one malformed/extreme-input family not worth copying (D1).
- The important surprises are ordinary New York/Lord Howe gaps and wrong
  `isdst` hints selecting ancient offsets, and leap-aware `right/*` files
  affecting even `!` UTC. `os.time` also wrongly accepts the `-1` sentinel.
- Recommend A1–A4 first, then B1/B2/B3/B5; B4 is larger and needs a scope decision.
  Keep the documented deterministic fold/gap and bounded-cache policies.

## Corpus

- `docs/plans/tz-corpus.lua` is the retained
  driver and worker. Master `0738e32`, Linux x86-64, glibc 2.44, tzcode/zoneinfo
  2026e; `/etc/localtime` was `America/Chicago`. `LC_ALL=C` throughout. Master
  advanced to `fa170e7` during the run, but that commit changes only `AGENTS.md`.
- **46 settings**, **3,711 distinct per-setting transition signatures** in
  the union of both implementations, **118,645 records**, **30,955 differing
  records** (18,350 time; 12,599 date; 6 embedded-NUL `*t` records whose date
  values differ). Each record compares complete bytes via `cmp`; a composite
  format contains every allowed C-locale conversion, including `%C`, `%%`,
  and all allowed E/O modifiers. Also compared UTC/local tables, invalid
  conversions, normalized tables, nil/false/true hints, and field errors.
- Daily scans plus binary search cover 1900–1971, 2000–2030 and 2399–2402;
  each discovered change is sampled at −3601, −1, 0, +1, +3601 seconds, with
  shared reference/ours wall inputs around gaps/folds. The scan can miss two
  changes within one day that restore the same signature: independently checked
  all 13 regular named settings against `zdump -V` in those ranges, with none
  missed. Also sampled epoch, −1, leap seconds, negative/large years and both
  `tm_year` limits. This is systematic sampling, not a proof over all TZif.
- Named zones include New York, Chicago, Lord Howe, Santiago, Dublin, Kolkata,
  Chatham, Amsterdam, Apia, Casablanca, Kathmandu and Moscow; also `right/*`,
  unset/empty/colon, paths, nonexistent names, empty `TZDIR`, explicit M/J/n
  POSIX rules and −167/+167-hour transitions. Valid formatting/error cases had
  no independent conversion-specifier or field-error mismatches; date-value
  differences propagate through the composite formats.
- Re-run from a disposable checkout, with a built `build/out/lua`:

  ```sh
  export PATH=/home/sky/.local/bin:$PATH TMPDIR=/tmp/opencode/tmp-correctness-tz
  export REFLUA=/tmp/opencode/refbuild/src/lua OURS="$PWD/build/out/lua" LC_ALL=C
  mkdir -p "$TMPDIR"
  "$REFLUA" docs/plans/tz-corpus.lua driver
  ```

- Cleanup: the scratch worktree and TMPDIR were removed, no jobs remain, and
  the main checkout was clean at `fa170e7`.

## Differences

Classes: **a** bug; **b** glibc behavior worth matching; **c** acceptable,
already documented; **d** glibc-specific and not worth matching. Results are
**ours → glibc**, with fresh processes unless a prior call is stated.

| ID / minimal reproduction | Ours → glibc | Class; cause |
|---|---|---|
| A1 `TZ=UTC`, `pcall(os.time,{year=1969,month=12,day=31,hour=23,min=59,sec=59})` | `true,-1` → error; both normalize the table, reference sets `wday=4,yday=365,isdst=false` before throwing | a; `oslib.odin:932–963` lacks Lua's sentinel check; existing `oslib_time_minus_one` asserts the opposite. |
| A2 `TZ=UTC`, `os.time{year=2147485547,month=13,day=1}` | succeeds with year 2147485548 → representability error | a; `normalize_civil`/`os_time` do not check normalized `tm_year` range. Similarly at the low limit. |
| A3 NY `os.time{year=2024,month=3,day=10,hour=2,min=30}` | `1710055562`, normalized 03:26:02 → `1710055800`, 03:30:00 | a; `timestamp_from_loaded_zone:336–400` ranks every historical TZif type, including 1883 LMT, rather than nearby transition offsets. Lord Howe gap 2024-10-06 02:15 similarly becomes 02:38:40 → 02:45. A wrong `isdst=false` in NY summer also picks LMT: 12:56:02 → 13:00. |
| A4 UTC `pcall(os.time,{year=2024,month=1,day=1,isdst=true})` | error → `1704106800`, normalized 11:00, `isdst=false` | a; `timestamp_from_loaded_zone:376–424` has no candidate when a fixed zone has only a matching-wall standard type and a conflicting hint; the unloaded-zone shortcut ignores the hint altogether. |
| B1 `TZ=:`; `os.date('%Z',0)` | empty → `UTC` | b; `load_local_zone_for:673–694` strips `:` then treats empty name as an unreadable file; empty `TZ` is handled separately. |
| B2 `TZ=AAA0BBB`; `os.date('%F %T %z %Z',1719835200)`; no such zone file | `12:00 +0000` empty → `13:00 +0100 BBB` | b; `POSIX_TZ_Parse:482–486` rejects absent DST rules. glibc uses `TZDIR/posixrules` when available (including historical transitions), otherwise built-in US rules; do not assume a single recurring rule reproduces both. `EST5EDT` happens to exist as a file on this system. |
| B3 empty `TZDIR`, `TZ=America/New_York`, same date | `08:00 -0400 EDT` → `12:00 +0000 America` | b; `local_zone_path:643–659` falls through to system dirs after a `TZDIR` miss; glibc honors the override, then applies its TZ parser. |
| B4 `TZ=right/UTC`, `os.date('!%F %T',1483228826)` | `2017-01-01 00:00:26` → `2016-12-31 23:59:60`; local `os.time{year=2016,month=12,day=31,hour=23,min=59,sec=60}` gives `1483228800` → `1483228826` | b; `TZif_Parse:253–262` skips leap records; `os_date:880–895` bypasses zone state for `!`; `normalize_civil` loses `sec=60`. Modern right-zone dates also differ by 27 seconds. |
| B5 `TZ=Foo/Bar`, `os.date('%Z',0)`; `TZ=XYZ3BAD/suffix`, `os.date('%z %Z',1719835200)` | empty → `Foo`; `+0000` empty → `-0200 BAD` | b; after file lookup fails, `POSIX_TZ_Parse` rejects the whole string while glibc retains partially parsed name/offset/DST state. Also affects the valid zone name in B3 after its overridden file lookup fails. |
| C1 `TZ=EST5EDT,M3.2.0,M11.1.0`, `os.date('%H %z %Z',-299851200)` | `08 -0400 EDT` → `07 -0500 EST` | c; POSIX recurrence in `POSIX_TZ_At:543–563` applies proleptically. glibc's POSIX-only computation anchors pre-1970 transition years at the epoch; southern rules can instead remain in DST. Named TZif history must not be changed. FUTURE_WORK §6 and `tzif_posix_rule_before_the_epoch` already document this choice. |
| C2 NY `os.time{year=2024,month=11,day=3,hour=1,min=30}` | `1730615400` standard → fresh glibc `1730611800` DST; after a prior winter `os.time`, glibc also chooses standard | c; `timestamp_from_loaded_zone:402–420` intentionally prefers standard for nil hints. Dublin 2024-03-31 01:30 gap normalizes forward 02:30 → glibc backward 00:30. README documents our choice; glibc's fold can depend on previous calls. |
| C3 replace an oversized, already-loaded zone file in place, same `TZ` | ours re-reads on next call → glibc retains initial file | c; `cached_local_zone_open:780–783` falls back to `load_local_zone`, as documented in FUTURE_WORK §6. Observable experiment below. |
| D1 `TZ=<X>1`, `os.date('%z %Z',0)`; `TZ=ABC65536`, `os.date('%z',0)`; `TZ=AAA0BBB,M1.1.0/-167,M12.5.0/167`, `pcall(os.date,'%F',67768036191676799)` | `-0100 X` → `+0000` empty; `-2400` → `+0000`; error → succeeds at max `tm_year` | d; glibc requires longer quoted names, its `%hu` parsing wraps before clamping, and its extreme POSIX-year computation differs; `posix_name`, `posix_clamped_number`, `POSIX_TZ_At`, and final local-year check do not replicate these nonportable artifacts. |

The scoped-loader difference is real, not hypothetical. For each interpreter,
the following prints UTC then UTC on glibc, but UTC then EDT on Odin; the
subsequent `os.time` changes from `1719835200` to `1719849600` on Odin only:

```sh
cp /usr/share/zoneinfo/UTC "$TMPDIR/utc"
cp /usr/share/zoneinfo/America/New_York "$TMPDIR/ny"
truncate -s 65537 "$TMPDIR/utc" "$TMPDIR/ny"
for L in "$REFLUA" "$OURS"; do
  cp "$TMPDIR/utc" "$TMPDIR/live"
  TZ="$TMPDIR/live" NEW="$TMPDIR/ny" "$L" -e \
    'print(os.date("%F %T %z %Z",1719835200)); assert(os.execute("cp "..os.getenv("NEW").." "..os.getenv("TZ"))); print(os.date("%F %T %z %Z",1719835200)); print(os.time{year=2024,month=7,day=1,hour=12})'
done
```

Regular-sized files remain cached in both. I would **not** make the cache
unbounded just to copy this: Lua's `localtime_r` also retains stale `TZ`, while
our per-call `TZ` check and unset-`TZ` `/etc/localtime` re-stat deliberately
provide stronger change detection. A bounded fallback remains a reasonable,
documented tradeoff; add a regression documenting both paths if desired.

## Fixes

- **A1/A2:** On non-Windows, check the normalized local year against the actual
  `struct tm` range and reject `t == -1` after updating the table, matching
  `loslib.c`. Do not copy indeterminate `struct tm` fields on glibc overflow;
  only the successful-but-`-1` normalization is well-defined. Tests: −1,
  adjacent seconds and table mutation; both bounds with month/day/hour spill,
  local offsets near limits, and unchanged field-error messages. No cache
  changes; guard the existing Windows behavior.
- **A3/A4:** Replace global historical-type ranking with candidates derived
  from active/adjacent transitions and, for contradictory hints, glibc-like
  nearby DST-offset probing and its fixed-zone one-hour fallback. Handle the
  unloaded-zone UTC path too. Preserve explicit hint selection and the
  documented nil-fold/forward-gap policy rather than copying glibc's global
  previous-call state. Test NY winter/summer and gap/fold, Lord Howe's 30-minute
  jump, Dublin negative DST, political offset changes, fixed/no-DST zones and
  normalized tables. Keep the current mutex/last-range invariants: no Lua calls
  while locked, no borrowed abbreviation escaping, same results on scoped and
  cached loaders; leave the Windows branch untouched.
- **B1:** Treat `:` as explicit UTC on Linux, including the cached reparse path
  (`cached_local_zone_open:768–778` currently reparses the stripped empty key).
  Test `:`/empty/`:UTC` and both cache/fallback behavior; no Windows change.
- **B2:** Add Linux default-rule loading that interprets `posixrules` with the
  requested standard/daylight offsets and names; use glibc's built-in fallback
  when absent. Historical transition adjustments matter. Cache owned TZif data
  and key-backed names rather than pointers into a temporary arena; retain the
  bounded fallback and lock discipline. Test `AAA0BBB`, both populated and
  empty `TZDIR`, historical/future transitions, and aliases/file precedence.
  Keep the generic explicit-rule parser and Windows path unchanged.
- **B3:** On Linux, if `TZDIR` is set, do not search system zoneinfo after its
  miss; then follow the selected parser/fallback, including B5's partial-name
  behavior for `America/New_York`. Test valid/missing custom
  zones, absolute/colon paths, and `TZ` changes. Cache currently keys only
  `TZ`, not `TZDIR`: decide whether deliberately stronger dynamic detection
  should also key `TZDIR`; do not accidentally introduce dangling key slices.
  Do not alter Windows or other hosts without their own libc tests.
- **B4:** If adopted, retain and validate TZif leap records; apply correction
  and leap-second extra to both local and Linux UTC conversion, and invert it
  in `os.time` without prematurely normalizing `sec=60`. Test first/last leap,
  `!*t`/`*t`/`%S`, leap-free controls, modern 27-second correction, transitions
  and bounds. Cache ranges must be split at leap boundaries or store leap data
  independently; account for scoped loader, invalidation and concurrency.
  This would make `!` consult zone state on Linux; isolate Windows and non-CRT.
- **B5:** Add a Linux-only staged fallback parser for failed file names,
  retaining the successfully parsed prefix, offset and DST state as glibc does;
  keep the strict parser for TZif footers and generic POSIX hosts. Test
  `garbage`, `Foo/Bar`, `XYZ3BAD/suffix`, nonalphabetic failures and B3's
  overridden named zone. Preserve cache ownership of abbreviation strings,
  bounded oversized-key fallback and no-Lua-under-lock; Windows unchanged.

## Work packages

1. `fix/os-time-range-sentinel`: A1/A2; `src/stdlib/oslib.odin`,
   `tests/oslib_test.odin`, integration checks. Acceptance: reference errors,
   deterministic normalized −1 table, range boundaries, Windows unchanged.
2. `fix/os-local-mktime-candidates`: A3/A4; `src/stdlib/oslib.odin`,
   `src/stdlib/tzif.odin` if lookup needs helpers, isolated Linux process tests.
   Acceptance:
   no LMT contamination or false fixed-zone error; nil fold/gap policy retained;
   all hint and cache/scoped regression cases above.
3. `fix/tz-linux-partial-parser`: B5; `src/stdlib/tzif.odin`, Linux subprocess tests.
   Acceptance: partial prefix/offset/DST reproductions match without changing
   strict TZif-footer parsing or cache safety.
4. `fix/tz-linux-discovery`: B1/B3; `src/stdlib/tzif.odin`, TZ process tests,
   `README.md`/`docs/ARCHITECTURE.md`. Acceptance: colon, `TZDIR`/absolute-path tests
   match glibc where specified, including B5 after lookup misses; cache change
   policy documented.
5. `feat/tz-posix-default-rules`: B2; `src/stdlib/tzif.odin`, `tests/tzif_test.odin`,
   Linux subprocess tests, `README.md`. Acceptance: populated/missing `posixrules`, history,
   footer and owned-cache tests; no unbounded process-wide allocations.
6. `feat/tzif-leap-seconds`: B4, subject to decision; `src/stdlib/tzif.odin`,
   `src/stdlib/oslib.odin`, `tests/tzif_test.odin`, `tests/oslib_test.odin` and docs.
   Acceptance: local and UTC `right/*` differential
   cases, leap inversion, boundary/cache/concurrency and non-leap regressions.

For each stdlib package, run the repository's full stdlib gates in `AGENTS.md`,
including both interpreter modes, stress/ASan, PUC, `build/check.sh` (Windows
type-check), and the differential corpus. Compare only the affected families;
remaining C/D mismatches are deliberate, not test failures to conceal.

## Open questions

- Prioritize leap-aware `right/*` and its Linux `!`-UTC dependency, or explicitly
  document that TZif leap records are unsupported? It is the largest package.
- Should changing `TZDIR` alone invalidate Odin's cache, despite glibc
  `localtime_r` itself retaining initial settings? Recommend yes only if the
  stronger dynamic-environment contract is intentional and documented.
- Keep the explicitly documented fold/gap and pre-1970 POSIX policies? Recommend
  yes; reproducing glibc's stateful fold and anomalous old-rule arithmetic has
  interoperability and maintenance costs. B2 would expand documented support
  for default DST rules; confirm that expansion is desired.
