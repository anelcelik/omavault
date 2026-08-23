#!/bin/bash
# Usage: decrypt-snapshot.sh <snapshot-dir>
# Reads a passphrase from stdin (one line), decrypts that snapshot's
# payload.tar.gpg into a fresh temp folder, and prints that folder's path.
# inspect-snapshot.sh and import.sh then operate on it exactly like a plain
# (unencrypted) snapshot dir, since once unpacked it has the same layout
# (manifest.json, README.txt, SHA256SUMS, config/, dotfiles/).
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./lib.sh

dir="${1:-}"
fail() { jq -n --arg e "$1" '{ok:false, error:$e}'; exit 1; }

[ -n "$dir" ] && [ -d "$dir" ] || fail "Snapshot folder not found."
[ -f "$dir/payload.tar.gpg" ] || fail "This snapshot isn't encrypted (no payload.tar.gpg)."

IFS= read -r passphrase
[ -n "${passphrase:-}" ] || fail "No passphrase entered."

# Memory-backed (tmpfs) location, not the USB stick or disk -- the
# decrypted plaintext should never land on durable storage. Fail closed
# rather than falling back to /tmp: /tmp is commonly disk-backed and not
# guaranteed private. Removed on every exit path via the trap below,
# including an unexpected early exit, so a botched decrypt can't leave
# plaintext sitting in tmpfs either.
base=$(verified_runtime_dir) || fail "Refusing to decrypt: $base"
tmpDir=$(mktemp -d "$base/omavault-decrypt-XXXXXX") || fail "Could not create a temp folder."
chmod 700 "$tmpDir"
trap 'passphrase=""; rm -rf "$tmpDir"' EXIT

# ---- Bound gpg's own output, not just what we check afterward. A
# hostile .gpg file can decompress to far more than its on-disk size (a
# compression bomb) -- without this, gpg would happily write the entire
# expanded payload to $tmpDir/.payload.tar before the totalBytes check
# below ever runs, exhausting the tmpfs (and the runtime's memory) first.
# `ulimit -f` is a producer-side, kernel-enforced cap on this subshell (so
# it hits gpg's own writes) in 512-byte blocks: gpg gets SIGXFSZ/EFBIG and
# stops the moment it crosses MAX_BACKUP_BYTES, well before that.
gpgErr="$tmpDir/.gpg-err"
if ! ( ulimit -f $((MAX_BACKUP_BYTES / 512))
       printf '%s' "$passphrase" | gpg --batch --yes --passphrase-fd 0 --pinentry-mode loopback \
         -d "$dir/payload.tar.gpg" >"$tmpDir/.payload.tar" 2>"$gpgErr" ); then
  fail "Wrong passphrase, this backup is corrupted, or the decrypted archive exceeds the $((MAX_BACKUP_BYTES / 1024 / 1024)) MiB limit for a config backup."
fi
passphrase=""

# ---- Validate the archive before extracting it -- this unpacks into RAM-
# backed tmpfs, and a corrupted or hostile .gpg file (a stolen/lost drive
# being tampered with and put back, say) shouldn't be able to make
# extraction itself misbehave. The checksum pass in import.sh afterward
# covers file *content*; this covers the archive *structure*: no member
# path allowed to escape tmpDir (absolute paths or ".." segments), and a
# sanity size cap since real config backups are KB-MB, not GB.
while IFS= read -r entry; do
  case "$entry" in
    /*|*/../*|../*|..)
      fail "Backup rejected: archive contains an unsafe path (\"$entry\")."
      ;;
  esac
done < <(tar -tf "$tmpDir/.payload.tar" 2>/dev/null)

# Belt-and-suspenders on top of the ulimit above: the ulimit already
# bounds .payload.tar itself to MAX_BACKUP_BYTES, so this can only ever
# trip on a malformed/inconsistent tar (it doesn't rely on the ulimit
# having fired correctly).
totalBytes=$(tar -tvf "$tmpDir/.payload.tar" 2>/dev/null | awk '{s+=$3} END{print s+0}')
if [ "$totalBytes" -gt "$MAX_BACKUP_BYTES" ]; then
  fail "Backup rejected: archive is implausibly large ($totalBytes bytes) for a config backup."
fi

if ! tar -xf "$tmpDir/.payload.tar" -C "$tmpDir"; then
  fail "Decrypted, but could not unpack the backup -- it may be corrupted."
fi
rm -f "$tmpDir/.payload.tar" "$gpgErr"
# manifest.json comes out of the tar itself now -- every OmaVault backup is
# fully encrypted, nothing (including manifest.json) is ever left plain
# next to payload.tar.gpg to copy from.

# Success: the caller (inspect-snapshot.sh, then import.sh, then
# cleanup-temp.sh once done) needs tmpDir to keep existing -- disarm the
# cleanup trap so only a failure path above removes it.
trap - EXIT
jq -n --arg tempDir "$tmpDir" '{ok:true, tempDir:$tempDir}'
