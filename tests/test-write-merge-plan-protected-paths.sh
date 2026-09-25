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
literal_out=$("$writer" --dispatch-plan "$literal_plan" --validate-only)
assert_contains "$literal_out" 'schemaVersion=1 valid' \
    'a default-protected literal path stays in the valid dispatch plan'
assert_contains "$literal_out" 'protected=1' 'the retained protected-path count is reported'
assert_contains "$literal_out" 'issue#583:.github/workflows/ci.yml' \
    'the retained protected issue and concrete path are reported'
assert_contains "$literal_out" 'proposal=0' \
    'a CI workflow can be prepared normally before its publication approval'

# --- a directory-prefix glob over a protected directory is flagged too. -----
glob_plan="$tmp/glob.json"
cat >"$glob_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 584, "predictedWriteSet": [".github/workflows/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
glob_out=$("$writer" --dispatch-plan "$glob_plan" --validate-only)
assert_contains "$glob_out" 'schemaVersion=1 valid' \
    'a directory-prefix glob over a protected directory stays dispatchable'
assert_contains "$glob_out" 'issue#584:.github/workflows/**' 'the colliding glob is reported'

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

# Incident examples do not redefine policy: ordinary .github/ and docs/adrs/
# paths remain unprotected while an actual harness configuration path is named.
actual_policy_plan="$tmp/actual-policy.json"
cat >"$actual_policy_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{
    "issue": 595,
    "predictedWriteSet": [".github/CODEOWNERS", "docs/adrs/decision.md", ".claude/settings.json"]
  }],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
actual_policy_out=$("$writer" --dispatch-plan "$actual_policy_plan" --validate-only)
assert_contains "$actual_policy_out" 'protected=1[issue#595:.claude/settings.json]' \
    'classification follows the shared protected policy instead of incident path guesses'
assert_contains "$actual_policy_out" 'proposal=1[issue#595:.claude/settings.json]' \
    'a retained harness-config issue is marked for safe patch proposal before approval'
assert_not_contains "$actual_policy_out" '.github/CODEOWNERS' \
    'ordinary .github content is not promoted to protected'
assert_not_contains "$actual_policy_out" 'docs/adrs/decision.md' \
    'ADR content is not promoted to protected'

# --- regression: a literal predictedWriteSet path containing a "/" must
# never be misrouted into the dir-prefix-glob branch -- `[[ $x == */** ]]`
# glob-matches ANY value containing a slash ("**" degrades to a plain "*"
# inside [[ ]], it is not bash's globstar), so a literal sibling of a
# protected literal file was wrongly flagged as colliding with its own
# containing directory. A quoted literal '/**' suffix test is required. -----
sibling_repo="$tmp/sibling-repo"
mkdir -p "$sibling_repo/.agent"
cat >"$sibling_repo/.agent/config.env" <<'EOF'
AGENT_PROTECTED_PATHS=config/prod.yml
EOF
git init -q -b main "$sibling_repo"
git -C "$sibling_repo" config user.email test@example.invalid
git -C "$sibling_repo" config user.name test
git -C "$sibling_repo" add -- .
git -C "$sibling_repo" commit -qm base

sibling_plan="$tmp/sibling.json"
cat >"$sibling_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 591, "predictedWriteSet": ["config/dev.yml"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
sibling_rc=0
(cd "$sibling_repo" && "$writer" --dispatch-plan "$sibling_plan" --validate-only) >/dev/null 2>&1 || sibling_rc=$?
assert_eq 0 "$sibling_rc" 'a literal path sibling of a protected literal file does not collide'

# A dir/** glob genuinely covering the protected file's directory must still
# collide -- the literal-suffix fix must not also disable the glob branch.
sibling_glob_plan="$tmp/sibling-glob.json"
cat >"$sibling_glob_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 592, "predictedWriteSet": ["config/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
sibling_glob_out=$(cd "$sibling_repo" && "$writer" --dispatch-plan "$sibling_glob_plan" --validate-only)
assert_contains "$sibling_glob_out" 'schemaVersion=1 valid' \
    'a dir/** glob covering a protected file remains dispatchable'
assert_contains "$sibling_glob_out" 'issue#592:config/**' 'the colliding glob is reported'

# --- regression: a predictedWriteSet entry containing a literal comma must
# never be split into phantom patterns by the comma-joined TSV transfer --
# that previously could manufacture a bogus collision from one safe path. --
comma_plan="$tmp/comma.json"
cat >"$comma_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 593, "predictedWriteSet": ["notes,.github/workflows/ci.yml"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'a single path containing a literal comma is never split into a phantom colliding pattern' -- \
    "$writer" --dispatch-plan "$comma_plan" --validate-only

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
declared_out=$(cd "$declared_repo" && "$writer" --dispatch-plan "$declared_plan" --validate-only)
assert_contains "$declared_out" 'schemaVersion=1 valid' \
    'a repo-declared protected path remains dispatchable'
assert_contains "$declared_out" 'issue#586:secrets/prod.env' \
    'the declared-pattern collision is reported'

# A repo with no such declaration never flags the same path. Run this from a
# neutral temporary repository -- never the host checkout -- so the negative
# assertion never depends on what this repository's own .agent/config.env
# happens to declare (it would silently break if AGENT_PROTECTED_PATHS ever
# grew a pattern matching "secrets/prod.env" here).
neutral_repo="$tmp/neutral-repo"
mkdir -p "$neutral_repo/.agent"
git init -q -b main "$neutral_repo"
git -C "$neutral_repo" config user.email test@example.invalid
git -C "$neutral_repo" config user.name test
git -C "$neutral_repo" commit -q --allow-empty -m base
neutral_rc=0
(cd "$neutral_repo" && "$writer" --dispatch-plan "$declared_plan" --validate-only) >/dev/null 2>&1 || neutral_rc=$?
assert_eq 0 "$neutral_rc" 'the same path is not flagged outside the declaring repo'

# --- regression: a repo-declared protected pattern carrying a leading "./"
# must still collide with a normal (unprefixed) write-set path -- without
# stripping "./" the same way worktree-commit.sh's shared_protected_pattern
# already does, this validated "clean" here and was only refused later, at
# commit time. -----------------------------------------------------------
dotslash_repo="$tmp/dotslash-repo"
mkdir -p "$dotslash_repo/.agent"
cat >"$dotslash_repo/.agent/config.env" <<'EOF'
AGENT_PROTECTED_PATHS=./secrets/
EOF
git init -q -b main "$dotslash_repo"
git -C "$dotslash_repo" config user.email test@example.invalid
git -C "$dotslash_repo" config user.name test
git -C "$dotslash_repo" add -- .
git -C "$dotslash_repo" commit -qm base

dotslash_plan="$tmp/dotslash.json"
cat >"$dotslash_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 594, "predictedWriteSet": ["secrets/x.env"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
dotslash_out=$(cd "$dotslash_repo" && "$writer" --dispatch-plan "$dotslash_plan" --validate-only)
assert_contains "$dotslash_out" 'schemaVersion=1 valid' \
    'a ./-prefixed declared protected pattern retains the issue'
assert_contains "$dotslash_out" 'issue#594:secrets/x.env' 'the colliding path is reported'

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

# --- acceptance: clean plans disclose that they contain no create entries. --
clean_plan="$tmp/clean.json"
cat >"$clean_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 589, "predictedWriteSet": ["src/a"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
clean_out=$("$writer" --dispatch-plan "$clean_plan" --validate-only)
assert_eq "dispatch-plan=$clean_plan schemaVersion=1 valid create=none protected=0 proposal=0" "$clean_out" \
    'a clean plan with no protected-path collision reports no create entries'

# --- acceptance: --fix does not need to alter a retained protected path. ----
fix_repo="$tmp/fix-repo"
mkdir -p "$fix_repo/src" "$fix_repo/.agent" "$fix_repo/.github/workflows"
printf 'source\n' >"$fix_repo/src/main.sh"
printf 'workflow\n' >"$fix_repo/.github/workflows/ci.yml"
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
fix_out=$("$writer" --dispatch-plan "$fix_plan" --chain-base "$fix_repo" --validate-only --fix)
assert_contains "$fix_out" 'schemaVersion=1 valid' '--fix keeps a protected-path issue dispatchable'
assert_eq 'null' "$(jq -r '.entries[0].protectedPathAcknowledgement // "null"' "$fix_plan")" \
    '--fix never auto-writes a protectedPathAcknowledgement'

# A protected root, its queued dependent, and unrelated runnable work all stay
# represented. Publication state, not path classification, releases the queue.
retained_plan="$tmp/retained.json"
cat >"$retained_plan" <<'EOF'
{
  "schemaVersion": 1,
  "selection": {"requested": 3, "eligible": 3, "dispatched": 2, "queued": [612], "tracker": []},
  "entries": [
    {"issue": 611, "predictedWriteSet": [".github/workflows/ci.yml"]},
    {"issue": 612, "predictedWriteSet": ["src/dependent.sh"]},
    {"issue": 613, "predictedWriteSet": ["src/unrelated.sh"]}
  ],
  "conflictMap": {
    "pairs": [{"issues": [611, 612], "overlap": ["src/dependency-contract.sh"]}],
    "revisions": []
  }
}
EOF
retained_out=$("$writer" --dispatch-plan "$retained_plan" --validate-only)
assert_contains "$retained_out" 'schemaVersion=1 valid' \
    'protected work, its queued dependent, and unrelated work remain in one valid plan'
assert_eq '3' "$(jq '.entries | length' "$retained_plan")" \
    'validation retains every selected issue'
assert_eq '612' "$(jq -r '.selection.queued[0]' "$retained_plan")" \
    'validation retains the named dependent in the queue'

finish
