<#
    puc.ps1 -- drive the vendored PUC-Rio Lua 5.5 test suite against our `lua` (Windows side).

    The PUC-Rio suite (tests/puc/) is the project's final, un-fitted correctness
    oracle: real Lua's own regression tests, run verbatim against our interpreter.
    This script builds the standalone `lua` CLI and then runs the suite's master
    driver `all.lua` from inside tests/puc (the tests use relative `dofile` paths,
    so the working directory must be that folder).

    Usage:
        .\build\puc.ps1                 # build, then run the whole suite (all.lua)
        .\build\puc.ps1 -File math.lua  # run a single suite file standalone
        .\build\puc.ps1 -NoBuild        # skip the build, reuse the last lua.exe

    Notes:
      * We build to a space-free temp path. Odin's test/run steps mis-handle the
        space in this repo's "OneDrive - Microsoft" path; building `lua.exe`
        elsewhere sidesteps that entirely.
      * `-e "_U=true"` enables the suite's "user tests" mode. The internal C test
        library `T` is intentionally absent (we ship no ltests build), and every
        suite file guards its `T` usage with `not T or ...`, so those checks are
        skipped cleanly rather than failing.
      * On Windows, files.lua reaches two tests that open Unix-only special files,
        `/dev/null` and `/dev/full`. Reference Lua on Windows fails there too.
        Pass `-AdaptDevices` to run the suite from a temp copy in which those two
        device paths are adapted to the platform: `/dev/null` becomes `NUL`, and
        the `/dev/full` block (which has no Windows equivalent -- it needs a device
        whose writes always fail) is skipped and reported. With that, the suite runs
        to completion and prints `final OK !!!`.

        This is deliberately opt-in, and it substitutes only device *paths* -- no
        assertion, expectation or test logic is touched. The default run remains
        the verbatim, unmodified suite, because that is the honest oracle; this
        switch exists to show how much of the suite the device paths were hiding.
        See tests/puc/README.md.
#>
[CmdletBinding()]
param(
    [string]$File = '',
    [switch]$NoBuild,
    [switch]$AdaptDevices
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot 'src'
$PucDir   = Join-Path $RepoRoot 'tests\puc'

$Collection = "-collection:lang=$SrcDir"

# Build to a space-free temp dir to dodge Odin's space-in-path tokenization bug.
$OutDir  = Join-Path $env:TEMP 'luao-puc'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$LuaExe  = Join-Path $OutDir 'lua.exe'

# Windows threads default to a 1 MiB stack, too small for Lua's LUAI_MAXCCALLS
# (200) nested C-boundary frames; reserve 128 MiB so Lua's own C-stack guard fires
# as a catchable error instead of a hard crash. (See build.ps1 for the full story.)
$StackFlags = '-extra-linker-flags:/STACK:0x8000000'

if (-not $NoBuild) {
    Write-Host "==> Building lua -> $LuaExe"
    & odin build $SrcDir $Collection '-o:speed' $StackFlags "-out:$LuaExe"
    if ($LASTEXITCODE -ne 0) { throw "Build failed" }
}

if (-not (Test-Path $LuaExe)) {
    throw "lua.exe not found at $LuaExe -- run without -NoBuild first."
}

# `-AdaptDevices` runs from a throwaway copy of the suite in which the two Unix-only
# device paths are adapted to Windows. Nothing else about the tests changes: no
# assertion is relaxed and no expectation is rewritten, so a pass here still means
# the interpreter satisfied the real Lua test. We copy rather than edit in place so
# the vendored suite in the repository stays verbatim.
$RunDir = $PucDir
if ($AdaptDevices) {
    $RunDir = Join-Path $env:TEMP 'luao-puc-devices'
    Remove-Item -Recurse -Force $RunDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
    Copy-Item (Join-Path $PucDir '*') $RunDir -Recurse -Force

    $filesLua = Join-Path $RunDir 'files.lua'
    $text = Get-Content $filesLua -Raw

    # /dev/null has a direct Windows equivalent, so that test runs for real.
    $text = $text -replace '/dev/null', 'NUL'

    # /dev/full does not: it is a device whose every write fails with ENOSPC, and
    # Windows offers nothing equivalent. Skip exactly that block, matched on its
    # text rather than by line number so the edit cannot silently drift.
    $devFull = @'
  local f = io.output("/dev/full")
  assert(f:write("abcd"))   -- write to buffer
  assert(not f:flush())     -- cannot write to device
  assert(f:write("abcd"))   -- write to buffer
  assert(not io.flush())    -- cannot write to device
  assert(f:close())
'@
    $replacement = "  -- [-AdaptDevices] /dev/full has no Windows equivalent; block skipped.`r`n"
    $before = $text
    $text = $text.Replace(($devFull -replace "`r`n", "`n"), $replacement)
    if ($text -eq $before) {
        $text = $text.Replace($devFull, $replacement)
    }
    if ($text -eq $before) {
        throw "-AdaptDevices: could not find the /dev/full block in files.lua; the vendored suite may have changed."
    }

    Set-Content $filesLua $text -NoNewline
    Write-Host "==> -AdaptDevices: /dev/null -> NUL; /dev/full block skipped (no Windows equivalent)"
}

Push-Location $RunDir
try {
    if ($File -ne '') {
        Write-Host "==> Running suite file '$File' standalone"
        & $LuaExe -e "_soft=true; _port=true; _nomsg=true" $File
    }
    else {
        Write-Host "==> Running full PUC-Rio suite (all.lua, _U=true)"
        & $LuaExe -e "_U=true" all.lua
    }
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
}

if ($code -ne 0) {
    Write-Host "PUC suite exited with code $code (see tests/puc/README.md for known platform deviations)."
    exit $code
}
Write-Host "PUC suite finished."
