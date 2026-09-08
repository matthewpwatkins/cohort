#!/usr/bin/env bash
#
# cohort — run a group of peer Claude Code sessions, one per tmux session.
#
# Sessions this tool creates are named with a fixed prefix and tagged with a
# tmux user option, so `ls`, `attach` and `kill` only ever act on its own
# sessions and leave the rest of your tmux server alone. Run `cohort help` for
# the subcommand list.
#
# Installed by install-cohort.sh — local edits will be overwritten.

set -euo pipefail

TAG=@cohort
PREFIX=cohort-
DEFAULT_COMMAND=claude
DEFAULT_MODEL=claude-opus-5
CONFIG_DIR=${COHORT_CONFIG_DIR:-$HOME/.cohort}
SETTINGS=$CONFIG_DIR/settings.json

warn() { printf '%s\n' "$*" >&2; }
die()  { warn "cohort: $*"; exit 1; }

usage() {
  cat <<'USAGE'
usage: cohort <command> [args]

  new [--command CMD] <name> [claude args...]
                               spawn a detached session named cohort-<name>
  ls                           list sessions this tool created
  attach <name>                switch to a session (attach when outside tmux)
  kill <name>                  kill one session
  kill --all [--yes]           kill every session this tool created
  config                       show resolved settings and where each came from
  help [command]               longer help for a command

Everything after <name> in `new` passes through to claude verbatim.
Sessions are tmux sessions named cohort-<name>; subcommands take <name>.
USAGE
  exit "${1:-0}"
}

help_topic() {
  case ${1:-} in
    new) cat <<'H'
cohort new [--command CMD] <name> [claude args...]

Starts a detached tmux session named cohort-<name> running Claude Code, tagged
so the other subcommands recognise it. The prefix keeps the session clear of
tmux sessions you started yourself; every subcommand takes the bare <name> and
adds it back. Extra args pass through to claude verbatim.

Inherits $PWD, so cd into a worktree before spawning that worktree's worker.
Safe to run from inside tmux: it never steals your pane.

The launcher, model and permission mode each resolve highest-first:

  launcher          --command  >  $COHORT_COMMAND  >  settings.command  >  claude
  model             a model flag you pass  >  $COHORT_MODEL  >  settings.model
                                                            >  claude-opus-5
  permission mode   --permission-mode or --dangerously-skip-permissions that
                    you pass  >  $COHORT_MODE  >  settings.permissionMode
                    >  left unset

Run `cohort help config` for the settings file, and `cohort config` to see what
the current resolution actually is.
H
;;
    ls) cat <<'H'
cohort ls

One row per tagged session: name, git branch of its working directory, age,
whether a client is attached, and the directory itself. Names print without the
cohort- prefix, which is what the other subcommands take. Sessions started by
anything other than cohort are not listed.
H
;;
    attach) cat <<'H'
cohort attach <name>

Equivalent to `tmux attach -t cohort-<name>`, except that inside tmux it
switches the current client instead of nesting. Refuses sessions cohort did not
create — use tmux directly for those.
H
;;
    kill) cat <<'H'
cohort kill <name>
cohort kill --all [--yes]

Kills tagged sessions, given the bare <name>. Refuses any session cohort did
not create, so nothing outside the cohort- prefix is ever at risk.

Killing a session discards the Claude conversation running in it and leaves
whatever is uncommitted in its worktree untouched but unattended. There is no
bare `cohort kill` meaning "all": --all is explicit, prompts when interactive,
and requires --yes when not.
H
;;
    config) cat <<'H'
cohort config

Prints each resolved setting and the source it came from.

Settings live in ~/.cohort/settings.json ($COHORT_CONFIG_DIR relocates the
directory). Every key is optional:

  {
    "command": "claude",
    "model": "claude-opus-5",
    "permissionMode": "bypassPermissions",
    "args": ["--verbose"]
  }

  command         launcher to run. A string is split on whitespace; use an
                  array when an argument contains spaces. Must be an
                  executable on PATH — a shell alias or function cannot be
                  used, because the session is started as argv rather than
                  through a shell. Wrap one like this instead:
                    "command": ["env", "CLAUDE_CONFIG_DIR=/path", "claude"]
  model           model flag for new sessions.
  permissionMode  --permission-mode for new sessions.
  args            extra arguments added to every session, before yours.

Prefer this file over the environment variables for anything you want to
persist. A detached tmux session inherits the tmux server's environment, not
your shell's, so COHORT_* variables do not survive into a spawned session and
a lead cannot pass them on to workers it spawns. The settings file is read
fresh on every invocation, so it does.
H
;;
    ''|help) usage 0 ;;
    *) die "no help topic '$1'" ;;
  esac
}

SET_COMMAND='' SET_MODEL='' SET_MODE='' SET_ARGS=()

# Read the settings file into SET_*. A missing file is fine; an unreadable or
# malformed one is fatal, because silently falling back to defaults would spawn
# sessions the user believes they have configured.
load_settings() {
  [[ -f $SETTINGS ]] || return 0
  local out key val
  if command -v jq >/dev/null; then
    out=$(jq -r '
      (.command // empty | if type == "array" then .[] | "carg\t" + . else "command\t" + . end),
      (.model // empty | "model\t" + .),
      (.permissionMode // empty | "permissionMode\t" + .),
      ((.args // [])[] | "arg\t" + .),
      (keys[] as $k | select(["command","model","permissionMode","args"] | index($k) | not) | "unknown\t" + $k)
    ' "$SETTINGS" 2>/dev/null) || die "could not parse $SETTINGS"
  elif command -v python3 >/dev/null; then
    out=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write("%s\n" % e); sys.exit(1)
if not isinstance(d, dict):
    sys.stderr.write("top level is not an object\n"); sys.exit(1)
c = d.get("command")
if isinstance(c, list):
    for w in c: print("carg\t%s" % w)
elif c is not None:
    print("command\t%s" % c)
for k in ("model", "permissionMode"):
    if k in d: print("%s\t%s" % (k, d[k]))
for a in d.get("args") or []: print("arg\t%s" % a)
for k in d:
    if k not in ("command", "model", "permissionMode", "args"): print("unknown\t%s" % k)
' "$SETTINGS") || die "could not parse $SETTINGS"
  else
    die "$SETTINGS exists but neither jq nor python3 is available to read it"
  fi

  local -a cargs=()
  while IFS=$'\t' read -r key val; do
    case $key in
      command) SET_COMMAND=$val ;;
      carg) cargs+=("$val") ;;
      model) SET_MODEL=$val ;;
      permissionMode) SET_MODE=$val ;;
      arg) SET_ARGS+=("$val") ;;
      unknown) warn "cohort: ignoring unknown setting '$val' in $SETTINGS" ;;
    esac
  done <<<"$out"
  [[ ${#cargs[@]} -eq 0 ]] || SET_COMMAND=${cargs[*]}
}

need_tmux() { command -v tmux >/dev/null || die "tmux not found"; }

# Every tmux session this tool creates is named "cohort-<name>", so a worker
# called `auth` cannot collide with a hand-rolled tmux session of that name.
# Subcommands take the short name; typing the prefixed name works too, so
# copying a name out of `tmux ls` does the expected thing.
full_name()  { printf '%s%s' "$PREFIX" "${1#"$PREFIX"}"; }
short_name() { printf '%s' "${1#"$PREFIX"}"; }

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
  load_settings

  local cmd_override=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --command) [[ $# -ge 2 ]] || die "--command needs a value"; cmd_override=$2; shift 2 ;;
      --command=*) cmd_override=${1#*=}; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  [[ $# -ge 1 && $1 != -* ]] || usage 2
  local name session
  name=$(short_name "$1"); shift
  case $name in
    '') die "session name cannot be just '$PREFIX'" ;;
    *:*|*.*) die "session name cannot contain ':' or '.'" ;;
  esac
  session=$(full_name "$name")

  need_tmux

  # The launcher is a full argv, not just a program name, so a wrapper that
  # only exists as a shell function can be expressed as `env VAR=x claude`.
  local launcher=${cmd_override:-${COHORT_COMMAND:-${SET_COMMAND:-$DEFAULT_COMMAND}}}
  local -a program=()
  read -r -a program <<<"$launcher"
  [[ ${#program[@]} -ge 1 ]] || die "empty launcher command"
  command -v "${program[0]}" >/dev/null \
    || die "'${program[0]}' not found (a shell alias or function cannot be used — see 'cohort help config')"

  ! session_exists "$session" || die "'$name' already exists (tmux session $session)"

  # Seed the array so it is never empty: bash 3.2 (stock macOS) errors on
  # expanding an empty array under `set -u`.
  local args=("${program[@]}" -n "$name") a model_set=0 mode_set=0
  for a in "$@"; do
    case $a in
      -m|--model|--model=*) model_set=1 ;;
      --permission-mode|--permission-mode=*|--dangerously-skip-permissions) mode_set=1 ;;
    esac
  done

  local model=${COHORT_MODEL:-${SET_MODEL:-$DEFAULT_MODEL}}
  [[ $model_set -eq 1 || -z $model ]] || args+=(--model "$model")

  local mode=${COHORT_MODE:-${SET_MODE:-}}
  [[ $mode_set -eq 1 || -z $mode ]] || args+=(--permission-mode "$mode")

  [[ ${#SET_ARGS[@]} -eq 0 ]] || args+=("${SET_ARGS[@]}")
  args+=("$@")

  # Capture the session id rather than re-targeting by name: set-option does
  # not accept the "=" exact-match prefix, and an id cannot prefix-match some
  # other session the way a bare name can.
  local sid
  sid=$(tmux new-session -d -P -F '#{session_id}' -s "$session" -c "$PWD" "${args[@]}")

  # Tag it. A session that died on startup cannot be tagged, and would other-
  # wise look like someone else's session to every later subcommand.
  if ! tmux set-option -t "$sid" "$TAG" 1 2>/dev/null; then
    session_exists "$session" && die "started '$name' but could not tag it"
    die "'$name' exited immediately — check the launcher and claude args"
  fi

  if [[ -n ${TMUX:-} ]]; then
    printf '%s started as tmux session %s (cohort attach %s)\n' "$name" "$session" "$name"
  else
    tmux attach -t "=$session"
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
  # Rows carry the real tmux names; the prefix is noise in a listing where
  # every row has it, and the short name is what the other subcommands take.
  while IFS=$'\t' read -r name path created attached; do
    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo -)
    age=$(human_age $(( now - created )))
    printf '%-20s %-22s %-8s %-9s %s\n' \
      "$(short_name "$name")" "$branch" "$age" "$([[ $attached == 0 ]] && echo no || echo yes)" "$path"
  done <<<"$rows"
}

cmd_attach() {
  [[ $# -eq 1 ]] || usage 2
  need_tmux
  local session
  session=$(full_name "$1")
  session_exists "$session" || die "no session '$(short_name "$1")'"
  is_ours "$session" || die "'$session' is not a cohort session — use 'tmux attach -t $session'"
  if [[ -n ${TMUX:-} ]]; then
    tmux switch-client -t "=$session"
  else
    tmux attach -t "=$session"
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
      *) names+=("$(full_name "$1")") ;;
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
      local shortnames=()
      for line in "${names[@]}"; do shortnames+=("$(short_name "$line")"); done
      printf 'kill %d cohort session(s): %s\n' "$count" "${shortnames[*]}"
      read -r -p 'proceed? [y/N] ' reply
      [[ $reply == [yY]* ]] || { echo "cancelled"; return; }
    fi
  else
    [[ ${#names[@]} -ge 1 ]] || die "kill needs a session name, or --all"
  fi

  local name rc=0
  for name in "${names[@]}"; do
    if ! session_exists "$name"; then
      warn "cohort: no session '$(short_name "$name")'"; rc=1; continue
    fi
    if ! is_ours "$name"; then
      warn "cohort: skipped '$name' — not a cohort session"; rc=1; continue
    fi
    tmux kill-session -t "=$name"
    echo "killed $(short_name "$name")"
  done
  return $rc
}

cmd_config() {
  load_settings
  local exists='present'
  [[ -f $SETTINGS ]] || exists='absent'
  printf 'settings: %s (%s)\n\n' "$SETTINGS" "$exists"

  local v s
  printf '%-16s %-34s %s\n' SETTING VALUE SOURCE

  if   [[ -n ${COHORT_COMMAND:-} ]]; then v=$COHORT_COMMAND s='$COHORT_COMMAND'
  elif [[ -n $SET_COMMAND ]];       then v=$SET_COMMAND     s='settings.command'
  else                                   v=$DEFAULT_COMMAND s='default'; fi
  printf '%-16s %-34s %s\n' command "$v" "$s"

  if   [[ -n ${COHORT_MODEL:-} ]]; then v=$COHORT_MODEL   s='$COHORT_MODEL'
  elif [[ -n $SET_MODEL ]];        then v=$SET_MODEL      s='settings.model'
  else                                  v=$DEFAULT_MODEL  s='default'; fi
  printf '%-16s %-34s %s\n' model "$v" "$s"

  if   [[ -n ${COHORT_MODE:-} ]]; then v=$COHORT_MODE s='$COHORT_MODE'
  elif [[ -n $SET_MODE ]];        then v=$SET_MODE    s='settings.permissionMode'
  else                                 v='(unset)'    s='default'; fi
  printf '%-16s %-34s %s\n' permissionMode "$v" "$s"

  if [[ ${#SET_ARGS[@]} -gt 0 ]]; then
    printf '%-16s %-34s %s\n' args "${SET_ARGS[*]}" 'settings.args'
  else
    printf '%-16s %-34s %s\n' args '(none)' 'default'
  fi
  echo
  echo "A flag passed to 'cohort new' overrides every row above."
}

[[ $# -ge 1 ]] || usage 2
cmd=$1; shift
case $cmd in
  new)    cmd_new "$@" ;;
  ls|list) cmd_ls "$@" ;;
  attach) cmd_attach "$@" ;;
  kill)   cmd_kill "$@" ;;
  config) cmd_config "$@" ;;
  help)   help_topic "${1:-}" ;;
  -h|--help) usage 0 ;;
  *) warn "cohort: unknown command '$cmd'"; usage 2 ;;
esac
