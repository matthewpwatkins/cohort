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
MODE=install
WANT_TMUX=1
ASSUME_YES=0

on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

BINDIRS=("$HOME/.local/bin" "$HOME/bin")

# Prefer a bin directory the shell already searches, so the command works the
# moment this finishes rather than after a PATH edit the user has to notice.
# An existing install wins over both: upgrading in place is what someone
# re-running this expects, and it cannot leave two copies shadowing each other.
default_bindir() {
  local d
  for d in "${BINDIRS[@]}"; do
    [[ -f $d/cohort ]] && grep -qF 'Installed by install-cohort.sh' "$d/cohort" 2>/dev/null \
      && { printf '%s\n' "$d"; return; }
  done
  for d in "${BINDIRS[@]}"; do
    on_path "$d" && { printf '%s\n' "$d"; return; }
  done
  printf '%s\n' "$HOME/.local/bin"
}
BINDIR=${COHORT_BINDIR:-$(default_bindir)}

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
  ./install-cohort.sh --yes        do not ask before installing tmux

By default the command goes to the first of ~/.local/bin or ~/bin already on
your PATH; if neither is, it is installed and your PATH is extended for you.
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --uninstall) MODE=uninstall ;;
    --no-tmux) WANT_TMUX=0 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --bindir) [[ $# -ge 2 ]] || { echo "--bindir needs a directory" >&2; exit 2; }
              BINDIR=$2; shift ;;
    --bindir=*) BINDIR=${1#*=} ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done

TARGET=$BINDIR/cohort

BOLD='' DIM='' RESET=''
if [[ -t 1 ]]; then BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'; fi

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

banner() {
  cat <<'ART'
              _                   _
  ___   ___  | |__    ___   _ __ | |_
 / __| / _ \ | '_ \  / _ \ | '__|| __|
| (__ | (_) || | | || (_) || |   | |_
 \___| \___/ |_| |_| \___/ |_|    \__|
ART
  printf '%s  peer Claude Code sessions, one per tmux session%s\n' "$DIM" "$RESET"
}

section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }
status()  { printf '  %-9s %s\n' "$1" "${2:-}"; }
note()    { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }

# Ask a yes/no question, defaulting to yes. Reads the answer from the terminal
# rather than stdin, which is the script itself when this runs off a pipe.
# Returns non-zero when there is no terminal to ask, so the caller can say so
# instead of deciding for the user.
confirm() {
  (( ASSUME_YES )) && return 0
  # The file can exist and still not be openable when the process has no
  # controlling terminal, which is exactly the case worth detecting.
  { : >/dev/tty; } 2>/dev/null || return 2
  local reply
  printf '  %s [Y/n] ' "$1" >/dev/tty
  read -r reply </dev/tty || return 2
  [[ -z $reply || $reply == [yY]* ]]
}

# Whether a new shell is needed before everything works.
RELOAD_RC=''
NEEDS_PATH=0
on_path "$BINDIR" || NEEDS_PATH=1

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
  section "Command"
  if [[ -x $TARGET ]] && cmp -s "$src" "$TARGET"; then
    status unchanged "$TARGET"
    return
  fi
  local verb=installed
  [[ -f $TARGET ]] && verb=updated
  mkdir -p "$BINDIR"
  cp "$src" "$TARGET"
  chmod 755 "$TARGET"
  status "$verb" "$TARGET"
}

# An older install may sit in the other candidate directory, where it would
# shadow or be shadowed by this one depending on PATH order. Only ever remove
# a file this installer wrote.
tidy_old_bin() {
  local d p
  for d in "${BINDIRS[@]}"; do
    p=$d/cohort
    [[ $p == "$TARGET" || ! -f $p ]] && continue
    if grep -qF 'Installed by install-cohort.sh' "$p" 2>/dev/null; then
      rm -f "$p"
      status removed "$p (older copy, would have shadowed this one)"
    fi
  done
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

  section "Guidance for Claude"
  if [[ -f $CLAUDE_MD && $old == "$new" ]]; then
    status unchanged "$CLAUDE_MD"
    note "loaded into every Claude Code session"
    return
  fi

  verb=created
  if [[ -f $CLAUDE_MD ]]; then
    verb=added
    grep -qF "$BEGIN_MARK" "$CLAUDE_MD" && verb=updated
  fi
  printf '%s\n' "$new" >"$CLAUDE_MD"
  status "$verb" "$CLAUDE_MD"
  note "loaded into every Claude Code session"
}

# tmux is not optional — cohort is a tmux session manager — so install it
# rather than leaving the user a note to come back to. Package installs need
# root; sudo reads its password from the terminal, not stdin, so this still
# works when the script is running off a curl pipe.
install_tmux() {
  section "tmux"
  if command -v tmux >/dev/null; then
    status present "$(command -v tmux)"
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
    status missing "no supported package manager found"
    return 1
  fi

  # Homebrew refuses to run as root and manages its own prefix; everything
  # else writes to system directories.
  local -a run=("${mgr[@]}")
  if [[ ${mgr[0]} != brew && $(id -u) -ne 0 ]]; then
    if command -v sudo >/dev/null; then
      run=(sudo "${mgr[@]}")
    else
      status missing "need root to run '${mgr[*]}'"
      return 1
    fi
  fi

  # Installing a system package is the one thing here that reaches outside the
  # user's own files, so it is the one thing worth asking about.
  status missing "cohort runs every session in tmux"
  local answer=0
  confirm "Install it with: ${run[*]} ?" || answer=$?
  if (( answer == 2 )); then
    status skipped "no terminal to ask on — re-run with --yes to install it"
    return 1
  elif (( answer )); then
    status declined "left tmux alone"
    return 1
  fi

  status installing "${run[*]}"
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
    status installed "$(command -v tmux)"
  else
    status failed "'${run[*]}' did not produce tmux"
    return 1
  fi
}

# The rc file to wire for a shell: whichever one the user already has, else the
# conventional one for a login shell of that type. macOS bash reads
# .bash_profile and never .bashrc, so the fallback is not the same everywhere.
rc_for() {
  local f
  case $1 in
    bash)
      for f in "$HOME/.bashrc" "$HOME/.bash_profile"; do
        [[ -f $f ]] && { printf '%s\n' "$f"; return; }
      done
      if [[ $(uname -s) == Darwin ]]; then
        printf '%s\n' "$HOME/.bash_profile"
      else
        printf '%s\n' "$HOME/.bashrc"
      fi ;;
    zsh) printf '%s\n' "$HOME/.zshrc" ;;
  esac
}

# fish reads completions from its own directory rather than from an rc file, so
# ours is a file we own outright instead of a block spliced into one of theirs.
FISH_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/fish
FISH_COMPLETION=$FISH_DIR/completions/cohort.fish

# Whether a shell looks like one this user actually has. bash and zsh are
# judged by their rc file, fish by its config directory; the login shell counts
# for any of them, which is what covers a machine with no dotfiles yet.
have_shell() {
  [[ ${SHELL##*/} == "$1" ]] && return 0
  case $1 in
    bash|zsh) [[ -f $(rc_for "$1") ]] ;;
    fish)     [[ -d $FISH_DIR ]] ;;
  esac
}

# Completion is generated by the installed command, so it can never drift from
# the subcommands that command actually has.
install_completion() {
  section "Shell completion"
  mkdir -p "$COHORT_DIR"
  local sh f rc added='' present=''
  for sh in bash zsh fish; do
    f=$COHORT_DIR/completion.$sh
    "$TARGET" completion "$sh" >"$f" 2>/dev/null || warn "completion: skipped ($sh)"
  done

  # Wire every shell the user appears to have, not just the login one: people
  # keep a second shell around, and each block only ever sources its own file.
  local -a shells=()
  for sh in bash zsh fish; do
    have_shell "$sh" && shells+=("$sh")
  done
  if [[ ${#shells[@]} -eq 0 ]]; then
    # An exotic login shell. Writing a .bashrc it will never read would report
    # success for something that cannot work.
    status skipped "${SHELL##*/} is not supported — bash, zsh and fish are"
    note "the scripts are in $COHORT_DIR if you want to adapt one"
    return
  fi

  for sh in "${shells[@]}"; do
    if [[ $sh == fish ]]; then
      mkdir -p "$(dirname "$FISH_COMPLETION")"
      if cmp -s "$COHORT_DIR/completion.fish" "$FISH_COMPLETION"; then
        present+="$FISH_COMPLETION "
      else
        cp "$COHORT_DIR/completion.fish" "$FISH_COMPLETION"
        added+="$FISH_COMPLETION "
      fi
      # Completions autoload, but PATH does not.
      if (( NEEDS_PATH )) && ! { [[ -f $FISH_DIR/config.fish ]] && grep -qF "$RC_BEGIN" "$FISH_DIR/config.fish"; }; then
        mkdir -p "$FISH_DIR"
        printf '\n%s\nset -gx PATH "%s" $PATH\n%s\n' \
          "$RC_BEGIN" "$BINDIR" "$RC_END" >>"$FISH_DIR/config.fish"
        added+="$FISH_DIR/config.fish "
      fi
      continue
    fi
    rc=$(rc_for "$sh")
    if [[ -f $rc ]] && grep -qF "$RC_BEGIN" "$rc"; then
      # The block only ever sources a fixed path, so a regenerated completion
      # file is picked up without touching the rc again.
      present+="$rc "
      continue
    fi
    mkdir -p "$(dirname "$rc")"
    {
      printf '\n%s\n' "$RC_BEGIN"
      (( NEEDS_PATH )) && printf 'export PATH="%s:$PATH"\n' "$BINDIR"
      printf '[ -f "%s" ] && . "%s"\n%s\n' \
        "$COHORT_DIR/completion.$sh" "$COHORT_DIR/completion.$sh" "$RC_END"
    } >>"$rc"
    added+="$rc "
  done

  if [[ -n $added ]]; then
    status added "${added% }"
    RELOAD_RC=${added%% *}
  else
    status current "${present% }"
  fi
}

uninstall_completion() {
  section "Shell completion"
  local rc found=0 body
  # Only ever remove a fish completion this installer generated.
  if [[ -f $FISH_COMPLETION ]] && grep -q '__cohort_names' "$FISH_COMPLETION"; then
    rm -f "$FISH_COMPLETION"
    found=1
  fi
  for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$FISH_DIR/config.fish"; do
    [[ -f $rc ]] || continue
    grep -qF "$RC_BEGIN" "$rc" || continue
    body=$(strip_block "$RC_BEGIN" "$RC_END" <"$rc" | trim_trailing_blank)
    if [[ -z $body ]]; then
      # The only thing in it was our block, so this is an rc file we created
      # on a machine that had none. Leaving an empty one behind is litter.
      rm -f "$rc"
    else
      printf '%s\n' "$body" >"$rc"
    fi
    found=1
  done
  rm -f "$COHORT_DIR/completion.bash" "$COHORT_DIR/completion.zsh" \
        "$COHORT_DIR/completion.fish"
  if [[ $found -eq 1 ]]; then status removed; else status absent; fi
}

# Only ever delete a file this installer wrote. ~/bin is full of your own
# scripts; a name collision must not cost you one.
ours() { grep -qF 'Installed by install-cohort.sh' "$1" 2>/dev/null; }

uninstall_bin() {
  section "Command"
  local found=0 p seen=' '
  for p in "$TARGET" "$HOME/bin/cohort" "$HOME/.local/bin/cohort"; do
    [[ -e $p || -L $p ]] || continue
    [[ $seen == *" $p "* ]] && continue
    seen+="$p "
    if ours "$p"; then
      rm -f "$p"
      status removed "$p"
      found=1
    else
      status skipped "$p is not ours — left alone"
    fi
  done
  [[ $found -eq 1 ]] || status absent
}

uninstall_md() {
  section "Guidance for Claude"
  if [[ ! -f $CLAUDE_MD ]] || ! grep -qF "$BEGIN_MARK" "$CLAUDE_MD"; then
    status absent
    return
  fi
  local body
  body=$(strip_block <"$CLAUDE_MD" | trim_trailing_blank)
  if [[ -z $body ]]; then
    rm -f "$CLAUDE_MD"
    status removed "deleted now-empty $CLAUDE_MD"
  else
    printf '%s\n' "$body" >"$CLAUDE_MD"
    status removed "$CLAUDE_MD"
  fi
}

if [[ $MODE == install ]]; then
  banner

  # Every cohort session is a tmux session, so this is a dependency rather than
  # a nicety. Check it first: nothing else is worth writing to disk if the
  # answer is no, and finding out afterwards would leave a half-useful install.
  if [[ $WANT_TMUX -eq 1 ]] && ! install_tmux; then
    section "Stopped"
    printf '  nothing was installed — cohort runs every session in tmux\n'
    note "install tmux and run this again, or pass --no-tmux to install without it"
    printf '\n'
    exit 1
  fi

  install_bin
  tidy_old_bin
  install_md
  install_completion

  # Say plainly whether the command works right now, because "installed" and
  # "usable in this shell" are not the same thing when PATH had to change.
  section "Ready"
  if (( NEEDS_PATH )); then
    if [[ -n $RELOAD_RC ]]; then
      status "almost" "$BINDIR was not on your PATH, so it was added to $RELOAD_RC"
      note "finish with:  source $RELOAD_RC        (or open a new terminal)"
    else
      status "almost" "$BINDIR is not on your PATH"
      note "add it with:  export PATH=\"$BINDIR:\$PATH\""
    fi
  else
    status "yes" "cohort is on your PATH in this shell"
    [[ -z $RELOAD_RC ]] || note "tab-completion starts in new shells, or run: source $RELOAD_RC"
  fi
  printf '\n'
  note "cohort new lead     start a session"
  note "cohort help         everything else"
  printf '\n'
else
  uninstall_bin
  uninstall_md
  uninstall_completion
  printf '\n'
  note "settings in $COHORT_DIR were left alone; delete that directory to remove them"
  printf '\n'
fi
