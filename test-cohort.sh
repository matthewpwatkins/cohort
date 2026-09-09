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
says "completion rejects other shells"   "'$COHORT' completion nope"  "try bash, zsh or fish"

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
says "fish completion uses complete -c"  "'$COHORT' completion fish"  "complete -c cohort"
says "completion offers session names"   "'$COHORT' completion bash"  "cohort ls --names"
says "fish completion offers them too"   "'$COHORT' completion fish"  "__cohort_names"

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

if spawn exit-status --no-worktree; then ok "new exits 0 with no terminal to attach to"
else bad "new exits 0 with no terminal to attach to"; fi

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
inst() { env HOME="$H" XDG_CONFIG_HOME="$H/.config" CLAUDE_CONFIG_DIR="$H/.claude" \
             COHORT_CONFIG_DIR="$H/.cohort" COHORT_BINDIR="$H/bin" SHELL=/bin/bash \
             "$INSTALLER" "$@" 2>&1; }
says "installs the command"              "inst --no-tmux"             "installed"
says "is idempotent"                     "inst --no-tmux"             "unchanged"
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
says "uninstalls the command"            "inst --uninstall"           "removed"
says "keeps the user's rc content"       "cat '$RC'"                  "export MINE=1"
lacks "and removes its own block"        "cat '$RC'"                  "BEGIN cohort"
says "keeps the user's CLAUDE.md"        "cat '$H/.claude/CLAUDE.md'" "# my rules"
lacks "and removes its own block"        "cat '$H/.claude/CLAUDE.md'" "BEGIN cohort"
[[ -e $H/bin/cohort ]] && bad "binary is gone" || ok "binary is gone"

group "which shell the installer wires"
# $2 is the login shell; any further arguments are dotfiles that already exist.
wire_case() {
  local label=$1 login=$2; shift 2
  local h=$TMP/wire-$label f
  rm -rf "$h"; mkdir -p "$h"
  for f in "$@"; do mkdir -p "$h/$(dirname "$f")"; printf '# existing\n' >"$h/$f"; done
  env HOME="$h" SHELL="$login" XDG_CONFIG_HOME="$h/.config" CLAUDE_CONFIG_DIR="$h/.claude" \
      COHORT_CONFIG_DIR="$h/.cohort" COHORT_BINDIR="$h/bin" "$INSTALLER" --no-tmux 2>&1 \
    | sed -n '/^Shell completion/,/^$/p' 
}
says "a fish user gets an autoloaded file" \
  "wire_case fish /usr/bin/fish .config/fish/config.fish" ".config/fish/completions/cohort.fish"
lacks "and no rc file it will never read" \
  "wire_case fish2 /usr/bin/fish .config/fish/config.fish" ".bashrc"
says "a fish login shell counts with no dotfiles" \
  "wire_case fish3 /usr/bin/fish" "cohort.fish"
says "a zsh user gets .zshrc" "wire_case zsh /bin/zsh .zshrc" ".zshrc"
says "both shells present means both wired" \
  "wire_case mixed /bin/bash .bashrc .config/fish/config.fish" ".bashrc"
says "an exotic login shell is refused, not guessed at" \
  "wire_case exotic /usr/bin/nu" "is not supported"
lacks "and nothing is written for it" "wire_case exotic2 /usr/bin/nu" "added"

group "tmux is a hard dependency"
# A PATH with everything the installer needs except tmux, so the dependency
# check is the thing that fails rather than some coreutil.
NOTMUX=$TMP/notmux-bin
mkdir -p "$NOTMUX"
# type -P, not command -v: the latter reports a shell function or alias by
# name, which would link each tool to itself and break the fixture subtly.
for t in bash sh dirname basename mktemp cp chmod cat grep awk sed id uname rm mkdir cmp tr cut curl; do
  t_path=$(type -P "$t" 2>/dev/null) && [[ $t_path == /* ]] && ln -sf "$t_path" "$NOTMUX/$t"
done
# Present so a package manager is found, but it never actually produces tmux.
printf '#!/bin/sh\nexit 0\n' >"$NOTMUX/apt-get"; chmod +x "$NOTMUX/apt-get"
# Without this the run stops at "need root" before ever reaching the question.
printf '#!/bin/sh\nexec "$@"\n' >"$NOTMUX/sudo"; chmod +x "$NOTMUX/sudo"

# shellcheck disable=SC2120  # callers pass installer flags; no args is valid
notmux_case() {
  local h=$TMP/notmux-home
  rm -rf "$h"; mkdir -p "$h"; printf '# rc\n' >"$h/.bashrc"
  env HOME="$h" SHELL=/bin/bash XDG_CONFIG_HOME="$h/.config" CLAUDE_CONFIG_DIR="$h/.claude" \
      COHORT_CONFIG_DIR="$h/.cohort" COHORT_BINDIR="$h/bin" PATH="$NOTMUX" \
      "$NOTMUX/bash" "$INSTALLER" "$@" 2>&1
}
says "tmux is checked before anything is written" "notmux_case" "nothing was installed"
says "and it is clear it could not ask"           "notmux_case" "no terminal to ask on"
notmux_case >/dev/null 2>&1
[[ -e $TMP/notmux-home/bin/cohort ]] && bad "the command is not left behind" \
  || ok "the command is not left behind"
[[ -e $TMP/notmux-home/.claude/CLAUDE.md ]] && bad "guidance is not left behind" \
  || ok "guidance is not left behind"
lacks "and the rc file is untouched" "cat '$TMP/notmux-home/.bashrc'" "BEGIN cohort"
says "a tmux install that does not work stops the run" "notmux_case --yes" "nothing was installed"
says "--no-tmux installs without it"                   "notmux_case --no-tmux" "installed"

group "Claude Code is checked but not required"
# tmux present, claude absent. The real installer is never run: with no
# terminal to answer on it can only skip, which is the point being tested.
NOCLAUDE=$TMP/noclaude-bin
mkdir -p "$NOCLAUDE"
for t in bash sh dirname basename mktemp cp chmod cat grep awk sed id uname rm mkdir cmp tr cut curl tmux; do
  t_path=$(type -P "$t" 2>/dev/null) && [[ $t_path == /* ]] && ln -sf "$t_path" "$NOCLAUDE/$t"
done

# shellcheck disable=SC2120  # callers pass installer flags; no args is valid
noclaude_case() {
  local h=$TMP/noclaude-home
  rm -rf "$h"; mkdir -p "$h/.local/bin"; printf '# rc\n' >"$h/.bashrc"
  env HOME="$h" SHELL=/bin/bash XDG_CONFIG_HOME="$h/.config" CLAUDE_CONFIG_DIR="$h/.claude" \
      COHORT_CONFIG_DIR="$h/.cohort" PATH="$NOCLAUDE:$h/.local/bin" \
      "$NOCLAUDE/bash" "$INSTALLER" "$@" 2>&1
}
says "a missing claude is reported"    "noclaude_case" "cohort runs Claude Code sessions"
says "and it says it could not ask"    "noclaude_case" "no terminal to ask on"
says "but cohort installs regardless"  "noclaude_case" "installed"
says "and the summary says why nothing will start" \
  "noclaude_case" "Claude Code is not installed, so no session will start yet"
says "with the command to fix it"      "noclaude_case" "https://claude.ai/install.sh"
noclaude_case >/dev/null 2>&1
[[ -x $TMP/noclaude-home/.local/bin/cohort ]] && ok "the command is on disk" \
  || bad "the command is on disk"
lacks "--no-claude skips the check"    "noclaude_case --no-claude" "runs Claude Code sessions"
says "and the flag is documented"      "'$INSTALLER' --help" "--no-claude"

group "PATH and readiness"
path_case() {
  local label=$1 path=$2
  local h=$TMP/path-$label
  rm -rf "$h"; mkdir -p "$h/.local/bin" "$h/bin"; printf '# rc\n' >"$h/.bashrc"
  env HOME="$h" SHELL=/bin/bash XDG_CONFIG_HOME="$h/.config" CLAUDE_CONFIG_DIR="$h/.claude" \
      COHORT_CONFIG_DIR="$h/.cohort" PATH="$path:$PATH" "$INSTALLER" --no-tmux 2>&1
}
says "a bindir already on PATH is preferred" \
  "path_case onpath '$TMP/path-onpath/.local/bin'" "/.local/bin/cohort"
says "and it says you are ready now" \
  "path_case onpath2 '$TMP/path-onpath2/.local/bin'" "cohort is on your PATH in this shell"
says "otherwise PATH is fixed, not just complained about" \
  "path_case offpath /nonexistent-dir" "was not on your PATH, so it was added"
says "and it tells you how to finish" \
  "path_case offpath2 /nonexistent-dir" "source"
says "the rc block carries the PATH line" \
  "cat '$TMP/path-offpath/.bashrc'" 'export PATH='

# Re-running after the preferred directory changed must not leave two copies
# on PATH shadowing each other.
upgrade_case() {
  local h=$TMP/upgrade
  rm -rf "$h"; mkdir -p "$h/.local/bin" "$h/bin"; printf '# rc\n' >"$h/.bashrc"
  env HOME="$h" SHELL=/bin/bash XDG_CONFIG_HOME="$h/.config" CLAUDE_CONFIG_DIR="$h/.claude" \
      COHORT_CONFIG_DIR="$h/.cohort" COHORT_BINDIR="$h/bin" "$INSTALLER" --no-tmux >/dev/null 2>&1
  # Now with only .local/bin on PATH, which is the one it would otherwise pick.
  env HOME="$h" SHELL=/bin/bash XDG_CONFIG_HOME="$h/.config" CLAUDE_CONFIG_DIR="$h/.claude" \
      COHORT_CONFIG_DIR="$h/.cohort" PATH="$h/.local/bin:$PATH" "$INSTALLER" --no-tmux 2>&1
}
says "an existing install is upgraded in place" "upgrade_case" "/bin/cohort"
[[ -f $TMP/upgrade/bin/cohort && ! -f $TMP/upgrade/.local/bin/cohort ]] \
  && ok "and no second copy appears" || bad "and no second copy appears"

group "installer leaves other people's files alone"
printf '#!/usr/bin/env bash\necho mine\n' >"$H/bin/cohort" 2>/dev/null || mkdir -p "$H/bin"
printf '#!/usr/bin/env bash\necho mine\n' >"$H/bin/cohort"; chmod +x "$H/bin/cohort"
says "never deletes a cohort it did not write" "inst --uninstall"     "is not ours"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[[ $fail -eq 0 ]]
