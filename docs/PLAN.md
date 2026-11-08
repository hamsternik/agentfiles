# agentfiles — plan

Turn a spare Mac into an always-on **agent host**, driven entirely from a
main laptop (the **master**), and make the whole setup reproducible from
this repo on any future machine.

## Why

Agents running on the laptop you work on are always within reach, so it is
always easier to step in by hand than to automate. A separate machine removes
that option and forces a workflow that runs without you, while still letting
you step in at any point. It also takes always-on load off the main laptop:
VPN egress, crawls, long-running jobs, parallel simulators.

## Principles

1. **Master and engine.** The laptop (and phone) only *drive*. Everything
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
 master (main laptop, phone)                   slave (always-on Mac)
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
| Roles | `slave` = always-on agent machine; `master` = the machine you drive it from |
| Network | Tailscale. Host runs the CLI daemon (up before login); master runs the app |
| Terminal | SSH + tmux (mosh when available) via `af attach` |
| GUI | macOS Screen Sharing over Tailscale (`af attach --screen`) |
| Async control | GitHub issues and PRs |
| Resource limits (16 GB / 512 GB) | 1 Xcode build, ≤2 simulators, ≤2 browsers, ≤6 worktrees; disk warn 80% / block 90% |
| Apple toolchain | Xcode pinned by version **and** build in `config/versions.env` (xcodes), simulator runtimes pinned by build in `apple/runtimes.txt`; simulator-only builds at first; signing stays on the master |
| Browsers | Dedicated Chrome profiles (`us`, `agent`) for Claude in Chrome; projects install the browsers of their own Playwright version (no host-level Playwright or Chrome for Testing: no Homebrew package) |
| US egress | gluetun + WireGuard VPN in OrbStack with kill switch; HTTP proxy on localhost and the tailnet IP only |
| Secrets | macOS Keychain via `af secret`; never in git or `local/` |
| Terminal environment | Slave step **25**, right after Homebrew: the personal dotfiles repo (`DOTFILES_REPO`, default in `local.example`), its `Brewfile.terminal`, the `DOTFILES_TARGETS` make targets, fish as the login shell (`AF_LOGIN_SHELL`) |
| Install source | Homebrew formula or cask first; a native installer only after a discussion per tool. Hand-installed apps with a cask are adopted (`brew install --cask --adopt`) |
| Versions | Strategy A: `brew bundle --no-upgrade`, pins in `config/versions.env` / `apple/runtimes.txt` / compose digest, snapshot `config/brew-versions.<role>.txt`; `af versions` fails on drift. mise (Strategy B) later |
| Mullvad app on the slave | Bridge for US egress until the gluetun gateway works; step 30 keeps its local network sharing on |
| Repo visibility | Private first; public only after a full-history gitleaks scan |
| Disk encryption | FileVault **on** for the slave. No automatic login; after an unplanned restart, unlock over SSH from the same LAN (Tailscale starts only after the unlock). See runbook |
| Lid | Slave runs with the lid closed: `AF_LID_CLOSED=1` (step 15, `pmset disablesleep 1`). Display for Screen Sharing: decided on the M1 (HDMI cable or dummy plug) |
| GitHub identities | Slave signs in to `gh` with the personal **and** the work account (full access; git picks the identity per remote via SSH host aliases) |
| Sharing services | Remote Login + Screen Sharing on, only for the agent user. Remote Management and Remote Application Scripting off |
| Tests | `make test` (stubbed, macOS `/bin/bash` 3.2); real-host checks: `make e2e-power`, `make remote-step` |

## Phases

### Phase 0 — Prepare (on the master)
- [x] Push this repo to a **private** GitHub repo; run `make hooks`.
- [ ] Fill `local/denylist.txt` on the master with employer, client and work-domain terms.
- [ ] List what moves to the host: long-running jobs, crawlers, anything needing US egress.
- [ ] In the VPN account, generate a WireGuard key for the host (uses one device slot).
- [x] Decide FileVault on/off for the host: **on** (see runbook: *Reboots and FileVault*).
- [x] Back up anything on the spare Mac you still want.
- [x] `make lint` clean; `--dry-run` changes nothing (tests/dry-run.test.sh; both roles run on the master).
- [x] macOS commands checked against current docs: `docs/research/RESEARCH-macos-commands.md`.
- [x] Decide the version-pin strategy: **A** now, B (mise) later (`docs/plans/PLAN-session-2.md`).
- [ ] Your dotfiles prerequisites for step 25 (`Brewfile.terminal`, no `neofetch`, `$HOME` instead of
      hardcoded paths, safe `zshenv`, `ssh-add -l || true`, fish folders/fisher, node@24):
      see `docs/plans/PLAN-session-2.md`, Part 1.
- [ ] Decide the user model on the slave: one admin `agent` (now) or admin + standard `agent`. Reversible without a wipe.
- [ ] Decide the tailnet tag + ACL for the slave (example in `docs/security.md`).

### Phase 1 — Wipe and base the host
- [x] Erase the spare Mac; install the newest macOS it supports (Erase All Content and Settings, then macOS 27.2).
- [x] Create an admin user for agents (e.g. `agent`). Skip iCloud on this machine.
- [x] Install Command Line Tools: `xcode-select --install`.
- [x] Turn on Remote Login and Screen Sharing (not Remote Management) for the agent user.
- [x] Lid closed: `make remote-step TARGET=agent@<host> STEP=15 VARS="AF_LID_CLOSED=1"`; `make e2e-power` passed.
- [ ] Install Homebrew and `gh`; `gh auth login` (both accounts); `gh repo clone <you>/agentfiles ~/Developer/_hamsternik/agentfiles`.
- [ ] `./bootstrap.sh slave --dry-run`, then `./bootstrap.sh slave` (first run creates `local/`).
- [ ] Fill `local/machine.env`, then `make slave`. Work through the printed manual steps.
- [ ] `af doctor` passes the base checks (sleep, Remote Login, Tailscale, Homebrew).

### Phase 2 — Access from the master
- [ ] On the master: clone the repo, fill `local/machine.env`, `make master`.
- [ ] Add the `Include` line to `~/.ssh/config`; `ssh-copy-id agent`.
- [ ] `af attach` opens a tmux session on the host; `af attach --screen` opens Screen Sharing.
- [ ] Reach the host from the phone over Tailscale (SSH app + tmux).
- [ ] Tailscale admin: disable key expiry for the host; ACLs limit access to your devices.

### Phase 3 — US gateway
- [ ] On the host: `af secret set us-gateway/wireguard-private-key` and `.../wireguard-addresses`.
- [ ] `af gateway up`, then `af gateway test` shows a US exit through the VPN.
- [ ] On the master: `AF_US_PROXY_URL=http://<host>:8888`, then `af browser us` opens US stores.
- [ ] Once that is reliable, turn off the system-wide VPN on the master (keep the app as fallback).

### Phase 4 — Migrate the first scheduled project
- [ ] Add `.agent/project.yaml` to the project's own repo (see `schemas/project.example.yaml`).
- [ ] List it in the host's `local/projects.yaml`; `af projects sync`.
- [ ] Run once by hand: `af job <project> <job>`; check logs in `.state/logs/` in the clone.
- [ ] `af projects install-jobs`; set `AF_NOTIFY_CMD` (Slack webhook, Telegram or ntfy script).
- [ ] Watch a week of `health.log`; tune `local/limits.env` from real numbers.
- [ ] Repeat for the remaining long-running projects; remove their schedules from the master.

### Phase 5 — Interactive agent work on the host
- [ ] Sign in to Claude Code and the Claude desktop app on the host; `gh auth login` (personal and work accounts).
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

## Known gaps (verify on the M1)

Everything below is either untested on real hardware or only partly tested. Commands come from
`docs/research/RESEARCH-macos-commands.md` (section "Only verifiable on the M1").

- **Full bootstrap**: only step 15 ran on the slave. Steps 00–90 ran as dry-runs and stub tests.
- **FileVault**: the SSH unlock at the pre-boot screen (macOS 26+, LAN only) is not tested yet;
  nor is the state after it or after `fdesetup authrestart` (GUI session up or login window?).
- **Lid closed**: `SleepDisabled 1` after a reboot; thermals during long Xcode builds.
- **Display**: Screen Sharing with the lid closed, with HDMI 2 connected while the monitor shows
  another input, is in standby, or is off. Fallback: dummy plug.
- **Remote Login / Screen Sharing**: the `launchctl print-disabled` format (the master has no
  overrides to compare); whether `launchctl enable system/com.openssh.sshd` works without Full
  Disk Access and is honoured by the FileVault SSH unlock.
- **Keychain over SSH and from launchd**: reads may hang (now cut off after
  `AF_KEYCHAIN_TIMEOUT_SECONDS`); `security unlock-keychain` over SSH.
- **launchd**: LaunchAgents load only with a GUI session; step 90 skips them over SSH before login.
- **Xcode**: xcodes 2.1.0+ sign-in over SSH; `-downloadPlatform iOS -architectureVariant arm64`
  without an Apple ID; the SDK-matched runtime check after Xcode 27.1.
- **OrbStack**: `orb start` on a first run over SSH; "Start at login" (no CLI key);
  the port bind to the Tailscale 100.x address; `/dev/net/tun` + `NET_ADMIN` for gluetun.
- **gluetun**: empty `SERVER_CITIES`; the pinned `v3.41.3` digest on OrbStack.
- **Tailscale**: `tailscaled` (formula) is down until the FileVault unlock; coexistence with the
  Mullvad app on the master and on the slave (Mullvad needs "Local network sharing" for LAN
  access; step 30 sets it with `mullvad lan set allow`, untested without sudo on the slave).
- **SSH PATH**: `ssh agent 'command -v tmux mosh-server'` on the slave (af attach now uses absolute paths).
- **Terminal (step 25)**: needs your dotfiles prerequisites; which shell Claude Code uses for its
  tools when the login shell is fish; the `ssh` target needs your keys on the slave.
- **Versions**: the first `af versions --record` on the slave (commit the snapshot);
  `xcodes runtimes install <build>` by build; Xcode 27.1 needs an Apple ID sign-in or a copied `.xip`.
- **Adopted casks**: `brew install --cask --adopt` for the hand-installed Claude and Mullvad apps.
- **perl**: `af secret` uses `/usr/bin/perl` for the timeout; Apple calls it deprecated.
- **CI**: runs only shellcheck and gitleaks. `make test` needs macOS `/bin/bash` 3.2 and is not in CI.

## Later / open
- nix-darwin, if the shell-based bootstrap starts to drift.
- A 1Password CLI backend for `af secret`, alongside the Keychain one.
- A residential proxy as an alternative exit for sites that block VPN IPs.
- Physical-device testing and signing on the host (fastlane match).
- Additional agent harnesses on the same slots and worktrees.
