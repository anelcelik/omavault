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

if [ "${#relFiles[@]}" -gt 0 ]; then
  [ -f "$snapDir/SHA256SUMS" ] || fail "No SHA256SUMS in this backup -- refusing to restore unverified files."

  # Exact path -> hash map, built once, instead of grepping SHA256SUMS per
  # file. A plain `grep -F "  ./$rel"` (the previous approach) is an
  # unanchored substring match -- "config/foo.conf" matches as a substring
  # of a line for "config/foo.conf.bak" too, so a shorter selected path
  # could silently "pass" against a longer, unrelated file's checksum.
  # Requiring exactly one exact-path match per file closes that, and also
  # means a file with NO entry at all is a verification failure, not a
  # silent skip that still gets restored.
  declare -A sumFor sumCount
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    hash="${line%% *}"
    rest="${line#"$hash"}"
    rest="${rest# }"
    rest="${rest# }"
    rest="${rest#\*}"
    [ -z "$rest" ] && continue
    sumFor["$rest"]="$hash"
    sumCount["$rest"]=$(( ${sumCount["$rest"]:-0} + 1 ))
  done < "$snapDir/SHA256SUMS"

  badFiles=()
  for rel in "${relFiles[@]}"; do
    key="./$rel"
    cnt="${sumCount[$key]:-0}"
    if [ "$cnt" != "1" ]; then
      # 0 = no checksum entry for this file at all; >1 = duplicate/
      # conflicting entries for the same path. Both are refused rather
      # than guessed at.
      badFiles+=("$rel")
      continue
    fi
    actual=$(cd "$snapDir" && sha256sum -- "$rel" 2>/dev/null | awk '{print $1}')
    if [ "$actual" != "${sumFor[$key]}" ]; then
      badFiles+=("$rel")
    fi
  done
  if [ "${#badFiles[@]}" -gt 0 ]; then
    jq -n --argjson f "$(printf '%s\n' "${badFiles[@]}" | jq -R . | jq -s .)" \
      '{ok:false, error:"Checksum mismatch (or missing/duplicate checksum entry) -- refusing to restore. The stick may be corrupted or the file was edited by hand.", failedFiles:$f}'
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
  while IFS=$'\t' read -r src rel kind extraExclude; do
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
      # Same extraExclude as export.sh (e.g. "core" excluding its nested
      # /plugins subfolder) -- without this, restoring "core" alone would
      # also drag in files that only belong to a separate category the
      # user may not have selected (they're physically nested in the
      # snapshot when both categories were exported together).
      rsyncFlags=(-a)
      [ -n "$extraExclude" ] && rsyncFlags+=($extraExclude)
      rsync "${rsyncFlags[@]}" "$snapSrc/" "$src/" 2>/dev/null
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
