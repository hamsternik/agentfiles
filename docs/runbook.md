# Runbook

## Rebuild a host from scratch
1. **Erase**: System Settings > General > Transfer or Reset > Erase All Content and Settings.
   In Setup Assistant: Migration Assistant "Not now"; Apple Account "Set Up Later" (no iCloud on
   the slave); create the admin account `agent`; FileVault as decided (on). Then Software Update.
2. **Sharing** (System Settings > General > Sharing), each limited to "Only these users: agent":
   Remote Login on, Screen Sharing on. Remote Management and Remote Application Scripting off
   (Remote Management takes over Screen Sharing). Leave "Allow full disk access for remote users"
   off unless a tool needs it.
3. `xcode-select --install`.
4. Homebrew (the one-line installer from brew.sh, then the two `shellenv` lines it prints),
   `brew install gh`, `gh auth login` once per account,
   `gh repo clone <you>/agentfiles ~/agentfiles && cd ~/agentfiles`.
5. `./bootstrap.sh slave --dry-run` (changes nothing; reads `local.example/` until `local/` exists).
6. `./bootstrap.sh slave` → creates `local/`. Restore or fill `local/machine.env`,
   `local/projects.yaml`, `local/limits.env` (keep a copy of `local/` in your password manager
   or another private place; it is not in git).
7. `make slave`, then do the printed manual steps. Re-run `make slave` until it is clean.
8. Secrets: `af secret set us-gateway/wireguard-private-key` and `.../wireguard-addresses`.
9. `af doctor`.

Re-running `make slave` at any time applies changes from the repo.

## Try a change on the real host before pushing
| What | Command (on the master) |
|---|---|
| All stub tests (macOS `/bin/bash` 3.2) | `make test` |
| One step of this working tree on the host | `make remote-step TARGET=agent@<host> STEP=15 VARS="AF_LID_CLOSED=1"` |
| Lid-closed end-to-end check | `make e2e-power TARGET=agent@<host>` |

`remote-step` copies the working tree to `~/agentfiles-dev` on the host and never touches its
own `~/agentfiles`. Type the SSH password within 2 minutes (sshd `LoginGraceTime`).

## Daily operations
| Task | Command |
|---|---|
| Open a shell on the host | `af attach` (master) |
| See the host's screen | `af attach --screen` (master) |
| Machine status | `af doctor`, `af health`, `af slot status` |
| Gateway | `af gateway status` / `test` / `logs` / `up` / `down` |
| Projects | `af projects list` / `sync` / `install-jobs` |
| Run a job now | `af job <project> <job>` |
| Free disk | `af cleanup` (dry run), `af cleanup --apply` |
| Logs | `~/.agentfiles/logs/` (long logs are trimmed to `AF_LOG_MAX_LINES`) |

## Lid closed and the display
- Set `AF_LID_CLOSED=1` in `local/machine.env`; step 15 sets `pmset -a disablesleep 1`. It
  applies on battery too: keep the charger connected and never put the Mac in a bag like this.
- Keep air gaps: the 16" MacBook Pro takes air in at the bottom side edges and blows it out at
  the back. Check with `pmset -g therm` during a long build.
- Screen Sharing needs a display. Options, to be tested on the host:
  1. A real HDMI cable from the monitor's second input. It works only if the monitor keeps the
     link up while it shows another input, is in standby, or is off. Turn off the monitor's
     "auto source" so it does not jump to the host.
  2. A dummy HDMI plug in the free HDMI port (most reliable).
  3. A software virtual display (no hardware; can break after updates).
- Test: lid closed, monitor on the other input; from the master open Screen Sharing and run
  `system_profiler SPDisplaysDataType` over SSH. Repeat after 15 minutes, after the master
  sleeps, and after the monitor is switched off and on.

## Reboots and FileVault
**FileVault on** (the current decision):
- After any restart the Mac waits at the unlock screen. Nothing runs before the unlock,
  including `tailscaled`, so the host is **not** reachable over Tailscale.
- macOS 26+ on Apple silicon can unlock over SSH: from a device on the **same LAN**,
  `ssh agent@<host>.local`, type the password; the Mac finishes booting. Reconnect after about a
  minute. Remote Login must be on in System Settings **before** the restart; use Ethernet or a
  known WPA2 Wi-Fi. (Status: not yet tested on the host.)
- Away from home there is no way to unlock: the host stays down until you are back.
- Planned reboot: `sudo fdesetup authrestart` (check `fdesetup supportsauthrestart` first).
- macOS updates download only. Install them while you watch; Apple silicon needs a volume owner:
  over SSH `sudo softwareupdate -l`, then
  `sudo softwareupdate -i -a -R --agree-to-license --user "$USER" --stdinpass` (password on
  stdin), then the LAN SSH unlock.
- Automatic login is impossible while FileVault is on; the unlock itself logs `agent` in.

**FileVault off**: the host reboots to the login window; with automatic login the GUI session
(simulators, Chrome) comes back on its own. Weaker if the machine is stolen.

## After a reboot
1. FileVault: unlock (above). Tailscale (system daemon) comes up after the unlock.
   Check from the master: `ssh agent true`.
2. OrbStack starts at login; the gateway restarts itself (`restart: unless-stopped`).
   If it started before Tailscale had an IP, the health check re-runs `af gateway up`.
3. `af doctor`.

## Master with a system-wide VPN
With the Mullvad app connected on the master, LAN traffic is blocked: `<host>.local` does not
resolve and SSH / Screen Sharing time out. Turn on Mullvad > Settings > VPN settings >
"Local network sharing". Phase 3 (US gateway on the host) removes the need for the app.

## Troubleshooting
- **Gateway test fails:** `af gateway logs`. The test needs `loc=US` from Cloudflare's trace
  through the proxy (and a Mullvad exit when the provider is mullvad). Common causes: WireGuard
  key revoked or device limit reached in the VPN account; Keychain locked.
- **`af secret get` times out or fails over SSH:** the login keychain is locked in SSH sessions.
  Run `security unlock-keychain ~/Library/Keychains/login.keychain-db`, then retry.
- **SSH asks for the password, then "Connection closed":** the 2-minute login grace time ran out.
- **Screen Sharing switch is off, "controlled by the remote management service":** turn Remote
  Management off, then Screen Sharing on.
- **`tmux` / `mosh-server` not found over SSH:** `af attach` calls them under
  `AF_HOST_BREW_PREFIX` (default `/opt/homebrew`); set it in the master's `local/machine.env`.
- **Agents waiting forever for a slot:** `af slot status`. Slots of dead processes are
  reclaimed automatically; a live one is genuinely busy.
- **Disk blocked:** `af cleanup --apply`, then `af worktree list` and remove finished ones.
- **`codesign` fails over SSH:** the login keychain is locked in SSH sessions. Simulator builds
  don't need signing; device builds stay on the master for now.
