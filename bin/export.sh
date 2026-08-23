#!/bin/bash
# Usage: export.sh <comma-separated-category-ids> <destination-root> <new|latest> [encrypt]
# Copies the selected categories into <destination-root>/omavault/<snapshot>/
# as a mirrored plain-text folder tree (see lib.sh's header), then writes
# manifest.json + SHA256SUMS + README.txt and prints a JSON summary to stdout.
#
# If the 4th arg is the literal string "encrypt", a passphrase is read as
# one line from stdin afterwards, and everything except manifest.json is
# packed into payload.tar and symmetrically encrypted (gpg, AES256) as
# payload.tar.gpg, with the plaintext originals then deleted -- manifest.json
# stays plain so a stick can still be browsed (labels/file counts only, no
# content) without the passphrase.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./lib.sh

catsArg="${1:-}"
destRoot="${2:-}"
mode="${3:-new}"
encryptFlag="${4:-}"

fail() { jq -n --arg e "$1" '{ok:false, error:$e}'; exit 1; }

[ -n "$catsArg" ] || fail "No categories selected."
[ -n "$destRoot" ] || fail "No destination chosen."
[ -d "$destRoot" ] || fail "Destination \"$destRoot\" does not exist or is not mounted."
[ -w "$destRoot" ] || fail "Destination \"$destRoot\" is not writable."

vaultRoot="$destRoot/omavault"
if [ "$mode" = "latest" ]; then
  snapName="latest"
else
  snapName="snapshot-$(date +%Y%m%d_%H%M%S)"
fi
snapDir="$vaultRoot/$snapName"
mkdir -p "$snapDir" || fail "Could not create $snapDir"

IFS=',' read -r -a catIds <<<"$catsArg"
declare -A catLabel
while IFS=$'\t' read -r id label _desc _def; do catLabel["$id"]="$label"; done < <(list_category_meta)

categoriesJson="[]"
skippedList=()
errors=()

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
      rsyncFlags=(-a "${BINARY_RSYNC_EXCLUDES[@]}")
      [ -n "$extraExclude" ] && rsyncFlags+=($extraExclude)
      [ "$mode" = "latest" ] && rsyncFlags+=(--delete)
      if ! rsync "${rsyncFlags[@]}" "$src/" "$target/" 2>/tmp/omavault-rsync-err.$$; then
        errors+=("$label: rsync failed -- $(cat /tmp/omavault-rsync-err.$$ 2>/dev/null | tail -n1)")
      fi
      rm -f /tmp/omavault-rsync-err.$$
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
  echo "This folder is a plain, uncompressed, unencrypted copy of the config"
  echo "files listed below -- every file in here is exactly what it looks"
  echo "like, individually readable, diffable and greppable. Nothing is"
  echo "archived or hidden inside a bundled format."
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
  '{schemaVersion: ($version|tonumber), tool:$tool, createdAt:$createdAt, hostname:$hostname, mode:$mode, categories:$categories, skippedBinaryCount:$skippedCount}')
echo "$manifest" > "$snapDir/manifest.json"

# ---- Checksums, computed last so they cover README.txt and manifest.json
# too -- relative paths, verifiable with plain `sha256sum -c` from anywhere,
# no dependency on this plugin being installed. (Regenerated below, scoped
# to exclude manifest.json, if this snapshot ends up encrypted.)
( cd "$snapDir" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum ) > "$snapDir/SHA256SUMS"

encrypted=false
if [ "$encryptFlag" = "encrypt" ]; then
  IFS= read -r passphrase
  if [ -z "${passphrase:-}" ]; then
    fail "Encryption was requested but no passphrase was received."
  fi

  # manifest.json is the one file that stays plain outside the encrypted
  # blob (so a stick can be browsed -- labels/counts only -- without the
  # passphrase); recompute SHA256SUMS to match exactly what's about to be
  # packed, or a post-decrypt check would fail on a manifest.json entry
  # that was never extracted.
  ( cd "$snapDir" && find . -type f ! -name SHA256SUMS ! -name manifest.json -print0 | sort -z | xargs -0 sha256sum ) > "$snapDir/SHA256SUMS"

  # Built outside snapDir so tar isn't asked to archive its own in-progress
  # output file (harmless but noisy: "archive cannot contain itself").
  payloadTar=$(mktemp)
  if ! ( cd "$snapDir" && tar --exclude=manifest.json -cf "$payloadTar" . ); then
    rm -f "$payloadTar"
    passphrase=""
    fail "Could not package the backup for encryption."
  fi

  gpgErr=$(mktemp)
  if ! printf '%s' "$passphrase" | gpg --batch --yes --passphrase-fd 0 --pinentry-mode loopback \
      --symmetric --cipher-algo AES256 -o "$snapDir/payload.tar.gpg" "$payloadTar" 2>"$gpgErr"; then
    errMsg=$(tail -n2 "$gpgErr" 2>/dev/null)
    rm -f "$gpgErr" "$payloadTar" "$snapDir/payload.tar.gpg"
    passphrase=""
    fail "Encryption failed: ${errMsg:-gpg error}"
  fi
  rm -f "$gpgErr" "$payloadTar"
  passphrase=""

  # Everything is now duplicated inside payload.tar.gpg -- drop the
  # plaintext originals, keeping only manifest.json and the encrypted blob.
  find "$snapDir" -mindepth 1 -maxdepth 1 ! -name manifest.json ! -name payload.tar.gpg -exec rm -rf {} +
  manifest=$(jq '. + {encrypted:true}' <<<"$manifest")
  echo "$manifest" > "$snapDir/manifest.json"
  encrypted=true
fi

jq -n \
  --arg path "$snapDir" \
  --argjson categories "$categoriesJson" \
  --argjson totalFiles "$totalFiles" \
  --argjson totalBytes "$totalBytes" \
  --argjson skippedCount "${#skippedList[@]}" \
  --argjson encrypted "$encrypted" \
  --argjson errors "$(printf '%s\n' "${errors[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
  '{ok:true, path:$path, categories:$categories, totalFiles:$totalFiles, totalBytes:$totalBytes, skippedBinaryCount:$skippedCount, encrypted:$encrypted, errors:$errors}'
