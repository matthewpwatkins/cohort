#!/usr/bin/env bash
#
# claude-session <name> [claude args...]
#
# Starts a detached tmux session named <name> running Claude Code. Extra args
# pass through to claude verbatim; defaults to Opus when no model is given.
# Safe to run from inside tmux. Inherits $PWD, so cd into a worktree first.
#
# Installed by install-claude-session.sh — local edits will be overwritten.

set -euo pipefail

usage() { echo "usage: claude-session <name> [claude args...]" >&2; exit 2; }

[[ $# -ge 1 && $1 != -* ]] || usage
name=$1; shift

command -v tmux >/dev/null || { echo "claude-session: tmux not found" >&2; exit 1; }
command -v claude >/dev/null || { echo "claude-session: claude not found" >&2; exit 1; }

if tmux has-session -t "=$name" 2>/dev/null; then
  echo "claude-session: '$name' already exists" >&2
  exit 1
fi

# Seed the array so it is never empty: bash 3.2 (stock macOS) errors on
# expanding an empty array under `set -u`.
args=(claude -n "$name")

model_set=0
for a in "$@"; do
  case $a in -m|--model|--model=*) model_set=1 ;; esac
done
[[ $model_set -eq 1 ]] || args+=(--model claude-opus-5)

# Match the spawner's permission mode unless the caller set one: a receiving
# session whose mode class differs holds inbound peer messages for human
# approval instead of delivering them.
mode_set=0
for a in "$@"; do
  case $a in --permission-mode|--permission-mode=*) mode_set=1 ;; esac
done
if [[ $mode_set -eq 0 && -n ${CLAUDE_SESSION_MODE:-} ]]; then
  args+=(--permission-mode "$CLAUDE_SESSION_MODE")
fi

args+=("$@")

tmux new-session -d -s "$name" -c "$PWD" "${args[@]}"

if [[ -n ${TMUX:-} ]]; then
  echo "$name started (tmux switch-client -t $name)"
else
  tmux attach -t "=$name"
fi
