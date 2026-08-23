#!/bin/bash
# Outputs a JSON array of mounted removable drives (USB sticks and similar),
# each with free space and, if it already carries an omavault/ folder, the
# list of snapshots found on it (so Import can offer them straight away).
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

lsblk_json=$(lsblk -J -b -o NAME,PATH,RM,TRAN,HOTPLUG,MOUNTPOINT,LABEL,FSSIZE,FSAVAIL 2>/dev/null || echo '{"blockdevices":[]}')

# Flatten lsblk's nested children (built-in recursive descent, not a
# hand-rolled recursive def -- cheaper and avoids depth surprises on deeply
# nested LVM/dm stacks), keep only mounted, removable-or-usb-tran
# filesystems, drop the root/boot mounts a plugged-in stick would never be.
drives=$(jq -c '
  [.. | objects | select(has("mountpoint"))]
  | map(select(.mountpoint != null and .mountpoint != ""
      and (.rm == true or .tran == "usb" or .hotplug == true)
      and (.mountpoint | test("^/(boot)?$") | not)))
  | map({path: .mountpoint, label: (.label // (.path // "drive")),
         freeBytes: (.fsavail // 0), sizeBytes: (.fssize // 0)})
  | unique_by(.path)
' <<<"$lsblk_json")

result="[]"
while IFS= read -r drive; do
  [ -z "$drive" ] && continue
  mnt=$(jq -r '.path' <<<"$drive")
  snaps="[]"
  vault="$mnt/omavault"
  if [ -d "$vault" ]; then
    for d in "$vault"/*/; do
      [ -d "$d" ] || continue
      name=$(basename "$d")
      manifest="$d/manifest.json"
      if [ -f "$manifest" ] && jq -e . "$manifest" >/dev/null 2>&1; then
        summary=$(jq -c --arg path "${d%/}" --arg name "$name" \
          '{name:$name, path:$path, createdAt:(.createdAt // ""), hostname:(.hostname // ""), categories:[.categories[]?.label], encrypted:(.encrypted // false)}' "$manifest")
      else
        summary=$(jq -cn --arg path "${d%/}" --arg name "$name" '{name:$name, path:$path, createdAt:"", hostname:"", categories:[], noManifest:true}')
      fi
      snaps=$(jq --argjson s "$summary" '. + [$s]' <<<"$snaps")
    done
    # Newest first.
    snaps=$(jq 'sort_by(.createdAt) | reverse' <<<"$snaps")
  fi
  entry=$(jq --argjson snaps "$snaps" '. + {hasVault: ($snaps | length > 0), snapshots: $snaps}' <<<"$drive")
  result=$(jq --argjson e "$entry" '. + [$e]' <<<"$result")
done < <(jq -c '.[]' <<<"$drives")

echo "$result"
