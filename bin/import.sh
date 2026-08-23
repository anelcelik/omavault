#!/bin/bash
# Usage: import.sh <snapshot-dir> <comma-separated-category-ids>
# Verifies checksums for just the selected categories, backs up whatever
# already lives at each real destination (into
# ~/.local/state/omavault/pre-restore-<timestamp>/), then copies the
# snapshot's files into place. Never deletes existing live files that
# aren't present in the snapshot -- restore only adds/overwrites.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./lib.sh

snapDir="${1:-}"
catsArg="${2:-}"

fail() { jq -n --arg e "$1" '{ok:false, error:$e}'; exit 1; }

[ -n "$snapDir" ] && [ -d "$snapDir" ] || fail "Snapshot folder not found."
[ -f "$snapDir/manifest.json" ] || fail "No manifest.json -- not an OmaVault snapshot."
[ -n "$catsArg" ] || fail "No categories selected."

IFS=',' read -r -a catIds <<<"$catsArg"
# Labels come from the snapshot's own manifest, not this machine's category
# list -- a fresh machine won't have e.g. ~/.config/hypr yet, so
# list_category_meta wouldn't offer a label for it at all.
declare -A catLabel
while IFS=$'\t' read -r id label; do catLabel["$id"]="$label"; done < <(jq -r '.categories[]? | "\(.id)\t\(.label)"' "$snapDir/manifest.json" 2>/dev/null)

# ---- Scope checksum verification to just the files we're about to touch.
relFiles=()
for id in "${catIds[@]}"; do
  [ -n "$id" ] || continue
  while IFS=$'\t' read -r src rel kind _ex; do
    [ -z "$rel" ] && continue
    if [ "$kind" = "file" ]; then
      [ -f "$snapDir/$rel" ] && relFiles+=("$rel")
    else
      while IFS= read -r -d '' f; do
        relFiles+=("${f#"$snapDir"/}")
      done < <(find "$snapDir/$rel" -type f -print0 2>/dev/null)
    fi
  done < <(category_entries "$id")
done

if [ "${#relFiles[@]}" -gt 0 ] && [ -f "$snapDir/SHA256SUMS" ]; then
  badFiles=()
  while IFS= read -r rel; do
    line=$(grep -F "  ./$rel" "$snapDir/SHA256SUMS" 2>/dev/null || grep -F " ./$rel" "$snapDir/SHA256SUMS" 2>/dev/null)
    [ -z "$line" ] && continue
    if ! ( cd "$snapDir" && echo "$line" | sha256sum -c --quiet - >/dev/null 2>&1 ); then
      badFiles+=("$rel")
    fi
  done < <(printf '%s\n' "${relFiles[@]}")
  if [ "${#badFiles[@]}" -gt 0 ]; then
    jq -n --argjson f "$(printf '%s\n' "${badFiles[@]}" | jq -R . | jq -s .)" \
      '{ok:false, error:"Checksum mismatch -- refusing to restore. The stick may be corrupted or the file was edited by hand.", failedFiles:$f}'
    exit 1
  fi
fi

backupDir="$HOME_DIR/.local/state/omavault/pre-restore-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$backupDir"

categoriesJson="[]"
needsRestart=false
for id in "${catIds[@]}"; do
  [ -n "$id" ] || continue
  label="${catLabel[$id]:-$id}"
  files=0
  case "$id" in core|plugins|hypr) needsRestart=true ;; esac
  while IFS=$'\t' read -r src rel kind _ex; do
    [ -z "$src" ] && continue
    snapSrc="$snapDir/$rel"
    if [ "$kind" = "file" ]; then
      [ -f "$snapSrc" ] || continue
      if [ -f "$src" ]; then
        mkdir -p "$(dirname "$backupDir/$rel")"
        cp -p -- "$src" "$backupDir/$rel"
      fi
      mkdir -p "$(dirname "$src")"
      cp -p -- "$snapSrc" "$src" && files=$((files + 1))
    else
      [ -d "$snapSrc" ] || continue
      if [ -d "$src" ]; then
        mkdir -p "$(dirname "$backupDir/$rel")"
        cp -a -- "$src" "$backupDir/$rel"
      fi
      mkdir -p "$src"
      rsync -a "$snapSrc/" "$src/" 2>/dev/null
      files=$((files + $(find "$snapSrc" -type f | wc -l)))
    fi
  done < <(category_entries "$id")
  categoriesJson=$(jq --arg id "$id" --arg label "$label" --argjson f "$files" '. + [{id:$id, label:$label, fileCount:$f}]' <<<"$categoriesJson")
done

jq -n \
  --argjson categories "$categoriesJson" \
  --arg backupDir "$backupDir" \
  --argjson needsRestart "$needsRestart" \
  '{ok:true, categories:$categories, backupDir:$backupDir, needsRestart:$needsRestart}'
