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
preflight_sh="$root/agentkit/skills/.shared/scripts/agent-preflight.sh"
harness_id_script="$root/agentkit/skills/.shared/scripts/harness-id.sh"
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
        'AGENT_BASE_BRANCH=main' \
        'AGENT_WORKTREE_ROOT=.fleet' \
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

# --- the ordinary case: root has already preflighted itself -----------------
repo="$tmp/repo"
mkdir -p "$repo"
make_repo "$repo" >/dev/null
"$preflight_sh" --worktree "$repo" >/dev/null 2>&1
root_contract="$repo/.agent/env-contract.txt"
assert_eq 'yes' "$([[ -f $root_contract ]] && printf yes || printf no)" \
    'fixture setup: the root has a real preflight contract to inherit from'

out=$(umask 022; "$create_sh" --repo-root "$repo" --issue 41 --base main 2>&1)
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

finish
