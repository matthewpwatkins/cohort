#!/usr/bin/env bash
# The script the "basics" recording plays back. render.sh runs it under
# asciinema; it expects the sandbox repo, the isolated tmux server and the stub
# launcher that render.sh sets up, so running it by hand will spawn sessions you
# did not want.
#
# Commands are typed out a character at a time and then really run, so every
# line of output in the recording is cohort's own output against a real tmux
# server and real git worktrees. Only the typing is simulated, and only what is
# inside the sessions is faked (see stub-claude).
set -u

# shellcheck source=demo/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

state=$(mktemp -d)
dwell=$state/dwell
running=$state/running
printf '3\n' > "$dwell"
touch "$running"

# `cohort new` attaches when it has a terminal, and so does `cohort attach`, so
# the recording spends much of its time inside a session with nobody at the
# keyboard to leave it. This watcher plays that part: it waits for a client to
# appear, holds it there long enough to read, then detaches it.
#
# It runs outside tmux rather than as a client-attached hook because a hook's
# command is expanded in a context that does not carry the attaching client,
# leaving it with no way to name what to detach.
watch_and_detach() {
  local clients tty
  while [[ -f $running ]]; do
    clients=$(tmux list-clients -F '#{client_tty}' 2>/dev/null)
    if [[ -n $clients ]]; then
      sleep "$(cat "$dwell")"
      while read -r tty; do
        [[ -n $tty ]] && tmux detach-client -t "$tty" 2>/dev/null
      done <<<"$clients"
    fi
    sleep 0.3
  done
}

# How long the next attached session stays on screen.
hold() { printf '%s\n' "$1" > "$dwell"; }

demo_tmux_start
watch_and_detach &
watcher=$!

clear
sleep 1

# Two workers. Each lands on its own branch in its own worktree, so they can
# edit the same repo at the same time without treading on each other. `new`
# drops you straight into the session it starts; the watcher backs out again.
hold 3.5
run "cohort new auth-refactor" 1.5
hold 2.5
run "cohort new search-index" 2

# What is running, and where.
run "cohort ls" 4

# Going back to a session you left.
hold 4
run "cohort attach auth-refactor" 2

# Retiring one ends that Claude conversation, so it is named rather than
# swept up with --all.
run "cohort kill search-index" 2.5
run "cohort ls" 3.5

rm -f "$running"
wait "$watcher" 2>/dev/null || true
rm -rf "$state"
demo_tmux_stop
