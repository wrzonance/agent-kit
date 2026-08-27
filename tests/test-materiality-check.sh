#!/usr/bin/env bash
# Suite: materiality-check.sh gates the adversarial-review spend mechanically.
set -uo pipefail

TEST_NAME='materiality-check'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

helper="$root/agentkit/skills/parallel-issues/scripts/materiality-check.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

assert_eq yes "$([[ -x $helper ]] && printf yes || printf no)" 'materiality helper is executable'

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
gitc() { git -C "$repo" -c user.name=test -c user.email=test@example.invalid "$@"; }
mkdir -p "$repo/src" "$repo/tests" "$repo/docs" "$repo/.github/workflows"
printf 'logic\n' > "$repo/src/app.sh"
printf 'auth\n' > "$repo/src/auth.sh"
printf 'test\n' > "$repo/tests/test-app.sh"
printf 'wf\n' > "$repo/.github/workflows/ci.yml"
printf 'readme\n' > "$repo/README.md"
printf '.agent/\n' > "$repo/.gitignore"
gitc add -A
gitc commit -q -m 'base'

start_branch() {
    gitc checkout -q main
    gitc branch -q -D work 2> /dev/null || true
    gitc checkout -q -b work
}

# A test-only diff takes the documented-skip path, with a recorded oracle.
start_branch
printf 'more tests\n' >> "$repo/tests/test-app.sh"
printf 'new test\n' > "$repo/tests/test-new.sh"
gitc add -A
gitc commit -q -m 'test: extend coverage'
out=$("$helper" --worktree "$repo" --base main)
assert_eq 0 $? 'a test-only diff classifies cleanly'
assert_contains "$out" 'verdict=skip-eligible' 'a test-only diff is skip-eligible'
assert_contains "$out" 'oracle=' 'a skip-eligible verdict prints its oracle'
assert_contains "$out" 'files=2' 'the verdict counts the changed files'

repo_root_alias=$($helper --repo-root "$repo" --base main)
assert_contains "$repo_root_alias" 'verdict=skip-eligible' '--repo-root remains an alias for --worktree'

# A docs-only diff is skip-eligible too.
start_branch
printf 'notes\n' > "$repo/docs/notes.md"
printf 'readme more\n' >> "$repo/README.md"
gitc add -A
gitc commit -q -m 'docs: notes'
out=$("$helper" --worktree "$repo" --base main)
assert_contains "$out" 'verdict=skip-eligible' 'a docs-only diff is skip-eligible'

# Executable logic is material.
start_branch
printf 'change\n' >> "$repo/src/app.sh"
gitc add -A
gitc commit -q -m 'feat: change logic'
out=$("$helper" --worktree "$repo" --base main)
assert_contains "$out" 'verdict=material' 'executable logic gets the full review'
assert_contains "$out" 'first-material=src/app.sh' 'the verdict names the first material file'
assert_not_contains "$out" 'oracle=' 'a material verdict offers no skip oracle'

# An issue-declared acceptance command makes even a docs-only diff material
# until the assembled branch records a green acceptance result.  The status
# file is intentionally separate from the declaration so a missing result is
# unambiguously not-run rather than an accidental pass.
mkdir -p "$repo/.agent"
printf '%s\n' 'npm run test:browser' > "$repo/.agent/acceptance.txt"
rm -f -- "$repo/.agent/acceptance-status.txt"
start_branch
printf 'acceptance notes\n' > "$repo/README.md"
gitc add -A
gitc commit -q -m 'docs: acceptance notes'
out=$($helper --worktree "$repo" --base main)
assert_contains "$out" 'verdict=material' \
    'an unrun declared acceptance command blocks a docs-only skip'
assert_contains "$out" 'acceptance=npm run test:browser:not-run' \
    'the material verdict records missing acceptance evidence as not-run'
out=$($helper --worktree "$repo" --base main \
    --acceptance-status-file "$repo/.agent/missing-status.txt")
assert_contains "$out" 'acceptance=npm run test:browser:not-run' \
    'an explicitly missing status artifact is treated as not-run'

printf '%s\n' 'npm run test:browser=pass' > "$repo/.agent/acceptance-status.txt"
out=$($helper --worktree "$repo" --base main)
assert_contains "$out" 'verdict=skip-eligible' \
    'a green declared acceptance command permits a docs-only skip'
assert_contains "$out" 'acceptance=npm run test:browser:pass' \
    'the skip oracle records the green acceptance result'

printf '%s\n' 'npm run test:browser=fail' > "$repo/.agent/acceptance-status.txt"
out=$($helper --worktree "$repo" --base main)
assert_contains "$out" 'verdict=material' \
    'a failed declared acceptance command blocks a docs-only skip'
assert_contains "$out" 'acceptance=npm run test:browser:fail' \
    'the material verdict records a failed acceptance result'

# Authorization, workflow, and persistence surfaces are material even when
# tests change alongside them -- one material file decides.
start_branch
printf 'authz\n' >> "$repo/src/auth.sh"
printf 'wf2\n' >> "$repo/.github/workflows/ci.yml"
printf 'cover it\n' >> "$repo/tests/test-app.sh"
gitc add -A
gitc commit -q -m 'feat: auth + workflow'
out=$("$helper" --worktree "$repo" --base main)
assert_contains "$out" 'verdict=material' 'auth/workflow diffs are material despite test files'

# A rename of executable code INTO a test path must stay material: with rename
# detection, --name-only would report only the destination and the relocated
# logic would read as a test-only diff (CodeRabbit finding, PR #226).
start_branch
gitc mv src/app.sh tests/test-app-moved.sh
gitc commit -q -m 'refactor: move logic into tests'
out=$("$helper" --worktree "$repo" --base main)
assert_contains "$out" 'verdict=material' \
    'an executable-to-test rename is never skip-eligible'
assert_contains "$out" 'first-material=src/app.sh' \
    'the rename verdict names the removed source path'

# Evidence failures are loud and fail closed: no verdict means no skip.
start_branch
assert_rc 2 'an empty diff refuses to classify' -- "$helper" --worktree "$repo" --base main
assert_rc 2 'an unresolvable base is refused' -- "$helper" --worktree "$repo" --base no-such-ref
assert_rc 2 'a missing worktree is refused' -- "$helper" --worktree "$tmp/absent" --base main
assert_rc 2 'a hostile base ref is refused' -- "$helper" --worktree "$repo" --base '--upload-pack=x'

finish
