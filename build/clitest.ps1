<#
    clitest.ps1 -- end-to-end tests for the standalone `lua` and `luac` CLIs (Windows side).

    These are honest black-box tests: they build the two executables, then drive
    them exactly as a user would (arguments, stdin, script files, bytecode dumps)
    and assert on observable output, exit codes, and -- where a reference `luac` is
    available -- byte-for-byte dump compatibility. Nothing here peeks at internals.

    Usage:
        .\build\clitest.ps1              # build lua + luac, run all CLI tests
        .\build\clitest.ps1 -NoBuild     # reuse the last-built exes

    On success prints a pass count and exits 0; on any failed assertion it prints
    the mismatch and exits 1.
#>
[CmdletBinding()]
param(
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot 'src'
$Collection = "-collection:luao=$SrcDir"

# Build to a space-free temp dir (Odin mis-tokenizes the space in this repo's path).
$OutDir = Join-Path $env:TEMP 'luao-clitest'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Lua  = Join-Path $OutDir 'lua.exe'
$Luac = Join-Path $OutDir 'luac.exe'

$StackFlags = '-extra-linker-flags:/STACK:0x8000000'

if (-not $NoBuild) {
    Write-Host "==> Building lua + luac"
    & odin build $SrcDir $Collection '-o:speed' $StackFlags "-out:$Lua"
    if ($LASTEXITCODE -ne 0) { throw "lua build failed" }
    & odin build (Join-Path $SrcDir 'luac') $Collection '-o:speed' "-out:$Luac"
    if ($LASTEXITCODE -ne 0) { throw "luac build failed" }
}

# A scratch directory for the fixtures we generate.
$Work = Join-Path $env:TEMP 'luao-clitest-work'
if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Work | Out-Null

$script:Passed = 0
$script:Failed = 0

# Assert two strings are equal, trimming trailing whitespace/newlines so we don't
# trip over platform line-ending differences in captured output.
function Assert-Eq {
    param([string]$Label, [string]$Expected, [string]$Actual)
    $e = ($Expected -replace "`r", '').TrimEnd("`n")
    $a = ($Actual   -replace "`r", '').TrimEnd("`n")
    if ($e -eq $a) {
        $script:Passed++
        Write-Host "  ok   $Label"
    } else {
        $script:Failed++
        Write-Host "  FAIL $Label"
        Write-Host "       expected: [$e]"
        Write-Host "       actual:   [$a]"
    }
}

function Assert-True {
    param([string]$Label, [bool]$Cond)
    if ($Cond) { $script:Passed++; Write-Host "  ok   $Label" }
    else { $script:Failed++; Write-Host "  FAIL $Label" }
}

# Run a program, capturing stdout (as a single string) and the exit code.
function Invoke-Capture {
    param([string]$Exe, [string[]]$CliArgs, [string]$StdIn = $null)
    $out = if ($null -ne $StdIn) {
        $StdIn | & $Exe @CliArgs 2>$null
    } else {
        & $Exe @CliArgs 2>$null
    }
    return @{ Out = ($out -join "`n"); Code = $LASTEXITCODE }
}

Write-Host "==> lua CLI"

# -e executes a statement string.
$r = Invoke-Capture $Lua @('-e', 'print(6*7)')
Assert-Eq 'lua -e prints 42' '42' $r.Out

# -v prints the version banner.
$r = Invoke-Capture $Lua @('-v')
Assert-True 'lua -v shows Lua 5.5 banner' ($r.Out -like '*Lua 5.5*')

# A script file runs, and command-line arguments arrive in the global 'arg'.
$hello = Join-Path $Work 'hello.lua'
Set-Content $hello 'print("hello", 1+1); print(arg[1])' -NoNewline
$r = Invoke-Capture $Lua @($hello, 'world')
Assert-Eq 'lua script + arg' "hello`t2`nworld" $r.Out

# '-' reads and runs a chunk from stdin.
$r = Invoke-Capture $Lua @('-') -StdIn 'print(40+2)'
Assert-Eq 'lua - reads stdin' '42' $r.Out

# Multiple -e statements run in order.
$r = Invoke-Capture $Lua @('-e', 'io.write("a")', '-e', 'io.write("b")')
Assert-Eq 'lua chained -e' 'ab' $r.Out

# A runtime error yields a non-zero exit status.
$r = Invoke-Capture $Lua @('-e', "error('boom')")
Assert-True 'lua error -> nonzero exit' ($r.Code -ne 0)

# An unrecognized option yields a non-zero exit status.
$r = Invoke-Capture $Lua @('-Z')
Assert-True 'lua bad option -> nonzero exit' ($r.Code -ne 0)

Write-Host "==> luac CLI"

# -o dumps bytecode; the dumped chunk runs on lua and reproduces the source output.
$srcOut = (Invoke-Capture $Lua @($hello, 'X')).Out
$dump = Join-Path $Work 'hello.luac'
& $Luac -o $dump $hello | Out-Null
Assert-True 'luac -o creates a dump' (Test-Path $dump)
$dumpOut = (Invoke-Capture $Lua @($dump, 'X')).Out
Assert-Eq 'dumped chunk runs like source' $srcOut $dumpOut

# -p parses without producing output.
$r = Invoke-Capture $Luac @('-p', $hello)
Assert-True 'luac -p exits 0' ($r.Code -eq 0)

# -l lists bytecode (human-readable disassembly).
$r = Invoke-Capture $Luac @('-l', $hello)
Assert-True 'luac -l disassembles' ($r.Out -like '*main <*')

# -s strips debug info: the stripped dump is smaller but still runs.
$full  = Join-Path $Work 'full.luac'
$strip = Join-Path $Work 'strip.luac'
& $Luac -o $full  $hello | Out-Null
& $Luac -s -o $strip $hello | Out-Null
Assert-True 'stripped dump is smaller' ((Get-Item $strip).Length -lt (Get-Item $full).Length)
$stripOut = (Invoke-Capture $Lua @($strip, 'X')).Out
Assert-Eq 'stripped chunk still runs' $srcOut $stripOut

# Byte-compatibility with the reference luac, when one is available.
$RefLuac = Join-Path $env:TEMP 'refluabuild\refluac.exe'
if (Test-Path $RefLuac) {
    $ours = Join-Path $Work 'ours.luac'
    $ref  = Join-Path $Work 'ref.luac'
    & $Luac    -o $ours $hello | Out-Null
    & $RefLuac -o $ref  $hello | Out-Null
    $ab = [IO.File]::ReadAllBytes($ours)
    $bb = [IO.File]::ReadAllBytes($ref)
    $same = ($ab.Length -eq $bb.Length) -and (-not (Compare-Object $ab $bb))
    Assert-True 'luac dump byte-identical to reference' $same
} else {
    Write-Host "  skip reference byte-compat (no refluac.exe)"
}

Write-Host ""
Write-Host "CLI tests: $($script:Passed) passed, $($script:Failed) failed."
if ($script:Failed -ne 0) { exit 1 }
