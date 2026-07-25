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
      * On Windows, files.lua aborts partway through at its `/dev/null` /
        `/dev/full` device tests -- those are Unix-only special files (reference
        Lua on Windows fails there too). All io tests before that point pass. See
        tests/puc/README.md for the full list of documented platform deviations.
#>
[CmdletBinding()]
param(
    [string]$File = '',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot 'src'
$PucDir   = Join-Path $RepoRoot 'tests\puc'

$Collection = "-collection:luao=$SrcDir"

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

Push-Location $PucDir
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
