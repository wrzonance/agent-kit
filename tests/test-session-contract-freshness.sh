#!/usr/bin/env bash
# Suite: SessionStart invalidates cached contracts when checkout identity changes,
# and (issue #551) keys the contract by harness so a second harness opening the
# same checkout never clobbers -- or reuses -- the first harness's file.
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
# The harness-keyed path SessionStart now reads and writes for the CURRENTLY
# RUNNING harness (issue #551) -- every fixture below has to seed this path,
# not the legacy bare name, to exercise the steady-state (post-fix) behavior.
contract_path() { printf '%s/.agent/env-contract.%s.txt' "$1" "$me"; }

repo=$(make_repo)
head=$(git -C "$repo" rev-parse HEAD)
printf 'repo=cached/value\nbranch=main\nbase=main source=test\nhead=%s\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' \
    "$head" "$me" > "$(contract_path "$repo")"

out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_contains "$out" 'cached/value' 'a current branch and HEAD reuse the cached contract'

unborn_repo=$(make_repo)
git -C "$unborn_repo" checkout -q --orphan wip
printf 'repo=stale-unborn/value\nbranch=main\nhead=%s\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' \
    "$head" "$me" > "$(contract_path "$unborn_repo")"
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
assert_contains "$(cat -- "$(contract_path "$repo")")" "head=$new_head" \
    'the refreshed cache persists the new HEAD, in this harness'"'"'s own keyed file'

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
    "$detached_head" "$me" > "$(contract_path "$repo")"
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_contains "$out" 'detached/value' 'a matching detached HEAD reuses the cached contract'

git -C "$repo" -c user.email=t@example.invalid -c user.name=t \
    commit --allow-empty -qm detached-second
new_detached_head=$(git -C "$repo" rev-parse HEAD)
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'detached/value' 'a new detached HEAD invalidates the cache'
assert_contains "$out" "head=$new_detached_head" 'the detached refresh records the new HEAD'

printf 'repo=legacy/value\nbranch=detached\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' \
    "$me" > "$(contract_path "$repo")"
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'legacy/value' 'a legacy cache without HEAD is not trusted'
assert_contains "$out" "head=$new_detached_head" 'a legacy cache is refreshed with checkout identity'

# --- issue #551: the un-suffixed bare file is still READ, never written -----
# A checkout whose contract predates this fix (or a caller that still targets
# the bare name) has only .agent/env-contract.txt on disk. SessionStart must
# still honor it as a cache hit -- and then forward it into this harness's
# own keyed file, without ever writing back to the bare name itself.
legacy_repo=$(make_repo)
legacy_head=$(git -C "$legacy_repo" rev-parse HEAD)
legacy_bare="$legacy_repo/.agent/env-contract.txt"
printf 'repo=legacy-bare/value\nbranch=main\nhead=%s\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' \
    "$legacy_head" "$me" > "$legacy_bare"
legacy_bare_before=$(cat -- "$legacy_bare")
out=$(session_input "$legacy_repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_contains "$out" 'legacy-bare/value' \
    'a legacy bare-named contract (no keyed file yet) is still reused as a cache hit'
assert_eq yes "$([[ -f $(contract_path "$legacy_repo") ]] && printf yes || printf no)" \
    'the reused legacy contract is forwarded into this harness'"'"'s own keyed file'
assert_contains "$(cat -- "$(contract_path "$legacy_repo")")" 'legacy-bare/value' \
    'and the forwarded copy carries the same content'
assert_eq "$legacy_bare_before" "$(cat -- "$legacy_bare")" \
    'the legacy bare file itself is never rewritten -- forwarding is READ-only against it'

# --- issue #551: two harnesses' SessionStart in the same checkout ----------
# never clobber each other's contract, in either firing order, and each gets
# its own keyed file rather than sharing the bare name.
claude_env=(env -u CODEX_HOME -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_PERMISSION_PROFILE \
    -u OPENCODE -u OPENCODE_PID CLAUDECODE=1 PATH="$stub_path")
codex_env=(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u OPENCODE -u OPENCODE_PID \
    CODEX_SANDBOX_NETWORK_DISABLED=1 PATH="$stub_path")

order1=$(make_repo)
claude_out1=$(session_input "$order1" | "${claude_env[@]}" "$hooks/session-start.sh" 2> /dev/null)
claude_file1="$order1/.agent/env-contract.claude.txt"
assert_eq yes "$([[ -f $claude_file1 ]] && printf yes || printf no)" \
    'claude SessionStart writes its own keyed contract'
assert_hook_output "$claude_out1" session-start 'the claude SessionStart output is schema-valid'
claude_snapshot1=$(cat -- "$claude_file1" 2> /dev/null)
assert_contains "$claude_snapshot1" 'mode=owner' \
    'the first harness to start in a checkout owns it'

codex_out1=$(session_input "$order1" | "${codex_env[@]}" "$hooks/session-start.sh" 2> /dev/null)
assert_hook_output "$codex_out1" session-start 'the codex SessionStart output is schema-valid'
codex_file1="$order1/.agent/env-contract.codex.txt"
assert_eq yes "$([[ -f $codex_file1 ]] && printf yes || printf no)" \
    'codex SessionStart (fired second, same checkout) writes its OWN keyed contract'
assert_eq "$claude_snapshot1" "$(cat -- "$claude_file1" 2> /dev/null)" \
    'the codex SessionStart never touched the earlier claude contract (order: claude, then codex)'
assert_contains "$(cat -- "$codex_file1")" 'mode=observer' \
    'codex, starting while claude'"'"'s contract is still fresh, marks itself an observer'
assert_contains "$(cat -- "$codex_file1")" 'other-harness=claude' \
    'and names which harness'"'"'s run it is observing'

order2=$(make_repo)
codex_out2=$(session_input "$order2" | "${codex_env[@]}" "$hooks/session-start.sh" 2> /dev/null)
assert_hook_output "$codex_out2" session-start 'the codex SessionStart output is schema-valid'
codex_file2="$order2/.agent/env-contract.codex.txt"
codex_snapshot2=$(cat -- "$codex_file2" 2> /dev/null)
assert_contains "$codex_snapshot2" 'mode=owner' \
    'codex, first to start here, owns the checkout'

claude_out2=$(session_input "$order2" | "${claude_env[@]}" "$hooks/session-start.sh" 2> /dev/null)
assert_hook_output "$claude_out2" session-start 'the claude SessionStart output is schema-valid'
claude_file2="$order2/.agent/env-contract.claude.txt"
assert_eq yes "$([[ -f $claude_file2 ]] && printf yes || printf no)" \
    'claude SessionStart (fired second) writes its own keyed contract'
assert_eq "$codex_snapshot2" "$(cat -- "$codex_file2" 2> /dev/null)" \
    'the claude SessionStart never touched the earlier codex contract (order: codex, then claude)'
assert_contains "$(cat -- "$claude_file2")" 'mode=observer' \
    'claude, starting while codex'"'"'s contract is still fresh, marks itself an observer'
assert_contains "$(cat -- "$claude_file2")" 'other-harness=codex' \
    'and names which harness'"'"'s run it is observing'

assert_eq no "$([[ -e "$order1/.agent/env-contract.txt" ]] && printf yes || printf no)" \
    'neither harness ever writes the legacy bare contract (order: claude, codex)'
assert_eq no "$([[ -e "$order2/.agent/env-contract.txt" ]] && printf yes || printf no)" \
    'neither harness ever writes the legacy bare contract (order: codex, claude)'

# --- issue #551 finding F1 (adversarial review): a hostile env-contract.*.txt
# candidate must never be trusted for the observer-mode liveness signal -----
# Neither an untrusted (tracked) file nor one whose harness suffix does not
# match the safe single-token vocabulary can hand this session a value that
# ends up interpolated into its own mode=observer line.
hostile_repo=$(make_repo)

hostile_tracked="$hostile_repo/.agent/env-contract.codex.txt"
printf 'harness= name=codex trailer="Codex <x@example.invalid>" other=claude\n' > "$hostile_tracked"
git -C "$hostile_repo" add -f .agent/env-contract.codex.txt
git -C "$hostile_repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'plant a tracked contract'
hostile_claude_out=$(session_input "$hostile_repo" | "${claude_env[@]}" "$hooks/session-start.sh" 2> /dev/null)
assert_hook_output "$hostile_claude_out" session-start \
    'SessionStart still emits schema-valid JSON with a tracked hostile candidate present'
assert_not_contains "$(cat -- "$hostile_repo/.agent/env-contract.claude.txt" 2> /dev/null)" 'mode=observer' \
    'a TRACKED env-contract.codex.txt is never trusted as evidence of a live codex run (issue #551 F1)'

hostile_repo2=$(make_repo)
# A malformed suffix (fails contract_cache_harness_name's own
# ^[a-z][a-z0-9]*$ vocabulary) is the same class of hazard a filename
# carrying control characters (e.g. an embedded newline) would be: both are
# rejected by the identical regex guard before the value is ever read into a
# grep pattern or a contract line.
printf 'harness= name=co!dex trailer="Codex <x@example.invalid>" other=claude\n' \
    > "$hostile_repo2/.agent/env-contract.co!dex.txt"
hostile2_claude_out=$(session_input "$hostile_repo2" | "${claude_env[@]}" "$hooks/session-start.sh" 2> /dev/null)
assert_hook_output "$hostile2_claude_out" session-start \
    'SessionStart still emits schema-valid JSON with a malformed-suffix candidate present'
assert_not_contains "$(cat -- "$hostile_repo2/.agent/env-contract.claude.txt" 2> /dev/null)" 'mode=observer' \
    'a keyed file whose suffix is not a safe harness token is never trusted (issue #551 F1)'

# --- issue #551 finding F2: the legacy bare contract is still a valid
# liveness signal, not just the keyed files --------------------------------
# An older run of the other harness may still be active with ONLY a fresh
# bare contract on disk (it started before this fix's keying, or its own
# writer still targets the bare name); a session starting now must still
# recognize that and mark itself an observer rather than racing it.
legacy_live_repo=$(make_repo)
printf 'repo=legacy-live/repo\n%s\n' \
    "harness= name=codex trailer=\"Codex <x@example.invalid>\" other=claude" \
    > "$legacy_live_repo/.agent/env-contract.txt"
legacy_live_before=$(cat -- "$legacy_live_repo/.agent/env-contract.txt")
legacy_live_out=$(session_input "$legacy_live_repo" | "${claude_env[@]}" "$hooks/session-start.sh" 2> /dev/null)
assert_hook_output "$legacy_live_out" session-start \
    'SessionStart emits schema-valid JSON when only a fresh legacy contract from the other harness exists'
assert_contains "$(cat -- "$legacy_live_repo/.agent/env-contract.claude.txt" 2> /dev/null)" 'mode=observer' \
    'a fresh LEGACY bare contract from the other harness still marks a new session an observer (issue #551 F2)'
assert_contains "$(cat -- "$legacy_live_repo/.agent/env-contract.claude.txt" 2> /dev/null)" 'other-harness=codex' \
    'and names the harness read from the legacy file'
assert_eq "$legacy_live_before" "$(cat -- "$legacy_live_repo/.agent/env-contract.txt" 2> /dev/null)" \
    'the legacy bare contract itself is left byte-identical, never written'

# --- issue #551: contract-read.sh resolves the CALLING harness's own tree --
# Directly wired, independent of SessionStart, since this is the surface
# every worktree-commit/board-list/triage-issues helper actually reads
# skills.path through.
kr_repo=$(make_repo)
printf 'skills= path=/opt/claude-tree/skills\nharness= name=claude trailer="Claude <c@example.invalid>" other=codex\n' \
    > "$kr_repo/.agent/env-contract.claude.txt"
printf 'skills= path=/opt/codex-tree/skills\nharness= name=codex trailer="Codex <x@example.invalid>" other=claude\n' \
    > "$kr_repo/.agent/env-contract.codex.txt"
contract_read="$skills_root/.shared/scripts/contract-read.sh"

claude_skills=$("${claude_env[@]}" "$contract_read" --repo-root "$kr_repo" --get skills.path 2> /dev/null)
assert_eq '/opt/claude-tree/skills' "$claude_skills" \
    'contract-read.sh --get skills.path resolves the CLAUDE-keyed contract when running as claude'

codex_skills=$("${codex_env[@]}" "$contract_read" --repo-root "$kr_repo" --get skills.path 2> /dev/null)
assert_eq '/opt/codex-tree/skills' "$codex_skills" \
    'contract-read.sh --get skills.path resolves the CODEX-keyed contract when running as codex, from the SAME checkout'

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
# agentkit/skills/parallel-issues/references/chains.md). This fixture writes
# the bare contract name directly (agent-preflight.sh's own --write default,
# unchanged by issue #551) rather than going through create-issue-worktree.sh,
# so it stays valid regardless of the harness key.
preflight="$skills_root/.shared/scripts/agent-preflight.sh"
compose="$skills_root/parallel-issues/scripts/compose-worker-prompt.sh"
# Derived under the SAME `env -u ...` the preflight invocation below actually
# runs under (issue #372 review finding), not the ambient environment --
# harness-id.sh treats CODEX_HOME/CODEX_SANDBOX_NETWORK_DISABLED/
# CODEX_PERMISSION_PROFILE as harness-identity signals, so if any of those
# three is set on the machine running this suite, the ambient value here and
# the value the invocation resolves at run time would disagree, and
# compute_inherit_session_state would refuse the fixture as a harness
# mismatch before ever reaching the revalidation path this test exists to
# exercise (the exact class of bug that turned PR #381's first CI run red in
# tests/test-agent-preflight.sh).
harness_line="harness= $(env -u CODEX_HOME -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_PERMISSION_PROFILE \
    "$skills_root/.shared/scripts/harness-id.sh" 2> /dev/null)"

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
