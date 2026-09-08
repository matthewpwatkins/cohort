# cohort

Run several Claude Code sessions in parallel under tmux, one lead coordinating
peer workers, with a small command to spawn and manage them.

```
cohort.sh           the command source; installs as `cohort`
guidance.md         the CLAUDE.md block taught to every session
install-cohort.sh   installs both; --uninstall reverses it
```

## Intent

You give direction to a single `lead` session; the lead decomposes the work,
spawns workers, and owns what a worker cannot see — merge ordering,
deploy sequencing, dependencies between slices.

This is different from Claude's native Agent Teams feature because these workers
are long-lived and independent of the agent that spawned them. You can interact
directly with them, or through the lead agent, putting you in the role of technical
PM instead of manager.

- **One Claude per tmux session**, spawned with `cohort new <name>` and living
  under the `cohort-` prefix, clear of the tmux sessions you run yourself.
- **Peers, not subagents.** Sessions find each other with `ListAgents` and talk
  with `SendMessage`. A worker is a full session you can attach to, not a
  nested subagent hidden inside the lead.
- **Model split.** Lead runs Fable (holds the whole picture, does the planning);
  workers run Opus on one slice each.
- **The PM roams.** You hop into worker sessions to check progress and answer
  questions. Workers ask the lead first; when the lead lacks the context, the
  worker states the question plainly in its own session and keeps working on
  whatever isn't blocked by it.
- **Isolation by default.** One git worktree per worker. The lead may put a
  small, independent change directly on master at its discretion.
- **Git stays gated.** No commit, push, PR, or merge without explicit
  instruction. Workers hand off ready branches; the lead sequences what lands.

The rules the sessions themselves are taught live in `guidance.md`, which the
installer writes into your CLAUDE.md. That file is the behavioural contract;
this section is the summary.

## Example usage

```console
$ cd ~/worktrees/auth-refactor
$ cohort new auth-refactor
auth-refactor started as tmux session cohort-auth-refactor (cohort attach auth-refactor)

$ cohort ls
NAME                 BRANCH                 AGE      ATTACHED  DIR
auth-refactor        feat/auth              4m       no        /home/you/worktrees/auth-refactor
search-index         feat/search            2h14m    yes       /home/you/worktrees/search-index

$ cohort attach search-index      # same as: tmux attach -t cohort-search-index

$ cohort kill auth-refactor
killed auth-refactor
```

Subcommands take the bare name; the `cohort-` prefix is added for you, and
passing the prefixed name works too.

## Usage

```
cohort new [--command CMD] <name> [claude args...]
                                    spawn a detached session named cohort-<name>
cohort ls                           list sessions this tool created
cohort attach <name>                switch to a session (attach when outside tmux)
cohort kill <name>                  kill one session
cohort kill --all [--yes]           kill every session this tool created
cohort config                       show resolved settings and their sources
cohort help [command]               longer help for a command
```

Sessions are tmux sessions named `cohort-<name>`; subcommands take `<name>`.

## Settings

Model, permission mode and the launcher itself come from
`~/.cohort/settings.json`. Every key is optional; `COHORT_CONFIG_DIR` relocates
the directory.

```json
{
  "command": ["env", "CLAUDE_CONFIG_DIR=/home/you/.claude-work", "claude"],
  "model": "claude-opus-5",
  "permissionMode": "bypassPermissions",
  "args": ["--verbose"]
}
```

| Key | Effect |
|---|---|
| `command` | Launcher to run. A string is split on whitespace; an array is used as exact argv. |
| `model` | Model flag for new sessions. |
| `permissionMode` | `--permission-mode` for new sessions. |
| `args` | Extra arguments added to every session, ahead of yours. |

Each resolves highest-first, and `cohort config` prints which source won:

```
flag on `cohort new`  >  $COHORT_*  >  settings.json  >  built-in default
```

**The launcher must be an executable**, because the session is started as argv
rather than through a shell — a shell alias or function is invisible to it.
Wrap one with `env`, which is what the array form above does: it is the argv
equivalent of a `ccw() { CLAUDE_CONFIG_DIR=... claude "$@"; }` function.

**Prefer the file over the environment variables for anything durable.** A
detached tmux session inherits the tmux server's environment, not your shell's,
so `COHORT_MODE` and its siblings do not survive into a spawned session — a
lead cannot pass them on to the workers it spawns, and will fall back to
defaults or have to reason out the right flags by hand. The settings file is
read fresh on every invocation, at every hop.

An unrecognised key is reported and ignored, so a typo is visible rather than
silently inert. A malformed file is fatal rather than ignored, since falling
back to defaults would spawn sessions you believe you had configured. Reading
it needs `jq`, or `python3` as a fallback; with neither, only a settings file
that exists is an error.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/matthewpwatkins/cohort/main/install-cohort.sh | bash
```

Or from a clone:

```bash
./install-cohort.sh              # install or update
./install-cohort.sh --uninstall  # remove both pieces
./install-cohort.sh --bindir DIR
```

The installer reads `cohort.sh` and `guidance.md` from alongside itself when run
out of a checkout, and downloads them otherwise — so the one-liner needs no
release artifact. Pin a version by pointing `COHORT_REF` at a tag
(`COHORT_REF=v1.0.0`, default `main`); `COHORT_REPO` retargets a fork. Cutting
GitHub releases is optional on top of that: a tag already gives atomic pinning
of the pair, and a release tarball would need unpacking before the installer
could run, which costs the one-liner.

Installs `cohort.sh` as `cohort` in `~/bin` (already on PATH for interactive,
login, and Claude's non-interactive Bash tool alike — no sudo, no rc-file
edits), and appends the `guidance.md` block between HTML-comment markers in
`${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md`.

Idempotency comes from comparing content, not checking existence: each run
strips the old marker block and re-appends the current one, so re-running after
a hand-edit restores the canonical text instead of duplicating it. Uninstall
leaves the rest of CLAUDE.md byte-identical, deleting the file only when the
block was all it contained.

| Variable | Default | Effect |
|---|---|---|
| `COHORT_MODE` | unset | `--permission-mode` handed to new sessions |
| `COHORT_MODEL` | `claude-opus-5` | Model handed to new sessions |
| `COHORT_COMMAND` | `claude` | Launcher for new sessions |
| `COHORT_CONFIG_DIR` | `~/.cohort` | Where `settings.json` lives |
| `COHORT_BINDIR` | `~/bin` | Install location (same as `--bindir`) |
| `COHORT_REPO` | `matthewpwatkins/cohort` | Source repo when running off a pipe |
| `COHORT_REF` | `main` | Tag or branch to install from |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Which CLAUDE.md gets the guidance block |

## Design notes

- **Sessions live under a `cohort-` prefix.** The tmux session for worker
  `auth` is `cohort-auth`, so a worker never collides with a tmux session you
  started by hand, and `tmux ls` shows at a glance which sessions belong to a
  cohort. Every subcommand takes the short name and adds the prefix, so
  `cohort attach auth` is `tmux attach -t cohort-auth`; `ls` strips it back off
  for display, and a prefixed name given on the command line is accepted as-is
  rather than doubled.
- **Sessions are tagged, not name-matched.** `new` sets a tmux user option
  (`@cohort`) on the session it creates, and `ls`, `attach` and `kill` filter on
  that tag. Your other tmux sessions are invisible to this tool, so `kill`
  cannot take one out even inside the prefix — the same guarantee the installer
  gives `~/bin` by checking for its own sentinel before deleting anything.
- **The tag is set via the session id returned by `new-session -P`.** Retargeting
  by name would be both prefix-matchable and inconsistent: `set-option -t =name`
  errors on the exact-match prefix that `has-session` accepts, and
  `display-message -t =name` silently returns empty rather than failing, which
  would make every session read as untagged.
- **`kill` is deliberately awkward.** It refuses untagged sessions outright
  rather than warning, there is no bare `kill` meaning "all", and `--all`
  prompts when interactive and demands `--yes` when not. Killing a worker ends
  its Claude conversation and abandons whatever is uncommitted in its worktree.
- **Everything after `<name>` passes through to `claude` verbatim**, so any flag
  Claude supports works. Opus is the default only when no model flag is present.
- **Permission mode must match across sessions.** A session whose permission
  mode class differs from the sender's *holds* inbound peer messages behind a
  human approval prompt in its own pane, which defeats the point of a lead
  driving workers. `cohort new` passes `--permission-mode $COHORT_MODE` when the
  caller doesn't set one; export that in the lead's shell. The alternative is
  `"crossSessionInbound": "accept"` in settings, which accepts messages from any
  local session regardless of mode — a real loosening, so it's opt-in and not
  something the installer does.
- **The command is handed to `tmux new-session` as argv**, not typed in with
  `send-keys`, which removes both quoting fragility and the race where a fresh
  session isn't ready for input.
- **`-d` means it never attaches**, so spawning a worker doesn't yank you out
  of your pane. Run outside tmux, it attaches for you.
- **`$PWD` is inherited**, so `cd` into a worktree before spawning its worker.
- **`args` is seeded, never empty.** Stock macOS bash is 3.2, where expanding an
  empty array under `set -u` is an unbound-variable error. `mapfile` is avoided
  for the same reason.
- The tmux session dies when Claude exits. To keep the pane for scrollback, wrap
  the argv in a shell that execs after.

## Verified

Tested on Linux (tmux 3.4, bash 5.2), against both a stub launcher and real
Claude sessions, with unrelated tmux sessions live alongside throughout.

**Sessions.** Default model, explicit model override, `COHORT_MODE` forwarding,
duplicate session name, names containing `:` or `.`, and bare `kill` with no
argument. `ls` listed only tagged sessions, excluding both a decoy and the
session the tests ran inside. `kill` and `attach` each refused the decoy by
name. `kill --all` refused to run non-interactively without `--yes`, and with it
removed exactly the tagged sessions and nothing else. With an untagged tmux
session `alpha` already live, `cohort new alpha` created `cohort-alpha`
alongside it, and `ls`, `attach` and `kill` all resolved to the prefixed one;
`cohort new cohort-beta` produced `cohort-beta`, not `cohort-cohort-beta`.

**Settings.** Resolution and precedence for launcher, model, permission mode and
extra args, across flag, environment variable, settings file and built-in
default, on both the `jq` and `python3` parser paths. An unknown key warns and
is ignored; malformed JSON exits non-zero; a settings file with neither parser
available is a clear error. A launcher given in array form (`env VAR=x claude`)
reached the spawned process with the variable set, which is how a shell function
like `ccw` is expressed as argv.

**End to end, real sessions.** Installed via the published one-liner, then two
workers spawned into separate git worktrees came up on the right branches,
appeared in `ListAgents` under their session names, and round-tripped
`SendMessage`. A lead asked in plain language to "spin up a worker" — with the
tool never named — ran `cohort new` on its own from the CLAUDE.md guidance, and
matched its own permission mode deliberately.

**Settings across a hop.** A lead spawned from `settings.json` alone, with no
`COHORT_*` variables set, was asked to stand up a worker. It ran bare
`cohort new <name>`, and the worker came up with the same launcher, model and
permission mode as the lead. This is the case the environment variables cannot
serve: a detached tmux session inherits the tmux server's environment, so
`tmux show-environment` confirms `COHORT_MODE` is absent inside a spawned
session even when it was set in the spawning shell.

**Installer.** Fresh install, re-run, install onto an existing CLAUDE.md, re-run
after a hand-edit inside the block, uninstall with and without other content,
uninstall twice, `CLAUDE_CONFIG_DIR` and `--bindir` overrides, a piped run that
downloads its payloads and ignores same-named files in the working directory,
and a `cohort` in the target directory the installer did not write — reported as
skipped and left on disk. Uninstall restored a 159-line CLAUDE.md
byte-for-byte.

Untested: macOS, and `attach` against a live client (its refusal path is
covered, the switch itself is not). The paradigm under sustained multi-worker
load is exercised only as far as the runs above.
