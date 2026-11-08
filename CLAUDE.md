# CLAUDE.md — working on agentfiles

Context for an agent editing *this* repo (rules for agents running *on* a host
are in `claude/CLAUDE.host.md`).

## What this is
Bash-based provisioning for macOS agent machines, in two roles (`slave`, `master`),
plus the `af` CLI. See `docs/PLAN.md`.

## Hard rules
- No secrets, employer/client/project names, hostnames, IPs or emails in tracked files.
  Machine-specific values go in `local/` (gitignored); secrets in the Keychain via `af secret`.
- Stay project-agnostic: never add a specific project here. Projects declare needs in their
  own `.agent/project.yaml`.

## Conventions
- Steps live in `roles/<role>/steps/NN-name.sh`, run in order, and must be idempotent.
- Side effects go through `run` (so `--dry-run` works); human-only actions through `manual`.
- `bootstrap.sh`, `lib/common.sh` and steps 00–20 run before Homebrew exists, under macOS
  `/bin/bash` 3.2: no associative arrays, no `mapfile`, guard empty arrays under `set -u`
  with `${arr[@]+"${arr[@]}"}`.
- New `af` subcommands: `bin/af-<name>`, line 2 is a one-line description (shown by `af help`),
  source `lib/common.sh` and call `af_load_config`.
- Limits are variables in `config/limits.env`, never literals in scripts.
- Keep `make lint` (shellcheck) clean.
- `--dry-run` changes nothing: no sudo, no writes outside the repo, no installs, no opened apps.
  Read-only checks are fine; preconditions use `die_or_warn`. `tests/dry-run.test.sh` enforces it.
- Every behaviour change gets a stub test in `tests/<name>.test.sh` first (stubs on PATH, temp
  HOME/AF_HOME/AF_LOCAL, run with `/bin/bash`); `make test` runs them. Real-host checks live in
  `tests/e2e/`.
- Prefer tools that ship with macOS (e.g. `/usr/bin/jq`, `/usr/bin/perl`) over Homebrew ones in
  steps that may run before Homebrew.
- `systemsetup` exits 0 on failure: never rely on its exit code.
- Install source: Homebrew formula or cask first; anything else (curl script, npx, pkg) only
  after the owner agrees, per tool. Exact versions live in `config/versions.env`,
  `apple/runtimes.txt` and the compose digest; `af versions` checks them and the Homebrew snapshot.
- Layout: nothing of agentfiles goes directly into `~` (also no `~/.x`). The clone is
  `~/Developer/_hamsternik/agentfiles`, runtime state `AF_HOME` = `<clone>/.state/` (git-ignored),
  dotfiles `~/Developer/_hamsternik/dotfiles`, projects by `group` in `~/Developer/_work` or
  `~/Developer/_hamsternik`, worktrees in `<group folder>/.worktrees`. Only tool locations
  (`.ssh`, `.claude`, `.config`, `.vim`, `Library`) are allowed in `~`; `tests/layout.test.sh` checks it.
- The slave's login shell is fish: every remote command (`ssh host cmd`) must parse in fish and
  sh (`tests/remote-shell.test.sh`).
