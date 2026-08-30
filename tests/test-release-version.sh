#!/usr/bin/env bash
# Suite: release tags and the four plugin manifests agree.
set -uo pipefail

TEST_NAME='release-version'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

root=$(cd -- "$here/.." && pwd)
checker="$here/check-release-version.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# check-release-version.sh resolves an ambient tag from GITHUB_REF_TYPE and
# GITHUB_REF_NAME (only) when no --tag is supplied. Neutralize both here so
# every "no tag" case below genuinely runs without one, instead of merely
# relying on their absence -- which holds on a branch push but not on the tag
# push this suite exists to guard.
unset GITHUB_REF_TYPE GITHUB_REF_NAME

expected_version=$(jq -r '.version' < "$root/agentkit/.claude-plugin/plugin.json")
mismatch_version="${expected_version}-mismatch"

fixture="$tmp/tree"
mkdir -p "$fixture/agentkit/.claude-plugin" \
    "$fixture/agentkit/.codex-plugin" \
    "$fixture/plugin/agentkit/.claude-plugin" \
    "$fixture/plugin/agentkit/.codex-plugin"
cp -- "$root/agentkit/.claude-plugin/plugin.json" \
    "$fixture/agentkit/.claude-plugin/plugin.json"
cp -- "$root/agentkit/.codex-plugin/plugin.json" \
    "$fixture/agentkit/.codex-plugin/plugin.json"
cp -- "$fixture/agentkit/.claude-plugin/plugin.json" \
    "$fixture/plugin/agentkit/.claude-plugin/plugin.json"
cp -- "$fixture/agentkit/.codex-plugin/plugin.json" \
    "$fixture/plugin/agentkit/.codex-plugin/plugin.json"

run_checker() {
    local out=$1
    shift
    local rc=0
    "$checker" --root "$fixture" "$@" >"$out" 2>&1 || rc=$?
    printf '%s\n' "$rc"
}

out="$tmp/agreement.out"
assert_eq '0' "$(run_checker "$out")" 'matching manifests pass without a tag'
assert_contains "$(cat -- "$out")" "all 4 manifests agree on $expected_version" \
    'agreement success names the version and manifest count'

out="$tmp/tag.out"
assert_eq '0' "$(run_checker "$out" --tag "refs/tags/v$expected_version")" \
    'a v-prefixed tag matches the manifest version'
assert_contains "$(cat -- "$out")" "tag refs/tags/v$expected_version matches $expected_version" \
    'tag success names the tag and normalized version'

out="$tmp/tag-mismatch.out"
assert_eq '1' "$(run_checker "$out" --tag "v$mismatch_version")" \
    'a tag mismatch fails the gate'
assert_contains "$(cat -- "$out")" 'tag version mismatch' \
    'tag mismatch identifies the failed invariant'

jq --arg version "$mismatch_version" '.version = $version' \
    "$fixture/plugin/agentkit/.codex-plugin/plugin.json" \
    > "$fixture/plugin/agentkit/.codex-plugin/plugin.json.new"
mv -- "$fixture/plugin/agentkit/.codex-plugin/plugin.json.new" \
    "$fixture/plugin/agentkit/.codex-plugin/plugin.json"
out="$tmp/disagreement.out"
assert_eq '1' "$(run_checker "$out")" 'disagreeing manifests fail the gate'
assert_contains "$(cat -- "$out")" \
    "plugin/agentkit/.codex-plugin/plugin.json declares $mismatch_version; expected $expected_version" \
    'disagreement identifies the path and both values'

rm -- "$fixture/plugin/agentkit/.codex-plugin/plugin.json"
out="$tmp/missing.out"
assert_eq '1' "$(run_checker "$out")" 'a missing manifest fails the gate'
assert_contains "$(cat -- "$out")" \
    'missing manifest: plugin/agentkit/.codex-plugin/plugin.json' \
    'missing manifest identifies the required relative path'

cp -- "$fixture/agentkit/.claude-plugin/plugin.json" \
    "$fixture/plugin/agentkit/.codex-plugin/plugin.json"
printf '{not-json}\n' > "$fixture/plugin/agentkit/.claude-plugin/plugin.json"
out="$tmp/invalid.out"
assert_eq '1' "$(run_checker "$out")" 'invalid manifest JSON fails the gate'
assert_contains "$(cat -- "$out")" \
    'invalid manifest JSON: plugin/agentkit/.claude-plugin/plugin.json' \
    'invalid JSON identifies the required relative path'

cp -- "$fixture/agentkit/.claude-plugin/plugin.json" \
    "$fixture/plugin/agentkit/.claude-plugin/plugin.json"
jq '.version = ""' \
    "$fixture/plugin/agentkit/.claude-plugin/plugin.json" \
    > "$fixture/plugin/agentkit/.claude-plugin/plugin.json.new"
mv -- "$fixture/plugin/agentkit/.claude-plugin/plugin.json.new" \
    "$fixture/plugin/agentkit/.claude-plugin/plugin.json"
out="$tmp/empty-version.out"
assert_eq '1' "$(run_checker "$out")" 'an empty manifest version fails the gate'
assert_contains "$(cat -- "$out")" \
    'manifest has no non-empty string version: plugin/agentkit/.claude-plugin/plugin.json' \
    'empty version identifies the required relative path'

# The bump helper edits only the three source manifests from the checkout root.
bump="$root/agentkit/skills/.shared/scripts/bump-version.sh"
bump_fixture="$tmp/bump-tree"
mkdir -p "$bump_fixture/agentkit/.claude-plugin" \
    "$bump_fixture/agentkit/.codex-plugin" "$bump_fixture/opencode"
cp -- "$root/agentkit/.claude-plugin/plugin.json" \
    "$bump_fixture/agentkit/.claude-plugin/plugin.json"
cp -- "$root/agentkit/.codex-plugin/plugin.json" \
    "$bump_fixture/agentkit/.codex-plugin/plugin.json"
cp -- "$root/opencode/package.json" "$bump_fixture/opencode/package.json"
git -C "$bump_fixture" init -q -b main
git -C "$bump_fixture" config user.name test
git -C "$bump_fixture" config user.email test@example.invalid
git -C "$bump_fixture" add -- .
git -C "$bump_fixture" commit -qm init
bump_out="$tmp/bump.out"
bump_rc=0
(cd "$bump_fixture" && "$bump" 0.7.3 >"$bump_out" 2>&1) || bump_rc=$?
assert_eq '0' "$bump_rc" 'the version bump helper succeeds from a repository root'
assert_contains "$(cat -- "$bump_out")" 'bumped version to 0.7.3 (3 files)' \
    'the bump helper reports its exact three-file scope'
assert_eq $'agentkit/.claude-plugin/plugin.json\nagentkit/.codex-plugin/plugin.json\nopencode/package.json' \
    "$(git -C "$bump_fixture" diff --name-only | sort)" \
    'the bump helper edits exactly the three source manifests'
assert_eq '0.7.3' "$(jq -r '.version' "$bump_fixture/agentkit/.claude-plugin/plugin.json")" \
    'the bump helper updates the Claude manifest'
assert_eq '0.7.3' "$(jq -r '.version' "$bump_fixture/agentkit/.codex-plugin/plugin.json")" \
    'the bump helper updates the Codex manifest'
assert_eq '0.7.3' "$(jq -r '.version' "$bump_fixture/opencode/package.json")" \
    'the bump helper updates the OpenCode manifest'

# Release, prerelease, and build identifiers must be non-empty. Valid
# semver-style prerelease/build identifiers remain accepted.
for valid_version in 0.7.3-rc.1 0.7.3-rc-1 0.7.3+build.2 0.7.3+build-2 0.7.3-rc.1+build.2; do
    valid_rc=0
    (cd "$bump_fixture" && "$bump" "$valid_version" >/dev/null 2>&1) || valid_rc=$?
    assert_eq '0' "$valid_rc" "the version bump helper accepts $valid_version"
done
for invalid_version in 0.7.3. 0.7.3-rc..1 0.7.3+build..2; do
    invalid_rc=0
    invalid_out=$(cd "$bump_fixture" && "$bump" "$invalid_version" 2>&1) || invalid_rc=$?
    assert_eq '2' "$invalid_rc" "the version bump helper rejects $invalid_version"
    assert_contains "$invalid_out" 'VERSION must be a dotted release version' \
        "the invalid version error identifies $invalid_version"
done

# Replacements are transactional: a failure after earlier moves must restore
# every manifest byte-for-byte.
failure_bin="$tmp/failure-bin"
mkdir -p "$failure_bin"
real_mv=$(command -v mv)
cat > "$failure_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
    if [[ $arg == */opencode/package.json ]]; then
        printf 'mv: injected failure\n' >&2
        exit 1
    fi
done
exec "$BUMP_TEST_REAL_MV" "$@"
EOF
chmod +x "$failure_bin/mv"
before_failure=$(sha256sum \
    "$bump_fixture/agentkit/.claude-plugin/plugin.json" \
    "$bump_fixture/agentkit/.codex-plugin/plugin.json" \
    "$bump_fixture/opencode/package.json")
failure_rc=0
(cd "$bump_fixture" && PATH="$failure_bin:$PATH" BUMP_TEST_REAL_MV="$real_mv" \
    "$bump" 0.8.0 >/dev/null 2>&1) || failure_rc=$?
assert_eq '1' "$failure_rc" 'a later manifest replacement failure is reported'
after_failure=$(sha256sum \
    "$bump_fixture/agentkit/.claude-plugin/plugin.json" \
    "$bump_fixture/agentkit/.codex-plugin/plugin.json" \
    "$bump_fixture/opencode/package.json")
assert_eq "$before_failure" "$after_failure" \
    'a replacement failure restores every manifest byte-for-byte'

mkdir -p "$bump_fixture/.worktrees/child"
worktree_bump_rc=0
worktree_bump_out=$(cd "$bump_fixture/.worktrees/child" && "$bump" 0.7.4 2>&1) || worktree_bump_rc=$?
assert_eq '1' "$worktree_bump_rc" 'the bump helper refuses execution inside .worktrees'
assert_contains "$worktree_bump_out" 'refusing to run inside .worktrees' \
    'the worktree refusal explains the safe invocation boundary'

# A real linked worktree may live outside the repository's conventional
# .worktrees/ directory, so Git metadata—not the checkout path—must trigger the
# refusal and preserve all manifests byte-for-byte.
real_linked="$tmp/real-linked-bump"
git -C "$bump_fixture" worktree add -q -b bump-linked "$real_linked"
linked_before=$(sha256sum \
    "$real_linked/agentkit/.claude-plugin/plugin.json" \
    "$real_linked/agentkit/.codex-plugin/plugin.json" \
    "$real_linked/opencode/package.json")
linked_bump_rc=0
linked_bump_out=$(cd "$real_linked" && "$bump" 0.7.4 2>&1) || linked_bump_rc=$?
assert_eq '1' "$linked_bump_rc" 'the bump helper refuses a real linked worktree'
assert_contains "$linked_bump_out" 'refusing to run inside a linked worktree' \
    'the linked-worktree refusal identifies the Git metadata boundary'
linked_after=$(sha256sum \
    "$real_linked/agentkit/.claude-plugin/plugin.json" \
    "$real_linked/agentkit/.codex-plugin/plugin.json" \
    "$real_linked/opencode/package.json")
assert_eq "$linked_before" "$linked_after" \
    'a linked-worktree refusal leaves every source manifest byte-identical'

cp -- "$fixture/agentkit/.claude-plugin/plugin.json" \
    "$fixture/plugin/agentkit/.claude-plugin/plugin.json"
out="$tmp/tag-context.out"
export GITHUB_REF_TYPE=tag GITHUB_REF_NAME="v$expected_version"
assert_eq '0' "$(run_checker "$out")" \
    'tag-push context checks the tag without an argument'
assert_contains "$(cat -- "$out")" \
    "tag v$expected_version matches $expected_version across 4 manifests" \
    'tag-push context reports the tag comparison, not the no-tag message'
unset GITHUB_REF_TYPE GITHUB_REF_NAME

bad_root="$tmp/missing-root"
out="$tmp/bad-root.out"
rc=0
"$checker" --root "$bad_root" >"$out" 2>&1 || rc=$?
assert_eq '2' "$rc" 'a missing checker root is a usage failure'
assert_contains "$(cat -- "$out")" "root is not a directory: $bad_root" \
    'a missing checker root reports the original path'

ci_text=$(cat -- "$root/.github/workflows/ci.yml")
assert_contains "$ci_text" "tags: ['v*']" 'CI runs the gate for versioned tag pushes'
assert_contains "$ci_text" 'types: [published]' 'CI runs the gate for published releases'
assert_contains "$ci_text" 'tests/check-release-version.sh' 'CI invokes the release gate'
assert_contains "$ci_text" 'github.event.release.tag_name || github.sha' \
    'release runs check out the published tag'
assert_not_contains "$ci_text" 'github.event.release.tag_name || github.ref' \
    'CI does not resolve non-release checkouts from a moving ref'

finish
