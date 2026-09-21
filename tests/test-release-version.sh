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
    "$fixture/agentkit/skills/example" \
    "$fixture/plugin/agentkit/.claude-plugin" \
    "$fixture/plugin/agentkit/.codex-plugin" \
    "$fixture/tests"
cp -- "$root/agentkit/.claude-plugin/plugin.json" \
    "$fixture/agentkit/.claude-plugin/plugin.json"
cp -- "$root/agentkit/.codex-plugin/plugin.json" \
    "$fixture/agentkit/.codex-plugin/plugin.json"
cp -- "$fixture/agentkit/.claude-plugin/plugin.json" \
    "$fixture/plugin/agentkit/.claude-plugin/plugin.json"
cp -- "$fixture/agentkit/.codex-plugin/plugin.json" \
    "$fixture/plugin/agentkit/.codex-plugin/plugin.json"
printf 'tagged content\n' > "$fixture/agentkit/skills/example/SKILL.md"
cat > "$fixture/tests/build-plugin.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
rm -rf -- "$root/plugin"
mkdir -p "$root/plugin/agentkit/.claude-plugin" \
    "$root/plugin/agentkit/.codex-plugin" \
    "$root/plugin/agentkit/skills/example"
cp -- "$root/agentkit/.claude-plugin/plugin.json" \
    "$root/plugin/agentkit/.claude-plugin/plugin.json"
cp -- "$root/agentkit/.codex-plugin/plugin.json" \
    "$root/plugin/agentkit/.codex-plugin/plugin.json"
cp -- "$root/agentkit/skills/example/SKILL.md" \
    "$root/plugin/agentkit/skills/example/SKILL.md"
EOF
chmod +x -- "$fixture/tests/build-plugin.sh"
"$fixture/tests/build-plugin.sh"
printf '/plugin/\n' > "$fixture/.gitignore"
git -C "$fixture" init -q -b main
git -C "$fixture" config user.name test
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" add -- .
git -C "$fixture" commit -qm init
git -C "$fixture" tag "v$expected_version"

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
assert_contains "$(cat -- "$out")" "shipped content matches tag v$expected_version" \
    'an unchanged shipped tree matches the content recorded by its version tag'
tagged_content_hash=$(sed -n 's/.*content hash \([0-9a-f]\{64\}\).*/\1/p' "$out")
assert_eq '64' "${#tagged_content_hash}" \
    'the passing gate reports the reproducible SHA-256 content hash'

find_failure_bin="$tmp/find-failure-bin"
mkdir -p "$find_failure_bin"
cat > "$find_failure_bin/find" <<'EOF'
#!/usr/bin/env bash
printf './agentkit/.claude-plugin/plugin.json\0'
exit 9
EOF
chmod +x "$find_failure_bin/find"
out="$tmp/find-enumeration-failure.out"
find_failure_rc=0
PATH="$find_failure_bin:$PATH" "$checker" --root "$fixture" >"$out" 2>&1 ||
    find_failure_rc=$?
assert_eq '1' "$find_failure_rc" \
    'an entry finder that emits partial output and then fails stops the content gate'
assert_contains "$(cat -- "$out")" 'could not enumerate shipped tree' \
    'a partial finder failure identifies unavailable tree enumeration'

sort_failure_bin="$tmp/sort-failure-bin"
mkdir -p "$sort_failure_bin"
cat > "$sort_failure_bin/sort" <<'EOF'
#!/usr/bin/env bash
command cat > /dev/null
exit 8
EOF
chmod +x "$sort_failure_bin/sort"
out="$tmp/sort-enumeration-failure.out"
sort_failure_rc=0
PATH="$sort_failure_bin:$PATH" "$checker" --root "$fixture" >"$out" 2>&1 ||
    sort_failure_rc=$?
assert_eq '1' "$sort_failure_rc" 'an entry sort failure stops the content gate'
assert_contains "$(cat -- "$out")" 'could not enumerate shipped tree' \
    'a sort failure identifies unavailable tree enumeration'

cat_failure_bin="$tmp/cat-failure-bin"
mkdir -p "$cat_failure_bin"
cat > "$cat_failure_bin/cat" <<'EOF'
#!/usr/bin/env bash
printf 'partial file bytes'
exit 7
EOF
chmod +x "$cat_failure_bin/cat"
out="$tmp/entry-read-failure.out"
cat_failure_rc=0
PATH="$cat_failure_bin:$PATH" "$checker" --root "$fixture" >"$out" 2>&1 ||
    cat_failure_rc=$?
assert_eq '1' "$cat_failure_rc" \
    'an entry reader that emits partial bytes and then fails stops the content gate'
assert_contains "$(cat -- "$out")" 'could not hash shipped tree' \
    'a partial entry read identifies unavailable tree hashing'

fixture_link="$tmp/tree-link"
ln -s -- "$fixture" "$fixture_link"
out="$tmp/symlink-root.out"
symlink_rc=0
"$checker" --root "$fixture_link" >"$out" 2>&1 || symlink_rc=$?
assert_eq '0' "$symlink_rc" 'a symlinked checkout root resolves to the physical Git root'
assert_contains "$(cat -- "$out")" "shipped content matches tag v$expected_version" \
    'the content gate runs normally through a symlinked checkout root'

missing_tag_checkout="$tmp/missing-tag-checkout"
git clone -q --no-tags "file://$fixture" "$missing_tag_checkout"
printf 'changed bytes hidden by a missing local tag\n' \
    > "$missing_tag_checkout/agentkit/skills/example/SKILL.md"
"$missing_tag_checkout/tests/build-plugin.sh"
out="$tmp/missing-local-tag.out"
missing_tag_rc=0
"$checker" --root "$missing_tag_checkout" >"$out" 2>&1 || missing_tag_rc=$?
assert_eq '1' "$missing_tag_rc" \
    'a published version fetched from origin still rejects changed shipped content'
assert_contains "$(cat -- "$out")" \
    "shipped content changed under existing version $expected_version" \
    'a missing local tag cannot make a published version look new'
assert_eq 'yes' \
    "$(git -C "$missing_tag_checkout" show-ref --verify --quiet \
        "refs/tags/v$expected_version" && printf yes || printf no)" \
    'the gate fetches the exact published version tag from origin'

git -C "$missing_tag_checkout" tag -d "v$expected_version" > /dev/null
out="$tmp/missing-explicit-tag.out"
missing_explicit_rc=0
"$checker" --root "$missing_tag_checkout" --tag "refs/tags/v$expected_version" \
    >"$out" 2>&1 || missing_explicit_rc=$?
assert_eq '1' "$missing_explicit_rc" \
    'an explicit fully qualified published tag is fetched before content comparison'
assert_contains "$(cat -- "$out")" \
    "shipped content changed under existing version $expected_version" \
    'the fully qualified tag form uses the exact remote tag name'

unreachable_checkout="$tmp/unreachable-origin-checkout"
git clone -q --no-tags "file://$fixture" "$unreachable_checkout"
"$unreachable_checkout/tests/build-plugin.sh"
git -C "$unreachable_checkout" remote set-url origin "$tmp/no-such-origin"
out="$tmp/unreachable-origin.out"
unreachable_rc=0
"$checker" --root "$unreachable_checkout" >"$out" 2>&1 || unreachable_rc=$?
assert_eq '1' "$unreachable_rc" \
    'an unavailable origin fails instead of treating a missing local tag as unpublished'
assert_contains "$(cat -- "$out")" \
    "could not establish whether tag v$expected_version exists on origin" \
    'the remote lookup failure explains how published-version evidence is unavailable'

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
# The fixture's starting version is seeded to a fixed value independent of the
# live checkout's manifest version -- otherwise this section is a no-op (and
# the "edits exactly the three source manifests" assertion below goes red) on
# any checkout whose manifests already equal the bump target, e.g. right after
# a release commit.
bump="$root/agentkit/skills/.shared/scripts/bump-version.sh"
bump_fixture="$tmp/bump-tree"
seed_version='0.0.1'
mkdir -p "$bump_fixture/agentkit/.claude-plugin" \
    "$bump_fixture/agentkit/.codex-plugin" "$bump_fixture/opencode"
jq --arg version "$seed_version" '.version = $version' \
    "$root/agentkit/.claude-plugin/plugin.json" \
    > "$bump_fixture/agentkit/.claude-plugin/plugin.json"
jq --arg version "$seed_version" '.version = $version' \
    "$root/agentkit/.codex-plugin/plugin.json" \
    > "$bump_fixture/agentkit/.codex-plugin/plugin.json"
jq --arg version "$seed_version" '.version = $version' \
    "$root/opencode/package.json" \
    > "$bump_fixture/opencode/package.json"
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
cp -- "$fixture/agentkit/.codex-plugin/plugin.json" \
    "$fixture/plugin/agentkit/.codex-plugin/plugin.json"
out="$tmp/tag-context.out"
export GITHUB_REF_TYPE=tag GITHUB_REF_NAME="v$expected_version"
assert_eq '0' "$(run_checker "$out")" \
    'tag-push context checks the tag without an argument'
assert_contains "$(cat -- "$out")" \
    "tag v$expected_version matches $expected_version across 4 manifests" \
    'tag-push context reports the tag comparison, not the no-tag message'
unset GITHUB_REF_TYPE GITHUB_REF_NAME

printf 'changed bytes under the same version\n' > "$fixture/agentkit/skills/example/SKILL.md"
"$fixture/tests/build-plugin.sh"
out="$tmp/content-drift.out"
assert_eq '1' "$(run_checker "$out")" \
    'changing shipped content without moving the version fails the gate'
assert_contains "$(cat -- "$out")" \
    "shipped content changed under existing version $expected_version" \
    'content drift identifies the version that must move'

bumped_version="${expected_version%.*}.$((${expected_version##*.} + 1))"
for manifest in \
    "$fixture/agentkit/.claude-plugin/plugin.json" \
    "$fixture/agentkit/.codex-plugin/plugin.json"; do
    jq --arg version "$bumped_version" '.version = $version' "$manifest" > "$manifest.new"
    mv -- "$manifest.new" "$manifest"
done
"$fixture/tests/build-plugin.sh"
out="$tmp/content-bump.out"
assert_eq '0' "$(run_checker "$out")" 'a normal version bump passes the content gate'
assert_contains "$(cat -- "$out")" \
    "no existing tag v$bumped_version; shipped content is eligible for a new version" \
    'a version bump reports why no prior content comparison applies'

clean_checkout="$tmp/tag-checkout"
git clone -q "$fixture" "$clean_checkout"
git -C "$clean_checkout" checkout -q "v$expected_version"
"$clean_checkout/tests/build-plugin.sh"
clean_out="$tmp/clean-tag.out"
clean_rc=0
"$checker" --root "$clean_checkout" >"$clean_out" 2>&1 || clean_rc=$?
assert_eq '0' "$clean_rc" 'a clean checkout of the version tag passes the content gate'
clean_content_hash=$(sed -n 's/.*content hash \([0-9a-f]\{64\}\).*/\1/p' "$clean_out")
assert_eq "$tagged_content_hash" "$clean_content_hash" \
    'a clean checkout of the tag reproduces the recorded content hash'

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
