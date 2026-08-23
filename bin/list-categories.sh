#!/bin/bash
# Outputs a JSON array describing every exportable category available on
# this machine, with a live file/byte count for each so the GUI checkbox
# list can show real numbers before the user commits to an export.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. ./lib.sh

result="[]"
while IFS=$'\t' read -r id label desc defaultOn; do
  [ -z "$id" ] && continue
  files=0
  bytes=0
  while IFS=$'\t' read -r src rel kind extraExclude; do
    [ -z "$src" ] && continue
    if [ "$kind" = "file" ]; then
      [ -f "$src" ] || continue
      files=$((files + 1))
      bytes=$((bytes + $(stat -c%s -- "$src" 2>/dev/null || echo 0)))
    else
      [ -d "$src" ] || continue
      # Name-based excludes only, for a fast estimate -- the binary-content
      # sniff pass only runs during a real export, not this preview count.
      stats=$(rsync -a --dry-run --stats "${BINARY_RSYNC_EXCLUDES[@]}" $extraExclude "$src/" /tmp/omavault-count-target-unused/ 2>/dev/null)
      n=$(awk -F': ' '/Number of regular files transferred/ {gsub(",","",$2); print $2}' <<<"$stats")
      b=$(awk -F': ' '/Total transferred file size/ {gsub(/[, bytes]/,"",$2); print $2}' <<<"$stats")
      files=$((files + ${n:-0}))
      bytes=$((bytes + ${b:-0}))
    fi
  done < <(category_entries "$id")

  entry=$(jq -n --arg id "$id" --arg label "$label" --arg desc "$desc" \
    --argjson defaultOn "$( [ "$defaultOn" = "1" ] && echo true || echo false )" \
    --argjson files "$files" --argjson bytes "$bytes" \
    '{id:$id, label:$label, description:$desc, defaultOn:$defaultOn, fileCount:$files, bytes:$bytes}')
  result=$(jq --argjson e "$entry" '. + [$e]' <<<"$result")
done < <(list_category_meta)

echo "$result"
