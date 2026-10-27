# Agent host rules

You are running on a shared, always-on agent host with limited resources
(16 GB RAM, 512 GB disk). Several agents may be working at the same time.
These rules apply to every project on this machine; the project's own
CLAUDE.md and `.agent/project.yaml` add project-specific detail.

## Use the host's tools for heavy work
- Xcode builds and tests: `af build <xcodebuild args>` — never call `xcodebuild` directly.
- Simulators: `af sim run [--device "iPhone 17"] -- <command>`; inside it, `$SIM_UDID` is yours.
  Screenshots: `af sim shot out.png`. Video: `af sim record out.mp4`.
- Browsers (Playwright, Chrome): wrap the run in `af slot browser -- <command>`.
- These commands wait for a free slot. Waiting is normal; do not work around it.

## Work in your own worktree
- Create one with `af worktree new <repo> <branch>`; it prints the path. Work only there.
- Remove it with `af worktree rm <path>` when the branch is merged or abandoned.
- Never touch other worktrees, and never stop processes you did not start.

## Before heavy work
- Run `af health`. If disk is blocked, stop and report instead of cleaning other agents' files.

## Secrets and network
- Read secrets with `af secret get <name>`. Never print, log, commit or paste them into PRs.
- If a project needs US egress, its jobs get `HTTP_PROXY`/`HTTPS_PROXY` set by `af job`.
  Never change system network or VPN settings.

## Evidence in pull requests
- UI changes: attach before/after screenshots, and a short video for flows.
- State what you ran (setup, tests, validation) and the results.
- Read `.agent/project.yaml` in the repo for its `agent.setup`, `agent.test`, `agent.validate` commands.
