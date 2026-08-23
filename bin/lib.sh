#!/bin/bash
# Shared category registry + helpers for OmaVault's export/import scripts.
# Every category maps one or more real config locations under $HOME to a
# path inside a snapshot that mirrors it 1:1 (config/omarchy/..., dotfiles/
# .bashrc, ...) -- a snapshot is a browsable mini home directory, not a
# bespoke archive format, so once decrypted every file in it stays
# individually readable with nothing further to unpack. Nothing is ever
# left in that mirrored, readable form on the USB stick itself, though --
# export.sh always packs and encrypts it before anything touches disk.
set -u

HOME_DIR="${HOME:?HOME not set}"
CONFIG_DIR="$HOME_DIR/.config"

# Extensions treated as binary noise and excluded from every copy up front
# (cheap, name-based, applied via rsync). A second content-sniffing pass
# (strip_binaries, in export.sh) catches anything that slips through this
# without a recognized extension.
BINARY_RSYNC_EXCLUDES=(
  --exclude=.git
  --exclude=*.png --exclude=*.jpg --exclude=*.jpeg --exclude=*.gif
  --exclude=*.ico --exclude=*.webp --exclude=*.bmp --exclude=*.svgz
  --exclude=*.woff --exclude=*.woff2 --exclude=*.ttf --exclude=*.otf --exclude=*.eot
  --exclude=*.so --exclude=*.o --exclude=*.bin --exclude=*.pyc
  --exclude=*.sqlite --exclude=*.sqlite3 --exclude=*.db --exclude=*.qmlc
)

# Emits one "id<TAB>label<TAB>description<TAB>defaultOn(0/1)" line per
# category that has at least one real source on this machine. Order here is
# the order the GUI lists them in.
list_category_meta() {
  [ -d "$CONFIG_DIR/omarchy" ] && printf 'core\tOmarchy core settings\tBar layout, dock, search, themes, extensions and hooks under ~/.config/omarchy (the plugins/ subfolder is its own category below, so it is not duplicated here).\t1\n'
  [ -d "$CONFIG_DIR/omarchy/plugins" ] && printf 'plugins\tInstalled plugins\tEvery plugin under ~/.config/omarchy/plugins -- its settings plus its own source -- so a fresh machine can restore a plugin without re-fetching it from anywhere.\t1\n'
  [ -d "$CONFIG_DIR/hypr" ] && printf 'hypr\tHyprland\tWindow rules, keybindings, monitor layout and animations under ~/.config/hypr.\t1\n'
  local t label
  for t in alacritty foot kitty ghostty; do
    if [ -d "$CONFIG_DIR/$t" ]; then
      label="$(tr '[:lower:]' '[:upper:]' <<<"${t:0:1}")${t:1}"
      printf 'term-%s\t%s\tConfig under ~/.config/%s.\t1\n' "$t" "$label" "$t"
    fi
  done
  if [ -d "$CONFIG_DIR/nvim" ] || [ -f "$HOME_DIR/.bashrc" ] || [ -f "$HOME_DIR/.zshrc" ] || [ -f "$HOME_DIR/.gitconfig" ]; then
    printf 'extra\tShell & editor dotfiles\tOptional: ~/.config/nvim plus .bashrc/.zshrc/.bash_profile/.zprofile/.gitconfig/.profile. Off by default -- these can bake in machine-specific paths that do not always carry over cleanly.\t0\n'
  fi
}

# Emits "srcAbsPath<TAB>relSnapshotPath<TAB>kind(dir|file)<TAB>extraExcludeArg"
# lines (one category id can expand to several real locations, e.g. "extra").
# Deliberately NOT gated on whether srcAbsPath exists on *this* machine --
# import.sh calls this on a fresh machine where none of it exists yet, and
# needs the mapping anyway to know where a snapshot's files should land.
# Existence checks belong to the caller: export.sh skips a missing source,
# import.sh skips a missing snapshot-side path.
category_entries() {
  local id="$1"
  case "$id" in
    core)
      printf '%s\t%s\tdir\t%s\n' "$CONFIG_DIR/omarchy" "config/omarchy" "--exclude=/plugins"
      ;;
    plugins)
      printf '%s\t%s\tdir\t%s\n' "$CONFIG_DIR/omarchy/plugins" "config/omarchy/plugins" "--exclude=/.*"
      ;;
    hypr)
      printf '%s\t%s\tdir\t\n' "$CONFIG_DIR/hypr" "config/hypr"
      ;;
    term-*)
      local t="${id#term-}"
      printf '%s\t%s\tdir\t\n' "$CONFIG_DIR/$t" "config/$t"
      ;;
    extra)
      printf '%s\t%s\tdir\t\n' "$CONFIG_DIR/nvim" "config/nvim"
      local f
      for f in .bashrc .zshrc .bash_profile .zprofile .gitconfig .profile; do
        printf '%s\t%s\tfile\t\n' "$HOME_DIR/$f" "dotfiles/$f"
      done
      ;;
  esac
}

# True (exit 0) if the file "looks like" plain text worth keeping on the
# stick. Empty files pass too (harmless, and common for marker/lock files).
is_text_file() {
  local f="$1"
  [ -s "$f" ] || return 0
  case "$(file -b --mime-type -- "$f" 2>/dev/null)" in
    text/*|application/json|application/xml|inode/x-empty) return 0 ;;
    *) return 1 ;;
  esac
}

json_escape() {
  jq -Rn --arg s "$1" '$s'
}

# Hard ceiling for a decrypted/staged config backup. Real backups are
# KB-MB (text config only, binaries are excluded); this is generous
# headroom, not a target -- see decrypt-snapshot.sh for how it's enforced
# as an actual producer-side write limit, not just a post-hoc check.
MAX_BACKUP_BYTES=$((128 * 1024 * 1024)) # 128 MiB

# Resolves $XDG_RUNTIME_DIR to a scratch base we actually trust to be
# private and memory-backed, or fails. There is deliberately no fallback
# to /tmp: /tmp is commonly disk-backed and not guaranteed private, so
# silently degrading to it would put decrypted config contents (which can
# include SSH configs, tokens baked into dotfiles, etc.) on durable
# storage without ever telling the caller. On success prints the
# directory to stdout and returns 0; on failure prints a one-line reason
# to stdout (not stderr, so `x=$(verified_runtime_dir) || fail "$x"`
# captures it directly) and returns 1.
verified_runtime_dir() {
  local dir="${XDG_RUNTIME_DIR:-}"
  if [ -z "$dir" ]; then
    echo "\$XDG_RUNTIME_DIR is not set"
    return 1
  fi
  if [ ! -d "$dir" ]; then
    echo "\$XDG_RUNTIME_DIR ($dir) does not exist"
    return 1
  fi
  local owner mode fstype
  owner=$(stat -c '%U' "$dir" 2>/dev/null)
  if [ "$owner" != "$(id -un)" ]; then
    echo "$dir is not owned by the current user"
    return 1
  fi
  mode=$(stat -c '%a' "$dir" 2>/dev/null)
  if [ "$mode" != "700" ]; then
    echo "$dir is not private (mode ${mode:-unknown}, expected 700)"
    return 1
  fi
  fstype=$(stat -f -c '%T' "$dir" 2>/dev/null)
  case "$fstype" in
    tmpfs|ramfs) ;;
    *)
      echo "$dir is not memory-backed (filesystem: ${fstype:-unknown})"
      return 1
      ;;
  esac
  printf '%s' "$dir"
}
