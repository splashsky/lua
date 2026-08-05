<#
    rebrand-smoke.ps1 -- prove that a rebranded build is really rebranded.

    The default profile is validated by build\test.ps1, build\puc.ps1 and
    build\clitest.ps1: those are the "did we break Lua 5.5.0?" gates. This script
    is the other half -- it builds the runtime under a *different* brand and
    checks that every user-visible name actually followed the `-define:` flags.

    Usage:
        .\build\rebrand-smoke.ps1                    # brand "moon" (.moon/MOON_*)
        .\build\rebrand-smoke.ps1 -Brand zig
        .\build\rebrand-smoke.ps1 -NoBuild
#>
[CmdletBinding()]
param(
    [string]$Brand = 'moon',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'brand.ps1')

if ($Brand -ceq 'lua') { throw "rebrand-smoke needs a brand other than the default 'lua'." }

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir   = Join-Path $RepoRoot 'src'
$Collection = "-collection:lang=$SrcDir"
$Defines  = Get-BrandDefines -Brand $Brand

$Display   = $Brand.Substring(0, 1).ToUpperInvariant() + $Brand.Substring(1)
$Ext       = ".$Brand"
$EnvPrefix = $Brand.ToUpperInvariant()

# Build to a space-free temp dir (Odin mis-tokenizes the space in this repo's path).
$OutDir = Join-Path $env:TEMP "lang-rebrand-$Brand"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Exe  = Join-Path $OutDir (Get-BrandExe $Brand)
$Cexe = Join-Path $OutDir (Get-BrandCompilerExe $Brand)

$StackFlags = '-extra-linker-flags:/STACK:0x8000000'

if (-not $NoBuild) {
    Write-Host "==> Building the '$Brand' profile"
    & odin build $SrcDir $Collection '-o:speed' $StackFlags @Defines "-out:$Exe"
    if ($LASTEXITCODE -ne 0) { throw "Build failed" }
    & odin build (Join-Path $SrcDir 'compiler') $Collection '-o:speed' @Defines "-out:$Cexe"
    if ($LASTEXITCODE -ne 0) { throw "Compiler build failed" }
}

$passed = 0
$failed = 0
function Assert-Equal {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Actual -ceq $Expected) { Write-Host "  ok   $Label"; $script:passed++ }
    else {
        Write-Host "  FAIL $Label"
        Write-Host "         expected: '$Expected'"
        Write-Host "         actual:   '$Actual'"
        $script:failed++
    }
}
function Assert-True {
    param([string]$Label, [bool]$Cond)
    if ($Cond) { Write-Host "  ok   $Label"; $script:passed++ }
    else { Write-Host "  FAIL $Label"; $script:failed++ }
}

$Work = Join-Path $env:TEMP "lang-rebrand-work-$Brand"
Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Work | Out-Null

Write-Host "==> '$Brand' branding"

# 1. The banner and _VERSION carry the new brand.
Assert-True 'version banner shows the brand' (((& $Exe -v) 2>&1) -join '').StartsWith("$Display 5.5.0")
Assert-Equal '_VERSION follows the brand' "$Display 5.5" (& $Exe -e "io.write(_VERSION)")

# 2. debug.getinfo().what reports the brand for a non-native function.
Assert-Equal 'getinfo().what follows the brand' $Display `
    (& $Exe -e "io.write(debug.getinfo(function() end).what)")

# 3. package.path templates use the brand directory and the new extension.
$path = & $Exe -e "io.write(package.path)"
Assert-True 'package.path uses the new extension' ($path.Contains("?$Ext"))
Assert-True 'package.path uses the brand directory' ($path.Contains("\$Brand\") -or $path.Contains("/$Brand/"))

# 4. `require` actually loads a module file with the new extension.
$modDir = Join-Path $Work 'mods'
New-Item -ItemType Directory -Force -Path $modDir | Out-Null
Set-Content (Join-Path $modDir "greet$Ext") 'return function() return "hi" end' -NoNewline
Push-Location $Work
try {
    $out = & $Exe -e "package.path = 'mods/?$Ext'; io.write(require('greet')())"
} finally { Pop-Location }
Assert-Equal "require loads a $Ext module" 'hi' $out

# 5. The brand-prefixed init environment variable is honoured.
$initVar = "${EnvPrefix}_INIT"
try {
    Set-Item -Path "Env:$initVar" -Value 'io.write("init!")'
    Assert-Equal "$initVar is honoured" 'init!' (& $Exe -e "")
} finally { Remove-Item -Path "Env:$initVar" -ErrorAction SilentlyContinue }

# 6. The precompiled-chunk signature is ESC + the brand, and round-trips.
Write-Host "==> '$Brand' precompiled chunks"
$src  = Join-Path $Work "hello$Ext"
$dump = Join-Path $Work "hello.dump"
Set-Content $src 'io.write("compiled ok")' -NoNewline
& $Cexe -o $dump $src | Out-Null
Assert-True 'the compiler produced a dump' (Test-Path $dump)

$sig = [System.IO.File]::ReadAllBytes($dump)[0..(3 + $Display.Length)]
$sigText = [System.Text.Encoding]::ASCII.GetString($sig[1..$Display.Length])
Assert-Equal 'dump signature is ESC + brand' $Display $sigText
Assert-True 'dump signature starts with ESC' ($sig[0] -eq 0x1b)
Assert-Equal 'the dump runs' 'compiled ok' (& $Exe $dump)

# 7. Brands are deliberately not bytecode-compatible: the default-profile
#    interpreter must reject a rebranded dump rather than silently misread it.
$DefaultExe = Join-Path $RepoRoot 'build\out\lua.exe'
if (Test-Path $DefaultExe) {
    & $DefaultExe $dump 2>&1 | Out-Null
    Assert-True 'the default profile rejects a rebranded dump' ($LASTEXITCODE -ne 0)
} else {
    Write-Host "  skip cross-brand rejection (build\out\lua.exe not built)"
}

Write-Host ""
Write-Host "Rebrand smoke tests: $passed passed, $failed failed."
if ($failed -gt 0) { exit 1 }
