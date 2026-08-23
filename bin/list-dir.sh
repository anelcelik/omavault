#!/bin/bash
# Usage: list-dir.sh <path>
# Lists the immediate subdirectories of <path> as JSON, for the plugin's
# own in-popup folder browser -- deliberately NOT a native GTK/portal file
# dialog: that path crashed the whole Quickshell process in testing here
# (GVFS aborting inside libgtk-3's directory-monitor D-Bus call), so
# picking a folder is done entirely in-process instead, with this script
# just doing the `ls`.
set -u

path="${1:-$HOME}"
[ -n "$path" ] || path="$HOME"
# realpath -m tolerates a path that doesn't exist (yet) rather than erroring,
# but we still fall back to $HOME if the result isn't a real directory.
resolved=$(realpath -m -- "$path" 2>/dev/null || echo "$HOME")
[ -d "$resolved" ] || resolved="$HOME"

parent=$(dirname -- "$resolved")
[ "$parent" = "$resolved" ] && parent=""

entries="[]"
while IFS= read -r -d '' d; do
  name=$(basename -- "$d")
  case "$name" in .*) continue ;; esac
  entries=$(jq --arg name "$name" --arg path "$d" '. + [{name:$name, path:$path}]' <<<"$entries")
done < <(find "$resolved" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

jq -n --arg path "$resolved" --arg parent "$parent" --argjson entries "$entries" \
  '{ok:true, path:$path, parent:$parent, entries:$entries}'
