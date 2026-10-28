#!/bin/bash
# NotProtonGPTK: boots a throwaway prefix on a built NotProton Wine and runs a 64 bit and a
# 32 bit (WoW64) program in it, the two things Steam's install scripts need first.
#
#   wine/smoke.sh [path/to/Wine]     default: scratch/cxwine/dist/Wine
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-$here/../scratch/cxwine/dist/Wine}"
root="$(cd "$root" && pwd)"
loader="$root/lib/wine/x86_64-unix/wine"
export WINESERVER="$root/bin/wineserver"
export WINELOADER="$loader"
export WINEDLLPATH="$root/lib/wine/x86_64-windows:$root/lib/wine/x86_64-unix"
WINEPREFIX="$(mktemp -d "${TMPDIR:-/tmp}/np-smoke.XXXXXX")"
export WINEPREFIX
export WINEDEBUG=-all
trap '"$WINESERVER" -k >/dev/null 2>&1 || true; rm -rf "$WINEPREFIX"' EXIT

fail() { echo "==> smoke: $*" >&2; exit 1; }

# Each step gets a deadline: a Wine that hangs on a dialog must fail the job, not stall it.
within() { # seconds command...
    local seconds="$1"
    shift
    perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}

version="$(within 60 "$loader" --version)" || fail "the loader did not start"
echo "==> smoke: $version"
case "$version" in wine-11.*) ;; *) fail "expected Wine 11, got $version" ;; esac

within 600 "$loader" wineboot --init || fail "wineboot failed"
"$WINESERVER" -w
[ -f "$WINEPREFIX/system.reg" ] || fail "wineboot made no registry"
[ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || fail "the prefix has no syswow64"

out="$(within 120 "$loader" cmd /c echo np64 | tr -d '\r')" || fail "64 bit cmd failed"
[ "$out" = np64 ] || fail "64 bit cmd printed '$out'"
out="$(within 120 "$loader" 'C:\windows\syswow64\cmd.exe' /c echo np32 | tr -d '\r')" || fail "32 bit cmd failed"
[ "$out" = np32 ] || fail "32 bit cmd printed '$out'"
echo "==> smoke: prefix boots, 64 bit and 32 bit programs run"
