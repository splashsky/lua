<#
    debrand-rename.ps1 -- one-shot mechanical identifier rename for the debranding work.

    Renames Lua-branded identifiers to neutral subsystem-semantic names. Replacements
    are applied to code and string literals but NEVER to comment text, so the
    provenance comments that name the reference C original stay verbatim.

    Usage:
        .\build\debrand-rename.ps1 -Path src\kernel            # rewrite in place
        .\build\debrand-rename.ps1 -Path src\kernel -WhatIfReport   # collision report only
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'debrand-map.ps1')
$script:Renames = $DebrandRenames

# Split a line into alternating (replaceable, verbatim) runs. Comment text is
# verbatim; code and string/rune literals are replaceable. `$state` carries block
# comment nesting across lines (Odin block comments nest).
function Split-Line {
    param([string]$line, [ref]$depth)

    $segments = New-Object System.Collections.ArrayList
    $buf = New-Object System.Text.StringBuilder
    $mode = if ($depth.Value -gt 0) { 'verbatim' } else { 'code' }

    $emit = {
        param($kind)
        if ($buf.Length -gt 0) { [void]$segments.Add(@{ Kind = $mode; Text = $buf.ToString() }) }
        [void]$buf.Clear()
        $script:__ignore = $kind
    }

    $i = 0
    $n = $line.Length
    while ($i -lt $n) {
        $c = $line[$i]
        $c2 = if ($i + 1 -lt $n) { $line[$i + 1] } else { [char]0 }

        if ($depth.Value -gt 0) {
            if ($c -eq '/' -and $c2 -eq '*') { $depth.Value++; [void]$buf.Append('/*'); $i += 2; continue }
            if ($c -eq '*' -and $c2 -eq '/') {
                $depth.Value--
                [void]$buf.Append('*/'); $i += 2
                if ($depth.Value -eq 0) { & $emit 'x'; $mode = 'code' }
                continue
            }
            [void]$buf.Append($c); $i++; continue
        }

        if ($c -eq '/' -and $c2 -eq '/') {
            & $emit 'x'
            $mode = 'verbatim'
            [void]$buf.Append($line.Substring($i))
            break
        }
        if ($c -eq '/' -and $c2 -eq '*') {
            & $emit 'x'
            $mode = 'verbatim'
            $depth.Value = 1
            [void]$buf.Append('/*'); $i += 2
            continue
        }
        if ($c -eq '"') {
            [void]$buf.Append($c); $i++
            while ($i -lt $n) {
                if ($line[$i] -eq '\') { [void]$buf.Append($line.Substring($i, [Math]::Min(2, $n - $i))); $i += 2; continue }
                [void]$buf.Append($line[$i])
                if ($line[$i] -eq '"') { $i++; break }
                $i++
            }
            continue
        }
        if ($c -eq '`') {
            [void]$buf.Append($c); $i++
            while ($i -lt $n) { [void]$buf.Append($line[$i]); if ($line[$i] -eq '`') { $i++; break }; $i++ }
            continue
        }
        if ($c -eq "'") {
            [void]$buf.Append($c); $i++
            while ($i -lt $n) {
                if ($line[$i] -eq '\') { [void]$buf.Append($line.Substring($i, [Math]::Min(2, $n - $i))); $i += 2; continue }
                [void]$buf.Append($line[$i])
                if ($line[$i] -eq "'") { $i++; break }
                $i++
            }
            continue
        }
        [void]$buf.Append($c); $i++
    }
    & $emit 'x'
    return $segments
}

function Convert-Text {
    param([string]$text)
    foreach ($r in $script:Renames) {
        $pattern = '(?<![A-Za-z0-9_])' + [regex]::Escape($r[0])
        $text = [regex]::Replace($text, $pattern, $r[1])
    }
    return $text
}

$files = @()
foreach ($p in $Path) { $files += (Get-ChildItem -Path $p -Recurse -File -Filter *.odin).FullName }

$changed = 0
foreach ($f in $files) {
    $lines = [System.IO.File]::ReadAllLines($f)
    $depth = 0
    $out = New-Object System.Collections.Generic.List[string]
    $dirty = $false
    foreach ($line in $lines) {
        $d = [ref]$depth
        $segs = Split-Line -line $line -depth $d
        $depth = $d.Value
        $sb = New-Object System.Text.StringBuilder
        foreach ($s in $segs) {
            if ($s.Kind -eq 'code') { [void]$sb.Append((Convert-Text $s.Text)) }
            else { [void]$sb.Append($s.Text) }
        }
        $new = $sb.ToString()
        if ($new -ne $line) { $dirty = $true }
        $out.Add($new)
    }
    if ($dirty) {
        $changed++
        if (-not $ReportOnly) {
            [System.IO.File]::WriteAllLines($f, $out, (New-Object System.Text.UTF8Encoding($false)))
        }
        Write-Host "  rewrote $([System.IO.Path]::GetFileName($f))"
    }
}
Write-Host "$changed file(s) changed."
