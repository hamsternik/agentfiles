# RESEARCH: exact version pins for the agent toolchain

Date: 2026-10-27. Scope: every development tool that `./bootstrap.sh slave` (and `master`)
installs. Question: which existing tools can install and hold an **exact** version, so a
rebuild on a fresh Mac gives the same toolchain? Where no tool fits, what is the smallest
own tooling?

Target ("slave"): MacBook Pro M1 Pro, macOS 27.2. Research machine ("master"): M4 Max,
macOS 27.0.1, Homebrew 7.0.11, xcodes 1.6.0, Xcode 27.0 (27A266a). No mise, aqua, Nix,
devbox, pkgx or Renovate on the master.

Read this with `RESEARCH-macos-commands.md` items 7, 8, 12, 14, 18 (same date).

How to read this:
- "Local" = a read-only command on the master on 2026-10-27 (`brew info`, `--help`, reading
  Homebrew's own Ruby source under `$(brew --repository)/Library/Homebrew`, `curl` of public
  JSON). Nothing was installed, upgraded or uninstalled.
- "Unconfirmed" = a claim that no primary source or local test showed. Test it on the M1.
- One side effect: `brew extract --help` turns on Homebrew **developer mode** by itself (it is
  a developer command). I turned it off again with `brew developer off`
  (`brew developer` -> "Developer mode is disabled."). Steps must never call `brew extract`
  or `brew version-install` by accident: developer mode makes `brew update` follow `main`
  instead of the stable tag.

---

## Summary

1. **Homebrew cannot install an exact version.** No `brew install foo@1.2.3`; casks have no
   version flag; `Brewfile.lock.json` was removed (Nov 2024). Homebrew can only *hold* what is
   installed (`brew pin`, `HOMEBREW_BUNDLE_NO_UPGRADE`). A rebuild gets whatever Homebrew ships
   that day.
2. **mise** (single Rust binary, no daemon, installable with `curl` before Homebrew) can pin
   exact versions, with checksums in `mise.lock`, for: Node.js, npm CLIs (Playwright,
   `@puppeteer/browsers`), gh, gitleaks, shellcheck, yq, jq, xcodes, tmux. It cannot do
   Xcode, simulator runtimes, casks, git, mosh (only via conda), aria2 or the `tailscaled` daemon.
3. **xcodes** pins Xcode by version string (`27.1`); the build (`27A9275`) needs an own check.
   `xcodes runtimes install` accepts a runtime **build** (`24A94425`) as the identifier (source).
4. **Chrome for Testing**: `@puppeteer/browsers install chrome@<exact build>` is the only
   maintained manager. No Homebrew cask and no mise/aqua registry entry exist.
5. **Docker**: pin `image: name:tag@sha256:<digest>`. Renovate and Dependabot both update it.
6. **Keeping pins current**: Renovate (free hosted app for private repos) covers `mise.toml`,
   `mise.lock`, compose digests, GitHub Actions, and any own pin file through regex managers.
   Dependabot covers only GitHub Actions and Docker here. Neither updates a Brewfile.
7. **Self-updating apps**: pin only Claude Code (native installer + exact version + updates
   off). Real Chrome, Claude desktop, OrbStack, Tailscale app, AlDente: record the version,
   do not pin.

Recommendation: **Strategy B** (mise for Node/npm/CLIs, xcodes for Xcode/runtimes, one
`config/versions.env` for the rest, Homebrew only for what mise cannot do, Renovate to propose
bumps). See the end of the document.

---

## 0. The model: pin file -> installer -> verifier -> updater

A "pin" has four parts. A component is fully solved only when all four exist.

| Part | Question | Example |
|---|---|---|
| Pin file | Where is the exact version written, in git? | `mise.toml` + `mise.lock`, `config/versions.env` |
| Installer | Which tool installs *that* version on a fresh Mac? | `mise install --locked`, `xcodes install 27.1` |
| Verifier | How does a re-run know the installed version is right? | `xcodebuild -version` build = `27A9275` |
| Updater | Who proposes the next version as a PR? | Renovate |

Current state in the repo (commit `6c1098e`):

| Component | Pin file | Installer | Pinned? |
|---|---|---|---|
| Xcode | `apple/xcode-version` = `latest` | `xcodes install --latest` | no |
| Simulator runtimes | `apple/runtimes.txt` = `iOS` | `xcodebuild -downloadPlatform iOS` | no |
| Node, Python | `roles/slave/Brewfile` (`node`, `python`) | `brew bundle` | no |
| Playwright + browsers | none | `npx -y playwright@latest install chromium` | no |
| Chrome for Testing | none | `npx -y @puppeteer/browsers install chrome@stable` | no |
| CLI formulae | `Brewfile`, `roles/*/Brewfile` | `brew update && brew bundle` (upgrades by default) | no |
| Casks | `roles/*/Brewfile` | `brew bundle` | no |
| gluetun | `services/us-gateway/compose.yaml` = `:latest` | `docker compose` | no |
| GitHub Actions | `.github/workflows/ci.yml` (`@v4`, `@v2`) | GitHub | major tag only |

---

## 1. Xcode

- **Used at:** `apple/xcode-version`; `roles/slave/steps/50-apple.sh:9-20`.
- **Candidates:**
  - **xcodes CLI** (https://github.com/XcodesOrg/xcodes, release 2.1.0 on 2026-09-14; Homebrew
    core formula `xcodes` 2.1.0). Install, list, select, uninstall, runtimes. Signs in to the
    Apple Developer site (Apple ID + 2FA, password kept in the login keychain).
  - **Xcodes.app** (https://github.com/XcodesOrg/XcodesApp, v4.1.1b41 on 2026-09-14). GUI on the
    same XcodesKit. Not scriptable. Not needed on the slave.
  - **fastlane `xcodes` action** (https://docs.fastlane.tools/actions/xcodes/, accessed
    2026-10-27). Wraps the xcodes CLI; reads `.xcode-version` when `version` is omitted. Needs Ruby;
    no gain for a bash repo.
  - **xcode-install gem / `xcversion`**: legacy, named as such in xcodes' `XCODE_VERSION.md`.
  - **xcenv**: not found in any primary source fetched today. Treat as not relevant (unconfirmed).
- **Exact pin possible?** Version: yes. Build: only by own check.
  - `xcodes install <version>` takes a version string: `27.1`, `11 Beta 7`, `11.2 GM seed`
    (local `xcodes install --help`). Source 2.1.0 `Sources/XcodesKit/XcodeInstaller.swift` parses
    it with `Version(xcodeVersion:)`; tests show only version + prerelease labels. No build
    argument. Apple ships one build per release version in normal cases (xcodereleases.com:
    `27.1 Release` = `27A9275`, 2026-10-15; `27.1 RC 1` = also `27A9275`), so version = build in
    practice. A re-release with a new build would be silent: verify the build after install.
  - Install path: `/Applications/Xcode-27.1.0.app` (README sample `Xcode-11.2.0.app`; local
    `xcodes installed` -> `27.0 (27A266a) (Selected)  /Applications/Xcode-27.0.0.app`). Several
    versions live side by side; `xcodes select <version>` switches (`xcode-select -s`).
  - Offline / no Apple ID on the slave: `xcodes install 27.1 --path Xcode_27.1.xip` (item 7).
- **`.xcode-version` convention** (`XCODE_VERSION.md` at tag 2.1.0, fetched 2026-10-27): plain
  text, one version string, file next to the project; read by xcodes CLI, xcode-install, fastlane.
  No build numbers in the spec. It advises non-beta versions: Apple may remove pre-releases.
  - `xcodes select` with no argument reads `.xcode-version` in the **current directory**
    (local `xcodes select --help`). The 2.1.0 source also wires a version-file service into
    `install` resolution; whether `xcodes install` with no argument reads it: unconfirmed.
  - For this repo the convention adds little: the host is project-agnostic, and projects may
    carry their own `.xcode-version`. Keep the host pin in the repo's own pin file.
- **Recommended:**
  - Pin version **and** build: `AF_XCODE_VERSION=27.1`, `AF_XCODE_BUILD=27A9275`.
  - Pin xcodes itself (2.1.0+; 1.6.0 fails today: local `xcodes runtimes` ->
    `DecodingError.dataCorrupted ... Authentication from invalid String value none`). xcodes is
    in the aqua registry (`aqua:XcodesOrg/xcodes`, asset `xcodes.zip`), so mise can pin it.
- **Bootstrap step** (bash 3.2, inside `50-apple.sh`):
  ```bash
  # config/versions.env: AF_XCODE_VERSION=27.1  AF_XCODE_BUILD=27A9275
  want="$AF_XCODE_VERSION"; build="$AF_XCODE_BUILD"
  sel_build="$(xcodebuild -version 2>/dev/null | awk '/^Build version/{print $3}')"
  if [[ "$sel_build" == "$build" ]]; then
    ok "Xcode $want ($build) selected"
  elif xcodes installed 2>/dev/null | grep -q "^$want ($build)"; then
    run xcodes select "$want"
  elif [[ -t 0 ]]; then
    run xcodes install "$want" --select --experimental-unxip
  else
    manual "Install Xcode $want ($build): xcodes install $want --select --experimental-unxip (Apple ID + 2FA), or copy the .xip and add --path <file.xip>"
    exit 0
  fi
  [[ "$AF_DRY_RUN" == 1 ]] || xcodebuild -version | grep -q "Build version $build" \
    || die_or_warn "Xcode build is not $build after install"
  ```
- **Risks:** Apple sign-in changes break xcodes (2.0.2 and 2.1.0 were login fixes). Apple
  may pull a version (rare for releases). Xcode needs a minimum macOS (27.1 needs macOS 26.6+,
  item 7). Disk: each Xcode is large (keep one, plus one during an upgrade).
- **Confidence:** high (CLI flags, file convention), medium (no build selection: read from source,
  not tested).

---

## 2. iOS simulator runtimes

- **Used at:** `apple/runtimes.txt`; `50-apple.sh:24-33`.
- **Candidates:** `xcodebuild -downloadPlatform`, `xcodes runtimes install`, `xcrun simctl runtime`.
- **Evidence:**
  - Local `xcodebuild -help` (Xcode 27.0): `-downloadPlatform <iOS|...> [-exportPath <path>
    -buildVersion <osversion> -architectureVariant <universal|arm64>]`, `-importPlatform <dmg>`.
    `-buildVersion` says `<osversion>`. Whether it also takes a build (`24A94425`): unconfirmed.
  - Apple's downloadable index (`index2.dvtdownloadableindex`, fetched 2026-10-27, read with
    `plutil`): `iOS 27.1 Simulator Runtime` version `27.1` build **`24A94425`**, arm64,
    `cryptexDiskImage`. Also `iOS 27.1 Release Candidate` = `24A94232`, `iOS 27.2` = `24B91016s`.
    So one version string can map to several builds (beta, RC, release). Version alone is not exact.
  - xcodes 2.1.0 source `RuntimeInstaller.swift`: the identifier matches
    `visibleIdentifier == identifier || simulatorVersion.buildUpdate == identifier`. So
    `xcodes runtimes install 24A94425` selects the **exact build**. For `cryptexDiskImage`
    runtimes (all iOS 27.x) xcodes hands the download to `xcodebuild` (Xcode 16.1+ path).
  - Local `xcrun simctl help runtime`: `add <dmg>`, `delete (<id>|--notUsedSinceDays|--unusable|--outdated) [--dry-run]`,
    `list -j`, `match list` (SDK build -> runtime build mapping), `verify`.
    `simctl runtime list -j` has fields `build`, `version`, `platformIdentifier`, `state`.
- **Exact pin possible?** Yes, by build, through xcodes. With plain `xcodebuild`, by version only
  (build unconfirmed). Verification by build is easy (`simctl runtime list -j`).
- **Recommended:** extend `apple/runtimes.txt` to `platform build` lines and verify by build.
  Install with `xcodes runtimes install <build>`; fall back to `xcodebuild -downloadPlatform` when
  xcodes fails. Delete stale runtimes with `simctl runtime delete --outdated --dry-run` first.
- **Bootstrap step** (bash 3.2):
  ```bash
  # apple/runtimes.txt:  iOS 24A94425     # iOS 27.1, matches the Xcode 27.1 SDK
  have_build() { xcrun simctl runtime list -j 2>/dev/null | jq -e --arg b "$1" 'to_entries[] | select(.value.build==$b)' >/dev/null; }
  while read -r platform build; do
    [[ -z "$platform" || "$platform" == \#* ]] && continue
    if have_build "$build"; then ok "$platform runtime $build present"
    else run xcodes runtimes install "$build"; fi
  done < "$AF_ROOT/apple/runtimes.txt"
  xcrun simctl runtime match list   # log the SDK -> runtime mapping for the record
  ```
- **Risks:** Apple removes old beta/RC runtimes from the index; release runtimes stay longer
  (not guaranteed). Each runtime costs several GB. A runtime that does not match the Xcode SDK
  works, but `simctl runtime match` may prefer another one.
- **Confidence:** high (index data, xcodes matching code), medium (`-buildVersion` with a build).
- **Verify on M1:** `xcodes runtimes | grep '^iOS 27'`; `xcrun simctl runtime list -j | jq -r '.[] | "\(.version) \(.build)"'`.

---

## 3. Node.js and global npm CLIs

- **Used at:** `roles/slave/Brewfile:10` (`brew "node"`, unpinned); `npx -y ...@latest` in
  `60-browsers.sh`.
- **Candidates** (release dates from GitHub API, 2026-10-27):

  | Tool | Latest | Pins Node exactly | Pins global npm CLIs | Lockfile + checksums | Notes |
  |---|---|---|---|---|---|
  | **mise** (https://mise.jdx.dev) | v2026.10.21 (2026-10-27) | yes (`node = "24.22.1"`) | yes, `npm:` backend | yes, `mise.lock` (per-platform URL + sha256; npm: full dependency graph) | one binary, no daemon |
  | asdf (https://asdf-vm.com) | v0.20.2 (2026-09-22) | yes (`.tool-versions`) | via plugin `.default-npm-packages` (unconfirmed for 0.20) | no lockfile | plugin = shell scripts |
  | Volta | v2.0.2 (2024-12-05) | yes | yes | no | **unmaintained**: README notice (Nov 2025) recommends mise |
  | fnm (https://github.com/Schniz/fnm) | v1.39.0 (2026-03-06) | yes (`.node-version`) | no | no | Node only |
  | nvm (https://github.com/nvm-sh/nvm) | v0.40.8 (2026-09-21) | yes (`.nvmrc`) | `default-packages` file, no lock | no | shell function, needs sourcing |
  | Homebrew `node@24` | 24.22.1 | major line only; patch moves | no | no | local `brew info`: `node@22` deprecation_date 2026-10-30, `node@24` 2027-10-30, `node@20` disabled 2026-10-28 |

- **Evidence (mise):**
  - Node install: official binary, checked against `SHASUMS256.txt` with OpenPGP verify on by
    default; `mise lock node` records checksums (https://mise.jdx.dev/lang/node.html, 2026-10-27).
  - `~/.default-npm-packages` is deprecated (warning from 2026.11.0, ignored from 2027.11.0); use
    `"npm:<pkg>" = "<version>"` instead (same page).
  - npm backend: installs each package in its own directory with an embedded installer ("aube");
    does not need Node to install, but most CLIs need Node to run; `mise.lock` records the full
    dependency graph with a sidecar `.mise/locks/npm-<pkg>/<version>/` that must be committed;
    lifecycle scripts do not run unless listed in `allow_builds`
    (https://mise.jdx.dev/dev-tools/backends/npm.html, 2026-10-27).
  - `mise install --locked` (or `MISE_LOCKED=1`) fails when the lock has no entry for the
    platform; `mise lock --platform macos-arm64` adds entries
    (https://mise.jdx.dev/dev-tools/mise-lock.html, 2026-10-27; not marked experimental).
  - mise registry (`registry/<tool>.toml` on `main`, 2026-10-27): `playwright` -> `npm:playwright`.
- **Which Node line?** nodejs.org (2026-10-27): latest LTS **24.22.1**, latest release 26.12.1.
  Node 26 should enter LTS around now (even lines go LTS in October): unconfirmed today. Pick
  24.22.1 for the host baseline; projects pin their own Node.
- **Recommended:** mise for Node and for every global npm CLI. Remove `brew "node"` from the
  slave Brewfile (Homebrew `node` would shadow or confuse PATH).
- **Bootstrap step:** mise itself, pinned and checksum-verified, before Homebrew (step 20 or a
  new step 18). bash 3.2, no Homebrew needed:
  ```bash
  # config/versions.env:
  #   AF_MISE_VERSION=2026.10.21
  #   AF_MISE_SHA256=b20d30788a819fade398a1cb92aee56c383e3c34324162ec39fb8567dee79ba6   # mise-v2026.10.21-macos-arm64
  mise_bin="$HOME/.local/bin/mise"
  if [[ -x "$mise_bin" ]] && "$mise_bin" --version 2>/dev/null | grep -q "^$AF_MISE_VERSION "; then
    ok "mise $AF_MISE_VERSION present"
  else
    url="https://github.com/jdx/mise/releases/download/v$AF_MISE_VERSION/mise-v$AF_MISE_VERSION-macos-arm64"
    tmp="$AF_HOME/tmp/mise.$$"
    run mkdir -p "$HOME/.local/bin" "$AF_HOME/tmp"
    run curl -fsSL -o "$tmp" "$url"
    if [[ "$AF_DRY_RUN" != 1 ]]; then
      echo "$AF_MISE_SHA256  $tmp" | shasum -a 256 -c - >/dev/null || die_or_warn "mise checksum mismatch"
    fi
    run install -m 755 "$tmp" "$mise_bin"
    run rm -f "$tmp"
  fi
  export MISE_GLOBAL_CONFIG_FILE="$AF_ROOT/roles/slave/mise.toml"   # tracked file
  run "$mise_bin" install --locked
  ```
  `roles/slave/mise.toml` (sketch):
  ```toml
  [settings]
  lockfile = true

  [tools]
  node = "24.22.1"
  "npm:playwright" = "1.64.1"
  "npm:@puppeteer/browsers" = "3.2.6"
  ```
  Alternative installer: `curl -fsSL https://mise.run | MISE_VERSION=v2026.10.21 sh` (verifies
  `SHASUMS256.txt` itself; https://mise.jdx.dev/installing-mise.html). The direct download above
  keeps the expected hash in git, which is stricter.
- **PATH for agents:** non-interactive SSH and launchd jobs do not run `mise activate`. Put
  `~/.local/share/mise/shims` on PATH (same place as item 16 of the commands research).
- **Risks:**
  - mise moves fast (several releases a week; `ubi:` backend removed in 2027.1.0;
    `generate bootstrap` renamed to `generate install-script`). Pin mise itself; bump on purpose.
  - Whether `mise.lock` is written next to a config set by `MISE_GLOBAL_CONFIG_FILE`:
    unconfirmed. Fallback: keep the file at `$AF_ROOT/mise.toml` and run with `-C "$AF_ROOT"`
    after `mise trust` (project configs need trust).
  - The npm sidecar lock directory is a new mise feature: test `mise install --locked` on a
    clean user before relying on it.
- **Confidence:** high (docs), medium (global-config lock behavior).

---

## 4. Playwright and its browsers

- **Used at:** `60-browsers.sh:11` (`npx -y playwright@latest install chromium`).
- **Evidence:**
  - npm registry (2026-10-27): `playwright` latest **1.64.1** (2026-10-14), next 1.65.0-alpha.
  - https://playwright.dev/docs/browsers (2026-10-27): "Each version of Playwright needs specific
    versions of browser binaries"; `PLAYWRIGHT_BROWSERS_PATH` sets a shared install/lookup path;
    default `~/Library/Caches/ms-playwright`; Playwright **removes browsers no installed Playwright
    uses** unless `PLAYWRIGHT_SKIP_BROWSER_GC=1` or `install --no-remove`; `--only-shell` for
    headless-only. No way to choose a different browser build.
  - `playwright-core@1.64.1` `browsers.json` (item 18): chromium = Chrome for Testing
    156.0.8078.4.
- **Exact pin possible?** Yes. Pin the Playwright version; the browser builds follow it.
- **Recommended:** `"npm:playwright" = "1.64.1"` in mise; then `playwright install chromium`.
  Keep the default cache path (or set `PLAYWRIGHT_BROWSERS_PATH` once, in config, if the cache
  must move). Projects install with their own Playwright version; the host install only warms the
  cache. Because of the GC rule, a project with an older Playwright can delete nothing the host
  pin needs, and the reverse (GC keeps browsers of *any* installed Playwright). Unconfirmed: how
  GC sees a Playwright inside a mise install directory. Test with `playwright install --list`.
- **Bootstrap step:**
  ```bash
  run mise exec -- playwright install chromium   # version from mise.toml
  playwright --version 2>/dev/null | grep -q "Version $AF_PLAYWRIGHT_VERSION" || warn "playwright not $AF_PLAYWRIGHT_VERSION"
  ```
  Without mise: `run npx -y "playwright@$AF_PLAYWRIGHT_VERSION" install chromium`.
- **Risks:** npx without a lock resolves the package's dependencies fresh each time (only the
  top version is pinned). Browser downloads come from Playwright's CDN; no own checksum.
- **Confidence:** high.

---

## 5. Chrome for Testing (CfT)

- **Used at:** `60-browsers.sh:15` (`@puppeteer/browsers install chrome@stable --path ...`).
- **Candidates:**
  - **`@puppeteer/browsers`** (npm, 3.2.6, 2026-10-22). Recommended by the CfT project README
    (https://github.com/GoogleChromeLabs/chrome-for-testing, 2026-10-27). Accepts
    `chrome@<exact build>`, `chrome@<milestone>`, `chrome@stable`, `chromedriver@<build>`
    (https://pptr.dev/browsers-api). `--path` exists: `src/CLI.ts` at 3.2.6 defines
    `yargs.option('path', ...)`, plus `--base-url`, `--install-deps`, `--format`.
  - **Homebrew**: no cask (local: `brew info --cask chrome-for-testing` -> "No Cask with this name
    exists"). `chromium` cask is a different, unpinned build.
  - **mise / aqua**: no `chrome-for-testing` entry found (mise registry has only `chromedriver`
    via a vfox plugin). mise's `http:` backend could fetch the zip by URL template, but a `.app`
    bundle in a zip with spaces in the path is untested: unconfirmed.
  - **Direct download**: `https://storage.googleapis.com/chrome-for-testing-public/<version>/mac-arm64/chrome-mac-arm64.zip`
    (CfT README). JSON endpoints: `last-known-good-versions.json` (today: Stable
    **156.0.8078.73**), `known-good-versions-with-downloads.json`, per-version `<version>.json`.
    The README shows no published checksums (unconfirmed).
- **Exact pin possible?** Yes, by build, with `@puppeteer/browsers`. Integrity: no vendor hash;
  record our own sha256 at first download (trust on first use).
- **Recommended:** keep `@puppeteer/browsers`, pinned in mise, with an exact CfT build in
  `config/versions.env`.
- **Bootstrap step:**
  ```bash
  # config/versions.env: AF_CFT_VERSION=156.0.8078.73
  run mise exec -- browsers install "chrome@$AF_CFT_VERSION" --path "$AF_HOME/browsers"
  ```
- **Risks:** old CfT builds stay on the bucket for a long time but Google gives no retention
  promise (unconfirmed). `bin/af-browser` must look up the pinned build directory, not "the newest".
- **Confidence:** high (CLI), medium (retention, checksums).

---

## 6. Homebrew formulae and casks, and alternatives

### 6a. What Homebrew can and cannot do (Homebrew 7.0.11, local)

- **No exact install.** `brew install` has no version argument; for casks the manpage documents
  none (https://docs.brew.sh/Manpage, 2026-10-27). A formula version is whatever the current API
  JSON says.
- **Versioned formulae** (`node@24`, `python@3.x`): only for major/minor lines with an upstream
  release branch, at most five per formula; patch versions still move
  (https://docs.brew.sh/Versions, 2026-10-27). None exist for git, gh, tmux, jq, yq, etc.
- **`brew pin`** (local help): "preventing it from being upgraded"; now also `--cask`. Note:
  "Pinned casks with auto_updates true may update themselves outside Homebrew." Pin = hold, not
  install.
- **`brew bundle`**: "Install and upgrade (by default)". `--no-upgrade` or
  `HOMEBREW_BUNDLE_NO_UPGRADE` stops the upgrade (Manpage). `brew bundle dump` writes names, not
  versions.
- **`Brewfile.lock.json`: removed.** homebrew-bundle commit of 2024-11-26 removed generation
  ("added to support functionality that never arrived"; seen through a mirror, so medium
  confidence). Local source confirms: no `Brewfile.lock` string anywhere in
  `Library/Homebrew`; `bundle/subcommand/install.rb` still passes a dead `no_lock: false`. A
  nix-darwin user report shows `Error: invalid option: --no-lock`.
- **`brew extract` / `brew version-install`** (local source `dev-cmd/extract.rb`,
  `cmd/version-install.rb`): copies an old formula into a personal tap (`<user>/homebrew-versions`).
  It needs `homebrew/core` **cloned** (`source_tap.installed?`), which API-mode installs do not
  have, and it **removes bottle blocks** ("as they won't work") -> builds from source. Homebrew
  warns "You are responsible for maintaining this". Not fit for a bootstrap.
- **Formulae from paths are forbidden by default** (`HOMEBREW_FORBID_PACKAGES_FROM_PATHS`, "true
  unless `$HOMEBREW_DEVELOPER` is set", local `env_config.rb`). An own cask/formula file must live
  in a tap.
- **Freezing Homebrew itself**: `HOMEBREW_NO_AUTO_UPDATE`, `HOMEBREW_NO_INSTALL_UPGRADE`,
  `HOMEBREW_NO_INSTALL_FROM_API` exist (local `env_config.rb`). In theory: clone `homebrew/core`
  and `homebrew/cask` at fixed commits + `HOMEBREW_NO_INSTALL_FROM_API=1` -> fixed formula files.
  Bottles for old revisions may already be gone from the registry -> source builds. This is what
  nix-homebrew does for Homebrew and taps (it does "not manage any package installed by it").
  Unconfirmed in practice; large and fragile.
- **Casks with `auto_updates true`** (local `brew info --json=v2`, 2026-10-27): `google-chrome`
  156.0.8078.48, `claude` 4.29.0, `orbstack` 2.2.5, `tailscale-app` 1.104.2, `aldente` 1.40.
  `brew upgrade` skips them unless `--greedy`; the apps update themselves. `claude-code` 2.1.308
  has no `auto_updates`.

**Conclusion:** Homebrew is a good *installer* and a weak *pinner*. Use it with
`HOMEBREW_BUNDLE_NO_UPGRADE=1` in normal runs, an explicit upgrade command, and a drift report.

Current `20-homebrew.sh` runs `brew update` and `brew bundle` (which upgrades). So every re-run
of the bootstrap moves versions. Smallest fix, independent of the strategy:
```bash
run brew bundle --no-upgrade --file "$AF_ROOT/Brewfile"
run brew bundle --no-upgrade --file "$AF_ROOT/roles/slave/Brewfile"
# upgrades only through an explicit, logged command (e.g. `af upgrade brew`)
```

### 6b. Alternatives for CLI tools with exact versions

Coverage of the listed tools (registry files fetched 2026-10-27):

| Tool | mise (backend) | aqua registry | Homebrew only |
|---|---|---|---|
| gh | `github-cli` -> `aqua:cli/cli` | yes | |
| gitleaks | `aqua:gitleaks/gitleaks` | yes | |
| shellcheck | `aqua:koalaman/shellcheck` | yes | |
| yq | `aqua:mikefarah/yq` | yes | |
| jq | `aqua:jqlang/jq` | yes | |
| xcodes | `aqua:XcodesOrg/xcodes` | yes (`xcodes.zip`) | |
| tmux | `aqua:tmux/tmux-builds` | yes (`tmux/tmux-builds`) | (prebuilt quality unconfirmed) |
| mosh | `conda:mosh` only | no | **yes** |
| aria2 | no | no | **yes** |
| git | no | no | yes (or Apple CLT git) |
| tailscale (daemon) | no | macOS entry extracts only the GUI app's CLI, no `tailscaled` | **yes** (formula runs `tailscaled`) |
| casks | no | no | **yes** |

| Option | macOS arm64 | Maturity (2026-10-27) | Lockfile | Bootstrap fit (bash 3.2, before Homebrew) |
|---|---|---|---|---|
| **mise** | yes | very active, daily releases | `mise.lock`: version, URL, sha256 per platform | one binary via `curl`; no daemon; no root. Good |
| **aqua** (https://aquaproj.github.io) | yes | v2.65.2 (2026-10-22), stable | `aqua.yaml` pins exact versions; `aqua-checksums.json` | one binary, no deps; lazy install on first run. Good, but CLIs only (no Node runtime manager, no npm) |
| **nix-darwin + nix-homebrew** | yes | nix-darwin active (last commit 2026-10-23), branches `master`, `nix-darwin-26.05` | `flake.lock` pins nixpkgs, Homebrew and taps | needs a Nix install first (`/nix` volume, `nix-daemon`), `sudo darwin-rebuild switch`. Poor fit |
| **devbox** (https://www.jetify.com/devbox) | yes | 0.18.5 (2026-10-25) | `devbox.json` + `devbox.lock` (prior knowledge, not re-read today) | wraps Nix (needs Nix + daemon). Poor fit |
| **pkgx** (https://github.com/pkgxdev/pkgx) | yes | v2.11.0 (2026-07-22) | no lockfile documented | 4 MiB binary; pins by `pkgx node@24` in commands; breaking v1->v2 change. Weak fit |

Notes:
- mise and aqua share the aqua registry, so their coverage is the same for CLIs; mise adds Node,
  Python and npm. Running both gives no gain.
- nix-darwin's Homebrew module only generates a Brewfile and calls `brew bundle`; by default it
  does not auto-update or upgrade. It does **not** pin cask versions (search results 2026-10-27).
- `mise bootstrap` (https://mise.jdx.dev/cli/bootstrap.html) now covers whole-machine setup
  (packages, macOS defaults, launchd agents, dotfiles). It overlaps with this repo. Not
  recommended: the repo rule is bash steps with `run`/`manual`.
- Homebrew 7 `brew bundle` has an `npm` entry type (local `bundle/extensions/npm.rb`). The source
  shows no version handling: version pins there are unconfirmed. Do not use it for pins.

---

## 7. Docker images

- **Used at:** `services/us-gateway/compose.yaml:10` (`qmcgaw/gluetun:latest`).
- **Evidence:**
  - Docker Hub API (2026-10-27): tag `v3.41.3`, digest
    `sha256:fa19cc76b2af13d57a8d3dc3066f2ada061b1c761b8aecf989b3877c0486e027`, pushed 2026-07-30.
    `latest` moves with the development branch (item 12).
  - Renovate docs (https://docs.renovatebot.com/docker/, 2026-10-27): pin to `tag@sha256:...`;
    "Renovate retains the Docker tag ... for readability"; preset `docker:pinDigests`. The
    docker-compose manager matches `compose.yaml` and `compose.tailnet.yaml` by default.
  - Dependabot: `docker-compose` and `docker` ecosystems support version updates for private repos
    (GitHub docs table, 2026-10-27). Whether it bumps the digest next to a tag: unconfirmed.
- **Exact pin possible?** Yes. With `name:tag@digest`, the engine pulls by digest; the tag is a label.
- **Recommended:**
  ```yaml
  image: qmcgaw/gluetun:v3.41.3@sha256:fa19cc76b2af13d57a8d3dc3066f2ada061b1c761b8aecf989b3877c0486e027
  ```
  Get a digest by hand: `docker buildx imagetools inspect qmcgaw/gluetun:v3.41.3` (or the Docker
  Hub API as above). The digest is the multi-arch index, so it works on arm64.
- **Risks:** a digest pin also freezes security fixes; you need the updater (section 8).
- **Confidence:** high.

---

## 8. Keeping pins current

| Updater | mise.toml / mise.lock | Own pin file (`config/versions.env`, `apple/runtimes.txt`) | Compose digests | GitHub Actions | Brewfile | Cost (private repo) |
|---|---|---|---|---|---|---|
| **Renovate** (Mend hosted app) | yes: `mise` manager reads `mise.toml`, updates `mise.lock` | yes: regex `customManagers` + `customDatasources` | yes: `docker-compose` + `pinDigests` | yes | **no** (homebrew manager reads only `Formula/*.rb` in taps) | free: "free to install for both public and private repositories" (GitHub Marketplace, 2026-10-27) |
| Renovate self-hosted (GitHub Action) | same | same | same | same | no | Actions minutes; needs a token |
| **Dependabot** | not in the ecosystem table (unconfirmed absence) | no custom files | yes (`docker-compose`) | yes | no | free on github.com (not stated on the fetched page; unconfirmed) |
| `mise outdated` / `mise upgrade --bump` | local, manual | no | no | no | no | free |
| `xcodes list`, `xcodes runtimes` | | manual for Xcode / runtimes | | | | free |
| `brew outdated` | | | | | report only | free |

Evidence:
- Renovate managers list (https://docs.renovatebot.com/modules/manager/, 2026-10-27): `mise`,
  `asdf`, `homebrew`, `docker-compose`, `github-actions`, `npm`, `nix`, `devbox`, `nvm`, `regex`,
  `jsonata`. No Xcode / `.xcode-version` manager.
- Renovate mise manager (https://docs.renovatebot.com/modules/manager/mise/): backends `core`,
  `aqua`, `github`, `npm`, `ubi`, ...; "Renovate supports mise lock files (`mise.lock`)"; lock
  maintenance runs `mise lock --bump`; self-hosted needs `mise` in `allowedUnsafeExecutions`.
  Whether the hosted app runs it: unconfirmed.
- Regex manager field is `managerFilePatterns` (https://docs.renovatebot.com/modules/manager/regex/).
- Custom datasource: JSON endpoint + JSONata transform (https://docs.renovatebot.com/modules/datasource/custom/).

Data sources for own pins:
- Xcode: `https://xcodereleases.com/data.json` (community site, not Apple; versions and builds).
  Risk: third party; check the build against `xcodes list` before merging.
- iOS runtimes: Apple's `index2.dvtdownloadableindex` is a plist, not JSON; Renovate cannot read
  it directly. Bump runtimes by hand together with Xcode.
- Chrome for Testing: `https://googlechromelabs.github.io/chrome-for-testing/known-good-versions.json`.
- Playwright, `@puppeteer/browsers`: `npm` datasource (or mise manager).
- mise itself: `github-releases` datasource `jdx/mise` (the sha256 must be bumped too; Renovate
  cannot compute it -> own script or a manual step in the PR).

Example `renovate.json` fragment for `config/versions.env` (shape only; not tested):
```json
{
  "extends": ["config:recommended", "docker:pinDigests", "helpers:pinGitHubActionDigests"],
  "customManagers": [{
    "customType": "regex",
    "managerFilePatterns": ["/^config/versions\\.env$/"],
    "matchStrings": ["# renovate: datasource=(?<datasource>\\S+) depName=(?<depName>\\S+)\\n[A-Z_]+=(?<currentValue>\\S+)"]
  }],
  "customDatasources": {
    "cft": {
      "defaultRegistryUrlTemplate": "https://googlechromelabs.github.io/chrome-for-testing/known-good-versions.json",
      "transformTemplates": ["{ \"releases\": $map(versions, function($v) { { \"version\": $v.version } }) }"]
    }
  }
}
```
with lines like:
```bash
# renovate: datasource=custom.cft depName=chrome-for-testing
AF_CFT_VERSION=156.0.8078.73
```
Fit for a private personal repo: the hosted Renovate app is free and needs no workflow. Add
`"schedule": ["before 6am on monday"]` and group PRs to keep noise low. Every bump still needs a
test on the M1 (`./bootstrap.sh slave` on the real host, `tests/remote-step`).

---

## 9. Apps that update themselves

| App | Install now | Auto-update | Vendor switch | Pin on the agent host? |
|---|---|---|---|---|
| **Claude Code** | cask `claude-code` 2.1.308 | cask: none by default; native installer: background updates | `DISABLE_AUTOUPDATER=1` (stops background check) or `DISABLE_UPDATES=1` (blocks all update paths) in `settings.json` `env`; `minimumVersion`; channel `stable`/`latest`; exact install `curl -fsSL https://claude.ai/install.sh \| bash -s 2.1.89` (https://code.claude.com/docs/en/setup, 2026-10-27) | **yes**: it is the agent runtime. Exact version + updates off + bump via PR |
| Google Chrome | cask, `auto_updates` | Google updater | `/Library/Managed Preferences/com.google.Keystone.plist`: `updatePolicies` -> `global` -> `UpdateDefault` = 3 ("Updates are never applied"); `TargetVersionPrefix` pins a major (https://support.google.com/chrome/a/answer/7591084, 2026-10-27). Needs root; Google: "We do not recommend turning off browser updates." | **no**. It holds real sign-ins (Claude in Chrome). Keep it current; use CfT for pinned validation |
| Claude desktop | cask `claude`, `auto_updates` | in-app | none found | no; record version |
| OrbStack | cask, `auto_updates` | in-app | no key on https://docs.orbstack.dev/settings (2026-10-27); GUI option unconfirmed | no; record version; the pinned part is the image digest |
| Tailscale app (master) | cask `tailscale-app`, `auto_updates` | Sparkle | policy keys `SUAutomaticallyUpdate`, `SUEnableAutomaticChecks` (standalone only) in `io.tailscale.ipn.macsys` (https://tailscale.com/kb/1315/device-management); values unconfirmed | no; personal laptop. The slave uses the formula (no auto-update, item 14) |
| AlDente | cask, `auto_updates` | in-app | not checked | no |

Claude Code sketch (step 80):
```bash
# config/versions.env: AF_CLAUDE_CODE_VERSION=2.1.308
if claude --version 2>/dev/null | grep -q "^$AF_CLAUDE_CODE_VERSION "; then ok "claude $AF_CLAUDE_CODE_VERSION"
else run /bin/bash -c "curl -fsSL https://claude.ai/install.sh | bash -s $AF_CLAUDE_CODE_VERSION"; fi
# and "env": {"DISABLE_UPDATES": "1"} in ~/.claude/settings.json (merge with jq, never overwrite)
```
Drop `cask "claude-code"` then: two installs of `claude` on PATH conflict. Risk: an old Claude
Code may not support a new model (docs: a new model "can require a Claude Code version newer
than the stable channel serves"). Bump often. Releases from 2.1.89 have a signed
`manifest.json` with sha256 per platform: a stricter step can verify it.

---

## (a) Comparison table

| Component | Recommended tool | Pin file | Verify | Update path |
|---|---|---|---|---|
| mise itself | direct GitHub download + sha256 | `config/versions.env` (`AF_MISE_VERSION`, `AF_MISE_SHA256`) | `mise --version` | Renovate `github-releases` + hand-updated sha |
| Xcode | xcodes (pinned in mise) | `config/versions.env` (`AF_XCODE_VERSION`, `AF_XCODE_BUILD`) | `xcodebuild -version` build | Renovate `custom.xcode` (xcodereleases) or manual + `xcodes list` |
| iOS runtimes | `xcodes runtimes install <build>` | `apple/runtimes.txt` (`iOS 24A94425`) | `simctl runtime list -j` `.build` | manual, with each Xcode bump |
| Node.js | mise `core:node` | `roles/slave/mise.toml` + `mise.lock` | `mise install --locked` | Renovate `mise` manager |
| Playwright + browsers | mise `npm:playwright` | `mise.toml` + `mise.lock` | `playwright --version` | Renovate `mise` manager |
| Chrome for Testing | `@puppeteer/browsers` (mise `npm:`) | `config/versions.env` (`AF_CFT_VERSION`) | path `$AF_HOME/browsers/chrome/mac_arm-<build>` exists (layout unconfirmed) | Renovate `custom.cft` |
| gh, gitleaks, shellcheck, yq, jq, tmux | mise `aqua:` | `mise.toml` + `mise.lock` | `mise install --locked` | Renovate `mise` manager |
| git, mosh, aria2, tailscale, python | Homebrew formula | Brewfile (names) + drift report | `brew list --versions` vs record | manual `af upgrade brew` |
| Casks (orbstack, chrome, claude, aldente, tailscale-app) | Homebrew cask, not pinned | Brewfile (names) | record version only | the apps / `brew upgrade --greedy` by hand |
| Claude Code | native installer, exact version, `DISABLE_UPDATES` | `config/versions.env` (`AF_CLAUDE_CODE_VERSION`) | `claude --version` | Renovate regex (`npm` datasource `@anthropic-ai/claude-code`, unconfirmed it tracks the same versions) |
| gluetun | compose `tag@sha256` | `services/us-gateway/compose.yaml` | `docker image inspect` | Renovate `docker-compose` (or Dependabot) |
| GitHub Actions | SHA pins | `.github/workflows/ci.yml` | | Renovate / Dependabot |

---

## (b) Strategy options

### A. Homebrew + small pin files + drift report + Renovate regex

Keep Homebrew for everything it installs today. Add `config/versions.env` for Xcode, runtimes,
Playwright, CfT, Claude Code, and use `npx -y pkg@<exact>`. Stop `brew bundle` upgrades. A new
`af versions` prints installed vs pinned and fails on drift.

- Pros: smallest change; no new tool; all steps stay bash.
- Cons: Homebrew items are **not** reproducible: a rebuild gets today's versions; the pin file
  only detects drift. `npx` pins only the top package. Node patch versions move.
- Effort: ~0.5-1 day.
- Fit: full (bash, `run`, idempotent). Nothing new before Homebrew.

### B. mise for Node / npm / CLIs + xcodes for Apple + Homebrew for the rest (recommended)

mise (pinned binary, sha256 in git) installs Node, Playwright, `@puppeteer/browsers`, gh,
gitleaks, shellcheck, yq, jq, xcodes, tmux from `mise.toml` + `mise.lock` with `--locked`.
xcodes installs Xcode and runtimes from `config/versions.env` / `apple/runtimes.txt` with a
build check. Homebrew keeps git, mosh, aria2, tailscale, python (or mise python), and all casks,
with `--no-upgrade`. Renovate proposes all bumps; `af versions` reports drift.

- Pros: real reproducibility, with checksums, for most of the toolchain; one lockfile; Renovate
  support is native; mise needs no Homebrew and no root, so it can run in an early step under
  `/bin/bash` 3.2. Projects can use the same mise for their own pins.
- Cons: one more tool on PATH (shims); mise changes fast (pin it); repo `Brewfile` (gitleaks,
  shellcheck, yq, jq for `make deps`) also moves to mise, which changes `make deps` on the
  master. Casks and Homebrew formulae stay drift-only.
- Effort: ~2-3 days including a full rebuild test on the M1.
- Fit: good. mise calls go through `run`; `mise install --locked` is idempotent; versions live in
  config files, not in scripts (same rule as `config/limits.env`).

### C. nix-darwin (+ nix-homebrew)

One flake describes the whole machine; `flake.lock` pins nixpkgs, Homebrew and taps.

- Pros: strongest lock for CLI tools; rollbacks.
- Cons: Nix needs a `/nix` APFS volume, a root daemon and `sudo darwin-rebuild`; Xcode,
  simulator runtimes and casks are still outside the lock (casks only via generated Brewfile);
  replaces the bash step model and the `run` dry-run wrapper; a large learning cost.
- Effort: 1-2 weeks (rewrite).
- Fit: poor. Breaks "bash steps, idempotent, `/bin/bash` 3.2 before Homebrew".

---

## (c) Recommendation and what stays unsolved

**Recommendation: B.** Order of work, smallest risk first:
1. `brew bundle --no-upgrade` in step 20 (stops silent upgrades today).
2. `config/versions.env` with Xcode version + build, CfT build, Claude Code version, mise
   version + sha256; `apple/runtimes.txt` with builds. Pin gluetun by digest.
   (`.gitignore` ignores `*.env` but keeps `!config/*.env`, so `config/versions.env` is tracked.
   It holds versions only, never secrets or machine values.)
3. Pinned mise in an early step; `roles/slave/mise.toml` + `mise.lock`; remove `brew "node"`.
4. `bin/af-versions` (one-line description on line 2, `af_load_config`): print pinned vs installed
   for every row of table (a); exit 1 on drift; call it from `af doctor`.
5. Renovate hosted app with `config:recommended`, `docker:pinDigests`, regex managers for
   `config/versions.env`, weekly schedule.

**Unsolved, and the smallest answer:**
- **Casks** (Chrome, Claude desktop, OrbStack, AlDente, Tailscale app): no tool installs an
  exact older cask version. Options: own tap with own cask files (version + sha256), maintained
  by hand; or accept drift and record versions. Recommended: accept drift, record, no pin.
- **Homebrew formulae** git, mosh, aria2, tailscale: exact install only through an own tap or
  frozen Homebrew taps (fragile, source builds). Recommended: `--no-upgrade` + drift report.
- **Xcode build**: xcodes selects by version only; the build pin is our own check. Apple may
  remove downloads; keep the `.xip` on the master as an offline copy (`--path`).
- **Simulator runtimes**: no updater; bump by hand with Xcode. Availability of old builds is
  Apple's choice.
- **Chrome for Testing integrity**: no vendor checksum; record our own sha256 (TOFU) if needed.
- **mise sha256 on bump**: Renovate bumps the version but not the hash; a small
  `scripts/bump-mise.sh` or a manual PR step reads `SHASUMS256.txt`.
- **Command Line Tools and macOS itself**: Apple's Software Update decides; record
  `sw_vers` / `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables` in the drift report only.
- **Project toolchains**: out of scope by design. Projects pin their own Node/Playwright/Xcode
  (`.xcode-version`, `mise.toml`) and the host pins only its own baseline.

---

## Verify on the M1

- `xcodes version` (2.1.0+); `xcodes installed`; `xcodes runtimes | grep '^iOS 27'`.
- `xcodebuild -downloadPlatform iOS -buildVersion 24A94425 -exportPath /tmp/rt` accepts a build?
  (downloads several GB: run only when wanted).
- mise: `MISE_GLOBAL_CONFIG_FILE=... mise lock` writes `mise.lock` next to the file?
  `mise install --locked` on a clean user; `mise exec -- playwright install --list`.
- `npx -y @puppeteer/browsers@3.2.6 install --help | grep -- --path`.
- OrbStack Settings: any "check for updates automatically" switch.
- `claude doctor` after the native install shows `Auto-updates: disabled`.

---

## Sources (all accessed 2026-10-27 unless a release date is given)

- xcodes: https://github.com/XcodesOrg/xcodes (README, `XCODE_VERSION.md`, source at tag 2.1.0;
  release 2.1.0 on 2026-09-14). Xcodes.app: https://github.com/XcodesOrg/XcodesApp (v4.1.1b41, 2026-09-14).
- fastlane xcodes action: https://docs.fastlane.tools/actions/xcodes/
- Xcode releases data: https://xcodereleases.com/ and https://xcodereleases.com/data.json
- Apple simulator index: https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex
- mise: https://mise.jdx.dev/dev-tools/backends/ , /dev-tools/mise-lock.html ,
  /dev-tools/backends/npm.html , /dev-tools/backends/http.html , /lang/node.html ,
  /installing-mise.html , /cli/upgrade.html , /cli/bootstrap.html ,
  /cli/generate/install-script.html ; releases https://github.com/jdx/mise/releases (v2026.10.21,
  2026-10-27); registry https://github.com/jdx/mise/tree/main/registry
- aqua: https://aquaproj.github.io/ (v2.65.2, 2026-10-22); registry https://github.com/aquaproj/aqua-registry
- asdf v0.20.2 (2026-09-22), fnm v1.39.0 (2026-03-06), nvm v0.40.8 (2026-09-21), Volta v2.0.2
  (2024-12-05; unmaintained notice Nov 2025): GitHub release pages.
- Node.js releases: https://nodejs.org/en/about/previous-releases
- Playwright: https://playwright.dev/docs/browsers ; npm registry `playwright` (1.64.1, 2026-10-14)
- Chrome for Testing: https://github.com/GoogleChromeLabs/chrome-for-testing ;
  https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json (timestamp 2026-10-27)
- Puppeteer browsers: https://pptr.dev/browsers-api ; `@puppeteer/browsers@3.2.6` `src/CLI.ts` (unpkg)
- Homebrew: https://docs.brew.sh/Manpage , https://docs.brew.sh/Versions ; local Homebrew 7.0.11
  source; homebrew-bundle commit removing `Brewfile.lock.json` (2024-11-26, seen via mirror)
- nix-darwin: https://github.com/nix-darwin/nix-darwin (last commit 2026-10-23);
  nix-homebrew: https://github.com/zhaofengli/nix-homebrew
- devbox: https://www.jetify.com/docs/devbox/ (0.18.5, 2026-10-25); pkgx: https://github.com/pkgxdev/pkgx (v2.11.0, 2026-07-22)
- Renovate: https://docs.renovatebot.com/modules/manager/ , /modules/manager/mise/ ,
  /modules/manager/homebrew/ , /modules/manager/docker-compose/ , /modules/manager/regex/ ,
  /modules/datasource/custom/ , /docker/ , /getting-started/running/ ; app
  https://github.com/apps/renovate (renovate 44.190.0, 2026-10-27)
- Dependabot ecosystems: https://docs.github.com/en/code-security/dependabot/ecosystems-supported-by-dependabot/supported-ecosystems-and-repositories
- Docker Hub API: https://hub.docker.com/v2/repositories/qmcgaw/gluetun/tags/v3.41.3
- Claude Code setup: https://code.claude.com/docs/en/setup
- Chrome updates (Mac): https://support.google.com/chrome/a/answer/7591084
- OrbStack settings: https://docs.orbstack.dev/settings
- Tailscale system policies: https://tailscale.com/kb/1315/device-management
