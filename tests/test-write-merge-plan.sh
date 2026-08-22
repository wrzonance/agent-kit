#!/usr/bin/env bash
# Regression coverage for the parallel-issues merge-plan handoff.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='write merge plan'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

writer="$root/agentkit/skills/parallel-issues/scripts/write-merge-plan.sh"
plan="$tmp/dispatch-plan.json"
merge_plan="$tmp/merge-plan.json"

cat >"$plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [
    {"issue": 11, "predictedWriteSet": ["src/a"]},
    {"issue": 12, "predictedWriteSet": ["src/b"]},
    {"issue": 13, "predictedWriteSet": ["src/c"]}
  ],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF

cat >"$merge_plan" <<'EOF'
{
  "generatedAt": "2026-08-17T20:00:00Z",
  "independent": [
    {"issue":13,"pr":103,"branch":"feat/independent","chainBaseSha":null,"headSha":"cccccccccccccccccccccccccccccccccccccccc"}
  ],
  "chains": [[
    {"issue":11,"pr":101,"branch":"feat/root","chainBaseSha":null,"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    {"issue":12,"pr":102,"branch":"feat/child","chainBaseSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
  ]]
}
EOF

"$writer" --dispatch-plan "$plan" --merge-plan "$merge_plan"
assert_eq '2' "$(jq -r '.schemaVersion' "$plan")" \
    'writer upgrades the dispatch plan to schemaVersion 2'
assert_eq '2' "$(jq -r '.chains[0] | length' "$plan")" \
    'writer persists each chain in base-to-tip order'
assert_eq '103' "$(jq -r '.independent[0].pr' "$plan")" \
    'writer persists the independent pull request set'
assert_eq 'src/a' "$(jq -r '.entries[0].predictedWriteSet[0]' "$plan")" \
    'writer preserves the existing dispatch audit record'

before=$(sha256sum "$plan")
jq '.chains += [[.chains[0][1]]]' "$merge_plan" >"$tmp/join.json"
assert_rc 1 'a PR with multiple predecessors is rejected' -- \
    "$writer" --dispatch-plan "$plan" --merge-plan "$tmp/join.json"
assert_eq "$before" "$(sha256sum "$plan")" \
    'a rejected merge plan leaves the dispatch plan byte-identical'

jq '.chains[0][1].headSha = "short"' "$merge_plan" >"$tmp/bad-sha.json"
assert_rc 1 'non-full recorded head SHAs are rejected' -- \
    "$writer" --dispatch-plan "$plan" --merge-plan "$tmp/bad-sha.json"

jq '.chains[0][1].branch = "../escape"' "$merge_plan" >"$tmp/bad-branch.json"
assert_rc 1 'unsafe branch names are rejected' -- \
    "$writer" --dispatch-plan "$plan" --merge-plan "$tmp/bad-branch.json"

jq 'del(.generatedAt)' "$merge_plan" >"$tmp/missing-generated-at.json"
stderr=$("$writer" --dispatch-plan "$plan" --merge-plan "$tmp/missing-generated-at.json" 2>&1 1>/dev/null) && rc=0 || rc=$?
assert_eq '1' "$rc" \
    'a merge plan missing generatedAt is rejected'
assert_contains "$stderr" 'generatedAt' \
    'the missing-generatedAt error names the field'

finish
