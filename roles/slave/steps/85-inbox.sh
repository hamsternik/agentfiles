#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Claude Inbox: the triage-inbox skill and `af inbox` for Claude sessions (docs/inbox.md).
install_inbox
