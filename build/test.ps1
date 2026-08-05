<#
    test.ps1 -- run the lua-odin test suite (Windows side).

    Odin's built-in test runner compiles a directory's @(test) procs and runs
    them. We point it at tests/ with the same `luao` collection the build uses so
    the tests can import `luao:lua` and `luao:stdlib`.

    Later phases will also invoke the vendored PUC-Rio Lua 5.5 suite from here;
    for now this runs whatever Odin unit tests exist.

    Usage:
        .\build\test.ps1                 # run all Odin unit tests
        .\build\test.ps1 -Name foo       # run only tests matching a name
#>
[CmdletBinding()]
param(
    [string]$Name = ''
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot 'src'
$TestsDir = Join-Path $RepoRoot 'tests'

$Collection = "-collection:lang=$SrcDir"

# Odin's `test` command compiles the test binary and then runs it. If the output
# path contains a space (as this repo's "OneDrive - Microsoft" path does), Odin's
# internal run step mis-tokenizes it and dies with "Unknown argument encountered
# '-'". We dodge that by writing the test binary to a space-free temp location.
$OutDir  = Join-Path $env:TEMP 'luao-tests'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutPath = Join-Path $OutDir 'tests.exe'

$Args = @($TestsDir, $Collection, "-out:$OutPath")
if ($Name -ne '') {
    # Odin filters tests by fully-qualified name via -define:ODIN_TEST_NAMES.
    $Args += "-define:ODIN_TEST_NAMES=tests.$Name"
}

Write-Host "==> Running Odin tests in $TestsDir"
& odin test @Args
if ($LASTEXITCODE -ne 0) { throw "Tests failed" }

Write-Host "All tests passed."
