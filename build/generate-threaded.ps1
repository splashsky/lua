<# Regenerate the threaded VM, or verify it with -Check. #>
[CmdletBinding()]
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutDir = Join-Path $RepoRoot 'build\out'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Exe = Join-Path $OutDir 'generate-threaded.exe'
& odin build (Join-Path $RepoRoot 'tools\generate_threaded') "-out:$Exe"
if ($LASTEXITCODE -ne 0) { throw 'Could not build threaded VM generator.' }
if ($Check) { & $Exe $RepoRoot --check } else { & $Exe $RepoRoot }
if ($LASTEXITCODE -ne 0) { throw 'Threaded VM generation failed.' }
