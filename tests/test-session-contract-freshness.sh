#!/usr/bin/env bash
# Suite: SessionStart invalidates cached contracts when checkout identity changes.
set -uo pipefail

TEST_NAME='session-contract-freshness'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

hooks="$root/agentkit/hooks"
skills_root="$root/agentkit/skills"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
stub_path="$here/stub:$PATH"

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    git -C "$dir" checkout -q -b main
    git -C "$dir" -c user.email=t@example.invalid -c user.name=t \
        commit --allow-empty -qm base
    mkdir -p "$dir/.agent"
    printf '%s' "$dir"
}

session_input() {
    jq -nc --arg cwd "$1" \
        '{cwd:$cwd,hook_event_name:"SessionStart",model:"m",permission_mode:"default",
          session_id:"s1",source:"startup",transcript_path:null}'
}

me=$("$skills_root"/.shared/scripts/harness-id.sh --name 2> /dev/null)
repo=$(make_repo)
head=$(git -C "$repo" rev-parse HEAD)
printf 'repo=cached/value\nbranch=main\nbase=main source=test\nhead=%s\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' \
    "$head" "$me" > "$repo/.agent/env-contract.txt"

out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_contains "$out" 'cached/value' 'a current branch and HEAD reuse the cached contract'

unborn_repo=$(make_repo)
git -C "$unborn_repo" checkout -q --orphan wip
printf 'repo=stale-unborn/value\nbranch=main\nhead=%s\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' \
    "$head" "$me" > "$unborn_repo/.agent/env-contract.txt"
out=$(session_input "$unborn_repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'stale-unborn/value' \
    'a named unborn branch invalidates a cache from another branch'
assert_contains "$out" 'branch=HEAD' \
    'the refreshed context identifies the unborn checkout'

git -C "$repo" -c user.email=t@example.invalid -c user.name=t \
    commit --allow-empty -qm second
new_head=$(git -C "$repo" rev-parse HEAD)
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'cached/value' 'a new HEAD invalidates the cached contract'
assert_contains "$out" "head=$new_head" 'the refreshed context records the new HEAD'
assert_contains "$(cat -- "$repo/.agent/env-contract.txt")" "head=$new_head" \
    'the refreshed cache persists the new HEAD'

git -C "$repo" checkout -q -b feat/same-head
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'cached/value' 'a branch change invalidates the cached contract'
assert_contains "$out" 'branch=feat/same-head' 'the refreshed context reports the new branch'

git -C "$repo" checkout -q --detach "$new_head"
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'cached/value' 'detached HEAD invalidates a branch cache'
assert_contains "$out" 'branch=detached' 'the refreshed context reports detached HEAD'
detached_head=$(git -C "$repo" rev-parse HEAD)
printf 'repo=detached/value\nbranch=detached\nhead=%s\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' \
    "$detached_head" "$me" > "$repo/.agent/env-contract.txt"
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_contains "$out" 'detached/value' 'a matching detached HEAD reuses the cached contract'

git -C "$repo" -c user.email=t@example.invalid -c user.name=t \
    commit --allow-empty -qm detached-second
new_detached_head=$(git -C "$repo" rev-parse HEAD)
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'detached/value' 'a new detached HEAD invalidates the cache'
assert_contains "$out" "head=$new_detached_head" 'the detached refresh records the new HEAD'

printf 'repo=legacy/value\nbranch=detached\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' \
    "$me" > "$repo/.agent/env-contract.txt"
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'legacy/value' 'a legacy cache without HEAD is not trusted'
assert_contains "$out" "head=$new_detached_head" 'a legacy cache is refreshed with checkout identity'

# --- issue #372: a chain link created outside the 30-minute inheritance ----
# window still composes a worker prompt. This is the end-to-end shape of a
# long --auto-serialize chain's later links: create-issue-worktree.sh calls
# agent-preflight.sh --inherit-session against the ROOT checkout's own
# .agent/env-contract.txt, and that root contract was written once, at
# session start -- by the third-or-later link it is reliably older than
# INHERIT_SESSION_MAX_AGE_MINUTES even though nothing about the session
# changed. Before agent-preflight.sh revalidated instead of discarding a
# stale-but-same-harness source, the worktree fell back to an unqualified
# fresh probe, which could disagree with the (more restrictive) root and
# trip compose-worker-prompt.sh's worktree-contract-less-restrictive-than-
# root refusal -- with no documented recovery (see
# agentkit/skills/parallel-issues/references/chains.md).
preflight="$skills_root/.shared/scripts/agent-preflight.sh"
compose="$skills_root/parallel-issues/scripts/compose-worker-prompt.sh"
harness_line="harness= $("$skills_root/.shared/scripts/harness-id.sh" 2> /dev/null)"

make_chain_root() {
    local dir=$1 sandbox_line=$2
    mkdir -p "$dir/.agent"
    git -C "$dir" init -q
    git -C "$dir" config user.name test
    git -C "$dir" config user.email test@example.invalid
    printf 'seed\n' > "$dir/seed.txt"
    git -C "$dir" add -- seed.txt
    git -C "$dir" commit -qm seed
    printf '%s\n%s\n' "$harness_line" "$sandbox_line" > "$dir/.agent/env-contract.txt"
    chmod 600 "$dir/.agent/env-contract.txt"
    # Backdate past INHERIT_SESSION_MAX_AGE_MINUTES (30m) -- the exact shape
    # a chain's third-or-later link finds the root contract in.
    touch -d '2 hours ago' "$dir/.agent/env-contract.txt" 2> /dev/null ||
        touch -t "$(date -d '2 hours ago' +%Y%m%d%H%M 2> /dev/null || date -v-2H +%Y%m%d%H%M)" \
            "$dir/.agent/env-contract.txt"
}

chain_restrictive='sandbox= active=yes profile=strict network=disabled home-writable=no measured-by=hook note="probed outside your sandbox; treat this as the floor, not the ceiling, and believe a denial over this line"'

chain_root=$(mktemp -d "$tmp/chain-root.XXXXXX")
make_chain_root "$chain_root" "$chain_restrictive"

chain_branch=feat/issue-chain-link
chain_worktree="$chain_root/.worktrees/$chain_branch"
git -C "$chain_root" worktree add -q -b "$chain_branch" "$chain_worktree" > /dev/null 2>&1
mkdir -p "$chain_worktree/.agent"
printf '%s\n' \
    'AGENT_REPO_SLUG=example-org/example-repo' \
    'AGENT_BASE_BRANCH=main' \
    'AGENT_CMD_TEST=tools/full-test' \
    > "$chain_worktree/.agent/config.env"
printf 'SPEC-BYTES\n' > "$chain_worktree/.agent/fenced-spec.txt"
printf 'PRIOR-BYTES\n' > "$chain_worktree/.agent/fenced-prior-art.txt"

# create-issue-worktree.sh's own call shape: preflight the new worktree,
# inheriting the root's contract. Force a genuinely unsandboxed fresh probe
# (env -u) so the only way the worktree ends up at least as restrictive as
# the stale root is the revalidation path, never an accidental agreement.
chain_preflight_err=$(env -u CODEX_HOME -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_PERMISSION_PROFILE \
    "$preflight" --worktree "$chain_worktree" --inherit-session "$chain_root/.agent/env-contract.txt" \
    2>&1 > /dev/null)
assert_contains "$chain_preflight_err" 'revalidated sandbox=' \
    'a chain link past the inheritance window revalidates the stale root contract rather than silently discarding it'

chain_worktree_sandbox=$(grep '^sandbox=' "$chain_worktree/.agent/env-contract.txt")
assert_eq "$chain_restrictive" "$chain_worktree_sandbox" \
    'the revalidated worktree sandbox= is never less restrictive than the stale root (kept verbatim here since a fresh probe would have widened it)'

chain_prompt_rc=0
chain_prompt=$(bash "$compose" --template issue-lead --boundary public-fenced --write-set 'src/**' \
    --worktree "$chain_worktree" --issue 372 --branch "$chain_branch" \
    --worker-model gpt-5.6-luna --worker-effort high 2> "$tmp/chain-compose-err") || chain_prompt_rc=$?
assert_eq 0 "$chain_prompt_rc" \
    'the worker prompt still composes for a chain link created outside the inheritance window'
assert_not_contains "$(cat -- "$tmp/chain-compose-err")" 'worktree-contract-less-restrictive-than-root' \
    'composing never hits the less-restrictive-than-root refusal for a revalidated stale-but-same-harness worktree'
assert_contains "$chain_prompt" 'Repo: example-org/example-repo' \
    'the composed prompt is a real worker prompt, not an empty success'

finish
