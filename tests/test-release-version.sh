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
