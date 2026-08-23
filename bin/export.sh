#!/bin/bash
# Usage: export.sh <comma-separated-category-ids> <destination-root> <new|latest>
# Copies the selected categories into <destination-root>/omavault/<snapshot>/
# as a mirrored plain-text folder tree in a scratch dir (see lib.sh's
# header), writes manifest.json + SHA256SUMS + README.txt, then ALWAYS
# encrypts: a passphrase is read as one line from stdin (required -- fails
# fast if none is given), and every one of those files, manifest.json
# included, is packed into payload.tar and symmetrically encrypted (gpg,
# AES256) as payload.tar.gpg. The plaintext scratch copy is then deleted,
# leaving only payload.tar.gpg on disk -- nothing about a backup (contents,
# category labels, even the source hostname) is readable without the
# passphrase. There is no unencrypted-export mode: a lost/stolen backup
# drive must not hand over anything readable.
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

# ---- Encrypt. There is no plain-text mode: everything built above,
# manifest.json included, is packed and encrypted, then deleted from disk --
# nothing about this backup (contents, file names, categories, even that it
# came from this host) is readable without the passphrase. Built outside
# snapDir so tar isn't asked to archive its own in-progress output file
# (harmless but noisy: "archive cannot contain itself").
payloadTar=$(mktemp)
if ! ( cd "$snapDir" && tar -cf "$payloadTar" . ); then
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

# Everything is now duplicated inside payload.tar.gpg -- drop every
# plaintext original, keeping only the encrypted blob itself.
find "$snapDir" -mindepth 1 -maxdepth 1 ! -name payload.tar.gpg -exec rm -rf {} +

jq -n \
  --arg path "$snapDir" \
  --argjson categories "$categoriesJson" \
  --argjson totalFiles "$totalFiles" \
  --argjson totalBytes "$totalBytes" \
  --argjson skippedCount "${#skippedList[@]}" \
  --argjson errors "$(printf '%s\n' "${errors[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
  '{ok:true, path:$path, categories:$categories, totalFiles:$totalFiles, totalBytes:$totalBytes, skippedBinaryCount:$skippedCount, encrypted:true, errors:$errors}'
