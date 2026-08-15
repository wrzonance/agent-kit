#!/usr/bin/env bash
# Suite: onboarding drift aggregation and refresh inventory.
set -uo pipefail

TEST_NAME='onboard-refresh'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"

refresh_sh="$root/agentkit/skills/.shared/scripts/onboard-refresh.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo/.agent" "$repo/.github/workflows" "$repo/tools" "$repo/new"
git -C "$repo" init -q
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tools/verify"
chmod +x "$repo/tools/verify"
printf '%s\n' '{"scripts":{"test":"jest"}}' > "$repo/new/package.json"
printf '%s\n' 'name: CI' 'on:' '  pull_request:' 'jobs:' '  verify:' '    steps:' \
    '      - name: Format' '        run: format-check' \
    '      - name: Markdown lint' '        run: markdownlint' \
    '      - name: Verify locally' '        run: tools/verify' \
    > "$repo/.github/workflows/ci.yml"
cat > "$repo/.agent/config.env" <<'EOF'
AGENT_REPO_SLUG=example-org/example-repo
AGENT_ONBOARDED_BY=agentkit/0.0.0
AGENT_CMD_VERIFY=tools/verify
# proposal-component|old|node|package.json
# proposal-command|AGENT_CMD_VERIFY|tools/verify|missing|
EOF

out=$(bash "$refresh_sh" --repo-root "$repo" --report 2>&1)
assert_contains "$out" 'drift= components=+1/-1 toolchains=+1 generator=stale ci-gaps=2' \
    'report summarizes all non-trivial drift axes on one line'
assert_contains "$out" 'component= added path=new' \
    'report names a newly detected component'
assert_contains "$out" 'component= removed path=old' \
    'report names a removed component'
assert_contains "$out" 'toolchain= key=AGENT_CMD_VERIFY' \
    'report names a proposal whose binary became available'
assert_contains "$out" 'generator= stale' \
    'report names a stale generator stamp'
assert_contains "$out" 'ci-gap-gate= Format' \
    'report folds an uncovered CI gate into the drift details'

sed -i 's/|missing|/|present|/' "$repo/.agent/config.env"
rm -f "$repo/tools/verify"
out=$(bash "$refresh_sh" --repo-root "$repo" --summary 2>&1)
assert_contains "$out" 'toolchains=-1' \
    'summary reports a proposal binary becoming unavailable'

current=$(
    jq -r '.version' < "$root/agentkit/.codex-plugin/plugin.json"
)
mkdir -p "$repo/tools"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tools/verify"
chmod +x "$repo/tools/verify"
printf '%s\n' 'name: CI' 'on:' '  pull_request:' 'jobs:' '  verify:' '    steps:' \
    '      - name: Verify locally' '        run: tools/verify' \
    > "$repo/.github/workflows/ci.yml"
cat > "$repo/.agent/config.env" <<EOF
AGENT_REPO_SLUG=example-org/example-repo
AGENT_ONBOARDED_BY=agentkit/$current
AGENT_CMD_VERIFY=tools/verify
# proposal-component|new|node|package.json
# proposal-command|AGENT_CMD_VERIFY|tools/verify|present|
EOF
out=$(bash "$refresh_sh" --repo-root "$repo" --summary 2>&1)
assert_eq 'drift= none' "$out" 'a current inventory with no uncovered gates is quiet'

finish
