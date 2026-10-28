#!/usr/bin/env bash
# Tests for Homebrew use: `brew bundle --no-upgrade` everywhere (slave step 20,
# master step 10, make deps), and the keg-only node@NN from the slave Brewfile
# force-linked when `node` is not that major version. Stubbed brew and node.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
node_formula="$(grep -oE 'brew "node@[0-9]+"' "$repo/roles/slave/Brewfile" | grep -oE 'node@[0-9]+' || true)"

setup() {  # setup <installed node version, e.g. v20.1.0, or "">
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home" "$tmp/Applications/Claude.app"
  : > "$tmp/calls"; echo orbstack > "$tmp/managed"
  printf 'AF_HOST_TAILNET="box"\n' > "$tmp/local/machine.env"
  cat > "$tmp/bin/brew" <<EOF
#!/bin/bash
echo "brew \$*" >> "$tmp/calls"
if [[ "\$1 \$2" == "list --cask" ]]; then grep -qx "\$3" "$tmp/managed"; exit; fi
if [[ "\$1 \$2" == "info --cask" ]]; then
  t="\${@: -1}"; app="X-\$t.app"; [[ "\$t" == claude ]] && app="Claude.app"
  printf '{"casks":[{"token":"%s","artifacts":[{"uninstall":[]},{"app":["%s"]}]}]}\n' "\$t" "\$app"; exit 0
fi
[[ "\$1" == link ]] && printf '#!/bin/bash\necho v24.22.1\n' > "$tmp/bin/node" && chmod +x "$tmp/bin/node"
true
EOF
  if [[ -n "$1" ]]; then printf '#!/bin/bash\necho %s\n' "$1" > "$tmp/bin/node"; fi
  cat > "$tmp/bin/uname" <<'EOF'
#!/bin/bash
if [[ "$1" == -m ]]; then echo arm64; else echo Darwin; fi
EOF
  chmod +x "$tmp/bin/"*
}

run_step() {  # run_step <role> <step file>
  HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" AF_ROOT="$repo" \
    AF_HOME="$tmp/home/.agentfiles" AF_LOCAL="$tmp/local" AF_DRY_RUN=0 AF_APPLICATIONS_DIR="$tmp/Applications" \
    /bin/bash "$repo/roles/$1/steps/$2" >"$tmp/out" 2>&1 || echo "step exited $?" >> "$tmp/out"
}

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"
  else echo "FAIL $what"; sed 's/^/     /' "${tmp:-/nonexistent}/out" "${tmp:-/nonexistent}/calls" 2>/dev/null || true; fails=$((fails + 1)); fi
}
called()       { grep -qF -- "$1" "$tmp/calls"; }
not_called()   { [[ -f "$tmp/calls" ]] && ! grep -qF -- "$1" "$tmp/calls"; }
adopt_first()  { [[ "$(grep -n -- '--adopt claude' "$tmp/calls" | cut -d: -f1)" -lt "$(grep -n '^brew bundle' "$tmp/calls" | head -1 | cut -d: -f1)" ]]; }
no_upgrading() { ! grep '^brew bundle' "$tmp/calls" | grep -qv -- '--no-upgrade'; }

check "slave Brewfile pins a node@NN line"       [ -n "$node_formula" ]
check "slave Brewfile has no plain node"         bash -c "! grep -qE '^brew \"node\"' '$repo/roles/slave/Brewfile'"

setup v20.1.0; run_step slave 20-homebrew.sh
check "slave 20: every bundle is --no-upgrade"   no_upgrading
check "slave 20: repo Brewfile bundled"          called "brew bundle --no-upgrade --file $repo/Brewfile"
check "slave 20: old node -> link $node_formula" called "brew link --overwrite --force $node_formula"
check "slave 20: hand-installed Claude.app adopted" called "brew install --cask --adopt claude"
check "slave 20: adopt runs before the bundle"   adopt_first
check "slave 20: app not on disk -> no adopt"    not_called "--adopt google-chrome"
check "slave 20: managed cask -> no adopt"       not_called "--adopt orbstack"
rm -rf "$tmp"

setup v24.22.1; run_step slave 20-homebrew.sh
check "slave 20: node 24 already -> no link"     not_called "brew link"
rm -rf "$tmp"

setup ""; run_step slave 20-homebrew.sh
check "slave 20: no node yet -> link"            called "brew link --overwrite --force $node_formula"
rm -rf "$tmp"

setup ""; run_step master 10-packages.sh
check "master 10: every bundle is --no-upgrade"  no_upgrading
check "master 10: master Brewfile bundled"       called "brew bundle --no-upgrade --file $repo/roles/master/Brewfile"
rm -rf "$tmp"

deps="$(make -s -n -C "$repo" deps)"
check "make deps: --no-upgrade"                  grep -q -- '--no-upgrade' <<<"$deps"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
