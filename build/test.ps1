<#
    test.ps1 -- verify generated handlers and run the Odin tests (Windows).

    Odin's built-in test runner compiles a directory's @(test) procs and runs
    them. We point it at tests/ with the same `lang` collection the build uses so
    the tests can import `lang:kernel` and `lang:stdlib`.
    The generated threaded handlers are checked first. Both steps need a linker.

    The unit tests exercise the default (Lua 5.5.1) profile. `-Brand` rebuilds
    them against a different branding profile; see build\brand.ps1.

    Usage:
        .\build\test.ps1                 # run all Odin unit tests
        .\build\test.ps1 -Name foo       # run only tests matching a name
        .\build\test.ps1 -Stress -Asan   # force stack moves under AddressSanitizer
#>
[CmdletBinding()]
param(
    [string]$Name = '',
    [string]$Brand = 'lua',
    [switch]$Stress,
    [switch]$Asan
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'brand.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot 'src'
$TestsDir = Join-Path $RepoRoot 'tests'

$Collection = "-collection:lang=$SrcDir"

# Odin's `test` command compiles the test binary and then runs it. If the output
# path contains a space (as this repo's "OneDrive - Microsoft" path does), Odin's
# internal run step mis-tokenizes it and dies with "Unknown argument encountered
# '-'". We dodge that by writing the test binary to a space-free temp location.
$OutDir  = Join-Path $env:TEMP "lang-tests-$Brand"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutPath = Join-Path $OutDir 'tests.exe'

$Args = @($TestsDir, $Collection, "-out:$OutPath", '-define:INTERNAL_ASSERTS=true') + (Get-BrandDefines -Brand $Brand)
if ($Stress) { $Args += '-define:HARDSTACKTESTS=true' }
if ($Asan) { $Args += '-sanitize:address' }
if ($Name -ne '') {
    # Odin filters tests by fully-qualified name via -define:ODIN_TEST_NAMES.
    $Args += "-define:ODIN_TEST_NAMES=tests.$Name"
}

& (Join-Path $RepoRoot 'build\generate-threaded.ps1') -Check

Write-Host "==> Running Odin tests in $TestsDir"
& odin test @Args
if ($LASTEXITCODE -ne 0) { throw "Tests failed" }

Write-Host "All tests passed."
