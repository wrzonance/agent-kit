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
remedy_count=$(grep -c '^  jq --argjson issue ' <<<"$multi_err" || true)
assert_eq '3' "$remedy_count" \
    'one copy-pasteable remedy command is printed per violating entry'

# The remedy is built as data (printf %q per argument via --argjson), never by
# interpolating a repository-derived value inside a literal single-quoted jq
# filter -- an embedded quote in that value would otherwise escape the
# operator's copy-pasted shell command (#550 F1).
assert_not_contains "$(cat -- "$writer")" "select(.issue == %s)" \
    'the printed remedy never interpolates repo-derived data inside a literal single-quoted jq filter'
assert_contains "$(cat -- "$writer")" "jq --argjson issue %q --argjson roots %q %q %q" \
    'the printed remedy shell-escapes every data argument with printf %q'

# Apply the printed remedy verbatim; the next invocation must then pass.
while IFS= read -r remedy_cmd; do
    eval "$remedy_cmd"
done < <(grep '^  jq --argjson issue ' <<<"$multi_err" | sed 's/^  //')
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

# --- acceptance: --fix exits nonzero when a non-fixable violation (an
# unmatched predictedWriteSet glob) remains after applying the missing-test-
# root patches it can make (#550 F2). ----------------------------------------
partial_fix_plan="$tmp/partial-fix.json"
cat >"$partial_fix_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [
    {"issue": 631, "predictedWriteSet": ["frontend/**"]},
    {"issue": 632, "predictedWriteSet": ["nowhere/**"]}
  ],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
partial_fix_rc=0
partial_fix_err=$("$writer" --dispatch-plan "$partial_fix_plan" --chain-base "$chain_base" \
    --validate-only --fix 2>&1 >/dev/null) || partial_fix_rc=$?
assert_eq 1 "$partial_fix_rc" \
    '--fix exits nonzero when an unmatched-glob violation remains after applying exclusions'
assert_contains "$partial_fix_err" 'nowhere/**' \
    'the non-fixable remaining violation is named in the --fix output'
assert_eq 'tests/**' "$(jq -r '.entries[0].testRootExclusions[0] // "null"' "$partial_fix_plan")" \
    '--fix still applies the patch it can make even though the overall result fails'

# --- acceptance: a repository that genuinely declares a test root under
# docs/ is honored -- detection is declaration-driven only, with no
# unconditional docs/**/bench/gold/** filter discarding a real declaration
# (#550 F3). ------------------------------------------------------------------
docs_root_base="$tmp/docs-root-base"
mkdir -p "$docs_root_base/tests" "$docs_root_base/docs" "$docs_root_base/src" "$docs_root_base/.agent"
printf '%s\n' 'test' >"$docs_root_base/tests/smoke.sh"
printf '%s\n' 'doc test runner' >"$docs_root_base/docs/run-tests.sh"
printf '%s\n' 'source' >"$docs_root_base/src/main.sh"
cat >"$docs_root_base/.agent/config.env" <<'EOF'
AGENT_CMD_TEST=tests/run-tests.sh
AGENT_CMD_DOCS_TEST=docs/run-tests.sh
EOF
git init -q -b main "$docs_root_base"
git -C "$docs_root_base" config user.email test@example.invalid
git -C "$docs_root_base" config user.name test
git -C "$docs_root_base" add -- .
git -C "$docs_root_base" commit -qm base

docs_root_plan="$tmp/docs-root.json"
cat >"$docs_root_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 641, "predictedWriteSet": ["src/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
docs_root_rc=0
docs_root_err=$("$writer" --dispatch-plan "$docs_root_plan" --chain-base "$docs_root_base" \
    --validate-only 2>&1 >/dev/null) || docs_root_rc=$?
assert_eq 1 "$docs_root_rc" \
    'a source-only write set demands every declared test root, including one declared under docs/'
assert_contains "$docs_root_err" 'tests/**' \
    'the declared tests/ root is demanded'
assert_contains "$docs_root_err" 'docs/**' \
    'a declared docs/ test root is demanded too -- it is no longer unconditionally filtered out'

# --- acceptance: an argv[0]-derived root whose directory does not exist in
# the chain-base tree is never treated as a required test root; an absolute
# or parent-traversing argv[0] is guarded the same way in source (#550 F4). --
ghost_base="$tmp/ghost-base"
mkdir -p "$ghost_base/tests" "$ghost_base/src" "$ghost_base/.agent"
printf '%s\n' 'test' >"$ghost_base/tests/smoke.sh"
printf '%s\n' 'source' >"$ghost_base/src/main.sh"
cat >"$ghost_base/.agent/config.env" <<'EOF'
AGENT_CMD_TEST=tests/run-tests.sh
AGENT_CMD_GHOST_TEST=ghost/run-tests.sh
EOF
git init -q -b main "$ghost_base"
git -C "$ghost_base" config user.email test@example.invalid
git -C "$ghost_base" config user.name test
git -C "$ghost_base" add -- .
git -C "$ghost_base" commit -qm base

ghost_plan="$tmp/ghost.json"
cat >"$ghost_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 651, "predictedWriteSet": ["src/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
ghost_rc=0
ghost_err=$("$writer" --dispatch-plan "$ghost_plan" --chain-base "$ghost_base" \
    --validate-only 2>&1 >/dev/null) || ghost_rc=$?
assert_eq 1 "$ghost_rc" 'the real declared test root is still demanded'
assert_contains "$ghost_err" 'tests/**' \
    'the tests/ root that actually exists in the tree is demanded'
assert_not_contains "$ghost_err" 'ghost/**' \
    'an argv[0]-derived root whose directory does not exist in the chain-base tree is never demanded'
assert_contains "$(cat -- "$writer")" 'test_root_dir_exists' \
    'argv[0]-derived roots are validated against the chain-base tree before being treated as required'

# --- acceptance: --chain-base <ref> reads test-root configuration from that
# ref's tracked .agent/config.env, never the live checkout's -- a chain
# successor's declared root is honored even when the live checkout is on a
# different commit (#550 F5). -------------------------------------------------
ref_base="$tmp/ref-base"
mkdir -p "$ref_base/alpha" "$ref_base/src" "$ref_base/.agent"
printf '%s\n' 'alpha test' >"$ref_base/alpha/smoke.sh"
printf '%s\n' 'source' >"$ref_base/src/main.sh"
cat >"$ref_base/.agent/config.env" <<'EOF'
AGENT_CMD_TEST=alpha/run-tests.sh
EOF
git init -q -b main "$ref_base"
git -C "$ref_base" config user.email test@example.invalid
git -C "$ref_base" config user.name test
git -C "$ref_base" add -- .
git -C "$ref_base" commit -qm 'declares alpha/ as the test root'
base_sha=$(git -C "$ref_base" rev-parse HEAD)

mkdir -p "$ref_base/beta"
printf '%s\n' 'beta test' >"$ref_base/beta/smoke.sh"
cat >"$ref_base/.agent/config.env" <<'EOF'
AGENT_CMD_TEST=beta/run-tests.sh
EOF
git -C "$ref_base" add -- .
git -C "$ref_base" commit -qm 'live checkout now declares beta/ instead'

ref_plan="$tmp/ref-base.json"
cat >"$ref_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 661, "predictedWriteSet": ["src/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
ref_rc=0
ref_err=$(cd "$ref_base" && "$writer" --dispatch-plan "$ref_plan" --chain-base "$base_sha" \
    --validate-only 2>&1 >/dev/null) || ref_rc=$?
assert_eq 1 "$ref_rc" 'a chain-base ref still demands the test root it declares'
assert_contains "$ref_err" 'alpha/**' \
    "the referenced commit's declared root (alpha/) is honored, not the live checkout's"
assert_not_contains "$ref_err" 'beta' \
    "the live checkout's config (beta/) is never consulted when the chain base pins an older ref"
assert_contains "$ref_err" 'test-root config source: chain-base ref' \
    'the resolved config source is disclosed'

finish
