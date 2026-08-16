#!/usr/bin/env bash
# Suite: issue and pull-request worktree setup entry points.
set -uo pipefail

TEST_NAME='worktree-setup'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

create_sh="$root/agentkit/skills/parallel-issues/scripts/create-issue-worktree.sh"
pr_sh="$root/agentkit/skills/review-remote-pr/scripts/pr-worktree.sh"
shared_sh="$root/agentkit/skills/.shared/scripts/lib/worktree-setup.sh"
tty_approve="$here/lib/tty-approve"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
# shellcheck source=../agentkit/skills/.shared/scripts/lib/worktree-setup.sh
source "$shared_sh"

assert_file() {
    local path=$1 label=$2
    if [[ -f $path && ! -L $path ]]; then
        printf 'ok - %s\n' "$label"
    else
        printf 'not ok - %s\n' "$label" >&2
        return 1
    fi
}

assert_exec() {
    local path=$1 label=$2
    if [[ -x $path && ! -L $path ]]; then
        printf 'ok - %s\n' "$label"
    else
        printf 'not ok - %s\n' "$label" >&2
        return 1
    fi
}

assert_file "$shared_sh" 'shared worktree setup library exists'
assert_exec "$create_sh" 'issue worktree entry point is executable'
assert_exec "$pr_sh" 'PR worktree entry point is executable'

if [[ -x $create_sh ]]; then
    assert_rc 0 'issue entry point exposes help' -- "$create_sh" --help
fi
if [[ -x $pr_sh ]]; then
    assert_rc 0 'PR entry point exposes help' -- "$pr_sh" --help
fi

make_repo() {
    local repo=$1 origin
    origin=$tmp/"$(basename "$1")-origin"
    git init -q --bare "$origin"
    git init -q -b main "$repo"
    git -C "$repo" config user.name test
    git -C "$repo" config user.email test@example.invalid
    mkdir -p "$repo/.agent" "$repo/tools"
    printf '%s\n' \
        'AGENT_BASE_BRANCH=main' \
        'AGENT_WORKTREE_ROOT=.fleet' \
        'AGENT_CMD_SETUP=tools/setup' \
        >"$repo/.agent/config.env"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf setup-ran > setup.marker' >"$repo/tools/setup"
    chmod +x "$repo/tools/setup"
    git -C "$repo" add -- tools/setup
    git -C "$repo" commit -qm base
    git -C "$repo" remote add origin "$origin"
    git -C "$repo" push -q origin main
    git -C "$repo" fetch -q origin
    printf '.agent/config.env\n' >>"$repo/.git/info/exclude"
    printf '%s\n' "$repo"
}

repo=$tmp/repo
mkdir -p "$repo"
if [[ -x $create_sh ]]; then
    make_repo "$repo" >/dev/null
    trust=$tmp/trust
    mkdir -p "$trust"
    out=$($tty_approve y -- env AGENT_TRUST_ROOT="$trust" "$create_sh" \
        --repo-root "$repo" --issue 7 --base main 2>&1)
    rc=$?
    assert_eq '1' "$rc" 'issue setup stops for setup approval'
    issue_worktree="$repo/.fleet/feat/issue-7"
    assert_eq 'yes' "$([[ -d $issue_worktree ]] && printf yes || printf no)" \
        'issue setup creates the configured worktree path'
    assert_eq 'yes' "$(grep -Fxq '.fleet/' "$repo/.git/info/exclude" && printf yes || printf no)" \
        'issue setup excludes the configured worktree root'
    assert_eq 'yes' "$(git -C "$repo" show-ref --verify --quiet refs/remotes/origin/feat/issue-7 && printf yes || printf no)" \
        'issue setup pushes the new branch upstream'
    assert_eq "$(<"$repo/.agent/config.env")" "$(<"$issue_worktree/.agent/config.env")" \
        'issue setup propagates the ignored root-local config'
    assert_eq 'yes' "$(git -C "$repo" check-ignore -q .agent/config.env && printf yes || printf no)" \
        'root-local config remains ignored'
    assert_eq '!! .agent/config.env' "$(git -C "$repo" status --porcelain --ignored -- .agent/config.env)" \
        'root-local config remains untracked'
    assert_contains "$out" 'setup failed' 'issue setup reports the setup approval boundary'

    # Approve the exact propagated target once, then exercise the same shared
    # declared-setup dispatch used by the entry point through agent-run.sh.
    export AGENT_TRUST_ROOT=$trust
    $tty_approve y -- \
        "$root/agentkit/skills/.shared/scripts/agent-run.sh" \
        --dir "$issue_worktree" --approve --cmd setup >/dev/null 2>&1
    worktree_setup_declared_setup "$root/agentkit/skills/.shared/scripts/repo-config.sh" \
        "$root/agentkit/skills/.shared/scripts/agent-run.sh" "$issue_worktree"
    assert_eq 'setup-ran' "$(<"$issue_worktree/setup.marker")" \
        'declared issue setup runs through agent-run after approval'
fi

# The entry points pass a declared setup through the shared command runner
# boundary. A fake runner keeps this focused test independent of the interactive
# approval record owned by agent-run.sh itself.
dispatch_root=$tmp/dispatch
dispatch_worktree=$dispatch_root/worktree
mkdir -p "$dispatch_worktree/.agent" "$dispatch_root/tools"
printf '%s\n' 'AGENT_CMD_SETUP=tools/setup' >"$dispatch_worktree/.agent/config.env"
fake_runner=$dispatch_root/fake-agent-run.sh
# shellcheck disable=SC2016  # the fixture intentionally records literal argv text.
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\\n" "$*" > "$WORKTREE_SETUP_TEST_ARGS"' >"$fake_runner"
chmod +x "$fake_runner"
WORKTREE_SETUP_TEST_ARGS=$dispatch_root/setup-args
export WORKTREE_SETUP_TEST_ARGS
worktree_setup_declared_setup "$root/agentkit/skills/.shared/scripts/repo-config.sh" \
    "$fake_runner" "$dispatch_worktree"
assert_eq "--dir $dispatch_worktree --cmd setup" "$(<"$WORKTREE_SETUP_TEST_ARGS")" \
    'shared setup dispatch uses agent-run with the named setup command'

# Root-local state is copied only into a safe, empty target. Existing regular
# targets are preserved, while either side of a symlink boundary fails closed.
secure_root=$tmp/secure-root
secure_worktree=$tmp/secure-worktree
mkdir -p "$secure_root/.agent" "$secure_worktree"
printf '%s\n' 'AGENT_CMD_SETUP=tools/setup' >"$secure_root/.agent/config.env"
worktree_setup_propagate_config "$secure_root" "$secure_worktree"
assert_eq "$(<"$secure_root/.agent/config.env")" "$(<"$secure_worktree/.agent/config.env")" \
    'config propagation creates a private target file'
printf '%s\n' trusted >"$secure_worktree/.agent/config.env"
worktree_setup_propagate_config "$secure_root" "$secure_worktree"
assert_eq trusted "$(<"$secure_worktree/.agent/config.env")" \
    'config propagation preserves an existing regular target'
rm -f -- "$secure_worktree/.agent/config.env"
ln -s "$secure_root/.agent/config.env" "$secure_worktree/.agent/config.env"
propagate_ok=yes
worktree_setup_propagate_config "$secure_root" "$secure_worktree" >/dev/null 2>&1 || propagate_ok=no
assert_eq no "$propagate_ok" 'config propagation rejects a target symlink'
assert_eq yes "$(test -L "$secure_worktree/.agent/config.env" && printf yes || printf no)" \
    'config propagation leaves a target symlink untouched'
rm -f -- "$secure_worktree/.agent/config.env" "$secure_root/.agent/config.env"
ln -s "$secure_root/missing-config.env" "$secure_root/.agent/config.env"
propagate_ok=yes
worktree_setup_propagate_config "$secure_root" "$secure_worktree" >/dev/null 2>&1 || propagate_ok=no
assert_eq no "$propagate_ok" 'config propagation rejects a source symlink'
assert_eq no "$(test -e "$secure_worktree/.agent/config.env" && printf yes || printf no)" \
    'config propagation does not create a target for a source symlink'

# A target directory can appear after the existence check. The placement must
# not let mv reinterpret it as a directory destination and report success.
race_root=$tmp/race-root
race_worktree=$tmp/race-worktree
race_bin=$tmp/race-bin
mkdir -p "$race_root/.agent" "$race_worktree" "$race_bin"
printf '%s\n' 'AGENT_CMD_SETUP=tools/setup' >"$race_root/.agent/config.env"
race_mv=$race_bin/mv
# shellcheck disable=SC2016  # the fixture intentionally records literal env refs.
printf '%s\n' '#!/usr/bin/env bash' \
    'mkdir -p -- "$WORKTREE_SETUP_RACE_TARGET"' \
    'exec "$WORKTREE_SETUP_REAL_MV" "$@"' >"$race_mv"
chmod +x "$race_mv"
real_mv=$(command -v mv)
race_ok=yes
PATH="$race_bin:$PATH" WORKTREE_SETUP_RACE_TARGET="$race_worktree/.agent/config.env" \
    WORKTREE_SETUP_REAL_MV="$real_mv" \
    worktree_setup_propagate_config "$race_root" "$race_worktree" >/dev/null 2>&1 || race_ok=no
assert_eq no "$race_ok" 'config propagation rejects a raced target directory'
assert_eq yes "$(test -d "$race_worktree/.agent/config.env" && printf yes || printf no)" \
    'config propagation leaves the raced target directory in place'
assert_eq no "$(test -f "$race_worktree/.agent/config.env/config.env" && printf yes || printf no)" \
    'config propagation does not place config inside the raced directory'

if [[ -x $create_sh ]]; then
    assert_rc 1 'issue setup rejects an invalid issue number' -- \
        "$create_sh" --repo-root "$repo" --issue 0 --base main
    assert_rc 1 'issue setup rejects an abbreviated chain base' -- \
        "$create_sh" --repo-root "$repo" --issue 8 --base main --chain-base abc
fi

if [[ -x $pr_sh ]]; then
    assert_rc 1 'PR setup rejects an invalid PR number before forge access' -- \
        "$pr_sh" --pr 0 --repo example/repo
    assert_rc 1 'PR setup rejects an invalid repository slug before forge access' -- \
        "$pr_sh" --pr 9 --repo example
fi

# Exercise the two PR creation branches with a local origin and a tiny gh
# fixture. The fixture records calls but never contacts a forge.
fake_bin=$tmp/fake-bin
mkdir -p "$fake_bin"
fake_gh=$fake_bin/gh
# shellcheck disable=SC2016  # fixture expands its own positional arguments.
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\\n" "$*" >> "$WORKTREE_SETUP_GH_LOG"' \
    'case "$*" in' \
    '  *"pr view 9"*headRefName*) printf "%s\\n" feat/pr-head ;;' \
    '  *"pr view 9"*isCrossRepository*) printf "%s\\n" false ;;' \
    '  *"pr view 10"*headRefName*) printf "%s\\n" fork/pr-head ;;' \
    '  *"pr view 10"*isCrossRepository*) printf "%s\\n" true ;;' \
    '  *"pr checkout 10"*) exit 0 ;;' \
    '  *) exit 1 ;;' \
    'esac' >"$fake_gh"
fake_jq=$fake_bin/jq
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fake_jq"
chmod +x "$fake_gh" "$fake_jq"

if [[ -x $pr_sh ]]; then
    pr_repo=$tmp/pr-repo
    mkdir -p "$pr_repo"
    make_repo "$pr_repo" >/dev/null
    git -C "$pr_repo" switch -q -c feat/pr-head
    git -C "$pr_repo" push -q origin feat/pr-head
    git -C "$pr_repo" switch -q main
    gh_log=$tmp/gh.log
    : >"$gh_log"
    out=$(cd "$pr_repo" && PATH="$fake_bin:$PATH" \
        AGENT_WORKTREE_ROOT=wrong-root WORKTREE_SETUP_GH_LOG="$gh_log" \
        "$pr_sh" --pr 9 --repo example/repo 2>&1)
    rc=$?
    assert_eq '1' "$rc" 'same-repository PR setup stops for setup approval'
    assert_eq 'yes' "$(test -d "$pr_repo/.fleet/pr-9" && printf yes || printf no)" \
        'same-repository PR setup uses the configured root after export'
    assert_eq 'yes' "$(grep -Fxq '.fleet/' "$pr_repo/.git/info/exclude" && printf yes || printf no)" \
        'same-repository PR setup excludes the configured root'
    assert_not_contains "$out" 'wrong-root' \
        'same-repository PR setup does not use a stale inherited root'
    assert_eq "$(<"$pr_repo/.agent/config.env")" "$(<"$pr_repo/.fleet/pr-9/.agent/config.env")" \
        'same-repository PR setup propagates the ignored root-local config'
    assert_contains "$out" 'setup failed' \
        'same-repository PR setup reports the setup approval boundary'
    $tty_approve y -- \
        "$root/agentkit/skills/.shared/scripts/agent-run.sh" \
        --dir "$pr_repo/.fleet/pr-9" --approve --cmd setup >/dev/null 2>&1
    worktree_setup_declared_setup "$root/agentkit/skills/.shared/scripts/repo-config.sh" \
        "$root/agentkit/skills/.shared/scripts/agent-run.sh" "$pr_repo/.fleet/pr-9"
    assert_eq 'setup-ran' "$(<"$pr_repo/.fleet/pr-9/setup.marker")" \
        'same-repository PR setup runs through agent-run after approval'

    fork_repo=$tmp/fork-repo
    mkdir -p "$fork_repo"
    make_repo "$fork_repo" >/dev/null
    : >"$gh_log"
    out=$(cd "$fork_repo" && PATH="$fake_bin:$PATH" \
        WORKTREE_SETUP_GH_LOG="$gh_log" "$pr_sh" --pr 10 --repo example/repo 2>&1)
    rc=$?
    assert_eq '1' "$rc" 'cross-repository PR setup stops for setup approval'
    assert_eq 'yes' "$(test -d "$fork_repo/.fleet/pr-10" && printf yes || printf no)" \
        'cross-repository PR setup creates the configured worktree'
    assert_eq "$(<"$fork_repo/.agent/config.env")" "$(<"$fork_repo/.fleet/pr-10/.agent/config.env")" \
        'cross-repository PR setup propagates the ignored root-local config'
    assert_contains "$(<"$gh_log")" 'pr checkout 10 --repo example/repo' \
        'cross-repository PR setup delegates checkout to gh'
    assert_contains "$out" 'setup failed' \
        'cross-repository PR setup reports the setup approval boundary'
    $tty_approve y -- \
        "$root/agentkit/skills/.shared/scripts/agent-run.sh" \
        --dir "$fork_repo/.fleet/pr-10" --approve --cmd setup >/dev/null 2>&1
    worktree_setup_declared_setup "$root/agentkit/skills/.shared/scripts/repo-config.sh" \
        "$root/agentkit/skills/.shared/scripts/agent-run.sh" "$fork_repo/.fleet/pr-10"
    assert_eq 'setup-ran' "$(<"$fork_repo/.fleet/pr-10/setup.marker")" \
        'cross-repository PR setup runs through agent-run after approval'
fi

finish
