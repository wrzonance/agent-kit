#!/usr/bin/env bash
# Suite: executable skill recipes cannot teach hook/guard bypasses.
# shellcheck disable=SC2016  # $agentkit and Markdown snippets are literal fixtures.
set -uo pipefail

TEST_NAME='recipe-safety'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/bypass.md"
no_verify='--no-''verify'
printf '%s\n' \
    'The prose may discuss the hook-suppression flag, core.hooksPath, aliases, and config.' \
    '```bash' \
    "git commit $no_verify -m \"skip\"" \
    'git -c core.hooksPath=/dev/null commit -m "skip"' \
    "git config alias.commit \"commit $no_verify\"" \
    "printf \"%s\\n\" \"git commit $no_verify\"" \
    '```' > "$fixture"

findings=$(scan_skill_recipes "$fixture")
assert_eq '1' "$(grep -c 'hook bypass' <<< "$findings" || true)" \
    'recipe scan rejects the hook-suppression flag'
assert_eq '1' "$(grep -c 'hook execution config bypass' <<< "$findings" || true)" \
    'recipe scan rejects core.hooksPath execution changes'
assert_eq '1' "$(grep -c 'git alias bypass' <<< "$findings" || true)" \
    'recipe scan rejects git alias execution changes'
assert_not_contains "$findings" 'printf' \
    'recipe scan ignores bypass text in non-executable commands'

review_skill="$root/agentkit/skills/review-remote-pr/SKILL.md"
guard_lib="$root/agentkit/hooks/lib/guard-lib.sh"
onboard_skill="$root/agentkit/skills/onboard-repo/SKILL.md"
parallel_skill="$root/agentkit/skills/parallel-issues/SKILL.md"
green_skill="$root/agentkit/skills/pr-to-green/SKILL.md"
shell_policy="$root/agentkit/skills/.shared/shell-portability.md"
provider_rules="$root/agentkit/skills/review-remote-pr/references/provider-rules.md"
reference_manifest="$root/agentkit/skills/references.md"
hooks_path='core.''hooksPath'
assert_contains "$(cat "$guard_lib")" 'core\.hooksPath' \
    'the guard library names hook execution configuration as prohibited'
assert_contains "$(cat "$guard_lib")" "$no_verify" \
    'the guard library names hook suppression as prohibited'
assert_contains "$(cat "$review_skill")" "$hooks_path" \
    'review guidance retains the hook execution configuration phrase'
assert_contains "$(cat "$review_skill")" 'merge-inherited paths parked/handed off' \
    'review guidance reports inherited-path churn'
assert_contains "$(cat "$onboard_skill")" 'named-base affordance' \
    'onboarding guidance describes the sanctioned inherited-path handoff'

# Multi-line recipes run in the harness shell, which is not necessarily Bash.
# Keep the portability contract in one shared reference and require every
# recipe-bearing skill to route readers there before they execute a fence.
assert_contains "$(cat "$reference_manifest")" \
    '`$agentkit/.shared/shell-portability.md`' \
    'the reference manifest exposes the shared shell-portability policy'
for skill in "$onboard_skill" "$parallel_skill" "$green_skill" "$review_skill"; do
    assert_contains "$(cat "$skill")" '$agentkit/.shared/shell-portability.md' \
        "$(basename "$(dirname "$skill")") points runnable recipes at the shared shell policy"
done
assert_contains "$(cat "$onboard_skill")" 'bootstrap fence through explicit `bash -c`' \
    'onboarding explicitly Bash-wraps the resolver needed to discover the policy'
assert_contains "$(cat "$onboard_skill")" 'Once it resolves `$agentkit`, read' \
    'onboarding reads the shared policy only after its path is available'

shell_policy_text=$(cat "$shell_policy" 2>/dev/null || true)
for required in mapfile readarray BASH_REMATCH SH_WORD_SPLIT 'array index' \
    'python3 -c' 'pipe and heredoc' 'bash -c' 'nested quoting'; do
    assert_contains "$shell_policy_text" "$required" \
        "the shared shell policy covers $required"
done
assert_contains "$shell_policy_text" 'producer \| python3' \
    'the pipe-plus-heredoc example escapes its GFM table delimiter'
assert_contains "$(cat "$provider_rules")" \
    '$agentkit/.shared/shell-portability.md' \
    'provider pitfalls route shell hazards to the shared policy'
assert_not_contains "$(cat "$provider_rules")" '`python3 -c "..."` fails' \
    'provider rules do not duplicate the moved multi-line Python hazard'
assert_not_contains "$(cat "$provider_rules")" '`cmd | python3`' \
    'provider rules do not duplicate the moved pipe-plus-heredoc hazard'

# Exercise the actual lint entry point: a fence label alone cannot select Bash.
lint="$here/lint-markdown-blocks.sh"
mkdir -p "$tmp/skills/example"
for recipe in 'mapfile -t items' 'readarray -t items' 'read -a items' \
    'IFS=, read -ra items' 'read -r -a items' \
    'read -d "" -ra items' \
    'true; mapfile -t items'; do
    printf '```bash\n%s\n```\n' "$recipe" > "$tmp/skills/example/SKILL.md"
    output=$("$lint" "$tmp/skills" 2>&1)
    assert_contains "$output" 'Bash-only builtin outside explicit Bash boundary' \
        "lint rejects unwrapped $recipe"
done

cat > "$tmp/skills/example/SKILL.md" <<'MARKDOWN'
```bash
bash -c "$(cat <<'FIXTURE_RECIPE'
mapfile -t items
printf '%s\n' "${items[@]}"
FIXTURE_RECIPE
)"
```
MARKDOWN
assert_rc 0 'lint accepts explicit Bash boundary with alternate delimiter' -- \
    "$lint" "$tmp/skills"

cat > "$tmp/skills/example/SKILL.md" <<'MARKDOWN'
```bash
captured=$(bash -c "$(cat <<'FIXTURE_RECIPE'
printf '%s\n' $unquoted
FIXTURE_RECIPE
)" _ 'literal input') || exit 1
printf '%s\n' "$captured"
```
MARKDOWN
output=$("$lint" "$tmp/skills" 2>&1)
assert_contains "$output" 'SC2086' 'lint still ShellChecks the wrapped recipe body'

cat > "$tmp/skills/example/SKILL.md" <<'MARKDOWN'
```bash
bash -c "$(cat <<'FIXTURE_RECIPE'
true
FIXTURE_RECIPE
)" _ 'literal input'
mapfile -t outside
```
MARKDOWN
output=$("$lint" "$tmp/skills" 2>&1)
assert_contains "$output" 'Bash-only builtin outside explicit Bash boundary' \
    'lint still checks commands after a parameterized Bash boundary'

cat > "$tmp/skills/example/SKILL.md" <<'MARKDOWN'
```bash
# mapfile -t items is a deliberately negative example.
printf '%s\n' 'readarray -t items'
printf '%s\n' 'bad; mapfile -t items'
printf '%s\n' "bad; read -ra items"
true # bad; readarray -t items
```
MARKDOWN
assert_rc 0 'lint leaves comment and quoted negative examples alone' -- \
    "$lint" "$tmp/skills"
output=$("$lint" "$root/agentkit/skills" 2>&1)
assert_not_contains "$output" 'Bash-only builtin outside explicit Bash boundary' \
    'all shipped recipes put Bash-only builtins behind a Bash boundary'

# Run complete shipped fences in ordinary parent shells. Nothing here exports
# recipe inputs or removes a wrapper to make a failing boundary pass.
extract_recipe() {
    awk -v needle="$2" '
        /^```bash$/ { active=1; body=""; next }
        /^```$/ { if (active && index(body, needle)) { printf "%s", body; exit }; active=0 }
        active { body=body $0 "\n" }
    ' "$1"
}
triage="$root/agentkit/skills/parallel-issues/references/triage-and-selection.md"
bulk_recipe=$(extract_recipe "$triage" 'report_batch_failure()')
needs_recipe=$(extract_recipe "$triage" 'mapfile -t needs_lines')
handback_recipe=$(extract_recipe "$parallel_skill" '--scratch-label handback')
final_handoff_recipe=$(extract_recipe "$parallel_skill" 'final-handoff summary')
for recipe in "$bulk_recipe" "$needs_recipe" "$handback_recipe"; do
    assert_contains "$recipe" 'bash -c' 'runtime regression extracted a complete Bash fence'
done
assert_contains "$final_handoff_recipe" 'run-state.sh" summary' \
    'runtime regression extracts the executable final-handoff summary fence'
fixture_root="$tmp/recipe inputs"
mkdir -p "$fixture_root/kit/.shared/scripts" "$fixture_root/kit/review-remote-pr/scripts" "$fixture_root/worktree" "$fixture_root/root-repo/.agent"
cp "$root/agentkit/skills/review-remote-pr/scripts/run-dir.sh" "$fixture_root/kit/review-remote-pr/scripts/run-dir.sh"
mkdir -p "$fixture_root/kit/.shared/scripts/lib"
cp "$root/agentkit/skills/.shared/scripts/lib/private-dir.sh" "$fixture_root/kit/.shared/scripts/lib/private-dir.sh"
cat > "$fixture_root/ledger-helper" <<'SCRIPT'
#!/usr/bin/env bash
operation=$1; shift
while (($#)); do
    case $1 in --ledger) ledger=$2; shift 2 ;; *) shift ;; esac
done
case $operation in
    pending) [[ $(cat "$ledger") != pending ]] || printf 'item-17\n' ;;
    record) printf applied > "$ledger" ;;
    status) printf '{"applied":0,"remaining":1}\n' ;;
esac
SCRIPT
cat > "$fixture_root/kit/.shared/scripts/validate-handback.sh" <<'SCRIPT'
#!/usr/bin/env bash
[[ -f $4 && -f $8 && $6 == 723 ]] || exit 2
printf '%s\0' "$2/commit-helper" "$6" "$4" "$8"
SCRIPT
cat > "$fixture_root/kit/.shared/scripts/run-state.sh" <<'SCRIPT'
#!/usr/bin/env bash
[[ $1 == summary && $2 == --run-id && $3 == run && $4 == --repo-root &&
   $5 == "$EXPECTED_REPOSITORY_ROOT" && $6 == --reports-dir &&
   $7 == "$EXPECTED_DISPATCH_PLAN.verification-reports" ]] || exit 2
printf 'fixture-summary\n'
SCRIPT
cat > "$fixture_root/worktree/commit-helper" <<'SCRIPT'
#!/usr/bin/env bash
printf 'commit=%s:%s\n' "$PWD" "$*"
SCRIPT
chmod +x "$fixture_root/ledger-helper" "$fixture_root/kit/.shared/scripts/validate-handback.sh" \
    "$fixture_root/kit/.shared/scripts/run-state.sh" \
    "$fixture_root/worktree/commit-helper"
mkdir -p "$fixture_root/worktree/.agent/cache"
printf 'preserve worker target' >"$fixture_root/worker-target"
ln -s "$fixture_root/worker-target" "$fixture_root/worktree/.agent/cache/parallel-issues-handback.argv"
bulk_inputs='apply_ledger=$1; ledger=$2; plan=$3; agentkit=$4; repository_root=$5; RUN_ID=run; bulk_dir=$5'
bulk_callback='perform_rest_mutation() {
    [ -f "$plan" ] && [ -f "$ledger" ] && [ "$RUN_ID" = run ] || return 1
    printf "{\"number\":17,\"html_url\":\"https://example.test/issues/17\"}\n"
}'
completed='printf "%s\n" parent-completed'
for parent_shell in bash zsh; do
    if ! command -v "$parent_shell" >/dev/null; then
        printf 'SKIP: %s whole-recipe runtime checks (shell unavailable)\n' "$parent_shell"
        continue
    fi
    printf pending > "$fixture_root/ledger"
    : > "$fixture_root/plan"
    output=$("$parent_shell" -f -c "$bulk_inputs"$'\n'"$bulk_callback"$'\n'"$bulk_recipe"$'\n'"$completed" \
        _ "$fixture_root/ledger-helper" "$fixture_root/ledger" "$fixture_root/plan" "$fixture_root/kit" "$fixture_root" 2>&1)
    assert_eq 0 "$?" "$parent_shell bulk fence receives its callback and ordinary inputs"
    assert_eq applied "$(cat "$fixture_root/ledger")" "$parent_shell bulk fence records the mutation"
    printf pending > "$fixture_root/ledger"
    output=$("$parent_shell" -f -c "$bulk_inputs"$'\n''perform_rest_mutation() { return 1; }'$'\n'"$bulk_recipe"$'\n'"$completed" \
        _ "$fixture_root/ledger-helper" "$fixture_root/ledger" "$fixture_root/plan" "$fixture_root/kit" "$fixture_root" 2>&1)
    assert_eq 1 "$?" "$parent_shell bulk failure stops the parent"
    assert_contains "$output" 'ledger evidence (applied/remaining)' "$parent_shell bulk failure retains ledger evidence"
    assert_not_contains "$output" parent-completed "$parent_shell bulk failure cannot continue"

    printf '%s\n' '{"entries":[{"issue":723,"predictedWriteSet":[]}],"conflictMap":{"revisions":[]}}' > "$fixture_root/plan"
    printf '%s\n' 'needs-paths: src/new.py' > "$fixture_root/report"
    needs_inputs='raw_report=$1; dispatch_plan=$2; issue_number=$3; agentkit=$4; agentkit_provenance=$5; repository_root=$6'
    output=$("$parent_shell" -f -c "$needs_inputs"$'\n'"$needs_recipe"$'\n'"$completed" \
        _ "$fixture_root/report" "$fixture_root/plan" 723 "$fixture_root/kit" ok "$fixture_root/root-repo" 2>&1)
    assert_eq 0 "$?" "$parent_shell needs-paths fence accepts ordinary inputs"
    assert_eq src/new.py "$(jq -r '.entries[0].predictedWriteSet[0]' "$fixture_root/plan")" \
        "$parent_shell needs-paths fence updates the plan"
    printf '%s\n' 'needs-paths: ../escape' > "$fixture_root/report"
    output=$("$parent_shell" -f -c "$needs_inputs"$'\n'"$needs_recipe"$'\n'"$completed" \
        _ "$fixture_root/report" "$fixture_root/plan" 723 "$fixture_root/kit" ok "$fixture_root/root-repo" 2>&1)
    assert_eq 1 "$?" "$parent_shell needs-paths refusal stops the parent"
    assert_not_contains "$output" parent-completed "$parent_shell needs-paths refusal cannot continue"

    handback_inputs='agentkit=$1; agentkit_provenance=ok; dispatch_plan=$2; worktree=$3; raw_handback=$4; issue_number=723; repository_root=$5'
    output=$("$parent_shell" -f -c "$handback_inputs"$'\n'"$handback_recipe"$'\n'"$completed" \
        _ "$fixture_root/kit" "$fixture_root/plan" "$fixture_root/worktree" "$fixture_root/report" "$fixture_root/root-repo" 2>&1)
    assert_eq 0 "$?" "$parent_shell handback fence receives ordinary inputs"
    assert_contains "$output" "commit=$fixture_root/worktree:--include-staged 723" "$parent_shell handback preserves cwd and argv"
    assert_eq 'preserve worker target' "$(<"$fixture_root/worker-target")" \
        "$parent_shell handback never follows worker-controlled scratch symlinks"
    output=$("$parent_shell" -f -c "$handback_inputs"$'\n'"$handback_recipe"$'\n'"$completed" \
        _ "$fixture_root/kit" "$fixture_root/plan" "$fixture_root/worktree" "$fixture_root/missing" "$fixture_root/root-repo" 2>&1)
    assert_eq 1 "$?" "$parent_shell handback refusal stops the parent"
    assert_not_contains "$output" parent-completed "$parent_shell handback refusal cannot continue"

    : > "$fixture_root/dispatch-plan"
    handoff_inputs='agentkit=$1; dispatch_plan=$2; RUN_ID=run; repository_root=$3; export EXPECTED_DISPATCH_PLAN=$2 EXPECTED_REPOSITORY_ROOT=$3'
    output=$("$parent_shell" -f -c "$handoff_inputs"$'\n'"$final_handoff_recipe"$'\n'"$completed" \
        _ "$fixture_root/kit" "$fixture_root/dispatch-plan" "$fixture_root/root-repo" 2>&1)
    assert_eq 0 "$?" "$parent_shell final handoff accepts a valid dispatch plan"
    assert_contains "$output" fixture-summary "$parent_shell final handoff executes the computed summary"
    assert_contains "$output" parent-completed "$parent_shell final handoff returns after successful summary"
    output=$("$parent_shell" -f -c "$handoff_inputs"$'\n'"$final_handoff_recipe"$'\n'"$completed" \
        _ "$fixture_root/kit" "$fixture_root/missing-plan" "$fixture_root/root-repo" 2>&1)
    assert_eq 1 "$?" "$parent_shell final handoff refuses a missing dispatch plan"
    assert_not_contains "$output" parent-completed "$parent_shell missing-plan refusal cannot continue"

done

markdown_mktemp=$(rg -n 'mktemp' "$root/agentkit/skills" --glob '*.md' || true)
assert_eq '' "$markdown_mktemp" 'skill prose contains no executable mktemp recipes'

finish
