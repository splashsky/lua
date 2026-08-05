param()

$ErrorActionPreference = 'Stop'
Set-Location 'C:\Users\skyjohnson\OneDrive - Microsoft\Documents\lua-odin'
. .\build\debrand-map.ps1

$pkgs = [ordered]@{
    'kernel'    = 'src\kernel'
    'stdlib'    = 'src\stdlib'
    'main'      = 'src'
    'luac'      = 'src\compiler'
    'tests'     = 'tests'
    'lineedit'  = 'src\lineedit'
    'host'      = 'src\host'
    'stream'    = 'src\stream'
    'shellproc' = 'src\shellproc'
    'free'      = 'src\freestanding'
}

function New-Name([string]$n) {
    foreach ($p in $DebrandRenames) {
        if ($n.StartsWith($p[0], [System.StringComparison]::Ordinal)) {
            return $p[1] + $n.Substring($p[0].Length)
        }
    }
    return $n
}

$total = 0
foreach ($pkg in $pkgs.Keys) {
    if ($pkg -eq 'main') {
        $files = (Get-ChildItem 'src' -File -Filter *.odin).FullName
    } else {
        $files = (Get-ChildItem $pkgs[$pkg] -Recurse -File -Filter *.odin).FullName
    }
    if (-not $files) { continue }

    $decls = Select-String -Path $files -Pattern '^([A-Za-z_][A-Za-z0-9_]*)\s*(::|:=|:)' -CaseSensitive |
        ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique

    $old  = @($decls | Where-Object { $_ -cmatch '^(lua|LUA|Lua)' })
    $keep = @($decls | Where-Object { $_ -cnotmatch '^(lua|LUA|Lua)' })
    $keepSet = @{}; foreach ($k in $keep) { $keepSet[$k] = $true }

    $newSeen = @{}
    $conflicts = @()
    foreach ($o in $old) {
        $n = New-Name $o
        if ([string]::IsNullOrEmpty($n)) { $conflicts += "$o -> <EMPTY NAME>"; continue }
        if ($n -cmatch '^[0-9]')          { $conflicts += "$o -> $n (starts with a digit)"; continue }
        if ($keepSet.ContainsKey($n))     { $conflicts += "$o -> $n  [clashes with existing '$n']" }
        elseif ($newSeen.ContainsKey($n)) { $conflicts += "$o -> $n  [clashes with renamed '$($newSeen[$n])']" }
        $newSeen[$n] = $o
    }
    $total += $conflicts.Count
    Write-Host "=== $pkg : $($old.Count) branded decls, $($conflicts.Count) conflict(s)"
    $conflicts | ForEach-Object { Write-Host "    $_" }
}
Write-Host ""
Write-Host "TOTAL CONFLICTS: $total"
