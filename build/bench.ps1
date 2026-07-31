<#
    bench.ps1 -- run the reproducible lua-odin benchmark harness (Windows side).

    The useful comparison is always a same-session, back-to-back run. Machine
    load varies enough that numbers from different sessions should not be treated
    as evidence, even when the source and build flags appear identical.

    Usage:
        .\build\bench.ps1
        .\build\bench.ps1 -File tables.lua
        .\build\bench.ps1 -NoBuild
        .\build\bench.ps1 -NoBuild -File micro.lua -Isolated
        .\build\bench.ps1 -Reference C:\path\to\lua.exe
        .\build\bench.ps1 -Reference C:\path\to\lua.exe -InProcess

    The runner samples WorkingSet64 every 40 ms. PeakWorkingSet64 becomes zero
    after some Windows processes exit, so reading that property afterward loses
    exactly the short-lived peaks this harness is intended to preserve.
#>
[CmdletBinding()]
param(
    [string]$File = '',
    [switch]$NoBuild,
    [string]$Reference = '',
    [switch]$Isolated,
    [switch]$InProcess
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot 'src'
$BenchDir = Join-Path $RepoRoot 'bench'
$Collection = "-collection:luao=$SrcDir"

# Odin mis-tokenizes the space in this repository's OneDrive path, so benchmark
# builds deliberately land in a stable, space-free temp directory.
$OutDir = Join-Path $env:TEMP 'luao-bench'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$LuaExe = Join-Path $OutDir 'lua.exe'

# Lua permits more nested C-boundary calls than Windows' default 1 MiB stack can
# hold. Reserving 128 MiB lets Lua's own guard report an error instead of letting
# the operating system terminate the process; build.ps1 documents the full story.
$StackFlags = '-extra-linker-flags:/STACK:0x8000000'

if (-not $NoBuild) {
    Write-Host "==> Building lua -> $LuaExe"
    & odin build $SrcDir $Collection '-o:speed' $StackFlags "-out:$LuaExe"
    if ($LASTEXITCODE -ne 0) { throw "Build failed" }
}

if (-not (Test-Path $LuaExe)) {
    throw "lua.exe not found at $LuaExe -- run without -NoBuild first."
}
if ($Reference -ne '' -and -not (Test-Path $Reference)) {
    throw "Reference lua not found at $Reference."
}
if ($Isolated -and $InProcess) {
    throw 'Choose either -Isolated or -InProcess, not both.'
}

$Files = @('micro.lua', 'tables.lua', 'stdlib.lua', 'scaling.lua')
if ($File -ne '') {
    if ($File -notin $Files) {
        throw "Unknown benchmark '$File'. Choose micro.lua, tables.lua, stdlib.lua, or scaling.lua."
    }
    $Files = @($File)
}

function Invoke-Benchmark {
    param(
        [string]$Exe,
        [string]$BenchFile,
        [string]$Label,
        [string]$BenchmarkName = ''
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = "`"$BenchFile`""
    if ($BenchmarkName -ne '') {
        # Benchmark names are deliberately simple identifiers. Quoting still
        # keeps this correct if a future suite gives one spaces.
        $psi.Arguments += " `"$BenchmarkName`""
    }
    $psi.WorkingDirectory = $BenchDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($psi)

    # Drain both pipes asynchronously while sampling. A benchmark that emits
    # enough output must never block waiting for this parent process to read it.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $peak = 0
    while (-not $process.HasExited) {
        try {
            $process.Refresh()
            if ($process.WorkingSet64 -gt $peak) { $peak = $process.WorkingSet64 }
        }
        catch {
            # The process can disappear between HasExited and Refresh; that race
            # is harmless because the previous sample still remains valid.
        }
        Start-Sleep -Milliseconds 40
    }
    $process.WaitForExit()
    $sw.Stop()

    $ModeLabel = if ($BenchmarkName -eq '') {
        'all-in-one process'
    } else {
        "isolated process : $BenchmarkName"
    }
    Write-Host "===== $Label : $BenchFile [$ModeLabel] ====="
    $stdout = $stdoutTask.Result.TrimEnd()
    if ($stdout -ne '') { Write-Host $stdout }
    $stderr = $stderrTask.Result.TrimEnd()
    if ($stderr -ne '') { Write-Host $stderr }
    Write-Host ("wall {0:N3}s   peakRSS {1:N0} KiB" -f
        $sw.Elapsed.TotalSeconds, [math]::Round($peak / 1KB, 0))
    Write-Host ''

    if ($process.ExitCode -ne 0) {
        throw "$Label exited with code $($process.ExitCode) while running $BenchFile $BenchmarkName."
    }
}

function Get-BenchmarkNames {
    param([string]$BenchFile)

    # Discovery is done by the script itself instead of a duplicated list in
    # PowerShell. That makes adding or renaming a Lua benchmark a one-file edit.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $LuaExe
    $psi.Arguments = "`"$BenchFile`" --list"
    $psi.WorkingDirectory = $BenchDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "Could not list benchmarks in $BenchFile`: $stderr"
    }
    return @($stdout -split '\r?\n' | Where-Object { $_ -ne '' })
}

# Comparisons default to fresh-process isolation because that is the only mode
# whose numbers are not conditioned by whichever workloads happened to run
# first. A no-reference invocation remains all-in-one for convenient casual use.
$UseIsolation = $Isolated -or ($Reference -ne '' -and -not $InProcess)

foreach ($BenchFile in $Files) {
    if ($UseIsolation) {
        $BenchmarkNames = Get-BenchmarkNames $BenchFile
        foreach ($BenchmarkName in $BenchmarkNames) {
            Invoke-Benchmark $LuaExe $BenchFile 'lua-odin' $BenchmarkName
            if ($Reference -ne '') {
                # Keep each reference run adjacent to ours. This minimizes load
                # drift while giving both interpreters the same fresh-process
                # starting point.
                Invoke-Benchmark $Reference $BenchFile 'reference Lua' $BenchmarkName
            }
        }
    } else {
        Invoke-Benchmark $LuaExe $BenchFile 'lua-odin'
        if ($Reference -ne '') {
            Invoke-Benchmark $Reference $BenchFile 'reference Lua'
        }
    }
}

Write-Host 'Benchmarks finished.'
