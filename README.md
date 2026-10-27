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
git clone https://github.com/<you>/agentfiles.git ~/agentfiles && cd ~/agentfiles
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
apple/                  pinned Xcode version, simulator runtimes
services/us-gateway/    gluetun compose files (VPN egress + HTTP proxy)
services/launchd/       health + cleanup agent templates
claude/CLAUDE.host.md   global rules for agents running on the host
schemas/                example .agent/project.yaml for project repos
local.example/          templates for local/ (gitignored, machine-specific)
hooks/pre-commit        blocks local/, secrets, denylisted terms
docs/                   PLAN, runbook, security
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

## Relationship to dotfiles

Shell, editor, git and tmux config stay in your personal dotfiles repo. Set
`DOTFILES_REPO` and `DOTFILES_TARGETS` in `local/machine.env` and the host step
`40-dotfiles` clones it and runs those make targets.

## Safety

Nothing private goes in git: see [docs/security.md](docs/security.md). Run `make deps hooks`
on every clone; fill `local/denylist.txt` with work-related terms.
