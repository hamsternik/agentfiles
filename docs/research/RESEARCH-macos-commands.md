# RESEARCH: macOS commands used by agentfiles

Date: 2026-10-27. Scope: every macOS-specific command in `roles/slave/*`, `roles/master/*`,
`bin/af-*`, `services/*` and `docs/runbook.md`.

Target ("slave"): MacBook Pro 16" M1 Pro, 16 GB, macOS 27.2, lid closed, FileVault on,
no Apple Account, driven over SSH / Screen Sharing / Tailscale.
Research machine ("master"): MacBook Pro M4 Max (`Mac16,6`), macOS 27.0.1 (build 26A434),
Xcode 27.0 (27A266a), xcodes 1.6.0, no OrbStack, no Tailscale CLI.

How to read this:
- "Local" evidence = a read-only command run on the master on 2026-10-27. Output is quoted.
- "Status": works / changed / broken / unknown. "unknown" means: test it on the M1.
- Line numbers refer to the tree at commit `6263b72`.

Two findings change the design, not only a command:

1. **With FileVault on, Tailscale is not reachable after a reboot.** `tailscaled` lives on the
   encrypted Data volume. The macOS 26+ pre-boot SSH unlock listens on the Mac's own LAN/Wi-Fi
   address only. You must unlock from a device on the same LAN (or through a Tailscale subnet
   router on that LAN). See item 6.
2. **`systemsetup` exits 0 on failure.** Every `systemsetup ... || manual/warn` fallback in the
   repo is dead code. See item 2.

---

## 1. pmset

### 1a. `pmset -c sleep 0 disksleep 0 displaysleep 10 powernap 0 womp 1 tcpkeepalive 1`

- **Used at:** `roles/slave/steps/15-power.sh:14`; checked at `bin/af-doctor:23`.
- **Status:** works.
- **Evidence:**
  - Local `man pmset`: `-c` = charger, keys `womp`, `powernap`, `tcpkeepalive` documented.
  - Local `pmset -g cap` on an Apple silicon MacBook Pro lists for AC Power:
    `displaysleep disksleep sleep womp standby powernap ttyskeepawake hibernatemode hibernatefile tcpkeepalive lowpowermode highpowermode`.
    All six keys in the command are in that list.
  - Local `pmset -g custom` prints an `AC Power:` block with lines like ` sleep                0`.
    The `af-doctor` awk/grep (`/AC Power/,0` then `^ *sleep +0`) matched on the master.
- **Recommended change:** none. Optional: add `standby 0` only if the M1 still enters standby;
  with `sleep 0` and `disablesleep 1` it is not needed.
- **Confidence:** high.
- **Verify on M1:** yes. `pmset -g cap; pmset -g custom | awk '/AC Power/,0'`

### 1b. `pmset -a autorestart 1` on a MacBook

- **Used at:** `roles/slave/steps/15-power.sh:15`.
- **Status:** broken on laptops (setting not supported by the hardware; it is a no-op).
- **Evidence:**
  - Local `pmset -g cap` on the M4 Max MacBook Pro: `autorestart` is **not** in the list.
    Local `pmset -g custom` has no `autorestart` line. Same as reported on the M1.
  - Local `man pmset`: `autorestart - automatic restart on power loss`. It is a desktop
    feature (Mac mini / Studio / iMac).
  - Apple, "Prevent a Mac laptop from turning on when opening its lid or connecting to power",
    https://support.apple.com/120622 (Jan 2025): an Apple silicon laptop turns on
    automatically when you open the lid **or connect it to power**. You turn this off with
    `nvram BootPreference`. Default (variable absent) = auto power-on. Local:
    `nvram BootPreference` -> "data was not found" (default behaviour active).
  - So on a laptop the battery covers short power loss. After a full drain, the Mac powers on
    again when AC returns, by default.
- **Recommended change:** guard it and say why:
  ```bash
  if pmset -g cap | grep -qw autorestart; then
    run sudo pmset -a autorestart 1
  else
    ok "autorestart not supported on this model; Apple silicon laptops power on when AC is connected"
  fi
  ```
  Do **not** set `BootPreference`.
- **Confidence:** high (not supported), medium (auto power-on also fires with the lid closed;
  the Apple article does not say).
- **Verify on M1:** yes. `pmset -g cap | grep -w autorestart; nvram BootPreference`
  (expect: no output, then "data was not found").

### 1c. `pmset -a disablesleep 1` (lid closed)

- **Used at:** `roles/slave/steps/15-power.sh:21-29`; `bin/af-doctor:24`;
  `local.example/machine.env:8`.
- **Status:** works (undocumented).
- **Evidence:**
  - Local `man pmset` (macOS 27.0.1): `disablesleep` is not documented.
  - Local `pmset -g` prints `System-wide power settings:` / ` SleepDisabled		0`. The awk in
    `15-power.sh:21` reads field 2 of that line. Format confirmed.
  - Community guides (2025-2026), e.g.
    https://pasqualepillitteri.it/en/news/779/disable-laptop-sleep-lid-close-ai-agents and
    https://apple.gadgethacks.com/how-to/how-to-keep-macbook-awake-with-lid-closed-3-scenarios-explained/ :
    `sudo pmset -a disablesleep 1` is the usual way to keep an Apple silicon MacBook awake with
    the lid closed and no display. `caffeinate` does not stop lid-close sleep.
  - Apple supports only clamshell mode with AC + external display + keyboard/mouse. No Apple
    document describes `disablesleep`.
- **Side effects (from the same sources, not tested here):**
  - It applies on battery too (`-a`). A pulled cable drains the battery to shutdown.
  - Less airflow with the lid closed. Watch thermals under long Xcode builds.
  - One source says the internal display can stay lit under the lid. Low confidence.
  - Persistence across reboot: sources disagree. Test it.
- **Recommended change:** keep the command. Fix the contradicting manual text at
  `roles/slave/steps/10-macos.sh:36` ("Lid: keep it open, or use a dummy HDMI plug ... clamshell
  needs a display"). Replace with:
  `manual "Lid closed needs AF_LID_CLOSED=1 (pmset disablesleep 1). Keep the charger connected: sleep is off on battery too."`
- **Confidence:** medium (works per many reports; undocumented, can change in any release).
- **Verify on M1:** yes.
  `pmset -g | grep SleepDisabled; pmset -g assertions | head -20` (lid closed, over SSH).
  After one reboot: `pmset -g | grep SleepDisabled` again (persistence).
  Thermal: `sudo powermetrics -n 1 -i 1000 --samplers smc | grep -i -E 'temp|fan'` during a build.

---

## 2. systemsetup

### 2a. `systemsetup -setrestartfreeze on`

- **Used at:** `roles/slave/steps/15-power.sh:16-17`.
- **Status:** broken (no effect on Apple silicon; error is not detected).
- **Evidence:**
  - Local: `systemsetup -getremotelogin` without root printed
    "You need administrator access to run this tool... exiting!" and returned **exit 0**.
    `systemsetup -getrestartfreeze` did the same. So `|| warn` never fires.
  - On the M1: "### Error:-99 ... InternetServices.m" with exit 0 (user report). Same -99 seen
    on Apple silicon for `-setrestartpowerfailure`:
    https://discussions.apple.com/thread/255886644 (Sequoia 15.2).
    And on Intel: https://github.com/mathiasbynens/dotfiles/issues/1030.
  - No Apple document says the setting works on Apple silicon. Apple silicon Macs restart on
    their own after a kernel panic (that is what a panic does); a hard freeze needs a power-button
    reset in any case: https://eclecticlight.co/2026/01/26/what-was-that-a-crash-freeze-or-panic/
    (2026-01-26).
- **Recommended change:** delete lines 16-17. If you want to keep it, check the output, not the
  exit code:
  ```bash
  out="$(sudo systemsetup -setrestartfreeze on 2>&1 || true)"
  [[ "$out" == *Error* || "$out" == *"administrator"* ]] && warn "restartfreeze not supported here"
  ```
- **Confidence:** medium.
- **Verify on M1:** yes. `sudo systemsetup -getrestartfreeze; echo "rc=$?"`

### 2b. Remote Login: `systemsetup -getremotelogin` / `-setremotelogin on`

- **Used at:** `roles/slave/steps/10-macos.sh:24-28` (check is now `nc -z -G 2 localhost 22`,
  set is `systemsetup`); `bin/af-doctor:25` (still uses `systemsetup -getremotelogin`
  without sudo, so it always falls through to `nc`).
- **Status:** changed (works only with Full Disk Access; failure is silent).
- **Evidence:**
  - Apple, https://support.apple.com/en-us/HT210595 (Catalina and later, still current):
    `systemsetup -setremotelogin` needs Full Disk Access for the **parent process**
    (Terminal / iTerm / sshd-keygen-wrapper), granted by hand or by MDM PPPC.
  - Local: `systemsetup` returns exit 0 even when it refuses (see 2a). So the `|| manual`
    at `10-macos.sh:27-28` never records the manual step.
  - Local `/System/Library/LaunchDaemons/ssh.plist`: label `com.openssh.sshd`,
    `Disabled = true` by default, socket-activated on port `ssh`. Remote Login on = launchd
    override "enabled" for that label.
  - Local `launchctl print-disabled system` works without root and lists overrides as
    `"label" => enabled|disabled`.
- **Recommended change:**
  - Check (no sudo):
    ```bash
    remote_login_on() {
      launchctl print-disabled system 2>/dev/null | grep -q '"com.openssh.sshd" => enabled' \
        || nc -z -G 2 127.0.0.1 22 2>/dev/null
    }
    ```
    Use it in `10-macos.sh` and `bin/af-doctor:25`.
  - Set (no Full Disk Access needed, as far as known):
    ```bash
    run sudo launchctl enable system/com.openssh.sshd
    run sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
    remote_login_on || manual "Turn on System Settings > General > Sharing > Remote Login."
    ```
  - On a fresh machine, turn Remote Login on in **System Settings** once anyway. The macOS 26+
    pre-boot FileVault SSH unlock (item 6) is tied to the Sharing setting; it is not confirmed
    that a `launchctl enable` alone is honoured there.
- **Confidence:** medium (launchctl path is widely used; not tested here on 27.x; the
  Settings toggle reflecting it is not confirmed).
- **Verify on M1:** yes.
  `launchctl print-disabled system | grep -E 'openssh|screensharing'; nc -z -G 2 127.0.0.1 22; echo $?`

---

## 3. Screen Sharing

- **Used at:** `roles/slave/steps/10-macos.sh:32` (manual step); `bin/af-attach:12` (`open vnc://`).
- **Status:** changed. CLI enable is not supported by Apple; manual step stays.
- **Evidence:**
  - Apple Remote Desktop guide, "Enable remote management",
    https://support.apple.com/guide/remote-desktop/apd8b1c65bd/mac (accessed 2026-10-27):
    in macOS 12.1 or later Screen Sharing cannot be enabled by `kickstart`; use MDM. On 10.14+
    `kickstart` gives view-only access at most.
  - Local `/System/Library/LaunchDaemons/com.apple.screensharing.plist`: label
    `com.apple.screensharing`, `Disabled = true`, socket `vnc-server` (5900).
  - CIS / DISA STIG for macOS 26 disable it with `launchctl disable system/com.apple.screensharing`
    (https://www.stigviewer.com/stigs/apple_macos_26_tahoe/2026-05-23/finding/V-277114).
    The reverse (`launchctl enable` + `bootstrap`) is used by guides such as
    https://www.techrepublic.com/article/how-to-enable-screen-sharing-on-macs-via-terminal/ ,
    but not confirmed on macOS 27.
- **Recommended change:** keep the manual step, but only record it when a read-only check fails:
  ```bash
  screen_sharing_on() {
    launchctl print-disabled system 2>/dev/null | grep -q '"com.apple.screensharing" => enabled' \
      || nc -z -G 2 127.0.0.1 5900 2>/dev/null
  }
  screen_sharing_on && ok "Screen Sharing on" \
    || manual "Turn on System Settings > General > Sharing > Screen Sharing (for simulators and permission prompts)."
  ```
  Optional experiment on the M1 (not for the script yet):
  `sudo launchctl enable system/com.apple.screensharing && sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist`.
- **Confidence:** high (kickstart is out), low (launchctl enable works on 27.x).
- **Verify on M1:** yes. `launchctl print-disabled system | grep screensharing; nc -z -G 2 127.0.0.1 5900; echo $?`

---

## 4. `scutil --set ComputerName / HostName / LocalHostName`

- **Used at:** `roles/slave/steps/10-macos.sh:11-13`.
- **Status:** works.
- **Evidence:** local `man scutil` (macOS 27.0.1): "Supported preferences include: ComputerName
  LocalHostName HostName"; "--set option requires super-user access". `scutil --get
  ComputerName` / `LocalHostName` work locally.
- **Recommended change:** make it idempotent and validate the name (LocalHostName must be a
  DNS label: letters, digits, hyphen; no dots or spaces):
  ```bash
  [[ "$AF_HOSTNAME" =~ ^[A-Za-z0-9-]{1,63}$ ]] || die "AF_HOSTNAME must be letters, digits, hyphens"
  for k in ComputerName HostName LocalHostName; do
    [[ "$(scutil --get "$k" 2>/dev/null)" == "$AF_HOSTNAME" ]] || run sudo scutil --set "$k" "$AF_HOSTNAME"
  done
  ```
- **Confidence:** high.
- **Verify on M1:** no (optional: `scutil --get LocalHostName`).

---

## 5. Software update `defaults` keys

- **Used at:** `roles/slave/steps/10-macos.sh:18-20`.
- **Status:** works; one key is missing.
- **Evidence:**
  - Local `defaults read /Library/Preferences/com.apple.SoftwareUpdate` on macOS 27.0.1 shows
    `AutomaticDownload = 1; AutomaticallyInstallMacOSUpdates = 1; ConfigDataInstall = 1;
    CriticalUpdateInstall = 1;`. The keys still exist and System Settings writes them.
  - Local `defaults read /Library/Preferences/com.apple.commerce` shows `AutoUpdate = 0;`
    (the key is still written on 27.0.1).
  - Local: `AutomaticallyInstallAppUpdates` is absent from `com.apple.SoftwareUpdate` until set.
  - CIS macOS 14 benchmark (Tenable, https://www.tenable.com/audits/items/CIS_Apple_macOS_14.0_Sonoma_v2.0.0_L1.audit:adc3117c853109c1b3435645b17a18d8):
    App Store auto-update is `com.apple.commerce AutoUpdate` (script) **or**
    `com.apple.SoftwareUpdate AutomaticallyInstallAppUpdates` (profile key). The GUI may show the
    change only after log out / in.
- **Recommended change:** write both App Store keys; pin the "keep on" keys explicitly:
  ```bash
  su=/Library/Preferences/com.apple.SoftwareUpdate
  run sudo defaults write $su AutomaticCheckEnabled -bool true
  run sudo defaults write $su AutomaticDownload -bool true
  run sudo defaults write $su AutomaticallyInstallMacOSUpdates -bool false
  run sudo defaults write $su AutomaticallyInstallAppUpdates -bool false
  run sudo defaults write $su CriticalUpdateInstall -bool true   # security responses / XProtect
  run sudo defaults write $su ConfigDataInstall -bool true       # system data files
  run sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
  ```
  With no Apple Account on the slave, App Store app updates are mostly moot.
- **Confidence:** medium-high (keys exist on 27.0.1; Apple does not document unmanaged `defaults`).
- **Verify on M1:** yes. After the step, open System Settings > General > Software Update > (i)
  and compare. Read-only: `defaults read /Library/Preferences/com.apple.SoftwareUpdate | grep -E 'Automatic|Critical|ConfigData'`

---

## 6. FileVault and reboots

- **Used at:** `docs/runbook.md:27-35`; `roles/slave/steps/10-macos.sh:33`; `docs/PLAN.md` (Phase 0).
- **Status:** changed (new remote-unlock option in macOS 26+, with a network limit).

### 6a. Pre-boot FileVault unlock over SSH

- **Evidence:**
  - Apple Platform Deployment, "Intro to FileVault",
    https://support.apple.com/guide/deployment/dep82064ec40/web (published 2026-09-17): on a Mac
    with Apple silicon and macOS 26 or later, "FileVault can be unlocked over ssh after a restart
    if Remote Login is turned on and a network connection is available."
  - Apple Platform Security (search excerpt of
    https://support.apple.com/guide/security/sec8447f5049/web, accessed 2026-10-27): pre-boot
    network must be a previously joined Wi-Fi that is open or WPA2-PSK, or open/unauthenticated
    Ethernet. 802.1X / enterprise Wi-Fi: not supported (inference).
  - Jeff Geerling, https://www.jeffgeerling.com/blog/2025/you-can-finally-manage-macs-filevault-remotely-tahoe/
    (2025-09-19): SSH in before login, give an **administrator** password, the Mac finishes boot;
    Wi-Fi did not work at first, works "as of macOS 26.5".
  - https://portal.greenmini.host/help/filevault-on-mac-servers-in-our-data-center : Remote Login
    must be on **before** the reboot; Intel Macs are not supported.
- **Network limit (important):** `tailscaled` (Homebrew service) and its state are on the
  Data volume, which is locked until unlock. So the tailnet name/IP of the slave does not answer
  pre-boot. Reach the slave's **LAN IP** from a device on the same LAN, or through a Tailscale
  **subnet router** on that LAN that advertises the LAN prefix. This is an inference from how
  FileVault works; no Tailscale doc covers it. Confidence: high for "tailscaled not running",
  medium for the subnet-router path.
- **Unknown:** after SSH unlock, does the GUI session start (user logged in), or does the Mac
  stop at the login window? Not documented. With FileVault, the normal pre-boot unlock also logs
  the user in; the SSH path may differ. GUI session matters for simulators, Chrome, LaunchAgents
  (item 10) and the keychain (item 13).

### 6b. Automatic login

- **Evidence:** System Settings shows "Automatic login can't be turned on because FileVault is
  enabled" (Apple Community, e.g. https://discussions.apple.com/thread/253371325 and Tahoe
  threads, 2025). Confirmed: impossible with FileVault on.

### 6c. `fdesetup authrestart`

- **Evidence:** local `man fdesetup` (27.0.1): `authrestart [-inputplist]
  [-delayminutes n]` "restarts the system, bypassing the initial unlock ... The command may not
  work on all systems." `supportsauthrestart` checks support. Jamf reports (2023) that on Apple
  silicon it fails for a volume-owner account that never logged in:
  https://community.jamf.com/general-discussions-2/fdesetup-authrestart-with-managed-admin-account-29253 .
  Whether the Mac then lands in the GUI session or at the login window: not documented. Unknown.

### 6d. Installing macOS updates with FileVault on Apple silicon

- **Evidence:**
  - Local `softwareupdate --help` (27.0.1): `-R | --restart`, `--agree-to-license`,
    `--stdinpass` "Password to authenticate as an owner. Apple Silicon only.",
    `--user` "Local username to authenticate as an owner. Apple Silicon only."
  - Apple deployment guide (search excerpt of https://support.apple.com/guide/deployment/dep24dbdcf9e ):
    authorizing macOS updates on Apple silicon needs a **volume owner**.
  - Jamf forum: without a volume-owner name + password, `softwareupdate` cannot install OS
    updates on Apple silicon: https://community.jamf.com/t5/jamf-pro/macos-update-from-terminal/m-p/294839 .
- **Recommended change:** replace `docs/runbook.md:31-35` with:
  ```text
  - FileVault on (macOS 26+, Apple silicon): after any reboot the Mac waits for unlock.
    Unlock it over SSH from a device on the SAME LAN (Tailscale is not up yet):
      ssh <user>@<LAN-IP>   -> enter an admin password -> the Mac finishes booting.
    Remote Login must already be on. Ethernet or a known WPA2-PSK Wi-Fi only.
  - Planned update, from the slave over SSH, while you watch:
      sudo softwareupdate -l
      sudo softwareupdate -i -a -R --agree-to-license --user "$USER" --stdinpass
    (type the password on stdin; Apple silicon needs a volume owner). Then do the LAN SSH unlock.
  - `sudo fdesetup authrestart` is optional for a plain reboot; check `fdesetup supportsauthrestart` first.
  - Automatic login is impossible while FileVault is on.
  ```
  Remove "With automatic login enabled" from the FileVault-off bullet only if you keep FileVault on.
- **Confidence:** high (SSH unlock exists, auto-login impossible), medium (LAN-only reach,
  `--stdinpass` flow), low (state after unlock / authrestart).
- **Verify on M1:** yes (needs one planned reboot; all checks are read-only):
  - Before: `fdesetup status; fdesetup supportsauthrestart; sudo fdesetup list` (who can unlock),
    `diskutil apfs listUsers /` (volume owners).
  - Reboot, then from a LAN device: `ssh <user>@<LAN-IP>` -> unlock.
  - After: `stat -f %Su /dev/console` (prints the user if the GUI session is up, `root` at login
    window); `launchctl print gui/$(id -u) >/dev/null && echo gui-up`; `tailscale status`.

---

## 7. xcodes

- **Used at:** `roles/slave/steps/50-apple.sh:9-20`; `apple/xcode-version:2` (`latest`);
  `roles/slave/Brewfile:15-16`.
- **Status:** works (flags confirmed in xcodes 2.1.0); version pin should change; one check bug.
- **Evidence:**
  - xcodes 2.1.0 source, `Sources/xcodes/App.swift` at tag `2.1.0`
    (https://github.com/XcodesOrg/xcodes, released 2026-09-14): `install` has `<version>`,
    `--path` ("Local path to Xcode .xip"), `--latest`, `--latest-prerelease`, `--select`,
    `--update`, `--experimental-unxip`, `--no-superuser`, `--empty-trash`, `--directory`,
    `--use-fastlane-auth`. `--path` builds `.path(versionString, path)`, so **give a version
    with `--path`** (README example: `xcodes install 9.0 --path ~/Archive/Xcode_9.xip`).
  - `xcodes runtimes install <version>` has `--architecture arm64|x86_64|appleSilicon|universal`,
    `--keep-archive`, `--directory`.
  - Release notes: 2.1.0 "Fixes 404 login issue — Apple has changed how they log in (again)";
    2.0.2 fixed a 2FA 403. Older xcodes (the master has 1.6.0) may fail to sign in.
  - README: Apple ID needed for downloads (`XCODES_USERNAME`, `XCODES_PASSWORD` env); the
    password is saved in the **login keychain**. This is a developer-site login, not a macOS
    Apple Account, so "no Apple Account on the Mac" is fine. 2FA code is typed interactively.
  - Local `xcodes list` (2026-10-27): newest entries `27.1 (27A9275)`,
    `27.2 Beta 3 (27B5038j)`, `27.2 Release Candidate (27B48)`. So the newest **release** is 27.1.
  - Apple, Xcode 27.1 Release Notes,
    https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes :
    "requires a Mac running macOS Tahoe 26.6 or later"; SDKs iOS 27.1 etc. Runs on macOS 27.2
    and on M1 Pro (Apple silicon).
  - Local: xcodes installs as `/Applications/Xcode-27.0.0.app`. The check
    `ls -d /Applications/Xcode*.app` at `50-apple.sh:11` also matches `/Applications/Xcodes.app`
    (the xcodes GUI app, present on the master). False positive.
- **Recommended change:**
  - `apple/xcode-version`: `27.1`.
  - `50-apple.sh:11`: `if xcodes installed 2>/dev/null | grep -q "^$ver "; then`
    (or `xcodebuild -version | head -1 | grep -qx "Xcode $ver"`).
  - Install: `run xcodes install "$ver" --select --experimental-unxip`
  - Offline path (no Apple ID on the slave): download the .xip on the master, copy it, then
    `run xcodes install "$ver" --path "$xip" --select --experimental-unxip`.
  - Make sure step 20 runs `brew upgrade xcodes` (2.1.0+).
  - Manual text (non-tty branch, line 18):
    `manual "Install Xcode: xcodes install $ver --select --experimental-unxip  (Apple Developer sign-in + 2FA), or copy the .xip and add --path <file.xip>"`
- **Confidence:** high (flags, version), medium (sign-in over SSH: the keychain save can fail
  with a locked keychain, see item 13).
- **Verify on M1:** yes. `xcodes version; xcodes list | tail -8; sw_vers -productVersion`

---

## 8. xcodebuild and DevToolsSecurity

- **Used at:** `roles/slave/steps/50-apple.sh:22-35`; `apple/runtimes.txt`.
- **Status:** works; `-architectureVariant` exists.
- **Evidence:**
  - Local `xcodebuild -help` (Xcode 27.0):
    `xcodebuild -downloadPlatform <iOS|watchOS|tvOS|visionOS> [-exportPath <destinationpath> -buildVersion <osversion> -architectureVariant <universal|arm64>]`,
    `-downloadAllPlatforms`, `-importPlatform`, `-license`, `-checkFirstLaunchStatus`,
    `-runFirstLaunch` (+ `-checkForNewerComponents`).
  - Apple, "Downloading and installing additional Xcode components",
    https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components
    (accessed 2026-10-27): on Apple silicon Xcode downloads the **Apple silicon variant by
    default** "to save disk space"; universal only with `-architectureVariant universal` or
    Rosetta destinations. No Apple ID / sign-in is mentioned for `-downloadPlatform`.
  - Local `DevToolsSecurity -status` -> "Developer mode is currently enabled."; usage
    `DevToolsSecurity [-verbose] [-enable | -disable | -status]`.
  - The runtime check at `50-apple.sh:26-29` greps `^iOS ` in `simctl list runtimes`. Any old
    iOS runtime satisfies it, even when it does not match the selected SDK.
- **Recommended change:**
  ```bash
  run sudo xcodebuild -license accept
  xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || run sudo xcodebuild -runFirstLaunch
  DevToolsSecurity -status 2>/dev/null | grep -q enabled || run sudo DevToolsSecurity -enable
  # runtime that matches the SDK, arm64 only:
  sdk="$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null)"   # e.g. 27.1
  xcrun simctl list runtimes -j | jq -e --arg v "$sdk" \
    '.runtimes[] | select(.platform=="iOS" and .isAvailable and (.version|startswith($v)))' >/dev/null \
    || run xcodebuild -downloadPlatform iOS -architectureVariant arm64
  ```
  (`-checkFirstLaunchStatus` exit code meaning: confirm on the M1.)
- **Confidence:** high (flags), medium-high (no Apple ID needed).
- **Verify on M1:** yes. `xcodebuild -checkFirstLaunchStatus; echo $?; xcrun --sdk iphonesimulator --show-sdk-version`

---

## 9. simctl (`bin/af-sim`, `bin/af-cleanup`)

- **Used at:** `bin/af-sim:20,22,24,41,42,44,48,49`; `bin/af-cleanup:23,25`;
  `roles/slave/steps/50-apple.sh:26,37`.
- **Status:** works; the default device and runtime choice should change.
- **Evidence (all local, Xcode 27.0, `xcrun simctl help <sub>`):**
  - `list [-j | --json] ... [devices|devicetypes|runtimes|pairs]`.
  - Device JSON keys: `dataPath dataPathSize deviceTypeIdentifier isAvailable lastUsedAt logPath name state udid`.
    `.devices[][] | .name,.isAvailable,.udid` is valid.
  - Runtime JSON keys: `buildversion bundlePath identifier isAvailable isInternal lastUsage name platform runtimeRoot supportedArchitectures supportedDeviceTypes version`.
    `platform` exists (`"iOS"`). `.runtimes[] | .platform,.isAvailable,.identifier` is valid.
  - Runtimes came back sorted by version, but simctl does not promise an order; `last` relies on it.
  - `create <name> <device type id> [<runtime id>]`; device type by name is allowed
    (help example `"iPhone X"`).
  - iOS 27.0 runtime `supportedDeviceTypes` (iPhone): iPhone 18 Pro / 18 Pro Max, 17 Pro /
    17 Pro Max, 17e, Air, **17**, 16 Pro / 16 Pro Max, 16e, **16**, 16 Plus, 15..., 11.
    No base "iPhone 18". "iPhone 16" is still available.
  - `bootstatus <device> [-bcd]`, `-b` boots if needed (so the `boot` at `af-sim:41` is optional).
  - `io <device> screenshot [--type=...] <file>`; `recordVideo [--codec=<h264|hevc>] [--force] <file>`
    (default hevc; writes "Recording started" to stderr; stop with SIGINT).
  - `delete <device>... | unavailable | all`; `shutdown <device> | all`.
- **Recommended change:**
  - Default device: `AF_SIM_DEVICE_TYPE` default `iPhone 17` (present in iOS 26.x and 27.x
    runtimes). Better: the identifier `com.apple.CoreSimulator.SimDeviceType.iPhone-17`
    (names can carry special characters, e.g. "iPhone Xʀ").
  - Runtime: choose the newest iOS runtime that supports the device type:
    ```bash
    runtime="$(xcrun simctl list runtimes -j | jq -r --arg d "$devtype" '
      [.runtimes[] | select(.platform=="iOS" and .isAvailable
         and any(.supportedDeviceTypes[]; .name==$d or .identifier==$d))]
      | sort_by(.version | split(".") | map(tonumber)) | last | .identifier // empty')"
    ```
  - Keep `bootstatus -b`, `io ... screenshot`, `recordVideo --codec=h264 --force`,
    `delete unavailable`, `shutdown all` unchanged.
- **Confidence:** high for Xcode 27.0; medium for 27.1 (re-check device list after install).
- **Verify on M1:** yes (after Xcode 27.1):
  `xcrun simctl list devicetypes | grep -E 'iPhone 1[6-8]'; xcrun simctl list runtimes -j | jq -r '.runtimes[]|"\(.platform) \(.version) \(.isAvailable)"'`

---

## 10. launchctl (LaunchAgents)

- **Used at:** `roles/slave/steps/90-services.sh:15-16`; `bin/af-projects:41,80`;
  `bin/af-doctor:29-30`.
- **Status:** works with a GUI session; fragile otherwise.
- **Evidence:**
  - Local `man launchctl` (27.0.1): `bootstrap | bootout domain-target [service-path ...] |
    service-target`; `gui/<uid>/[service-name]` "targets the domain based on which user it is
    associated with" (a login session); `user/<uid>` "may exist independently of a logged-in
    user"; `enable | disable` state "persists across boots"; `kickstart -k` restarts a running job.
  - "Bootstrap failed: 5: Input/output error" after a bootout: Apple Developer Forums
    https://developer.apple.com/forums/thread/774570 (2025); fixes in the wild: wait/retry after
    bootout, and `launchctl enable` a label that has a "disabled" override.
  - From SSH with no GUI login, `gui/<uid>` does not exist ("Could not find domain" /
    125 "Domain does not support specified action"):
    https://developer.apple.com/forums/thread/766489 and GitHub Actions runner reports.
    With FileVault, the GUI domain exists only after unlock **and** login (item 6).
  - Agents in `~/Library/LaunchAgents` are loaded by launchd at the next GUI login anyway.
- **Recommended change** (bash 3.2 safe):
  ```bash
  load_agent() {
    local label="$1" tmpl="$2" dst="$agents_dir/$1.plist" uid; uid="$(id -u)"
    AF_LABEL="$label" render_template "$tmpl" "$dst"
    if ! launchctl print "gui/$uid" >/dev/null 2>&1; then
      warn "no GUI session: $label loads at next login"; return 0
    fi
    if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
      run launchctl bootout "gui/$uid/$label" || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "gui/$uid/$label" >/dev/null 2>&1 || break; sleep 0.5
      done
    fi
    run launchctl enable "gui/$uid/$label"
    run launchctl bootstrap "gui/$uid" "$dst" \
      || { sleep 1; run launchctl bootstrap "gui/$uid" "$dst"; }
    ok "loaded $label"
  }
  ```
  Use the same helper in `bin/af-projects`. `launchctl print gui/<uid>/<label>` stays the check.
- **Confidence:** high (syntax), medium (the race fix; there is no Apple-documented pattern).
- **Verify on M1:** yes. Over SSH: `launchctl print gui/$(id -u) >/dev/null && echo gui-up;
  launchctl print gui/$(id -u)/local.agentfiles.health | head -20; launchctl print-disabled gui/$(id -u) | grep agentfiles`

---

## 11. OrbStack

- **Used at:** `roles/slave/steps/70-containers.sh:9-21`; `roles/slave/Brewfile:23`;
  `services/us-gateway/compose*.yaml`; `bin/af-doctor:27`; `bin/af-cleanup:31`.
- **Status:** mostly works; "start at login" is not scriptable by a documented key; tailnet-IP
  bind and TUN are unknown.
- **Evidence:**
  - OrbStack settings, https://docs.orbstack.dev/settings (accessed 2026-10-27): key
    `memory_mib` ("total amount of memory that containers and machines ... are allowed to use",
    default no more than 8 GB); unit MiB (key name; the page does not state it). "All settings
    can be changed from both the command line (`orb config`) and the app".
  - OrbStack headless, https://docs.orbstack.dev/headless : `orb` / `orb start` starts OrbStack,
    `orb stop` stops it; "can be used exclusively from the command line, without the GUI app";
    example `orb config set setup.use_admin false` (no admin prompts). Auto-update needs the GUI.
  - Homebrew cask `orbstack` 2.2.5 (local `brew info --json`): links `orb` and `orbctl` into
    `/opt/homebrew/bin`; caveat "Open the OrbStack app to finish setup."; macOS >= 14.
  - No documented config key for "Start at login" (searched docs and web). Unknown.
  - OrbStack networking, https://docs.orbstack.dev/docker/network : "To bind a port to a
    specific address instead of all interfaces, include it in the `-p` flag"
    (`-p <ip>:80:80`). Ports are exposed to LAN by default
    (`docker.expose_ports_to_lan`). A Tailscale `utun` address is not mentioned.
  - `/dev/net/tun` + `NET_ADMIN`: OrbStack runs a full Linux kernel VM; no doc or report found
    for gluetun on OrbStack. Unknown.
  - `docker info` over SSH: the docker CLI uses the `orbstack` context socket in the user's home;
    nothing in the docs needs a GUI for that once OrbStack runs.
- **Recommended change:**
  - Start without the GUI (works from SSH): replace `run open -a OrbStack` at line 10 with
    `run orb start || run open -a OrbStack`.
  - Memory: keep `run orb config set memory_mib "${AF_ORB_MEMORY_MIB:-3072}"`; move 3072 into
    `config/limits.env` as `AF_ORB_MEMORY_MIB=3072` (repo rule: limits are config).
  - Start at login: keep the manual step, or add a LaunchAgent `local.agentfiles.orbstack` with
    `ProgramArguments=/opt/homebrew/bin/orb start` and `RunAtLoad=true` (loads at GUI login).
    Manual text: `manual "OrbStack: open the app once to finish setup (admin prompt), then Settings > enable 'Start at login'."`
  - Gateway start order: the tailnet port bind needs the 100.x address to exist; keep the
    existing health-check self-heal.
- **Confidence:** high (`orb start`, `memory_mib`), low (tailnet IP bind, TUN, login item).
- **Verify on M1:** yes.
  `orb version; orb config show; orb config show | grep -i -E 'login|memory'; docker context ls; docker info --format '{{.OperatingSystem}} {{.KernelVersion}}'`
  After `af gateway up`: `lsof -nP -iTCP:8888 -sTCP:LISTEN; docker logs af-us-gateway 2>&1 | grep -i -E 'tun|wireguard|error' | head`.

---

## 12. gluetun (`services/us-gateway/compose.yaml`, `bin/af-gateway`)

- **Used at:** `services/us-gateway/compose.yaml:10-26`; `services/us-gateway/compose.tailnet.yaml:8`;
  `bin/af-gateway:19-21,27-29,39-41`; `bin/af-doctor:40`.
- **Status:** works; image tag must be pinned; test can be provider-neutral.
- **Evidence:**
  - gluetun wiki, Mullvad: https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/mullvad.md :
    `VPN_SERVICE_PROVIDER=mullvad`, `VPN_TYPE=wireguard`, `WIREGUARD_PRIVATE_KEY` (base64
    `PrivateKey` from a generated config, not the "Wireguard Key" on the devices page),
    `WIREGUARD_ADDRESSES` (CIDR, **use the IPv4 one**, e.g. `<ipv4>/32`). Optional
    `SERVER_COUNTRIES`, `SERVER_CITIES`, `SERVER_HOSTNAMES`, `OWNED_ONLY`.
  - gluetun source v3.41.3, `internal/provider/mullvad/updater/api.go` + `hosttoserver.go`:
    country = Mullvad API `country_name`; city = `city_name` with commas removed.
    Mullvad API (https://api.mullvad.net/www/relays/wireguard/, fetched 2026-10-27): US relays
    have `country_name = "USA"`; cities like "New York, NY" -> gluetun value **"New York NY"**.
    So `SERVER_COUNTRIES=USA` is correct; a city filter must be e.g. `SERVER_CITIES=New York NY`.
  - Empty `SERVER_CITIES:` is passed as an empty string; gluetun reads CSV env vars, empty = no
    filter (expected; confirm in logs).
  - gluetun wiki, HTTP proxy: https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/http-proxy.md :
    `HTTPPROXY` default `off`; `HTTPPROXY_LISTENING_ADDRESS` default `:8888`; also
    `HTTPPROXY_USER`, `HTTPPROXY_PASSWORD`, `HTTPPROXY_STEALTH`, `HTTPPROXY_LOG`.
  - Tags (Docker Hub API, 2026-10-27): `v3.41.3`, `v3.41`, `v3` all pushed 2026-07-30;
    `latest` pushed **2026-10-19** -> `latest` tracks the development branch, not the release.
    GitHub latest release: `v3.41.3` (2026-07-30).
  - Release notes v3.40.0-v3.41.x (https://github.com/qdm12/gluetun/releases): role-based
    control-server auth; `HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE`; DNS env renames (old names
    still accepted); default `WIREGUARD_MTU` 1400 -> 1320.
  - Control server wiki: https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/control-server.md :
    port `8000`; `GET /v1/publicip/ip`; "All routes are now private by default and require
    authentication"; auth file `/gluetun/auth/config.toml`
    (`HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH`). One route can be opened:
    ```toml
    [[roles]]
    name = "publicip"
    routes = ["GET /v1/publicip/ip"]
    auth = "none"
    ```
  - Response fields (source `internal/models/publicip.go`, v3.41.3): `public_ip`, `region`,
    `country`, `city`, `hostname`, `location`, `organization`, `postal_code`, `timezone`.
    With the default ipinfo lookup, `country` is the full name: code `us` -> **"United States"**
    (`internal/constants/countries.go`).
  - Local check of `am.i.mullvad.net/json` keys: `blacklisted city country ip latitude longitude
    mullvad_exit_ip mullvad_exit_ip_hostname mullvad_server_type organization`; US exit shows
    `"country": "USA"`. The current `af gateway test` regex `United States|USA` covers both.
- **Recommended change:**
  - `compose.yaml:10`: `image: qmcgaw/gluetun:v3.41.3` (update deliberately).
  - Provider-neutral test, two options:
    1. Through the proxy, no gluetun auth needed:
       `curl -fsS --max-time 15 -x "http://127.0.0.1:$AF_US_PROXY_PORT" https://www.cloudflare.com/cdn-cgi/trace | grep -qx 'loc=US'`
    2. gluetun's own view: mount `services/us-gateway/auth.toml` (the role above) at
       `/gluetun/auth/config.toml:ro`, keep port 8000 **unpublished**, and run
       `docker exec af-us-gateway wget -qO- http://127.0.0.1:8000/v1/publicip/ip | jq -e '.country=="United States"'`
       (busybox `wget` in the image: verify).
    Keep the Mullvad check only when `AF_US_GATEWAY_PROVIDER=mullvad`.
  - `local.example/machine.env`: note the city format, e.g. `AF_US_GATEWAY_CITIES=""  # e.g. "New York NY,Ashburn VA"`.
- **Confidence:** high (env names, "USA", tag drift, control server path/auth), medium (empty
  `SERVER_CITIES`, busybox wget).
- **Verify on M1:** yes. `docker logs af-us-gateway 2>&1 | grep -i -E 'server|country|city|public ip' | tail`;
  `docker exec af-us-gateway sh -c 'command -v wget'`.

---

## 13. Keychain `security` (`bin/af-secret`)

- **Used at:** `bin/af-secret:19,22,23,24`; called by `bin/af-gateway:27-28`,
  `roles/slave/steps/70-containers.sh:26`.
- **Status:** works locally; over SSH and in LaunchAgents: unknown on 27.x.
- **Evidence:**
  - Local `security add-generic-password -h`: "Use of the -p or -w options is insecure.
    **Specify -w as the last option to be prompted.**" `-U` = update if it exists. So
    `add-generic-password -U -s svc -a name -w` prompts (twice: value + retype). Confirmed.
  - Local `find-generic-password -h`: `-w Display only the password on stdout`. Not found ->
    exit 44 (local probe, 15 ms). `delete-generic-password -s -a` matches the same way.
  - Local `unlock-keychain -h`: `[-hu] [-p password] [keychain]`; `-u` prompts via GUI;
    without `-p` it prompts on the terminal; "Unlocking the login keychain might succeed even if
    an incorrect password is presented".
  - Local `security show-keychain-info ~/Library/Keychains/login.keychain-db` ->
    `... no-timeout`, rc 0 (unlocked GUI session).
  - Items made by `/usr/bin/security` trust that binary in their ACL, so later reads by the same
    binary need no prompt (Apple `SecKeychainFindGenericPassword` docs: untrusted callers get a
    prompt; SSH cannot show one -> errSecInteractionNotAllowed -25308:
    https://developer.apple.com/forums/thread/97091).
  - Report for macOS 26 (single author, 2026-02-19):
    https://dev.to/euda1mon1a/macos-tahoe-broke-keychain-cli-reads-novel-findings-from-an-ai-agent-deployment-2p3o
    — `security find-generic-password -w` hangs or exits 36 over SSH and even from a
    LaunchAgent; `unlock-keychain -p` fails over SSH. Not confirmed elsewhere.
- **Recommended change:**
  - Keep `af secret set` as is (prompt keeps the value out of `ps`).
  - Add a guard with a timeout for reads, so a hang does not block `af gateway up` /
    `af health` (bash 3.2 has no `timeout`; use perl):
    ```bash
    get) perl -e 'alarm 10; exec @ARGV' security find-generic-password -s "$svc" -a "${name:?name}" -w \
           || die "Keychain read failed (locked? over SSH run: security unlock-keychain ~/Library/Keychains/login.keychain-db)" ;;
    ```
  - Runbook troubleshooting: "Over SSH, if `af secret get` fails: run
    `security unlock-keychain ~/Library/Keychains/login.keychain-db` (it prompts), then retry."
- **Confidence:** high (CLI syntax), low (SSH / LaunchAgent behaviour on 27.x).
- **Verify on M1:** yes (a test item only, no real secret):
  - Over SSH: `security show-keychain-info ~/Library/Keychains/login.keychain-db; echo rc=$?`
  - `af secret set probe/test` (type any value), then `time af secret get probe/test`,
    then `af secret rm probe/test`. Repeat once from Screen Sharing Terminal, once over SSH.
  - From the health LaunchAgent: check `~/.agentfiles/logs/health.err.log` for keychain errors.

---

## 14. Homebrew names and Tailscale daemon

- **Used at:** `Brewfile:4-7`; `roles/slave/Brewfile:5-27`; `roles/master/Brewfile:3-4`;
  `roles/slave/steps/30-tailscale.sh:9-10`.
- **Status:** works. All names exist; none deprecated or disabled.
- **Evidence (local `brew info --json=v2`, 2026-10-27, API data):**

  | Type | Token | Version | Notes |
  |---|---|---|---|
  | cask | `claude` | 4.29.0 | macOS >= 13, auto_updates |
  | cask | `claude-code` | 2.1.308 | binary cask |
  | cask | `tailscale-app` | 1.104.2 | old token `tailscale`; pkg; macOS >= 13 |
  | cask | `orbstack` | 2.2.5 | macOS >= 14; caveat "Open the OrbStack app to finish setup." |
  | cask | `google-chrome` | 156.0.8078.48 | auto_updates |
  | cask | `aldente` | 1.40 | macOS >= 12 |
  | formula | `tailscale` | 1.104.2 | service `require_root: true`, runs `tailscaled`, KeepAlive |
  | formula | `mosh` | 1.4.0 | |
  | formula | `xcodes` | 2.1.0 | (master has 1.6.0: upgrade) |
  | formula | `aria2` | 1.37.0 | |
  | formula | `gitleaks` | 8.30.1 | |
  | formula | `shellcheck` | 0.11.0 | |
  | formula | `yq` | 4.54.1 | |
  | formula | `jq` | 1.8.2 | |

  Also confirmed: `tmux` 3.8.
- **Tailscale daemon evidence:**
  - Formula caveat (local): "To start tailscale now and restart at startup:
    `sudo brew services start tailscale`".
  - Tailscale wiki, https://github.com/tailscale/tailscale/wiki/Tailscaled-on-macOS :
    `brew install --formula tailscale`, `sudo brew services start tailscale`, `sudo tailscale up`;
    alternative `sudo tailscaled install-system-daemon`. "tailscaled on macOS is less tested";
    uses a `utun` TUN device; "MagicDNS works, but you need to set <Tailscale quad-100 address> as your DNS
    server yourself" (it does not change system DNS).
  - Tailscale KB "macOS variants", https://tailscale.com/kb/1065/macos-variants (validated
    2026-01-05): "Run before login": standalone **no**, App Store **no (sandboxed)**,
    `tailscaled` **yes**. `tailscaled` lacks: GUI, MDM, auto-update, complete Taildrop, **using**
    exit nodes (can advertise), macOS VPN-settings management, system extension. The
    standalone app lacks Funnel and the Tailscale SSH server. So the standalone app's system
    extension does **not** run before login.
- **Recommended change:** none for names. Add `brew upgrade xcodes` (or `brew bundle` upgrades)
  so 2.1.0+ is used. Keep the formula on the slave. Remember: "before login" still means
  "after FileVault unlock" (item 6).
- **Confidence:** high.
- **Verify on M1:** yes. `brew bundle check --file roles/slave/Brewfile --verbose; sudo brew services list | grep tailscale; ls /Library/LaunchDaemons | grep -i tailscale`

---

## 15. `tailscale up --hostname` and tags

- **Used at:** `roles/slave/steps/30-tailscale.sh:17,19,21`.
- **Status:** works; re-runs need care.
- **Evidence:**
  - Tailscale KB "tailscale up", https://tailscale.com/kb/1241/tailscale-up (validated
    2026-01-26): `--hostname` sets the device name (also the MagicDNS name);
    `--advertise-tags` needs you in `tagOwners`; `--auth-key` accepts `file:<path>`.
    "Flags are not persisted between runs; you must specify all flags each time." `--reset`
    resets unspecified settings.
  - Tailscale CLI KB, https://tailscale.com/kb/1080/cli (validated 2026-07-30):
    `tailscale set --hostname=...` "does not require the complete set of desired settings".
  - Tailscale KB "Tags", https://tailscale.com/kb/1068/tags (validated 2025-12-04): tag must
    exist in `tagOwners`; you must be a tag owner (Owners/Admins/Network admins can apply any
    tag); or use an auth key with pre-assigned tags. Tagged devices: **key expiry disabled by
    default**; tagging **removes the user identity** from the device.
- **Recommended change:**
  - First login: `run sudo tailscale up --hostname="$AF_HOSTNAME" ${AF_TAILSCALE_TAGS:+--advertise-tags="$AF_TAILSCALE_TAGS"}`
    with `AF_TAILSCALE_TAGS=""` in `local.example/machine.env` (e.g. `tag:agent-host`).
  - Later name changes: `sudo tailscale set --hostname="$AF_HOSTNAME"` (not `up`).
  - Manual text when tags are used:
    `manual "Tailscale admin: add \"tag:agent-host\": [\"autogroup:admin\"] to tagOwners and grant your devices access to tag:agent-host in the policy. Tagged devices do not expire."`
    Keep the "disable key expiry" step only for untagged use.
- **Confidence:** high.
- **Verify on M1:** yes. `tailscale status --self --json | jq '.Self | {HostName, DNSName, Tags, KeyExpiry}'`

---

## 16. PATH for non-interactive SSH commands (`af attach`)

- **Used at:** `bin/af-attach:16,18`; also every `ssh agent <cmd>` from the master
  (`bin/af-doctor:39`).
- **Status:** broken when the slave's login shell is zsh and Homebrew is set in `~/.zprofile`.
- **Evidence:**
  - Local `man zsh` (STARTUP/SHUTDOWN FILES): always `/etc/zshenv` then `$ZDOTDIR/.zshenv`;
    only for **login** shells `/etc/zprofile` and `.zprofile`; only for **interactive** shells
    `.zshrc`. `ssh host cmd` runs `$SHELL -c cmd`: non-login, non-interactive -> only `.zshenv`.
  - Local `/etc/zprofile` runs `/usr/libexec/path_helper` -> login shells only. Homebrew's
    installer tells you to put `brew shellenv` in `~/.zprofile`. So `/opt/homebrew/bin` is
    missing for `ssh host tmux`.
  - Local `/etc/ssh/sshd_config.d/100-macos.conf`: `AcceptEnv LANG LC_*` only;
    `PermitUserEnvironment no` (default). So `SetEnv PATH=...` on the client is dropped, and
    `~/.ssh/environment` is ignored.
  - mosh.org FAQ, https://mosh.org/ : "mosh-server not found" — the server "is expected to be
    available on your server's default login PATH ... not usually true on OS X"; fix:
    `mosh --server=/path/to/mosh-server host`. `mosh host -- cmd` runs `cmd`.
  - If the slave's login shell is fish: `fish -c` reads `config.fish` and `conf.d/*` also
    non-interactively; a `brew shellenv` line outside `status is-interactive` works.
- **Recommended change** (no dependency on the dotfiles):
  ```bash
  brew_prefix="${AF_HOST_BREW_PREFIX:-/opt/homebrew}"
  if have mosh; then
    exec mosh --server="$brew_prefix/bin/mosh-server" agent -- "$brew_prefix/bin/tmux" new -A -s "$session"
  else
    exec ssh -t agent "$brew_prefix/bin/tmux" new -A -s "$session"
  fi
  ```
  On the slave (dotfiles' job): `eval "$(/opt/homebrew/bin/brew shellenv)"` in `~/.zshenv`
  (zsh) or in `config.fish` outside the interactive block (fish).
- **Confidence:** high.
- **Verify on M1:** yes, from the master:
  `ssh agent 'echo $SHELL; echo $PATH; command -v tmux mosh-server || echo missing'`

---

## 17. Chrome profiles and proxy (`bin/af-browser`)

- **Used at:** `bin/af-browser:17-24`.
- **Status:** works; DNS/WebRTC leak hardening recommended.
- **Evidence:**
  - Chrome blog, https://developer.chrome.com/blog/remote-debugging-port (2025-03): from
    Chrome 136, `--remote-debugging-port/pipe` are ignored for the **default** data dir; a
    custom `--user-data-dir` is required for remote debugging. A custom dir is still fully
    supported; it only gets its own encryption key. No impact on `af browser` (it already uses a
    custom dir). Chrome for Testing keeps the old behaviour.
  - Chromium `net/docs/proxy.md`,
    https://chromium.googlesource.com/chromium/src.git/+show/HEAD/net/docs/proxy.md :
    "When using an HTTP proxy in Chrome, name resolution is always deferred to the proxy."
    For HTTPS the target host name is sent to the proxy in the CONNECT line.
  - Chromium SOCKS design doc,
    https://www.chromium.org/developers/design-documents/network-stack/socks-proxy/ :
    `--proxy-server` "applies to URL loads only"; other components (DNS prefetcher) "may issue
    DNS resolves directly"; fix `--host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE myproxy"`.
  - WebRTC can send UDP outside the proxy. Policy value `disable_non_proxied_udp` exists
    (Chromium `privacy.json`); the exact command-line switch name was **not** confirmed.
  - If a Chrome process with the same `--user-data-dir` already runs, a new `open -na ... --args`
    hands the URL to that process; flags such as `--proxy-server` from the second launch do not
    apply (Chromium process-singleton behaviour; not tested here).
- **Recommended change** (`us` profile):
  ```bash
  proxy_host="$(printf '%s' "$proxy" | sed -E 's#^[a-z]+://##; s#:[0-9]+/?$##')"
  args+=(--proxy-server="$proxy" --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE $proxy_host")
  ```
  Leave WebRTC as a manual check: `manual "In the 'us' Chrome profile, open a WebRTC leak test page and confirm only the VPN exit IP shows."`
  Optional: warn when the profile is already running (`pgrep -f -- "--user-data-dir=$dir"`).
- **Confidence:** high (custom dir OK, HTTP proxy resolves names), medium (prefetch leak fix),
  low (WebRTC switch).
- **Verify on M1 / master:** yes. `af browser us https://www.cloudflare.com/cdn-cgi/trace`
  -> `loc=US`; with the cable to the VPN cut, pages must fail (kill switch).

---

## 18. Pinned browsers (`roles/slave/steps/60-browsers.sh`)

- **Used at:** `roles/slave/steps/60-browsers.sh:11,15`.
- **Status:** works; `@latest` / `@stable` are not pins.
- **Evidence:**
  - npm registry (2026-10-27): `playwright` latest **1.64.1** (published 2026-10-14);
    `next` = 1.65.0-alpha. `@puppeteer/browsers` latest **3.2.6** (2026-10-22).
  - `playwright-core@1.64.1` `browsers.json`: `chromium` revision 1248 =
    **Chrome for Testing 156.0.8078.4**; `chromium-headless-shell` 156.0.8078.4; firefox 157.0;
    webkit 27.2.
  - Playwright 1.57 release notes (https://playwright.dev/docs/release-notes): Playwright runs
    on Chrome for Testing builds (headed `chrome`, headless `chrome-headless-shell`).
  - https://playwright.dev/docs/browsers : `npx playwright install <browser>`, `--only-shell`,
    `--no-shell`, `PLAYWRIGHT_BROWSERS_PATH`; default cache `~/Library/Caches/ms-playwright`;
    "Each version of Playwright needs specific versions of browser binaries".
  - Chrome for Testing dashboard, https://googlechromelabs.github.io/chrome-for-testing/ and
    `last-known-good-versions.json` (timestamp 2026-10-27): **Stable 156.0.8078.73**,
    Beta 157.0.8103.15.
  - https://pptr.dev/browsers-api : `npx @puppeteer/browsers install chrome@stable`,
    `chrome@116.0.5793.0` (exact build), `chrome@117` (milestone). The fetched page did not show
    `--path`; it is the documented CLI option for the install root in the package README/help
    (not re-confirmed here).
- **Recommended change** (put versions in a pinned file, e.g. `apple/`-style `browsers/versions`):
  ```bash
  run npx -y playwright@1.64.1 install chromium
  run npx -y @puppeteer/browsers@3.2.6 install chrome@156.0.8078.73 --path "$AF_HOME/browsers"
  ```
  Projects that use Playwright should install with **their own** Playwright version; the host
  install only warms the shared cache.
- **Confidence:** high (versions as of today), medium (`--path` spelling).
- **Verify on M1:** yes. `npx -y @puppeteer/browsers@3.2.6 install --help | grep -A1 -- --path`;
  `ls ~/Library/Caches/ms-playwright`.

---

## 19. `memory_pressure -Q` and `sysctl vm.swapusage` (`bin/af-health`)

- **Used at:** `bin/af-health:25-31`.
- **Status:** works.
- **Evidence (local, macOS 27.0.1):**
  ```text
  $ memory_pressure -Q
  The system has 38654705664 (2359296 pages with a page size of 16384).
  System-wide memory free percentage: 67%
  $ sysctl -n vm.swapusage
  total = 3072.00M  used = 1781.50M  free = 1290.50M  (encrypted)
  ```
  `awk -F': ' '/free percentage/'` gets `67%` -> `67`. The swap awk finds `used`, takes field
  +2 (`1781.50M`), strips `M`, prints `1781`. Units are always `M` with two decimals.
- **Recommended change:** none. Note: "free percentage" includes reclaimable memory; it is the
  same number Activity Monitor uses for pressure, not "unused RAM".
- **Confidence:** high.
- **Verify on M1:** no (optional: run both commands).

---

## 20. `xcode-select --install` / `xcode-select -p` on a fresh macOS 27

- **Used at:** `roles/slave/steps/00-preflight.sh:11-16`; `docs/runbook.md:4`; `README.md:23`.
- **Status:** works with a GUI session; headless needs another method.
- **Evidence:**
  - Local `man xcode-select`: `--install` "Opens a user interface dialog to request automatic
    installation of the command line developer tools." -> needs someone at the GUI
    (Screen Sharing). `-p` "Prints the path to the currently selected developer directory."
  - Local: `xcode-select -p` -> `/Applications/Xcode-27.0.0.app/Contents/Developer` (Xcode
    selected). On a fresh Mac the exit code of `-p` was not testable here.
  - Homebrew `install.sh` (HEAD, fetched 2026-10-27) does **not** trust `xcode-select -p`; it
    tests `/Library/Developer/CommandLineTools/usr/bin/git`, then installs headless:
    touch `/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress`, pick the newest
    "Command Line Tools" label from `softwareupdate -l`, `softwareupdate -i <label>`,
    `xcode-select --switch /Library/Developer/CommandLineTools`. GUI dialog is only a fallback.
- **Recommended change:**
  ```bash
  clt_ok() { [[ -x /Library/Developer/CommandLineTools/usr/bin/git ]] \
             || { d="$(xcode-select -p 2>/dev/null)" && [[ -x "$d/usr/bin/git" ]]; }; }
  if ! clt_ok; then
    ph=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    run sudo touch "$ph"
    label="$(softwareupdate -l 2>/dev/null | grep -B1 -E 'Command Line Tools' \
      | awk -F'*' '/^ *\*/ {print $2}' | sed -e 's/^ *Label: //' -e 's/^ *//' | sort -V | tail -n1)"
    [[ -n "$label" ]] && run sudo softwareupdate -i "$label"
    run sudo rm -f "$ph"
    clt_ok || { run xcode-select --install || true; die_or_warn "Finish the Command Line Tools dialog (Screen Sharing), then re-run."; }
  fi
  ```
  Note: the runbook clones the repo with `git` first, so on a fresh Mac the CLT are installed
  before bootstrap anyway (GUI dialog from `git` / `xcode-select --install`).
- **Confidence:** medium (Homebrew uses this daily; Apple does not document the placeholder file).
- **Verify on M1:** no (CLT already present). Optional: `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables`.

---

## Other findings (not in the item list)

- `systemsetup` returns exit 0 on refusal and on `Error:-99`. Fix every `systemsetup ... ||` in
  `roles/slave/steps/10-macos.sh:27` and `15-power.sh:16`.
- `bin/af-doctor:25` runs `systemsetup -getremotelogin` without sudo -> always the "administrator
  access" message. Replace with the `launchctl print-disabled` check (item 2b).
- `roles/slave/steps/50-apple.sh:11` glob `Xcode*.app` matches `Xcodes.app` (item 7).
- `roles/slave/steps/10-macos.sh:36` lid text contradicts `AF_LID_CLOSED` (item 1c).
- `roles/slave/steps/70-containers.sh:19` literal `3072` should be a variable in
  `config/limits.env` (repo rule).

---

## (a) Summary table

| # | Item | Status | Change |
|---|---|---|---|
| 1a | `pmset -c sleep 0 ... tcpkeepalive 1` | works | none |
| 1b | `pmset -a autorestart 1` on laptop | broken (unsupported) | guard with `pmset -g cap`; rely on laptop auto power-on |
| 1c | `pmset -a disablesleep 1` | works (undocumented) | keep; fix lid manual text; test thermals/persistence |
| 2a | `systemsetup -setrestartfreeze on` | broken (no-op, exit 0) | delete, or parse output |
| 2b | `systemsetup -setremotelogin` | changed (needs FDA, silent fail) | `launchctl enable/bootstrap system/com.openssh.sshd`; check via `print-disabled` |
| 3 | Screen Sharing enable | changed (kickstart out since 12.1) | keep manual; add read-only check |
| 4 | `scutil --set ...` | works | idempotent + name validation |
| 5 | update `defaults` keys | works | also write `AutomaticallyInstallAppUpdates`, keep Critical/ConfigData on |
| 6 | FileVault reboots | changed (SSH unlock 26+) | runbook: LAN-only SSH unlock; `softwareupdate -i -a -R --user --stdinpass` |
| 7 | xcodes | works | pin `27.1`; `--experimental-unxip`; `--path` needs version; fix `Xcode*.app` glob; xcodes >= 2.1.0 |
| 8 | xcodebuild / DevToolsSecurity | works | `-architectureVariant arm64`; `-checkFirstLaunchStatus`; SDK-matched runtime check |
| 9 | simctl | works | default `iPhone 17`; sort runtimes by version and device support |
| 10 | launchctl gui domain | works with GUI only | wait/enable/retry pattern; skip when no GUI session |
| 11 | OrbStack | mostly works | `orb start`; limit to `limits.env`; login item stays manual; test tailnet bind + TUN |
| 12 | gluetun | works | pin `v3.41.3`; neutral test via `cdn-cgi/trace loc=US` or control server with route role |
| 13 | `security` keychain | works locally; SSH unknown | timeout on reads; unlock hint |
| 14 | Homebrew names / tailscaled | works | upgrade xcodes; nothing else |
| 15 | `tailscale up` / tags | works | optional `--advertise-tags`; later changes with `tailscale set` |
| 16 | SSH PATH | broken (zsh, `.zprofile`) | absolute paths + `mosh --server=` |
| 17 | Chrome proxy profile | works | add `--host-resolver-rules`; WebRTC manual check |
| 18 | Playwright / CfT pins | works (not pinned) | `playwright@1.64.1`, `@puppeteer/browsers@3.2.6`, `chrome@156.0.8078.73` |
| 19 | `memory_pressure` / `vm.swapusage` | works | none |
| 20 | `xcode-select` | works with GUI | headless CLT via `softwareupdate`; check CLT by file |

## (b) Only verifiable on the M1

All read-only (sudo where marked). Run over SSH unless noted.

```bash
# 1 power
pmset -g cap; pmset -g custom | awk '/AC Power/,0'; pmset -g | grep SleepDisabled
pmset -g cap | grep -w autorestart; nvram BootPreference
pmset -g assertions | head -20                       # lid closed
# after one reboot:
pmset -g | grep SleepDisabled
# 2 systemsetup / Remote Login / 3 Screen Sharing
sudo systemsetup -getrestartfreeze; echo "rc=$?"
launchctl print-disabled system | grep -E 'openssh|screensharing'
nc -z -G 2 127.0.0.1 22; echo "ssh=$?"; nc -z -G 2 127.0.0.1 5900; echo "vnc=$?"
# 5 updates
defaults read /Library/Preferences/com.apple.SoftwareUpdate | grep -E 'Automatic|Critical|ConfigData'
defaults read /Library/Preferences/com.apple.commerce AutoUpdate
# 6 FileVault
fdesetup status; fdesetup supportsauthrestart; sudo fdesetup list; diskutil apfs listUsers /
# after a planned reboot + LAN SSH unlock:
stat -f %Su /dev/console; launchctl print gui/$(id -u) >/dev/null && echo gui-up; tailscale status
# 7/8 Xcode
xcodes version; xcodes list | tail -8; sw_vers -productVersion
xcodebuild -checkFirstLaunchStatus; echo "rc=$?"; xcrun --sdk iphonesimulator --show-sdk-version
# 9 simctl
xcrun simctl list devicetypes | grep -E 'iPhone 1[6-8]'
xcrun simctl list runtimes -j | jq -r '.runtimes[]|"\(.platform) \(.version) \(.isAvailable)"'
# 10 launchd
launchctl print gui/$(id -u) >/dev/null && echo gui-up
launchctl print gui/$(id -u)/local.agentfiles.health | head -20
launchctl print-disabled gui/$(id -u) | grep agentfiles
# 11 OrbStack
orb version; orb config show; docker context ls
docker info --format '{{.OperatingSystem}} {{.KernelVersion}}'
lsof -nP -iTCP:8888 -sTCP:LISTEN
# 12 gluetun
docker logs af-us-gateway 2>&1 | grep -i -E 'tun|wireguard|country|city|public ip|error' | tail -20
docker exec af-us-gateway sh -c 'command -v wget'
# 13 keychain (over SSH and from Screen Sharing Terminal)
security show-keychain-info ~/Library/Keychains/login.keychain-db; echo "rc=$?"
# 14/15 Tailscale
sudo brew services list | grep tailscale; ls /Library/LaunchDaemons | grep -i tailscale
tailscale status --self --json | jq '.Self | {HostName, DNSName, Tags, KeyExpiry}'
# 16 from the master:
ssh agent 'echo $SHELL; echo $PATH; command -v tmux mosh-server || echo missing'
# 18
npx -y @puppeteer/browsers@3.2.6 install --help | grep -A1 -- --path
```

Tests that change state (do them deliberately, not from bootstrap):
`af secret set probe/test` / `get` / `rm` over SSH;
`docker run --rm --cap-add NET_ADMIN --device /dev/net/tun alpine ls -l /dev/net/tun`;
one planned reboot with LAN SSH unlock.

## (c) Cannot be scripted any more -> manual steps

Text ready for `manual "..."`:

1. `manual "Turn on System Settings > General > Sharing > Remote Login. Do it in Settings once even if SSH already works: the FileVault SSH unlock after a restart depends on it."`
2. `manual "Turn on System Settings > General > Sharing > Screen Sharing (for simulators and permission prompts)."`
   (record only when the `print-disabled` / port 5900 check fails)
3. `manual "FileVault is on: after any restart, unlock over SSH from a device on the same LAN (ssh <user>@<LAN-IP>, admin password). Tailscale is not up until the unlock. Use Ethernet or a known WPA2-PSK Wi-Fi."`
4. `manual "macOS updates: over SSH run 'sudo softwareupdate -i -a -R --agree-to-license --user \$USER --stdinpass', then unlock over LAN SSH after the restart."`
5. `manual "Install Xcode: xcodes install 27.1 --select --experimental-unxip (Apple Developer sign-in + 2FA). Without an Apple ID here: copy the .xip from another Mac and add --path <file.xip>."`
6. `manual "OrbStack: open the app once (Screen Sharing) to finish setup and approve the admin prompt, then Settings > enable 'Start at login'."`
7. `manual "Lid closed needs AF_LID_CLOSED=1 (pmset disablesleep 1). Keep the charger connected: sleep is off on battery too."`
8. `manual "AlDente: cap charging at 80% and start it at login (battery health on an always-plugged laptop)."` (unchanged; GUI app)
9. `manual "In the 'us' Chrome profile, open a WebRTC leak test page and confirm only the VPN exit IP shows."`
10. `manual "Tailscale admin: if you use tag:agent-host, add it to tagOwners and allow your devices to reach it. Tagged devices do not expire; otherwise disable key expiry for this machine."`
11. `manual "Command Line Tools: if the headless install failed, finish the 'xcode-select --install' dialog in Screen Sharing, then re-run."`
