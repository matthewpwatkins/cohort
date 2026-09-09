# shellcheck shell=bash
# Shared by the recording drivers. Sourced, not run.

PROMPT=$'\033[38;5;114macme-api\033[0m \033[38;5;245m$\033[0m '
CHAR_DELAY=${CHAR_DELAY:-0.04}
HOLDER=demo-holder

# Type a command the way a person would, then leave it on screen for a beat
# before it runs, so the eye can finish reading it.
type_line() {
  local line=$1 i
  printf '%s' "$PROMPT"
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}"
    sleep "$CHAR_DELAY"
  done
  printf '\n'
  sleep 0.4
}

run() {
  type_line "$1"
  eval "$1"
  sleep "${2:-2}"
}

# tmux's stock status-right carries the machine's hostname, which has no place
# in a GIF that gets published. These are global options, so the sessions cohort
# starts later inherit them — but only if a server is already up to hold them,
# and `tmux start-server` does not keep one alive with no sessions in it. Hence
# a holding session, which also carries the environment those later sessions
# need: a pane gets the server's environment, not the caller's, which is the
# same reason cohort tells you to configure it through settings.json rather than
# through exported variables.
demo_tmux_start() {
  tmux new-session -d -s "$HOLDER" 'sleep 900'
  tmux set -g status-left  ' #S ' \;  \
       set -g status-left-length 40 \;  \
       set -g status-right ''      \;  \
       set -g status-style 'bg=colour236,fg=colour145' \;  \
       set -g status-left-style 'bg=colour114,fg=colour235,bold'
  tmux set-environment -g PATH "$PATH"
  [[ -n ${DEMO_BEATS_DIR:-} ]] && tmux set-environment -g DEMO_BEATS_DIR "$DEMO_BEATS_DIR"
  return 0
}

demo_tmux_stop() {
  tmux kill-session -t "=$HOLDER" 2>/dev/null || true
}
