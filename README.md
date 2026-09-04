# claude-swarm

Run several Claude Code sessions in parallel under tmux, one lead coordinating
peer workers, with a one-liner to spawn them.

```
claude-session.sh           spawn a named, detached Claude session in tmux
guidance.md                 the CLAUDE.md block taught to every session
install-claude-session.sh   installs both; --uninstall reverses it
```

## Intent

Matthew acts as technical PM. He gives direction to a single `lead` session; the
lead decomposes the work, spawns workers, and owns what a worker cannot see —
merge ordering, deploy sequencing, dependencies between slices.

- **One Claude per tmux session**, spawned with `claude-session <name>`.
- **Peers, not subagents.** Sessions find each other with `ListAgents` and talk
  with `SendMessage`. A worker is a full session the PM can attach to, not a
  nested subagent hidden inside the lead.
- **Model split.** Lead runs Fable (holds the whole picture, does the planning);
  workers run Opus on one slice each.
- **The PM roams.** He hops into worker sessions to check progress and answer
  questions. Workers ask the lead first; when the lead lacks the context, the
  worker states the question plainly in its own session and keeps working on
  whatever isn't blocked by it.
- **Isolation by default.** One git worktree per worker. The lead may put a
  small, independent change directly on master at its discretion.
- **Git stays gated.** No commit, push, PR, or merge without explicit
  instruction. Workers hand off ready branches; the lead sequences what lands.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/matthewpwatkins/claude-swarm/main/install-claude-session.sh | bash
```

Or from a clone:

```bash
./install-claude-session.sh              # install or update
./install-claude-session.sh --uninstall  # remove both pieces
./install-claude-session.sh --bindir DIR
```

The installer reads `claude-session.sh` and `guidance.md` from alongside itself
when run out of a checkout, and downloads them otherwise — so the one-liner
needs no release artifact. Pin a version by pointing `CLAUDE_SWARM_REF` at a tag
(`CLAUDE_SWARM_REF=v1.0.0`, default `main`); `CLAUDE_SWARM_REPO` retargets a
fork. Cutting GitHub releases is optional on top of that: a tag already gives
atomic pinning of the pair, and a release tarball would need unpacking before
the installer could run, which costs the one-liner.

Installs `claude-session.sh` as `claude-session` in `~/bin` (already on PATH
for interactive, login, and Claude's non-interactive Bash tool alike — no sudo,
no rc-file edits), and appends the `guidance.md` block between HTML-comment
markers in `${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md`.

Idempotency comes from comparing content, not checking existence: each run
strips the old marker block and re-appends the current one, so re-running after
a hand-edit restores the canonical text instead of duplicating it. Uninstall
leaves the rest of CLAUDE.md byte-identical, deleting the file only when the
block was all it contained.

## Design notes

- **Everything after `<name>` passes through to `claude` verbatim**, so any flag
  Claude supports works. Opus is the default only when no model flag is present.
- **Permission mode must match across sessions.** A session whose permission
  mode class differs from the sender's *holds* inbound peer messages behind a
  human approval prompt in its own pane, which defeats the point of a lead
  driving workers. `claude-session` passes `--permission-mode
  $CLAUDE_SESSION_MODE` when the caller doesn't set one; export that in the
  lead's shell. The alternative is `"crossSessionInbound": "accept"` in
  settings, which accepts messages from any local session regardless of mode —
  a real loosening, so it's opt-in and not something the installer does.
- **The command is handed to `tmux new-session` as argv**, not typed in with
  `send-keys`, which removes both quoting fragility and the race where a fresh
  session isn't ready for input.
- **`-d` means it never attaches**, so spawning a worker doesn't yank the PM out
  of his pane. Run outside tmux, it attaches for you.
- **`$PWD` is inherited**, so `cd` into a worktree before spawning its worker.
- **`args` is seeded, never empty.** Stock macOS bash is 3.2, where expanding an
  empty array under `set -u` is an unbound-variable error.
- The tmux session dies when Claude exits. To keep the pane for scrollback, wrap
  the argv in a shell that execs after.

## Verified

Tested on Linux (tmux 3.4, bash 5.2). Installer: fresh install, re-run,
install onto an existing CLAUDE.md, re-run after a hand-edit, uninstall with and
without other content, uninstall twice, `CLAUDE_CONFIG_DIR` override, and a
piped run that downloads its payloads and ignores same-named files in the cwd —
all as described above. Uninstall additionally: sweeps `~/bin`, `~/.local/bin`
and `--bindir` without double-reporting an overlap, leaves a CLAUDE.md that
never held the block untouched, restores surrounding content byte-for-byte, and
skips a `claude-session` it did not install rather than deleting someone's own
script of that name.

`claude-session`: default model, flag pass-through, permission-mode inheritance
and override, missing args, duplicate session name.

End to end with real sessions: a spawned worker inherits the cwd, defaults to
Opus, appears in the lead's `ListAgents` under its session name, and
round-trips `SendMessage` — immediately when permission modes match, and only
after a manual approval in its pane when they don't.

Untested: macOS, and the paradigm itself under real multi-worker load.
