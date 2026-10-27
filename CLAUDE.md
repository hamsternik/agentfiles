# CLAUDE.md — working on agentfiles

Context for an agent editing *this* repo (rules for agents running *on* a host
are in `claude/CLAUDE.host.md`).

## What this is
Bash-based provisioning for macOS agent machines, in two roles (`host`, `cockpit`),
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
