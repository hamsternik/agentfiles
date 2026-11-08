# agentfiles

Dotfiles for agent machines. One repo that turns a Mac into an always-on
**agent host**, or into the **master** you drive it from, and can rebuild
either on a new machine.

```
./bootstrap.sh slave     # the always-on machine agents run on
./bootstrap.sh master    # the laptop you work from
```

It is project-agnostic: it provides capabilities (US egress gateway, resource
slots, worktrees, scheduled jobs, health checks). Projects declare what they need
in their own repos, and which projects a machine runs is machine-local config.

See [docs/PLAN.md](docs/PLAN.md) for the why, the architecture and the rollout phases.

## Quick start

On a fresh Mac:

```bash
xcode-select --install
git clone https://github.com/<you>/agentfiles.git ~/Developer/_hamsternik/agentfiles && cd ~/Developer/_hamsternik/agentfiles
./bootstrap.sh slave       # first run creates local/ from local.example/ and stops
$EDITOR local/machine.env  # fill it in
make slave                 # installs hooks, runs every step; safe to re-run
af doctor                  # add bin/ to PATH first: `make path`
```

Steps that need a human (Apple ID, logins, System Settings toggles) are printed as
**manual steps** at the end of each run.

## Layout

```
Brewfile                repo dependencies (make deps)
bootstrap.sh            entry point: ./bootstrap.sh <role> [--only NN] [--dry-run]
roles/slave/            Brewfile + numbered idempotent steps for the agent host
roles/master/           Brewfile + steps for the driving laptop
bin/af                  the `af` CLI (af help)
config/limits.env       default limits for a 16 GB / 512 GB machine
config/versions.env     exact versions (Xcode version + build, xcodes minimum)
config/brew-versions.*  Homebrew snapshot per role (af versions --record)
apple/                  simulator runtimes pinned by build
services/us-gateway/    gluetun compose files (VPN egress + HTTP proxy)
services/launchd/       health + cleanup agent templates
claude/CLAUDE.host.md   global rules for agents running on the host
claude/skills/          Claude skills the inbox step links into ~/.claude/skills (triage-inbox)
claude/inbox/           the page that holds the Claude Inbox db (no interface)
schemas/                example .agent/project.yaml for project repos
local.example/          templates for local/ (gitignored, machine-specific)
hooks/pre-commit        blocks local/, secrets, denylisted terms
tests/                  stub tests (make test); tests/e2e/ checks against a real host
docs/                   PLAN, runbook, security; docs/research/ = dated evidence for decisions
```

## `af` commands

| Command | What it does |
|---|---|
| `af slot <kind> -- cmd` | run holding an `xcodebuild` / `simulator` / `browser` slot; waits when full |
| `af build <args>` | `xcodebuild` in a slot, DerivedData inside the worktree |
| `af sim run -- cmd` | boot a slot-owned simulator, export `SIM_UDID`, run, shut down |
| `af sim shot` / `record` | screenshot / video of a simulator |
| `af worktree new\|list\|rm` | agent worktrees with a cap; `rm` deletes build caches too |
| `af browser us\|agent` | dedicated Chrome profiles; `us` exits via the US gateway |
| `af gateway up\|down\|test` | the VPN egress gateway |
| `af secret set\|get\|has\|rm` | secrets in the macOS Keychain |
| `af projects list\|sync\|install-jobs` | projects from `local/projects.yaml`, schedules from their manifests |
| `af job <project> <job>` | run one manifest job with its needs applied |
| `af health` / `af cleanup` | disk, memory, swap, gateway checks / reclaim disk |
| `af attach [--screen]` | from the master: tmux on the host, or Screen Sharing |
| `af doctor` | check this machine against its role |
| `af versions [--record]` | pinned and recorded versions vs installed; fails on drift |
| `af inbox add\|move\|take\|ack\|status` | Claude Inbox, local side: outbox, local log, page URL (docs/inbox.md) |

## Tests

```
make lint                                   # shellcheck, no blanket disables
make test                                   # every tests/*.test.sh under macOS /bin/bash 3.2, stubbed
make remote-step TARGET=agent@<host> STEP=15 VARS="AF_LID_CLOSED=1"   # one step on the real host
make e2e-power TARGET=agent@<host>          # lid-closed check on the real host
```

## Relationship to dotfiles

Shell, editor, git and tmux config stay in your personal dotfiles repo. Slave step
`25-terminal` runs right after Homebrew: it clones `DOTFILES_REPO` (default in
`local.example/machine.env`), installs the repo's `Brewfile.terminal`, runs the
`DOTFILES_TARGETS` make targets and sets `AF_LOGIN_SHELL` (fish) as the login shell.
So you and the agents work in the same environment from the first SSH session on.

## Safety

Nothing private goes in git: see [docs/security.md](docs/security.md). Run `make deps hooks`
on every clone; fill `local/denylist.txt` with work-related terms.
