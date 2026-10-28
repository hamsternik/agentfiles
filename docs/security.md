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
- Decision: the slave signs in to `gh` with the personal **and** the work account, with full
  access. Every agent on the slave can therefore read and push to all those repos. The safer
  option (a fine-grained token or a separate account limited to the repos agents work on) stays
  available if that risk becomes too high.
- `gh auth switch` changes the active account for every process. For git, use one SSH key per
  account and host aliases, so the remote URL picks the identity.
- Work and personal git identities are separated by directory (`includeIf`) and SSH host
  aliases; see `local.example/git-identities.gitconfig`.

## Machine
- FileVault on (recovery key in your password manager); no automatic login.
- Sharing: Remote Login and Screen Sharing only for the agent user. Remote Management and Remote
  Application Scripting off. "Allow full disk access for remote users" off: agents run in tmux
  sessions started over SSH and would inherit it.
- Agents run as the admin user `agent` today. Open decision: a standard user for agents and a
  separate admin (no wipe needed: create the admin, then demote `agent`).

## Network exposure
- The host exposes SSH, Screen Sharing and the US proxy only to the tailnet. The proxy binds to
  127.0.0.1 and the Tailscale IP, never 0.0.0.0. Use Tailscale ACLs to limit who can reach it.
- By default every tailnet device can reach every other device. A prompt-injected agent on the
  host could then reach your laptop. Open decision: tag the host and let it accept connections
  only. Example policy (Tailscale admin console; a tagged device also has no key expiry):

  ```jsonc
  {
    "tagOwners": { "tag:agent-host": ["autogroup:admin"] },
    "acls": [
      // your devices -> host: SSH, Screen Sharing, US proxy, mosh
      { "action": "accept", "src": ["autogroup:member"],
        "dst": ["tag:agent-host:22,5900,8888,60000-61000"] },
      // your own devices keep reaching each other
      { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self:*"] }
      // no rule has src tag:agent-host: the host starts no connections into the tailnet
    ]
  }
  ```
  Apply the tag at login with `sudo tailscale up --hostname=<name> --advertise-tags=tag:agent-host`
  (you must be a tag owner). Tagging removes the user identity from the device.

## Before making the repo public
- [ ] `make secrets-scan` (full history) is clean.
- [ ] Grep history for your denylist terms: `git log -p | grep -iF -f local/denylist.txt`.
- [ ] Review `docs/` and examples for anything specific to you.
