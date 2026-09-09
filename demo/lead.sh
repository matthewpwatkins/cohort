#!/usr/bin/env bash
# The script the "lead" recording plays back: one session directing three
# others, with the person at the keyboard answering a worker in the lead and
# then dropping into a worker's own session to answer the next one.
#
# render.sh runs it under asciinema, and it expects the sandbox that render.sh
# sets up. Unlike the basics recording, almost all of this plays out inside a
# session rather than at the shell, so the pacing lives in demo/beats/ and the
# stub launcher plays it. What is real here is cohort: the lead really runs
# `cohort new` three times, the sessions in the picker are the sessions those
# calls created, and the worktrees behind them are real.
set -u

# shellcheck source=demo/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

demo_tmux_start

clear
sleep 1

# A lead stays on the checkout it was started from: it reads, delegates and
# sequences merges, and needs to see the branches its workers produce.
#
# `new` attaches, so this call does not return until the lead's script has
# played out and handed the terminal back.
run "cohort new lead -W" 1.5

# Everything the lead started, still running.
run "cohort ls" 4.5

demo_tmux_stop
