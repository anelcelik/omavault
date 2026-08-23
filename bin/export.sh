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
# here matches what a real export would actually try to copy.
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
      stats=$(rsync -a --dry-run --stats "${BINARY_RSYNC_EXCLUDES[@]}" $extraExclude "$src/" /tmp/omavault-count-target-unused/ 2>/dev/null)
      b=$(awk -F': ' '/Total transferred file size/ {gsub(/[, bytes]/,"",$2); print $2}' <<<"$stats")
      projectedBytes=$((projectedBytes + ${b:-0}))
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
rsyncErrFile="$snapDir/.rsync-err"

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
        cp -p -- "$src" "$target" && { catFiles=$((catFiles + 1)); catBytes=$((catBytes + $(stat -c%s -- "$src" 2>/dev/null || echo 0))); }
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
      if ! rsync "${rsyncFlags[@]}" "$src/" "$target/" 2>"$rsyncErrFile"; then
        errors+=("$label: rsync failed -- $(cat "$rsyncErrFile" 2>/dev/null | tail -n1)")
      fi
      rm -f "$rsyncErrFile"
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
find "$snapDir" -type d -empty -delete 2>/dev/null

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

mkdir -p "$finalDir" || fail "Could not create $finalDir on the destination."

gpgErr="$snapDir/.gpg-err"
if ! printf '%s' "$passphrase" | gpg --batch --yes --passphrase-fd 0 --pinentry-mode loopback \
    --symmetric --cipher-algo AES256 -o "$finalDir/payload.tar.gpg" "$payloadTar" 2>"$gpgErr"; then
  errMsg=$(tail -n2 "$gpgErr" 2>/dev/null)
  rm -f "$finalDir/payload.tar.gpg"
  fail "Encryption failed: ${errMsg:-gpg error}"
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
