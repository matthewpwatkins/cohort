# cohort

A lightweight orchestrator for running parallel and persistent
Claude Code sessions on Mac and Linux.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/matthewpwatkins/cohort/main/install-cohort.sh | bash
```

This installs cohort and gives your claude code installation the "smarts"
to interact with cohort sessions, spin up new workers, and facilitate messaging
between your cohort agents.

There is nothing to set up afterwards. The installer puts the command in `~/bin`,
wires session-name completion into your `.bashrc` and `.zshrc`, and installs
[tmux](https://github.com/tmux/tmux/wiki/Getting-Started) if you do not already
have it (via brew, apt, dnf, yum, zypper, pacman or apk — it will ask for your
password if the package manager needs root). Completion applies to shells you
open from then on.

Pass `--bindir DIR` to install the command somewhere other than `~/bin`, or
`--no-tmux` to leave the tmux check alone.

## Usage

### Creating sessions

```bash
cohort new lead             # Creates a new tmux session called cohort-lead
                            # and spawns a Claude Code session named lead
                            # inside that tmux session
```

Then, while inside the lead Claude session, tell Claude:

```
Create a worker session for each of the three tickets assigned to me on our Jira board: <url>
```

The lead agent will then spin up those three new cohort claude sessions as worktrees
and coordinate their work. You can see these sessions and interact with them individually:

```bash
$ cohort ls
NAME                      BRANCH                         AGE      ATTACHED  DIR
lead                      main                                     20m      yes       /home/you/project
JIRA-1234-add-crud-ops    worktree-JIRA-1234-add-crud-ops          4m       no        /home/you/project/.claude/worktrees/JIRA-1234-add-crud-ops
JIRA-1235-unit-tests      worktree-JIRA-1235-unit-tests            16m      no        /home/you/project/.claude/worktrees/JIRA-1235-unit-tests
```

The lead session is on your checkout and the workers are each on their own
branch in their own worktree — see [Worktrees](#worktrees) for how to change
that.

### Interacting with sessions through the lead

When you're attached to the lead, you can give it more work to farm out to its team,
tell it to spawn new workers, or ask for overall status updates. You are basically
the technical PM now:

```
I just heard that we want to combine the create and update into a single upsert operation. Let the CRUD worker know.

Also, tell the unit test worker to make sure to upgrade us to the latest version of the mocking lib while it's working.

And we got another ticket in for adding a new role-- JIRA-1236-- spin up another worker to do that. That will impact the CRUD worker.

And is the unit test worker almost done? I'm wondering if we should add integration tests while we're in there.
```

Just as you can direct the whole team from the lead session, the lead session will also surface questions from its workers to you:

```
There is a pre-existing test failure both workers found. Ignore the test or fix it?
```

### Interacting with sessions yourself

But you may find it helpful to join the worker sessions yourself to give guidance, rotating through each of them
like an architect stopping by each team member's desk to check in and answer questions.

Use the `cohort attach` (or `cohort a`) command with the session name (auto-complete works):

```bash
$ cohort attach JIRA-1234-add-crud-ops
```

All sessions are [tmux](https://github.com/tmux/tmux/wiki/Getting-Started) sessions under the hood so all your familiar tmux commands work as well:

| Command | Does |
| ------- | ---- |
| `tmux a -t cohort-<name>` | Attaches to a cohort session named `name` |
| Ctrl + B, D | Detaches from the currently attached cohort session |
| Ctrl + B, S | Lists the running sessions and lets you switch between them |
| ... | ... |

### Human as the lead

Don't feel like letting the Claude lead session run things for you?
That's fine, you can always manage your worker sessions yourself:

```bash
cohort new bug-hunt
cohort new auth-refactor
cohort new lighthouse-audit
```

### Configuration

Any command flags you pass to cohort new get passed to your claude command.
So, for example, if you wanted to start a claude session in cohort with a
particular model, effort level, or permission mode, you can do that:

```bash
cohort new auth-refactor --model opus --effort high --permission-mode plan
```

This is also how you give one session a different model than the rest — you
might want your lead on Fable, which is stronger at holding a plan across a
dozen moving parts, while the workers stay on Opus:

```bash
cohort new lead --model fable
```

You can set the default model, permission mode and claude launch command in
`~/.cohort/settings.json`. Every key is optional:

```json
{
  "command": ["env", "CLAUDE_CONFIG_DIR=/home/you/.claude-work", "claude"],
  "model": "claude-opus-5",
  "permissionMode": "bypassPermissions",
  "worktree": true,
  "args": ["--verbose"]
}
```

`cohort config` prints what is actually in effect and where each value came
from, which is the quickest way to check a settings file is being read.

### Cohort/Claude "profiles"

Did you know you can have Claude installed against two different configurations
and two different accounts or integration types? You do this by having two different
`~/.claude` configuration dirs and launching claude against the specific dir you want
to target via the `CLAUDE_CONFIG_DIR` environment variable.

For example, in your `.bashrc` or `.zshrc`:

```bash
# Claude - work profile launcher
claude_work() {
  CLAUDE_CONFIG_DIR="/home/you/.claude-work" claude "$@"
}

# Claude - personal profile launcher
claude_personal() {
  CLAUDE_CONFIG_DIR="/home/you/.claude-personal" claude "$@"
}

# ... other profiles / accounts ...
```

Then you can launch Claude either against work or personal (or whatever) from the shell:

```bash
claude_work             # Launches claude against your work config / credentials
claude_personal         # Launches claude against your personal config / credentials
```

You can do the same thing for cohort via the `COHORT_CONFIG_DIR` environment directory:

```bash
# Cohort - work profile launcher
cohort_work() {
  COHORT_CONFIG_DIR="/home/you/.cohort-work" cohort "$@"
}

# Cohort - personal profile launcher
cohort_personal() {
  COHORT_CONFIG_DIR="/home/you/.cohort-personal" cohort "$@"
}

# ... other profiles / accounts ...
```

The launch from the shell:

```bash
cohort_work             # Launches cohort against your work config / credentials
cohort_personal         # Launches cohort against your personal config / credentials
```

### Worktrees

Worker agents in the cohort each get their own Claude/Git worktree/branch by default
(same as `claude --worktree <cohort-agent-name>`). You can keep the agent on the
current branch/repo root by passing `--no-worktree`:

```bash
cohort new auth-refactor --no-worktree
```

Claude branches a new worktree from the tracked remote branch rather than from
your working checkout, so a worker does not inherit commits you made locally but
have not pushed. cohort warns when your HEAD is ahead of its upstream, so this
does not surprise you halfway through a session:

```
cohort: HEAD is 3 commit(s) ahead of origin/main; 'auth-refactor' branches from origin/main and will not see them
```

Or if you want to disable worktrees on all `cohort new` commands by default,
you can set `"worktree": false` in the settings.json. If you want to launch
a worktree after setting that flag, just pass `--worktree <name>` in the `cohort new`
command explicitly.

## How this different from Claude Agent Teams

[Claude Agent Teams](https://code.claude.com/docs/en/agent-teams) is an
experimental feature in claude hidden behind a feature flag. It allows
agents to spin up specialized subagents that can communicate with each
other, but these subagents cannot spawn their own subagents, and they die when
the agent that spawned them dies. Native subagents use their own messaging
tools and interacting directly with child agents is difficult.

By contrast, cohort spawns sessions as full peer agents, independent
of the agent that spawned them. They communicate with each other using
Claude's new [inter-session messaging protocol](https://code.claude.com/docs/en/cross-session-messaging),
they can spawn their own subagents, and interacting directly with them is seamless.

## Updating and uninstalling

Updating is the install command again. It overwrites the `cohort` command and
the guidance block in your CLAUDE.md, reports what it changed, and says
`unchanged` when there was nothing to do:

```bash
curl -fsSL https://raw.githubusercontent.com/matthewpwatkins/cohort/main/install-cohort.sh | bash
```

Uninstalling takes the same script:

```bash
curl -fsSL https://raw.githubusercontent.com/matthewpwatkins/cohort/main/install-cohort.sh | bash -s -- --uninstall
```

That removes the `cohort` command, the completion files, and the managed blocks
in your CLAUDE.md and shell rc files, leaving everything else in those files
alone. It will not delete a `cohort` in your bin directory that this installer
did not write, and it will not uninstall tmux. Your `~/.cohort/settings.json`
stays put, so a reinstall picks up where you left off; delete it yourself if you
want it gone.

Running sessions are unaffected by either — they are tmux sessions, and they
keep running. Use `cohort kill --all` first if you want a clean slate.
