#!/usr/bin/env bash
#
# cohort — run a group of peer Claude Code sessions, one per tmux session.
#
# Sessions this tool creates are tagged with a tmux user option, so `ls`,
# `attach` and `kill` only ever act on its own sessions and leave the rest of
# your tmux server alone. Run `cohort help` for the subcommand list.
#
# Installed by install-cohort.sh — local edits will be overwritten.

set -euo pipefail

TAG=@cohort
DEFAULT_MODEL=claude-opus-5

warn() { printf '%s\n' "$*" >&2; }
die()  { warn "cohort: $*"; exit 1; }

usage() {
  cat <<'USAGE'
usage: cohort <command> [args]

  new <name> [claude args...]  spawn a detached session named <name>
  ls                           list sessions this tool created
  attach <name>                switch to a session (attach when outside tmux)
  kill <name>                  kill one session
  kill --all [--yes]           kill every session this tool created
  help [command]               longer help for a command

Everything after <name> in `new` passes through to claude verbatim.
USAGE
  exit "${1:-0}"
}

help_topic() {
  case ${1:-} in
    new) cat <<'H'
cohort new <name> [claude args...]

Starts a detached tmux session named <name> running Claude Code, tagged so the
other subcommands recognise it. Extra args pass through to claude verbatim;
the model defaults to claude-opus-5 when no model flag is given.

Inherits $PWD, so cd into a worktree before spawning that worktree's worker.
Safe to run from inside tmux: it never steals your pane.

When COHORT_MODE is set and you pass no --permission-mode, it is forwarded to
claude. Peer sessions whose permission mode class differs from the sender hold
inbound messages for human approval, so workers should match their lead.
H
;;
    ls) cat <<'H'
cohort ls

One row per tagged session: name, git branch of its working directory, age,
whether a client is attached, and the directory itself. Sessions started by
anything other than cohort are not listed.
H
;;
    attach) cat <<'H'
cohort attach <name>

Inside tmux, switches the current client to <name>. Outside tmux, attaches.
Refuses sessions cohort did not create — use tmux directly for those.
H
;;
    kill) cat <<'H'
cohort kill <name>
cohort kill --all [--yes]

Kills tagged sessions. Refuses any session cohort did not create, so a name
collision with your own tmux session cannot cost you that session.

Killing a session discards the Claude conversation running in it and leaves
whatever is uncommitted in its worktree untouched but unattended. There is no
bare `cohort kill` meaning "all": --all is explicit, prompts when interactive,
and requires --yes when not.
H
;;
    ''|help) usage 0 ;;
    *) die "no help topic '$1'" ;;
  esac
}

need_tmux() { command -v tmux >/dev/null || die "tmux not found"; }

# True when <name> is a live session that cohort created. The tag is a tmux
# user option, not a naming convention, so unrelated sessions can never match.
#
# Derived from the same listing `ls` uses, deliberately: `display-message -t`
# silently returns empty for a "=name" target instead of erroring, which would
# make every session look untagged and every kill refuse.
is_ours() {
  local n
  while IFS=$'\t' read -r n _; do
    [[ $n == "$1" ]] && return 0
  done < <(tagged)
  return 1
}

session_exists() { tmux has-session -t "=$1" 2>/dev/null; }

# Print tagged sessions as: name<TAB>path<TAB>created<TAB>attached
tagged() {
  tmux list-sessions -F "#{$TAG}"$'\t'"#{session_name}"$'\t'"#{session_path}"$'\t'"#{session_created}"$'\t'"#{session_attached}" 2>/dev/null \
    | awk -F'\t' '$1 == 1 { sub(/^[^\t]*\t/, ""); print }'
}

human_age() {
  local s=$1
  if   (( s < 60 ));    then printf '%ds' "$s"
  elif (( s < 3600 ));  then printf '%dm' $(( s / 60 ))
  elif (( s < 86400 )); then printf '%dh%dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  else                       printf '%dd%dh' $(( s / 86400 )) $(( s % 86400 / 3600 ))
  fi
}

cmd_new() {
  [[ $# -ge 1 && $1 != -* ]] || usage 2
  local name=$1; shift
  case $name in
    *:*|*.*) die "session name cannot contain ':' or '.'" ;;
  esac

  need_tmux
  command -v claude >/dev/null || die "claude not found"
  ! session_exists "$name" || die "'$name' already exists"

  # Seed the array so it is never empty: bash 3.2 (stock macOS) errors on
  # expanding an empty array under `set -u`.
  local args=(claude -n "$name") a model_set=0 mode_set=0
  for a in "$@"; do
    case $a in
      -m|--model|--model=*) model_set=1 ;;
      --permission-mode|--permission-mode=*) mode_set=1 ;;
    esac
  done
  [[ $model_set -eq 1 ]] || args+=(--model "$DEFAULT_MODEL")
  [[ $mode_set -eq 1 || -z ${COHORT_MODE:-} ]] || args+=(--permission-mode "$COHORT_MODE")
  args+=("$@")

  # Capture the session id rather than re-targeting by name: set-option does
  # not accept the "=" exact-match prefix, and an id cannot prefix-match some
  # other session the way a bare name can.
  local sid
  sid=$(tmux new-session -d -P -F '#{session_id}' -s "$name" -c "$PWD" "${args[@]}")

  # Tag it. A session that died on startup cannot be tagged, and would other-
  # wise look like someone else's session to every later subcommand.
  if ! tmux set-option -t "$sid" "$TAG" 1 2>/dev/null; then
    session_exists "$name" && die "started '$name' but could not tag it"
    die "'$name' exited immediately — check the claude args"
  fi

  if [[ -n ${TMUX:-} ]]; then
    printf '%s started (cohort attach %s)\n' "$name" "$name"
  else
    tmux attach -t "=$name"
  fi
}

cmd_ls() {
  need_tmux
  local rows name path created attached now age branch
  rows=$(tagged) || true
  if [[ -z $rows ]]; then
    echo "no cohort sessions"
    return
  fi
  now=$(date +%s)
  printf '%-20s %-22s %-8s %-9s %s\n' NAME BRANCH AGE ATTACHED DIR
  while IFS=$'\t' read -r name path created attached; do
    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo -)
    age=$(human_age $(( now - created )))
    printf '%-20s %-22s %-8s %-9s %s\n' \
      "$name" "$branch" "$age" "$([[ $attached == 0 ]] && echo no || echo yes)" "$path"
  done <<<"$rows"
}

cmd_attach() {
  [[ $# -eq 1 ]] || usage 2
  need_tmux
  session_exists "$1" || die "no session '$1'"
  is_ours "$1" || die "'$1' is not a cohort session — use 'tmux attach -t $1'"
  if [[ -n ${TMUX:-} ]]; then
    tmux switch-client -t "=$1"
  else
    tmux attach -t "=$1"
  fi
}

cmd_kill() {
  [[ $# -ge 1 ]] || die "kill needs a session name, or --all"
  need_tmux

  local all=0 yes=0 reply names=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --all) all=1 ;;
      -y|--yes) yes=1 ;;
      -*) die "unknown option: $1" ;;
      *) names+=("$1") ;;
    esac
    shift
  done

  if [[ $all -eq 1 ]]; then
    [[ ${#names[@]} -eq 0 ]] || die "--all takes no session names"
    local rows line count
    rows=$(tagged) || true
    [[ -n $rows ]] || { echo "no cohort sessions"; return; }
    while IFS= read -r line; do names+=("$line"); done < <(cut -f1 <<<"$rows")
    count=${#names[@]}
    if [[ $yes -eq 0 ]]; then
      [[ -t 0 ]] || die "refusing --all without --yes when not interactive"
      printf 'kill %d cohort session(s): %s\n' "$count" "${names[*]}"
      read -r -p 'proceed? [y/N] ' reply
      [[ $reply == [yY]* ]] || { echo "cancelled"; return; }
    fi
  else
    [[ ${#names[@]} -ge 1 ]] || die "kill needs a session name, or --all"
  fi

  local name rc=0
  for name in "${names[@]}"; do
    if ! session_exists "$name"; then
      warn "cohort: no session '$name'"; rc=1; continue
    fi
    if ! is_ours "$name"; then
      warn "cohort: skipped '$name' — not a cohort session"; rc=1; continue
    fi
    tmux kill-session -t "=$name"
    echo "killed $name"
  done
  return $rc
}

[[ $# -ge 1 ]] || usage 2
cmd=$1; shift
case $cmd in
  new)    cmd_new "$@" ;;
  ls|list) cmd_ls "$@" ;;
  attach) cmd_attach "$@" ;;
  kill)   cmd_kill "$@" ;;
  help)   help_topic "${1:-}" ;;
  -h|--help) usage 0 ;;
  *) warn "cohort: unknown command '$cmd'"; usage 2 ;;
esac
