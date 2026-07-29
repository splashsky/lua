<#
    bench.ps1 -- run the reproducible lua-odin benchmark harness (Windows side).

    The useful comparison is always a same-session, back-to-back run. Machine
    load varies enough that numbers from different sessions should not be treated
    as evidence, even when the source and build flags appear identical.

    Usage:
        .\build\bench.ps1
        .\build\bench.ps1 -File tables.lua
        .\build\bench.ps1 -NoBuild
        .\build\bench.ps1 -Reference C:\path\to\lua.exe

    The runner samples WorkingSet64 every 40 ms. PeakWorkingSet64 becomes zero
    after some Windows processes exit, so reading that property afterward loses
    exactly the short-lived peaks this harness is intended to preserve.
#>
[CmdletBinding()]
param(
    [string]$File = '',
    [switch]$NoBuild,
    [string]$Reference = ''
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

$Files = @('micro.lua', 'tables.lua', 'scaling.lua')
if ($File -ne '') {
    if ($File -notin $Files) {
        throw "Unknown benchmark '$File'. Choose micro.lua, tables.lua, or scaling.lua."
    }
    $Files = @($File)
}

function Invoke-Benchmark {
    param([string]$Exe, [string]$BenchFile, [string]$Label)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = "`"$BenchFile`""
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

    Write-Host "===== $Label : $BenchFile ====="
    $stdout = $stdoutTask.Result.TrimEnd()
    if ($stdout -ne '') { Write-Host $stdout }
    $stderr = $stderrTask.Result.TrimEnd()
    if ($stderr -ne '') { Write-Host $stderr }
    Write-Host ("wall {0:N3}s   peakRSS {1:N0} KiB" -f
        $sw.Elapsed.TotalSeconds, [math]::Round($peak / 1KB, 0))
    Write-Host ''

    if ($process.ExitCode -ne 0) {
        throw "$Label exited with code $($process.ExitCode) while running $BenchFile."
    }
}

foreach ($BenchFile in $Files) {
    Invoke-Benchmark $LuaExe $BenchFile 'lua-odin'
    if ($Reference -ne '') {
        # Keep the reference run adjacent to ours. This minimizes load drift and
        # makes the two blocks the only honest pair to compare.
        Invoke-Benchmark $Reference $BenchFile 'reference Lua'
    }
}

Write-Host 'Benchmarks finished.'
