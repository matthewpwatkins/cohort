#!/usr/bin/env bash
# Render the README's animations.
#
#   ./demo/render.sh            both
#   ./demo/render.sh basics     demo/basics.gif — starting, listing, attaching
#   ./demo/render.sh lead       demo/lead.gif   — a lead directing three workers
#
# Each build gets a throwaway repo of its own and points cohort at
# demo/stub-claude instead of the real claude, so the GIFs carry none of what a
# real session prints at startup and none of the waiting a real one involves.
#
# Needs asciinema and agg on PATH:
#   https://docs.asciinema.org/getting-started/
#   https://docs.asciinema.org/manual/agg/installation/
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
sandbox=${COHORT_DEMO_DIR:-/tmp/cohort-demo}

for tool in asciinema agg tmux git; do
  command -v "$tool" >/dev/null || { echo "render: $tool not found on PATH" >&2; exit 1; }
done

# The recording gets a tmux server of its own, so it can never touch whatever
# sessions the person rendering it is sitting in. Two things decide that, and
# both are required:
#
#   TMUX_TMPDIR picks the socket directory, and so the server. Keep the path
#   short: a unix socket path has a hard length limit, and tmux fails with
#   "File name too long" well before anything else complains.
#
#   TMUX must be unset. Inside a tmux pane it holds the current server's socket,
#   which tmux follows in preference to TMUX_TMPDIR — leaving it set points the
#   recording's tmux calls straight back at the caller's live sessions. It also
#   makes cohort attach switch the caller's client instead of attaching inside
#   the recording.
#
# Nothing here ever runs `tmux kill-server`, for the same reason: it would
# follow $TMUX and take the caller's own sessions down with it.
export TMUX_TMPDIR="$sandbox/tmux"
unset TMUX TMUX_PANE

export COHORT_CONFIG_DIR="$sandbox/config"
export COHORT_COMMAND="$here/stub-claude"
export DEMO_BEATS_DIR="$here/beats"
export PATH="$sandbox/bin:$PATH"

# Retire whatever a previous render left behind. By name, never by server.
sweep_sessions() {
  local session
  while read -r session; do
    [[ $session == cohort-* || $session == demo-* ]] \
      && tmux kill-session -t "=$session" 2>/dev/null || true
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
}

# A fresh repo for every recording, so branch names, ages and the session list
# never carry over from the last one. The sandbox holds the tmux socket too, so
# the sessions have to go before the directory does — a server that outlives its
# own socket lingers with nothing able to reach it.
build_sandbox() {
  [[ -d $TMUX_TMPDIR ]] && sweep_sessions
  rm -rf "$sandbox"
  mkdir -p "$sandbox/acme-api" "$TMUX_TMPDIR" "$sandbox/bin"
  ln -sf "$repo/cohort.sh" "$sandbox/bin/cohort"
  (
    cd "$sandbox/acme-api"
    git init -q -b main .
    git config user.name  "Demo"
    git config user.email "demo@example.com"
    mkdir -p src
    printf 'export const version = "1.0.0"\n' > src/index.ts
    git add -A
    git commit -qm "initial commit"
  )
}

# $1 driver script, $2 output gif, $3 terminal size, $4 font size, $5 seconds
# before giving up
record() {
  local driver=$1 gif=$2 size=$3 font=$4 limit=$5
  local cast=$sandbox/${driver%.sh}.cast

  build_sandbox

  # The recorded command is kept to a bare `bash <script>`: asciinema hands it
  # to /bin/sh, which chokes on anything that quotes badly, and under WSL a PATH
  # carrying Windows directories has parentheses in it. Everything exported
  # above is inherited, so none of it needs restating here.
  #
  # The timeout is a backstop. A session that never hands the terminal back
  # would otherwise hang the render with nothing on screen to explain itself.
  cd "$sandbox/acme-api"
  timeout "$limit" asciinema rec "$cast" \
    --window-size "$size" \
    --command "bash $here/$driver" \
    --overwrite --quiet

  # Idle gaps are capped rather than cut: the pauses are what make the output
  # readable, but nobody should have to wait out a slow git call.
  agg "$cast" "$here/$gif" \
    --theme asciinema \
    --font-size "$font" \
    --idle-time-limit 2

  sweep_sessions
  echo "render: wrote $here/$gif"
}

case ${1:-all} in
  basics) record basics.sh basics.gif 112x18 18 180 ;;
  lead)   record lead.sh   lead.gif   118x30 15 420 ;;
  all)    record basics.sh basics.gif 112x18 18 180
          record lead.sh   lead.gif   118x30 15 420 ;;
  *) echo "render: unknown recording '$1' (basics, lead, or all)" >&2; exit 2 ;;
esac
