## Multi-session work

Work is split across peer Claude sessions, one per tmux session. You act as
technical PM and give direction to the `lead`; the lead decomposes it and
delegates to workers.

- **Roles.** `lead` (Fable) holds the full picture: scope, ordering, cross-worker
  dependencies, merge and deploy sequencing. Workers (Opus) each own one slice
  and report to the lead.
- **Spawning.** Only the lead spawns peers: `cohort new <name> [claude args...]`
  — detached tmux session named `cohort-<name>`, inherits the cwd, so `cd` into
  the worktree first. Name sessions after the work (`auth-refactor`, not
  `worker-2`); `cohort attach`, `ls` and `kill` all take the bare name. The
  first `SendMessage` to a new worker states its scope, its worktree/branch,
  and what it depends on.
- **Launcher settings.** Model, permission mode and launcher come from
  `~/.cohort/settings.json`; `cohort config` shows what is in effect. Pass a
  flag to `cohort new` only to deviate from it for one session. Workers must run
  in the same permission mode as their lead, otherwise every message to them
  waits on a human approval prompt in their pane — the settings file is what
  keeps that consistent, since COHORT_* environment variables do not survive
  into a spawned session.
- **Managing.** `cohort ls` shows the live sessions with their branches,
  `cohort attach <name>` moves between them, `cohort kill <name>` retires one
  whose work has landed. Killing a session ends the Claude conversation in it,
  so confirm the branch is handed off first.
- **Comms.** `ListAgents` to see who is live, `SendMessage` to talk; the name in
  the listing is the address. Workers report status and blockers to the lead;
  cross-worker coordination routes through the lead.
- **Questions.** Ask the lead first. If the answer needs the PM, the lead says
  so and the worker states the question plainly in its own session, then
  continues on anything not blocked by it — the PM hops between sessions and
  will see it. Do not idle-wait on a non-blocking question.
- **Isolation.** Default to one git worktree per worker. The lead may run a
  small, self-contained change directly on master at its discretion, and states
  which when delegating.
- **Git.** Standing rule holds: no commit, push, PR, or merge without explicit
  instruction. Workers leave the branch ready and notify the lead; the lead
  sequences merges and deploys and clears them with the PM first.
