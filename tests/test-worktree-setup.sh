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
# not reinterpret it as a directory destination and report success. The
# staging shim creates that directory immediately after mktemp returns, which
# is the handoff point immediately before placement.
race_root=$tmp/race-root
race_worktree=$tmp/race-worktree
race_bin=$tmp/race-bin
mkdir -p "$race_root/.agent" "$race_worktree" "$race_bin"
printf '%s\n' 'AGENT_CMD_SETUP=tools/setup' >"$race_root/.agent/config.env"
race_mktemp=$race_bin/mktemp
# shellcheck disable=SC2016  # the fixture intentionally records literal env refs.
printf '%s\n' '#!/usr/bin/env bash' \
    'staged=$("$WORKTREE_SETUP_REAL_MKTEMP" "$@") || exit 1' \
    'mkdir -p -- "$WORKTREE_SETUP_RACE_TARGET"' \
    'printf "%s\n" "$staged"' >"$race_mktemp"
chmod +x "$race_mktemp"
real_mktemp=$(command -v mktemp)
race_ok=yes
PATH="$race_bin:$PATH" WORKTREE_SETUP_RACE_TARGET="$race_worktree/.agent/config.env" \
    WORKTREE_SETUP_REAL_MKTEMP="$real_mktemp" \
    worktree_setup_propagate_config "$race_root" "$race_worktree" >/dev/null 2>&1 || race_ok=no
assert_eq no "$race_ok" 'config propagation rejects a raced target directory'
assert_eq yes "$(test -d "$race_worktree/.agent/config.env" && printf yes || printf no)" \
    'config propagation leaves the raced target directory in place'
assert_eq no "$(test -f "$race_worktree/.agent/config.env/config.env" && printf yes || printf no)" \
    'config propagation does not place config inside the raced directory'

# The placement path must not depend on GNU-only mv flags; a macOS-style mv
# that rejects them still leaves a valid staged config to place.
portable_root=$tmp/portable-root
portable_worktree=$tmp/portable-worktree
portable_bin=$tmp/portable-bin
mkdir -p "$portable_root/.agent" "$portable_worktree" "$portable_bin"
printf '%s\n' 'AGENT_CMD_SETUP=tools/setup' >"$portable_root/.agent/config.env"
portable_mv=$portable_bin/mv
# shellcheck disable=SC2016  # the fixture intentionally records literal env refs.
printf '%s\n' '#!/usr/bin/env bash' \
    'for arg in "$@"; do' \
    '    case "$arg" in --no-clobber|--no-target-directory) exit 64 ;; esac' \
    'done' \
    'exec "$WORKTREE_SETUP_REAL_MV" "$@"' >"$portable_mv"
chmod +x "$portable_mv"
real_mv=$(command -v mv)
portable_ok=yes
PATH="$portable_bin:$PATH" WORKTREE_SETUP_REAL_MV="$real_mv" \
    worktree_setup_propagate_config "$portable_root" "$portable_worktree" >/dev/null 2>&1 || portable_ok=no
assert_eq yes "$portable_ok" 'config propagation works without GNU mv flags'
assert_eq "$(<"$portable_root/.agent/config.env")" "$(<"$portable_worktree/.agent/config.env")" \
    'portable config propagation preserves the staged bytes'

# An exclusive open can succeed before the copy fails. That post-create copy
# failure must not be mistaken for a trusted pre-existing target.
copy_fail_root=$tmp/copy-fail-root
copy_fail_worktree=$tmp/copy-fail-worktree
copy_fail_bin=$tmp/copy-fail-bin
mkdir -p "$copy_fail_root/.agent" "$copy_fail_worktree" "$copy_fail_bin"
printf '%s\n' 'AGENT_CMD_SETUP=tools/setup' >"$copy_fail_root/.agent/config.env"
copy_fail_cat=$copy_fail_bin/cat
# shellcheck disable=SC2016  # the fixture intentionally records literal env refs.
printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ ${1:-} == "$WORKTREE_SETUP_FAIL_CAT_SOURCE" ]]; then' \
    '    exec "$WORKTREE_SETUP_REAL_CAT" "$@"' \
    'fi' \
    'exit 73' >"$copy_fail_cat"
chmod +x "$copy_fail_cat"
real_cat=$(command -v cat)
copy_fail_ok=yes
PATH="$copy_fail_bin:$PATH" WORKTREE_SETUP_REAL_CAT="$real_cat" \
    WORKTREE_SETUP_FAIL_CAT_SOURCE="$copy_fail_root/.agent/config.env" \
    worktree_setup_propagate_config "$copy_fail_root" "$copy_fail_worktree" >/dev/null 2>&1 || copy_fail_ok=no
assert_eq no "$copy_fail_ok" 'config propagation rejects a post-create copy failure'
# The failed copy must not leave an empty target behind: an empty file at
# $target would be indistinguishable from a "previously trusted target" on
# the next run, silently poisoning it with a config that never arrives.
assert_eq no "$(test -e "$copy_fail_worktree/.agent/config.env" && printf yes || printf no)" \
    'config propagation removes the empty target left by a failed copy'
copy_fail_retry_ok=yes
worktree_setup_propagate_config "$copy_fail_root" "$copy_fail_worktree" >/dev/null 2>&1 || copy_fail_retry_ok=no
assert_eq yes "$copy_fail_retry_ok" 'a retried config propagation succeeds after a failed copy'
assert_eq "$(<"$copy_fail_root/.agent/config.env")" "$(<"$copy_fail_worktree/.agent/config.env")" \
    'a retried config propagation is not poisoned by a leftover empty target'

if [[ -x $create_sh ]]; then
    assert_rc 1 'issue setup rejects an invalid issue number' -- \
        "$create_sh" --repo-root "$repo" --issue 0 --base main
    assert_rc 1 'issue setup rejects an abbreviated chain base' -- \
        "$create_sh" --repo-root "$repo" --issue 8 --base main --chain-base abc
fi

# Git owns branch-ref grammar; retain the leading-dash guard while accepting
# valid punctuation and Unicode that the old ASCII hand-regex rejected.
ref_ok=yes
worktree_setup_validate_ref 'feat/pr+head%üñîcode' 'test branch' >/dev/null 2>&1 || ref_ok=no
assert_eq yes "$ref_ok" 'branch validation accepts Git-valid punctuation and Unicode'
for invalid_ref in 'foo..bar' 'foo bar' '-option' 'foo~bar'; do
    ref_ok=yes
    worktree_setup_validate_ref "$invalid_ref" 'test branch' >/dev/null 2>&1 || ref_ok=no
    assert_eq no "$ref_ok" "branch validation rejects invalid ref: $invalid_ref"
done

# A dot-leading segment (in particular '..') must not slip past the slug
# guard: $REPO is forwarded to gh and agent-preflight.sh, and a segment that
# reads as a path-traversal token is weaker than the guard's own failure
# message ("must look like OWNER/REPO") claims to reject.
for invalid_slug in '../..' './x' 'owner/..' '../repo'; do
    slug_ok=yes
    worktree_setup_validate_repo_slug "$invalid_slug" >/dev/null 2>&1 || slug_ok=no
    assert_eq no "$slug_ok" "repo slug validation rejects dot-leading segment: $invalid_slug"
done
slug_ok=yes
worktree_setup_validate_repo_slug 'owner-name/repo.name_2' >/dev/null 2>&1 || slug_ok=no
assert_eq yes "$slug_ok" 'repo slug validation still accepts ordinary names containing dots'

shorthand_repo=$tmp/shorthand-repo
mkdir -p "$shorthand_repo"
git init -q -b main "$shorthand_repo"
git -C "$shorthand_repo" config user.name test
git -C "$shorthand_repo" config user.email test@example.invalid
printf '%s\n' seed >"$shorthand_repo/seed"
git -C "$shorthand_repo" add -- seed
git -C "$shorthand_repo" commit -qm seed
git -C "$shorthand_repo" switch -q -c previous
git -C "$shorthand_repo" switch -q main
ref_ok=yes
(cd "$shorthand_repo" && worktree_setup_validate_ref '@{-1}' 'test branch') >/dev/null 2>&1 || ref_ok=no
assert_eq no "$ref_ok" 'branch validation rejects checkout shorthand'

# Resolve Git's existing common directory without depending on readlink -f.
no_readlink=$tmp/no-readlink
mkdir -p "$no_readlink"
printf '%s\n' '#!/usr/bin/env bash' 'exit 97' >"$no_readlink/readlink"
chmod +x "$no_readlink/readlink"
common_expected=$(cd -- "$repo/$(git -C "$repo" rev-parse --git-common-dir)" && pwd -P)
common_actual=$(PATH="$no_readlink:$PATH" worktree_setup_common_dir "$repo")
assert_eq "$common_expected" "$common_actual" \
    'common-dir resolution works without readlink -f'

# A linked worktree carries a .git FILE whose gitdir points into the main
# repository. mkdir .git is therefore the worker-only failure from the issue,
# while the shipped helper must follow Git's resolved metadata paths instead.
linked_main=$tmp/linked-main
linked_feature=$tmp/linked-feature
mkdir -p "$linked_main"
linked_main=$(cd -- "$linked_main" && pwd -P)
git init -q -b main "$linked_main"
git -C "$linked_main" config user.name test
git -C "$linked_main" config user.email test@example.invalid
printf '%s\n' seed >"$linked_main/seed"
git -C "$linked_main" add -- seed
git -C "$linked_main" commit -qm base
git -C "$linked_main" worktree add -q -b feat/linked "$linked_feature"
linked_feature=$(cd -- "$linked_feature" && pwd -P)
assert_eq file "$(if [[ -f $linked_feature/.git && ! -d $linked_feature/.git ]]; then printf file; else printf other; fi)" \
    'a linked worktree exposes .git as a metadata file, not a directory'
assert_contains "$(<"$linked_feature/.git")" "gitdir: $linked_main/.git/worktrees/" \
    'the linked .git file points at per-worktree metadata under the common directory'
mkdir_ok=yes
mkdir -p "$linked_feature/.git/cache" >/dev/null 2>&1 || mkdir_ok=no
assert_eq no "$mkdir_ok" \
    'the reproduced mkdir .git attempt fails only because worker context treats the file as a directory'
linked_common=$(cd -- "$linked_feature" && cd -- "$(git rev-parse --git-common-dir)" && pwd -P)
assert_eq "$linked_common" "$(worktree_setup_common_dir "$linked_feature")" \
    'linked worktree setup resolves the main repository common directory'
linked_exclude=$(git -C "$linked_feature" rev-parse --git-path info/exclude)
assert_eq "$linked_exclude" "$(worktree_setup_exclude_path "$linked_feature")" \
    'linked worktree setup resolves info/exclude through git-path'

# Audit shipped metadata helpers for literal .git/ concatenation. The protected
# path policy intentionally names user-facing paths such as .git/config, so it
# is excluded; every helper that reads or writes metadata must use Git plumbing.
# Match path construction, not explanatory prose such as "a read-only .git".
literal_pattern="(\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]+\})/\.git([/\"]|$)|\"\.git([/\"]|$)"
literal_git_paths=''
scanned_helpers=0
while IFS= read -r helper; do
    if [[ $helper == */lib/protected-paths.sh ]]; then
        continue
    fi
    scanned_helpers=$((scanned_helpers + 1))
    matches=$(grep -nHE "$literal_pattern" "$helper" | grep -vE ':[[:space:]]*#' || true)
    [[ -z $matches ]] || literal_git_paths+="$matches"$'\n'
done < <(find "$root/agentkit" -type f -name '*.sh' -print | sort)
assert_rc 0 'audit scans at least one shipped metadata helper' -- test "$scanned_helpers" -gt 0
assert_eq '' "$literal_git_paths" \
    'shipped metadata helpers contain no literal .git/ path assumptions'

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
    '  *"pr view 9"*headRefName*) printf "%s\\n" "feat/pr+head%üñîcode" ;;' \
    '  *"pr view 9"*isCrossRepository*) printf "%s\\n" false ;;' \
    '  *"pr view 10"*headRefName*) printf "%s\\n" fork/pr-head ;;' \
    '  *"pr view 10"*isCrossRepository*) printf "%s\\n" true ;;' \
    '  *"pr checkout 10"*) exit 0 ;;' \
    '  *"pr view 11"*headRefName*) printf "%s\\n" feat/pr-11-head ;;' \
    '  *"pr view 11"*isCrossRepository*) printf "%s\\n" false ;;' \
    '  *) exit 1 ;;' \
    'esac' >"$fake_gh"
fake_jq=$fake_bin/jq
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fake_jq"
chmod +x "$fake_gh" "$fake_jq"

if [[ -x $pr_sh ]]; then
    pr_repo=$tmp/pr-repo
    mkdir -p "$pr_repo"
    make_repo "$pr_repo" >/dev/null
    git -C "$pr_repo" switch -q -c 'feat/pr+head%üñîcode'
    git -C "$pr_repo" push -q origin 'feat/pr+head%üñîcode'
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

    # An inherited PR_WORKTREE must never steer worktree creation outside the
    # repository: the worktree path is always derived from the validated
    # repository root and worktree root, with no environment override honored.
    git -C "$pr_repo" switch -q -c 'feat/pr-11-head'
    git -C "$pr_repo" push -q origin 'feat/pr-11-head'
    git -C "$pr_repo" switch -q main
    escaped_target="$pr_repo/../elsewhere"
    rm -rf -- "$escaped_target"
    : >"$gh_log"
    out=$(cd "$pr_repo" && PATH="$fake_bin:$PATH" \
        PR_WORKTREE='../elsewhere' WORKTREE_SETUP_GH_LOG="$gh_log" \
        "$pr_sh" --pr 11 --repo example/repo 2>&1)
    rc=$?
    assert_eq '1' "$rc" 'PR setup with a malicious PR_WORKTREE still stops for setup approval'
    assert_eq 'yes' "$(test -d "$pr_repo/.fleet/pr-11" && printf yes || printf no)" \
        'PR_WORKTREE environment override no longer changes the derived worktree path'
    assert_eq 'no' "$(test -e "$escaped_target" && printf yes || printf no)" \
        'a malicious PR_WORKTREE does not escape the repository root'
    rm -rf -- "$escaped_target"

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
