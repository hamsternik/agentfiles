#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Project watchdogs: the start-project-watchdog skill, callable in any project.
install_watchdog_skill

# Work skills (handoff-session-context …): per work project, not at user level.
install_work_skills
