#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Project watchdogs: the start-project-watchdog skill, callable in any project.
install_watchdog_skill

# Work skills (handoff-session-context …): per work project, not at user level.
install_work_skills

# The minimal statusline for watchdogs (records the window size for the hand-off skill).
install_statusline
