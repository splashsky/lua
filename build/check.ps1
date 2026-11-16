<#
    check.ps1 -- linker-free type checks (Windows side).

    `odin check` type-checks packages without linking. Both interpreter modes,
    including freestanding, are checked regardless of VM_THREADED. The generated
    source drift check runs in test.ps1, which already needs a linker.

    Usage:
        .\build\check.ps1
#>
[CmdletBinding()]
param([string]$Brand = 'lua', [string]$FreestandingTarget = 'freestanding_amd64_sysv')

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'brand.ps1')
$BrandDefines = @(Get-BrandDefines -Brand $Brand | Where-Object { $_ -notlike '-define:VM_THREADED=*' })
$SwitchDefines = @($BrandDefines) + @('-define:VM_THREADED=false')

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot 'src'
$Collection = "-collection:lang=$SrcDir"

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
        & odin check $full $Collection @SwitchDefines -no-entry-point
    } else {
        & odin check $full $Collection @SwitchDefines
    }
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}

# The generator imports no kernel packages and uses none of their defines.
Write-Host '==> check tools\generate_threaded'
& odin check (Join-Path $RepoRoot 'tools\generate_threaded')
if ($LASTEXITCODE -ne 0) { $failed = $true }

if ($failed) { throw "One or more packages failed to check." }

# The bare-metal build selects a different set of files via `#+build freestanding`,
# so the hosted checks above cannot catch a break in it. Check it explicitly, or the
# platform split rots silently. Linker/codegen flags (-no-crt, -build-mode:obj) are
# not accepted by `odin check` and are not needed to type-check.
Write-Host "==> check src\freestanding ($FreestandingTarget)"
& odin check (Join-Path $SrcDir 'freestanding') $Collection @SwitchDefines `
    "-target:$FreestandingTarget" -default-to-nil-allocator -no-entry-point
if ($LASTEXITCODE -ne 0) { throw "Freestanding package failed to check." }

Write-Host '==> check threaded interpreter'
& odin check $SrcDir $Collection @BrandDefines '-define:VM_THREADED=true'
if ($LASTEXITCODE -ne 0) { throw 'Threaded interpreter failed to check.' }
Write-Host "==> check threaded freestanding interpreter ($FreestandingTarget)"
& odin check (Join-Path $SrcDir 'freestanding') $Collection @BrandDefines `
    '-define:VM_THREADED=true' "-target:$FreestandingTarget" -default-to-nil-allocator -no-entry-point
if ($LASTEXITCODE -ne 0) { throw 'Threaded freestanding interpreter failed to check.' }

Write-Host "All packages check clean."
