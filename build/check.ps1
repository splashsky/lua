<#
    check.ps1 -- linker-free verification for lua-odin (Windows side).

    `odin check` type-checks a package without invoking a native linker, so this
    works even on a machine with no Windows SDK / MSVC toolchain. It's our quick
    "does everything still compile?" gate. Library packages need -no-entry-point
    (they have no `main`); the two executables are checked as-is.

    Usage:
        .\build\check.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

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
        & odin check $full $Collection -no-entry-point
    } else {
        & odin check $full $Collection
    }
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}

if ($failed) { throw "One or more packages failed to check." }
Write-Host "All packages check clean."
