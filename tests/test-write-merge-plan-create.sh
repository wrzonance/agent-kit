#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='write merge plan create'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/tools"
printf 'tooling\n' >"$repo/tools/README.md"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
git -C "$repo" add -- .
git -C "$repo" commit -qm base

plan="$tmp/plan.json"
printf '%s\n' '{"schemaVersion":1,"entries":[{"issue":202,"publicationTarget":"feat/issue-101","expectedPredecessors":[101,102],"integrationBaseSha":null,"predictedWriteSet":["tools/bootstrap-worktree.sh","tools/literal[.sh"]}],"conflictMap":{"pairs":[],"revisions":[]}}' >"$plan"
writer="$root/agentkit/skills/parallel-issues/scripts/write-merge-plan.sh"
out=$("$writer" --dispatch-plan "$plan" --chain-base "$repo" --validate-only 2>"$tmp/err")
assert_contains "$out" 'create=tools/bootstrap-worktree.sh' \
    'validation identifies a literal new file as a create entry'
assert_contains "$out" 'tools/literal[.sh' \
    'an unmatched opening bracket remains a literal create path'
assert_not_contains "$(cat "$tmp/err")" 'matches no paths' \
    'the historical #202 fixture does not trigger a needs-paths round trip'

for invalid_filter in \
    '.entries[0].expectedPredecessors = [101,101]' \
    '.entries[0].expectedPredecessors = [202]' \
    '.entries[0].expectedPredecessors = [0]' \
    '.entries[0].integrationBaseSha = "abc"'; do
    invalid="$tmp/invalid-$(printf '%s' "$invalid_filter" | sha256sum | cut -c1-8).json"
    jq "$invalid_filter" "$plan" >"$invalid"
    assert_rc 1 "invalid join plan field is refused: $invalid_filter" -- \
        "$writer" --dispatch-plan "$invalid" --validate-only
done

finish
