#!/usr/bin/env bash
# Suite: executable onboarding stage detection and environment preflight.
set -uo pipefail

TEST_NAME='onboard-state'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"

state_sh="$root/agentkit/skills/.shared/scripts/onboard-state.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local dir=$1
    mkdir -p "$dir/.agent/cache"
    git -C "$dir" init -q
}

repo="$tmp/repo"
mkdir -p "$repo"
make_repo "$repo"
out=$("$state_sh" --repo-root "$repo" --report)
assert_contains "$out" 'stage=not onboarded' 'an absent config is not onboarded'
assert_contains "$out" 'next=discover' 'not onboarded reports discovery as the next step'

printf 'discovered\n' > "$repo/.agent/cache/onboarding-stage"
out=$("$state_sh" --repo-root "$repo" --report)
assert_contains "$out" 'stage=discovered' 'a discovery marker advances the stage'
assert_contains "$out" 'next=declare' 'discovered reports declaration as next'

printf 'AGENT_REPO_SLUG=o/r\nAGENT_BASE_BRANCH=main\n' > "$repo/.agent/config.env"
printf '{"project":{}}\n' > "$repo/.agent/board.json"
out=$("$state_sh" --repo-root "$repo" --report)
assert_contains "$out" 'stage=declared' 'config and board are declared'
assert_contains "$out" 'next=verify' 'declared reports verification as next'

printf 'AGENT_CMD_VERIFY=true\n' >> "$repo/.agent/config.env"
touch "$repo/.agent/cache/stamp-verify"
out=$("$state_sh" --repo-root "$repo" --report)
assert_contains "$out" 'stage=verified' 'a command plus verify evidence reaches verified'
assert_contains "$out" 'next=commit' 'verified reports commit as next'

# The blessed local model arms after verification once both declarations are
# ignored by the repository-local exclude; no tracked onboarding PR is needed.
local_exclude=$(git -C "$repo" rev-parse --git-path info/exclude)
[[ $local_exclude == /* ]] || local_exclude=$repo/$local_exclude
printf '.agent/*\n' >> "$local_exclude"
out=$($state_sh --repo-root "$repo" --report)
assert_contains "$out" 'stage=armed' 'ignored local declarations arm after verification'
assert_contains "$out" 'next=none' 'the local model has no commit step'

printf '.agent/*\n!.agent/config.env\n!.agent/board.json\n' > "$repo/.gitignore"
git -C "$repo" add -- .agent/config.env .agent/board.json .gitignore
out=$("$state_sh" --repo-root "$repo" --report)
assert_contains "$out" 'stage=committed' 'tracked onboarding artifacts reach committed'
assert_contains "$out" 'next=arm' 'committed reports arming as next'

git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm onboard
out=$("$state_sh" --repo-root "$repo" --report)
assert_contains "$out" 'stage=armed' 'a committed contract with evidence is armed'
assert_contains "$out" 'next=none' 'armed has no next onboarding step'

# Feature-branch HEAD can contain all three artifacts before the onboarding PR
# merges. It must remain committed until the declared trunk reference contains
# the same artifacts.
feature="$tmp/feature"
mkdir -p "$feature"
make_repo "$feature"
printf 'AGENT_REPO_SLUG=o/r\nAGENT_BASE_BRANCH=main\nAGENT_CMD_VERIFY=true\n' > "$feature/.agent/config.env"
printf '{"project":{}}\n' > "$feature/.agent/board.json"
printf '.agent/*\n!.agent/config.env\n!.agent/board.json\n' > "$feature/.gitignore"
touch "$feature/.agent/cache/stamp-verify"
git -C "$feature" add -- .agent/config.env .agent/board.json .gitignore
git -C "$feature" -c user.name=t -c user.email=t@example.invalid commit -qm trunk-base
git -C "$feature" checkout -qb feat/onboarding
git -C "$feature" commit --allow-empty -qm feature-change
git -C "$feature" checkout -q main
git -C "$feature" rm -q --cached .agent/config.env .agent/board.json .gitignore
git -C "$feature" commit -qm remove-onboarding
rm -f "$feature/.agent/config.env" "$feature/.agent/board.json" "$feature/.gitignore"
git -C "$feature" checkout -q feat/onboarding
out=$("$state_sh" --repo-root "$feature" --report)
assert_contains "$out" 'stage=committed' \
    'feature branch artifacts are not armed before trunk merge'
assert_contains "$out" 'next=arm' 'pre-merge feature state reports arming as next'

# Once the remote-tracking base has the onboarding artifacts, it is the source
# of truth even when a stale local main still lacks them.
trunk_with_artifacts=$(git -C "$feature" rev-parse main~1)
git -C "$feature" update-ref refs/remotes/origin/main "$trunk_with_artifacts"
out=$("$state_sh" --repo-root "$feature" --report)
assert_contains "$out" 'stage=armed' \
    'remote-tracking trunk artifacts arm a feature branch despite stale local main'

# Preflight must expose actual component, lockfile, runtime-pin, and setup facts.
pre="$tmp/preflight"
mkdir -p "$pre/dashboard"
make_repo "$pre"
mkdir -p "$pre/.github/workflows"
printf '%s\n' $'name: CI\non:\n  pull_request:\njobs:\n  verify:\n    steps:\n      - name: Verify\n        run: |\n          verify.sh --full' > "$pre/.github/workflows/ci.yml"
printf '{"scripts":{"test":"jest"}}\n' > "$pre/dashboard/package.json"
printf '{}\n' > "$pre/dashboard/package-lock.json"
printf '20\n' > "$pre/.nvmrc"
printf '3.12\n' > "$pre/.python-version"
printf 'AGENT_REPO_SLUG=o/r\nAGENT_CMD_TEST=pytest -q\n' > "$pre/.agent/config.env"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/node" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --version ]] && printf 'v18.19.0\n' || exit 0
EOF
cat > "$tmp/bin/python3" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --version ]] && printf 'Python 3.11.8\n' || exit 0
EOF
chmod +x "$tmp/bin/node" "$tmp/bin/python3"
out=$(PATH="$tmp/bin:$PATH" "$state_sh" --repo-root "$pre" --preflight)
assert_contains "$out" 'component= path=dashboard lang=node' \
    'preflight reports the detected package component'
assert_contains "$out" 'runtime-pin=.nvmrc=20' \
    'preflight reports a runtime pin and its value'
assert_contains "$out" 'setup:' 'preflight emits an explicit setup step'
assert_contains "$out" 'npm ci' 'package-lock setup uses its locked npm runner'
assert_contains "$out" 'toolchain=node active=18.19.0 pin=20 match=no' \
    'preflight reports active Node versus pinned Node mismatch'
assert_contains "$out" 'guidance: node target=20' \
    'Node mismatch names the required target without prescribing a version manager'
assert_contains "$out" 'toolchain=python active=3.11.8 pin=3.12 match=no' \
    'preflight reports active Python versus pinned Python mismatch'
assert_contains "$out" 'guidance: python target=3.12' \
    'Python mismatch names the required target without prescribing a version manager'
assert_contains "$out" 'CI verifier: verify.sh --full' \
    'preflight includes the CI verifier before command proposals'
assert_contains "$out" 'CI entry point/defaults: inspect verify.sh --help' \
    'preflight requires entry-point defaults to be confirmed'

# The report carries the one-line drift summary so a caller does not need a
# second probe to discover that onboarding facts are stale.
drift_repo="$tmp/drift"
mkdir -p "$drift_repo/.agent" "$drift_repo/new"
git -C "$drift_repo" init -q
printf '%s\n' '{"scripts":{"test":"jest"}}' > "$drift_repo/new/package.json"
printf 'AGENT_REPO_SLUG=o/r\nAGENT_ONBOARDED_BY=agentkit/0.0.0\n# proposal-component|old|node|package.json\n' > "$drift_repo/.agent/config.env"
printf '{}\n' > "$drift_repo/.agent/board.json"
out=$($state_sh --repo-root "$drift_repo" --report)
assert_contains "$out" 'drift= components=+1/-1 generator=stale' \
    'report includes the aggregated drift summary'

finish
