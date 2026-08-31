#!/usr/bin/env bash
# Regression coverage for issue #583: write-merge-plan.sh --validate-only must
# flag a predictedWriteSet entry that collides with a protected path (default
# or repo-declared) instead of validating "clean" and only surfacing the
# block ~50 minutes later at worktree-commit.sh's protected-path refusal.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='write merge plan protected-path collisions (#583)'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

writer="$root/agentkit/skills/parallel-issues/scripts/write-merge-plan.sh"

# --- acceptance: a default-protected literal path is flagged with issue
# number, path, and a remedy. ------------------------------------------------
literal_plan="$tmp/literal.json"
cat >"$literal_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 583, "predictedWriteSet": [".github/workflows/ci.yml", "src/a"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
literal_rc=0
literal_err=$("$writer" --dispatch-plan "$literal_plan" --validate-only 2>&1 >/dev/null) || literal_rc=$?
assert_eq 1 "$literal_rc" 'a default-protected literal path is rejected'
assert_contains "$literal_err" 'issue #583' 'the violating issue number is named'
assert_contains "$literal_err" '.github/workflows/ci.yml' 'the colliding path is named'
assert_contains "$literal_err" 'protectedPathAcknowledgement' 'the remedy names the acknowledgement field'

# --- a directory-prefix glob over a protected directory is flagged too. -----
glob_plan="$tmp/glob.json"
cat >"$glob_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 584, "predictedWriteSet": [".github/workflows/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
glob_rc=0
glob_err=$("$writer" --dispatch-plan "$glob_plan" --validate-only 2>&1 >/dev/null) || glob_rc=$?
assert_eq 1 "$glob_rc" 'a directory-prefix glob over a protected directory is rejected'
assert_contains "$glob_err" '.github/workflows/**' 'the colliding glob is named'

# --- a benign path is never a false positive (no substring match on a
# protected pattern's name). --------------------------------------------------
benign_plan="$tmp/benign.json"
cat >"$benign_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 585, "predictedWriteSet": [".github/workflows-docs/readme.md"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'a path that merely shares a prefix string with a protected pattern is not flagged' -- \
    "$writer" --dispatch-plan "$benign_plan" --validate-only

# --- acceptance: a repo-declared AGENT_PROTECTED_PATHS pattern is honored. --
declared_repo="$tmp/declared-repo"
mkdir -p "$declared_repo/.agent"
cat >"$declared_repo/.agent/config.env" <<'EOF'
AGENT_PROTECTED_PATHS=secrets/
EOF
git init -q -b main "$declared_repo"
git -C "$declared_repo" config user.email test@example.invalid
git -C "$declared_repo" config user.name test
git -C "$declared_repo" add -- .
git -C "$declared_repo" commit -qm base

declared_plan="$tmp/declared.json"
cat >"$declared_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 586, "predictedWriteSet": ["secrets/prod.env"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
declared_rc=0
declared_err=$(cd "$declared_repo" && "$writer" --dispatch-plan "$declared_plan" --validate-only 2>&1 >/dev/null) || declared_rc=$?
assert_eq 1 "$declared_rc" 'a repo-declared AGENT_PROTECTED_PATHS pattern is honored'
assert_contains "$declared_err" 'secrets/prod.env' 'the declared-pattern collision is named'

# A repo with no such declaration never flags the same path.
assert_rc 0 'the same path is not flagged outside the declaring repo' -- \
    "$writer" --dispatch-plan "$declared_plan" --validate-only

# --- acceptance: an explicit protectedPathAcknowledgement (entry-level)
# validates. -------------------------------------------------------------------
acked_plan="$tmp/acked.json"
cat >"$acked_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{
    "issue": 587,
    "predictedWriteSet": [".github/workflows/ci.yml", "src/a"],
    "protectedPathAcknowledgement": [".github/workflows/ci.yml"]
  }],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'an explicit entry-level acknowledgement validates' -- \
    "$writer" --dispatch-plan "$acked_plan" --validate-only

# A plan-level protectedPathAcknowledgement default satisfies every entry too.
plan_level_acked="$tmp/acked-plan-level.json"
cat >"$plan_level_acked" <<'EOF'
{
  "schemaVersion": 1,
  "protectedPathAcknowledgement": [".github/workflows/ci.yml"],
  "entries": [{"issue": 588, "predictedWriteSet": [".github/workflows/ci.yml"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'a plan-level protectedPathAcknowledgement default satisfies every entry' -- \
    "$writer" --dispatch-plan "$plan_level_acked" --validate-only

# An empty protectedPathAcknowledgement is rejected by the schema gate, same
# as an empty testRootExclusions.
empty_acked="$tmp/empty-acked.json"
jq '.entries[0].protectedPathAcknowledgement = []' "$acked_plan" >"$empty_acked"
assert_rc 1 'an empty protectedPathAcknowledgement is rejected by the schema gate' -- \
    "$writer" --dispatch-plan "$empty_acked" --validate-only

# --- acceptance: clean plans produce byte-identical output to today. --------
clean_plan="$tmp/clean.json"
cat >"$clean_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 589, "predictedWriteSet": ["src/a"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
clean_out=$("$writer" --dispatch-plan "$clean_plan" --validate-only)
assert_eq "dispatch-plan=$clean_plan schemaVersion=1 valid" "$clean_out" \
    'a clean plan with no protected-path collision produces the unchanged, byte-identical success line'

# --- acceptance: --fix never silently "fixes" a protected-path collision --
# it is a human decision (drop/split/acknowledge), never auto-patched. -------
fix_repo="$tmp/fix-repo"
mkdir -p "$fix_repo/src" "$fix_repo/.agent"
printf 'source\n' >"$fix_repo/src/main.sh"
git init -q -b main "$fix_repo"
git -C "$fix_repo" config user.email test@example.invalid
git -C "$fix_repo" config user.name test
git -C "$fix_repo" add -- .
git -C "$fix_repo" commit -qm base

fix_plan="$tmp/fix-collision.json"
cat >"$fix_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 590, "predictedWriteSet": [".github/workflows/ci.yml"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
fix_rc=0
"$writer" --dispatch-plan "$fix_plan" --chain-base "$fix_repo" --validate-only --fix >/dev/null 2>&1 || fix_rc=$?
assert_eq 1 "$fix_rc" '--fix cannot resolve a protected-path collision and still exits nonzero'
assert_eq 'null' "$(jq -r '.entries[0].protectedPathAcknowledgement // "null"' "$fix_plan")" \
    '--fix never auto-writes a protectedPathAcknowledgement'

finish
