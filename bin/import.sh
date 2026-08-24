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

# Relative-path listing files, one per dir-kind category entry, built once
# below (before checksum verification) and reused as-is for the actual
# restore copy further down -- see the comment at dirFileList[] for why.
# Never holds real snapshot content, only filenames, but cleaned up on
# every exit path regardless.
listTmpFiles=()
trap 'rm -f "${listTmpFiles[@]:-}"' EXIT

[ -n "$snapDir" ] && [ -d "$snapDir" ] || fail "Snapshot folder not found."
[ -f "$snapDir/manifest.json" ] || fail "No manifest.json -- not an OmaVault snapshot."
[ -n "$catsArg" ] || fail "No categories selected."

IFS=',' read -r -a catIds <<<"$catsArg"
# Labels come from the snapshot's own manifest, not this machine's category
# list -- a fresh machine won't have e.g. ~/.config/hypr yet, so
# list_category_meta wouldn't offer a label for it at all.
declare -A catLabel
while IFS=$'\t' read -r id label; do catLabel["$id"]="$label"; done < <(jq -r '.categories[]? | "\(.id)\t\(.label)"' "$snapDir/manifest.json" 2>/dev/null)

# ---- Reject any non-regular-file/non-directory entry within what we're
# about to restore, before any checksum work or copying happens. Type
# validation of the tar itself (decrypt-snapshot.sh) already blocks this
# for a normal encrypted backup, but a legacy pre-mandatory-encryption
# plain snapshot folder never goes through that tar check -- and either
# way, this is the actual restore boundary, so it's enforced here
# regardless of how the snapshot got onto disk. Without this, a symlink
# would skip checksum verification entirely (`find -type f` below doesn't
# match `-type l`) and then get faithfully recreated by rsync, or -- for
# a "file"-kind single dotfile, since `[ -f ]`/`cp` both dereference by
# default -- have some arbitrary target's content silently copied in as
# if it were that dotfile. `-L` is checked first (before any `-f`/`-d`
# test, which would dereference) so this also catches a dangling symlink
# and a top-level category entry that is itself a symlink.
for id in "${catIds[@]}"; do
  [ -n "$id" ] || continue
  while IFS=$'\t' read -r src rel kind _ex; do
    [ -z "$rel" ] && continue
    p="$snapDir/$rel"
    [ -e "$p" ] || [ -L "$p" ] || continue
    if [ -L "$p" ]; then
      fail "Backup rejected: \"$rel\" is a symlink -- refusing to restore."
    fi
    if [ "$kind" != "file" ] && [ -d "$p" ]; then
      bad=$(find "$p" -not -type f -not -type d 2>/dev/null | head -n1)
      if [ -n "$bad" ]; then
        fail "Backup rejected: \"${bad#"$snapDir"/}\" is not a regular file or directory -- refusing to restore."
      fi
    fi
  done < <(category_entries "$id")
done

# ---- Scope checksum verification to just the files we're about to touch.
# For a "dir" entry, the list is built with an rsync --dry-run against a
# throwaway *empty* directory -- never the real destination -- and that
# same list is what actually drives the restore copy further down (via
# --files-from), instead of the copy loop doing its own independent
# `find`/rsync walk of $snapSrc that's merely assumed to still agree with
# what got verified here. Two independent walks of the same directory
# can drift (a file added to $snapDir between them would be restored
# without ever having been checksum-verified) -- one captured list, reused
# unmodified for both verification and copy, can't drift by construction.
# Listing against the real destination instead of an empty throwaway would
# introduce a *different* version of the same bug: rsync's own delta-skip
# silently omits any file already identical at the destination, which
# would silently drop it from checksum coverage too (confirmed directly:
# a file already in place at the destination vanishes from the listing
# the moment the dest is used instead of an empty dir).
relFiles=()
declare -A dirFileList
for id in "${catIds[@]}"; do
  [ -n "$id" ] || continue
  while IFS=$'\t' read -r src rel kind extraExclude; do
    [ -z "$rel" ] && continue
    if [ "$kind" = "file" ]; then
      [ -f "$snapDir/$rel" ] && relFiles+=("$rel")
    else
      [ -d "$snapDir/$rel" ] || continue
      listDest=$(mktemp -d) && listTmpFiles+=("$listDest")
      listFile=$(mktemp) && listTmpFiles+=("$listFile")
      listFlags=(-rptgo)
      [ -n "$extraExclude" ] && listFlags+=($extraExclude)
      while IFS=',' read -r itemize fname; do
        [ -z "$fname" ] && continue
        case "$itemize" in '>f'*) ;; *) continue ;; esac
        printf '%s\n' "$fname" >>"$listFile"
        relFiles+=("$rel/$fname")
      done < <(rsync "${listFlags[@]}" --dry-run --out-format='%i,%n' "$snapDir/$rel/" "$listDest/" 2>/dev/null)
      rmdir "$listDest" 2>/dev/null
      dirFileList["$rel"]="$listFile"
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
      # Rechecked here, not just in the whole-snapshot pass above: `cp`
      # dereferences a symlink source by default, so if $snapSrc were
      # swapped out for one in the window between that pass and this
      # actual copy, `[ -f ]` below wouldn't catch it (it dereferences
      # too) and `cp` would silently copy whatever it points to. Narrows
      # that window to nothing by checking immediately before use.
      if [ -L "$snapSrc" ]; then
        fail "Backup rejected: \"$rel\" is a symlink -- refusing to restore."
      fi
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
      # --files-from fed the exact list captured (and checksum-verified)
      # above, not a fresh independent walk of $snapSrc -- extraExclude
      # (e.g. "core" excluding its nested /plugins subfolder) was already
      # applied when that list was built, so it doesn't need repeating
      # here, and nothing can reach this copy without having gone through
      # verification: the file sets are the same list, not two walks
      # hoped to agree.
      # -rptgo, not -a: -a implies -l (preserve symlinks as symlinks) and
      # -D (devices/specials). The type-check above already guarantees
      # nothing but regular files/directories exist under $snapSrc -- this
      # is defense-in-depth so even a future bug in that check can't have
      # rsync faithfully recreate something it shouldn't; without -l/-D,
      # this also closes the same TOCTOU window the recheck above closes
      # for the "file" branch, but for free: rsync itself (not just our
      # earlier pass) skips any non-regular entry at the moment it
      # actually reads $snapSrc, so a swap-in right before this call is
      # simply skipped rather than followed or recreated.
      listFile="${dirFileList[$rel]:-}"
      if [ -n "$listFile" ] && [ -s "$listFile" ]; then
        rsync -rptgo --files-from="$listFile" "$snapSrc/" "$src/" 2>/dev/null
        files=$((files + $(grep -c . "$listFile" 2>/dev/null || echo 0)))
      fi
    fi
  done < <(category_entries "$id")
  categoriesJson=$(jq --arg id "$id" --arg label "$label" --argjson f "$files" '. + [{id:$id, label:$label, fileCount:$f}]' <<<"$categoriesJson")
done

jq -n \
  --argjson categories "$categoriesJson" \
  --arg backupDir "$backupDir" \
  --argjson needsRestart "$needsRestart" \
  '{ok:true, categories:$categories, backupDir:$backupDir, needsRestart:$needsRestart}'
