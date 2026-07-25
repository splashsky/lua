<#
    build.ps1 -- cross-platform-friendly build wrapper for lua-odin (Windows side).

    Odin builds a whole directory as one package. We wire in the `luao` collection
    (mapping the name "luao" to the src/ tree) so packages import each other as
    `luao:lua`, `luao:stdlib`, etc. regardless of where the repo lives on disk.

    Usage:
        .\build\build.ps1              # build the standalone `lua` CLI (default)
        .\build\build.ps1 luac         # build the `luac` compiler
        .\build\build.ps1 all          # build both
        .\build\build.ps1 lua -DebugBuild   # debug build

    Output lands in build\out\.
#>
[CmdletBinding()]
param(
    [ValidateSet('lua', 'luac', 'all')]
    [string]$Target = 'lua',
    [switch]$DebugBuild
)

$ErrorActionPreference = 'Stop'

# Figure out the repo root from this script's location so the script works no
# matter the current working directory.
$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutDir   = Join-Path $RepoRoot 'build\out'
$SrcDir   = Join-Path $RepoRoot 'src'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Shared flags: the collection makes cross-package imports stable.
$Collection = "-collection:luao=$SrcDir"
$Optimize   = if ($DebugBuild) { '-debug' } else { '-o:speed' }

# Windows ships threads with only a 1 MiB stack by default, but Lua allows up to
# LUAI_MAXCCALLS (200) nested C-boundary calls -- each of which parks a full
# `luaV_execute` frame on the native stack. That is comfortably under the ~8 MiB
# default on Linux/macOS but overflows 1 MiB on Windows *before* Lua's own C-stack
# guard can turn the runaway recursion into a catchable "C stack overflow" error.
# Reserve a generous 128 MiB so the guard (not a hard crash) fires -- matching the
# observable overflow-handling behavior of reference Lua. Harmless elsewhere: this
# flag is only passed to the MSVC/LLD linker on Windows.
$StackFlags = '-extra-linker-flags:/STACK:0x8000000'

function Build-One {
    param([string]$Name, [string]$PackageDir)
    $ExeName = if ($Name -eq 'lua') { 'lua.exe' } else { "$Name.exe" }
    $OutPath = Join-Path $OutDir $ExeName
    Write-Host "==> Building $Name -> $OutPath"
    & odin build $PackageDir $Collection $Optimize $StackFlags "-out:$OutPath"
    if ($LASTEXITCODE -ne 0) { throw "Build failed for $Name" }
}

switch ($Target) {
    'lua'  { Build-One 'lua'  $SrcDir }
    'luac' { Build-One 'luac' (Join-Path $SrcDir 'luac') }
    'all'  {
        Build-One 'lua'  $SrcDir
        Build-One 'luac' (Join-Path $SrcDir 'luac')
    }
}

Write-Host "Done."
