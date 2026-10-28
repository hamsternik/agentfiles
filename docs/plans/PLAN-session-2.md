# PLAN: session 2 — terminal environment first, then version pins

Status: **approved 2026-10-28**, in progress.
Evidence: `docs/research/RESEARCH-version-management.md`, `docs/research/RESEARCH-macos-commands.md`,
and a read of the dotfiles repo (https://github.com/hamsternik/dotfiles, public) on 2026-10-28.

Two parts, done in this order:
- **Part 1 — terminal environment**: your dotfiles and terminal tools on every agent machine,
  as early in bootstrap as possible, so you and the agents work in the same environment.
- **Part 2 — version pins (Strategy A)**: `brew bundle --no-upgrade`, `config/versions.env`,
  and an `af versions` drift report.

Every agentfiles work item is one TDD iteration (failing stub test → fix → `make lint` +
`make test` → commit). Dotfiles changes are **yours** (the repo is yours; I only list them).

---

## Part 1 — terminal environment

### Decisions (interview, 2026-10-28)

| Topic | Decision |
|---|---|
| Where in bootstrap | New step **`25-terminal`**, right after `20-homebrew`, before `30-tailscale`. The old `40-dotfiles` moves into it. |
| Packages | A new **`Brewfile.terminal`** in dotfiles (terminal tools only). Step 25 installs it with `brew bundle --no-upgrade`. |
| Login shell | **fish** for the agent user, like yours. |
| Dotfiles targets | git, tmux, nvim, vim, shell, fish + fish plugins, zsh, ssh. zsh and ssh need the dotfiles fixes below first. |
| Repo URL | Default `DOTFILES_REPO=https://github.com/hamsternik/dotfiles.git` in `local.example/machine.env` (overridable in `local/`). |

### Why step 25

- Earliest point possible: fish, tmux and neovim need Homebrew (step 20); steps 00–15 take minutes.
- Before the long and interactive steps (Tailscale login, Xcode download, browsers, OrbStack),
  so every SSH / Screen Sharing session during the rest of bootstrap already has your setup.
- `af attach` needs tmux on the slave; this step brings it.

### Prerequisites in your dotfiles (you do these)

1. **`Brewfile.terminal`**: terminal tools only, e.g. fish, fisher, tmux, neovim, bat, fd,
   ripgrep, git-delta, htop, tree, lf, gnupg, pinentry-mac, reattach-to-user-namespace. No casks.
2. **Remove `brew "neofetch"`** from `Brewfile` (gone from Homebrew; `brew bundle` fails on it;
   `fastfetch` replaces it).
3. **No hardcoded `/Users/hamsternik`**: use `$HOME` in `config.fish` (PNPM_HOME, lmstudio),
   `zshenv` (`DEVELOPER`), `zshrc`, `bashrc`, `profile`.
4. **`zshenv` safe for every zsh** (it also runs for `ssh host cmd` and scripts): no `PATH=""`
   reset, no `java_home -v 1.8` without a check, `. "$HOME/.cargo/env"` only if it exists.
   Same guard for `source "$HOME/.cargo/env.fish"` in `config.fish`.
5. **`install-ssh-conf`**: `ssh-add -l || true` (it exits 1 when the agent has no keys, which
   stops `make`).
6. **`install-fish-conf`**: create `~/.config/fish/{functions,conf.d}` itself (`mkdir -p`) instead
   of stopping; fix the `fisher` TODO in `install-fish-plugins` (fisher is a fish function: run
   it with `fish -c 'fisher install …'`).
7. **`config.fish`**: `/opt/homebrew/opt/node@20/bin` → `node@24` (Part 2 uses node@24), and keep
   the Homebrew `fish_add_path` lines outside `status is-interactive` (they are today), so
   non-interactive `ssh host cmd` finds Homebrew tools.
8. Optional: a make target `install-agent` that runs exactly the targets for an agent machine,
   so agentfiles needs only `DOTFILES_TARGETS="install-agent"`.

### agentfiles work items

1. **`roles/slave/steps/25-terminal.sh`** (replaces `40-dotfiles.sh`):
   - clone `DOTFILES_REPO` (HTTPS, no key needed) into `DOTFILES_DIR`, or `git pull --ff-only`;
   - `brew bundle --no-upgrade --file "$DOTFILES_DIR/Brewfile.terminal"`; if the file is missing,
     `die_or_warn` with the prerequisite text;
   - create the folders the make targets expect (`~/.config/fish/{functions,conf.d}`, `~/.vim`,
     `~/.ssh` with mode 700);
   - `make -C "$DOTFILES_DIR" $DOTFILES_TARGETS`;
   - login shell: add `$(brew --prefix)/bin/fish` to `/etc/shells` if missing, then
     `sudo chsh -s <fish> "$USER"` if `dscl . -read /Users/$USER UserShell` differs.
   All through `run`; dry-run stays side-effect free. Test: `tests/terminal.test.sh`.
2. **`local.example/machine.env`**: `DOTFILES_REPO` default, `DOTFILES_TARGETS` default
   (`install-git-conf install-tmux-conf install-nvim-conf install-vim-conf install-shell-conf
   install-fish-conf install-fish-plugins install-zsh-conf install-ssh-conf`), new
   `AF_LOGIN_SHELL=fish` (empty = leave the shell alone).
3. **Fish-safe remote commands.** The slave's login shell runs every `ssh host cmd`. Check every
   remote command string in `tests/e2e/remote-step.sh`, `tests/e2e/power.e2e.sh`, `bin/af-attach`,
   `bin/af-doctor` with a test that runs each through `fish -n -c` (fish 4 is on the master)
   and through `/bin/sh -n -c`. Fix any that only work in one.
4. **Master SSH alias without touching dotfiles** (`roles/master/steps/30-ssh.sh`): your
   `~/.ssh/config` starts with `Include ~/.ssh/config.local`, so step 30 adds
   `Include ~/.agentfiles/ssh_config` to `~/.ssh/config.local` (idempotent) instead of asking
   you to edit the dotfiles file. Test with a temp HOME.
5. **Docs**: PLAN (step 25, login shell), runbook (rebuild: dotfiles are applied in step 25),
   README "Relationship to dotfiles", Known gaps.

### Risks (Part 1)

- **fish as login shell**: tools that run commands through `$SHELL` may expect POSIX syntax.
  Unconfirmed: which shell Claude Code uses for its Bash tool when `$SHELL` is fish (it may
  fall back to bash or zsh). Verify on the slave.
- **ssh target** replaces `~/.ssh/config` on the slave with your hosts; the keys it names
  (`github.hamsternik`, `github.work`) must exist there, or git over SSH fails (HTTPS via `gh`
  still works).
- `git pull --ff-only` on each run follows the dotfiles `main`: a dotfiles change applies on the
  next bootstrap run.

---

## Part 2 — version pins (Strategy A)

### Goal

A rebuild installs the **pinned** versions where a tool can pin them, and `af versions`
**fails** when anything else differs from the recorded versions. Versions change only on
purpose: you upgrade, record, and commit.

### Decisions (interview, 2026-10-28)

| Topic | Decision |
|---|---|
| Strategy | **A** now. B (mise, from its Homebrew formula) can replace the Homebrew CLIs later without rework. |
| Install source | Homebrew cask or formula. A native installer only after a discussion, per tool. |
| Claude Code | Stays the `claude-code` cask (not pinned; in the snapshot). |
| Node | `node@24` (LTS line; patch versions move). Keg-only, so step 20 force-links it. |
| Playwright, Chrome for Testing | No Homebrew package: **removed** from the host. Projects install their own Playwright browsers (`agent.setup`); validation uses the Homebrew `google-chrome`. |
| Drift | Snapshot file per role, committed. Any difference **fails** `af versions` and `af doctor`. |
| Self-updating casks | `auto_updates` casks (Chrome, Claude desktop, OrbStack, AlDente; Tailscale app on the master) are **left out** of the snapshot. |
| Upgrades | Manual: `brew upgrade <name>`, then `af versions --record`, then commit the diff. |
| Renovate | Later. `config/versions.env` lines carry `# renovate:` comments. |

### What gets pinned, and how

| Component | Pin | Where | Installer | Verifier |
|---|---|---|---|---|
| Xcode | version **and** build: `27.1` / `27A9275` | `config/versions.env` | `xcodes install <version>` | build from `xcodebuild -version` |
| iOS simulator runtime | build `24A94425` (iOS 27.1) | `apple/runtimes.txt` (`iOS 24A94425`) | `xcodes runtimes install <build>`, fallback `xcodebuild -downloadPlatform` | `xcrun simctl runtime list -j` `.build` |
| xcodes | minimum `2.1.0` | `config/versions.env` | Homebrew formula | `xcodes version` |
| gluetun | `v3.41.3@sha256:fa19cc76…` | `services/us-gateway/compose.yaml` | `docker compose` | digest of the running image |
| Homebrew formulae + non-auto-updating casks (incl. `Brewfile.terminal`) | recorded | `config/brew-versions.<role>.txt` | `brew bundle --no-upgrade` | `brew list --versions` vs snapshot |
| Node | major line `24` | `roles/slave/Brewfile` (`node@24`) | Homebrew | part of the snapshot |

Not pinned, not checked: macOS, the Command Line Tools (shown as information), `auto_updates` casks.

### Work items (Part 2)

1. **No silent upgrades**: `brew bundle --no-upgrade` in step 20 (slave), step 10 (master),
   step 25 (`Brewfile.terminal`) and `make deps`.
2. **Node 24**: `node` → `node@24`; step 20 runs `brew link --overwrite --force node@24` when
   `node` does not resolve to it.
3. **`config/versions.env`** (tracked; `.gitignore` keeps `config/*.env`), loaded by
   `af_load_config` before `local/`: `AF_XCODE_VERSION`, `AF_XCODE_BUILD`,
   `AF_XCODES_MIN_VERSION`, each with a `# renovate:` comment. `apple/xcode-version` is removed.
4. **Xcode by version + build** (`50-apple.sh`): selected build = pin → ok; installed but not
   selected → `xcodes select`; else install (tty) or manual step; check the build after install;
   warn when xcodes is below the minimum.
5. **Runtimes by build** (`apple/runtimes.txt` = `platform build`): present when
   `simctl runtime list -j` has the build; else `xcodes runtimes install <build>`, fallback
   `xcodebuild -downloadPlatform <platform> -architectureVariant arm64`.
6. **Remove host browsers** (`60-browsers.sh`): no Playwright, no Chrome for Testing; keep the
   Chrome profile folders and the Claude in Chrome manual step.
7. **gluetun digest** in `compose.yaml`.
8. **`bin/af-versions`**: `af versions` = one line per component, exit 1 on drift (Xcode build,
   runtime builds, xcodes minimum, every formula and non-`auto_updates` cask from this role's
   Brewfiles **and** `Brewfile.terminal` vs `config/brew-versions.<role>.txt`, gluetun digest
   when Docker runs; macOS and CLT as information). `af versions --record` rewrites the snapshot
   (repo-only write) and prints the diff.
9. **`af doctor`** runs `af versions`.
10. **Docs**: PLAN decisions, runbook "Upgrade a tool" (`brew upgrade <name>` →
    `af versions --record` → commit; Xcode: edit `versions.env` → `make slave` → commit),
    README `af` table, Known gaps.

### Tests (Part 2)

- New `tests/versions.test.sh` (stubbed `brew`, `xcodebuild`, `xcrun`, `xcodes`, `docker`): all
  match, formula drift, cask drift, `auto_updates` cask ignored, Xcode build drift, missing
  runtime build, gluetun digest drift, `--record` writes only Brewfile entries.
- Updated `tests/apple.test.sh`, `tests/dry-run.test.sh`; a step-20 test for `--no-upgrade` and
  the `node@24` link.

### Risks (Part 2)

- xcodes depends on Apple's developer login (changes often). Offline route: copy the `.xip`,
  `xcodes install 27.1 --path <file>`.
- Apple may remove old runtime builds; the pin then needs a bump.
- A fresh rebuild installs that day's Homebrew versions, so the first `af versions` after a
  rebuild fails until you record or downgrade (the intended signal of Strategy A).
- `brew link --force node@24` conflicts if the unversioned `node` is also installed.
- Unconfirmed: whether the `claude-code` cask updates itself; if so, it shows as drift and we
  discuss `DISABLE_AUTOUPDATER` then.

---

## Verification (both parts)

- On the master: `make lint`, `make test`, both dry-runs (nothing changes).
- On the slave, after your dotfiles fixes: `make remote-step TARGET=agent@<host> STEP=25`, then
  check `ssh agent@<host> 'echo $SHELL; command -v tmux nvim fish'` and an `af attach` session.
- After the first full bootstrap: `af versions --record` (commit the snapshot), then
  `af versions` exits 0; any `brew upgrade` makes it exit 1 until recorded.

## Out of scope

mise (Strategy B), Renovate, pinning casks, pinning macOS or the CLT, project toolchains,
dotfiles changes themselves (yours).
