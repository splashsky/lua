<#
    check.ps1 -- type checks and threaded-source verification (Windows side).

    `odin check` type-checks packages without linking; this wrapper also builds
    the generator for its drift check, which requires the native toolchain.
    Library packages need -no-entry-point (they have no `main`); the two
    executables are checked as-is.

    Usage:
        .\build\check.ps1
#>
[CmdletBinding()]
param([string]$Brand = 'lua', [string]$FreestandingTarget = 'freestanding_amd64_sysv')

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'brand.ps1')
$BrandDefines = Get-BrandDefines -Brand $Brand

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot 'src'
$Collection = "-collection:lang=$SrcDir"

# Refuse generated handlers that no longer match the switch interpreter.
& (Join-Path $RepoRoot 'build\generate-threaded.ps1') -Check

# Each entry: the path to check, and whether it's a library (no `main`).
$Targets = @(
    @{ Path = 'src';        Lib = $false },
    @{ Path = 'src\compiler';   Lib = $false },
    @{ Path = 'src\kernel';    Lib = $true  },
    @{ Path = 'src\stdlib'; Lib = $true  },
    @{ Path = 'tests';      Lib = $true  }
)

$failed = $false
foreach ($t in $Targets) {
    $full = Join-Path $RepoRoot $t.Path
    Write-Host "==> check $($t.Path)"
    if ($t.Lib) {
        & odin check $full $Collection @BrandDefines -no-entry-point
    } else {
        & odin check $full $Collection @BrandDefines
    }
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}

if ($failed) { throw "One or more packages failed to check." }

# The bare-metal build selects a different set of files via `#+build freestanding`,
# so the hosted checks above cannot catch a break in it. Check it explicitly, or the
# platform split rots silently. Linker/codegen flags (-no-crt, -build-mode:obj) are
# not accepted by `odin check` and are not needed to type-check.
Write-Host "==> check src\freestanding ($FreestandingTarget)"
& odin check (Join-Path $SrcDir 'freestanding') $Collection @BrandDefines `
    "-target:$FreestandingTarget" -default-to-nil-allocator -no-entry-point
if ($LASTEXITCODE -ne 0) { throw "Freestanding package failed to check." }

# Keep the optional interpreter type-checked even during the default check.
if ($env:VM_THREADED -ne '1') {
    Write-Host '==> check threaded interpreter'
    & odin check $SrcDir $Collection @BrandDefines '-define:VM_THREADED=true'
    if ($LASTEXITCODE -ne 0) { throw 'Threaded interpreter failed to check.' }
    Write-Host "==> check threaded freestanding interpreter ($FreestandingTarget)"
    & odin check (Join-Path $SrcDir 'freestanding') $Collection @BrandDefines `
        '-define:VM_THREADED=true' "-target:$FreestandingTarget" -default-to-nil-allocator -no-entry-point
    if ($LASTEXITCODE -ne 0) { throw 'Threaded freestanding interpreter failed to check.' }
}

Write-Host "All packages check clean."
