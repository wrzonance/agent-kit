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

# --- predicted write-set globs resolve against the chain-base tree ---------
chain_base="$tmp/chain-base"
mkdir -p "$chain_base/tests/CableTool.Core.Tests" "$chain_base/src" "$chain_base/.agent"
printf '%s\n' 'test' >"$chain_base/tests/CableTool.Core.Tests/Smoke.sh"
printf '%s\n' 'source' >"$chain_base/src/main.sh"
printf '%s\n' 'dotted' >"$chain_base/src/exact.new.txt"
printf '%s\n' 'bracket' >"$chain_base/src/literal[.txt"
mkdir -p "$chain_base/docs"
printf '%s\n' 'docs' >"$chain_base/docs/README.md"
mkdir -p "$chain_base/docs/c++" "$chain_base/docs/cx"
printf '%s\n' 'plus' >"$chain_base/docs/c++/README.md"
printf '%s\n' 'near miss' >"$chain_base/docs/cx/README.md"
cat >"$chain_base/.agent/config.env" <<'EOF'
AGENT_RUNDIR_ADDIN_TEST=./tests/CableTool.Core.Tests/
AGENT_RUNDIR_REPO_ROOT_TEST=.
EOF
git init -q -b main "$chain_base"
git -C "$chain_base" config user.email test@example.invalid
git -C "$chain_base" config user.name test
git -C "$chain_base" add -- .
git -C "$chain_base" commit -qm base

zero_match_plan="$tmp/zero-match.json"
cat >"$zero_match_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 14, "predictedWriteSet": ["addin/tests/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
zero_match_rc=0
zero_match_err=$("$writer" --dispatch-plan "$zero_match_plan" --chain-base "$chain_base" \
    --validate-only 2>&1 >/dev/null) || zero_match_rc=$?
assert_eq 1 "$zero_match_rc" 'a predicted glob matching no chain-base paths is rejected'
assert_contains "$zero_match_err" 'addin/tests/**' \
    'the zero-match refusal names the missing prediction'
assert_contains "$zero_match_err" 'tests/CableTool.Core.Tests/**' \
    'the zero-match refusal names the nearest existing sibling'

exact_new_plan="$tmp/exact-new-file.json"
cat >"$exact_new_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 141, "predictedWriteSet": ["src/future-file.sh"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'an exact new-file prediction is accepted when its literal parent exists' -- \
    "$writer" --dispatch-plan "$exact_new_plan" --chain-base "$chain_base" --validate-only

literal_glob_plan="$tmp/literal-glob.json"
cat >"$literal_glob_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 142, "predictedWriteSet": ["src/exact.new.txt", "src/literal[.txt", "tests/CableTool.Core.Tests/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'dots and unmatched opening brackets are escaped in predicted globs' -- \
    "$writer" --dispatch-plan "$literal_glob_plan" --chain-base "$chain_base" --validate-only

metachar_glob_plan="$tmp/metachar-glob.json"
cat >"$metachar_glob_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 143, "predictedWriteSet": ["docs/c++/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'plus signs are escaped in predicted globs' -- \
    "$writer" --dispatch-plan "$metachar_glob_plan" --chain-base "$chain_base" --validate-only

overmatch_glob_plan="$tmp/overmatch-glob.json"
cat >"$overmatch_glob_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 144, "predictedWriteSet": ["docs/c+++/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 1 'escaped plus signs prevent a near-match from satisfying a glob' -- \
    "$writer" --dispatch-plan "$overmatch_glob_plan" --chain-base "$chain_base" --validate-only

matching_plan="$tmp/matching.json"
cat >"$matching_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 15, "predictedWriteSet": ["src/**", "tests/CableTool.Core.Tests/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'predicted globs matching the chain-base tree are accepted' -- \
    "$writer" --dispatch-plan "$matching_plan" --chain-base "$chain_base" --validate-only

test_root_plan="$tmp/test-root-missing.json"
cat >"$test_root_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 16, "predictedWriteSet": ["src/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
test_root_rc=0
test_root_err=$("$writer" --dispatch-plan "$test_root_plan" --chain-base "$chain_base" \
    --validate-only 2>&1 >/dev/null) || test_root_rc=$?
assert_eq 1 "$test_root_rc" 'source predictions require a project test-root decision'
assert_contains "$test_root_err" 'tests/CableTool.Core.Tests/**' \
    'test-root refusal proposes the configured test root'
assert_not_contains "$test_root_err" './**' \
    'repo-root test configuration is skipped after root normalization'

test_root_excluded="$tmp/test-root-excluded.json"
jq '.entries[0].testRootExclusions = ["tests/CableTool.Core.Tests/**"]' \
    "$test_root_plan" >"$test_root_excluded"
assert_rc 0 'an explicit test-root exclusion satisfies validation' -- \
    "$writer" --dispatch-plan "$test_root_excluded" --chain-base "$chain_base" --validate-only

docs_plan="$tmp/docs-only.json"
cat >"$docs_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 17, "predictedWriteSet": ["docs/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'documentation-only predictions do not require project test roots' -- \
    "$writer" --dispatch-plan "$docs_plan" --chain-base "$chain_base" --validate-only
# Selection accounting is optional for older plans, but when present it must
# be typed so the fast-mode funnel cannot be made to claim a queue or tracker
# count from malformed run data.
jq '.selection = {"requested":11,"eligible":11,"dispatched":10,
                  "queued":[12],"tracker":[13]}' "$plan" >"$tmp/selection-valid.json"
assert_rc 0 'valid fast-mode selection accounting is accepted' -- \
    "$writer" --dispatch-plan "$tmp/selection-valid.json" --validate-only
jq '.selection.queued = ["12"]' "$tmp/selection-valid.json" >"$tmp/selection-bad.json"
jq '.selection.requested = 3 | .selection.eligible = 5 | .selection.dispatched = 3' \
    "$tmp/selection-valid.json" >"$tmp/selection-overflow.json"
assert_rc 0 'selection accounting permits eligible candidates beyond the requested slots' -- \
    "$writer" --dispatch-plan "$tmp/selection-overflow.json" --validate-only
jq '.selection.dispatched = 4' "$tmp/selection-overflow.json" >"$tmp/selection-over-dispatched.json"
assert_rc 1 'selection accounting rejects dispatched work beyond requested slots' -- \
    "$writer" --dispatch-plan "$tmp/selection-over-dispatched.json" --validate-only
assert_rc 1 'selection queue issue numbers must be positive integers' -- \
    "$writer" --dispatch-plan "$tmp/selection-bad.json" --validate-only
jq '.selection = {"requested":3,"eligible":3,"dispatched":3,
                  "queued":0,"tracker":0}' "$plan" >"$tmp/selection-counts.json"
assert_rc 0 'legacy scalar queue and tracker counts remain accepted' -- \
    "$writer" --dispatch-plan "$tmp/selection-counts.json" --validate-only

# Queue and tracker issue lists are candidate identities, not free-form
# counters.  They may contain candidates not yet represented by dispatched
# entries, and cannot overlap.
jq '.selection = {"requested":3,"eligible":3,"dispatched":1,
                  "queued":[12],"tracker":[13]}' "$plan" >"$tmp/selection-members.json"
assert_rc 0 'selection queue and tracker members are accepted' -- \
    "$writer" --dispatch-plan "$tmp/selection-members.json" --validate-only
jq '.selection.queued = [99] | .selection.tracker = [100]' \
    "$tmp/selection-members.json" >"$tmp/selection-unlisted-candidates.json"
assert_rc 0 'schema-1 selection permits queued and tracker candidates not yet dispatched' -- \
    "$writer" --dispatch-plan "$tmp/selection-unlisted-candidates.json" --validate-only
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

# --- CR-690-D/E: workflow_lock_siblings() matches `paths:` globs, and
# excludes only the workflow file itself, not every .github/ path -----------
dep_base="$tmp/dep-base"
mkdir -p "$dep_base/tools/dep" "$dep_base/.github/workflows"
printf '[package]\nname = "root"\n' >"$dep_base/Cargo.toml"
printf '# generated\n' >"$dep_base/Cargo.lock"
printf '[package]\nname = "dep"\n' >"$dep_base/tools/dep/Cargo.toml"
printf '# generated\n' >"$dep_base/tools/dep/Cargo.lock"
printf '{}\n' >"$dep_base/.github/dependency-snapshot.json"
printf 'rs companion\n' >"$dep_base/only-for-rs.txt"
cat >"$dep_base/.github/workflows/lockfile-check.yml" <<'EOF'
on:
  push:
    paths:
      - '**/Cargo.lock'
      - '.github/dependency-snapshot.json'
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo test
EOF
cat >"$dep_base/.github/workflows/rust-lint.yml" <<'EOF'
on:
  push:
    paths:
      - '**/*.rs'
      - 'only-for-rs.txt'
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo test
EOF
git init -q -b main "$dep_base"
git -C "$dep_base" config user.email test@example.invalid
git -C "$dep_base" config user.name test
git -C "$dep_base" add -- .
git -C "$dep_base" commit -qm base

dep_missing_plan="$tmp/dep-missing-companions.json"
cat >"$dep_missing_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 610, "predictedWriteSet": ["Cargo.toml", "tools/dep/Cargo.toml"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
dep_missing_rc=0
dep_missing_err=$("$writer" --dispatch-plan "$dep_missing_plan" --chain-base "$dep_base" \
    --validate-only 2>&1 >/dev/null) || dep_missing_rc=$?
assert_eq 1 "$dep_missing_rc" \
    'predicting a manifest without its lockfile and workflow-triggered companion is rejected'
assert_contains "$dep_missing_err" 'omits its companion: Cargo.lock' \
    'the root manifest is missing its sibling Cargo.lock'
assert_contains "$dep_missing_err" 'omits its companion: tools/dep/Cargo.lock' \
    'the nested manifest is missing its own sibling Cargo.lock (glob-matched at depth)'
assert_contains "$dep_missing_err" 'omits its companion: .github/dependency-snapshot.json' \
    'the workflow paths: glob sibling of Cargo.lock is a required companion, not excluded as a blanket .github/ path'
assert_not_contains "$dep_missing_err" 'only-for-rs.txt' \
    'an unrelated paths: glob (**/*.rs) never contributes a Cargo.lock companion'

dep_complete_plan="$tmp/dep-complete.json"
cat >"$dep_complete_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 610, "predictedWriteSet": [
    "Cargo.toml", "Cargo.lock", "tools/dep/Cargo.toml", "tools/dep/Cargo.lock",
    ".github/dependency-snapshot.json"
  ]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'a predicted write set already naming every manifest companion is accepted' -- \
    "$writer" --dispatch-plan "$dep_complete_plan" --chain-base "$dep_base" --validate-only

# --- CR-690-F: nearest_ancestor_lockfile() only lets Cargo adopt an ancestor
# lockfile, and only when a tracked ancestor Cargo.toml proves [workspace] --
ws_base="$tmp/ws-base"
mkdir -p "$ws_base/crates/foo"
printf '[workspace]\nmembers = ["crates/foo"]\n' >"$ws_base/Cargo.toml"
printf '# generated\n' >"$ws_base/Cargo.lock"
printf '[package]\nname = "foo"\n' >"$ws_base/crates/foo/Cargo.toml"
git init -q -b main "$ws_base"
git -C "$ws_base" config user.email test@example.invalid
git -C "$ws_base" config user.name test
git -C "$ws_base" add -- .
git -C "$ws_base" commit -qm base

ws_member_plan="$tmp/ws-member.json"
cat >"$ws_member_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 611, "predictedWriteSet": ["crates/foo/Cargo.toml"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
ws_member_err=$("$writer" --dispatch-plan "$ws_member_plan" --chain-base "$ws_base" \
    --validate-only 2>&1 >/dev/null) && ws_member_rc=0 || ws_member_rc=$?
assert_eq 1 "$ws_member_rc" \
    'a workspace member manifest without the workspace-root Cargo.lock is rejected'
assert_contains "$ws_member_err" 'omits its companion: Cargo.lock' \
    'the proven workspace root Cargo.lock is adopted as the ancestor companion'

ws_member_complete_plan="$tmp/ws-member-complete.json"
cat >"$ws_member_complete_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 611, "predictedWriteSet": ["crates/foo/Cargo.toml", "Cargo.lock"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'a workspace member paired with the proven ancestor Cargo.lock is accepted' -- \
    "$writer" --dispatch-plan "$ws_member_complete_plan" --chain-base "$ws_base" --validate-only

nonws_base="$tmp/nonws-base"
mkdir -p "$nonws_base/tools/bar"
printf '[package]\nname = "root"\n' >"$nonws_base/Cargo.toml"
printf '# generated -- belongs to the unrelated root project only\n' >"$nonws_base/Cargo.lock"
printf '[package]\nname = "bar"\n' >"$nonws_base/tools/bar/Cargo.toml"
git init -q -b main "$nonws_base"
git -C "$nonws_base" config user.email test@example.invalid
git -C "$nonws_base" config user.name test
git -C "$nonws_base" add -- .
git -C "$nonws_base" commit -qm base

nonws_plan="$tmp/nonws.json"
cat >"$nonws_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 612, "predictedWriteSet": ["tools/bar/Cargo.toml"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'a nested project under an unrelated root Cargo.toml (no [workspace]) never adopts the root Cargo.lock' -- \
    "$writer" --dispatch-plan "$nonws_plan" --chain-base "$nonws_base" --validate-only

# --- CR-690-F round 2: a "[workspace]" header alone proves an ancestor IS a
# workspace root, but not that THIS manifest is one of its declared members
# -- nearest_ancestor_lockfile() must also prove membership (members glob
# match, and no exclude match) before adopting the ancestor Cargo.lock -----
ws_glob_base="$tmp/ws-glob-base"
mkdir -p "$ws_glob_base/crates/foo" "$ws_glob_base/crates/bar" "$ws_glob_base/tools/unlisted" "$ws_glob_base/crates/excluded-crate"
cat >"$ws_glob_base/Cargo.toml" <<'EOF'
[workspace]
members = [
    "crates/*",
]
exclude = ["crates/excluded-crate"]
EOF
printf '# generated\n' >"$ws_glob_base/Cargo.lock"
printf '[package]\nname = "foo"\n' >"$ws_glob_base/crates/foo/Cargo.toml"
printf '[package]\nname = "bar"\n' >"$ws_glob_base/crates/bar/Cargo.toml"
printf '[package]\nname = "unlisted"\n' >"$ws_glob_base/tools/unlisted/Cargo.toml"
printf '[package]\nname = "excluded"\n' >"$ws_glob_base/crates/excluded-crate/Cargo.toml"
git init -q -b main "$ws_glob_base"
git -C "$ws_glob_base" config user.email test@example.invalid
git -C "$ws_glob_base" config user.name test
git -C "$ws_glob_base" add -- .
git -C "$ws_glob_base" commit -qm base

ws_glob_member_plan="$tmp/ws-glob-member.json"
cat >"$ws_glob_member_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 614, "predictedWriteSet": ["crates/foo/Cargo.toml"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
ws_glob_member_err=$("$writer" --dispatch-plan "$ws_glob_member_plan" --chain-base "$ws_glob_base" \
    --validate-only 2>&1 >/dev/null) && ws_glob_member_rc=0 || ws_glob_member_rc=$?
assert_eq 1 "$ws_glob_member_rc" \
    'a manifest matched by a members glob (crates/*) is still rejected without its ancestor lockfile'
assert_contains "$ws_glob_member_err" 'omits its companion: Cargo.lock' \
    'the members glob "crates/*" proves crates/foo is a workspace member, so the ancestor Cargo.lock is adopted'

ws_unlisted_plan="$tmp/ws-unlisted.json"
cat >"$ws_unlisted_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 615, "predictedWriteSet": ["tools/unlisted/Cargo.toml"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'a manifest under a workspace root but not matched by any members entry never adopts the ancestor Cargo.lock' -- \
    "$writer" --dispatch-plan "$ws_unlisted_plan" --chain-base "$ws_glob_base" --validate-only

ws_excluded_plan="$tmp/ws-excluded.json"
cat >"$ws_excluded_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 616, "predictedWriteSet": ["crates/excluded-crate/Cargo.toml"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'a manifest matched by members but also matched by exclude never adopts the ancestor Cargo.lock' -- \
    "$writer" --dispatch-plan "$ws_excluded_plan" --chain-base "$ws_glob_base" --validate-only

go_base="$tmp/go-base"
mkdir -p "$go_base/services/x" "$go_base/services/y"
printf 'module example.invalid/root\n' >"$go_base/go.mod"
printf 'example.invalid/dep v1.0.0 h1:abc=\n' >"$go_base/go.sum"
printf 'module example.invalid/x\n' >"$go_base/services/x/go.mod"
printf 'module example.invalid/y\n' >"$go_base/services/y/go.mod"
printf 'example.invalid/dep v1.0.0 h1:def=\n' >"$go_base/services/y/go.sum"
git init -q -b main "$go_base"
git -C "$go_base" config user.email test@example.invalid
git -C "$go_base" config user.name test
git -C "$go_base" add -- .
git -C "$go_base" commit -qm base

go_no_sibling_plan="$tmp/go-no-sibling.json"
cat >"$go_no_sibling_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 613, "predictedWriteSet": ["services/x/go.mod"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'a Go module with no sibling go.sum never adopts a same-named ancestor go.sum' -- \
    "$writer" --dispatch-plan "$go_no_sibling_plan" --chain-base "$go_base" --validate-only

go_sibling_plan="$tmp/go-sibling.json"
cat >"$go_sibling_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 613, "predictedWriteSet": ["services/y/go.mod"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
go_sibling_err=$("$writer" --dispatch-plan "$go_sibling_plan" --chain-base "$go_base" \
    --validate-only 2>&1 >/dev/null) && go_sibling_rc=0 || go_sibling_rc=$?
assert_eq 1 "$go_sibling_rc" \
    'a Go module with its own sibling go.sum still requires that companion'
assert_contains "$go_sibling_err" 'omits its companion: services/y/go.sum' \
    'the sibling go.sum (not the unrelated root go.sum) is the required companion'

finish
