#!/bin/bash
# Usage: decrypt-snapshot.sh <snapshot-dir>
# Reads a passphrase from stdin (one line), decrypts that snapshot's
# payload.tar.gpg into a fresh temp folder, and prints that folder's path.
# inspect-snapshot.sh and import.sh then operate on it exactly like a plain
# (unencrypted) snapshot dir, since once unpacked it has the same layout
# (manifest.json, README.txt, SHA256SUMS, config/, dotfiles/).
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

dir="${1:-}"
fail() { jq -n --arg e "$1" '{ok:false, error:$e}'; exit 1; }

[ -n "$dir" ] && [ -d "$dir" ] || fail "Snapshot folder not found."
[ -f "$dir/payload.tar.gpg" ] || fail "This snapshot isn't encrypted (no payload.tar.gpg)."

IFS= read -r passphrase
[ -n "${passphrase:-}" ] || fail "No passphrase entered."

# Memory-backed (tmpfs) location, not the USB stick or disk -- the
# decrypted plaintext should never land on durable storage.
base="${XDG_RUNTIME_DIR:-/tmp}"
tmpDir=$(mktemp -d "$base/omavault-decrypt-XXXXXX") || fail "Could not create a temp folder."
chmod 700 "$tmpDir"

gpgErr=$(mktemp)
if ! printf '%s' "$passphrase" | gpg --batch --yes --passphrase-fd 0 --pinentry-mode loopback \
    -d "$dir/payload.tar.gpg" >"$tmpDir/payload.tar" 2>"$gpgErr"; then
  rm -f "$gpgErr"
  rm -rf "$tmpDir"
  passphrase=""
  fail "Wrong passphrase, or this backup is corrupted."
fi
rm -f "$gpgErr"
passphrase=""

if ! tar -xf "$tmpDir/payload.tar" -C "$tmpDir"; then
  rm -rf "$tmpDir"
  fail "Decrypted, but could not unpack the backup -- it may be corrupted."
fi
rm -f "$tmpDir/payload.tar"
# manifest.json comes out of the tar itself now -- every OmaVault backup is
# fully encrypted, nothing (including manifest.json) is ever left plain
# next to payload.tar.gpg to copy from.

jq -n --arg tempDir "$tmpDir" '{ok:true, tempDir:$tempDir}'
