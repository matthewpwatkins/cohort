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

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CLAUDE_MD=$CONFIG_DIR/CLAUDE.md
BINDIR=${COHORT_BINDIR:-$HOME/bin}
MODE=install

usage() {
  cat <<'USAGE'
install-cohort.sh — install the `cohort` command and register its
multi-session guidance in the user-level CLAUDE.md.

  ./install-cohort.sh              install or update
  ./install-cohort.sh --uninstall  remove command + guidance block
  ./install-cohort.sh --bindir DIR install somewhere specific
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --uninstall) MODE=uninstall ;;
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
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
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
  case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) warn "note: $BINDIR is not on PATH — add it, or reinstall with --bindir" ;;
  esac
  command -v tmux >/dev/null || warn "note: tmux is not installed"
else
  uninstall_bin
  uninstall_md
fi
