#!/bin/sh
set -eu
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
body=$(sed -n '/^cross_over_trial_active() {$/,/^}$/p' "$SRC")
[ -n "$body" ] || { echo 'missing trial check'; exit 1; }
eval "$body"
CX_ROOT="$work/runner"
HOME="$work/home"
mkdir -p "$CX_ROOT" "$HOME/Library/Preferences"
# These fixtures deliberately contain no paid license.
# shellcheck disable=SC2329
date() { echo 1700000100; }
pass() { (cross_over_trial_active) || { echo "FAIL: $1"; exit 1; }; }
refuse() { if (cross_over_trial_active); then echo "FAIL: $1"; exit 1; fi; }
pass 'paid runner without a trial record'
printf '1700000000 1701209600\n' > "$CX_ROOT/notproton-trial-expires"
pass 'active trial'
printf '1698790500 1700000100\n' > "$CX_ROOT/notproton-trial-expires"
refuse 'exact expiry'
printf '1700000101 1701209701\n' > "$CX_ROOT/notproton-trial-expires"
refuse 'future start'
for record in '' '0 1' 'bad date' '1700000000 1701209600 extra' '1700000000 999999999999999999999999'; do
  printf '%s\n' "$record" > "$CX_ROOT/notproton-trial-expires"
  refuse "malformed record [$record]"
done
mkdir -p "$CX_ROOT/share/crossover/data"
/usr/bin/openssl genrsa -out "$work/private.pem" 2048 2>/dev/null
/usr/bin/openssl rsa -in "$work/private.pem" -pubout -out "$CX_ROOT/share/crossover/data/tie.pub" 2>/dev/null
license="$HOME/Library/Preferences/com.codeweavers.CrossOver.license"
printf '[crossmac]\ncustomer=Test\n' > "$license"
printf '1698790400 1700000000\n' > "$CX_ROOT/notproton-trial-expires"
refuse 'unsigned license does not unlock an expired trial'
for digest in sha256 sha1; do
  sidecar=sha256
  [ "$digest" != sha1 ] || sidecar=sig
  /usr/bin/openssl dgst "-$digest" -sign "$work/private.pem" -out "$HOME/Library/Preferences/com.codeweavers.CrossOver.$sidecar" "$license"
  pass "purchase overrides expiry ($digest)"
  rm "$HOME/Library/Preferences/com.codeweavers.CrossOver.$sidecar"
done
printf 'trialcheck: all checks passed\n'
