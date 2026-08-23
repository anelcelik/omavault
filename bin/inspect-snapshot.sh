#!/bin/bash
# Usage: inspect-snapshot.sh <snapshot-dir>
# Reads a snapshot's manifest + verifies every file against SHA256SUMS,
# without touching anything on this machine. Used before Import shows its
# category checklist, and to render a PASS/FAIL integrity badge.
#
# Every OmaVault backup is encrypted (see export.sh), so a snapshot straight
# off a stick has nothing readable pre-decrypt -- not even manifest.json.
# Call decrypt-snapshot.sh first and re-inspect its tempDir; this script
# reports that "nothing is readable yet" state as {locked:true}, not an
# error, whenever it finds payload.tar.gpg with no manifest.json alongside
# it. A dir that already has manifest.json (a decrypt-snapshot.sh tempDir,
# or a pre-mandatory-encryption legacy plain snapshot) is inspected fully.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

dir="${1:-}"
fail() { jq -n --arg e "$1" '{ok:false, error:$e}'; exit 1; }

[ -n "$dir" ] && [ -d "$dir" ] || fail "Snapshot folder not found."
manifest="$dir/manifest.json"
if [ ! -f "$manifest" ]; then
  if [ -f "$dir/payload.tar.gpg" ]; then
    jq -n --arg path "$dir" \
      '{ok:true, path:$path, encrypted:true, locked:true, manifest:null, checksumOk:false, checksumTotal:0, failedFiles:[]}'
    exit 0
  fi
  fail "No manifest.json or payload.tar.gpg in this folder -- not an OmaVault snapshot."
fi
jq -e . "$manifest" >/dev/null 2>&1 || fail "manifest.json is not valid JSON."

checksumOk=true
failedFiles="[]"
checksumTotal=0
if [ -f "$dir/SHA256SUMS" ]; then
  out=$(cd "$dir" && sha256sum -c SHA256SUMS 2>&1)
  checksumTotal=$(wc -l < "$dir/SHA256SUMS")
  if grep -q ': FAILED' <<<"$out"; then
    checksumOk=false
    failedFiles=$(grep ': FAILED' <<<"$out" | sed -E 's/: FAILED.*$//' | jq -R . | jq -s '.')
  fi
else
  checksumOk=false
fi

jq -n \
  --slurpfile m "$manifest" \
  --argjson checksumOk "$checksumOk" \
  --argjson checksumTotal "$checksumTotal" \
  --argjson failedFiles "$failedFiles" \
  --arg path "$dir" \
  '{ok:true, path:$path, manifest:$m[0], checksumOk:$checksumOk, checksumTotal:$checksumTotal, failedFiles:$failedFiles, encrypted:($m[0].encrypted // false), locked:false}'
