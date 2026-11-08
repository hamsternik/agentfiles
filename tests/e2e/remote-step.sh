#!/usr/bin/env bash
# Try one bootstrap step from THIS working tree on a real machine, before pushing:
#   make remote-step TARGET=agent@<host> STEP=15 VARS="AF_LID_CLOSED=1"
#   tests/e2e/remote-step.sh <user@host> <step> [VAR=value ...]
#
# Copies the working tree (tracked + untracked, not ignored; no .git, no local/)
# to ~/Developer/_hamsternik/agentfiles-dev on the target, never touching its own
# clone ~/Developer/_hamsternik/agentfiles (nothing goes directly into ~).
# local/machine.env there = the target clone's local/machine.env if it has one,
# else local.example/machine.env, plus the VAR=value overrides.
# Then runs `./bootstrap.sh $ROLE --only <step>` (ROLE=slave by default;
# DRY=1 adds --dry-run). One SSH login is shared; sudo asks on the target.
set -euo pipefail
target="${1:?usage: remote-step.sh <user@host> <step> [VAR=value ...]}"
step="${2:?usage: remote-step.sh <user@host> <step> [VAR=value ...]}"
shift 2
[[ "$step" =~ ^[0-9]+$ ]] || { echo "step must be a number prefix, e.g. 15" >&2; exit 2; }
role="${ROLE:-slave}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
base="${AF_REMOTE_BASE:-Developer/_hamsternik}"      # relative to the target's home
clone="$base/agentfiles"; dev="$base/agentfiles-dev"

ssh_opts=(-o ControlMaster=auto -o ControlPath=/tmp/af-rs-%C -o ControlPersist=5m -o ConnectTimeout=10)
trap 'ssh "${ssh_opts[@]}" -O exit "$target" 2>/dev/null || true; rm -rf "${stage:-}"' EXIT

stage="$(mktemp -d)"
( cd "$repo" && git ls-files -co --exclude-standard | while IFS= read -r f; do [[ -e "$f" ]] && echo "$f"; done ) \
  | COPYFILE_DISABLE=1 tar -C "$repo" -cf - -T - | tar -xf - -C "$stage"
mkdir -p "$stage/local"

echo "==> $target: reading its local/machine.env (type the password if asked)"
env_file="$stage/local/machine.env"
# shellcheck disable=SC2029  # the remote path is built here on purpose
ssh "${ssh_opts[@]}" "$target" "cat ~/$clone/local/machine.env 2>/dev/null" > "$env_file" || true
if [[ -s "$env_file" ]]; then echo "    using the target's own machine.env"
else cp "$repo/local.example/machine.env" "$env_file"; echo "    no machine.env there; using local.example"; fi

for kv in "$@"; do
  key="${kv%%=*}"
  awk -v k="$key" -v line="$kv" 'index($0, k "=") == 1 {print line; done = 1; next} {print} END {if (!done) print line}' \
    "$env_file" > "$env_file.new" && mv "$env_file.new" "$env_file"
  echo "    override: $kv"
done

echo "==> copying the working tree to $target:~/$dev"
# shellcheck disable=SC2029  # the remote path is built here on purpose
COPYFILE_DISABLE=1 tar -C "$stage" -cf - . | ssh "${ssh_opts[@]}" "$target" \
  "rm -rf ~/$dev && mkdir -p ~/$dev && tar -xf - -C ~/$dev"

echo "==> running step $step (role $role${DRY:+, dry-run}) on $target"
ssh -t "${ssh_opts[@]}" "$target" "cd ~/$dev && ./bootstrap.sh $role --only $step${DRY:+ --dry-run}"
