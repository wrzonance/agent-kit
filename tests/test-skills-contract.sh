#!/usr/bin/env bash
# Suite: the preflight skills-path contract and its single fallback resolver.
# shellcheck disable=SC2016  # resolver text is intentionally literal
set -uo pipefail

TEST_NAME='skills-contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skills="$root/agentkit/skills"
security_posture="$root/docs/security-posture.md"
preflight="$skills/.shared/scripts/agent-preflight.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# --- standing security posture contract ------------------------------------
# This is intentionally structural: the document's prose and evidence links
# remain reviewable, while deletion or removal of a rationale class fails the
# repository contract immediately.
assert_eq 'yes' "$([[ -f $security_posture && ! -L $security_posture ]] && printf yes || printf no)" \
    'the standing security-posture document exists as a regular file'
for heading in \
    '## Autonomy flags are per-invocation operator grants' \
    '## .agent/config.env is a secrets-free facts file' \
    '## The command trust gate is defense-in-depth, not a human-only guarantee' \
    '## Untrusted content is fenced and never shell-expanded'; do
    heading_count=$(grep -Fxc -- "$heading" "$security_posture" 2>/dev/null || printf '0')
    assert_eq '1' "$heading_count" "security-posture keeps heading: $heading"
done

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
out=$("$preflight" --worktree "$repo" --no-write 2>/dev/null)
skills_line=$(grep '^skills=' <<< "$out")
assert_eq '1' "$(grep -c '^skills=' <<< "$out")" \
    'preflight emits exactly one skills contract line'
assert_eq "$skills" "${skills_line#skills= path=}" \
    'the contract path is the installed skills tree'
path_is_absolute=no
if [[ ${skills_line#skills= path=} == /* ]]; then
    path_is_absolute=yes
fi
assert_eq 'yes' "$path_is_absolute" \
    'the contract path is absolute'

packaged="$tmp/plugin/agentkit/skills"
mkdir -p "$packaged/.shared/scripts"
cp -- "$preflight" "$packaged/.shared/scripts/agent-preflight.sh"
chmod +x "$packaged/.shared/scripts/agent-preflight.sh"
packaged_out=$("$packaged/.shared/scripts/agent-preflight.sh" --worktree "$repo" --no-write 2>/dev/null)
assert_contains "$packaged_out" "skills= path=$packaged" \
    'a packaged preflight reports its packaged skills tree'

resolver_matches=$(find "$skills" -type f -name SKILL.md -exec grep -Hn 'agentkit=\$(find ' {} + || true)
resolver_lines=$(printf '%s\n' "$resolver_matches" | grep -c . || true)
assert_eq '1' "$resolver_lines" \
    'the skill tree keeps exactly one literal fallback resolver'

for skill in "$skills"/*/SKILL.md; do
    name=$(basename "$(dirname "$skill")")
    assert_contains "$(<"$skill")" 'skills= path=' \
        "$name documents the contract field"
    # $agentkit IS the skills tree root -- agent-preflight.sh publishes it as
    # `skills= path=/abs/skills-tree`. So `$agentkit/skills/...` re-appends the
    # directory and resolves to .../skills/skills/..., which never exists. The
    # helpers themselves are covered by their own suites, but those invoke them
    # by repository path; nothing else exercises the `$agentkit` form the skill
    # bodies actually instruct agents to use, so a broken snippet reaches the
    # field instead of the suite. Any occurrence is a defect by definition.
    assert_not_contains "$(<"$skill")" '$agentkit/skills/' \
        "$name does not re-append skills/ to the skills tree root"
    if [[ $name == onboard-repo ]]; then
        resolver_count=$(grep -c 'agentkit=\$(find ' "$skill" || true)
        assert_eq '1' "$resolver_count" \
            "$name owns the sole fallback resolver"
    else
        resolver_count=$(grep -c 'agentkit=\$(find ' "$skill" || true)
        assert_eq '0' "$resolver_count" \
            "$name does not repeat the fallback resolver"
    fi
done

onboard="$skills/onboard-repo/SKILL.md"
onboard_text=$(<"$onboard")
worker_tier_text=$(<"$skills/.shared/schema/config.env.example")
spawn_contract="$skills/.shared/spawn-contract.md"
spawn_contract_text=$(<"$spawn_contract")
parallel_dispatch="$skills/parallel-issues/SKILL.md"
parallel_dispatch_text=$(<"$parallel_dispatch")
for dispatch_text_name in spawn_contract parallel_dispatch; do
    if [[ $dispatch_text_name == spawn_contract ]]; then
        dispatch_text=$spawn_contract_text
    else
        dispatch_text=$parallel_dispatch_text
    fi
    assert_contains "$dispatch_text" 'must not implement when a real worker can be dispatched' \
        "$dispatch_text_name forbids orchestrator-side implementation when spawning is available"
    assert_contains "$dispatch_text" '`worker=self` is only the documented spawn-unavailable degraded path' \
        "$dispatch_text_name limits worker=self to the degraded path"
    assert_contains "$dispatch_text" 'AGENT_WORKER_MODEL' \
        "$dispatch_text_name names the resolved worker model declaration"
    assert_contains "$dispatch_text" 'AGENT_WORKER_EFFORT' \
        "$dispatch_text_name names the resolved worker effort declaration"
    assert_contains "$dispatch_text" 'AGENT_WORKER_MODEL_FALLBACK' \
        "$dispatch_text_name names the resolved worker model fallback declaration"
done
assert_contains "$spawn_contract_text" 'AGENT_WORKER_MODEL' \
    'spawn contract reads the configured worker model key'
assert_contains "$spawn_contract_text" 'AGENT_WORKER_MODEL_FALLBACK' \
    'spawn contract reads the configured worker fallback key'
assert_contains "$spawn_contract_text" 'AGENT_WORKER_EFFORT' \
    'spawn contract reads the configured worker effort key'
assert_contains "$spawn_contract_text" 'gpt-5.6-luna' \
    'spawn contract documents the preserved preferred default'
assert_contains "$spawn_contract_text" 'gpt-5.6-terra' \
    'spawn contract documents the preserved fallback default'
assert_contains "$spawn_contract_text" 'using built-in default' \
    'spawn contract explains invalid or empty config fallback'
assert_contains "$spawn_contract_text" '--get "$key") && [[ -n $value ]]; then' \
    'spawn contract treats empty resolver output as absent'
resolver_guard_line=$(grep -m1 -n '^\[ -d "${agentkit:-}/.shared/scripts"' "$spawn_contract" | cut -d: -f1)
worker_config_function_line=$(grep -m1 -n '^worker_config_value() {' "$spawn_contract" | cut -d: -f1)
if [[ -n $resolver_guard_line && -n $worker_config_function_line &&
    $resolver_guard_line -lt $worker_config_function_line ]]; then
    printf '%s\n' 'ok - spawn contract validates the resolver before command substitution'
else
    printf '%s\n' 'not ok - spawn contract validates the resolver before command substitution' >&2
    exit 1
fi
assert_contains "$spawn_contract_text" 'explicit user authorization' \
    'spawn contract keeps unsupported-model authorization explicit'
assert_contains "$spawn_contract_text" 'reasoning_effort: "$worker_effort"' \
    'spawn shape carries the resolved effort'
assert_not_contains "$spawn_contract_text" 'reasoning_effort: "high"' \
    'spawn shape does not hardcode high effort'
assert_contains "$spawn_contract_text" 'model: "$selected_worker_model"' \
    'spawn shape carries the selected model'
assert_contains "$spawn_contract_text" 'set `selected_worker_model` to `worker_model`' \
    'spawn contract establishes selected preferred model'
assert_contains "$spawn_contract_text" '"$agentkit/.shared/scripts/repo-config.sh"' \
    'spawn contract resolves config through the validated agentkit root'
assert_not_contains "$spawn_contract_text" '"$shared/repo-config.sh"' \
    'spawn contract does not rely on an undefined shared variable'
assert_contains "$spawn_contract_text" 'sanctioned no-extra-authorization model set is exactly' \
    'spawn contract defines the sanctioned model gate'
assert_contains "$spawn_contract_text" 'Validate both resolved `worker_model` and `worker_model_fallback`' \
    'spawn contract validates preferred and fallback models'
assert_contains "$spawn_contract_text" 'Any other syntactically safe configured preferred or fallback model' \
    'spawn contract gates every unsupported configured model'
assert_contains "$onboard_text" 'AGENTS.md' \
    'onboarding reviews the repository instruction files'
assert_contains "$onboard_text" 'CLAUDE.md' \
    'onboarding includes the other common instruction file'
assert_contains "$onboard_text" 'untrusted data' \
    'instruction-file content is treated as repository data'
assert_contains "$onboard_text" 'Conflicting' \
    'onboarding classifies conflicting guidance'
assert_contains "$onboard_text" 'Duplicated' \
    'onboarding classifies duplicated guidance'
assert_contains "$onboard_text" 'Repo-specific' \
    'onboarding preserves repository-specific guidance'
assert_contains "$onboard_text" 'discover equivalents' \
    'onboarding discovers equivalent instruction files beyond the examples'
assert_contains "$onboard_text" 'proposed diff' \
    'onboarding emits a proposed diff'
assert_contains "$onboard_text" 'must not delete, rewrite' \
    'onboarding prohibits deleting or rewriting instruction files'
assert_contains "$onboard_text" 'explicitly retained' \
    'onboarding retains repository-specific guidance'
assert_contains "$onboard_text" 'Do not do this by hand' \
    'onboarding warns against hand-rolling the Status-column mutation'
assert_contains "$onboard_text" 'singleSelectOptions' \
    'onboarding names the board-wiping mutation the warning is about'
assert_contains "$worker_tier_text" 'AGENT_WORKER_MODEL=gpt-5.6-luna' \
    'onboarding approval surfaces the preferred worker model default'
assert_contains "$worker_tier_text" 'AGENT_WORKER_MODEL_FALLBACK=gpt-5.6-terra' \
    'onboarding approval surfaces the fallback worker model default'
assert_contains "$worker_tier_text" 'AGENT_WORKER_EFFORT=high' \
    'onboarding approval surfaces the worker effort default'

assert_line_order() {
    local label=$1 first=$2 second=$3
    if [[ -n $first && -n $second && $first -lt $second ]]; then
        printf 'ok - %s\n' "$label"
    else
        printf 'not ok - %s\n' "$label" >&2
        exit 1
    fi
}

step_two_line=$(grep -m1 -n '^## Step 2 ' "$onboard" | cut -d: -f1)
review_line=$(grep -m1 -in 'review existing instructions' "$onboard" | cut -d: -f1)
write_line=$(grep -m1 -n '^"\$shared/bootstrap-repo\.sh"$' "$onboard" | cut -d: -f1)
audit_approval_line=$(grep -m1 -n 'explicitly approved onboarding pass' "$onboard" | cut -d: -f1)
write_approval_line=$(grep -m1 -n 'approved the proposed onboarding additions' "$onboard" | cut -d: -f1)
conflicting_line=$(grep -m1 -n '^- \*\*Conflicting\*\*' "$onboard" | cut -d: -f1)
duplicated_line=$(grep -m1 -n '^- \*\*Duplicated\*\*' "$onboard" | cut -d: -f1)
repo_specific_line=$(grep -m1 -n '^- \*\*Repo-specific\*\*' "$onboard" | cut -d: -f1)

assert_line_order 'instruction review precedes the config write section' \
    "$review_line" "$step_two_line"
assert_line_order 'approval-gated review precedes the non-dry-run bootstrap write' \
    "$review_line" "$write_line"
assert_line_order 'the config write section precedes the non-dry-run bootstrap write' \
    "$step_two_line" "$write_line"
assert_line_order 'the audit demands an explicitly approved pass before Step 2' \
    "$audit_approval_line" "$step_two_line"
assert_line_order 'user approval of the additions precedes the non-dry-run bootstrap write' \
    "$write_approval_line" "$write_line"
assert_line_order 'Conflicting is classified before Duplicated' \
    "$conflicting_line" "$duplicated_line"
assert_line_order 'Duplicated is classified before Repo-specific' \
    "$duplicated_line" "$repo_specific_line"

review_skill="$skills/review-remote-pr/SKILL.md"
parallel_skill="$skills/parallel-issues/SKILL.md"
review_refs=("$skills"/review-remote-pr/references/*.md)
parallel_refs=("$skills"/parallel-issues/references/*.md)
shared_refs=("$skills"/.shared/*.md)
gh_pr_state_script="$skills/review-remote-pr/scripts/gh-pr-state.sh"
prepare_issue_script="$skills/parallel-issues/scripts/prepare-issue-artifacts.sh"
review_setup_status_line=$(grep -m1 -n '^if ! setup_output=' "$review_skill" | cut -d: -f1)
review_setup_parse_line=$(grep -m1 -n '^PR_WORKTREE=' "$review_skill" | cut -d: -f1)
assert_line_order 'review helper status is checked before parsing its worktree output' \
    "$review_setup_status_line" "$review_setup_parse_line"
assert_contains "$(<"$review_skill")" 'if ! setup_output=' \
    'review helper setup captures failure before output parsing'
assert_contains "$(<"$review_skill")" 'jq is not installed; evidence unavailable' \
    'review recipes name jq parser failures as unavailable evidence'
# The former inline python3 thread-classification recipe was absorbed into
# gh-pr-state.sh (bash + jq, no python3 -- see the "no python3" doc line in
# SKILL.md itself); its own jq guard is the evidence-unavailable failure mode now.
assert_contains "$(<"$gh_pr_state_script")" 'jq not found on PATH; evidence unavailable' \
    'the absorbed classification recipe names jq parser failures as unavailable evidence'
assert_contains "$(<"$parallel_skill")" 'jq is not installed; evidence unavailable' \
    'parallel recipes name jq parser failures as unavailable evidence'
assert_contains "$(<"$prepare_issue_script")" 'issue_payload_file="$agent_dir/fetched-issue.json"' \
    'parallel fetch persists raw issue bytes before parsing'
# The wait-contract rule sentences are single-sourced in .shared/wait-discipline.md;
# review-remote-pr's body keeps only a pointer to it (see Step 2's "Wait contract"
# subsection), so the pinned wait-rule content is asserted against the shared file.
shared_wait_discipline="$skills/.shared/wait-discipline.md"
review_wait_contract=$(<"$shared_wait_discipline")
assert_contains "$(<"$review_skill")" '.shared/wait-discipline.md' \
    'review skill points at the shared wait-discipline contract'
assert_contains "$review_wait_contract" 'A wait must never spend model turns.' \
    'review skill states the no-model-turn wait rule'
assert_contains "$review_wait_contract" 'claude-adversarial-review.sh … > verdict.json' \
    'review wait rule names the blocking adversarial helper'
assert_contains "$review_wait_contract" 'gh-pr-state.sh --wait-ci --rounds N --interval S' \
    'review wait rule names the blocking CI helper'
assert_contains "$review_wait_contract" 'adversarial max-duration-seconds' \
    'review wait rule names the adversarial duration bound'
assert_contains "$review_wait_contract" 'CI round cap' \
    'review wait rule names the CI round bound'
assert_contains "$review_wait_contract" 'worker completion marker/contract' \
    'review wait rule names the worker completion marker contract'
assert_contains "$review_wait_contract" 'runner completion marker' \
    'review wait rule names the runner completion bound'
assert_contains "$review_wait_contract" 'A `sleep N` + re-check issued as its own tool call is churn' \
    'review wait rule rejects sleep and re-check tool churn'
assert_contains "$review_wait_contract" 'A bounded wait must be silent until its terminal condition.' \
    'review wait rule is silent until terminal'
assert_contains "$review_wait_contract" 'every line of background output wakes the orchestrator for a turn' \
    'review wait rule explains why background output is forbidden'
assert_contains "$review_wait_contract" 'target_epoch - $(date +%s)' \
    'review wait rule provides a known-epoch sleep recipe'
assert_contains "$review_wait_contract" 'remaining=$(( target_epoch - $(date +%s) ))' \
    'review wait recipe calculates remaining time safely'
assert_contains "$review_wait_contract" 'if (( remaining > 0 )); then' \
    'review wait recipe guards an expired target epoch'
assert_contains "$review_wait_contract" 'sleep "$remaining"' \
    'review wait recipe sleeps only for a nonnegative duration'
assert_contains "$review_wait_contract" 'progress heartbeat' \
    'review wait rule names progress heartbeats'
assert_contains "$review_wait_contract" 'log file, not stdout' \
    'review wait rule redirects heartbeats away from stdout'
assert_contains "$(<"$review_skill")" 'silent until terminal' \
    'review polling section points at silent-until-terminal guidance'
assert_eq '' "$(scan_skill_recipes "$review_skill" "${review_refs[@]}" "${parallel_refs[@]}" "${shared_refs[@]}" | grep 'sleep command' || true)" \
    'review skill has no sleep polling recipe'

scanner_fixture="$tmp/recipe.md"
printf '%s\n' \
    'Never run `sleep 1` in prose.' \
    '```bash' \
    'sleep 1' \
    'sleep "$WAIT_SECONDS"' \
    '/usr/bin/sleep "$WAIT_SECONDS"' \
    'sleep deliberately' \
    '# sleep 1' \
    'printf "%s\\n" "sleep 1"' \
    '```' \
    'The prose still mentions sleep 1.' >"$scanner_fixture"
scanner_script="$tmp/recipe.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'sleep 2' \
    'sleep "$WAIT_SECONDS"' \
    './sleep intentionally' \
    'echo "sleep 3"' >"$scanner_script"
chmod +x "$scanner_script"
sleep_findings=$(scan_skill_recipes "$scanner_fixture" "$scanner_script")
assert_eq '7' "$(grep -c 'sleep command' <<<"$sleep_findings" || true)" \
    'recipe scanner detects every executable sleep argument form'
assert_not_contains "$sleep_findings" 'Never run' \
    'recipe scanner ignores prose sleep prohibitions'
assert_not_contains "$sleep_findings" 'printf' \
    'recipe scanner ignores sleep text in non-sleep commands'

ban_fixture="$tmp/banned.md"
printf '%s\n' \
    'Never run `gh pr ready` or post `@coderabbitai review`.' \
    '```bash' \
    'gh pr ready 81' \
    'gh pr comment 81 --body "@coderabbitai review"' \
    'printf "%s\\n" "gh pr ready 81"' \
    '```' >"$ban_fixture"
ban_findings=$(scan_skill_recipes "$ban_fixture")
assert_eq '1' "$(grep -c 'gh pr ready command' <<<"$ban_findings" || true)" \
    'recipe scanner detects a ready command in an executable fence'
assert_eq '1' "$(grep -c 'provider review trigger' <<<"$ban_findings" || true)" \
    'recipe scanner detects a provider trigger in an executable fence'
assert_not_contains "$ban_findings" 'Never run' \
    'recipe scanner ignores prose command prohibitions'

assert_eq '' "$(scan_skill_recipes "$review_skill" "$parallel_skill" "${review_refs[@]}" "${parallel_refs[@]}" "${shared_refs[@]}" | grep -E 'gh pr ready|provider review trigger' || true)" \
    'review skill recipes contain no ready or provider trigger commands'
step3=$(sed -n '/^## Step 3 (Phase B)/,/^## Step 4:/p' "$review_skill")
assert_contains "$step3" 'Never run `gh pr ready`' \
    'Step 3 keeps the ready transition as a user-only action'
assert_contains "$step3" 'bounded blocking re-check rounds' \
    'Step 3 bounds CodeRabbit rate-limit re-checks'
assert_contains "$step3" '~10 minutes each' \
    'Step 3 gives each rate-limit re-check round a ten-minute bound'
assert_contains "$step3" '~90 minutes total' \
    'Step 3 caps the total rate-limit wait'
assert_contains "$step3" 'one blocking helper/harness wait' \
    'Step 3 keeps rate-limit polling turn-free'
assert_contains "$step3" 'Never trigger a review' \
    'Step 3 never triggers a provider review while retrying'
assert_not_contains "$step3" 'stop and escalate to the user rather than spending turns on repeated checks' \
    'Step 3 does not escalate immediately on a rate limit'
assert_contains "$(<"$review_skill")" 'blocked check and must never be summarized as “no findings.”' \
    'review Step 5 treats missing parsers as blocked checks'

# --- a split skill's references/*.md stay discoverable and flat -------------
# review-remote-pr (and any future skill split the same way) delegates detail
# out of its dispatcher body into references/*.md. Two structural guarantees
# keep that delegation navigable rather than a place things get lost:
#   (a) every reference file is named in the body, with a cue for WHEN to
#       read it (not just a bare link an agent has no reason to follow), and
#   (b) references/ stays one level deep -- no nested subdirectories to lose
#       a file in.
# references/*.md getting a TOC once it passes 100 lines is already enforced
# generically by lint-skill-size.sh; not duplicated here.
for ref_dir in "$skills"/*/references; do
    [[ -d $ref_dir ]] || continue
    split_skill_name=$(basename "$(dirname "$ref_dir")")
    split_skill_body="$(dirname "$ref_dir")/SKILL.md"

    while IFS= read -r -d '' ref_file; do
        ref_rel="references/$(basename "$ref_file")"
        line_no=$(grep -n -F -- "$ref_rel" "$split_skill_body" | head -1 | cut -d: -f1)
        if [[ -n $line_no ]]; then
            _pass "$split_skill_name names $ref_rel in the body"
            cue_line=$(sed -n "${line_no}p" "$split_skill_body")
            if grep -qE '(Read |read ).*in full|(See |see ).*for ' <<< "$cue_line"; then
                _pass "$split_skill_name gives a when-to-read cue for $ref_rel"
            else
                _fail "$split_skill_name gives a when-to-read cue for $ref_rel" \
                    "no 'Read … in full' / 'See … for' cue on $split_skill_body:$line_no"
            fi
        else
            _fail "$split_skill_name names $ref_rel in the body" \
                "not found in $split_skill_body"
        fi
    done < <(find "$ref_dir" -maxdepth 1 -name '*.md' -print0)
done

nested_references=$(find "$skills" -mindepth 3 -path '*/references/*' -type d)
assert_eq '' "$nested_references" \
    'references/ directories stay one level deep, no nested subdirectories'

# --- .shared/*.md policy files stay pointed-at by every consuming skill -----
# .shared/*.md is not a skill's own references/ split -- it is policy content
# shared ACROSS skills (parallel-issues and review-remote-pr both dispatch
# implementation workers and both wait on external state), so each file there
# must be named in every consuming skill's body, not just one of them. Unlike
# a plain references/*.md pointer, these files are pasted into worker prompts
# verbatim in more than one place, so a single first-occurrence "Read … in
# full" cue is not required here -- only that both bodies name the file.
shared_dir="$skills/.shared"
consuming_skills=(parallel-issues review-remote-pr)
while IFS= read -r -d '' shared_file; do
    shared_name=$(basename "$shared_file")
    shared_pointer="../.shared/$shared_name"
    for consumer in "${consuming_skills[@]}"; do
        consumer_body="$skills/$consumer/SKILL.md"
        if grep -qF -- "$shared_pointer" "$consumer_body"; then
            _pass "$consumer points at .shared/$shared_name"
        else
            _fail "$consumer points at .shared/$shared_name" \
                "'$shared_pointer' not found in $consumer_body"
        fi
    done
done < <(find "$shared_dir" -maxdepth 1 -name '*.md' -print0)

# --- no skill re-details a .shared policy ------------------------------------
# A pointer is worthless if the pointed-to skill also keeps its own competing
# explanation. The mechanical bullets a dispatched worker needs (STRUCTS,
# INTERFACES, ... the spawn_agent call shape) are deliberately duplicated
# verbatim inside worker-prompt text, per .shared/six-step-loop.md and
# .shared/spawn-contract.md themselves ("fork_context: false" leaves a worker
# no other way to see them) -- so counting the enumeration keywords would
# fail on that legitimate, load-bearing duplication. Instead this checks
# phrases that belong to the CANONICAL RATIONALE only -- prose a worker
# prompt has no reason to carry -- and confirms each survives in exactly one
# file repo-wide: its own .shared home.
declare -A shared_canonical_phrase=(
    [six-step-loop.md]='Worker prompts render this content verbatim, not as a pointer'
    [spawn-contract.md]='multi_agent_v1__spawn_agent('
    [wait-discipline.md]='empty wait cycles'
)
for shared_name in "${!shared_canonical_phrase[@]}"; do
    phrase=${shared_canonical_phrase[$shared_name]}
    hits=$(grep -rlF -- "$phrase" "$skills" | sort -u)
    hit_count=$(grep -c . <<< "$hits" || true)
    [[ -z $hits ]] && hit_count=0
    assert_eq '1' "$hit_count" \
        ".shared/$shared_name's canonical rationale is not re-detailed elsewhere"
    assert_eq "$shared_dir/$shared_name" "$hits" \
        ".shared/$shared_name's canonical rationale lives only in its own file"
done

finish
