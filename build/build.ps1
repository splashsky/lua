<#
    build.ps1 -- cross-platform-friendly build wrapper for lua-odin (Windows side).

    Odin builds a whole directory as one package. We wire in the `luao` collection
    (mapping the name "luao" to the src/ tree) so packages import each other as
    `luao:lua`, `luao:stdlib`, etc. regardless of where the repo lives on disk.

    Usage:
        .\build\build.ps1              # build the standalone `lua` CLI (default)
        .\build\build.ps1 luac         # build the `luac` compiler
        .\build\build.ps1 all          # build both
        .\build\build.ps1 freestanding # build the bare-metal Lua object
        .\build\build.ps1 lua -DebugBuild   # debug build

    Output lands in build\out\.
#>
[CmdletBinding()]
param(
    [ValidateSet('lua', 'luac', 'all', 'freestanding')]
    [string]$Target = 'lua',
    [switch]$DebugBuild,
	[string]$FreestandingTarget = 'freestanding_amd64_sysv'
)

$ErrorActionPreference = 'Stop'

# Figure out the repo root from this script's location so the script works no
# matter the current working directory.
$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutDir   = Join-Path $RepoRoot 'build\out'
$SrcDir   = Join-Path $RepoRoot 'src'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Shared flags: the collection makes cross-package imports stable.
$Collection = "-collection:lang=$SrcDir"
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

function Build-Freestanding {
	# A bare-metal target has no process entry point and no CRT to initialize one.
	# Build the stdlib package as a relocatable object instead: it pulls in the Lua
	# kernel and the six pure libraries, while Odin's `freestanding` build tag
	# removes io/os/package/stream and both hosted mains automatically.
	#
	# `-default-to-nil-allocator` is important even though the Lua kernel uses the
	# embedder's lua.Allocator exclusively. It prevents an accidental Odin make/new
	# in reachable support code from quietly assuming an OS heap exists.
	$OutPath = Join-Path $OutDir 'lua-freestanding.obj'
	$AbiFlags = @()
	if ($FreestandingTarget -in @('freestanding_amd64_win64', 'freestanding_amd64_mingw')) {
		# ODIN_OS is Freestanding for both triples, so jmp.odin cannot otherwise
		# distinguish their Win64 nonvolatile-register set from amd64 SysV.
		$AbiFlags += '-define:LUA_FREESTANDING_WIN64_ABI=true'
	}
	Write-Host "==> Building freestanding Lua ($FreestandingTarget) -> $OutPath"
	& odin build (Join-Path $SrcDir 'freestanding') $Collection $Optimize `
		"-target:$FreestandingTarget" -no-crt -default-to-nil-allocator `
		-no-entry-point -build-mode:obj -use-single-module @AbiFlags "-out:$OutPath"
	if ($LASTEXITCODE -ne 0) { throw "Freestanding build failed for $FreestandingTarget" }
}

switch ($Target) {
    'lua'  { Build-One 'lua'  $SrcDir }
    'luac' { Build-One 'luac' (Join-Path $SrcDir 'luac') }
    'all'  {
        Build-One 'lua'  $SrcDir
        Build-One 'luac' (Join-Path $SrcDir 'luac')
    }
	'freestanding' { Build-Freestanding }
}

Write-Host "Done."
