#!/usr/bin/env bash
# shellcheck disable=SC2016  # assertions intentionally match literal recipe variables
# Suite: create-issue-worktree.sh carries session-scoped facts into new worktrees.
#
# sandbox=, caches=, and tls= describe the SESSION (which process is running
# commands, what it can reach), not any one worktree. Issue #332: a per-worktree
# preflight that RE-MEASURES them can run in a differently-privileged process
# than the root's own preflight did, producing a truthful-for-itself but
# contradictory answer for the same session -- observed live as three mutually
# disagreeing contracts from one machine, one session, minutes apart. This
# suite pins that create-issue-worktree.sh instead carries the root contract's
# copies of those three lines forward byte-for-byte.
set -uo pipefail

TEST_NAME='create-issue-worktree'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

stat_mode() {
    stat -c %a -- "$1" 2>/dev/null || stat -f %Lp -- "$1"
}

create_sh="$root/agentkit/skills/parallel-issues/scripts/create-issue-worktree.sh"
compose_worker_sh="$root/agentkit/skills/parallel-issues/scripts/compose-worker-prompt.sh"
worktree_commit_sh="$root/agentkit/skills/.shared/scripts/worktree-commit.sh"
preflight_sh="$root/agentkit/skills/.shared/scripts/agent-preflight.sh"
activation_sh="$root/agentkit/skills/.shared/scripts/workflow-activation.sh"
activation_hook="$root/agentkit/hooks/user-prompt-submit.sh"
harness_id_script="$root/agentkit/skills/.shared/scripts/harness-id.sh"
run_state_sh="$root/agentkit/skills/.shared/scripts/run-state.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# --inherit-session only trusts a source contract that names the current
# CLI's own harness= (issue #332 F3); a hand-built fixture contract needs
# this line too, computed live so the suite passes under whichever CLI
# actually runs it.
current_harness_line="harness= $("$harness_id_script" 2> /dev/null)"

assert_exec() {
    local path=$1 label=$2
    if [[ -x $path && ! -L $path ]]; then
        _pass "$label"
    else
        _fail "$label" "not executable or missing: $path"
    fi
}
assert_exec "$create_sh" 'create-issue-worktree.sh is executable'
create_help=$("$create_sh" --help)
assert_contains "$create_help" '--dispatch-plan FILE --run-id ID' \
    'join setup help names its paired saved-run inputs'
assert_contains "$(<"$create_sh")" \
    'preflight_args=(--worktree "$worktree" --inherit-session "$root_contract")' \
    'preflight argv starts nonempty before optional activation arguments'

# Fetch must complete before resumability is calculated, so a newly discovered
# remote branch cannot contradict the summary printed to the caller.
fetch_line=$(grep -n 'git -C "$root" fetch origin' "$create_sh" | head -n1 | cut -d: -f1)
resumable_line=$(grep -n "printf 'resumable:" "$create_sh" | head -n1 | cut -d: -f1)
assert_eq yes "$([[ -n $fetch_line && -n $resumable_line && $fetch_line -lt $resumable_line ]] && printf yes || printf no)" \
    'resumability is calculated after the origin fetch'

make_repo() {
    local repo=$1 origin
    origin="$tmp/$(basename "$1")-origin"
    git init -q --bare "$origin"
    git init -q -b main "$repo"
    git -C "$repo" config user.name test
    git -C "$repo" config user.email test@example.invalid
    mkdir -p "$repo/.agent"
    printf '%s\n' \
        'AGENT_REPO_SLUG=example/repo' \
        'AGENT_BASE_BRANCH=main' \
        'AGENT_WORKTREE_ROOT=.fleet' \
        'AGENT_CMD_TEST=true' \
        >"$repo/.agent/config.env"
    printf 'seed\n' >"$repo/seed.txt"
    git -C "$repo" add -- seed.txt
    git -C "$repo" commit -qm seed
    git -C "$repo" remote add origin "$origin"
    git -C "$repo" push -q origin main
    git -C "$repo" fetch -q origin
    printf '.agent/config.env\n' >>"$repo/.git/info/exclude"
    printf '%s\n' "$repo"
}

activate_parallel() {
    local repo=$1 session=$2 record nonce
    jq -nc --arg cwd "$repo" --arg session "$session" \
        '{cwd:$cwd,session_id:$session,hook_event_name:"UserPromptSubmit",prompt:"$agentkit:parallel-issues 827"}' |
        "$activation_hook" >/dev/null
    record=$(find "$repo/.agent/activation" -type f -name '*.json' -print -quit)
    nonce=$(jq -r .nonce "$record")
    "$activation_sh" ack --repo-root "$repo" --session "$session" \
        --skill parallel-issues --nonce "$nonce" >/dev/null
    jq -nc --arg cwd "$repo" --arg session "$session" \
        '{cwd:$cwd,session_id:$session,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"true"}}' |
        "$activation_sh" hook >/dev/null
}

# An invalid origin receipt must fail before any worktree or repository mutation.
refusal_repo="$tmp/refusal-repo"
mkdir -p "$refusal_repo"
make_repo "$refusal_repo" >/dev/null
refusal_exclude=$(<"$refusal_repo/.git/info/exclude")
refusal_rc=0
refusal_out=$("$create_sh" --repo-root "$refusal_repo" --issue 39 --base main \
    --activation-session missing-session 2>&1) || refusal_rc=$?
assert_eq 1 "$refusal_rc" 'an invalid activation session refuses worktree preparation'
assert_contains "$refusal_out" 'no receipt at activation origin' \
    'the refusal names the missing origin receipt'
assert_eq "$refusal_exclude" "$(<"$refusal_repo/.git/info/exclude")" \
    'activation refusal leaves repository excludes unchanged'
assert_eq no "$(git -C "$refusal_repo" show-ref --verify --quiet refs/heads/feat/issue-39 && printf yes || printf no)" \
    'activation refusal creates no local issue branch'
assert_eq no "$(git -C "$refusal_repo" show-ref --verify --quiet refs/remotes/origin/feat/issue-39 && printf yes || printf no)" \
    'activation refusal pushes no remote issue branch'
assert_eq no "$(test -e "$refusal_repo/.fleet/feat/issue-39" && printf yes || printf no)" \
    'activation refusal creates no target worktree'

printf '%s\n' '{"schemaVersion":1,"entries":[{"issue":38,"expectedPredecessors":[],"integrationBaseSha":null,"predictedWriteSet":["seed.txt"]}],"conflictMap":{"pairs":[],"revisions":[]}}' \
    >"$tmp/argument-plan.json"
for bad_args in \
    "--dispatch-plan $tmp/argument-plan.json" \
    '--run-id argument-run' \
    "--dispatch-plan $tmp/argument-plan.json --dispatch-plan $tmp/argument-plan.json --run-id argument-run" \
    '--run-id argument-run --run-id argument-run'; do
    argument_rc=0
    # shellcheck disable=SC2086 # fixture exercises distinct public argv forms
    "$create_sh" --repo-root "$refusal_repo" --issue 38 --base main $bad_args \
        >/dev/null 2>"$tmp/argument.err" || argument_rc=$?
    assert_eq 1 "$argument_rc" "invalid join setup arguments are refused: $bad_args"
done
assert_eq no "$(git -C "$refusal_repo" show-ref --verify --quiet refs/heads/feat/issue-38 && printf yes || printf no)" \
    'invalid join arguments create no local issue branch'

# Exercise the public no-session path on the current shell. The structural
# assertion above pins the nonempty argv required by older Bash nounset.
compat_repo="$tmp/compat-repo"
mkdir -p "$compat_repo"
make_repo "$compat_repo" >/dev/null
compat_rc=0
"$create_sh" --repo-root "$compat_repo" --issue 40 --base main \
    >/dev/null 2>&1 || compat_rc=$?
assert_eq 0 "$compat_rc" 'no-session preparation works on the current shell'

# --- the ordinary case: root has already preflighted itself -----------------
repo="$tmp/repo"
mkdir -p "$repo"
make_repo "$repo" >/dev/null
"$preflight_sh" --worktree "$repo" >/dev/null 2>&1
root_contract="$repo/.agent/env-contract.txt"
assert_eq 'yes' "$([[ -f $root_contract ]] && printf yes || printf no)" \
    'fixture setup: the root has a real preflight contract to inherit from'
activation_session=create-worktree-session
activate_parallel "$repo" "$activation_session"
run_id=create-worktree-run
"$run_state_sh" bind --run-id "$run_id" --repo-root "$repo" \
    --activation-session "$activation_session" >/dev/null
# Simulate compaction: discard the in-memory operands and recover every
# identity from the existing run record through the normal bind operation.
unset activation_session run_id
run_context=$("$run_state_sh" bind --repo-root "$repo" \
    --activation-session create-worktree-session)
run_id=$(jq -r '.run_id' <<<"$run_context")
activation_session=$(jq -r '.activation_session' <<<"$run_context")
assert_eq 'create-worktree-run' "$run_id" 'resume recovers the workflow run ID'
assert_eq 'create-worktree-session' "$activation_session" \
    'resume recovers the activation session separately from the run ID'
assert_eq no "$([[ $run_id == "$activation_session" ]] && printf yes || printf no)" \
    'the worktree consumer never substitutes the run ID for activation session'

out=$(umask 022; "$create_sh" --repo-root "$repo" --issue 41 --base main \
    --activation-session "$activation_session" 2>&1)
rc=$?
assert_eq '0' "$rc" 'issue setup completes'
assert_contains "$out" 'resumable: no untracked=0 modified=0' \
    'new issue setup reports that no resumable state exists'
assert_not_contains "$out" 'setup failed' 'issue setup does not report a setup failure'
worktree="$repo/.fleet/feat/issue-41"
assert_eq no "$(test -e "$worktree/.agent/setup-succeeded" && printf yes || printf no)" \
    'issue setup without a declared command records no completion marker'
assert_eq 'yes' "$([[ -d $worktree ]] && printf yes || printf no)" \
    'issue setup creates the worktree path'
worktree_contract="$worktree/.agent/env-contract.txt"
assert_eq 'yes' "$([[ -f $worktree_contract ]] && printf yes || printf no)" \
    'issue setup leaves a preflight contract in the new worktree'
assert_eq no "$(test -e "$worktree/.agent/activation" && printf yes || printf no)" \
    'issue setup validates the origin receipt without copying it into the target'
assert_eq 644 "$(stat_mode "$worktree/seed.txt")" \
    'issue setup preserves ambient checkout permissions'

for private_dir in prompts evidence logs pr-body; do
    assert_eq 700 "$(stat_mode "$worktree/.agent/$private_dir")" \
        "issue setup creates .agent/$private_dir at mode 0700"
done

for key in sandbox= tls= caches=; do
    root_line=$(grep -m1 "^$key" "$root_contract")
    worktree_line=$(grep -m1 "^$key" "$worktree_contract")
    assert_eq "$root_line" "$worktree_line" \
        "the worktree contract's $key line is byte-identical to the root's"
done

repeat_rc=0
"$create_sh" --repo-root "$repo" --issue 41 --base main --resume \
    --activation-session "$activation_session" >/dev/null 2>&1 || repeat_rc=$?
assert_eq 0 "$repeat_rc" 'repeating activated preparation reuses the acknowledged origin receipt'

# An existing worktree is resumable even when its branch is already upstream;
# report its preserved implementation state before the normal refusal.
printf 'keep implementation\n' >"$worktree/untracked.bicep"
printf 'modified seed\n' >"$worktree/seed.txt"
resume_out=''
resume_rc=0
resume_out=$("$create_sh" --repo-root "$repo" --issue 41 --base main 2>&1) || resume_rc=$?
assert_eq '1' "$resume_rc" 'rerunning an existing issue setup keeps the refusal status'
assert_contains "$resume_out" 'resumable: yes untracked=1 modified=1' \
    'existing worktree reports resumable state and preserved counts'
assert_eq 'keep implementation' "$(<"$worktree/untracked.bicep")" \
    'existing worktree contents survive the detection path'

# Genuinely per-worktree facts are still freshly measured, not copied --
# only sandbox=/tls=/caches= are session-scoped. worktree= must name the NEW
# worktree, not be a stale copy of the root's own worktree= line.
#
# agent-preflight.sh builds worktree= from readlink -f plus the git toplevel,
# which resolves symlinks; $worktree here comes from mktemp -d, which does
# not (issue #332 F6). On a host where the temp root is itself a symlink
# (e.g. macOS's /var -> /private/var) the two would read as byte-different
# for reasons that have nothing to do with the behavior under test. Resolve
# the expected path the same way before comparing.
worktree_resolved=$(readlink -f -- "$worktree")
worktree_only_worktree=$(grep -m1 '^worktree=' "$worktree_contract")
assert_eq "worktree=$worktree_resolved" "$worktree_only_worktree" \
    'the worktree= line is freshly measured for the new worktree, not copied from the root'

# --- a note= on the root's sandbox= line survives into the worktree ---------
notes_root="$tmp/notes-root"
mkdir -p "$notes_root"
make_repo "$notes_root" >/dev/null
notes_contract="$notes_root/.agent/env-contract.txt"
printf '%s\n' \
    'skills= path='"$root"'/agentkit/skills' \
    "$current_harness_line" \
    'sandbox= active=yes profile=strict network=disabled home-writable=no measured-by=agent-shell note="escalate git writes and forge calls; only the workspace is writable"' \
    'tls= bundle=/etc/ssl/certs/ca-certificates.crt source=system corporate-ca=no preset=none uv-system-certs=not-needed' \
    'caches= root=/tmp/agent-cache-notes reason=home-cache-unwritable home-cache=/nonexistent/.cache UV_CACHE_DIR=/tmp/agent-cache-notes/uv NPM_CONFIG_CACHE=/tmp/agent-cache-notes/npm PIP_CACHE_DIR=/tmp/agent-cache-notes/pip XDG_CACHE_HOME=/tmp/agent-cache-notes' \
    >"$notes_contract"
chmod 600 "$notes_contract"
"$create_sh" --repo-root "$notes_root" --issue 42 --base main >/dev/null 2>&1
notes_worktree_contract="$notes_root/.fleet/feat/issue-42/.agent/env-contract.txt"
assert_contains "$(grep '^sandbox=' "$notes_worktree_contract")" \
    'note="escalate git writes and forge calls; only the workspace is writable"' \
    "a note= on the root's authoritative sandbox= line reaches the worktree contract"

# --- a root with no prior contract still succeeds (fresh-probe fallback) ----
fresh_repo="$tmp/fresh-repo"
mkdir -p "$fresh_repo"
make_repo "$fresh_repo" >/dev/null
assert_eq 'no' "$([[ -f "$fresh_repo/.agent/env-contract.txt" ]] && printf yes || printf no)" \
    'fixture setup: this root has never preflighted itself'
fresh_rc=0
"$create_sh" --repo-root "$fresh_repo" --issue 43 --base main >/dev/null 2>&1 || fresh_rc=$?
assert_eq '0' "$fresh_rc" \
    'issue setup succeeds even when the root has no contract to inherit from'
fresh_worktree_contract="$fresh_repo/.fleet/feat/issue-43/.agent/env-contract.txt"
assert_contains "$(grep '^sandbox=' "$fresh_worktree_contract" 2>/dev/null || true)" 'measured-by=' \
    'without a root contract, the worktree still gets a freshly-measured sandbox= line'

# --- the resumable refusal names the resume remedy, never a duplicate branch ---
# `resume_out` above is the refusal captured from rerunning issue 41 without
# --resume (a remote branch already exists for it, per the earlier push).
assert_not_contains "$resume_out" 'choose a different issue branch' \
    'the resumable refusal never tells the caller to pick a different issue branch'
assert_contains "$resume_out" 'resume it with --resume' \
    'the resumable refusal names --resume as the remedy'

# --- --resume on an existing worktree refreshes the contract in place -------
resume_repo="$tmp/resume-repo"
mkdir -p "$resume_repo"
make_repo "$resume_repo" >/dev/null
"$preflight_sh" --worktree "$resume_repo" >/dev/null 2>&1
resume_create_rc=0
"$create_sh" --repo-root "$resume_repo" --issue 44 --base main >/dev/null 2>&1 || resume_create_rc=$?
assert_eq '0' "$resume_create_rc" 'fixture setup: the resumable worktree was created cleanly'
resume_worktree="$resume_repo/.fleet/feat/issue-44"
resume_worktree_contract="$resume_worktree/.agent/env-contract.txt"

# Simulate the field defect: a stale contract left behind by a hand resume
# (issue #585) -- a bogus skills= path and an unauthenticated gh= line that a
# real preflight run would never produce for this environment.
printf '%s\n' \
    'skills= path=/stale/agentkit/0.7.2/skills' \
    'gh= authed=no scopes=none api=unreachable note="stale fixture contract"' \
    >"$resume_worktree_contract"

resume_flag_out=''
resume_flag_rc=0
resume_flag_out=$("$create_sh" --repo-root "$resume_repo" --issue 44 --base main --resume 2>&1) || resume_flag_rc=$?
assert_eq '0' "$resume_flag_rc" '--resume on a registered worktree exits 0'
assert_contains "$resume_flag_out" "worktree=$resume_worktree branch=feat/issue-44" \
    '--resume prints the standard worktree= line'
assert_not_contains "$(cat "$resume_worktree_contract")" '/stale/agentkit/0.7.2/skills' \
    '--resume overwrites the stale skills= path with a freshly measured one'
assert_not_contains "$(cat "$resume_worktree_contract")" 'stale fixture contract' \
    '--resume overwrites the stale gh= line with a freshly measured one'

# --- --resume on a nonexistent worktree fails with a clear message ----------
noresume_out=''
noresume_rc=0
noresume_out=$("$create_sh" --repo-root "$resume_repo" --issue 45 --base main --resume 2>&1) || noresume_rc=$?
assert_eq '1' "$noresume_rc" '--resume on a nonexistent worktree fails'
assert_contains "$noresume_out" 'no worktree is registered' \
    '--resume on a nonexistent worktree names the problem clearly'
assert_eq 'no' "$([[ -e "$resume_repo/.fleet/feat/issue-45" ]] && printf yes || printf no)" \
    '--resume on a nonexistent worktree creates nothing'

# --- issue #588 finding 1: a plain directory at the path is never mistaken --
# --- for a registered worktree (rev-parse --is-inside-work-tree walks up ----
# --- into the parent repo and would wrongly say yes) ------------------------
plain_dir="$resume_repo/.fleet/feat/issue-46"
mkdir -p "$plain_dir"
printf 'not a worktree\n' >"$plain_dir/decoy.txt"
plaindir_out=''
plaindir_rc=0
plaindir_out=$("$create_sh" --repo-root "$resume_repo" --issue 46 --base main --resume 2>&1) || plaindir_rc=$?
assert_eq '1' "$plaindir_rc" '--resume refuses a plain directory standing in for the worktree'
assert_contains "$plaindir_out" 'is not a registered git worktree' \
    'the plain-directory refusal names the actual problem'
assert_eq 'not a worktree' "$(cat "$plain_dir/decoy.txt")" \
    'the plain directory refusal never touches the occupying directory'

# --- issue #588 finding 1: a worktree registered on a DIFFERENT branch is ---
# --- refused, not silently adopted ------------------------------------------
otherbranch_worktree="$resume_repo/.fleet/feat/issue-47"
git -C "$resume_repo" worktree add "$otherbranch_worktree" -b not-issue-47 origin/main >/dev/null 2>&1
otherbranch_out=''
otherbranch_rc=0
otherbranch_out=$("$create_sh" --repo-root "$resume_repo" --issue 47 --base main --resume 2>&1) || otherbranch_rc=$?
assert_eq '1' "$otherbranch_rc" '--resume refuses a worktree registered on a different branch'
assert_contains "$otherbranch_out" 'registered worktree on refs/heads/not-issue-47' \
    'the different-branch refusal names the branch actually checked out there'

# --- issue #588 finding 2: a worktree that exists locally but was never -----
# --- pushed (a died-mid-creation simulation) gets pushed and tracked on -----
# --- --resume, not silently reported as done ---------------------------------
unpushed_branch=feat/issue-48
unpushed_worktree="$resume_repo/.fleet/feat/issue-48"
git -C "$resume_repo" worktree add "$unpushed_worktree" -b "$unpushed_branch" origin/main >/dev/null 2>&1
for private_dir in prompts evidence logs pr-body; do
    (umask 077; mkdir -p -- "$unpushed_worktree/.agent/$private_dir")
done
assert_eq 'no' "$(git -C "$resume_repo" show-ref --verify --quiet "refs/remotes/origin/$unpushed_branch" && printf yes || printf no)" \
    'fixture setup: the simulated died-mid-creation branch was never pushed'
unpushed_rc=0
"$create_sh" --repo-root "$resume_repo" --issue 48 --base main --resume >/dev/null 2>&1 || unpushed_rc=$?
assert_eq '0' "$unpushed_rc" '--resume on an unpushed worktree succeeds'
assert_eq 'yes' "$(git -C "$resume_repo" show-ref --verify --quiet "refs/remotes/origin/$unpushed_branch" && printf yes || printf no)" \
    '--resume pushes the branch that a died-mid-creation run left unpushed'
assert_eq "origin/$unpushed_branch" "$(git -C "$unpushed_worktree" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" \
    '--resume leaves the branch tracking its origin upstream'

# --- issue #588 finding 3: a pushed branch whose local worktree was pruned --
# --- is recreated by --resume, not left permanently unresumable -------------
pruned_rc=0
"$create_sh" --repo-root "$resume_repo" --issue 49 --base main >/dev/null 2>&1 || pruned_rc=$?
assert_eq '0' "$pruned_rc" 'fixture setup: issue 49 was created and pushed cleanly'
pruned_worktree="$resume_repo/.fleet/feat/issue-49"
git -C "$resume_repo" worktree remove --force "$pruned_worktree" >/dev/null 2>&1
assert_eq 'no' "$([[ -e $pruned_worktree ]] && printf yes || printf no)" \
    'fixture setup: the issue 49 worktree was pruned from disk'
assert_eq 'yes' "$(git -C "$resume_repo" show-ref --verify --quiet 'refs/remotes/origin/feat/issue-49' && printf yes || printf no)" \
    'fixture setup: the pushed origin/feat/issue-49 branch survives the prune'
recreate_out=''
recreate_rc=0
recreate_out=$("$create_sh" --repo-root "$resume_repo" --issue 49 --base main --resume 2>&1) || recreate_rc=$?
assert_eq '0' "$recreate_rc" '--resume recreates a pruned worktree from its pushed branch'
assert_contains "$recreate_out" "worktree=$pruned_worktree branch=feat/issue-49" \
    'the recreated worktree prints the standard worktree= line'
assert_eq 'yes' "$([[ -d $pruned_worktree ]] && printf yes || printf no)" \
    '--resume recreates the worktree directory on disk'

# --- complete join bases come from the saved plan and accepted publications -
join_repo="$tmp/join-repo"
mkdir -p "$join_repo"
make_repo "$join_repo" >/dev/null
"$preflight_sh" --worktree "$join_repo" >/dev/null 2>&1

make_predecessor() {
    local repo=$1 issue=$2 path=$3 content=$4 branch head
    branch="feat/issue-$issue"
    git -C "$repo" checkout -qb "$branch" main
    printf '%s\n' "$content" >"$repo/$path"
    git -C "$repo" add -- "$path"
    git -C "$repo" commit -qm "issue $issue"
    head=$(git -C "$repo" rev-parse HEAD)
    git -C "$repo" push -q origin "$branch"
    git -C "$repo" checkout -q main
    printf '%s\n' "$head"
}

join_a=$(make_predecessor "$join_repo" 61 a.txt alpha)
join_b=$(make_predecessor "$join_repo" 62 b.txt beta)
join_c=$(make_predecessor "$join_repo" 63 c.txt gamma)
conflict_left=$(make_predecessor "$join_repo" 81 seed.txt left)
conflict_right=$(make_predecessor "$join_repo" 82 seed.txt right)
identical_left=$(make_predecessor "$join_repo" 83 seed.txt identical)
identical_right=$(make_predecessor "$join_repo" 84 seed.txt identical)
join_run=join-run
for record in "61:$join_a" "62:$join_b" "63:$join_c" \
    "81:$conflict_left" "82:$conflict_right" \
    "83:$identical_left" "84:$identical_right"; do
    predecessor=${record%%:*}
    predecessor_head=${record#*:}
    publication=$(jq -nc --arg attempt "attempt-$predecessor" \
        --arg branch "feat/issue-$predecessor" --arg headSha "$predecessor_head" \
        '{attempt:$attempt,branch:$branch,headSha:$headSha}')
    "$run_state_sh" set --run-id "$join_run" --repo-root "$join_repo" \
        --path "initialPublications.$predecessor" --json "$publication"
done

join_plan="$tmp/join-plan.json"
jq -n '{schemaVersion:1,entries:[
    {issue:70,publicationTarget:"main",expectedPredecessors:[61,62,63],integrationBaseSha:null,predictedWriteSet:["seed.txt"]},
    {issue:71,publicationTarget:"main",expectedPredecessors:[61,99],integrationBaseSha:null,predictedWriteSet:["seed.txt"]},
    {issue:72,publicationTarget:"main",expectedPredecessors:[61,62],integrationBaseSha:null,predictedWriteSet:["seed.txt"]},
    {issue:73,publicationTarget:"main",expectedPredecessors:[61,62],integrationBaseSha:null,predictedWriteSet:["seed.txt"]},
    {issue:74,publicationTarget:"main",expectedPredecessors:[83,84],integrationBaseSha:null,predictedWriteSet:["seed.txt"]},
    {issue:75,publicationTarget:"main",expectedPredecessors:[61,62],integrationBaseSha:null,predictedWriteSet:["seed.txt"]},
    {issue:80,publicationTarget:"main",expectedPredecessors:[81,82],integrationBaseSha:null,predictedWriteSet:["seed.txt"]}
],conflictMap:{pairs:[],revisions:[]}}' >"$join_plan"

missing_rc=0
missing_out=$("$create_sh" --repo-root "$join_repo" --issue 71 --base main \
    --dispatch-plan "$join_plan" --run-id "$join_run" 2>&1) || missing_rc=$?
assert_eq 1 "$missing_rc" 'a join with an unpublished planned predecessor stays queued'
assert_contains "$missing_out" 'missing initial publication for predecessor #99' \
    'the queued join names the missing planned predecessor'
assert_eq no "$(git -C "$join_repo" show-ref --verify --quiet refs/heads/feat/issue-71 && printf yes || printf no)" \
    'an incomplete join creates no implementation branch'

join_out=$("$create_sh" --repo-root "$join_repo" --issue 70 --base main \
    --dispatch-plan "$join_plan" --run-id "$join_run" 2>&1)
join_worktree="$join_repo/.fleet/feat/issue-70"
join_head=$(git -C "$join_worktree" rev-parse HEAD)
assert_contains "$join_out" "join-base=$join_head predecessors=61,62,63" \
    'three-parent assembly reports its exact complete integration base'
for predecessor_head in "$join_a" "$join_b" "$join_c"; do
    assert_rc 0 "published join contains predecessor $predecessor_head" -- \
        git -C "$join_worktree" merge-base --is-ancestor "$predecessor_head" "$join_head"
done
assert_eq "$join_head" "$(git -C "$join_repo" ls-remote --refs origin refs/heads/feat/issue-70 | awk '{print $1}')" \
    'implementation receives the exact published integration base'
assert_eq "$join_head" "$(jq -r '.entries[] | select(.issue == 70) | .integrationBaseSha' "$join_plan")" \
    'saved plan records the integration base separately from publicationTarget'
assert_eq main "$(jq -r '.entries[] | select(.issue == 70) | .publicationTarget' "$join_plan")" \
    'join assembly preserves the PR publication target'

resume_head_before=$join_head
resume_out=$("$create_sh" --repo-root "$join_repo" --issue 70 --base main \
    --dispatch-plan "$join_plan" --run-id "$join_run" --resume 2>&1)
assert_eq "$resume_head_before" "$(git -C "$join_worktree" rev-parse HEAD)" \
    'repeat setup resumes without recreating merge commits'
assert_contains "$resume_out" "join-base=$resume_head_before predecessors=61,62,63" \
    'repeat setup reuses the recorded complete join'

# The recorded integration base remains immutable after implementation or
# review commits advance both the local and published branch.
printf 'implementation\n' >"$join_worktree/implementation.txt"
git -C "$join_worktree" add -- implementation.txt
git -C "$join_worktree" commit -qm 'implementation after join base'
git -C "$join_worktree" push -q
advanced_head=$(git -C "$join_worktree" rev-parse HEAD)
advanced_rc=0
advanced_out=$("$create_sh" --repo-root "$join_repo" --issue 70 --base main \
    --dispatch-plan "$join_plan" --run-id "$join_run" --resume 2>&1) || advanced_rc=$?
assert_eq 0 "$advanced_rc" 'resume accepts an advanced branch above its immutable integration base'
assert_eq "$advanced_head" "$(git -C "$join_worktree" rev-parse HEAD)" \
    'resume preserves implementation commits above the recorded integration base'
assert_contains "$advanced_out" "join-base=$resume_head_before predecessors=61,62,63" \
    'resume accepts a recorded integration base reachable from an advanced remote tip'

# A caller-supplied first predecessor is only a candidate starting point; it
# cannot narrow the expected set saved in the plan.
candidate_out=$("$create_sh" --repo-root "$join_repo" --issue 72 --base main \
    --chain-base "$join_a" --dispatch-plan "$join_plan" --run-id "$join_run" 2>&1)
candidate_worktree="$join_repo/.fleet/feat/issue-72"
candidate_head=$(git -C "$candidate_worktree" rev-parse HEAD)
assert_contains "$candidate_out" 'predecessors=61,62' \
    'a supplied single-parent base still assembles every planned predecessor'
assert_rc 0 'the remaining predecessor is present above the supplied candidate' -- \
    git -C "$candidate_worktree" merge-base --is-ancestor "$join_b" "$candidate_head"

# A pushed single-parent partial branch is resumable progress, never proof of
# a complete join. Resume adds only the missing planned predecessor.
partial_worktree="$join_repo/.fleet/feat/issue-73"
git -C "$join_repo" worktree add "$partial_worktree" -b feat/issue-73 "$join_a" >/dev/null 2>&1
git -C "$partial_worktree" push -q --set-upstream origin feat/issue-73
partial_before=$(git -C "$partial_worktree" rev-parse HEAD)
partial_out=$("$create_sh" --repo-root "$join_repo" --issue 73 --base main \
    --dispatch-plan "$join_plan" --run-id "$join_run" --resume 2>&1)
partial_after=$(git -C "$partial_worktree" rev-parse HEAD)
assert_eq no "$([[ $partial_before == "$partial_after" ]] && printf yes || printf no)" \
    'resume advances a partially published join'
assert_contains "$partial_out" "join-base=$partial_after predecessors=61,62" \
    'partial resume publishes the completed join identity'
assert_rc 0 'partial resume includes the missing second predecessor' -- \
    git -C "$partial_worktree" merge-base --is-ancestor "$join_b" "$partial_after"

# A stale local branch must never make setup hand a trunk checkout to the
# implementation worker merely because the recorded remote base is complete.
"$create_sh" --repo-root "$join_repo" --issue 75 --base main \
    --dispatch-plan "$join_plan" --run-id "$join_run" >/dev/null 2>&1
stale_base=$(git -C "$join_repo/.fleet/feat/issue-75" rev-parse HEAD)
git -C "$join_repo" worktree remove --force "$join_repo/.fleet/feat/issue-75" >/dev/null 2>&1
git -C "$join_repo" branch -f feat/issue-75 main >/dev/null
stale_resume_rc=0
stale_resume_out=$("$create_sh" --repo-root "$join_repo" --issue 75 --base main \
    --dispatch-plan "$join_plan" --run-id "$join_run" --resume 2>&1) || stale_resume_rc=$?
assert_eq 1 "$stale_resume_rc" 'resume refuses a checkout that omits the recorded integration base'
assert_contains "$stale_resume_out" "worktree does not contain recorded integration base $stale_base" \
    'the stale-checkout refusal names the missing recorded base'
assert_not_contains "$stale_resume_out" 'join-base=' \
    'a stale local checkout cannot dispatch implementation'

# Distinct predecessor commits may have identical trees. The second merge is
# still recorded so ancestry, not staged-path count, proves complete assembly.
identical_out=$("$create_sh" --repo-root "$join_repo" --issue 74 --base main \
    --dispatch-plan "$join_plan" --run-id "$join_run" 2>&1)
identical_worktree="$join_repo/.fleet/feat/issue-74"
identical_head=$(git -C "$identical_worktree" rev-parse HEAD)
assert_contains "$identical_out" "join-base=$identical_head predecessors=83,84" \
    'an empty-tree second merge still publishes a complete join base'
assert_rc 0 'identical-change join contains the first predecessor' -- \
    git -C "$identical_worktree" merge-base --is-ancestor "$identical_left" "$identical_head"
assert_rc 0 'identical-change join contains the second predecessor' -- \
    git -C "$identical_worktree" merge-base --is-ancestor "$identical_right" "$identical_head"
assert_eq 3 "$(git -C "$identical_worktree" rev-list --parents -n 1 "$identical_head" | awk '{print NF}')" \
    'the protected commit helper records the empty-tree predecessor as a merge parent'

# Conflicts remain in the same sole-writer worktree for automatic resolution.
# No implementation branch is published until a resolution preserves both
# behaviors and resume proves the combined result.
conflict_rc=0
conflict_out=$("$create_sh" --repo-root "$join_repo" --issue 80 --base main \
    --dispatch-plan "$join_plan" --run-id "$join_run" 2>&1) || conflict_rc=$?
conflict_worktree="$join_repo/.fleet/feat/issue-80"
assert_eq 3 "$conflict_rc" 'a content conflict requests the resolution-only worker path'
assert_contains "$conflict_out" 'next=resolution-worker-then-resume' \
    'conflict output names the automatic resolution continuation'
assert_eq conflict "$("$run_state_sh" get --run-id "$join_run" --repo-root "$join_repo" \
    --path joins.80.status)" 'conflict state is durable for resume'
assert_rc 0 'the unresolved join preserves MERGE_HEAD for the sole writer' -- \
    git -C "$conflict_worktree" rev-parse -q --verify MERGE_HEAD
assert_eq no "$(git -C "$join_repo" show-ref --verify --quiet refs/remotes/origin/feat/issue-80 && printf yes || printf no)" \
    'a conflicted partial join is not published as an implementation base'

resolution_prompt="$conflict_worktree/.agent/prompts/join-resolution.md"
"$compose_worker_sh" --template join-resolution --write-set seed.txt \
    --dispatch-plan "$join_plan" --worktree "$conflict_worktree" --issue 80 \
    --branch feat/issue-80 --worker-model gpt-5.6-luna --worker-effort high \
    --output "$resolution_prompt" >/dev/null

run_resolution_worker() {
    local prompt=$1 worktree=$2 mode=$3 merge_head
    grep -Fq 'resolution-only worker' "$prompt" || return 2
    git -C "$worktree" rev-parse -q --verify MERGE_HEAD >/dev/null || return 2
    [[ $mode != fail-validation ]] || return 1
    printf 'left\nright\n' >"$worktree/seed.txt"
    git -C "$worktree" add -- seed.txt
    merge_head=$(git -C "$worktree" rev-parse MERGE_HEAD)
    (cd "$worktree" && "$worktree_commit_sh" --include-staged \
        --message 'chore(chains): preserve both predecessor behaviors' \
        --allow-base-inherited "$merge_head" --yolo -- seed.txt) >/dev/null
    printf 'join-resolution=committed head=%s\n' "$(git -C "$worktree" rev-parse HEAD)"
}

failed_resolution_rc=0
run_resolution_worker "$resolution_prompt" "$conflict_worktree" fail-validation \
    >/dev/null || failed_resolution_rc=$?
assert_eq 1 "$failed_resolution_rc" 'resolution-only validation failure returns blocked work'
assert_rc 0 'failed resolution keeps the active merge resumable' -- \
    git -C "$conflict_worktree" rev-parse -q --verify MERGE_HEAD
assert_eq conflict "$("$run_state_sh" get --run-id "$join_run" --repo-root "$join_repo" \
    --path joins.80.status)" 'failed resolution retains durable conflict state'
assert_eq no "$(git -C "$join_repo" show-ref --verify --quiet refs/remotes/origin/feat/issue-80 && printf yes || printf no)" \
    'failed resolution cannot publish or start implementation'

resolution_marker=$(run_resolution_worker "$resolution_prompt" "$conflict_worktree" resolve)
assert_contains "$resolution_marker" 'join-resolution=committed head=' \
    'the composed resolution-only worker returns the setup resume marker'
resolved_out=$("$create_sh" --repo-root "$join_repo" --issue 80 --base main \
    --dispatch-plan "$join_plan" --run-id "$join_run" --resume 2>&1)
resolved_head=$(git -C "$conflict_worktree" rev-parse HEAD)
assert_contains "$resolved_out" "join-base=$resolved_head predecessors=81,82" \
    'resume publishes the behavior-preserving conflict resolution'
assert_eq $'left\nright' "$(cat "$conflict_worktree/seed.txt")" \
    'combined join preserves both predecessor behaviors'
assert_rc 0 'resolved join contains the left predecessor' -- \
    git -C "$conflict_worktree" merge-base --is-ancestor "$conflict_left" "$resolved_head"
assert_rc 0 'resolved join contains the right predecessor' -- \
    git -C "$conflict_worktree" merge-base --is-ancestor "$conflict_right" "$resolved_head"

# Issue #910: join-plan/run-state wiring adds only the public options and one
# call into the focused join helper; hold the setup script at its new boundary.
assert_eq yes "$([[ $(wc -l < "$root/agentkit/skills/parallel-issues/scripts/create-issue-worktree.sh") -le 347 ]] && printf yes || printf no)" \
    'create-issue-worktree.sh stays at or under 347 lines'
assert_eq yes "$([[ $(wc -l < "$root/agentkit/skills/parallel-issues/scripts/lib/join-base.sh") -le 219 ]] && printf yes || printf no)" \
    'the private join assembly library stays at or under 219 lines'

finish
