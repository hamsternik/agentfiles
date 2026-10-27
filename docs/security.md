# Security and privacy

This repo is meant to be safe to keep in a personal GitHub account, and to make
public later if wanted.

## What never goes in git
- Secrets of any kind: keys, tokens, VPN credentials, account numbers.
- Employer, client or project names from work; work domains, emails, internal hostnames.
- Machine identifiers: real hostnames, tailnet names, IPs, usernames.

All of that lives in `local/` (gitignored) or the macOS Keychain.

## Enforcement
- `hooks/pre-commit` (installed by `make hooks`) blocks commits that:
  - stage anything under `local/`,
  - contain a secret detected by gitleaks (`.gitleaks.toml` = default rules + VPN/Tailscale rules),
  - contain any term from `local/denylist.txt`. Put work-related names there on every machine.
- CI repeats the gitleaks scan on the full history and checks `local/` is untracked.

## Secrets
- Stored with `af secret set <name>` in the Keychain (service `agentfiles`). The value is typed
  at a prompt, so it never appears in shell history or the process list.
- Read at use time (`af secret get`) and passed as environment variables, never written to files.

## Identities
- Agents on the host use a GitHub identity whose access is limited to the repos they work on
  (fine-grained token, or a separate account).
- Work and personal git identities are separated by directory (`includeIf`) and SSH host
  aliases; see `local.example/git-identities.gitconfig`.

## Network exposure
- The host exposes SSH, Screen Sharing and the US proxy only to the tailnet. The proxy binds to
  127.0.0.1 and the Tailscale IP, never 0.0.0.0. Use Tailscale ACLs to limit who can reach it.

## Before making the repo public
- [ ] `make secrets-scan` (full history) is clean.
- [ ] Grep history for your denylist terms: `git log -p | grep -iF -f local/denylist.txt`.
- [ ] Review `docs/` and examples for anything specific to you.
