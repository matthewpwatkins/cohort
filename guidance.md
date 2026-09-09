## Multi-session work with cohort

`cohort` runs peer Claude sessions, one per tmux session. Each is a full session
rather than a subagent: it outlives whoever spawned it — a session, or you — and
can spawn peers of its own. Reach for it when work splits into slices that run
at the same time, or when a long job should keep going while other work does.

- **Spawning.** `cohort new <name> [claude args...]` — a detached tmux session
  `cohort-<name>` spawned from the cwd, args passed through to claude. Name it
  after the work (`auth-refactor`, not `worker-2`); `attach` and `kill` take
  that bare name back.
- **Managing.** `cohort ls` lists live sessions, `cohort attach <name>` moves
  between them, `cohort kill <name>` (or `--all`) retires one. Killing ends that
  Claude conversation, so hand the branch off first.
- **Comms.** `ListAgents` for who is live, `SendMessage` to talk; the listed name
  is the address. The first message to a new session gives it scope, its
  worktree/branch, and what it depends on.
- **Isolation.** By default `cohort new` creates the session's worktree itself,
  so never hand-roll one or `cd` into it first; it lands on its own branch under
  `<repo>/.claude/worktrees/<name>`, and `cohort ls` reports where each session
  really is. Pass `--no-worktree` (`-W`) to keep a session on the current
  checkout, which is usually right for a lead: it reads, delegates and sequences
  merges, and needs to see the branches its workers produce. A worktree branches
  from the tracked remote branch, so push anything the session must build on
  before spawning it; cohort warns when local HEAD is ahead.
- **Settings.** Launcher, model, permission mode and whether new sessions get a
  worktree all come from `~/.cohort/settings.json`; `cohort config` shows what is
  in effect, and a flag deviates from it for one session. A spawned session needs
  its spawner's permission mode, or messages to it stall on an approval prompt in
  its own pane — invisible until you attach, and indistinguishable from a hang.
  Only the file guarantees that: COHORT_* variables do not survive a spawn.
- **Git.** In any session: no commit, push, PR or merge without explicit
  instruction.

### Lead workflow

One shape; the human may equally direct a set of sessions themselves. Where
there is a `lead`:

- The human is technical PM and directs the lead, which decomposes the work and
  holds scope, ordering, cross-worker dependencies and merge sequencing; workers
  own one slice each.
- The lead spawns the workers, so that one session tracks who is on what. A
  worker that spawns a helper of its own says so.
- Workers report status and blockers to the lead, and anything cross-worker
  routes through it.
- Ask the lead first. If the answer needs the PM, state the question plainly in
  your own session and carry on with whatever it does not block. The PM hops
  between sessions and will see it. Never idle-wait.
- Workers leave the branch ready and notify the lead; the lead sequences merges
  and deploys and clears them with the PM.
- The lead says when it is putting a worker on `--no-worktree` rather than its
  own worktree.
