<#
    build.ps1 -- cross-platform-friendly build wrapper for lua-odin (Windows side).

    Odin builds a whole directory as one package. We wire in the `lang` collection
    (mapping the name "lang" to the src/ tree) so packages import each other as
    `lang:kernel`, `lang:stdlib`, etc. regardless of where the repo lives on disk.

    Usage:
        .\build\build.ps1              # build the standalone interpreter (default)
        .\build\build.ps1 compiler     # build the bytecode compiler
        .\build\build.ps1 all          # build both
        .\build\build.ps1 freestanding # build the bare-metal object
        .\build\build.ps1 lua -DebugBuild   # debug build

    The language this runtime presents is a build-time choice (see
    src\kernel\brand.odin). `-Brand` selects it and names the binaries:

        .\build\build.ps1 all                 # lua.exe  / luac.exe   (default)
        .\build\build.ps1 all -Brand moon     # moon.exe / moonc.exe

    Output lands in build\out\.

    Set $env:VM_THREADED to '1' for the threaded VM or '0' for the switch VM.
    Remove it to use the build default. Other values are rejected.
#>
[CmdletBinding()]
param(
    [ValidateSet('lua', 'luac', 'compiler', 'all', 'freestanding')]
    [string]$Target = 'lua',
    [switch]$DebugBuild,
	[string]$FreestandingTarget = 'freestanding_amd64_sysv',
	[string]$Brand = 'lua',
	[string]$Display = '',
	[string]$SourceExt = '',
	[string]$EnvPrefix = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'brand.ps1')

# Figure out the repo root from this script's location so the script works no
# matter the current working directory.
$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutDir   = Join-Path $RepoRoot 'build\out'
$SrcDir   = Join-Path $RepoRoot 'src'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Shared flags: the collection makes cross-package imports stable.
$Collection = "-collection:lang=$SrcDir"
$Optimize   = if ($DebugBuild) { '-debug' } else { '-o:speed' }
$Defines    = Get-BrandDefines -Brand $Brand -Display $Display -SourceExt $SourceExt -EnvPrefix $EnvPrefix

# Windows ships threads with only a 1 MiB stack by default, but the language allows
# up to MAXCCALLS (200) nested native-boundary calls -- each of which parks a full
# `vm_execute` frame on the native stack. That is comfortably under the ~8 MiB
# default on Linux/macOS but overflows 1 MiB on Windows *before* the interpreter's
# own C-stack guard can turn the runaway recursion into a catchable "C stack
# overflow" error. Reserve a generous 128 MiB so the guard (not a hard crash) fires
# -- matching the observable overflow-handling behavior of reference Lua. Harmless
# elsewhere: this flag is only passed to the MSVC/LLD linker on Windows.
$StackFlags = '-extra-linker-flags:/STACK:0x8000000'

function Build-One {
    param([string]$ExeName, [string]$PackageDir)
    $OutPath = Join-Path $OutDir $ExeName
    Write-Host "==> Building $ExeName -> $OutPath"
    & odin build $PackageDir $Collection $Optimize $StackFlags @Defines "-out:$OutPath"
    if ($LASTEXITCODE -ne 0) { throw "Build failed for $ExeName" }
}

function Build-Interpreter { Build-One (Get-BrandExe $Brand) $SrcDir }
function Build-Compiler    { Build-One (Get-BrandCompilerExe $Brand) (Join-Path $SrcDir 'compiler') }

function Build-Freestanding {
	# A bare-metal target has no process entry point and no CRT to initialize one.
	# Build the stdlib package as a relocatable object instead: it pulls in the
	# kernel and the six pure libraries, while Odin's `freestanding` build tag
	# removes io/os/package/stream and both hosted mains automatically.
	#
	# `-default-to-nil-allocator` is important even though the kernel uses the
	# embedder's kernel.Allocator exclusively. It prevents an accidental Odin
	# make/new in reachable support code from quietly assuming an OS heap exists.
	$OutPath = Join-Path $OutDir "$Brand-freestanding.obj"
	$AbiFlags = @()
	if ($FreestandingTarget -in @('freestanding_amd64_win64', 'freestanding_amd64_mingw')) {
		# ODIN_OS is Freestanding for both triples, so jmp.odin cannot otherwise
		# distinguish their Win64 nonvolatile-register set from amd64 SysV.
		$AbiFlags += '-define:FREESTANDING_WIN64_ABI=true'
	}
	Write-Host "==> Building freestanding object ($FreestandingTarget) -> $OutPath"
	& odin build (Join-Path $SrcDir 'freestanding') $Collection $Optimize `
		"-target:$FreestandingTarget" -no-crt -default-to-nil-allocator `
		-no-entry-point -build-mode:obj -use-single-module @AbiFlags @Defines "-out:$OutPath"
	if ($LASTEXITCODE -ne 0) { throw "Freestanding build failed for $FreestandingTarget" }
}

switch ($Target) {
    'lua'  { Build-Interpreter }
    'luac' { Build-Compiler }
    'compiler' { Build-Compiler }
    'all'  {
        Build-Interpreter
        Build-Compiler
    }
	'freestanding' { Build-Freestanding }
}

Write-Host "Done."
