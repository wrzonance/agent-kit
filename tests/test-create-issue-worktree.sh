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

finish
