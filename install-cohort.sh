#!/usr/bin/env bash
#
# install-cohort.sh — install the `cohort` command and register its
# multi-session guidance in the user-level CLAUDE.md. See usage() below.
#
# Idempotent: re-running converges to the same state and reports "unchanged".
# Runs from a clone or straight off a pipe: payload files are read from
# alongside this script when present, otherwise downloaded from
# $COHORT_REPO at $COHORT_REF.

set -euo pipefail

# Trust sibling files only when this really is a checkout, not whatever the
# cwd happens to hold when the installer is run off a pipe.
SRC=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)
[[ -f $SRC/install-cohort.sh && -f $SRC/cohort.sh && -f $SRC/guidance.md ]] || SRC=''

REPO=${COHORT_REPO:-matthewpwatkins/cohort}
REF=${COHORT_REF:-main}
RAW=https://raw.githubusercontent.com/$REPO/$REF
BEGIN_MARK='<!-- BEGIN cohort (managed by install-cohort.sh) -->'
END_MARK='<!-- END cohort -->'
RC_BEGIN='# BEGIN cohort (managed by install-cohort.sh)'
RC_END='# END cohort'
COHORT_DIR=${COHORT_CONFIG_DIR:-$HOME/.cohort}

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CLAUDE_MD=$CONFIG_DIR/CLAUDE.md
BINDIR=${COHORT_BINDIR:-$HOME/bin}
MODE=install
WANT_TMUX=1

usage() {
  cat <<'USAGE'
install-cohort.sh — install the `cohort` command and register its
multi-session guidance in the user-level CLAUDE.md.

Installs the command, the guidance block, shell completion, and tmux if it
is missing.

  ./install-cohort.sh              install or update
  ./install-cohort.sh --uninstall  remove everything it installed
  ./install-cohort.sh --bindir DIR install somewhere specific
  ./install-cohort.sh --no-tmux    skip the tmux check
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --uninstall) MODE=uninstall ;;
    --no-tmux) WANT_TMUX=0 ;;
    --bindir) [[ $# -ge 2 ]] || { echo "--bindir needs a directory" >&2; exit 2; }
              BINDIR=$2; shift ;;
    --bindir=*) BINDIR=${1#*=} ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done

TARGET=$BINDIR/cohort
say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

# Print a path to <file>: from the checkout if we are in one, else downloaded.
# Runs in a command substitution, so CACHE and its trap must be set up out here.
CACHE=$(mktemp -d)
trap 'rm -rf "$CACHE"' EXIT

payload() {
  local f=$1
  if [[ -n $SRC ]]; then printf '%s\n' "$SRC/$f"; return; fi
  if [[ ! -f $CACHE/$f ]]; then
    command -v curl >/dev/null || die "need curl to fetch $f"
    curl -fsSL "$RAW/$f" -o "$CACHE/$f" || die "could not fetch $RAW/$f"
  fi
  printf '%s\n' "$CACHE/$f"
}

# Remove the managed block (markers included) from stdin.
strip_block() {
  awk -v b="${1:-$BEGIN_MARK}" -v e="${2:-$END_MARK}" '
    $0 == b { inblk = 1; next }
    $0 == e { inblk = 0; next }
    !inblk  { print }
  '
}

# Drop trailing blank lines from stdin.
trim_trailing_blank() {
  awk '{ if (NF) { while (n-- > 0) print ""; n = 0; print } else n++ }'
}

install_bin() {
  local src
  src=$(payload cohort.sh)
  if [[ -x $TARGET ]] && cmp -s "$src" "$TARGET"; then
    say "command:  unchanged  ($TARGET)"
    return
  fi
  local verb=installed
  [[ -f $TARGET ]] && verb=updated
  mkdir -p "$BINDIR"
  cp "$src" "$TARGET"
  chmod 755 "$TARGET"
  say "command:  $verb  ($TARGET)"
}

install_md() {
  mkdir -p "$CONFIG_DIR"

  local body block new old verb
  block=$(printf '%s\n%s\n%s\n' "$BEGIN_MARK" "$(cat "$(payload guidance.md)")" "$END_MARK")

  if [[ -f $CLAUDE_MD ]]; then
    old=$(cat "$CLAUDE_MD")
    body=$(strip_block <"$CLAUDE_MD" | trim_trailing_blank)
  else
    old='' body=''
  fi

  if [[ -n $body ]]; then
    new=$(printf '%s\n\n%s\n' "$body" "$block")
  else
    new=$(printf '%s\n' "$block")
  fi

  if [[ -f $CLAUDE_MD && $old == "$new" ]]; then
    say "guidance: unchanged  ($CLAUDE_MD)"
    return
  fi

  verb=created
  if [[ -f $CLAUDE_MD ]]; then
    verb=added
    grep -qF "$BEGIN_MARK" "$CLAUDE_MD" && verb=updated
  fi
  printf '%s\n' "$new" >"$CLAUDE_MD"
  say "guidance: $verb  ($CLAUDE_MD)"
}

# tmux is not optional — cohort is a tmux session manager — so install it
# rather than leaving the user a note to come back to. Package installs need
# root; sudo reads its password from the terminal, not stdin, so this still
# works when the script is running off a curl pipe.
install_tmux() {
  if command -v tmux >/dev/null; then
    say "tmux:     present   ($(command -v tmux))"
    return
  fi

  local -a mgr=()
  if   command -v brew    >/dev/null; then mgr=(brew install tmux)
  elif command -v apt-get >/dev/null; then mgr=(apt-get install -y tmux)
  elif command -v dnf     >/dev/null; then mgr=(dnf install -y tmux)
  elif command -v yum     >/dev/null; then mgr=(yum install -y tmux)
  elif command -v zypper  >/dev/null; then mgr=(zypper --non-interactive install tmux)
  elif command -v pacman  >/dev/null; then mgr=(pacman -S --noconfirm tmux)
  elif command -v apk     >/dev/null; then mgr=(apk add tmux)
  else
    warn "tmux:     missing   (no supported package manager found — install tmux yourself)"
    return
  fi

  # Homebrew refuses to run as root and manages its own prefix; everything
  # else writes to system directories.
  local -a run=("${mgr[@]}")
  if [[ ${mgr[0]} != brew && $(id -u) -ne 0 ]]; then
    if command -v sudo >/dev/null; then
      run=(sudo "${mgr[@]}")
    else
      warn "tmux:     missing   (need root to run '${mgr[*]}')"
      return
    fi
  fi

  say "tmux:     installing (${run[*]})"
  # A machine that has never fetched package lists, or has a stale index,
  # fails the install with a 404 rather than a missing-package error.
  case ${mgr[0]} in
    apt-get) if [[ ${run[0]} == sudo ]]; then
               sudo apt-get update >/dev/null 2>&1 || true
             else
               apt-get update >/dev/null 2>&1 || true
             fi ;;
  esac
  # A package manager can exit 0 and still leave nothing on PATH, so believe
  # tmux itself rather than the exit status.
  DEBIAN_FRONTEND=noninteractive "${run[@]}" || true
  hash -r 2>/dev/null || true
  if command -v tmux >/dev/null; then
    say "tmux:     installed ($(command -v tmux))"
  else
    warn "tmux:     failed    ('${run[*]}' did not produce tmux — install it yourself)"
  fi
}

# Completion is generated by the installed command, so it can never drift from
# the subcommands that command actually has.
install_completion() {
  mkdir -p "$COHORT_DIR"
  local sh f line rc changed
  for sh in bash zsh; do
    f=$COHORT_DIR/completion.$sh
    "$TARGET" completion "$sh" >"$f" 2>/dev/null || { warn "completion: skipped ($sh)"; continue; }
  done

  changed=''
  for sh in bash zsh; do
    rc=$HOME/.${sh}rc
    # Only wire up a shell the user actually has an rc file for; creating one
    # can shadow a login-shell setup that lives somewhere else.
    [[ -f $rc ]] || continue
    line=". \"$COHORT_DIR/completion.$sh\""
    if [[ $(strip_block "$RC_BEGIN" "$RC_END" <"$rc") == "$(cat "$rc")" ]]; then
      printf '\n%s\n[ -f "%s" ] && %s\n%s\n' \
        "$RC_BEGIN" "$COHORT_DIR/completion.$sh" "$line" "$RC_END" >>"$rc"
      changed+="$rc "
    else
      # Block already there and it only ever sources a fixed path, so the
      # regenerated completion file is picked up without touching the rc.
      :
    fi
  done

  if [[ -n $changed ]]; then
    say "completion: added    (${changed% })"
    say "            open a new shell, or source the rc file, to pick it up"
  else
    say "completion: current  ($COHORT_DIR/completion.{bash,zsh})"
  fi
}

uninstall_completion() {
  local sh rc found=0 body
  for sh in bash zsh; do
    rc=$HOME/.${sh}rc
    [[ -f $rc ]] || continue
    grep -qF "$RC_BEGIN" "$rc" || continue
    body=$(strip_block "$RC_BEGIN" "$RC_END" <"$rc" | trim_trailing_blank)
    printf '%s\n' "$body" >"$rc"
    found=1
  done
  rm -f "$COHORT_DIR/completion.bash" "$COHORT_DIR/completion.zsh"
  [[ $found -eq 1 ]] && say "completion: removed" || say "completion: absent"
}

# Only ever delete a file this installer wrote. ~/bin is full of your own
# scripts; a name collision must not cost you one.
ours() { grep -qF 'Installed by install-cohort.sh' "$1" 2>/dev/null; }

uninstall_bin() {
  local found=0 p seen=' '
  for p in "$TARGET" "$HOME/bin/cohort" "$HOME/.local/bin/cohort"; do
    [[ -e $p || -L $p ]] || continue
    [[ $seen == *" $p "* ]] && continue
    seen+="$p "
    if ours "$p"; then
      rm -f "$p"
      say "command:  removed  ($p)"
      found=1
    else
      warn "command:  skipped  ($p is not ours — left alone)"
    fi
  done
  [[ $found -eq 1 ]] || say "command:  absent"
}

uninstall_md() {
  if [[ ! -f $CLAUDE_MD ]] || ! grep -qF "$BEGIN_MARK" "$CLAUDE_MD"; then
    say "guidance: absent"
    return
  fi
  local body
  body=$(strip_block <"$CLAUDE_MD" | trim_trailing_blank)
  if [[ -z $body ]]; then
    rm -f "$CLAUDE_MD"
    say "guidance: removed  (deleted now-empty $CLAUDE_MD)"
  else
    printf '%s\n' "$body" >"$CLAUDE_MD"
    say "guidance: removed  ($CLAUDE_MD)"
  fi
}

if [[ $MODE == install ]]; then
  install_bin
  install_md
  install_completion
  [[ $WANT_TMUX -eq 1 ]] && install_tmux
  case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) warn "note: $BINDIR is not on PATH — add it, or reinstall with --bindir" ;;
  esac
else
  uninstall_bin
  uninstall_md
  uninstall_completion
fi
