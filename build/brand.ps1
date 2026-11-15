<#
    brand.ps1 -- shared brand-configuration helper for the build scripts.

    The runtime hardcodes no language name (see src/kernel/brand.odin); every
    user-visible name is a `#config` constant chosen at build time. This helper
    turns one `-Brand` argument into the matching `-define:` flags and the
    matching binary names, so every script parameterizes the same way:

        .\build\build.ps1 all                 # the default Lua 5.5.1 profile
        .\build\build.ps1 all -Brand moon     # a `moon`/`.moon`/`MOON_*` build

    `-Brand lua` (the default) deliberately emits *no* defines at all, so the
    default build is byte-for-byte the one the PUC-Rio suite validates.

    Individual knobs can still be overridden for full control, e.g.
    `-Brand moon -SourceExt .mn`. Every wrapper also reads $env:VM_THREADED:
    '1' selects threaded, '0' selects switch, and unset uses the build default.
    Other values are rejected.
#>

# The -define: flags for a brand, or an empty array for the default profile.
function Get-BrandDefines {
    [CmdletBinding()]
    param(
        [string]$Brand = 'lua',
        [string]$Display = '',
        [string]$SourceExt = '',
        [string]$EnvPrefix = ''
    )

    $isDefault = ($Brand -ceq 'lua') -and ($Display -eq '') -and
                 ($SourceExt -eq '') -and ($EnvPrefix -eq '')
    $vmDefines = @()
    if (Test-Path Env:VM_THREADED) {
        switch -CaseSensitive ($env:VM_THREADED) {
            '1' { $vmDefines += '-define:VM_THREADED=true' }
            '0' { $vmDefines += '-define:VM_THREADED=false' }
            default { throw "VM_THREADED must be 0, 1, or unset (got '$env:VM_THREADED')." }
        }
    }
    if ($isDefault) { return $vmDefines }

    if ($Display -eq '') {
        # "moon" -> "Moon": the conventional display spelling.
        $Display = $Brand.Substring(0, 1).ToUpperInvariant() + $Brand.Substring(1)
    }
    if ($SourceExt -eq '') { $SourceExt = ".$Brand" }
    if ($EnvPrefix -eq '') { $EnvPrefix = $Brand.ToUpperInvariant() }

    return @(
        "-define:BRAND=$Display",
        "-define:BRAND_LOWER=$Brand",
        "-define:SOURCE_EXT=$SourceExt",
        "-define:ENV_PREFIX=$EnvPrefix",
        "-define:NATIVE_OPEN_FMT=$($Brand)open_%s"
    ) + $vmDefines
}

# The interpreter binary name for a brand ("lua.exe", "moon.exe").
function Get-BrandExe {
    param([string]$Brand = 'lua')
    return "$Brand.exe"
}

# The compiler binary name for a brand ("luac.exe", "moonc.exe").
function Get-BrandCompilerExe {
    param([string]$Brand = 'lua')
    return "${Brand}c.exe"
}
