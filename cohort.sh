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
WT_TAG=@cohort_worktree
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

  new [--command CMD] [-W|--no-worktree] <name> [claude args...]
                               spawn a detached session named cohort-<name>
  ls [--names]                 list sessions this tool created
  attach [name|number]         switch to a session; with no argument, pick one
  kill <name>                  kill one session
  kill --all [--yes]           kill every session this tool created
  config                       show resolved settings and where each came from
  completion [bash|zsh|fish]   print a shell completion script
  help [command]               longer help for a command

Short forms: n, l, a, k for new, ls, attach, kill.

Everything after <name> in `new` passes through to claude verbatim.
Sessions are tmux sessions named cohort-<name>; subcommands take <name>.
USAGE
  exit "${1:-0}"
}

help_topic() {
  case ${1:-} in
    new) cat <<'H'
cohort new [--command CMD] [-W|--no-worktree] <name> [claude args...]

Starts a detached tmux session named cohort-<name> running Claude Code, tagged
so the other subcommands recognise it. The prefix keeps the session clear of
tmux sessions you started yourself; every subcommand takes the bare <name> and
adds it back. Extra args pass through to claude verbatim.

Inherits $PWD. Safe to run from inside tmux: it never steals your pane. From a
plain prompt outside tmux it attaches you to the new session; with no terminal
to attach to, as in a script or a CI job, it prints the name and returns.

The launcher, model and permission mode each resolve highest-first:

  launcher          --command  >  $COHORT_COMMAND  >  settings.command  >  claude
  model             a model flag you pass  >  $COHORT_MODEL  >  settings.model
                                                            >  claude-opus-5
  permission mode   --permission-mode or --dangerously-skip-permissions that
                    you pass  >  $COHORT_MODE  >  settings.permissionMode
                    >  left unset
  worktree          --worktree/-w or --no-worktree/-W that you pass
                    >  $COHORT_WORKTREE  >  settings.worktree  >  on

With worktrees on, the session gets `--worktree <name>`, so claude puts it on
its own branch in <repo>/.claude/worktrees/<name> and `cohort ls` reports that
directory. --no-worktree (-W) keeps the worker in the current checkout; passing
--worktree yourself (with or without a name) is honoured verbatim.

Run `cohort help config` for the settings file, and `cohort config` to see what
the current resolution actually is.
H
;;
    ls) cat <<'H'
cohort ls [--names]

One row per tagged session: name, git branch of its working directory, age,
whether a client is attached, and the directory itself. Names print without the
cohort- prefix, which is what the other subcommands take. Sessions started by
anything other than cohort are not listed.

For a session in its own worktree the directory and branch are the worktree's,
not the directory the session was spawned from.

--names prints just the bare names, one per line, for scripts and completion.
H
;;
    attach) cat <<'H'
cohort attach [name|number]   (short form: cohort a)

Equivalent to `tmux attach -t cohort-<name>`, except that inside tmux it
switches the current client instead of nesting. Refuses sessions cohort did not
create — use tmux directly for those.

Takes the number from the # column of `cohort ls` as well as the name. A name
is always tried first, so a session actually called "2" is still reachable.

With no argument it lists the sessions and asks which one, or goes straight
there when only one is running.
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
    "worktree": true,
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
  worktree        false to stop giving every new session its own git
                  worktree. Defaults to true.
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

SET_COMMAND='' SET_MODEL='' SET_MODE='' SET_WORKTREE='' SET_ARGS=()

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
      (if has("worktree") then "worktree\t" + (.worktree | tostring) else empty end),
      ((.args // [])[] | "arg\t" + .),
      (keys[] as $k | select(["command","model","permissionMode","worktree","args"] | index($k) | not) | "unknown\t" + $k)
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
if "worktree" in d:
    print("worktree\t%s" % json.dumps(d["worktree"]))
for a in d.get("args") or []: print("arg\t%s" % a)
for k in d:
    if k not in ("command", "model", "permissionMode", "worktree", "args"): print("unknown\t%s" % k)
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
      worktree) SET_WORKTREE=$val ;;
      arg) SET_ARGS+=("$val") ;;
      unknown) warn "cohort: ignoring unknown setting '$val' in $SETTINGS" ;;
    esac
  done <<<"$out"
  [[ ${#cargs[@]} -eq 0 ]] || SET_COMMAND=${cargs[*]}
}

# `tagged` reads the tag through a #{@user-option} format, which older tmux
# does not interpolate: it returns empty for every session, so nothing looks
# like a cohort session and every subcommand quietly does nothing. Fail with a
# reason instead. An unparseable version (a self-built "master") is let through
# rather than blocked on a guess.
TMUX_MIN_MAJOR=3
need_tmux() {
  command -v tmux >/dev/null || die "tmux not found"
  local v major
  v=$(tmux -V 2>/dev/null) || return 0
  v=${v#tmux }; v=${v#next-}
  major=${v%%.*}
  case $major in
    ''|*[!0-9]*) return 0 ;;
  esac
  (( major >= TMUX_MIN_MAJOR )) \
    || die "tmux $v is too old — cohort needs ${TMUX_MIN_MAJOR}.0 or newer"
}

# Settings and environment both carry the worktree switch as free text, so one
# place decides what counts as off. Anything else, including an empty string
# from an unset variable's default, is on.
is_off() {
  case $(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]') in
    0|false|no|off) return 0 ;;
    *) return 1 ;;
  esac
}

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

# Print tagged sessions as: name<TAB>path<TAB>created<TAB>attached<TAB>worktree
#
# The worktree field is the directory claude was asked to create for the
# session, which is not where the session was spawned from and so cannot be
# derived from session_path.
tagged() {
  tmux list-sessions -F "#{$TAG}"$'\t'"#{session_name}"$'\t'"#{session_path}"$'\t'"#{session_created}"$'\t'"#{session_attached}"$'\t'"#{$WT_TAG}" 2>/dev/null \
    | awk -F'\t' '$1 == 1 { sub(/^[^\t]*\t/, ""); print }' \
    | sort
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

  # cohort's own flags are accepted on either side of <name>: the name is what
  # separates them from claude's, not position, and usage advertises them first.
  local cmd_override='' wt_set=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --command) [[ $# -ge 2 ]] || die "--command needs a value"; cmd_override=$2; shift 2 ;;
      --command=*) cmd_override=${1#*=}; shift ;;
      -W|--no-worktree) wt_set=1; shift ;;
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
  local -a passthru=()
  for a in "$@"; do
    case $a in
      -m|--model|--model=*) model_set=1; passthru+=("$a") ;;
      --permission-mode|--permission-mode=*|--dangerously-skip-permissions) mode_set=1; passthru+=("$a") ;;
      -w|--worktree|--worktree=*) wt_set=1; passthru+=("$a") ;;
      # cohort's own switch, and the only arg after <name> claude never sees.
      -W|--no-worktree) wt_set=1 ;;
      *) passthru+=("$a") ;;
    esac
  done

  local model=${COHORT_MODEL:-${SET_MODEL:-$DEFAULT_MODEL}}
  [[ $model_set -eq 1 || -z $model ]] || args+=(--model "$model")

  local mode=${COHORT_MODE:-${SET_MODE:-}}
  [[ $mode_set -eq 1 || -z $mode ]] || args+=(--permission-mode "$mode")

  # A worker gets its own branch unless told otherwise, so two of them editing
  # the same repo at once cannot tread on each other. Naming the worktree after
  # the session is what lets `ls` report where the session actually lives.
  # claude refuses to start at all when handed --worktree outside a repository,
  # which would surface here as a bare "exited immediately".
  local wtdir='' root
  if [[ $wt_set -eq 0 ]] && ! is_off "${COHORT_WORKTREE:-${SET_WORKTREE:-on}}"; then
    if root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null); then
      args+=(--worktree "$name")
      wtdir=$root/.claude/worktrees/$name
      # claude branches a new worktree off the tracked remote branch, not the
      # checkout it was launched from, so anything committed locally and not
      # pushed is invisible to the worker that is about to start.
      local up ahead
      if up=$(git -C "$root" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
        ahead=$(git -C "$root" rev-list --count "$up..HEAD" 2>/dev/null || echo 0)
        [[ ${ahead:-0} -gt 0 ]] && warn \
          "cohort: HEAD is $ahead commit(s) ahead of $up; '$name' branches from $up and will not see them"
      fi
    else
      warn "cohort: $PWD is not a git repository — starting '$name' without a worktree"
    fi
  fi

  [[ ${#SET_ARGS[@]} -eq 0 ]] || args+=("${SET_ARGS[@]}")
  [[ ${#passthru[@]} -eq 0 ]] || args+=("${passthru[@]}")

  # Capture the session id rather than re-targeting by name: set-option does
  # not accept the "=" exact-match prefix, and an id cannot prefix-match some
  # other session the way a bare name can.
  # Hold a pane that dies during startup open so its error can be read back,
  # set in the same tmux invocation that creates the session: a launcher that
  # fails instantly can otherwise be gone before a second call lands. Turned
  # off again once the session has settled, so that a session the user exits
  # normally still disappears instead of lingering dead in `ls`.
  local sid
  sid=$(tmux new-session -d -P -F '#{session_id}' -s "$session" -c "$PWD" "${args[@]}" \
        ';' set-option -t "$session" remain-on-exit on)

  # Tag it. An untagged session would look like someone else's to every later
  # subcommand, so a failure here is fatal rather than cosmetic.
  if ! tmux set-option -t "$sid" "$TAG" 1 2>/dev/null; then
    session_exists "$session" && die "started '$name' but could not tag it"
    die "'$name' exited immediately — check the launcher and claude args"
  fi
  [[ -z $wtdir ]] || tmux set-option -t "$sid" "$WT_TAG" "$wtdir" 2>/dev/null || true

  # claude validates against the directory rather than the command line — an
  # untrusted workspace, or --worktree where one cannot be made — so it starts
  # cleanly and exits about half a second later. tmux has long since reported
  # success by then, and without this the failure shows up only as a session
  # missing from `ls`.
  local waited=0 dead=0 out
  while (( waited < 20 )); do
    [[ $(tmux display-message -p -t "$sid" '#{pane_dead}' 2>/dev/null) == 1 ]] && { dead=1; break; }
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  if (( dead )); then
    # "Pane is dead ..." is tmux's own footer, not the launcher's output.
    out=$(tmux capture-pane -p -S -30 -t "$sid" 2>/dev/null \
      | sed -e '/^[[:space:]]*$/d' -e '/^Pane is dead/d' | tail -8)
    tmux kill-session -t "$sid" 2>/dev/null || true
    warn "cohort: '$name' exited during startup:"
    [[ -z $out ]] || printf '%s\n' "$out" | sed 's/^/  | /' >&2
    exit 1
  fi
  tmux set-option -t "$sid" remain-on-exit off 2>/dev/null || true

  # Attaching is the friendly thing for someone at a prompt, and the wrong
  # thing everywhere else: with no terminal to attach to, tmux fails with
  # "open terminal failed" and `new` exits non-zero despite having started the
  # session, which makes cohort unusable from a script or a CI job.
  if [[ -n ${TMUX:-} || ! -t 0 || ! -t 1 ]]; then
    printf '%s started as tmux session %s (cohort attach %s)\n' "$name" "$session" "$name"
  else
    tmux attach -t "=$session"
  fi
}

cmd_ls() {
  local names_only=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --names) names_only=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  need_tmux
  local rows name path created attached wt now age branch fmt
  rows=$(tagged) || true
  if [[ -z $rows ]]; then
    [[ $names_only -eq 1 ]] || echo "no cohort sessions"
    return
  fi
  if [[ $names_only -eq 1 ]]; then
    while IFS=$'\t' read -r name _; do short_name "$name"; echo; done <<<"$rows"
    return
  fi
  now=$(date +%s)
  # Build every row first so the columns can be sized to what is actually in
  # them: session names come from ticket ids as often as from short words.
  local -a out=()
  local nw=4 bw=6 line i=0
  # Rows carry the real tmux names; the prefix is noise in a listing where
  # every row has it, and the short name is what the other subcommands take.
  while IFS=$'\t' read -r name path created attached wt; do
    # A session spawned with a worktree runs in a directory tmux never knew
    # about, and only exists once claude has created it.
    [[ -n ${wt:-} && -d $wt ]] && path=$wt
    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo -)
    name=$(short_name "$name")
    age=$(human_age $(( now - created )))
    if [[ ${#name} -gt $nw ]]; then nw=${#name}; fi
    if [[ ${#branch} -gt $bw ]]; then bw=${#branch}; fi
    i=$(( i + 1 ))
    out+=("$i"$'\t'"$name"$'\t'"$branch"$'\t'"$age"$'\t'"$([[ $attached == 0 ]] && echo no || echo yes)"$'\t'"$path")
  done <<<"$rows"

  # The number is what `attach` takes as a shorthand, so it is a real column
  # rather than decoration.
  fmt="%-3s %-${nw}s  %-${bw}s  %-6s  %-8s  %s\n"
  # shellcheck disable=SC2059
  printf "$fmt" '#' NAME BRANCH AGE ATTACHED DIR
  local n
  for line in "${out[@]}"; do
    IFS=$'\t' read -r n name branch age attached path <<<"$line"
    # shellcheck disable=SC2059
    printf "$fmt" "$n" "$name" "$branch" "$age" "$attached" "$path"
  done
}

# Set PICKED to the full session name a reference denotes. A reference is a
# name or the number `ls` printed beside it; the name is tried first, so a
# session someone actually called "2" stays reachable by name.
PICKED=''
resolve_session() {
  local ref=$1 full name n=0
  full=$(full_name "$ref")
  if session_exists "$full"; then PICKED=$full; return 0; fi
  case $ref in ''|*[!0-9]*) return 1 ;; esac
  while IFS=$'\t' read -r name _; do
    n=$(( n + 1 ))
    if [[ $n -eq $ref ]]; then PICKED=$name; return 0; fi
  done < <(tagged)
  return 1
}

# Choose a session when none was named: straight there if only one is running,
# otherwise show the list and ask.
pick_session() {
  local rows count reply
  rows=$(tagged) || true
  [[ -n $rows ]] || { echo "no cohort sessions"; return 1; }
  count=$(printf '%s\n' "$rows" | wc -l)
  if [[ $count -eq 1 ]]; then
    PICKED=$(printf '%s' "$rows" | cut -f1)
    return 0
  fi
  [[ -t 0 ]] || die "attach needs a session name when there is no terminal to ask on"
  cmd_ls
  printf '\nattach which? [number or name] '
  read -r reply || return 1
  [[ -n $reply ]] || { echo "cancelled"; return 1; }
  resolve_session "$reply" || die "no session '$reply'"
}

cmd_attach() {
  [[ $# -le 1 ]] || usage 2
  need_tmux
  local session
  if [[ $# -eq 0 ]]; then
    pick_session || return 1
    session=$PICKED
  else
    resolve_session "$1" || die "no session '$1'"
    session=$PICKED
  fi
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

  if   [[ -n ${COHORT_WORKTREE:-} ]]; then v=$COHORT_WORKTREE s='$COHORT_WORKTREE'
  elif [[ -n $SET_WORKTREE ]];        then v=$SET_WORKTREE    s='settings.worktree'
  else                                     v='true'           s='default'; fi
  is_off "$v" && v=false || v=true
  printf '%-16s %-34s %s\n' worktree "$v" "$s"

  if [[ ${#SET_ARGS[@]} -gt 0 ]]; then
    printf '%-16s %-34s %s\n' args "${SET_ARGS[*]}" 'settings.args'
  else
    printf '%-16s %-34s %s\n' args '(none)' 'default'
  fi
  echo
  echo "A flag passed to 'cohort new' overrides every row above."
}

# Completion for session names comes from `cohort ls --names` rather than from
# tmux directly, so it can never offer a session cohort would refuse to touch.
cmd_completion() {
  case ${1:-bash} in
    bash) cat <<'H'
_cohort() {
  local cur cmds
  cur=${COMP_WORDS[COMP_CWORD]}
  cmds="new ls attach kill config completion help"
  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$cmds" -- "$cur"))
    return
  fi
  case ${COMP_WORDS[1]} in
    attach|a|kill|k) COMPREPLY=($(compgen -W "$(cohort ls --names 2>/dev/null)" -- "$cur")) ;;
    help)            COMPREPLY=($(compgen -W "$cmds" -- "$cur")) ;;
    completion)      COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur")) ;;
  esac
}
complete -F _cohort cohort
H
;;
    zsh) cat <<'H'
# Sourced from .zshrc, which may run before or after compinit.
(( $+functions[compdef] )) || { autoload -Uz compinit && compinit -C; }

_cohort() {
  local -a cmds
  cmds=(new ls attach kill config completion help)
  if (( CURRENT == 2 )); then
    compadd -- $cmds
    return
  fi
  case ${words[2]} in
    attach|a|kill|k) compadd -- ${(f)"$(cohort ls --names 2>/dev/null)"} ;;
    help)            compadd -- $cmds ;;
    completion)      compadd -- bash zsh fish ;;
  esac
}
compdef _cohort cohort
H
;;
    fish) cat <<'H'
function __cohort_names
  cohort ls --names 2>/dev/null
end
complete -c cohort -f
complete -c cohort -n __fish_use_subcommand -a 'new ls attach kill config completion help'
complete -c cohort -n '__fish_seen_subcommand_from attach a kill k' -a '(__cohort_names)'
complete -c cohort -n '__fish_seen_subcommand_from completion' -a 'bash zsh fish'
complete -c cohort -n '__fish_seen_subcommand_from help' -a 'new ls attach kill config'
complete -c cohort -n '__fish_seen_subcommand_from new' -l no-worktree -d 'keep the session in the current checkout'
complete -c cohort -n '__fish_seen_subcommand_from kill' -l all -d 'every cohort session'
complete -c cohort -n '__fish_seen_subcommand_from ls' -l names -d 'bare names, one per line'
H
;;
    *) die "no completion for '$1' — try bash, zsh or fish" ;;
  esac
}

# Only dispatch when run as a program. Sourcing the file gives you its
# functions without running anything, which is how the tests reach the parts
# that would otherwise need a terminal to observe.
if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
  [[ $# -ge 1 ]] || usage 2
  cmd=$1; shift
  case $cmd in
    new|n)     cmd_new "$@" ;;
    ls|list|l) cmd_ls "$@" ;;
    attach|a)  cmd_attach "$@" ;;
    kill|k)    cmd_kill "$@" ;;
    config)    cmd_config "$@" ;;
    completion) cmd_completion "$@" ;;
    help)      help_topic "${1:-}" ;;
    -h|--help) usage 0 ;;
    *) warn "cohort: unknown command '$cmd'"; usage 2 ;;
  esac
fi
