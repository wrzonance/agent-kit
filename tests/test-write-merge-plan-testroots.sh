#!/usr/bin/env bash
# Regression coverage for issue #550: write-merge-plan.sh --validate-only must
# report every violation in one pass, tighten test-root detection to declared
# verify-command roots only (never a directory-name heuristic), accept a
# plan-level testRootExclusions default, and emit an applicable remedy.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='write merge plan test-root detection (#550)'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

writer="$root/agentkit/skills/parallel-issues/scripts/write-merge-plan.sh"

# --- a chain-base tree whose only declared test root is tests/, but which
# also contains docs/specs/** and frontend/** -- directories a naming
# heuristic over "test"/"spec" would have wrongly flagged as required roots.
chain_base="$tmp/chain-base"
mkdir -p "$chain_base/tests" "$chain_base/src" "$chain_base/docs/specs" \
    "$chain_base/frontend" "$chain_base/bench/gold/tally/test" "$chain_base/.agent"
printf '%s\n' 'test' >"$chain_base/tests/smoke.sh"
printf '%s\n' 'source' >"$chain_base/src/main.sh"
printf '%s\n' 'frontend source' >"$chain_base/frontend/app.js"
printf '%s\n' 'spec' >"$chain_base/docs/specs/design.md"
printf '%s\n' 'gold fixture' >"$chain_base/bench/gold/tally/test/expected.txt"
cat >"$chain_base/.agent/config.env" <<'EOF'
AGENT_CMD_TEST=tests/run-tests.sh
EOF
git init -q -b main "$chain_base"
git -C "$chain_base" config user.email test@example.invalid
git -C "$chain_base" config user.name test
git -C "$chain_base" add -- .
git -C "$chain_base" commit -qm base

# --- acceptance: only the declared test root (tests/) is demanded; frontend/
# and docs/specs/ are never treated as required roots even though a prior
# directory-name heuristic would have matched them. --------------------------
tightened_plan="$tmp/tightened.json"
cat >"$tightened_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 501, "predictedWriteSet": ["frontend/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
tightened_rc=0
tightened_err=$("$writer" --dispatch-plan "$tightened_plan" --chain-base "$chain_base" \
    --validate-only 2>&1 >/dev/null) || tightened_rc=$?
assert_eq 1 "$tightened_rc" 'a source-only write set still demands the declared test root'
assert_contains "$tightened_err" 'tests/**' \
    'the declared test root (tests/) is demanded'
assert_not_contains "$tightened_err" 'docs/specs' \
    'docs/specs/** is never treated as a required test root'
assert_not_contains "$tightened_err" 'frontend/**;' \
    'frontend/** itself is never treated as a required test root'
assert_not_contains "$tightened_err" 'bench/gold' \
    'bench/gold/**/test/** fixtures are never treated as required test roots'

# --- acceptance: one invocation reports every violation across every entry,
# not just the first -- three entries, each missing the one declared root. ---
multi_plan="$tmp/multi.json"
cat >"$multi_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [
    {"issue": 601, "predictedWriteSet": ["src/**"]},
    {"issue": 602, "predictedWriteSet": ["frontend/**"]},
    {"issue": 603, "predictedWriteSet": ["src/**", "frontend/**"]}
  ],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
multi_rc=0
multi_err=$("$writer" --dispatch-plan "$multi_plan" --chain-base "$chain_base" \
    --validate-only 2>&1 >/dev/null) || multi_rc=$?
assert_eq 1 "$multi_rc" 'a plan with multiple violating entries is rejected in one pass'
for issue in 601 602 603; do
    assert_contains "$multi_err" "issue #$issue write set names source but omits project test root: tests/**" \
        "issue #$issue's missing test root is reported in the same invocation"
done
assert_contains "$multi_err" 'remedy --' \
    'a remedy is printed alongside the findings'
remedy_count=$(grep -c "^  jq '(.entries\[\] | select(.issue == " <<<"$multi_err" || true)
assert_eq '3' "$remedy_count" \
    'one copy-pasteable remedy command is printed per violating entry'

# Apply the printed remedy verbatim; the next invocation must then pass.
while IFS= read -r remedy_cmd; do
    eval "$remedy_cmd"
done < <(grep "^  jq '(.entries\[\] | select(.issue == " <<<"$multi_err" | sed 's/^  //')
assert_rc 0 'after applying the printed remedy, the next invocation passes' -- \
    "$writer" --dispatch-plan "$multi_plan" --chain-base "$chain_base" --validate-only
for issue in 601 602 603; do
    assert_eq 'tests/**' "$(jq -r --arg issue "$issue" \
        '.entries[] | select(.issue == ($issue | tonumber)) | .testRootExclusions[0]' "$multi_plan")" \
        "issue #$issue's testRootExclusions now records the applied remedy"
done

# --- acceptance: --fix applies the same remedy mechanically. ----------------
fix_plan="$tmp/fix.json"
cat >"$fix_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 611, "predictedWriteSet": ["frontend/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 '--fix applies the missing-test-root remedy and exits 0' -- \
    "$writer" --dispatch-plan "$fix_plan" --chain-base "$chain_base" --validate-only --fix
assert_eq 'tests/**' "$(jq -r '.entries[0].testRootExclusions[0]' "$fix_plan")" \
    '--fix records the same exclusion the printed remedy would have'
assert_rc 0 'a --fix-repaired plan validates cleanly on the next invocation' -- \
    "$writer" --dispatch-plan "$fix_plan" --chain-base "$chain_base" --validate-only

fix_without_chain_base_rc=0
"$writer" --dispatch-plan "$fix_plan" --validate-only --fix >/dev/null 2>&1 || fix_without_chain_base_rc=$?
assert_eq '2' "$fix_without_chain_base_rc" \
    '--fix with no --chain-base is a usage error, not a silent no-op'

# --- acceptance: a plan-level testRootExclusions default satisfies every
# entry, so a repo-wide decision is one line instead of N per-entry copies. --
plan_level_plan="$tmp/plan-level.json"
cat >"$plan_level_plan" <<'EOF'
{
  "schemaVersion": 1,
  "testRootExclusions": ["tests/**"],
  "entries": [
    {"issue": 621, "predictedWriteSet": ["src/**"]},
    {"issue": 622, "predictedWriteSet": ["frontend/**"]}
  ],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'a plan-level testRootExclusions default satisfies every entry' -- \
    "$writer" --dispatch-plan "$plan_level_plan" --chain-base "$chain_base" --validate-only

# A plan-level testRootExclusions must still be schema-validated: an empty
# array is rejected the same way an empty per-entry list is.
empty_plan_level="$tmp/plan-level-empty.json"
jq '.testRootExclusions = []' "$plan_level_plan" >"$empty_plan_level"
assert_rc 1 'an empty plan-level testRootExclusions is rejected by the schema gate' -- \
    "$writer" --dispatch-plan "$empty_plan_level" --validate-only

finish
