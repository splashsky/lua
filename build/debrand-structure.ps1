<#
    debrand-structure.ps1 -- rename the Odin package, collection, and import
    aliases as part of the debranding work.

      package lua            -> package kernel
      -collection:lang=src   -> -collection:lang=src
      import lua  "luao:lua" -> import kernel "lang:kernel"
      import aux  "luao:stdlib" -> import stdlib "lang:stdlib"
      import <x>  "luao:<x>"    -> import <x>  "lang:<x>"

    The qualifier renames (`lua.` -> `kernel.`, `aux.` -> `stdlib.`) are applied
    only to files that actually import that package, because `aux` is also an
    ordinary local variable name inside the kernel.
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string[]]$Path)

$ErrorActionPreference = 'Stop'

# Replace a qualifier token (`name.`) in code, leaving comments and string
# literals untouched.
function Convert-Qualifier {
    param([string]$line, [string]$from, [string]$to, [ref]$depth)

    $out = New-Object System.Text.StringBuilder
    $i = 0; $n = $line.Length
    $pattern = '(?<![A-Za-z0-9_])' + [regex]::Escape($from) + '(?=\.)'

    $flush = {
        param([string]$chunk)
        [void]$out.Append([regex]::Replace($chunk, $pattern, $to))
    }

    $code = New-Object System.Text.StringBuilder
    while ($i -lt $n) {
        $c = $line[$i]
        $c2 = if ($i + 1 -lt $n) { $line[$i + 1] } else { [char]0 }

        if ($depth.Value -gt 0) {
            if ($c -eq '/' -and $c2 -eq '*') { $depth.Value++; [void]$out.Append('/*'); $i += 2; continue }
            if ($c -eq '*' -and $c2 -eq '/') { $depth.Value--; [void]$out.Append('*/'); $i += 2; continue }
            [void]$out.Append($c); $i++; continue
        }
        if ($c -eq '/' -and $c2 -eq '/') { & $flush $code.ToString(); [void]$code.Clear(); [void]$out.Append($line.Substring($i)); return $out.ToString() }
        if ($c -eq '/' -and $c2 -eq '*') { & $flush $code.ToString(); [void]$code.Clear(); $depth.Value = 1; [void]$out.Append('/*'); $i += 2; continue }
        if ($c -eq '"' -or $c -eq '`' -or $c -eq "'") {
            & $flush $code.ToString(); [void]$code.Clear()
            $q = $c
            [void]$out.Append($c); $i++
            while ($i -lt $n) {
                if ($q -ne '`' -and $line[$i] -eq '\') { [void]$out.Append($line.Substring($i, [Math]::Min(2, $n - $i))); $i += 2; continue }
                [void]$out.Append($line[$i])
                if ($line[$i] -eq $q) { $i++; break }
                $i++
            }
            continue
        }
        [void]$code.Append($c); $i++
    }
    & $flush $code.ToString()
    return $out.ToString()
}

$files = @()
foreach ($p in $Path) { $files += (Get-ChildItem -Path $p -Recurse -File -Filter *.odin).FullName }

$changed = 0
foreach ($f in $files) {
    $text  = [System.IO.File]::ReadAllText($f)
    $orig  = $text

    $importsKernel = $text -match '(?m)^\s*import\s+lua\s+"luao:lua"'
    $importsAux    = $text -match '(?m)^\s*import\s+aux\s+"luao:stdlib"'

    # Package declaration.
    $text = [regex]::Replace($text, '(?m)^package\s+lua\s*$', 'package kernel')

    # Import lines.
    $text = [regex]::Replace($text, '(?m)^(\s*)import\s+lua\s+"luao:lua"',     '$1import kernel "lang:kernel"')
    $text = [regex]::Replace($text, '(?m)^(\s*)import\s+aux\s+"luao:stdlib"',  '$1import stdlib "lang:stdlib"')
    $text = $text.Replace('"luao:', '"lang:')

    # Qualifier usages, comment- and string-safe.
    if ($importsKernel -or $importsAux) {
        $lines = $text -split "`r`n|`n"
        $depth = 0
        for ($j = 0; $j -lt $lines.Count; $j++) {
            $d = [ref]$depth
            $l = $lines[$j]
            if ($importsKernel) { $l = Convert-Qualifier -line $l -from 'lua'  -to 'kernel'  -depth $d }
            if ($importsAux)    { $l = Convert-Qualifier -line $l -from 'aux'  -to 'stdlib'  -depth $d }
            $depth = $d.Value
            $lines[$j] = $l
        }
        $text = $lines -join "`r`n"
    }

    if ($text -ne $orig) {
        $changed++
        [System.IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding($false)))
    }
}
Write-Host "$changed file(s) changed."
