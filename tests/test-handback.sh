#!/usr/bin/env bash
# Suite: validate-handback.sh checks a root publication command without running it.
set -euo pipefail

TEST_NAME='validate-handback'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(dirname -- "$here")
script="$root/agentkit/skills/.shared/scripts/validate-handback.sh"
source "$here/lib/assert.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/validate-handback-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo/.agent" "$repo/src" "$repo/secrets"
cat >"$repo/.agent/config.env" <<'EOF'
AGENT_WORKER_MODEL=gpt-5.6-luna
AGENT_PROTECTED_PATHS=secrets/
EOF
git init -q -b feature "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
printf 'base\n' >"$repo/src/tracked.txt"
git -C "$repo" add -- .
git -C "$repo" commit -qm base
printf 'changed\n' >"$repo/src/tracked.txt"
printf 'new\n' >"$repo/src/untracked.txt"
printf 'workflow\n' >"$repo/secrets/config.txt"

helper="$root/agentkit/skills/.shared/scripts/worktree-commit.sh"
plan="$tmp/dispatch-plan.json"
cat >"$plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [
    {
      "issue": 167,
      "predictedWriteSet": ["src/tracked.txt", "src/untracked.txt"]
    }
  ],
  "conflictMap": {
    "pairs": [{"issues": [164, 167], "overlap": ["src/shared/**"]}],
    "revisions": [{"phase": "post-selection", "reason": "keep the reviewed successor edge"}]
  }
}
EOF
validate() {
    "$script" --worktree "$1" --handback-file "$2" --issue 167 \
        --dispatch-plan "$plan"
}
valid_handback="$tmp/valid.handback"
cat >"$valid_handback" <<EOF
"$helper" --message 'feat(skills): validate handbacks' --body 'Checks the publication boundary.' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt src/untracked.txt
EOF

valid_output="$tmp/valid.argv"
valid_rc=0
validate "$repo" "$valid_handback" >"$valid_output" 2>"$tmp/valid.err" || valid_rc=$?
assert_eq '0' "$valid_rc" 'valid handback passes'
assert_eq "$helper
--message
feat(skills): validate handbacks
--body
Checks the publication boundary.
--trailer
Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>
--
src/tracked.txt
src/untracked.txt" "$(tr '\0' '\n' <"$valid_output")" \
    'valid handback returns the parsed argv NUL-delimited'
assert_eq '' "$(cat -- "$tmp/valid.err")" 'valid handback keeps diagnostics off stdout and stderr'

schema_two_plan="$tmp/schema-two-plan.json"
jq '.schemaVersion = 2 |
    .generatedAt = "2026-08-24T12:00:00Z" |
    .independent = [{"issue":167,"pr":424,"branch":"feat/issue-167","chainBaseSha":null,"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}] |
    .chains = []' "$plan" >"$schema_two_plan"
plan_before_schema_two=$plan
plan=$schema_two_plan
schema_two_rc=0
validate "$repo" "$valid_handback" >"$tmp/schema-two.out" \
    2>"$tmp/schema-two.err" || schema_two_rc=$?
assert_eq '0' "$schema_two_rc" \
    'schema-2 plan preserves enough audit data to validate a delayed handback'
plan=$plan_before_schema_two

boolean_schema_plan="$tmp/boolean-schema-plan.json"
jq '.schemaVersion = true' "$plan" >"$boolean_schema_plan"
plan_before_boolean_schema=$plan
plan=$boolean_schema_plan
boolean_schema_rc=0
validate "$repo" "$valid_handback" >"$tmp/boolean-schema.out" \
    2>"$tmp/boolean-schema.err" || boolean_schema_rc=$?
assert_eq '2' "$boolean_schema_rc" 'boolean true is not schemaVersion 1'
plan=$plan_before_boolean_schema

# Predictions may be paths or globs; the validator applies repository-relative
# glob semantics without expanding the worker's command text.
glob_plan="$tmp/glob-plan.json"
cat >"$glob_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 167, "predictedWriteSet": ["src/*.txt"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
plan_before_glob=$plan
plan=$glob_plan
glob_rc=0
validate "$repo" "$valid_handback" >"$tmp/glob.out" 2>"$tmp/glob.err" || glob_rc=$?
assert_eq '0' "$glob_rc" 'glob prediction accepts matching explicit operands'
plan=$plan_before_glob

# A trailing newline is legal path data, not the end of a regex match. The
# predicted write set must reject it instead of treating `$` as a true anchor.
newline_plan="$tmp/newline-plan.json"
cat >"$newline_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 167, "predictedWriteSet": ["src/trailing.txt"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
newline_path=$'src/trailing.txt\n'
printf 'newline\n' >"$repo/$newline_path"
newline_handback="$tmp/newline.handback"
printf '"%s" --message '\''feat(skills): reject newline path'\'' --trailer '\''Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>'\'' -- "%s"\n' \
    "$helper" "$newline_path" >"$newline_handback"
plan_before_newline=$plan
plan=$newline_plan
newline_rc=0
validate "$repo" "$newline_handback" >"$tmp/newline.out" 2>"$tmp/newline.err" || newline_rc=$?
assert_eq '1' "$newline_rc" 'trailing-newline path is outside the predicted write set'
assert_contains "$(cat -- "$tmp/newline.err")" 'outside predicted write set' \
    'trailing-newline refusal names the pinned write set'
plan=$plan_before_newline

# The plan is mandatory: a caller cannot silently fall back to the pre-pin
# validator that accepted any changed operand.
legacy_rc=0
"$script" --worktree "$repo" --handback-file "$valid_handback" --issue 167 \
    >"$tmp/legacy.out" 2>"$tmp/legacy.err" || legacy_rc=$?
assert_eq '1' "$legacy_rc" 'handback without a dispatch plan is rejected'
assert_contains "$(cat -- "$tmp/legacy.err")" 'dispatch-plan' \
    'missing dispatch plan is named in the usage refusal'

# An explicit operand outside the pinned prediction cannot be silently
# accepted, even though it is a real changed file in the worktree.
printf 'late overlap\n' >"$repo/src/late-overlap.txt"
late_handback="$tmp/late-overlap.handback"
cat >"$late_handback" <<EOF
"$helper" --message 'feat(skills): late overlap' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/late-overlap.txt
EOF
late_rc=0
validate "$repo" "$late_handback" >"$tmp/late.out" 2>"$tmp/late.err" || late_rc=$?
assert_eq '1' "$late_rc" 'out-of-prediction operand is rejected without disposition'
assert_contains "$(cat -- "$tmp/late.err")" 'outside predicted write set' \
    'out-of-prediction refusal names the pinned write set'

# Each sanctioned late-overlap response is explicit in the plan and scoped to
# the operands it authorizes. The commit helper still receives only its normal
# argv after validation; disposition metadata never reaches execution.
for disposition in chain-conversion merge-down prediction-expansion; do
    cat >"$plan" <<EOF
{
  "schemaVersion": 1,
  "entries": [{
    "issue": 167,
    "predictedWriteSet": ["src/tracked.txt", "src/untracked.txt"],
    "writeSetDisposition": {
      "kind": "$disposition",
      "reason": "late-discovered overlap requires the recorded response",
      "paths": ["src/late-overlap.txt"]
    }
  }],
  "conflictMap": {
    "pairs": [],
    "revisions": [{"phase": "post-selection", "issues": [167], "paths": ["src/late-overlap.txt"], "reason": "record the late overlap response"}]
  }
}
EOF
    disposition_output="$tmp/$disposition.argv"
    disposition_rc=0
    validate "$repo" "$late_handback" >"$disposition_output" \
        2>"$tmp/$disposition.err" || disposition_rc=$?
    assert_eq '0' "$disposition_rc" "$disposition disposition accepts its scoped operand"
    assert_not_contains "$(tr '\0' '\n' <"$disposition_output")" 'writeSetDisposition' \
        "$disposition metadata is not passed to the commit helper"
done

# --- a revision must be bound to the disposition it authorizes -------------
# A non-empty revisions list proves only that SOME revision exists. Each fixture
# below carries a well-formed revision that has nothing to do with the operand
# being published: one recorded for a different issue, one covering different
# paths. Either previously satisfied the gate, letting a late-overlap operand
# ship with no conflict-map change of its own.
for unrelated in wrong-issue wrong-paths; do
    case $unrelated in
        wrong-issue) rev='{"phase": "post-selection", "issues": [164], "paths": ["src/late-overlap.txt"], "reason": "another issue entirely"}' ;;
        wrong-paths) rev='{"phase": "post-selection", "issues": [167], "paths": ["src/somewhere-else.txt"], "reason": "a different operand"}' ;;
    esac
    cat >"$plan" <<EOF
{
  "schemaVersion": 1,
  "entries": [{
    "issue": 167,
    "predictedWriteSet": ["src/tracked.txt", "src/untracked.txt"],
    "writeSetDisposition": {
      "kind": "merge-down",
      "reason": "late-discovered overlap requires the recorded response",
      "paths": ["src/late-overlap.txt"]
    }
  }],
  "conflictMap": {
    "pairs": [],
    "revisions": [$rev]
  }
}
EOF
    unrelated_rc=0
    validate "$repo" "$late_handback" >"$tmp/$unrelated.out" 2>"$tmp/$unrelated.err" || unrelated_rc=$?
    assert_eq '2' "$unrelated_rc" \
        "a $unrelated revision does not authorize this disposition"
    assert_contains "$(cat "$tmp/$unrelated.out" "$tmp/$unrelated.err")" 'covering its disposition paths' \
        "the $unrelated refusal names the missing binding"
done

# A disposition without a conflict-map revision is also unavailable: recording
# the response and the changed plan edge are one atomic audit decision.
cat >"$plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{
    "issue": 167,
    "predictedWriteSet": ["src/tracked.txt"],
    "writeSetDisposition": {
      "kind": "merge-down",
      "reason": "late overlap requires merge-down",
      "paths": ["src/late-overlap.txt"]
    }
  }],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
missing_revision_rc=0
validate "$repo" "$late_handback" >"$tmp/missing-revision.out" \
    2>"$tmp/missing-revision.err" || missing_revision_rc=$?
assert_eq '2' "$missing_revision_rc" 'disposition without a revision is unavailable evidence'
assert_contains "$(cat -- "$tmp/missing-revision.err")" 'conflict-map revision' \
    'missing conflict-map revision is named'

# A disposition without an auditable reason is unavailable evidence, not an
# implicit approval.
cat >"$plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{
    "issue": 167,
    "predictedWriteSet": ["src/tracked.txt"],
    "writeSetDisposition": {"kind": "merge-down", "paths": ["src/late-overlap.txt"]}
  }],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
bad_plan_rc=0
validate "$repo" "$late_handback" >"$tmp/bad-plan.out" 2>"$tmp/bad-plan.err" || bad_plan_rc=$?
assert_eq '2' "$bad_plan_rc" 'disposition without a reason is unavailable evidence'
assert_contains "$(cat -- "$tmp/bad-plan.err")" 'needs a reason' \
    'invalid disposition evidence names the missing reason'

# Restore a normal plan for the remaining legacy handback boundary checks.
cat >"$plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{
    "issue": 167,
    "predictedWriteSet": ["src/tracked.txt", "src/untracked.txt"]
  }],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF

expect_invalid() {
    local name=$1 contents=$2
    local handback="$tmp/$name.handback" marker="$tmp/$name.marker" rc=0
    printf '%s\n' "$contents" >"$handback"
    validate "$repo" "$handback" >"$tmp/$name.out" 2>"$tmp/$name.err" || rc=$?
    assert_eq '1' "$rc" "$name is invalid"
    assert_not_contains "$(cat -- "$tmp/$name.err")" 'Traceback' "$name has no Python traceback"
    assert_eq 'absent' "$([[ -e $marker ]] && printf present || printf absent)" \
        "$name did not execute shell syntax"
}

expect_invalid_message() {
    local name=$1 contents=$2 expected=$3
    local handback="$tmp/$name.handback" rc=0
    printf '%s\n' "$contents" >"$handback"
    validate "$repo" "$handback" >"$tmp/$name.out" 2>"$tmp/$name.err" || rc=$?
    assert_eq '1' "$rc" "$name is invalid"
    assert_contains "$(cat -- "$tmp/$name.err")" "$expected" \
        "$name names the actionable diagnostic"
}

empty_handback="$tmp/empty.handback"
: >"$empty_handback"
empty_rc=0
validate "$repo" "$empty_handback" >"$tmp/empty.out" 2>"$tmp/empty.err" || empty_rc=$?
assert_eq '1' "$empty_rc" 'empty handback is invalid'
assert_contains "$(cat -- "$tmp/empty.err")" \
    'handback argv is empty or not parseable as a command; materialize the exact command into the handback file' \
    'empty handback names the materialization remedy'

expect_invalid_message unparseable "'unterminated" \
    'handback argv is empty or not parseable as a command; materialize the exact command into the handback file'

expect_invalid bad-trailer \
    "\"$helper\" --message 'feat(skills): bad trailer' --trailer 'Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt"
expect_invalid wrong-model \
    "\"$helper\" --message 'feat(skills): wrong model' --trailer 'Co-Authored-By: Codex gpt-5.6-terra <noreply@openai.com>' -- src/tracked.txt"
expect_invalid bad-subject \
    "\"$helper\" --message 'not conventional' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt"
expect_invalid shell-syntax \
    "\"$helper\" --message 'feat(skills): reject syntax' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt && touch $tmp/shell-syntax.marker"
expect_invalid unchanged-file \
    "\"$helper\" --message 'feat(skills): unchanged' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- .agent/config.env"
expect_invalid protected-file \
    "\"$helper\" --message 'feat(skills): protected' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- secrets/config.txt"
expect_invalid_message wrong-helper \
    "\"$root/agentkit/skills/.shared/scripts/agent-run.sh\" --message 'feat(skills): wrong helper' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt" \
    'expected worktree-commit.sh as the only helper'

attacker_helper_dir="$tmp/attacker/bin"
attacker_helper="$attacker_helper_dir/worktree-commit.sh"
mkdir -p "$attacker_helper_dir"
printf '#!/usr/bin/env bash\n' >"$attacker_helper"
chmod +x "$attacker_helper"
expect_invalid attacker-helper \
    "\"$attacker_helper\" --message 'feat(skills): attacker helper' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt"

outside="$tmp/outside.txt"
printf 'outside\n' >"$outside"
expect_invalid outside-path \
    "\"$helper\" --message 'feat(skills): outside' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- ../outside.txt"

missing_rc=0
validate "$tmp/missing" "$valid_handback" >"$tmp/missing.out" 2>"$tmp/missing.err" || missing_rc=$?
assert_eq '2' "$missing_rc" 'missing worktree reports unavailable evidence'

# argv[0] is emitted as the canonical shipped helper, never as the spelling the
# worker submitted. Resolving the submitted path only proves what it pointed at
# during validation; a symlink retargeted before root executes would otherwise
# hand root a worker-controlled program.
helper_symlink="$tmp/attacker/worktree-commit.sh"
ln -sf "$helper" "$helper_symlink"
symlink_handback="$tmp/symlink.handback"
cat >"$symlink_handback" <<EOF
"$helper_symlink" --message 'feat(skills): symlink helper' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt
EOF
symlink_output="$tmp/symlink.argv"
symlink_rc=0
validate "$repo" "$symlink_handback" >"$symlink_output" 2>"$tmp/symlink.err" || symlink_rc=$?
assert_eq '0' "$symlink_rc" 'a symlink that resolves to the shipped helper is accepted'
assert_eq "$helper" "$(tr '\0' '\n' <"$symlink_output" | head -1)" \
    'the emitted argv names the canonical helper, not the submitted symlink'

# worktree-commit.sh commits the whole index, and its own staged-protected guard
# only fires during an active merge. A path staged but left out of the operands
# would otherwise be published without ever reaching the protected check.
git -C "$repo" add -- secrets/config.txt
staged_protected_rc=0
validate "$repo" "$valid_handback" \
    >"$tmp/staged-protected.out" 2>"$tmp/staged-protected.err" || staged_protected_rc=$?
assert_eq '1' "$staged_protected_rc" 'a staged protected path is refused even when undeclared'
assert_contains "$(cat -- "$tmp/staged-protected.err")" 'secrets/config.txt' \
    'the refusal names the staged protected path'
git -C "$repo" reset -q -- secrets/config.txt

printf 'plain\n' >"$repo/src/staged-only.txt"
git -C "$repo" add -- src/staged-only.txt
staged_undeclared_rc=0
validate "$repo" "$valid_handback" \
    >"$tmp/staged-undeclared.out" 2>"$tmp/staged-undeclared.err" || staged_undeclared_rc=$?
assert_eq '1' "$staged_undeclared_rc" 'a staged but undeclared path is refused'
assert_contains "$(cat -- "$tmp/staged-undeclared.err")" 'staged path is not declared' \
    'the refusal names the undeclared staged path'
git -C "$repo" reset -q -- src/staged-only.txt
rm -f -- "$repo/src/staged-only.txt"

printf 'AGENT_WORKER_MODEL= \t  \nAGENT_PROTECTED_PATHS=secrets/\n' >"$repo/.agent/config.env"
blank_model_rc=0
validate "$repo" "$valid_handback" >"$tmp/blank-model.out" 2>"$tmp/blank-model.err" || blank_model_rc=$?
assert_eq '2' "$blank_model_rc" 'blank worker model reports unavailable evidence'
assert_not_contains "$(cat -- "$tmp/blank-model.err")" 'Traceback' \
    'blank worker model has no Python traceback'

# --help/-h must be classified as a usage request, not an invalid handback:
# the wrapper intercepts them before exec'ing into the Python argv parser.
usage_text='usage: validate-handback.sh --worktree PATH --handback-file FILE --issue N --dispatch-plan FILE'
long_help_rc=0
"$script" --help >"$tmp/long-help.out" 2>"$tmp/long-help.err" || long_help_rc=$?
assert_eq '0' "$long_help_rc" '--help exits 0'
assert_eq "$usage_text" "$(cat -- "$tmp/long-help.out")" '--help prints the usage line on stdout'
assert_eq '' "$(cat -- "$tmp/long-help.err")" '--help writes nothing to stderr'

short_help_rc=0
"$script" -h >"$tmp/short-help.out" 2>"$tmp/short-help.err" || short_help_rc=$?
assert_eq '0' "$short_help_rc" '-h exits 0'
assert_eq "$usage_text" "$(cat -- "$tmp/short-help.out")" '-h prints the usage line on stdout'
assert_eq '' "$(cat -- "$tmp/short-help.err")" '-h writes nothing to stderr'

# All other invocations remain byte-identical: an unrelated unknown option is
# still an invalid handback, never mistaken for a usage request.
unknown_rc=0
"$script" --bogus >"$tmp/unknown.out" 2>"$tmp/unknown.err" || unknown_rc=$?
assert_eq '1' "$unknown_rc" 'an unrelated unknown option is still rejected'
assert_contains "$(cat -- "$tmp/unknown.err")" 'unknown option: --bogus' \
    'the unknown-option refusal is unchanged'

finish
