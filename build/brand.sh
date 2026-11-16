#!/usr/bin/env bash
#
# brand.sh -- shared brand-configuration helper for the build scripts.
#
# The runtime hardcodes no language name (see src/kernel/brand.odin); every
# user-visible name is a `#config` constant chosen at build time. This helper
# turns the BRAND environment variable into the matching `-define:` flags and
# binary names, so every script parameterizes the same way:
#
#     ./build/build.sh all              # the default Lua 5.5.1 profile
#     BRAND=moon ./build/build.sh all   # a `moon`/`.moon`/`MOON_*` build
#
# BRAND=lua (the default) deliberately emits no branding defines, so the
# default brand is the one the PUC-Rio suite validates.
#
# Individual knobs can still be overridden: BRAND_DISPLAY, SOURCE_EXT,
# ENV_PREFIX. VM_THREADED selects the interpreter in single-mode wrappers: 1
# for threaded, 0 for switch, or unset for threaded on amd64/arm64 and switch
# elsewhere. Forcing threaded on an unsupported architecture is rejected.
# check.sh and vm-compare.sh explicitly handle both modes.
#
# Source this file, then use $BRAND_DEFINES (an array), $BRAND_EXE and
# $BRAND_COMPILER_EXE.

BRAND="${BRAND:-lua}"

BRAND_DEFINES=()
if [[ "$BRAND" != "lua" || -n "${BRAND_DISPLAY:-}" ||
      -n "${SOURCE_EXT:-}" || -n "${ENV_PREFIX:-}" ]]; then
    # "moon" -> "Moon": the conventional display spelling.
    _display="${BRAND_DISPLAY:-$(printf '%s%s' \
        "$(printf '%s' "${BRAND:0:1}" | tr '[:lower:]' '[:upper:]')" \
        "${BRAND:1}")}"
    _ext="${SOURCE_EXT:-.$BRAND}"
    _env="${ENV_PREFIX:-$(printf '%s' "$BRAND" | tr '[:lower:]' '[:upper:]')}"

    BRAND_DEFINES=(
        "-define:BRAND=$_display"
        "-define:BRAND_LOWER=$BRAND"
        "-define:SOURCE_EXT=$_ext"
        "-define:ENV_PREFIX=$_env"
        "-define:NATIVE_OPEN_FMT=${BRAND}open_%s"
    )
fi

# Shared by every wrapper that builds the kernel, including the CLI and
# rebranding tests. An unset variable passes no interpreter define.
if [[ ${VM_THREADED+x} ]]; then
    case "$VM_THREADED" in
        1) BRAND_DEFINES+=("-define:VM_THREADED=true") ;;
        0) BRAND_DEFINES+=("-define:VM_THREADED=false") ;;
        *) echo "VM_THREADED must be 0, 1, or unset (got '$VM_THREADED')." >&2; exit 1 ;;
    esac
fi

BRAND_EXE="$BRAND"
BRAND_COMPILER_EXE="${BRAND}c"
