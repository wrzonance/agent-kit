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
AGENT_RUNDIR_VERIFY=dashboard
# AGENT_REVIEW_PROVIDERS=
# proposal-component|old|node|package.json
# proposal-command|AGENT_CMD_VERIFY|tools/verify|missing|
EOF

out=$(bash "$refresh_sh" --repo-root "$repo" --report 2>&1)
assert_contains "$out" 'drift= components=+1/-1 toolchains=+1 generator=stale review-providers=undeclared ci-gaps=2' \
    'report summarizes all non-trivial drift axes on one line'
assert_contains "$out" 'review-providers=undeclared' \
    'report identifies an undecided review provider without blocking other drift'
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

mkdir -p "$repo/dashboard"
printf '%s\n' '[project]' 'dependencies = ["pytest"]' > "$repo/dashboard/pyproject.toml"
inventory=$(bash "$refresh_sh" --repo-root "$repo" --inventory)
assert_contains "$inventory" \
    '# proposal-command|AGENT_CMD_DASHBOARD_TEST|' \
    'inventory retains the command key for a component rundir'
assert_contains "$inventory" '|present|dashboard' \
    'inventory resolves a command alongside its declared rundir'
rm -rf -- "$repo/dashboard"

sed -i 's/|missing|/|present|/' "$repo/.agent/config.env"
rm -f "$repo/tools/verify"
out=$(bash "$refresh_sh" --repo-root "$repo" --summary 2>&1)
assert_contains "$out" 'toolchains=-1' \
    'summary reports a proposal binary becoming unavailable'
assert_contains "$out" 'paths=drift' \
    'summary preserves path drift alongside generator drift'

printf '%s\n' 'AGENT_REVIEW_PROVIDERS=not-a-provider' >> "$repo/.agent/config.env"
out=$(bash "$refresh_sh" --repo-root "$repo" --summary 2>&1)
assert_contains "$out" 'review-providers=invalid' \
    'report identifies an invalid provider choice as an advisory gap'

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
AGENT_REVIEW_PROVIDERS=github-code-quality
# proposal-component|new|node|package.json
# proposal-command|AGENT_CMD_VERIFY|tools/verify|present|
EOF
out=$(bash "$refresh_sh" --repo-root "$repo" --summary 2>&1)
assert_eq 'drift= none' "$out" 'a current inventory with no uncovered gates is quiet'

# Provider resolution remains reportable when the helper loses its executable
# bit, and when an installation is incomplete. onboard-refresh must invoke a
# present regular helper through bash rather than silently dropping the drift.
provider_scripts="$tmp/provider-scripts"
cp -a "$root/agentkit/skills/.shared/scripts" "$provider_scripts"
chmod 644 "$provider_scripts/review-provider-config.sh"
out=$(bash "$provider_scripts/onboard-refresh.sh" --repo-root "$repo" --summary 2>&1)
assert_eq 'drift= none' "$out" \
    'present but non-executable provider helper runs through bash'
rm -- "$provider_scripts/review-provider-config.sh"
out=$(bash "$provider_scripts/onboard-refresh.sh" --repo-root "$repo" --summary 2>&1)
assert_contains "$out" 'review-providers=unavailable' \
    'report identifies a missing provider helper'
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$provider_scripts/review-provider-config.sh"
chmod 644 "$provider_scripts/review-provider-config.sh"
out=$(bash "$provider_scripts/onboard-refresh.sh" --repo-root "$repo" --summary 2>&1)
assert_contains "$out" 'review-providers=unavailable' \
    'report identifies a provider helper that fails to run'

# --- model-roster migration hints (issue #487) ------------------------------
# The roster form takes precedence over its singular counterpart once
# declared, so a repository carrying both is not broken -- but the singular
# declaration is now dead weight nobody notices without a nudge.
cat > "$repo/.agent/config.env" <<EOF
AGENT_REPO_SLUG=example-org/example-repo
AGENT_ONBOARDED_BY=agentkit/$current
AGENT_CMD_VERIFY=tools/verify
AGENT_REVIEW_PROVIDERS=github-code-quality
AGENT_WORKER_MODELS=claude-sonnet-5,gpt-5.6-luna
AGENT_WORKER_MODEL=gpt-5.6-luna
AGENT_ADVERSARIAL_REVIEWER=gpt-5.6-sol-xhigh
EOF
out=$(bash "$refresh_sh" --repo-root "$repo" --report 2>&1)
assert_contains "$out" 'model-roster=hint' \
    'summary flags a roster/singular-key overlap'
assert_contains "$out" 'roster-hint= AGENT_WORKER_MODELS* and AGENT_WORKER_MODEL* are both declared' \
    'report names the worker roster/singular overlap'
assert_contains "$out" 'roster-hint= AGENT_ADVERSARIAL_REVIEWER is a roster compound with no AGENT_ADVERSARIAL_REVIEWER_FALLBACK declared' \
    'report names the reviewer roster with no fallback candidate'

# Declaring only the roster form (no singular overlap, fallback present)
# stays quiet -- the hint is for migration debt, not for using the feature.
cat > "$repo/.agent/config.env" <<EOF
AGENT_REPO_SLUG=example-org/example-repo
AGENT_ONBOARDED_BY=agentkit/$current
AGENT_CMD_VERIFY=tools/verify
AGENT_REVIEW_PROVIDERS=github-code-quality
AGENT_WORKER_MODELS=claude-sonnet-5,gpt-5.6-luna
AGENT_ADVERSARIAL_REVIEWER=gpt-5.6-sol-xhigh
AGENT_ADVERSARIAL_REVIEWER_FALLBACK=claude-opus-5-high
EOF
out=$(bash "$refresh_sh" --repo-root "$repo" --summary 2>&1)
assert_eq 'drift= none' "$out" \
    'a roster-only declaration with a fallback candidate is quiet'

# Base-trusted reviewer settings are read from origin/main by the resolver;
# onboarding must surface the same divergence warning for a local edit.
base_repo="$tmp/base-trusted-repo"
mkdir -p "$base_repo/.agent"
git -C "$base_repo" init -q -b main
git -C "$base_repo" config user.email test@example.com
git -C "$base_repo" config user.name test
printf 'AGENT_REPO_SLUG=example-org/example-repo\nAGENT_ADVERSARIAL_REVIEWER=claude\n' \
    > "$base_repo/.agent/config.env"
git -C "$base_repo" add -- .agent/config.env
git -C "$base_repo" commit -qm base
git -C "$base_repo" update-ref refs/remotes/origin/main HEAD
printf 'AGENT_REPO_SLUG=example-org/example-repo\nAGENT_ADVERSARIAL_REVIEWER=codex\n' \
    > "$base_repo/.agent/config.env"
out=$(bash "$refresh_sh" --repo-root "$base_repo" --report 2>&1)
assert_contains "$out" 'config=base-drift' \
    'report summarizes divergence in a base-trusted reviewer setting'
assert_contains "$out" 'source=base:' \
    'report names the origin/base source for the reviewer setting'
assert_contains "$out" 'working-tree=codex (not in effect until on main)' \
    'report warns that the working-tree reviewer is not in effect yet'

# The refresh report audits linked worktrees against the active write set in
# their lead prompt and prunes registrations whose checkout disappeared.
fleet_repo="$tmp/fleet-repo"
mkdir -p "$fleet_repo/.agent"
git -C "$fleet_repo" init -q -b main
git -C "$fleet_repo" config user.email test@example.com
git -C "$fleet_repo" config user.name test
printf '%s\n' tracked > "$fleet_repo/tracked.txt"
git -C "$fleet_repo" add -- tracked.txt
git -C "$fleet_repo" commit -qm init
fleet_worktree="$tmp/fleet-worktree"
git -C "$fleet_repo" worktree add -q -b feat/fleet "$fleet_worktree"
mkdir -p "$fleet_worktree/.agent/prompts"
cat > "$fleet_worktree/.agent/prompts/issue-9-lead.md" <<'EOF'
## Declared write set (the files this dispatch owns)

- allowed.txt
EOF
printf '%s\n' changed > "$fleet_worktree/foreign.txt"
printf '%s\n' allowed > "$fleet_worktree/allowed.txt"
git -C "$fleet_worktree" add -- allowed.txt foreign.txt
fleet_out=$(bash "$refresh_sh" --repo-root "$fleet_repo" --report 2>&1)
assert_contains "$fleet_out" 'worktree= path=' \
    'refresh reports a linked worktree with tracked drift'
assert_contains "$fleet_out" 'outside-write-set=foreign.txt' \
    'refresh names tracked modifications outside the active write set'
assert_not_contains "$fleet_out" 'outside-write-set=allowed.txt' \
    'refresh accepts tracked modifications inside the active write set'
missing_registration="$tmp/missing-worktree"
git -C "$fleet_repo" worktree add -q -b feat/missing "$missing_registration"
rm -rf -- "$missing_registration"
prune_out=$(bash "$refresh_sh" --repo-root "$fleet_repo" --report 2>&1)
assert_contains "$prune_out" 'worktree= pruned path=' \
    'refresh reports pruning a dangling worktree registration'
assert_eq '2' "$(git -C "$fleet_repo" worktree list --porcelain | grep -c '^worktree ' | tr -d ' ')" \
    'refresh prunes the dangling registration while retaining the live worktree'

finish
