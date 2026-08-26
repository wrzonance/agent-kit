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

assert_not_contains "$(cat -- "$writer")" 'split("/").[]' \
    'dispatch-plan validation uses jq 1.6-compatible array iteration syntax'

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

"$writer" --dispatch-plan "$plan" --validate-only >"$tmp/validate.out"
assert_contains "$(cat "$tmp/validate.out")" 'schemaVersion=1 valid' \
    'the write-time gate accepts a complete schema-1 dispatch plan'

# Selection accounting is optional for older plans, but when present it must
# be typed so the fast-mode funnel cannot be made to claim a queue or tracker
# count from malformed run data.
jq '.selection = {"requested":11,"eligible":11,"dispatched":10,
                  "queued":[12],"tracker":[13]}' "$plan" >"$tmp/selection-valid.json"
assert_rc 0 'valid fast-mode selection accounting is accepted' -- \
    "$writer" --dispatch-plan "$tmp/selection-valid.json" --validate-only
jq '.selection.queued = ["12"]' "$tmp/selection-valid.json" >"$tmp/selection-bad.json"
assert_rc 1 'selection queue issue numbers must be positive integers' -- \
    "$writer" --dispatch-plan "$tmp/selection-bad.json" --validate-only
jq '.selection = {"requested":3,"eligible":3,"dispatched":3,
                  "queued":0,"tracker":0}' "$plan" >"$tmp/selection-counts.json"
assert_rc 0 'legacy scalar queue and tracker counts remain accepted' -- \
    "$writer" --dispatch-plan "$tmp/selection-counts.json" --validate-only

# Queue and tracker issue lists are candidate identities, not free-form
# counters.  They must name entries in this dispatch plan and cannot overlap.
jq '.selection = {"requested":3,"eligible":3,"dispatched":1,
                  "queued":[12],"tracker":[13]}' "$plan" >"$tmp/selection-members.json"
assert_rc 0 'selection queue and tracker members are accepted' -- \
    "$writer" --dispatch-plan "$tmp/selection-members.json" --validate-only
jq '.selection.queued = [99]' "$tmp/selection-members.json" >"$tmp/selection-unknown-queue.json"
assert_rc 1 'selection queue cannot name an issue outside dispatch entries' -- \
    "$writer" --dispatch-plan "$tmp/selection-unknown-queue.json" --validate-only
jq '.selection.tracker = [12]' "$tmp/selection-members.json" >"$tmp/selection-overlap.json"
assert_rc 1 'selection queue and tracker cannot name the same issue' -- \
    "$writer" --dispatch-plan "$tmp/selection-overlap.json" --validate-only

jq '.conflictMap.pairs = [{"issues":[11,12],"overlap":["src/shared/**"]}] |
    .conflictMap.revisions = [{"phase":"post-selection","reason":"retain the reviewed edge"}, {"reason":"authorize merge-down","issues":[12],"paths":["src/b"]}]' \
    "$plan" >"$tmp/valid-conflict-members.json"
assert_rc 0 'documented conflict-map members are accepted' -- \
    "$writer" --dispatch-plan "$tmp/valid-conflict-members.json" --validate-only

for invalid_case in pair-null pair-boolean pair-malformed revision-null revision-boolean revision-malformed; do
    case $invalid_case in
        pair-null) filter='.conflictMap.pairs = [null]' ;;
        pair-boolean) filter='.conflictMap.pairs = [true]' ;;
        pair-malformed) filter='.conflictMap.pairs = [{"issues":[11,11],"overlap":[]}]' ;;
        revision-null) filter='.conflictMap.revisions = [null]' ;;
        revision-boolean) filter='.conflictMap.revisions = [false]' ;;
        revision-malformed) filter='.conflictMap.revisions = [{"reason":"","issues":[],"paths":[]}]' ;;
    esac
    jq "$filter" "$plan" >"$tmp/$invalid_case.json"
    assert_rc 1 "$invalid_case conflict-map member is rejected" -- \
        "$writer" --dispatch-plan "$tmp/$invalid_case.json" --validate-only
done

# --- workShape / holdReason (issue #444) ------------------------------
jq '.entries[0].workShape = "no-code" | .entries[0].holdReason = "issue body prohibits branches"' \
    "$plan" >"$tmp/work-shape-no-code.json"
assert_rc 0 'a no-code entry with a holdReason is accepted' -- \
    "$writer" --dispatch-plan "$tmp/work-shape-no-code.json" --validate-only

jq '.entries[0].workShape = "implementation"' "$plan" >"$tmp/work-shape-implementation.json"
assert_rc 0 'an explicit implementation workShape with no holdReason is accepted' -- \
    "$writer" --dispatch-plan "$tmp/work-shape-implementation.json" --validate-only

jq '.entries[0].workShape = "no-code"' "$plan" >"$tmp/work-shape-missing-reason.json"
assert_rc 1 'a no-code entry with no holdReason is rejected' -- \
    "$writer" --dispatch-plan "$tmp/work-shape-missing-reason.json" --validate-only

jq '.entries[0].workShape = "no-code" | .entries[0].holdReason = "   "' \
    "$plan" >"$tmp/work-shape-blank-reason.json"
assert_rc 1 'a no-code entry with a blank holdReason is rejected' -- \
    "$writer" --dispatch-plan "$tmp/work-shape-blank-reason.json" --validate-only

jq '.entries[0].workShape = "implementation" | .entries[0].holdReason = "stray"' \
    "$plan" >"$tmp/work-shape-stray-reason.json"
assert_rc 1 'a stray holdReason on an implementation entry is rejected' -- \
    "$writer" --dispatch-plan "$tmp/work-shape-stray-reason.json" --validate-only

jq '.entries[0].holdReason = "stray, no workShape at all"' "$plan" >"$tmp/work-shape-orphan-reason.json"
assert_rc 1 'a holdReason with no workShape at all is rejected' -- \
    "$writer" --dispatch-plan "$tmp/work-shape-orphan-reason.json" --validate-only

jq '.entries[0].workShape = "bogus"' "$plan" >"$tmp/work-shape-bogus.json"
assert_rc 1 'an unrecognized workShape value is rejected' -- \
    "$writer" --dispatch-plan "$tmp/work-shape-bogus.json" --validate-only

# --- a workShape=no-code hold is excluded from the ready-flip issue set
# (root-review F2, PR #463) ------------------------------------------------
# A HOLD entry never gets a worktree/branch/PR/head, so the merge-plan
# upgrade must compare against implementation-shaped entries only, while
# still keeping the hold in `entries` for audit/funnel accounting.
cat >"$tmp/held-plan-base.json" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [
    {"issue": 21, "predictedWriteSet": ["src/x"]},
    {"issue": 22, "predictedWriteSet": ["src/y"]},
    {"issue": 23, "predictedWriteSet": ["docs/research"], "workShape": "no-code", "holdReason": "issue body prohibits pull requests"}
  ],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
cat >"$tmp/held-merge-ok.json" <<'EOF'
{
  "generatedAt": "2026-08-17T20:00:00Z",
  "independent": [
    {"issue":21,"pr":201,"branch":"feat/twentyone","chainBaseSha":null,"headSha":"111111111111111111111111111111111111111a"},
    {"issue":22,"pr":202,"branch":"feat/twentytwo","chainBaseSha":null,"headSha":"222222222222222222222222222222222222222b"}
  ],
  "chains": []
}
EOF

cp "$tmp/held-plan-base.json" "$tmp/held-plan-ok.json"
"$writer" --dispatch-plan "$tmp/held-plan-ok.json" --merge-plan "$tmp/held-merge-ok.json"
assert_eq '2' "$(jq -r '.schemaVersion' "$tmp/held-plan-ok.json")" \
    'a merge plan covering exactly the implementation-shaped entries upgrades to schema 2'
assert_eq 'no-code' "$(jq -r '.entries[] | select(.issue == 23) | .workShape' "$tmp/held-plan-ok.json")" \
    'the held entry survives the upgrade with its workShape intact'
assert_eq 'null' "$(jq -r '.entries[] | select(.issue == 23) | .pr // "null"' "$tmp/held-plan-ok.json")" \
    'the held entry gains no pr/branch/head record from the upgrade'

cp "$tmp/held-plan-base.json" "$tmp/held-plan-includes-held.json"
jq '.independent += [{"issue":23,"pr":203,"branch":"feat/twentythree","chainBaseSha":null,"headSha":"333333333333333333333333333333333333333c"}]' \
    "$tmp/held-merge-ok.json" >"$tmp/held-merge-includes-held.json"
before_held=$(sha256sum "$tmp/held-plan-includes-held.json")
stderr=$("$writer" --dispatch-plan "$tmp/held-plan-includes-held.json" \
    --merge-plan "$tmp/held-merge-includes-held.json" 2>&1 1>/dev/null) && rc=0 || rc=$?
assert_eq '1' "$rc" 'a merge plan that includes the held issue is rejected'
assert_contains "$stderr" 'no-code' \
    'the held-issue rejection names the workShape=no-code exclusion'
assert_eq "$before_held" "$(sha256sum "$tmp/held-plan-includes-held.json")" \
    'a rejected held-issue merge plan leaves the dispatch plan byte-identical'

cp "$tmp/held-plan-base.json" "$tmp/held-plan-missing-impl.json"
jq '.independent = [.independent[0]]' "$tmp/held-merge-ok.json" >"$tmp/held-merge-missing-impl.json"
assert_rc 1 'a merge plan missing an implementation issue is still rejected' -- \
    "$writer" --dispatch-plan "$tmp/held-plan-missing-impl.json" --merge-plan "$tmp/held-merge-missing-impl.json"

jq 'del(.schemaVersion)' "$plan" >"$tmp/missing-schema.json"
missing_schema_rc=0
"$writer" --dispatch-plan "$tmp/missing-schema.json" --validate-only \
    >"$tmp/missing-schema.out" 2>"$tmp/missing-schema.err" || missing_schema_rc=$?
assert_eq '1' "$missing_schema_rc" \
    'a dispatch plan missing schemaVersion is rejected at the write-time gate'
assert_contains "$(cat "$tmp/missing-schema.err")" 'schemaVersion 1' \
    'the write-time refusal names the required dispatch schema'

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

jq '.independent[0] = null' "$merge_plan" >"$tmp/null-record.json"
stderr=$("$writer" --dispatch-plan "$plan" --merge-plan "$tmp/null-record.json" 2>&1 1>/dev/null) && rc=0 || rc=$?
assert_eq '1' "$rc" \
    'a merge plan with a null record is rejected'
assert_contains "$stderr" 'independent[0]' \
    'the null-record error names the record, not the generic fallback'

finish
