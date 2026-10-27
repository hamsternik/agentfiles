# Runbook

## Rebuild a host from scratch
1. Fresh macOS, admin user, `xcode-select --install`.
2. `git clone https://github.com/<you>/agentfiles.git ~/agentfiles && cd ~/agentfiles`
3. `./bootstrap.sh host` → creates `local/`. Restore or fill `local/machine.env`,
   `local/projects.yaml`, `local/limits.env` (keep a copy of `local/` in your password manager
   or another private place; it is not in git).
4. `make host`, then do the printed manual steps. Re-run `make host` until it is clean.
5. Secrets: `af secret set us-gateway/wireguard-private-key` and `.../wireguard-addresses`.
6. `af doctor`.

Re-running `make host` at any time applies changes from the repo.

## Daily operations
| Task | Command |
|---|---|
| Open a shell on the host | `af attach` (cockpit) |
| See the host's screen | `af attach --screen` (cockpit) |
| Machine status | `af doctor`, `af health`, `af slot status` |
| Gateway | `af gateway status` / `test` / `logs` / `up` / `down` |
| Projects | `af projects list` / `sync` / `install-jobs` |
| Run a job now | `af job <project> <job>` |
| Free disk | `af cleanup` (dry run), `af cleanup --apply` |
| Logs | `~/.agentfiles/logs/` |

## Reboots and FileVault
- **FileVault off:** the host reboots straight to the login window. With automatic login
  enabled, the GUI session (simulators, Chrome) comes back on its own. Weaker if the
  machine is stolen.
- **FileVault on:** after any reboot the Mac waits at the unlock screen until someone types
  the password. Check what your macOS version allows for unlocking remotely before relying on it.
  `sudo fdesetup authrestart` does one planned reboot without that stop.
- Either way: macOS updates are set to download only. Install them on your schedule with
  `softwareupdate -ia --restart` while you are watching.

## After a reboot
1. Tailscale (system daemon) comes up first. Check from the cockpit: `ssh agent true`.
2. Log in to the GUI session if automatic login is off.
3. OrbStack starts at login; the gateway restarts itself (`restart: unless-stopped`).
   If it started before Tailscale had an IP, the health check re-runs `af gateway up`.
4. `af doctor`.

## Troubleshooting
- **Gateway test fails:** `af gateway logs`. Common causes: WireGuard key revoked or device
  limit reached in the VPN account; Keychain locked (log in to the GUI session).
- **Agents waiting forever for a slot:** `af slot status`. Slots of dead processes are
  reclaimed automatically; a live one is genuinely busy.
- **Disk blocked:** `af cleanup --apply`, then `af worktree list` and remove finished ones.
- **`codesign` fails over SSH:** the login keychain is locked in SSH sessions. Simulator builds
  don't need signing; device builds stay on the cockpit for now.
