#!/bin/bash
# Usage: export.sh <comma-separated-category-ids> <destination-root> <new|latest>
# Copies the selected categories into a private tmpfs scratch dir as a
# mirrored plain-text folder tree (see lib.sh's header), writes
# manifest.json + SHA256SUMS + README.txt there, then ALWAYS encrypts: a
# passphrase is read as one line from stdin (required -- fails fast if
# none is given), and every one of those files, manifest.json included, is
# packed into payload.tar and symmetrically encrypted (gpg, AES256) as
# payload.tar.gpg. Only that encrypted blob is ever written to
# <destination-root>/omavault/<snapshot>/ -- the plaintext scratch dir is
# built and torn down entirely under $XDG_RUNTIME_DIR (RAM-backed tmpfs,
# never the destination or a disk-backed tmp), and is removed via a trap
# on every exit path, success or failure, so a mid-run error can't leave
# plaintext behind either in the scratch dir or on the destination. There
# is no unencrypted-export mode: a lost/stolen backup drive must never see
# plaintext at any point, not even transiently -- deleting a file after
# writing it to real (especially flash) media does not reliably erase it.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./lib.sh

catsArg="${1:-}"
destRoot="${2:-}"
mode="${3:-new}"

fail() { jq -n --arg e "$1" '{ok:false, error:$e}'; exit 1; }

[ -n "$catsArg" ] || fail "No categories selected."
[ -n "$destRoot" ] || fail "No destination chosen."
[ -d "$destRoot" ] || fail "Destination \"$destRoot\" does not exist or is not mounted."
[ -w "$destRoot" ] || fail "Destination \"$destRoot\" is not writable."

# Read the passphrase up front so a typo'd/empty one fails fast, before any
# copying happens.
IFS= read -r passphrase
if [ -z "${passphrase:-}" ]; then
  fail "A passphrase is required -- every OmaVault backup is encrypted, there is no plain-text export."
fi

IFS=',' read -r -a catIds <<<"$catsArg"
declare -A catLabel
while IFS=$'\t' read -r id label _desc _def; do catLabel["$id"]="$label"; done < <(list_category_meta)

# ---- Bound the total size of what's about to be staged into tmpfs,
# before any of it is actually copied there -- not just checked
# afterward. Unlike the decrypt path there's no attacker-controlled
# compression amplification here (this reads real local files 1:1), so a
# cheap read-only dry-run scan is enough: nothing gets written until this
# passes. Mirrors list-categories.sh's estimate technique (same dry-run
# rsync --stats trick, same name-based excludes) so the number checked
# here matches what a real export would actually try to copy -- --copy-links
# in particular has to match the real copy step below (also --copy-links)
# exactly: without it here, this dry-run would measure a symlink as just
# the link itself (tiny), while the real copy dereferences it and stages
# whatever it actually points to -- letting a small symlink to a huge
# file or tree pass this gate and then blow up staging anyway.
projectedBytes=0
for id in "${catIds[@]}"; do
  [ -n "$id" ] || continue
  while IFS=$'\t' read -r src rel kind extraExclude; do
    [ -z "$src" ] && continue
    if [ "$kind" = "file" ]; then
      [ -f "$src" ] || continue
      projectedBytes=$((projectedBytes + $(stat -c%s -- "$src" 2>/dev/null || echo 0)))
    else
      [ -d "$src" ] || continue
      # Fail closed, not open, if this dry-run can't be trusted: a failed
      # rsync or an unparseable stats line falling back to "0 bytes"
      # would let an actually-oversized category slip straight through
      # this gate instead of being caught by it.
      if ! stats=$(rsync -a --copy-links --dry-run --stats "${BINARY_RSYNC_EXCLUDES[@]}" $extraExclude "$src/" /tmp/omavault-count-target-unused/ 2>/dev/null); then
        fail "Could not estimate the size of \"$rel\" -- refusing to export without a reliable size check."
      fi
      b=$(awk -F': ' '/Total transferred file size/ {gsub(/[, bytes]/,"",$2); print $2}' <<<"$stats")
      case "$b" in
        ''|*[!0-9]*) fail "Could not estimate the size of \"$rel\" -- refusing to export without a reliable size check." ;;
      esac
      projectedBytes=$((projectedBytes + b))
    fi
  done < <(category_entries "$id")
done
if [ "$projectedBytes" -gt "$MAX_BACKUP_BYTES" ]; then
  fail "Selected categories total $projectedBytes bytes, over the $((MAX_BACKUP_BYTES / 1024 / 1024)) MiB limit for a config backup -- deselect some categories."
fi

# ---- Private tmpfs scratch dir. Everything plaintext lives only here,
# never on the destination. mode 700, and removed on every exit path via
# the trap below -- including a mid-run failure, so a botched export can't
# leave plaintext sitting around either here or (since we never write
# there until the very end) on the destination. Fail closed rather than
# falling back to /tmp: /tmp is commonly disk-backed and not guaranteed
# private, so silently degrading to it would put plaintext config
# contents on durable storage without ever telling the caller.
scratchBase=$(verified_runtime_dir) || fail "Refusing to export: $scratchBase"
snapDir=$(mktemp -d "$scratchBase/omavault-export-XXXXXX") || fail "Could not create a private scratch directory."
chmod 700 "$snapDir"
trap 'passphrase=""; rm -rf "$snapDir"' EXIT

vaultRoot="$destRoot/omavault"
if [ "$mode" = "latest" ]; then
  snapName="latest"
else
  snapName="snapshot-$(date +%Y%m%d_%H%M%S)"
fi
finalDir="$vaultRoot/$snapName"

categoriesJson="[]"
skippedList=()
errors=()

# ---- Real, cumulative bytes actually written to $snapDir so far, updated
# as staging happens (not just checked once after the whole loop below
# finishes). The preflight above and the per-file ulimit caps during
# copying each close one gap, but neither bounds the *aggregate*: many
# files that each individually pass ulimit can still sum past
# MAX_BACKUP_BYTES while still mid-copy, and a source tree or symlink
# target swapped out right after preflight would only be caught once
# everything downstream of it had already been written to tmpfs. This
# counter is what lets both branches below fail the instant the running
# total crosses the cap, instead of only once the whole loop returns.
stagedBytes=0

for id in "${catIds[@]}"; do
  [ -n "$id" ] || continue
  label="${catLabel[$id]:-$id}"
  catFiles=0
  catBytes=0
  hadEntry=0
  while IFS=$'\t' read -r src rel kind extraExclude; do
    [ -z "$src" ] && continue
    if [ "$kind" = "file" ]; then
      [ -f "$src" ] || continue
    else
      [ -d "$src" ] || continue
    fi
    hadEntry=1
    target="$snapDir/$rel"
    if [ "$kind" = "file" ]; then
      mkdir -p "$(dirname "$target")"
      if is_text_file "$src"; then
        # Producer-bound, not just preflight-checked: `cp` dereferences a
        # symlink source by default too, so a dotfile that's actually a
        # symlink to something huge would otherwise be copied in full
        # before anything downstream could object. `ulimit -f` is a
        # kernel-enforced per-file cap on this subshell's own writes --
        # cp gets SIGXFSZ/EFBIG and stops the instant it crosses
        # MAX_BACKUP_BYTES, the same producer-bound pattern used for
        # gpg in decrypt-snapshot.sh.
        if ( ulimit -f $((MAX_BACKUP_BYTES / 512)); cp -p -- "$src" "$target" ); then
          sz=$(stat -c%s -- "$src" 2>/dev/null || echo 0)
          catFiles=$((catFiles + 1)); catBytes=$((catBytes + sz))
          # Cumulative check right here, not just this one file's own
          # ulimit cap: this "file" branch only ever handles a handful of
          # dotfiles per export, but each one individually passing its own
          # per-file cap says nothing about their sum. stagedBytes carries
          # real bytes written across every category so far, so this
          # catches the aggregate the moment it's crossed.
          stagedBytes=$((stagedBytes + sz))
          if [ "$stagedBytes" -gt "$MAX_BACKUP_BYTES" ]; then
            fail "Staging exceeded the $((MAX_BACKUP_BYTES / 1024 / 1024)) MiB limit for a config backup while copying \"$rel\" -- deselect some categories."
          fi
        else
          fail "Could not stage \"$rel\" -- it may exceed the $((MAX_BACKUP_BYTES / 1024 / 1024)) MiB per-file limit for a config backup (a symlink to something unexpectedly large?)."
        fi
      else
        skippedList+=("$rel (source: $src)")
      fi
    else
      mkdir -p "$target"
      # --copy-links: dereference any symlink in the live tree into its
      # real target content, rather than preserving it as a symlink.
      # decrypt-snapshot.sh now rejects a whole backup outright if it
      # contains any symlink member, so without this, a perfectly normal
      # symlinked dotfile setup (e.g. stow-managed configs) would silently
      # produce a backup that's entirely useless the moment someone tries
      # to restore it -- the worst possible time to find out.
      rsyncFlags=(-a --copy-links "${BINARY_RSYNC_EXCLUDES[@]}")
      [ -n "$extraExclude" ] && rsyncFlags+=($extraExclude)
      [ "$mode" = "latest" ] && rsyncFlags+=(--delete)
      # ---- Staged one file at a time, with stagedBytes checked after
      # every single one -- not one bulk rsync call left to run to
      # completion and checked afterward (that was the actual gap: a
      # background rsync polled from *outside* it can finish writing an
      # entire tree of small sub-cap files faster than any poll interval
      # can observe -- measured at 400 files/27MB in ~0.12s on tmpfs, well
      # under even a tight poll tick -- so a "run it, then poll it"
      # approach was tried here and confirmed unable to catch a fast local
      # copy before the whole aggregate had already landed). Checking
      # synchronously, in the same loop that performs each write, is the
      # only way to guarantee the cap is seen before the next file starts.
      #
      # rsync still owns the file *enumeration* -- a --dry-run pass with
      # --out-format emits exactly the (itemize-code, size, relative path)
      # triples the real transfer would produce, so the exclude patterns
      # and --copy-links dereferencing stay byte-for-byte the same as
      # before; nothing here re-implements rsync's filter matching. %l is
      # already the *post-dereference* size for a symlink source, matching
      # what a real copy would actually write.
      dryRunErr="$snapDir/.rsync-dryrun-err"
      if ! dryRunOut=$(rsync "${rsyncFlags[@]}" --dry-run --out-format='%i,%l,%n' "$src/" "$target/" 2>"$dryRunErr"); then
        errors+=("$label: rsync failed -- $(cat "$dryRunErr" 2>/dev/null | tail -n1)")
      else
        while IFS=',' read -r itemize _size fname; do
          [ -z "$fname" ] && continue
          # Only regular-file transfer lines (itemize starts ">f"); skip
          # directory-create lines ("cd...") and anything else rsync's
          # --out-format can emit -- mkdir -p below handles directories.
          case "$itemize" in
            '>f'*) ;;
            *) continue ;;
          esac
          ftarget="$target/$fname"
          fsrc="$src/$fname"
          mkdir -p "$(dirname "$ftarget")"
          # Same producer-bound ulimit as the "file" branch above: caps
          # this one file's own write (a dereferenced symlink to
          # something unexpectedly huge can't blow past the cap on its
          # own), while the stagedBytes check right after bounds the
          # running sum across every file staged so far, in every
          # category -- the actual cumulative gate.
          if ( ulimit -f $((MAX_BACKUP_BYTES / 512)); cp -p -- "$fsrc" "$ftarget" ) 2>/dev/null; then
            sz=$(stat -c%s -- "$ftarget" 2>/dev/null || echo 0)
            catFiles=$((catFiles + 1)); catBytes=$((catBytes + sz))
            stagedBytes=$((stagedBytes + sz))
            if [ "$stagedBytes" -gt "$MAX_BACKUP_BYTES" ]; then
              fail "Staging exceeded the $((MAX_BACKUP_BYTES / 1024 / 1024)) MiB limit for a config backup while copying \"$rel/$fname\" -- deselect some categories."
            fi
          else
            errors+=("$label: could not stage \"$fname\" (source: $fsrc)")
          fi
        done <<<"$dryRunOut"
      fi
      rm -f "$dryRunErr"
    fi
  done < <(category_entries "$id")

  if [ "$hadEntry" = "0" ]; then
    continue
  fi

  categoriesJson=$(jq --arg id "$id" --arg label "$label" '. + [{id:$id, label:$label}]' <<<"$categoriesJson")
done

# Content-sniffing pass: catch binaries that slipped through the name-based
# rsync excludes (no recognizable extension). Removes them from the
# snapshot and records what was skipped so the README/manifest stay honest
# about what didn't make it in.
while IFS= read -r -d '' f; do
  case "$f" in
    "$snapDir"/manifest.json|"$snapDir"/README.txt|"$snapDir"/SHA256SUMS) continue ;;
  esac
  if ! is_text_file "$f"; then
    skippedList+=("${f#"$snapDir"/} (binary content)")
    rm -f -- "$f"
  fi
done < <(find "$snapDir" -type f -print0)

# Drop directories left empty by the binary-stripping pass above.
# -mindepth 1: without it, GNU find's post-order -delete can cascade all
# the way up to $snapDir itself once every subdirectory under it is
# empty too (e.g. every selected category ended up filtered out, or was
# nothing but a since-dereferenced-away symlink) -- silently deleting the
# scratch dir this whole script still needs for README.txt/manifest.json/
# SHA256SUMS/the tar right below, turning a clean "nothing to back up"
# case into a confusing "No such file or directory" chain instead.
find "$snapDir" -mindepth 1 -type d -empty -delete 2>/dev/null

# Recompute real file counts per category now that binaries are stripped.
categoriesJson=$(jq -c '.[]' <<<"$categoriesJson" | while read -r c; do
  id=$(jq -r '.id' <<<"$c")
  rels=$(category_entries "$id" | cut -f2 | sort -u)
  files=0; bytes=0
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    p="$snapDir/$rel"
    if [ -f "$p" ]; then
      files=$((files + 1)); bytes=$((bytes + $(stat -c%s -- "$p" 2>/dev/null || echo 0)))
    elif [ -d "$p" ]; then
      n=$(find "$p" -type f | wc -l)
      b=$(find "$p" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
      files=$((files + n)); bytes=$((bytes + b))
    fi
  done <<<"$rels"
  jq -c --argjson f "$files" --argjson b "$bytes" '. + {fileCount:$f, bytes:$b}' <<<"$c"
done | jq -s '.')

totalFiles=$(jq '[.[].fileCount] | add // 0' <<<"$categoriesJson")
totalBytes=$(jq '[.[].bytes] | add // 0' <<<"$categoriesJson")

# ---- Authoritative size check against what's actually sitting in
# tmpfs now, not an estimate. The projectedBytes preflight, the per-file
# ulimit during copying, and the stagedBytes cumulative gate enforced
# live during the copy loop above each close one layer of this -- but
# this is still the final backstop: it's real `find`-measured bytes of
# what actually got staged, checked once more right before anything is
# packed and encrypted, so even a discrepancy from the binary-stripping
# pass just above (which removes files after the cumulative gate already
# counted them, so it can only ever push totalBytes down, never up) is
# caught here rather than assumed. Belt-and-suspenders, not the only
# guard -- but nothing gets packed without passing it regardless.
if [ "$totalBytes" -gt "$MAX_BACKUP_BYTES" ]; then
  fail "Staged backup came to $totalBytes bytes, over the $((MAX_BACKUP_BYTES / 1024 / 1024)) MiB limit for a config backup -- deselect some categories."
fi

# ---- README.txt: human-readable even without the plugin installed ----
{
  echo "OmaVault backup"
  echo "================"
  echo
  echo "Created:  $(date -Iseconds)"
  echo "Host:     $(hostname)"
  echo "Mode:     $mode"
  echo
  echo "This backup is encrypted (AES-256 via gpg) -- decrypt it with the"
  echo "passphrase it was created with, either through OmaVault's Import,"
  echo "or by hand:"
  echo "  gpg -d payload.tar.gpg | tar -x"
  echo "Once decrypted, the files listed below are exactly what they look"
  echo "like: individually readable, diffable and greppable, nothing hidden"
  echo "inside a bespoke format beyond the one tar+gpg wrapping layer."
  echo
  echo "Layout mirrors your home directory:"
  echo "  config/omarchy/...   -> ~/.config/omarchy/..."
  echo "  config/hypr/...      -> ~/.config/hypr/..."
  echo "  config/<terminal>/...-> ~/.config/<terminal>/..."
  echo "  dotfiles/.bashrc etc -> ~/.bashrc etc"
  echo
  echo "Categories included in this backup:"
  jq -r '.[] | "  - \(.label) (\(.fileCount) files)"' <<<"$categoriesJson"
  echo
  echo "SHA256SUMS lists a checksum for every file here -- verify the whole"
  echo "backup wasn't corrupted or altered with:"
  echo "  cd \"$(basename "$snapDir")\" && sha256sum -c SHA256SUMS"
  echo
  echo "To restore: open OmaVault on the new machine, choose Import, point"
  echo "it at this folder (or just plug in this stick, it will be found"
  echo "automatically), and pick what to bring back."
  if [ "${#skippedList[@]}" -gt 0 ]; then
    echo
    echo "Skipped (not plain text, left out on purpose):"
    for s in "${skippedList[@]}"; do echo "  - $s"; done
  fi
} > "$snapDir/README.txt"

manifest=$(jq -n \
  --arg version "1" \
  --arg tool "omavault" \
  --arg createdAt "$(date -Iseconds)" \
  --arg hostname "$(hostname)" \
  --arg mode "$mode" \
  --argjson categories "$categoriesJson" \
  --argjson skippedCount "${#skippedList[@]}" \
  '{schemaVersion: ($version|tonumber), tool:$tool, createdAt:$createdAt, hostname:$hostname, mode:$mode, categories:$categories, skippedBinaryCount:$skippedCount, encrypted:true}')
echo "$manifest" > "$snapDir/manifest.json"

# ---- Checksums cover every file about to be packed, including
# manifest.json and README.txt -- relative paths, so `sha256sum -c` still
# works by hand after a manual `gpg -d | tar -x`, no dependency on this
# plugin being installed.
( cd "$snapDir" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum ) > "$snapDir/SHA256SUMS"

# ---- Encrypt, entirely within the private scratch dir. There is no
# plain-text mode: everything built above, manifest.json included, is
# packed and encrypted. payloadTar is built inside the same tmpfs scratch
# dir (not ambient /tmp, which may not be RAM-backed) via a name that
# can't collide with anything real, then removed by the trap along with
# everything else once the destination has the final encrypted blob.
payloadTar="$snapDir/.payload.tar"
if ! ( cd "$snapDir" && tar --exclude=.payload.tar -cf "$payloadTar" . ); then
  fail "Could not package the backup for encryption."
fi

# ---- finalDir/finalFile are predictable paths (omavault/latest or
# omavault/snapshot-<timestamp>), so a pre-existing symlink planted at
# either one must never be followed: gpg's own -o open (no O_EXCL) and a
# naive mkdir -p would both happily write/truncate through it into
# whatever real file or directory the symlink points at. Fail closed on
# any such unexpected target rather than silently walking through it.
[ -L "$finalDir" ] && fail "Refusing to export: $finalDir is a symlink, not a real backup directory."
mkdir -p "$finalDir" || fail "Could not create $finalDir on the destination."

finalFile="$finalDir/payload.tar.gpg"
if [ -L "$finalFile" ]; then
  fail "Refusing to export: $finalFile is a symlink -- will not write through it."
elif [ -e "$finalFile" ] && [ ! -f "$finalFile" ]; then
  fail "Refusing to export: $finalFile already exists and is not a plain file."
fi
# A pre-existing plain file here (mode=latest overwriting last time's
# payload.tar.gpg) is expected and fine -- it gets replaced atomically by
# the rename below, not written through in place.

# Write the encrypted blob to a freshly, exclusively created random
# sibling first (its name is unguessable, so nothing could have
# pre-planted a symlink at it), validate what gpg actually produced, and
# only then atomically rename it onto finalFile. rename(2) never follows
# a destination symlink -- it replaces whatever directory entry is there
# -- so even if finalFile were re-swapped for a symlink in the instant
# between the checks above and this rename, the symlink itself would be
# unlinked and replaced, never written through.
tmpOut=$(mktemp "$finalDir/.payload.tar.gpg.XXXXXX") || fail "Could not create a temporary output file on the destination."

gpgErr="$snapDir/.gpg-err"
if ! printf '%s' "$passphrase" | gpg --batch --yes --passphrase-fd 0 --pinentry-mode loopback \
    --symmetric --cipher-algo AES256 -o "$tmpOut" "$payloadTar" 2>"$gpgErr"; then
  errMsg=$(tail -n2 "$gpgErr" 2>/dev/null)
  rm -f "$tmpOut"
  fail "Encryption failed: ${errMsg:-gpg error}"
fi

if [ -L "$tmpOut" ] || [ ! -f "$tmpOut" ] || [ ! -s "$tmpOut" ]; then
  rm -f "$tmpOut"
  fail "Encryption output looked wrong -- refusing to publish it."
fi

if ! mv -f -- "$tmpOut" "$finalFile"; then
  rm -f "$tmpOut"
  fail "Could not move the encrypted backup into place on the destination."
fi

# scratchDir (plaintext snapDir, payloadTar, gpgErr, everything) is removed
# by the trap below on exit -- nothing plaintext was ever written to the
# destination at any point, only the encrypted blob just above.

jq -n \
  --arg path "$finalDir" \
  --argjson categories "$categoriesJson" \
  --argjson totalFiles "$totalFiles" \
  --argjson totalBytes "$totalBytes" \
  --argjson skippedCount "${#skippedList[@]}" \
  --argjson errors "$(printf '%s\n' "${errors[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
  '{ok:true, path:$path, categories:$categories, totalFiles:$totalFiles, totalBytes:$totalBytes, skippedBinaryCount:$skippedCount, encrypted:true, errors:$errors}'
