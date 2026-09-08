#!/usr/bin/env bash
#
# test-cohort.sh — exercise cohort and its installer without touching your own
# HOME, tmux sessions or Claude config.
#
# Every session is started with a stub launcher rather than claude, so the
# suite needs no credentials and no network. The handful of behaviours that
# only real claude can show (workspace trust, where a worktree branches from)
# are checked by hand; see the notes in README.
#
#   ./test-cohort.sh            run everything
#   ./test-cohort.sh -v         also print each passing assertion

set -uo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
COHORT=$SRC/cohort.sh
INSTALLER=$SRC/install-cohort.sh
VERBOSE=0
[[ ${1:-} == -v ]] && VERBOSE=1

pass=0 fail=0
ok()   { pass=$((pass + 1)); (( VERBOSE )) && printf '  ok   %s\n' "$1"; return 0; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [[ -z ${2:-} ]] || printf '       %s\n' "$2"; }
group() { printf '\n%s\n' "$1"; }

# Assert that running $2 produces output containing $3.
says() {
  local out
  out=$(eval "$2" 2>&1)
  case $out in
    *"$3"*) ok "$1" ;;
    *) bad "$1" "expected to contain: $3
       got: $out" ;;
  esac
}

# Assert that running $2 produces output NOT containing $3.
lacks() {
  local out
  out=$(eval "$2" 2>&1)
  case $out in
    *"$3"*) bad "$1" "should not contain: $3
       got: $out" ;;
    *) ok "$1" ;;
  esac
}

command -v tmux >/dev/null || { echo "tmux is required to run these tests" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'COHORT_CONFIG_DIR=$TMP/cfg "$COHORT" kill --all --yes >/dev/null 2>&1; rm -rf "$TMP"' EXIT

# A stub that stands in for claude: records the argv it was handed, then idles
# so the session stays up the way a real interactive session would.
mkdir -p "$TMP/cfg" "$TMP/bin"
cat >"$TMP/bin/stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/argv"
sleep 120
EOF
cat >"$TMP/bin/dies" <<'EOF'
#!/usr/bin/env bash
echo "stub failure: something went wrong"
exit 1
EOF
chmod +x "$TMP/bin/stub" "$TMP/bin/dies"
: >"$TMP/argv"

export COHORT_CONFIG_DIR=$TMP/cfg
settings() { printf '%s' "$1" >"$TMP/cfg/settings.json"; }
# The argv the Nth spawned session was started with.
argv_of() { grep -m1 -- "-n $1 " "$TMP/argv" || grep -m1 -- "-n $1\$" "$TMP/argv"; }
spawn() { "$COHORT" new --command "$TMP/bin/stub" "$@" >/dev/null 2>&1; }

settings '{}'

group "usage and help"
says "bare invocation prints usage"      "'$COHORT'"                  "usage: cohort"
says "help new covers --no-worktree"     "'$COHORT' help new"         "--no-worktree"
says "help config documents worktree"    "'$COHORT' help config"      "worktree"
says "help ls documents --names"         "'$COHORT' help ls"          "--names"
says "unknown subcommand is named"       "'$COHORT' nope"             "unknown command 'nope'"
says "unknown help topic is named"       "'$COHORT' help nope"        "no help topic"

group "argument validation"
says "name cannot be only the prefix"    "'$COHORT' new cohort-"      "cannot be just"
says "name rejects a colon"              "'$COHORT' new 'a:b'"        "cannot contain"
says "name rejects a dot"                "'$COHORT' new 'a.b'"        "cannot contain"
says "missing launcher is reported"      "'$COHORT' new --command /nope x" "not found"
says "--command needs a value"           "'$COHORT' new --command"    "needs a value"
says "ls rejects unknown options"        "'$COHORT' ls --nope"        "unknown option"
says "kill needs a target"               "'$COHORT' kill"             "needs a session name"
says "kill --all takes no names"         "'$COHORT' kill --all foo"   "takes no session names"
says "attach needs an existing session"  "'$COHORT' attach ghost"     "no session 'ghost'"
says "completion rejects other shells"   "'$COHORT' completion fish"  "try bash or zsh"

group "settings"
settings '{"model":"m","permissionMode":"p","worktree":false,"args":["--x"]}'
says "model comes from settings"         "'$COHORT' config"           "m                                  settings.model"
says "permission mode from settings"     "'$COHORT' config"           "settings.permissionMode"
says "worktree false from settings"      "'$COHORT' config"           "false                              settings.worktree"
says "args from settings"                "'$COHORT' config"           "settings.args"
settings '{"bogus":1}'
says "unknown keys are called out"       "'$COHORT' config"           "ignoring unknown setting 'bogus'"
settings '{oops'
says "malformed settings are fatal"      "'$COHORT' config"           "could not parse"
settings '[1,2]'
says "non-object settings are fatal"     "'$COHORT' config"           "could not parse"
settings '{}'
says "env overrides the file"            "COHORT_MODEL=envm '$COHORT' config" '$COHORT_MODEL'

group "completion"
says "bash completion is a function"     "'$COHORT' completion bash"  "complete -F _cohort cohort"
says "zsh completion registers compdef"  "'$COHORT' completion zsh"   "compdef _cohort cohort"
says "completion offers session names"   "'$COHORT' completion bash"  "cohort ls --names"

group "spawning"
spawn wt-default
says "default asks claude for a worktree" "argv_of wt-default"        "--worktree wt-default"
spawn wt-off --no-worktree
lacks "--no-worktree suppresses it"      "argv_of wt-off"             "--worktree"
spawn --no-worktree wt-pre
lacks "--no-worktree works before name"  "argv_of wt-pre"             "--worktree"
spawn wt-explicit --worktree custom
says "an explicit --worktree passes through" "argv_of wt-explicit"    "--worktree custom"
lacks "and is not duplicated"            "argv_of wt-explicit"        "--worktree wt-explicit"
settings '{"worktree":false}'
spawn wt-settings-off
lacks "settings.worktree false disables" "argv_of wt-settings-off"    "--worktree"
says "COHORT_WORKTREE re-enables it" \
  "COHORT_WORKTREE=1 '$COHORT' new --command '$TMP/bin/stub' wt-env >/dev/null 2>&1; argv_of wt-env" \
  "--worktree wt-env"
settings '{}'
spawn model-given --model sonnet
lacks "a model you pass wins"            "argv_of model-given"        "--model claude-opus-5"
says "a launcher that dies is diagnosed" \
  "'$COHORT' new --command '$TMP/bin/dies' boom" "exited during startup"
says "and its output is shown"           "'$COHORT' new --command '$TMP/bin/dies' boom2" "stub failure"
says "duplicate names are refused"       "'$COHORT' new --command '$TMP/bin/stub' wt-default" "already exists"

group "listing"
says "ls has a header"                   "'$COHORT' ls"               "NAME"
says "ls shows a spawned session"        "'$COHORT' ls"               "wt-default"
says "--names is bare"                   "'$COHORT' ls --names"       "wt-default"
lacks "--names has no header"            "'$COHORT' ls --names"       "NAME"
spawn a-very-long-session-name-for-column-alignment --no-worktree
says "long names do not break alignment" \
  "'$COHORT' ls | awk 'NR>1 {print \$2}' | sort -u | head -1" "main"

group "foreign sessions are left alone"
tmux new-session -d -s cohort-imposter "sleep 120" 2>/dev/null
lacks "an untagged cohort- session is not listed" "'$COHORT' ls --names" "imposter"
says "attach refuses it"                 "'$COHORT' attach imposter"  "not a cohort session"
says "kill refuses it"                   "'$COHORT' kill imposter"    "not a cohort session"
tmux has-session -t "=cohort-imposter" 2>/dev/null && ok "and it survived" || bad "and it survived"
tmux kill-session -t "=cohort-imposter" 2>/dev/null

group "killing"
says "kill --all needs --yes when piped" "'$COHORT' kill --all </dev/null" "refusing --all"
says "kill names what it killed"         "'$COHORT' kill wt-off"      "killed wt-off"
says "kill reports a missing session"    "'$COHORT' kill wt-off"      "no session 'wt-off'"
"$COHORT" kill --all --yes >/dev/null 2>&1
says "ls is empty afterwards"            "'$COHORT' ls"               "no cohort sessions"

group "installer"
H=$TMP/home; mkdir -p "$H"
inst() { env HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" COHORT_CONFIG_DIR="$H/.cohort" \
             COHORT_BINDIR="$H/bin" SHELL=/bin/bash "$INSTALLER" "$@" 2>&1; }
says "installs the command"              "inst --no-tmux"             "command:  installed"
says "is idempotent"                     "inst --no-tmux"             "command:  unchanged"
[[ -f $H/.claude/CLAUDE.md ]] && ok "writes guidance" || bad "writes guidance"

# Which rc file that is depends on the platform: bash on macOS reads
# .bash_profile and never .bashrc, so the installer picks accordingly. The
# test cares that exactly one was wired, not which.
wired_rc() {
  local rc
  for rc in "$H/.bashrc" "$H/.bash_profile" "$H/.zshrc"; do
    if [[ -f $rc ]] && grep -q "BEGIN cohort" "$rc"; then printf '%s\n' "$rc"; return 0; fi
  done
  return 1
}
if RC=$(wired_rc); then ok "wires a shell with no rc file"; else bad "wires a shell with no rc file"; RC=$H/.bashrc; fi
says "sources the completion file"       "cat '$RC'"                  "completion."
cmp -s "$SRC/cohort.sh" "$H/bin/cohort" && ok "installed binary matches source" \
  || bad "installed binary matches source"

printf 'export MINE=1\n' >"$TMP/rc.user"; cat "$RC" >>"$TMP/rc.user"; mv "$TMP/rc.user" "$RC"
printf '# my rules\n' >"$TMP/claude.user"; cat "$H/.claude/CLAUDE.md" >>"$TMP/claude.user"
mv "$TMP/claude.user" "$H/.claude/CLAUDE.md"
says "uninstalls the command"            "inst --uninstall"           "command:  removed"
says "keeps the user's rc content"       "cat '$RC'"                  "export MINE=1"
lacks "and removes its own block"        "cat '$RC'"                  "BEGIN cohort"
says "keeps the user's CLAUDE.md"        "cat '$H/.claude/CLAUDE.md'" "# my rules"
lacks "and removes its own block"        "cat '$H/.claude/CLAUDE.md'" "BEGIN cohort"
[[ -e $H/bin/cohort ]] && bad "binary is gone" || ok "binary is gone"

printf '#!/usr/bin/env bash\necho mine\n' >"$H/bin/cohort" 2>/dev/null || mkdir -p "$H/bin"
printf '#!/usr/bin/env bash\necho mine\n' >"$H/bin/cohort"; chmod +x "$H/bin/cohort"
says "never deletes a cohort it did not write" "inst --uninstall"     "is not ours"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[[ $fail -eq 0 ]]
