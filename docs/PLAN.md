# agentfiles — plan

Turn a spare Mac into an always-on **agent host**, driven entirely from a
main laptop (the **cockpit**), and make the whole setup reproducible from
this repo on any future machine.

## Why

Agents running on the laptop you work on are always within reach, so it is
always easier to step in by hand than to automate. A separate machine removes
that option and forces a workflow that runs without you, while still letting
you step in at any point. It also takes always-on load off the main laptop:
VPN egress, crawls, long-running jobs, parallel simulators.

## Principles

1. **Cockpit and engine.** The laptop (and phone) only *drive*. Everything
   long-running lives on the host.
2. **Project-agnostic.** This repo provides capabilities (gateway, slots,
   worktrees, schedules, health). Projects describe their own needs in
   `.agent/project.yaml`. Which projects a machine runs is local config.
3. **Nothing private in git.** No secrets, no employer or client names, no
   machine identifiers. `local/` is gitignored; secrets live in the Keychain;
   a pre-commit hook enforces it.
4. **Idempotent and re-runnable.** `./bootstrap.sh <role>` is both install and
   update. A step that needs a human records a manual step instead of failing.
5. **Limits are config, not discipline.** Concurrency, disk and memory limits
   live in `config/limits.env` and are enforced by `af` commands agents must use.
6. **Harness-agnostic.** Slots, worktrees, health and the gateway work for any
   agent CLI: Claude Code today, other harnesses later.

## Architecture

```
 cockpit (main laptop, phone)                  host (always-on Mac)
 ─────────────────────────────                 ───────────────────────────────────
 Tailscale app ───────── tailnet ──────────── tailscaled (system daemon)
 af attach  ── ssh/mosh ──────────────────────▶ tmux sessions: Claude Code, shells
 Screen Sharing ──── vnc ─────────────────────▶ GUI session: simulators, Chrome, prompts
 af browser us ─ proxy :8888 (tailnet only) ──▶ gluetun (OrbStack) ── WireGuard ── VPN (US exit)
 GitHub issues / PRs ◀──────────────────────── agents: plan → implement → validate → review → PR
                                                launchd: health (15 min), cleanup (weekly), project jobs
                                                af slot: xcodebuild ×1, simulator ×2, browser ×2
```

## Decisions

| Area | Decision |
|---|---|
| Roles | `host` = always-on agent machine; `cockpit` = the machine you drive it from |
| Network | Tailscale. Host runs the CLI daemon (up before login); cockpit runs the app |
| Terminal | SSH + tmux (mosh when available) via `af attach` |
| GUI | macOS Screen Sharing over Tailscale (`af attach --screen`) |
| Async control | GitHub issues and PRs |
| Resource limits (16 GB / 512 GB) | 1 Xcode build, ≤2 simulators, ≤2 browsers, ≤6 worktrees; disk warn 80% / block 90% |
| Apple toolchain | Pinned Xcode via `xcodes`, short runtime list, simulator-only builds at first; signing stays on the cockpit |
| Browsers | Headless Playwright for scripted work; dedicated Chrome profiles (`us`, `agent`) for Claude in Chrome; Chrome for Testing for validation |
| US egress | gluetun + WireGuard VPN in OrbStack with kill switch; HTTP proxy on localhost and the tailnet IP only |
| Secrets | macOS Keychain via `af secret`; never in git or `local/` |
| Shell/editor config | Delegated to the personal dotfiles repo (`DOTFILES_REPO` + `DOTFILES_TARGETS`) |
| Repo visibility | Private first; public only after a full-history gitleaks scan |

## Phases

### Phase 0 — Prepare (on the cockpit)
- [ ] Push this repo to a **private** GitHub repo; run `make hooks`.
- [ ] Fill `local/denylist.txt` on the cockpit with employer, client and work-domain terms.
- [ ] List what moves to the host: long-running jobs, crawlers, anything needing US egress.
- [ ] In the VPN account, generate a WireGuard key for the host (uses one device slot).
- [ ] Decide FileVault on/off for the host (see runbook: *Reboots and FileVault*).
- [ ] Back up anything on the spare Mac you still want.

### Phase 1 — Wipe and base the host
- [ ] Erase the spare Mac; install the newest macOS it supports.
- [ ] Create an admin user for agents (e.g. `agent`). Skip iCloud on this machine.
- [ ] Install Command Line Tools: `xcode-select --install`.
- [ ] `git clone` this repo over HTTPS; run `./bootstrap.sh host` (first run creates `local/`).
- [ ] Fill `local/machine.env`, then `make host`. Work through the printed manual steps.
- [ ] `af doctor` passes the base checks (sleep, Remote Login, Tailscale, Homebrew).

### Phase 2 — Access from the cockpit
- [ ] On the cockpit: clone the repo, fill `local/machine.env`, `make cockpit`.
- [ ] Add the `Include` line to `~/.ssh/config`; `ssh-copy-id agent`.
- [ ] `af attach` opens a tmux session on the host; `af attach --screen` opens Screen Sharing.
- [ ] Reach the host from the phone over Tailscale (SSH app + tmux).
- [ ] Tailscale admin: disable key expiry for the host; ACLs limit access to your devices.

### Phase 3 — US gateway
- [ ] On the host: `af secret set us-gateway/wireguard-private-key` and `.../wireguard-addresses`.
- [ ] `af gateway up`, then `af gateway test` shows a US exit through the VPN.
- [ ] On the cockpit: `AF_US_PROXY_URL=http://<host>:8888`, then `af browser us` opens US stores.
- [ ] Once that is reliable, turn off the system-wide VPN on the cockpit (keep the app as fallback).

### Phase 4 — Migrate the first scheduled project
- [ ] Add `.agent/project.yaml` to the project's own repo (see `schemas/project.example.yaml`).
- [ ] List it in the host's `local/projects.yaml`; `af projects sync`.
- [ ] Run once by hand: `af job <project> <job>`; check logs in `~/.agentfiles/logs`.
- [ ] `af projects install-jobs`; set `AF_NOTIFY_CMD` (Slack webhook, Telegram or ntfy script).
- [ ] Watch a week of `health.log`; tune `local/limits.env` from real numbers.
- [ ] Repeat for the remaining long-running projects; remove their schedules from the cockpit.

### Phase 5 — Interactive agent work on the host
- [ ] Sign in to Claude Code and the Claude desktop app on the host; `gh auth login` with scoped access.
- [ ] Set up remote access to Claude sessions on the host (check current Claude Code / desktop options).
- [ ] Daily loop: `af attach`, `af worktree new`, agent works, `af worktree rm` after merge.
- [ ] Confirm agents follow `claude/CLAUDE.host.md` (builds via `af build`, simulators via `af sim run`).

### Phase 6 — Autonomous pipeline: issue to PR
- [ ] Pick one repo and one trigger (e.g. an `agent` label on an issue).
- [ ] Stage 1: plan → posts the plan as an issue comment. Stop there until plans are good.
- [ ] Stage 2: implement in a worktree → opens a draft PR.
- [ ] Stage 3: validate (tests, `af sim run`, Playwright) → screenshots and video attached.
- [ ] Stage 4: review by a separate agent → comments on the PR.
- [ ] Follow-ups happen in PR comments. Options for the runner: a self-hosted GitHub
      Actions runner on the host, or a small polling loop. Decide at the start of this phase.

### Phase 7 — Reproducibility drill
- [ ] Rebuild the host from scratch (or set up a second machine) using only this repo and the runbook.
- [ ] Time it; anything done by hand that could be scripted becomes a step; the rest goes in the runbook.

## Later / open
- nix-darwin, if the shell-based bootstrap starts to drift.
- A 1Password CLI backend for `af secret`, alongside the Keychain one.
- A residential proxy as an alternative exit for sites that block VPN IPs.
- Physical-device testing and signing on the host (fastlane match).
- Additional agent harnesses on the same slots and worktrees.
