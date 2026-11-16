## Validation and portability: summary
- QEMU arm64 has now exercised **both** VMs: plain and stress PUC pass; unit tests expose a cross-architecture NaN-sign assumption, not a confirmed interpreter defect.
- Native Windows x64, Linux arm64 and macOS arm64 remain necessary, including allocator, OS, terminal and ABI paths QEMU or cross-objects cannot establish.
- First fix the NaN test, then offer a manual native CI matrix; reserve cycle conclusions for an isolated physical machine. Defer 32-bit and BSD runtime ports until requested.

## Findings
- At `0738e32`, local Odin `dev-2026-11-nightly:9a69916`, clang 23.1.3, Ubuntu 24.04.5 arm64 glibc sysroot and registered `qemu-aarch64-static`: `build/puc.sh` with `VM_THREADED=0` and `=1`, both plain and `STRESS=1`, exited 0 with `final OK !!!` (four runs; `T` remains absent). Wall times respectively 10.5, 11.3, 56.8 and 54.7 seconds, including compilation on the shared host.
- `build/test.sh` plain and `--stress`: both VMs ran 366 tests and had the **same one failure**, `tests.str_format_numbers` at `tests/strlib_test.odin:279` (`%A` of `-(0/0)` expects `NAN`, arm64 produces `-NAN`). Reference Lua 5.5.1 cross-compiled for arm64 prints the same `-NAN`; the sign of a NaN created by division is not portable. The C-locale `tests/format_diff.lua` outputs matched arm64 reference byte-for-byte, 279,336 cases, for both VMs. Fix the fixture by constructing a positive NaN from explicit bits, retaining separate sign tests. Native arm64 confirmation is still required.
- `--stress --asan` could not link locally: clang lacks `libclang_rt.asan_static.a` and `libclang_rt.asan.a` for aarch64. No arm64 ASan run is claimed. LLVM emitted an SP-clobber warning; normal binaries did run.
- Cross-linking normally invokes **host** clang with no target; it failed with `Relocations in generic ELF (EM: 183)`. A disposable clang wrapper supplying `--target=aarch64-linux-gnu -fuse-ld=lld --sysroot=... --gcc-toolchain=...` and target CRT/libc/libgcc fixed it. `QEMU_LD_PREFIX` supplies the dynamic loader; an `odin` wrapper adds `-target:linux_arm64` to `build`, `test`, `check`, and `run`, including the generator. QEMU emulates user instructions, not a native kernel, and is not performance evidence.
- Recreate without root: extract [ubuntu-base-24.04.5-base-arm64.tar.gz](https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz) into `$TMPDIR/sysroot`; SHA-256 `a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2`. From `https://ports.ubuntu.com/ubuntu-ports/`, download `pool/main/g/glibc/libc6-dev_2.39-0ubuntu8.12_arm64.deb` (`b8411b504a468c19a2acf4ff38a2015997853d078138afac76ff89c9599794b2`) and `pool/main/g/gcc-13/libgcc-13-dev_13.3.0-6ubuntu2~24.04.1_arm64.deb` (`609a9410d9a1f25a1cb7847de92ee9f438336a0a3a82d282c3686f52ddd61526`); extract each with `ar p FILE data.tar.zst | tar --zstd -xf - -C "$TMPDIR/sysroot"`. For reference C compilation also extract `pool/main/l/linux/linux-libc-dev_6.8.0-149.149_arm64.deb` (`7ab70f6ebc55fe9ea6ceb9bb087cc7df252b62b9f1b14df46e825052206d7cff`). Verify checksums; archive package versions may move to an Ubuntu snapshot.
- Put executable wrappers ahead of PATH: `clang` execs `/usr/bin/clang` with the four flags above and `"$@"`; `odin` execs the native Odin with `"$@" -target:linux_arm64` for the four commands, passing other commands unchanged. Export `QEMU_LD_PREFIX="$TMPDIR/sysroot"`; run the existing scripts normally. Reference: extract Lua 5.5.1, `PATH=<wrapper-dir>:$PATH make -C <lua>/src linux CC=clang`. Native runner evidence is still preferred.
- Windows exercises the Win64 nonvolatile integer/XMM jump shim, process heap, text/binary streams and `popen`; macOS exercises `1055a5c`'s direct C-heap realloc/free, BSD-derived number formatting and plain-reader fallback. CI's redirected CLI input does **not** prove TTY fallback: add a PTY test. macOS `popen` is intentionally unsupported. Compare `format_diff.lua` against a reference built on each macOS/BSD host.
- Cleanup confirmed: no experiment processes remain, the scratch worktree and `$TMPDIR` are removed, and the main checkout's `git status --porcelain` is clean; only this plan remains.

## CI plan
- `splashsky/lua` is public and Actions are enabled. Standard `windows-latest` x64 and `ubuntu-24.04-arm` (4 vCPU/16 GB), `macos-15` M1 arm64 (3 CPU/7 GB) are free/unlimited in public repos; 14 GB disk each. `macos-14` is x64/deprecated, not ARM. Free-plan concurrency is 20 total, at most 5 macOS; actual owner plan and queue delays unknown; hosted jobs have a 6-hour ceiling. [Runner specs](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [limits](https://docs.github.com/en/actions/reference/limits).
- **Pin the actual compiler**, not merely the version text: release tag `dev-2026-11a` resolves to `9a6991685ddf663956d9836602eb421e141fc443`; assets and hashes below are from GitHub's release API. `dev-2026-11` points at an earlier tag; aliases can still contain the same binaries. Check both asset SHA-256 and `odin version`. Pin/review action SHAs before production.
- Windows image has VS 2022/SDK and ASan component; activate x64 MSVC (`ilammy/msvc-dev-cmd`) for the C reference. Ensure `%TEMP%`/`%TMP%` contain no spaces (`test.ps1` and other scripts rely on it). Reference `luac` must be exactly `%TEMP%\refluabuild\refluac.exe`; `clitest.ps1` otherwise silently skips it, and its `Compare-Object` is not a robust ordered byte comparison—replace with bytewise equality. Build `all` before rebrand so cross-brand rejection is exercised.
- Linux arm64 ASan requires a compatible native clang/compiler-rt; macOS requires matching Apple clang/runtime; Windows has the components but Odin/MSVC interception has reported compatibility problems. Probe all three with an intentional ASan violation and a clean program, then run `--stress --asan`/`-Stress -Asan`; fail rather than silently skip once supported. Windows allocator uses `HeapAlloc`/`HeapReAlloc`, so ASan cannot be assumed to provide malloc redzones for those blocks. The opt-in YAML tests support rather than promising it.
- PUC is verbatim on Linux. On Windows the original fails on `/dev/null`; macOS reaches absent `/dev/full`; reference fails at the same place. `-AdaptDevices` is diagnostic, not verbatim: Windows maps `/dev/null` to `NUL` and skips the one `/dev/full` block. **Prerequisites:** add `puc.sh --adapt-devices` for macOS using a temporary copy and exact-match skip of only that block; `/dev/null` stays tested. Add the called `ci-puc-verbatim.sh/.ps1` helpers to run the original suite against both our freshly built mode and the supplied native reference, retain logs and require both failures to identify `files.lua` and the expected device path/stage; an earlier or different failure must fail the job. Neither modified suite nor `T`-gated tests may be described as a full verbatim pass.
- Estimated 5–20 minutes per VM/mode job, 60-minute timeout, setup/queue excluded; rough estimate only, calibrate from first native runs. Jobs are independent, but execute heavy gates serially *within* each job. Draft is manual and also assumes new `ci-asan-probe.*` helpers proving a clean binary works and a deliberately out-of-bounds binary is caught, and a `ci-tty-fallback.sh` PTY test. These are prerequisites, not existing scripts; no runs created.

```yaml
name: native-validation
on:
  workflow_dispatch:
    inputs:
      asan: {type: boolean, default: false, description: 'Probe/run ASan'}
permissions: {contents: read}
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-24.04-arm, macos-15, windows-latest]
        vm: ['0', '1']
        include:
          - os: ubuntu-24.04-arm
            asset: odin-linux-arm64-dev-2026-11a.tar.gz
            sha: 5bdba22447ea46a99765235e401c2ad83930f967f987aab1531ed76c3aa7ea3b
            fs: freestanding_arm64
          - os: macos-15
            asset: odin-macos-arm64-dev-2026-11a.tar.gz
            sha: fa10eee280c8786758e3ff0b8fdd9355e1c9447b1f0b8c72764e25ee4ebc3e22
            fs: freestanding_arm64
          - os: windows-latest
            asset: odin-windows-amd64-dev-2026-11a.zip
            sha: 259effedf2997293c8fa4a5e497496f8ebce9f826652d9dd353a9dd2113c31fd
            fs: freestanding_amd64_win64
    runs-on: ${{ matrix.os }}
    timeout-minutes: 60
    env:
      VM_THREADED: ${{ matrix.vm }}
      RUN_ASAN: ${{ inputs.asan }}
      LC_ALL: C
    steps:
      - uses: actions/checkout@v4
      - uses: ilammy/msvc-dev-cmd@v1
        if: runner.os == 'Windows'
      - name: Install Odin (Unix)
        if: runner.os != 'Windows'
        shell: bash
        run: |
          set -euo pipefail
          curl -fsSL -o "$RUNNER_TEMP/odin.tgz" "https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/${{ matrix.asset }}"
          echo '${{ matrix.sha }}  '"$RUNNER_TEMP/odin.tgz" | shasum -a 256 -c -
          mkdir "$RUNNER_TEMP/odin"
          tar -xzf "$RUNNER_TEMP/odin.tgz" -C "$RUNNER_TEMP/odin"
          dirname "$(find "$RUNNER_TEMP/odin" -type f -name odin -print -quit)" >> "$GITHUB_PATH"
      - name: Install Odin (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          $env:TEMP = 'C:\lua-ci'; $env:TMP = $env:TEMP
          New-Item -ItemType Directory -Force $env:TEMP | Out-Null
          "TEMP=$env:TEMP`nTMP=$env:TMP" | Out-File $env:GITHUB_ENV -Append -Encoding utf8
          $zip = "$env:TEMP\odin.zip"
          Invoke-WebRequest "https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/${{ matrix.asset }}" -OutFile $zip
          if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne '${{ matrix.sha }}') { throw 'Odin hash mismatch' }
          Expand-Archive $zip "$env:TEMP\odin"
          (Get-ChildItem "$env:TEMP\odin" -Recurse -Filter odin.exe | Select-Object -First 1).DirectoryName | Out-File $env:GITHUB_PATH -Append -Encoding utf8
      - name: Build reference (Unix)
        if: runner.os != 'Windows'
        shell: bash
        run: |
          set -euo pipefail
          odin version | grep 9a69916
          curl -fsSL -o "$RUNNER_TEMP/lua.tgz" https://www.lua.org/ftp/lua-5.5.1.tar.gz
          echo '1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce  '"$RUNNER_TEMP/lua.tgz" | shasum -a 256 -c -
          tar -xzf "$RUNNER_TEMP/lua.tgz" -C "$RUNNER_TEMP"
          make -C "$RUNNER_TEMP/lua-5.5.1/src" $([[ "$RUNNER_OS" == macOS ]] && echo posix || echo linux)
      - name: Build reference (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          if (-not ((odin version) -match '9a69916')) { throw 'Odin version mismatch' }
          Invoke-WebRequest https://www.lua.org/ftp/lua-5.5.1.tar.gz -OutFile "$env:TEMP\lua.tgz"
          if ((Get-FileHash "$env:TEMP\lua.tgz" -Algorithm SHA256).Hash -ne '1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce') { throw 'Lua hash mismatch' }
          tar -xzf "$env:TEMP\lua.tgz" -C $env:TEMP
          Push-Location "$env:TEMP\lua-5.5.1\src"
          $src = @(Get-ChildItem *.c | Where-Object { $_.Name -notin @('lua.c','luac.c') } | ForEach-Object { $_.Name })
          & cl /nologo /O2 /MD /DLUA_USE_WINDOWS /D_CRT_SECURE_NO_WARNINGS /c @src; if ($LASTEXITCODE) { throw 'cl' }
          $obj = @(Get-ChildItem *.obj | ForEach-Object { $_.Name })
          & lib /nologo /OUT:ref.lib @obj; if ($LASTEXITCODE) { throw 'lib' }
          New-Item -ItemType Directory -Force "$env:TEMP\refluabuild" | Out-Null
          & cl /nologo /O2 /MD /DLUA_USE_WINDOWS /D_CRT_SECURE_NO_WARNINGS lua.c ref.lib "/Fe:$env:TEMP\refluabuild\reflua.exe"; if ($LASTEXITCODE) { throw 'lua' }
          & cl /nologo /O2 /MD /DLUA_USE_WINDOWS /D_CRT_SECURE_NO_WARNINGS luac.c ref.lib "/Fe:$env:TEMP\refluabuild\refluac.exe"; if ($LASTEXITCODE) { throw 'luac' }
          Pop-Location
      - name: Gates (Unix)
        if: runner.os != 'Windows'
        shell: bash
        env: {FREESTANDING_TARGET: '${{ matrix.fs }}'}
        run: |
          set -euo pipefail
          bash build/check.sh
          bash build/test.sh
          bash build/test.sh --stress
          if [[ "$RUNNER_OS" == macOS ]]; then
            bash build/ci-puc-verbatim.sh "$RUNNER_TEMP/lua-5.5.1/src/lua"
            bash build/puc.sh --adapt-devices
            STRESS=1 bash build/puc.sh --adapt-devices
          else
            bash build/puc.sh
            STRESS=1 bash build/puc.sh
          fi
          REFLUAC="$RUNNER_TEMP/lua-5.5.1/src/luac" bash build/clitest.sh
          bash build/rebrand-smoke.sh
          bash build/build.sh freestanding
          if [[ "$RUNNER_OS" == macOS ]]; then
            "$RUNNER_TEMP/lua-5.5.1/src/lua" tests/format_diff.lua > "$RUNNER_TEMP/ref.txt"
            build/out/lua tests/format_diff.lua > "$RUNNER_TEMP/ours.txt"
            cmp "$RUNNER_TEMP/ref.txt" "$RUNNER_TEMP/ours.txt"
            bash build/ci-tty-fallback.sh build/out/lua
          fi
          if [[ "$RUN_ASAN" == true ]]; then
            bash build/ci-asan-probe.sh
            bash build/test.sh --stress --asan
            if [[ "$RUNNER_OS" == macOS ]]; then STRESS=1 ASAN=1 bash build/puc.sh --adapt-devices; else STRESS=1 ASAN=1 bash build/puc.sh; fi
          fi
      - name: Gates (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          .\build\check.ps1
          .\build\test.ps1
          .\build\test.ps1 -Stress
          .\build\ci-puc-verbatim.ps1 -Reference "$env:TEMP\refluabuild\reflua.exe"
          .\build\puc.ps1 -AdaptDevices
          .\build\puc.ps1 -AdaptDevices -Stress
          if (-not (Test-Path "$env:TEMP\refluabuild\refluac.exe")) { throw 'missing reference' }
          .\build\clitest.ps1
          .\build\build.ps1 all
          .\build\rebrand-smoke.ps1
          .\build\build.ps1 freestanding -FreestandingTarget '${{ matrix.fs }}'
          if ($env:RUN_ASAN -eq 'true') { .\build\ci-asan-probe.ps1; .\build\test.ps1 -Stress -Asan; .\build\puc.ps1 -AdaptDevices -Stress -Asan }
```

## Measurement protocol
1. Use an otherwise idle, dedicated Linux machine; record CPU model/microcode, OS/kernel, RAM, compiler/LLVM, commits, binaries/hashes, build flags, locale, TZ and workload. Reserve a physical core via cpuset/boot isolation and move IRQs/housekeeping away; pin the benchmark with `taskset`. Disable SMT or ensure its sibling is idle before **and during** each block (topology and per-CPU activity); check no migration or unexpected context switches. Do not change a shared host without consent.
2. Set and record a fixed frequency/performance governor, disable boost/turbo where practical, allow thermal warmup, monitor effective frequency and temperature/throttling; abort or label blocks with interference. Warm each workload once, then run at least 21 paired/rotated blocks per workload in the same session, more for noisy hash/GC/I/O; repeat a second session. Keep environment and machine settings stable.
3. Count `instructions:u,cycles:u` simultaneously with `perf stat`, verify enabled/running time (no multiplexing), record task clock, migrations and switches. Report raw samples, medians, IQR/range and paired threaded/switch/reference ratios with bootstrap 95% CIs; report minima only as supplemental. State when intervals overlap or noise exceeds the effect. Compare independent distributions for variable seeds, not a cherry-picked minimum. Startup remains included and is disclosed.
4. `build/vm-compare.sh` already pins, rotates fresh processes, and outputs min/median of both counters, but defaults to 3 runs and deletes raw data. Add persistent CSV/metadata, warmups, quiet/sibling checks and per-block contamination flags, paired statistics and perf running percentages. A `perf stat -r` option is useful for single-mode diagnostics, but grouped repeats lose the existing interleaving; do not replace paired rotation with it. GitHub-hosted VMs have variable placement, shared resources/interrupts, uncertain frequency and often restricted PMU access: use for correctness, not trusted cycle comparisons.

## 32-bit and BSD
- `object.odin` asserts Value 8/align 8, TValue/StackValue 16 and tag offset 8, Udata 40; `string.odin` TString 32; `table.odin` Node 24, Table 48 and explicit field offsets; `func.odin` Proto 160, UpVal 48, CClosure 40, LClosure 32; `state.odin` State 192, GC header offsets 8/9 and LX extraspace. Allocation/GC sizing and inline closure/userdata/array alignment depend on these. Rework layouts/assertions and prove 8-byte integer/double alignment and allocator guarantees; audit pointer-sized `int`/`uint`/overflow and `opcodes.odin`'s explicit 64-bit-int assumption. Fixed bytecode ABI remains 32-bit instruction/int and 64-bit Lua number/integer.
- `Vararg_Count` is already `i32` when the stack bound fits, otherwise native `int`; on 32-bit reassess bounds including error reserve and every conversion, not simply widen it. `jmp.odin` has only amd64/arm64 shims; Odin `linux_i386` currently rejects inline-asm templates even in other architecture branches at parse time. A 32-bit port needs a separately gated/supported ABI-specific save/restore shim, switch VM, heap/OS APIs, build/test toolchain, overflow tests and native-or-emulated full gates. Threaded currently explicitly excludes it. Estimate several focused weeks plus validation, not a quick flag; recommend defer absent an embedding/customer target.
- Locally `odin check src` for `freebsd_amd64`, `netbsd_amd64`, `openbsd_amd64` fails at the amd64 OS guard in `jmp.odin`; do not claim BSD amd64 builds. FreeBSD and NetBSD arm64 `src` type-check in both modes, and threaded `-o:speed -build-mode:obj` emits objects; this is not linking or runtime validation. `openbsd_arm64` is not an Odin target here. To support BSD: verify each ABI before extending the SysV guard, check all packages, link on actual BSD with its compiler/libc, run both VMs and stress/PUC, document device/popen deviations, run format differential and PTY fallback. Use a BSD VM or self-hosted runner; no standard GitHub BSD runner.

## Work packages
1. `tests/portable-nan-fixture`: deterministic NaN bits plus independent sign coverage; `tests/strlib_test.odin`. Accept: reference-consistent Linux x64 and native/emulated arm64 plain/stress unit tests in both VMs; no weakened assertion.
2. `build/native-validation-harness`: macOS temporary PUC adaptation, verbatim/reference helpers, ASan probe, PTY test and ordered Windows byte compare; `build/puc.sh`, `build/ci-*.{sh,ps1}`, `build/clitest.ps1`, tests and docs. Accept: original expected failures identified against reference; adapted suite final OK without modifying vendor; missing luac fails CI; reordered byte fixture fails; probes distinguish working instrumentation from unavailable runtime.
3. `ci/native-vm-validation`: add draft matrix and PTY/OS coverage as approved; `.github/workflows/`, focused tests, `BUILDING.md`, `tests/puc/README.md`, `docs/FUTURE_WORK.md`. Accept: record native results per target/mode, sanitizer availability and warnings; Windows Win64/popen, macOS malloc/format/TTY verified; only update status after actual results. Separate sanitizer enablement if platform probe fails.
4. `bench/quiet-vm-compare`: opt-in quiet checks, interleaved samples/metadata/statistics; `build/vm-compare.sh`, `bench/README.md`. Accept: rejects/labels noisy samples and exports reproducible raw data; record a dedicated-machine comparison separately.
5. Optional `port/bsd-amd64`: ABI investigation, compile and native VM validation; `src/kernel/jmp.odin`, targeted tests and portability docs. Accept: native tests and format differential, no claim based solely on `odin check`.

## Open questions
- Enable native CI at all? Manual only initially, or PR/push/schedule after the first validated runs? Include Linux x64 regression jobs too?
- Is the diagnostic adapted PUC acceptable as a CI gate alongside recorded verbatim platform failures? Should ASan be mandatory only after a working native probe?
- Is a dedicated quiet machine available, and may its CPU/IRQ/frequency settings be changed? Is there a concrete 32-bit or BSD deployment to justify those ports?
