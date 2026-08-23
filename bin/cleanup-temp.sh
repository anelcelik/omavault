#!/bin/bash
# Usage: cleanup-temp.sh <tempDir>
# Deletes a decrypt-snapshot.sh temp folder (the decrypted plaintext of an
# encrypted backup). Scoped to paths that actually look like one of ours --
# a bug elsewhere passing the wrong path can't turn this into rm -rf of
# something real.
set -u
dir="${1:-}"
case "$dir" in
  */omavault-decrypt-*) [ -d "$dir" ] && rm -rf -- "$dir" ;;
esac
echo '{"ok":true}'
