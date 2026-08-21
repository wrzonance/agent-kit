#!/usr/bin/env bash
# Suite: parallel dispatch runtime cap and completion-only polling guidance.
# shellcheck disable=SC2016  # Markdown backticks are literal assertion text
set -uo pipefail

TEST_NAME='parallel-dispatch-contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skill="$root/agentkit/skills/parallel-issues/SKILL.md"
review_skill="$root/agentkit/skills/review-remote-pr/SKILL.md"
worker_gate="$root/agentkit/skills/review-remote-pr/references/worker-gate.md"
review_refs=("$root/agentkit/skills/review-remote-pr/references"/*.md)
parallel_refs=("$root/agentkit/skills/parallel-issues/references"/*.md)
shared_refs=("$root/agentkit/skills/.shared"/*.md)
github_body_policy="$root/agentkit/skills/.shared/github-body-policy.md"
shared_wait_discipline="$root/agentkit/skills/.shared/wait-discipline.md"
verification_isolation="$root/agentkit/skills/parallel-issues/references/verification-isolation.md"
ci_workflow="$root/.github/workflows/ci.yml"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

text=$(<"$skill")
normalized_text=$(tr '\n' ' ' <<<"$text" | tr -s '[:space:]' ' ')
review_skill_text=$(<"$review_skill")
normalized_review_text=$(tr '\n' ' ' <<<"$review_skill_text" | tr -s '[:space:]' ' ')
assert_contains "$normalized_text" 'worker=<model> <effort>' \
    'completion table records the selected worker model and effort'
assert_not_contains "$normalized_text" 'worker=gpt-5.6-luna high' \
    'completion table does not hardcode the worker tier'
# The fetch/fence recipe is absorbed into prepare-issue-artifacts.sh (single
# source of truth); assertions about its internals below check this script
# text rather than SKILL.md, which only documents invocation.
prepare_script_text=$(<"$root/agentkit/skills/parallel-issues/scripts/prepare-issue-artifacts.sh")
# Both dispatch prompt templates are single-sourced in
# references/worker-prompts.md (issue #107's split); SKILL.md's body keeps
# only a gate statement + pointer at each binding step. Template-content
# assertions below therefore check the reference file, never the body.
worker_prompts="$root/agentkit/skills/parallel-issues/references/worker-prompts.md"
worker_prompts_text=$(<"$worker_prompts")
# The bulk-mutation ledger recipe and the triage/prior-art/board adjudication
# detail are single-sourced in references/triage-and-selection.md (issue
# #107 phase 3's split); SKILL.md's body keeps only the one-line verdict
# table, the ledger/REST-first mandate, and pointers.
triage_and_selection="$root/agentkit/skills/parallel-issues/references/triage-and-selection.md"
triage_and_selection_text=$(<"$triage_and_selection")
wait_discipline_text=$(<"$shared_wait_discipline")
verification_isolation_text=$(<"$verification_isolation")
worker_gate_text=$(<"$worker_gate")
root_review_section=$(awk '
    $0 == "### Root review and draft PR after a worker push" { capture=1; next }
    capture && $0 == "### Polling discipline (applies to every wait in this skill)" { exit }
    capture { print }
' "$skill")
assert_not_contains "$root_review_section" '### Polling discipline (applies to every wait in this skill)' \
    'root review extraction stops before the following polling section'
provider_rules_text=$(<"$root/agentkit/skills/review-remote-pr/references/provider-rules.md")
grooming_text=$(<"$root/agentkit/skills/review-remote-pr/references/grooming.md")
issue_lead_prompt=$(awk '
    /^Per-issue prompt:/ { capture=1; next }
    capture && /^````$/ { exit }
    capture { print }
' "$worker_prompts")
# The opening fence may carry a language tag (markdownlint MD040 requires one);
# only the CLOSING fence is bare. Matching `^```$` for the opener silently
# extracted nothing the moment the tag was added, and an empty haystack fails
# every positive assertion at once rather than pointing at the real cause.
draft_loop_prompt=$(awk '
    /^\*\*Per-agent prompt template:\*\*$/ { capture=1; next }
    capture == 1 && /^```/ { capture=2; next }
    capture == 2 && /^```$/ { exit }
    capture == 2 { print }
' "$worker_prompts")
[[ -n $draft_loop_prompt ]] || {
    printf 'could not extract the draft-loop prompt block from %s\n' "$worker_prompts" >&2
    exit 1
}

# The fix-batch worker runs full verification through the same wrapper as an
# issue lead, so the Compose isolation rules must reach BOTH templates. Pinning
# them only on the whole-file text would pass while the fix-batch prompt carried
# none of them.
fix_batch_prompt=$(awk '
    /^## Fix-batch worker prompt$/ { capture=1; next }
    capture && /^## Exit Report$/ { exit }
    capture { print }
' "$worker_prompts")
[[ -n $fix_batch_prompt ]] || {
    printf 'could not extract the fix-batch prompt block from %s\n' "$worker_prompts" >&2
    exit 1
}
# Issue #336: the Compose-isolation prose is CONDITIONAL, so both raw templates
# carry the composer-filled token rather than the paragraph itself. A repository
# with no Compose-driven command never pays for the essay; one that declares a
# Compose command still gets every rule. The rendered-both-ways assertions live
# in test-compose-worker-prompt-scope.sh, which can actually compose a prompt;
# here we pin that neither template hardcodes the prose it must not always emit.
for _tpl_name in issue_lead fix_batch; do
    _tpl_var="${_tpl_name}_prompt"
    # Collapse wrapping before matching: these sentences are reflowed by hand and
    # a phrase split across two lines is still the phrase. Matching raw text made
    # the assertion depend on where the paragraph happened to wrap.
    _tpl_flat=$(printf '%s' "${!_tpl_var}" | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]')
    assert_contains "$_tpl_flat" '__compose_isolation__' \
        "the $_tpl_name template defers Compose isolation to the composer"
    assert_not_contains "$_tpl_flat" 'agent_compose_serialized' \
        "the $_tpl_name template does not hardcode the Compose serialization essay"
    assert_contains "$_tpl_flat" '__image_invalidating_writers__' \
        "the $_tpl_name template defers the image-invalidating writer list to the composer"
    assert_not_contains "$_tpl_flat" 'move-github-project-item.sh' \
        "the $_tpl_name template does not hardcode root-side writers a worker never invokes"
done
compose_script_text=$(<"$root/agentkit/skills/parallel-issues/scripts/compose-worker-prompt.sh")
assert_contains "$compose_script_text" 'AGENT_COMPOSE_SERIALIZED=1' \
    'the composer owns the Compose serialization fallback text'
assert_contains "$compose_script_text" 'environment-retry-eligible' \
    'the composer owns the Compose retry classification'
assert_contains "$compose_script_text" 'COMPOSE_PROJECT_NAME' \
    'the composer owns the isolated Compose project variable'
assert_contains "$text" '--auto-serialize' 'auto-serialize flag is documented'
assert_contains "$text" 'file-conflict pairs and native blocked-by edges inside the selected set' \
    'chain ordering sources are exactly the two mechanical ones'
assert_contains "$text" 'never an ordering input' \
    'issue-body prose is excluded from ordering'
assert_contains "$text" 'chain depth cap: 4' 'chain depth cap is pinned'
assert_contains "$text" 'cycle' 'cycles fall back instead of chaining'
assert_contains "$text" 'chain_base_sha' 'chain base sha variable is named'
assert_contains "$text" 'git worktree add "$worktree" -b "$branch" "${chain_base_sha:-origin/$base}"' \
    'worktree recipe parameterizes its start point'
assert_contains "$normalized_text" "as soon as the predecessor's worker has committed and pushed its branch" \
    'chain successors gate on the pushed commit, not root publication'
assert_not_contains "$normalized_text" 'only after the root has validated, committed, and pushed' \
    'chain successors no longer wait for the root publication ceremony'
chains_reference_text=$(<"$root/agentkit/skills/parallel-issues/references/chains.md")
normalized_chains_text=$(tr '\n' ' ' <<<"$chains_reference_text" | tr -s '[:space:]' ' ')
assert_contains "$normalized_chains_text" 'pushed commit' \
    'chains reference gates on the pushed commit'
assert_contains "$normalized_chains_text" 'A join is scheduled, not dropped' \
    'a multi-predecessor join is scheduled instead of dropped'
assert_contains "$normalized_chains_text" 'a five-issue set dispatches five issues' \
    'join scheduling keeps every selected issue dispatched'
assert_contains "$normalized_chains_text" 'Push that integration commit to' \
    'the join recipe pushes the merged base before dispatch'
assert_contains "$normalized_chains_text" 'predecessors pushed AND join base pushed' \
    "a join's dispatch gate is stated as two-part"
assert_contains "$normalized_chains_text" 'Publishing a locally-built chain base' \
    'chains reference documents the general pushed-base requirement'
assert_contains "$normalized_chains_text" 'a linear chain is not protected from this just because it only had one predecessor' \
    'the pushed-base requirement is generalized past the join case'
assert_contains "$normalized_text" 'for a join, this means every predecessor pushed AND the merged join base itself pushed' \
    'the deferred-dispatch gate names the join-specific push requirement'
assert_contains "$normalized_chains_text" 'interface dependency' \
    'chain edges require an interface dependency'
assert_contains "$normalized_text" 'test files or prose does not serialize' \
    'test/prose overlap runs in parallel with an end merge-down'
assert_contains "$text" 'root-owned dispatch plan' \
    'dispatch creates the root-owned plan before selection is dispatched'
assert_contains "$triage_and_selection_text" 'predictedWriteSet' \
    'dispatch-plan entries pin predicted write sets'
assert_contains "$triage_and_selection_text" 'conflictMap.revisions' \
    'dispatch-plan records post-selection conflict-map revisions'
assert_contains "$triage_and_selection_text" '"schemaVersion": 2' \
    'dispatch-plan schema carries the ready-flip merge plan'
assert_contains "$triage_and_selection_text" '"chains"' \
    'dispatch-plan records ordered base-to-tip chains'
assert_contains "$triage_and_selection_text" '"independent"' \
    'dispatch-plan records the independent PR set'
assert_contains "$triage_and_selection_text" 'chainBaseSha' \
    'merge-plan records pin each successor base SHA'
assert_contains "$triage_and_selection_text" 'headSha' \
    'merge-plan records pin live head verification evidence'
assert_contains "$text" 'write-merge-plan.sh' \
    'ready-flip handoff persists the machine-readable merge plan'
assert_contains "$triage_and_selection_text" 'shared root files' \
    'conflict analysis includes shared root files by default'
assert_contains "$triage_and_selection_text" 'chain-conversion' \
    'late overlap has an explicit chain-conversion disposition'
assert_contains "$triage_and_selection_text" 'merge-down' \
    'late overlap has an explicit merge-down disposition'
assert_contains "$triage_and_selection_text" 'inherited #137' \
    'late overlap points at the inherited #137 response'
assert_contains "$text" '"$agentkit/.shared/scripts/contract-read.sh" --repo-root "$repository_root" --get skills.path' \
    'parallel preflight passes its owned repository_root to contract-read.sh'
assert_not_contains "$text" '"$agentkit/.shared/scripts/contract-read.sh" --repo-root "$contract_root" --get skills.path' \
    'parallel preflight does not use the undefined contract_root'
# The wait-contract rule sentences are single-sourced in
# .shared/wait-discipline.md; the body keeps only a pointer (see the "###
# Polling discipline" subsection), so the pinned wait-rule content is
# asserted against the shared file, same as test-skills-contract.sh does for
# review-remote-pr's identical pointer.
assert_contains "$text" '.shared/wait-discipline.md' \
    'parallel skill points at the shared wait-discipline contract'
assert_contains "$wait_discipline_text" 'A wait must never spend model turns.' \
    'parallel skill states the no-model-turn wait rule'
assert_contains "$wait_discipline_text" 'gh-pr-state.sh --wait-ci --rounds N --interval S' \
    'parallel wait rule names the blocking CI exemplar'
assert_contains "$wait_discipline_text" 'claude-adversarial-review.sh … > verdict.json' \
    'parallel wait rule names the blocking adversarial helper'
assert_contains "$wait_discipline_text" 'agent-run.sh --cmd test' \
    'parallel wait rule names the blocking test runner'
assert_contains "$wait_discipline_text" 'adversarial max-duration-seconds' \
    'parallel wait rule names the adversarial duration bound'
assert_contains "$wait_discipline_text" 'CI round cap' \
    'parallel wait rule names the CI round bound'
assert_contains "$wait_discipline_text" 'worker completion marker' \
    'parallel wait rule names the worker completion bound'
assert_contains "$wait_discipline_text" 'runner completion marker' \
    'parallel wait rule names the runner completion bound'
assert_contains "$wait_discipline_text" 'test-runner logs' \
    'parallel wait rule covers test-runner logs'
# The triage/prior-art/board adjudication detail and the fast-mode Step 2b
# procedure moved to references/triage-and-selection.md, and both dispatch
# prompt templates moved to references/worker-prompts.md (issue #107 phase
# 3's split); pin the body's pointer to each, same as the wait-discipline
# pointer above -- content coverage of what those files carry is already
# proven by the assertions against $triage_and_selection_text and
# $worker_prompts_text throughout this suite, but nothing previously pinned
# that SKILL.md's body actually points a cold reader at either file.
assert_contains "$text" 'references/triage-and-selection.md' \
    'parallel skill points at the triage-and-selection reference'
assert_contains "$text" 'references/worker-prompts.md' \
    'parallel skill points at the worker-prompts reference'
assert_contains "$wait_discipline_text" 'A `sleep N` + re-check issued as its own tool call is churn' \
    'parallel wait rule rejects sleep and re-check tool churn'
assert_contains "$wait_discipline_text" 'A bounded wait must be silent until its terminal condition.' \
    'parallel wait rule is silent until terminal'
assert_contains "$wait_discipline_text" 'every line of background output wakes the orchestrator for a turn' \
    'parallel wait rule explains why background output is forbidden'
assert_contains "$wait_discipline_text" 'target_epoch - $(date +%s)' \
    'parallel wait rule provides a known-epoch sleep recipe'
assert_contains "$wait_discipline_text" 'remaining=$(( target_epoch - $(date +%s) ))' \
    'parallel wait recipe calculates remaining time safely'
assert_contains "$wait_discipline_text" 'if (( remaining > 0 )); then' \
    'parallel wait recipe guards an expired target epoch'
assert_contains "$wait_discipline_text" 'sleep "$remaining"' \
    'parallel wait recipe sleeps only for a nonnegative duration'
assert_contains "$wait_discipline_text" 'progress heartbeat' \
    'parallel wait rule names progress heartbeats'
assert_contains "$wait_discipline_text" 'log file, not stdout' \
    'parallel wait rule redirects heartbeats away from stdout'
assert_contains "$text" 'silent until terminal' \
    'parallel polling section points at silent-until-terminal guidance'
assert_eq '' "$(scan_skill_recipes "$skill" "$review_skill" "${review_refs[@]}" "${parallel_refs[@]}" "${shared_refs[@]}" | grep 'sleep command' || true)" \
    'parallel skill has no sleep polling recipe'
assert_eq '' "$(scan_skill_recipes "$skill" "$review_skill" "${review_refs[@]}" "${parallel_refs[@]}" "${shared_refs[@]}" | grep -E 'gh pr ready|provider review trigger' || true)" \
    'parallel skill recipes contain no ready or provider trigger commands'
assert_not_contains "$wait_discipline_text" 'Between waits, read durable state instead of waiting again' \
    'polling does not inspect durable state between empty waits'
assert_not_contains "$text" 'Between waits, read durable state instead of waiting again' \
    'parallel body does not reintroduce the rejected wait phrasing'
assert_contains "$wait_discipline_text" 'Between waits, wait again; read durable state only when a wait reports an actual completion.' \
    'polling reads durable state only after completion'
assert_contains "$draft_loop_prompt" 'do not load `review-remote-pr/SKILL.md`' \
    'dispatch is self-contained without loading the worker skill'
assert_not_contains "$text" 'Four total slots including the root' \
    'dispatch does not hardcode the old slot count'
assert_not_contains "$text" 'Max 5 issues' \
    'limits do not hardcode the old issue count'
assert_contains "$text" 'max_concurrent_threads_per_session' \
    'dispatch reads the runtime concurrency setting'
assert_contains "$text" 'concurrency-cap.sh' \
    'dispatch delegates runtime cap parsing to the helper'
dispatch_section=$(sed -n '/^### Dispatch /,/^When the runtime advertises/p' "$skill")
assert_contains "$dispatch_section" '[ -d "${agentkit:-}/.shared/scripts" ]' \
    'concurrency dispatch carries the resolver directory guard'
assert_contains "$dispatch_section" 'agentkit_provenance' \
    'concurrency dispatch validates resolver provenance'
assert_contains "$text" 'PR_LOOP_CONCURRENCY_CAP=2' \
    'dispatch names the hard PR-loop cap at the launch boundary'
assert_contains "$text" 'pr_loop_dispatch_cap' \
    'dispatch derives an effective loop cap before launching agents'
assert_contains "$text" 'queue overflow PR loops' \
    'dispatch queues PR loops beyond the effective cap'
assert_contains "$verification_isolation_text" 'serialize full-suite verification' \
    'dispatch documents full-suite serialization when Compose isolation is defeated'
assert_contains "$verification_isolation_text" 'COMPOSE_PROJECT_NAME' \
    'worker verification contract names the per-worktree Compose namespace'
assert_contains "$verification_isolation_text" 'environment-retry-eligible' \
    'worker verification contract names retry-eligible Compose findings'
assert_contains "$prepare_script_text" 'target="$agent_dir/fenced-spec.txt"' \
    'issue fencing uses the established excluded per-worktree path'
assert_contains "$prepare_script_text" 'prior_target="$agent_dir/fenced-prior-art.txt"' \
    'issue preparation persists prior-art fence bytes'
bulk_section=$(sed -n '/^## Bulk mutation discipline:/,/^## Prior-art adjudication/p' "$triage_and_selection")
assert_contains "$bulk_section" 'if ! mutation_json=$(perform_rest_mutation "$planning_id"); then' \
    'bulk recipe stops on a mutation failure'
assert_contains "$bulk_section" 'if ! "$apply_ledger" record --ledger "$ledger"' \
    'bulk recipe stops on a record failure'
assert_contains "$bulk_section" 'applied/remaining' \
    'bulk recipe reports applied and remaining ledger evidence on failure'
assert_contains "$bulk_section" 'if grep -Eq' \
    'bulk recipe guards a nonmatching budget marker explicitly'
root_fence_section=$(sed -n '/^### Root canonical issue fetch and fence preparation$/,/^Per-issue prompt:$/p' "$skill")
assert_contains "$root_fence_section" 'select-boundary-mode.sh' \
    'root delegates boundary mode selection to the helper'
assert_contains "$root_fence_section" 'boundary_mode' \
    'root carries the selected boundary mode'
assert_contains "$prepare_script_text" 'if [[ $boundary_mode == public-fenced ]]; then' \
    'trusted modes persist exact bytes without invoking the fence helper'
assert_contains "$root_fence_section" 'printf '\''boundary mode: %s\n'\'' "$boundary_mode"' \
    'root prints the selected boundary mode'
dispatch_handoff=$(sed -n '/^Per-issue prompt:/,/^### Collect (per-completion/p' <<< "$text")
assert_contains "$dispatch_handoff" 'Compose once, to a file; the spawn reads that file — never re-compose to re-read.' \
    'dispatch pins one composition to a file per spawned worker'
assert_contains "$dispatch_handoff" 'REQUIRED for an issue lead' \
    'dispatch marks write-set globs as required for issue leads'
assert_contains "$dispatch_handoff" 'prompt_file="$prompt_dir/issue-$issue_number-lead.md"' \
    'dispatch handoff composes to a per-issue file in the worker'"'"'s excluded .agent/ tree'
assert_contains "$dispatch_handoff" 'chmod 600 -- "$prompt_file"' \
    'the composed prompt file is not world-readable'
assert_contains "$dispatch_handoff" 'if ! "$compose_script" "${compose_args[@]}"; then' \
    'dispatch handoff stops when prompt composition fails'
compose_invocations=$(grep -Fxc 'if ! "$compose_script" "${compose_args[@]}"; then' <<< "$dispatch_handoff" || true)
assert_eq '1' "$compose_invocations" \
    'dispatch invokes the prompt composer exactly once per worker'
# Issue #336: the spawn consumes the FILE. Echoing the prompt spends the whole
# composed body in root context for no dispatch benefit -- twice, under an
# approval layer that re-executes an approved command. The block emits a digest.
assert_contains "$dispatch_handoff" "printf 'prompt=%s bytes=%s issue=%s write-set=%s" \
    'dispatch handoff emits a path + digest instead of the prompt body'
assert_contains "$dispatch_handoff" 'wc -c < "$prompt_file"' \
    'the digest carries the composed byte count'
for _echo in 'cat -- "$prompt_file"' 'cat "$prompt_file"' 'sed -n' 'head -' 'tail -'; do
    assert_not_contains "$dispatch_handoff" "$_echo" \
        "dispatch handoff never reads the composed prompt back into root context ($_echo)"
done
assert_not_contains "$dispatch_handoff" ': "$worker_prompt"' \
    'dispatch handoff does not discard the composed prompt'
boundary_selector="$root/agentkit/skills/parallel-issues/scripts/select-boundary-mode.sh"
assert_eq yes "$( [[ -x $boundary_selector ]] && printf yes || printf no )" \
    'boundary selector helper is executable'
for visibility in false unknown ''; do
    selected=$("$boundary_selector" --visibility "$visibility" --no-yolo 2>/dev/null | tail -n 1)
    assert_eq 'boundary mode: public-fenced' "$selected" \
        "visibility '$visibility' fails closed to public-fenced"
done
selected=$("$boundary_selector" --visibility false --yolo 2>/dev/null | tail -n 1)
assert_eq 'boundary mode: yolo-trusted' "$selected" \
    'explicit yolo selects yolo-trusted regardless of visibility'
assert_contains "$text" 'one canonical issue-body fetch during preparation' \
    'triage digest limits surviving issue body reads to preparation'
assert_contains "$text" 'Do not fetch issue timelines, `projectItems`' \
    'triage flow forbids redundant timeline and project item reads'
assert_contains "$text" '--issue-numbers "$issue_numbers_csv"' \
    'dispatch moves selected issues with one batch invocation'
assert_contains "$issue_lead_prompt" '--only NAME[,NAME...]' \
    'red/green iteration documents the focused suite selector'
assert_contains "$issue_lead_prompt" 'AGENT_CMD_TEST_FOCUS' \
    'focused iteration is gated by the repository declaration'
assert_contains "$issue_lead_prompt" 'once against the final tree state' \
    'the final tree receives one unfocused full-suite run'
assert_contains "$provider_rules_text" 'if ! "$agentkit/review-remote-pr/scripts/code-quality-state.sh"' \
    'Code Quality evidence failure stops before no-findings processing'
assert_contains "$provider_rules_text" 'Code Quality findings unavailable' \
    'Code Quality evidence failure is reported as unavailable'
assert_contains "$grooming_text" 'REPO_ROOT=$(git rev-parse --show-toplevel' \
    'backlog grooming resolves its repository root explicitly'
assert_contains "$grooming_text" 'git -C "$REPO_ROOT" rev-parse --show-toplevel' \
    'backlog grooming validates its repository root'
assert_contains "$worker_prompts_text" 'extends existing pattern <name>' \
    'worker contract makes the spike exemption novelty-based, naming the pattern'
assert_not_contains "$worker_prompts_text" 'at most 10 changed implementation lines' \
    'worker contract no longer sizes the spike exemption by line count'
assert_contains "$worker_prompts_text" 'line count is not the test' \
    'worker contract states that size never decides the spike'
assert_contains "$worker_prompts_text" 'A skip is never silent' \
    'worker contract records why every spike skip happened'
assert_contains "$worker_prompts_text" 'existing pattern' \
    'worker contract limits spike skips to existing patterns'
assert_contains "$worker_prompts_text" 'one-line justification' \
    'worker contract requires a one-line skip justification'
assert_contains "$worker_prompts_text" 'transcript evidence' \
    'worker contract requires transcript evidence for performed spikes'
assert_contains "$worker_prompts_text" 'both the spike edit and the revert' \
    'worker contract requires evidence for both spike operations'
assert_contains "$normalized_text" 'Do not request a post-hoc report rewrite' \
    'root validation does not request post-hoc spike report rewrites'
assert_contains "$normalized_text" 'bounces only absent or unjustified' \
    'root validation bounces only absent or unjustified spike reports'
assert_contains "$(<"$review_skill")" '--only NAME[,NAME...]' \
    'review workflow documents the focused suite selector'
assert_contains "$(<"$review_skill")" 'full-suite verdict' \
    'review workflow requires a final full-suite verdict'
review_verification_section=$(sed -n '/^## Step 0: Setup/,/^## Step 3 (Phase B)/p' "$review_skill")
assert_contains "$review_verification_section" '--only NAME[,NAME...]' \
    'review workflow forwards focused selectors'
assert_contains "$review_verification_section" 'AGENT_CMD_TEST_FOCUS' \
    'review workflow pins the focused declaration gate'
assert_contains "$review_verification_section" 'run the unfocused `"$agent_run" --cmd test` once' \
    'review workflow pins the final unfocused full-suite sequencing'
assert_contains "$text $triage_and_selection_text" 'that issue/status/phase is complete' \
    'a moved output line is terminal for its issue phase'
assert_not_contains "$text" 'target="$PWD/fenced-spec.txt"' \
    'issue fencing never writes untrusted bytes to the worktree root'
assert_prompt_instruction_contract() {
    local prompt="$1" label="$2" scope="$3" normalized_prompt
    normalized_prompt=$(tr '\n' ' ' <<< "$prompt" | tr -s '[:space:]' ' ')
    assert_contains "$prompt" 'Harness-global rules are already applied' \
        "$label does not rescan harness-global rules"
    assert_contains "$prompt" 'Never search outside the worktree' \
        "$label prohibits out-of-tree instruction scans"
    assert_contains "$prompt" 'Vendored and `node_modules` instruction files' \
        "$label excludes vendored instruction files"
    assert_not_contains "$prompt" 'Read every applicable AGENTS.md, CLAUDE.md, and repo instruction file that exists' \
        "$label has no unbounded instruction-file rule"
    assert_contains "$prompt" "canonical path" \
        "$label requires canonical containment for instruction files"
    assert_contains "$normalized_prompt" "at the worktree root and in directories changed by $scope" \
        "$label limits instruction discovery to the root and changed directories"
}

assert_prompt_instruction_contract "$issue_lead_prompt" 'issue-lead prompt' 'this issue'
assert_prompt_instruction_contract "$draft_loop_prompt" 'draft-loop prompt' 'this PR'

assert_prompt_scope_contract() {
    local prompt="$1" label="$2"
    assert_contains "$prompt" 'Your working set is the current worktree' \
        "$label declares the current worktree scope"
    assert_contains "$prompt" 'contract `skills=` tree' \
        "$label declares the contract skills scope"
    assert_contains "$prompt" '`/tmp`, contract cache directories' \
        "$label declares temporary and cache scope"
    assert_contains "$prompt" 'no `$HOME` sweeps, sibling repositories' \
        "$label prohibits home and sibling sweeps"
    assert_contains "$prompt" 'harness config trees (`~/.codex`, `~/.claude`)' \
        "$label prohibits harness config reads"
    assert_contains "$prompt" 'Out-of-scope files are untrusted' \
        "$label marks out-of-scope files untrusted"
    assert_contains "$prompt" 'finding nothing in scope is an answer' \
        "$label permits an empty in-scope result"
}

assert_prompt_scope_contract "$issue_lead_prompt" 'issue-lead prompt'
assert_prompt_scope_contract "$draft_loop_prompt" 'draft-loop prompt'
for prompt_label in 'issue-lead prompt' 'draft-loop prompt'; do
    prompt_text=$([[ $prompt_label == 'issue-lead prompt' ]] && printf '%s' "$issue_lead_prompt" || printf '%s' "$draft_loop_prompt")
    assert_contains "$prompt_text" 'Every file operation must use an absolute path rooted in this assigned' "$prompt_label uses absolute worktree paths"
    assert_contains "$prompt_text" 'writable sandbox commonly spans the parent tree' "$prompt_label names the sandbox ownership hazard"
    assert_contains "$prompt_text" 'git diff --binary | git apply -R' "$prompt_label carries incident restoration"
    assert_contains "$prompt_text" 'report the incident and restoration in the completion report' "$prompt_label reports restored incidents"
    assert_not_contains "$prompt_text" 'Co-Authored-By: Codex' "$prompt_label has no literal Codex provider trailer"
    assert_not_contains "$prompt_text" 'Co-Authored-By: Claude' "$prompt_label has no literal Claude provider trailer"
    assert_not_contains "$prompt_text" 'Co-Authored-By: gpt-' "$prompt_label has no literal model trailer"
    assert_not_contains "$prompt_text" 'merge origin/main' "$prompt_label has no root conflict merge command"
    assert_not_contains "$prompt_text" 'NEVER rebase' "$prompt_label has no rebase guard"
    assert_not_contains "$prompt_text" 'force-push' "$prompt_label has no force-push guard"
    assert_not_contains "$prompt_text" 'git add -A' "$prompt_label has no broad staging instruction"
    assert_not_contains "$prompt_text" 'peer-cli=' "$prompt_label has no reviewer provider selection"
    assert_not_contains "$prompt_text" 'gpt-5.6-terra' "$prompt_label has no blind reviewer fallback"
    assert_contains "$prompt_text" '<PASTE, verbatim, the agent-preflight.sh contract' \
        "$prompt_label carries the environment-contract paste placeholder"
done
assert_contains "$text" 'set its working directory to the assigned worktree' 'dispatcher sets worker cwd when supported'
assert_contains "$issue_lead_prompt" 'completion report' 'issue lead returns a completion report'
assert_contains "$draft_loop_prompt" 'completion report' 'phase lead returns a completion report'
assert_contains "$issue_lead_prompt" 'git push -u origin' 'issue lead pushes its own branch'
assert_contains "$draft_loop_prompt" 'push the branch' 'phase lead pushes its own branch'
issue_lead_flat=$(tr '\n' ' ' <<<"$issue_lead_prompt" | tr -s '[:space:]' ' ')
draft_loop_flat=$(tr '\n' ' ' <<<"$draft_loop_prompt" | tr -s '[:space:]' ' ')
assert_contains "$issue_lead_flat" 'worktree-commit.sh" --message' \
    'issue lead commits through the shipped helper'
assert_contains "$issue_lead_flat" 'Environment-refusal fallback' \
    'issue lead keeps the handback as the environment-refusal fallback only'
assert_contains "$draft_loop_flat" 'publication handback' \
    'phase lead keeps the fallback handback documented'
assert_contains "$issue_lead_flat" 'True blockers' \
    'issue lead defines true blockers explicitly'
assert_contains "$issue_lead_flat" 'routine self-correction' \
    'issue lead distinguishes routine self-correction from blockers'
assert_contains "$issue_lead_flat" 'Never ask permission to do work this dispatch already assigned you' \
    'issue lead never asks permission for assigned work'
assert_contains "$issue_lead_prompt" '__DECLARED_WRITE_SET__' \
    'issue lead template carries the declared write-set token'
assert_not_contains "$issue_lead_flat" 'Leave progress unstaged' \
    'issue lead no longer leaves progress unstaged for handback'
assert_not_contains "$draft_loop_flat" 'Leave all authored progress unstaged' \
    'phase lead no longer leaves progress unstaged for handback'
for prompt_label in 'issue-lead prompt' 'draft-loop prompt'; do
    prompt_text=$([[ $prompt_label == 'issue-lead prompt' ]] && printf '%s' "$issue_lead_prompt" || printf '%s' "$draft_loop_prompt")
    assert_contains "$prompt_text" '"$shared/contract-read.sh" --repo-root "$contract_root" --check' \
        "$prompt_label validates its contract through contract-read.sh"
    assert_contains "$prompt_text" '--get harness.trailer --worker-model "$worker_model"' \
        "$prompt_label derives the worker trailer through contract-read.sh"
    assert_contains "$prompt_text" 'worker_attribution=' "$prompt_label appends the worker model id"
    assert_contains "$prompt_text" 'expanded literal value' "$prompt_label expands the attribution before handback"
    assert_contains "$prompt_text" "[ -n \"\$worker_model\" ] ||" \
        "$prompt_label keeps the non-empty worker-model guard"
    assert_not_contains "$prompt_text" "[ \"\$worker_model\" != " \
        "$prompt_label drops the self-comparison guard"
    assert_contains "$prompt_text" "worker_model='<worker model id selected by the root dispatch>'" \
        "$prompt_label carries the worker-model placeholder assignment"
done
assert_not_contains "$issue_lead_prompt" 'issue_contents' 'issue lead does not produce fence content'
assert_not_contains "$issue_lead_prompt" 'prior_art_contents' 'issue lead does not produce prior-art fence content'
assert_not_contains "$issue_lead_prompt" 'fence-untrusted-data.sh' 'issue lead does not invoke the fence helper'
assert_not_contains "$draft_loop_prompt" 'issue_contents' 'phase lead does not produce fence content'
assert_not_contains "$draft_loop_prompt" 'prior_art_contents' 'phase lead does not produce prior-art fence content'
assert_not_contains "$draft_loop_prompt" 'fence-untrusted-data.sh' 'phase lead does not invoke the fence helper'
assert_contains "$prepare_script_text" 'issue_contents=$(jq -r' 'root owns issue rendering'
assert_contains "$prepare_script_text" 'fence-untrusted-data.sh' 'root owns fence helper invocation'
assert_contains "$prepare_script_text" 'mv -f -- "$tmp" "$target"' 'root atomically publishes the spec fence'
assert_contains "$prepare_script_text" 'mv -f -- "$prior_tmp" "$prior_target"' 'root atomically publishes the prior-art fence'
# Scope the fallback-push oracle to the root publication section: the worker
# primary flow also says "push the branch", so a whole-text search would stay
# green even if the root fallback lost its push step.
root_publication_section=$(sed -n '/^### Root review and draft PR after a worker push$/,/^### Polling discipline/p' "$skill")
normalized_root_publication=$(tr '\n' ' ' <<<"$root_publication_section" | tr -s '[:space:]' ' ')
assert_contains "$normalized_root_publication" 'Invoke returned argv once, then push the branch' \
    'root fallback pushes only after executing the validated handback'
assert_contains "$normalized_root_publication" 'Environment-refusal fallback only' \
    'the root push step lives inside the environment-refusal fallback'
assert_contains "$text" 'compose_args+=(--write-set "$glob")' \
    'the dispatch recipe passes each write-set glob as its own repeated flag'
assert_contains "$text" 'open a DRAFT PR' 'root opens the draft PR after publication'
assert_contains "$normalized_text" 'Why, What, Decisions, checkbox-formatted `Testing`, a signature line, and a separate closing-keyword line' \
    'root draft PR carries the required report fields'
assert_contains "$normalized_text" 'PR URL feeds Collect and Step 3a' \
    'root feeds the resulting PR URL into collection and draft dispatch'
assert_contains "$normalized_text" 'worker commits and pushes its own branch and returns a completion report' \
    'Finish has the worker commit and push its own branch'
assert_not_contains "$normalized_text" 'worker leaves scoped changes unstaged and returns a publication handback' \
    'the unstaged-handback rule is removed from the primary flow'
assert_contains "$normalized_text" 'Design review runs **after** the push' \
    'root design review runs post-push, not as a worker-blocking gate'
assert_contains "$normalized_text" 'Environment-refusal fallback only' \
    'the validator flow is scoped to the environment-refusal fallback'
assert_not_contains "$normalized_review_text" 'root publication stages only the explicit handback' \
    'review workflow no longer stages a worker handback as root publication'
assert_contains "$normalized_review_text" "review the worker's pushed diff and re-check CI and review state" \
    'review Phase A re-checks state after the worker push'
assert_not_contains "$normalized_review_text" 'verify its fix, commit/push once' \
    'review Phase A does not republish the worker fix from root'
assert_contains "$text" 'Step 3b workers receive only root-approved fix batches' \
    'Step 3b restricts workers to root-approved mechanical batches'
fix_batch_flat=$(tr '\n' ' ' <<<"$fix_batch_prompt" | tr -s '[:space:]' ' ')
assert_contains "$fix_batch_flat" 'Committing and pushing the assigned branch is yours' \
    'fix-batch workers publish their own branch'
assert_contains "$fix_batch_flat" 'RED: WAIVED' \
    'fix-batch workers declare a red-phase waiver when no test seam exists'
assert_contains "$fix_batch_flat" 'write set excludes tests' \
    'fix-batch red-phase waiver names test-excluded batches'
assert_not_contains "$fix_batch_flat" 'simulate a failing check' \
    'fix-batch workers never simulate a failing check for the TDD contract'
assert_contains "$normalized_text" 'root handles CI state/verification, forge conflicts, adversarial review, consent, replies, and publication' \
    'Phase A orchestration remains root-owned'
assert_contains "$normalized_text" 'preserves the raw command text for audit' \
    'parallel dispatch preserves worker handback command text'
assert_contains "$text" 'parse into validated arguments without eval' \
    'parallel dispatch parses handback arguments without eval'
assert_contains "$text" 'validate-handback.sh' \
    'parallel dispatch invokes the publication handback validator'
assert_contains "$text" 'if ! "$agentkit/.shared/scripts/validate-handback.sh"' \
    'parallel dispatch checks the validator status before publication'
assert_contains "$text" '--issue "$issue_number" --dispatch-plan "$dispatch_plan"' \
    'parallel dispatch validates handbacks against the selected plan entry'
assert_contains "$text" 'mapfile -d' \
    'parallel dispatch consumes validated handback argv without re-parsing shell text'
assert_contains "$text" '((${#validated_argv[@]})) || exit 1' \
    'parallel dispatch rejects empty validated argv'
assert_contains "$text" 'cd -- "$worktree"' \
    'parallel dispatch executes the validated argv in the worktree'
assert_contains "$normalized_text" 'expected worktree-commit.sh helper' \
    'parallel dispatch validates the expected commit helper'
assert_contains "$normalized_text" 'every explicit path inside the worktree and allowed' \
    'parallel dispatch validates handback path containment'
# The contract used to pin a `git diff -- <explicit handback paths>` inspection
# that the validator never performed. What it actually enforces -- and what root
# depends on -- is that every staged path is declared and unprotected, because
# worktree-commit.sh commits the whole index and its own staged-protected guard
# only fires during an active merge.
assert_contains "$normalized_text" 'every staged path declared and unprotected' \
    'parallel dispatch reconciles staged paths against the declared operands'
assert_contains "$normalized_text" 'Only after publication does the root inspect `base...HEAD`' \
    'parallel dispatch defers base diff inspection until publication'
# The draft-PR body composer recipe is single-sourced in references/worker-prompts.md
# -- it is dispatch-output content read at publication time, not a worker prompt,
# but it lives beside the worker prompts it is read alongside. SKILL.md's body
# keeps only a gate statement + pointer at the binding step.
publication_section=$(
    sed -n '/^## Draft PR body template$/,/^## Fix-batch worker prompt$/p' "$worker_prompts"
)
assert_contains "$publication_section" '"$agentkit/.shared/scripts/gh-body.sh" pr create --draft --body-file "$pr_body_file"' \
    'draft PR publication uses the byte-verifying body transport'
assert_not_contains "$publication_section" 'gh pr create --draft --body-file "$pr_body_file"' \
    'draft PR publication does not bypass the byte-verifying transport'
assert_contains "$publication_section" 'compose-pr-body.sh' \
    'draft PR publication uses the canonical body composer'
assert_contains "$publication_section" '--why-file "$pr_why_file"' \
    'draft PR publication supplies the root-approved Why file'
assert_contains "$publication_section" '--testing-file "$pr_testing_file"' \
    'draft PR publication supplies the root-approved Testing file'
assert_contains "$publication_section" '--expect-closing-issue "$issue_number"' \
    'default-branch PR publication verifies GitHub closing linkage'
assert_contains "$publication_section" 'This was written agentically; verify its assertions:' \
    'canonical composer documents the fixed attribution banner'
assert_contains "$publication_section" 'Never pass a multiline PR body through inline `--body`' \
    'draft PR publication forbids inline multiline body strings'
assert_contains "$publication_section" 'chmod 600 -- "$pr_body_file"' \
    'draft PR publication secures the body file with mode 600'
assert_contains "$publication_section" 'agent_identity=${agent_identity:?' \
    'draft PR publication requires an LLM/service/model identity'
assert_contains "$publication_section" 'pr_why_file=${pr_why_file:?' \
    'draft PR publication requires approved Why content'
assert_contains "$publication_section" '"$agentkit/.shared/scripts/gh-body.sh" issue create --body-file "$issue_body_file"' \
    'issue creation recipe uses the byte-verifying body transport'
assert_contains "$publication_section" '"$agentkit/.shared/scripts/gh-body.sh" issue edit "$issue_number" --body-file "$issue_body_file"' \
    'issue editing recipe uses the byte-verifying body transport'
assert_contains "$publication_section" 'Stacked on #' \
    'stacked PRs keep the base disclosure in approved section content'
assert_contains "$publication_section" 'chain-advance.sh --retarget' \
    'stacked PRs use the machine retarget proof before merging'
assert_contains "$text" 'verify the successor'"'"'s baseRefName' \
    'chain merge order requires verified retargeting before a successor merges'
assert_contains "$publication_section" 'automatic retarget' \
    'stacked body explains the human auto-retarget path'
assert_contains "$text" 'merge order' 'ready-flip handoff states the chain merge order'

body_template="$tmp/body-template"
cat >"$body_template" <<'EOF'
literal `sha` and $(printf should-not-run)
__AGENT_IDENTITY__ __PR_CLOSE_LINE__
EOF
body_identity='agent & \\path\\ `identity` $(not-run)'
body_close_line='Closes &82 \\close\\ `line` $(not-run)'
body_bytes=$(<"$body_template")
body_bytes+=$'\n'
body_prefix=${body_bytes%%__AGENT_IDENTITY__*}
body_remainder=${body_bytes#*__AGENT_IDENTITY__}
body_middle=${body_remainder%%__PR_CLOSE_LINE__*}
body_suffix=${body_remainder#*__PR_CLOSE_LINE__}
body_bytes=$body_prefix$body_identity$body_middle$body_close_line$body_suffix
body_output="$tmp/body-output"
printf %s "$body_bytes" >"$body_output"
expected_body='literal `sha` and $(printf should-not-run)
agent & \\path\\ `identity` $(not-run) Closes &82 \\close\\ `line` $(not-run)
'
actual_body=$(<"$body_output")
actual_body+=$'\n'
assert_eq "$expected_body" "$actual_body" \
    'quoted body substitution preserves backticks and command substitutions byte-for-byte'

assert_eq 'yes' "$([[ -f $github_body_policy ]] && printf yes || printf no)" \
    'shared GitHub body policy exists'
body_policy=''
[[ ! -f $github_body_policy ]] || body_policy=$(<"$github_body_policy")
assert_contains "$body_policy" 'ANY multiline body handed to `gh`' \
    'shared policy covers the whole multiline GitHub body class'
assert_contains "$body_policy" '`pr create`, `pr edit`, `issue create`, `issue edit`, and `api -f body=`' \
    'shared policy names every supported GitHub body mutation surface'
assert_contains "$body_policy" '`--body-file` or `--input`' \
    'shared policy requires file-backed GitHub bodies'
assert_contains "$body_policy" 'Comments already comply through `gh-comment.sh`.' \
    'shared policy records the existing comment transport'
assert_contains "$body_policy" 'Body content is data' \
    'shared policy treats body content as data'
assert_contains "$body_policy" 'never pass through interpolating heredocs or eval-adjacent expansion' \
    'shared policy rejects expansion adjacent to body transport'
assert_contains "$text" '../.shared/github-body-policy.md' \
    'parallel-issues inherits the shared GitHub body policy'
assert_contains "$(<"$review_skill")" '../.shared/github-body-policy.md' \
    'review-remote-pr inherits the shared GitHub body policy'

ci_text=$(<"$ci_workflow")
assert_contains "$ci_text" 'shellcheck-v0.11.0.linux.x86_64.tar.xz' \
    'CI installs the documented ShellCheck release'
assert_contains "$ci_text" '8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198' \
    'CI verifies the documented ShellCheck checksum'
assert_contains "$ci_text" 'shellcheck --version' \
    'CI logs the pinned ShellCheck version'
assert_contains "$ci_text" 'curl --fail --location --silent --show-error --retry 3 --retry-delay 2 --retry-all-errors' \
    'CI retries transient pinned ShellCheck downloads'
assert_contains "$ci_text" 'install_dir="${RUNNER_TEMP}/shellcheck-v${version}/bin"' \
    'CI installs ShellCheck into a persistent versioned runner-temp directory'
assert_contains "$ci_text" 'printf '\''%s\n'\'' "$install_dir" >>"$GITHUB_PATH"' \
    'CI exports the persistent ShellCheck directory across workflow steps'
assert_not_contains "$ci_text" 'printf '\''%s\n'\'' "$download_dir" >>"$GITHUB_PATH"' \
    'CI never exports the cleaned download scratch directory'
assert_not_contains "$ci_text" 'apt-get install -y -qq shellcheck' \
    'CI has no unpinned apt ShellCheck install path'

inline_body_recipes=$(sed -nE '/^[[:space:]]*gh[[:space:]]/ {
    /(^|[[:space:]])--body([=[:space:]]|$)/p
    /api.*(^|[[:space:]])(-f|--field)[[:space:]]+body=/p
}' "$skill" "$review_skill")
assert_eq '' "$inline_body_recipes" \
    'skill recipes never pass multiline GitHub bodies inline'

# Root safeguards are asserted only in bounded orchestration/publication
# sections. Worker prompt prose may mention the same words with different
# ownership semantics and must not satisfy these root-only checks.
root_sections=$(
    sed -n '/^### Root canonical issue fetch and fence preparation$/,/^Per-issue prompt:$/p' "$skill"
    sed -n '/^### Root review and draft PR after a worker push$/,/^### Polling discipline/p' "$skill"
    sed -n '/^## Runtime and provider neutrality$/,/^## Automated review provider rules/p' "$review_skill"
    sed -n '/^## Implementation-worker gate$/,/^## Worker-owned publication$/p' "$worker_gate"
    sed -n '/^## Worker-owned publication$/,$p' "$worker_gate"
    sed -n '/^## Step 0: Setup/,/^## Step 3 (Phase B)/p' "$review_skill"
)
assert_contains "$root_sections" 'never rebase' 'root-facing prose preserves merge-never-rebase guard'
assert_contains "$root_sections" 'git add -A' 'root-facing prose preserves explicit staging guard'
assert_contains "$root_sections" 'peer-cli= <name> absent' 'root-facing prose owns peer availability'
assert_contains "$root_sections" 'blind same-harness fallback' 'root-facing prose owns blind fallback'
worker_gate_flat=$(tr '\n' ' ' <<<"$worker_gate_text" | tr -s '[:space:]' ' ')
assert_contains "$worker_gate_flat" 'Workers commit and push their own branch' \
    'worker-gate.md pins worker-owned publication'
assert_contains "$worker_gate_flat" 'completion report' \
    'worker-gate.md pins the worker completion report'
assert_contains "$worker_gate_flat" 'Environment-refusal fallback' \
    'worker-gate.md keeps handback only for environment refusal'
assert_contains "$worker_gate_flat" 'worktree-commit.sh` exits 2' \
    'worker-gate.md distinguishes commit refusal'
assert_contains "$worker_gate_flat" 'push was refused after the commit succeeded' \
    'worker-gate.md distinguishes push refusal after commit'
assert_not_contains "$worker_gate_flat" 'Workers are turn-and-burn' \
    'worker-gate.md removes the turn-and-burn handback contract'
assert_not_contains "$worker_gate_flat" 'leave progress unstaged' \
    'worker-gate.md removes unstaged handback from the primary flow'
assert_not_contains "$worker_gate_flat" 'root-owned publication handback' \
    'worker-gate.md no longer presents root publication as the primary flow'
assert_contains "$worker_gate_flat" 'purely mechanical' \
    'worker-gate.md limits inline corrections to mechanical changes'
assert_contains "$worker_gate_flat" 'no new behavior, data shape, or control flow' \
    'worker-gate.md excludes behavioral inline corrections'
assert_contains "$worker_gate_flat" 'at most five changed lines' \
    'worker-gate.md bounds inline corrections to five lines'
assert_contains "$worker_gate_flat" 'root authored the exact diff' \
    'worker-gate.md requires root-authored inline diffs'
assert_contains "$worker_gate_flat" 'full declared verification' \
    'worker-gate.md requires verification after inline corrections'
assert_contains "$worker_gate_flat" 'root harness attribution' \
    'worker-gate.md requires root attribution for inline corrections'
assert_contains "$worker_gate_flat" 'recorded reason' \
    'worker-gate.md requires recording why the worker gate was skipped'
assert_contains "$root_review_section" 'resume the same worker with `followup_task` first' \
    'root review resumes the same worker before considering a fresh dispatch'
assert_contains "$root_review_section" 'inline correction' \
    'root review names the inline-correction decision at the correction call site'
assert_contains "$root_review_section" 'zero dispatches' \
    'root review records that qualifying inline corrections cost zero dispatches'
assert_contains "$text" 'two allowed implementation exceptions' \
    'parallel preflight names the complete implementation exception set'
assert_contains "$text" 'qualifying bounded inline correction' \
    'parallel preflight names bounded inline correction as an implementation exception'
assert_contains "$worker_gate_flat" 'continues the existing PR' \
    'worker-gate.md keeps review-remote-pr on the existing PR'
assert_contains "$worker_gate_flat" 'CI, reply, review, and metadata cycle' \
    'worker-gate.md names the existing PR follow-up responsibilities'
assert_not_contains "$worker_gate_flat" 'opens a DRAFT PR' \
    'worker-gate.md does not create a draft PR for an existing review'
assert_contains "$issue_lead_prompt" 'Read the authoritative `instructions=` line from `.agent/env-contract.txt`' \
    'issue leads use the preflight instruction contract'
assert_contains "$draft_loop_prompt" 'Use the authoritative `instructions=` line from `.agent/env-contract.txt`; inspect only' \
    'draft-loop workers use the bounded instruction contract'

# The outer four-backtick fence lives in references/worker-prompts.md now
# (issue #107's split); SKILL.md's body carries a pointer, never the fence.
outer_open_count=$(awk '$0 == "````text" { count++ } END { print count + 0 }' "$worker_prompts")
outer_close_count=$(awk '$0 == "````" { count++ } END { print count + 0 }' "$worker_prompts")
assert_eq '1' "$outer_open_count" \
    'the per-issue prompt has one four-backtick opening fence'
assert_eq '1' "$outer_close_count" \
    'the per-issue prompt has one four-backtick closing fence'
assert_eq '0' "$(awk '$0 == "````text" { count++ } END { print count + 0 }' "$skill")" \
    'SKILL.md carries no outer four-backtick fence of its own'

prompt_body=$(awk '
    $0 == "````text" { capture=1; next }
    capture && $0 == "````" { exit }
    capture { print }
' "$worker_prompts")
assert_contains "$prompt_body" '<PASTE the complete output selected by the boundary mode' \
    'the prompt placeholders remain inside the outer fence'
assert_contains "$issue_lead_prompt" \
    '<PASTE the complete output selected by the boundary mode for the approved design-doc contents or full issue body>' \
    'the issue-lead prompt carries the Spec placeholder individually'
assert_contains "$issue_lead_prompt" \
    '<PASTE the complete output selected by the boundary mode for the Step 2 prior-art verdicts; say "none" when empty>' \
    'the issue-lead prompt carries the Prior art placeholder individually'
inner_open_count=$(printf '%s\n' "$prompt_body" | awk '$0 == "```bash" { count++ } END { print count + 0 }')
inner_close_count=$(printf '%s\n' "$prompt_body" | awk '$0 == "```" { count++ } END { print count + 0 }')
# One inner bash example remains (`git branch --show-current`); the
# public-fenced `cat` recipe block was removed from the raw template
# (issue #334) -- compose-worker-prompt.sh now embeds the persisted bytes
# for every mode itself, so the worker prompt no longer documents a
# hand-copied recipe for the worker to run.
assert_eq '1' "$inner_open_count" \
    'inner bash examples retain their triple-backtick openings'
assert_eq '1' "$inner_close_count" \
    'inner bash examples retain their triple-backtick closers'

cap_helper="$root/agentkit/skills/parallel-issues/scripts/concurrency-cap.sh"
assert_eq yes "$( [[ -x $cap_helper ]] && printf yes || printf no )" \
    'concurrency cap helper is executable'
configured_home="$tmp/configured"
mkdir -p "$configured_home/.codex"
printf '%s\n' '[multi_agent_v2]' 'max_concurrent_threads_per_session = 10' \
    > "$configured_home/.codex/config.toml"
out=$("$cap_helper" --config "$configured_home/.codex/config.toml" 2>/dev/null)
status=$?
assert_contains "$out" 'runtime concurrency cap: 10 total threads, including the root' \
    'dispatch advertises the configured runtime cap'
assert_eq '0' "$status" 'an advertised cap exits zero'

codex_home="$tmp/codex-home"
mkdir -p "$codex_home"
printf '%s\n' '[multi_agent_v2]' 'max_concurrent_threads_per_session = 7' \
    > "$codex_home/config.toml"
out=$("$cap_helper" --config "$codex_home/config.toml" 2>/dev/null)
assert_contains "$out" 'runtime concurrency cap: 7 total threads, including the root' \
    'a CODEX_HOME override is honored over $HOME/.codex'

# --- issue #273: size facts never park an unattended run --------------------
# The 2026-08-18 cable-tool incident: a worker finished (implemented,
# committed, pushed, tests green) and the root dead-ended one step short of
# the draft PR, inventing a "fastlane" size gate the kit never declared. The
# fix states the unattended default at both places the incident touched: the
# Diff-size facts section (the flag/fact contract) and the Collect
# completion-report bullet (the exact spine point between a finished worker
# and PR creation). The disclosure recipe itself lives in worker-prompts.md,
# not the body, per the strong preference to land detail in references.
assert_contains "$text" 'Size facts never park an unattended run' \
    'diff-size facts state the unattended default explicitly'
assert_contains "$text" 'never authorize skipping' \
    'diff-size facts still forbid skipping review or chunking on facts alone'
assert_contains "$text" 'references/worker-prompts.md](references/worker-prompts.md#diff-size-disclosure)' \
    'diff-size facts point at the worker-prompts disclosure recipe'
assert_contains "$text" 'Diff size is never a reason to withhold this' \
    'the Collect completion-report bullet carries the same no-park rule'
assert_contains "$worker_prompts_text" '### Diff-size disclosure' \
    'worker-prompts.md carries the diff-size disclosure subsection'
assert_contains "$worker_prompts_text" '"$agentkit/.shared/scripts/diff-facts.sh" --repo-root "$worktree"' \
    'the disclosure recipe runs diff-facts.sh against the worktree'
assert_contains "$worker_prompts_text" '--base "${chain_base_sha:-origin/$base}"' \
    'the disclosure recipe pins the chain base for a chained issue'
assert_contains "$worker_prompts_text" '>> "$pr_decisions_file"' \
    'the disclosure recipe folds facts into the Decisions section, not a separate gate'
assert_contains "$worker_prompts_text" 'still gets the same draft PR a small one gets' \
    'the disclosure recipe states parity between over-guideline and small packets'
assert_contains "$worker_prompts_text" 'is never an unattended default' \
    'the disclosure recipe states trimming is attended-only, never automatic'

# The end-of-draft adversarial review on PR #280 confirmed a P2: the first
# draft of the disclosure recipe stood alone as its own code fence, ahead of
# the block that establishes $pr_decisions_file and $agentkit -- under
# `set -euo pipefail` that aborts the whole draft-PR recipe on an unbound
# variable, for every workstream, which is worse than the stall this issue
# exists to prevent. The fix folds the diff-facts.sh call into the existing
# recipe, after both prerequisites are established. Pin the ordering
# directly so a future edit cannot silently pull it back out ahead of them.
mapfile -t pub_lines <<< "$publication_section"
decisions_guard_idx=-1 resolver_guard_idx=-1 diff_facts_idx=-1 compose_idx=-1
for _pub_i in "${!pub_lines[@]}"; do
    _pub_line=${pub_lines[$_pub_i]}
    if ((decisions_guard_idx < 0)) && [[ $_pub_line == *'pr_decisions_file=${pr_decisions_file:?'* ]]; then
        decisions_guard_idx=$_pub_i
    fi
    if ((resolver_guard_idx < 0)) && [[ $_pub_line == *'agentkit unresolved: prepend the Step 0 resolver block'* ]]; then
        resolver_guard_idx=$_pub_i
    fi
    if ((diff_facts_idx < 0)) && [[ $_pub_line == *'"$agentkit/.shared/scripts/diff-facts.sh" --repo-root "$worktree"'* ]]; then
        diff_facts_idx=$_pub_i
    fi
    if ((compose_idx < 0)) && [[ $_pub_line == *'"$agentkit/parallel-issues/scripts/compose-pr-body.sh"'* ]]; then
        compose_idx=$_pub_i
    fi
done
assert_eq yes "$([[ $decisions_guard_idx -ge 0 && $diff_facts_idx -ge 0 && $diff_facts_idx -gt $decisions_guard_idx ]] && printf yes || printf no)" \
    'the disclosure recipe runs after $pr_decisions_file is guarded, never before'
assert_eq yes "$([[ $resolver_guard_idx -ge 0 && $diff_facts_idx -ge 0 && $diff_facts_idx -gt $resolver_guard_idx ]] && printf yes || printf no)" \
    'the disclosure recipe runs after the resolver establishes $agentkit, never before'
assert_eq yes "$([[ $compose_idx -ge 0 && $diff_facts_idx -ge 0 && $diff_facts_idx -lt $compose_idx ]] && printf yes || printf no)" \
    'the disclosure recipe runs before compose-pr-body.sh consumes the Decisions file'

v1_home="$tmp/v1-home"
mkdir -p "$v1_home"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 10' 'max_depth = 2' \
    > "$v1_home/config.toml"
out=$("$cap_helper" --config "$v1_home/config.toml" 2>/dev/null)
status=$?
assert_contains "$out" 'runtime concurrency cap: 10 total threads, including the root' \
    'the v1 [agents] section advertises the cap'
assert_eq '0' "$status" 'a v1 [agents] cap exits zero'

v2_home="$tmp/v2-home"
mkdir -p "$v2_home"
printf '%s\n' '[features.multi_agent_v2]' 'enabled = true' \
    'max_concurrent_threads_per_session = 8' > "$v2_home/config.toml"
out=$("$cap_helper" --config "$v2_home/config.toml" 2>/dev/null)
status=$?
assert_contains "$out" 'runtime concurrency cap: 8 total threads, including the root' \
    'the v2 [features.multi_agent_v2] section advertises the cap'
assert_eq '0' "$status" 'a v2 [features.multi_agent_v2] cap exits zero'

commented_home="$tmp/commented-home"
mkdir -p "$commented_home"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 10' \
    '# [features.multi_agent_v2]' '# max_concurrent_threads_per_session = 99' \
    > "$commented_home/config.toml"
out=$("$cap_helper" --config "$commented_home/config.toml" 2>/dev/null)
assert_contains "$out" 'runtime concurrency cap: 10 total threads, including the root' \
    'a commented-out v2 block does not shadow the live [agents] cap'

missing_home="$tmp/missing"
mkdir -p "$missing_home"
err=$("$cap_helper" --config "$missing_home/config.toml" 2>&1 >/dev/null)
status=$?
assert_contains "$err" 'Unable to advertise concurrency' \
    'missing runtime config explains why the cap is unavailable'
assert_eq 'nonzero' "$( (( status != 0 )) && printf nonzero || printf zero )" \
    'missing runtime config exits nonzero so dispatch stops'

# --- issue #224: named wait bounds (WS1) --------------------------------------
# The guidance must name a NUMBER per wait class, and every named bound must be
# at least 600 seconds -- "an explicit bound" without a duration measured out as
# the ~110 s harness default and two hours of empty timed-out waits.
normalized_wait_text=$(tr '\n' ' ' <<<"$wait_discipline_text" | tr -s '[:space:]' ' ')
assert_contains "$normalized_wait_text" 'Default numeric bounds per wait class' \
    'wait discipline documents default numeric bounds'
mapfile -t documented_bounds < <(grep -oE '\*\*[0-9]+ s\*\*' <<<"$wait_discipline_text" | grep -oE '[0-9]+')
assert_eq 'yes' "$( ((${#documented_bounds[@]} >= 2)) && printf yes || printf no )" \
    'wait discipline names at least two numeric class bounds'
for bound in "${documented_bounds[@]}"; do
    assert_eq 'yes' "$( ((bound >= 600)) && printf yes || printf no )" \
        "documented wait bound $bound s is at least 600 s"
done
assert_contains "$normalized_wait_text" 'never be re-issued at the same duration' \
    'a timed-out wait escalates instead of repeating'
assert_contains "$normalized_text" '**900 s** minimum, draft-loop/review/CI waits **600 s**' \
    'parallel skill names the numeric bound at its wait sites'

# --- issue #224: stall detection as a rule (WS4) ------------------------------
assert_contains "$text" 'stall-check.sh' \
    'collect loop names the stall-check helper'
assert_contains "$text" 'STALL_THRESHOLD_MINUTES' \
    'stall threshold is a named constant'
assert_contains "$normalized_text" 're-dispatch it once with the preserved worktree evidence' \
    'a stalled worker gets exactly one automatic re-dispatch'
assert_contains "$normalized_text" 'park the workstream and name it in the report' \
    'a twice-stalled workstream parks and is named'
assert_contains "$normalized_text" 'never `pgrep`' \
    'stall detection forbids process inspection'
assert_contains "$normalized_text" 'newest file mtime is the liveness signal' \
    'stall detection is defined by worktree mtime'

# --- issue #224: materiality gate before the review spend (WS2b) --------------
assert_contains "$text" 'materiality-check.sh' \
    'draft loops call the mechanical materiality gate'
assert_contains "$normalized_text" 'a skip records *why*, never silence' \
    'a materiality skip is recorded, never silent'

# --- issue #224: effort follows the issue (WS3) -------------------------------
assert_contains "$triage_and_selection_text" 'workerEffort' \
    'dispatch-plan entries may carry a per-issue effort override'
assert_contains "$triage_and_selection_text" 'effortReason' \
    'a per-issue effort override records its reason'
assert_contains "$normalized_text" 'Effort follows the issue, not the run' \
    'parallel skill states the per-issue effort rule'

# --- issue #224: authorization checked once against the ledger (WS6) ----------
assert_contains "$normalized_text" 'Authorization is checked once per run, not per command' \
    'parallel skill checks authorization once per run'
assert_contains "$text" 'covers --ledger' \
    'the once-per-run check uses the ledger covers subcommand'
assert_contains "$normalized_text" 'A mutation no recorded decision covers still stops' \
    'an uncovered mutation still stops'

# --- issue #224: references read once (WS2d); issue #336 reconciles the size
# probe with this skill's own size. The blanket prohibition and a 1000+ line
# mandatory read were jointly untenable: sizing is still barred as a routine
# habit, with ONE bounded exception for a large first read.
assert_contains "$normalized_text" 'References are read once and batched' \
    'parallel skill still reads each reference once, in batches'
assert_contains "$text" 'wc -l' \
    'the no-sizing rule names the observed probe explicitly'
assert_contains "$normalized_text" 'per-file sizing spends one root turn per file' \
    'the no-sizing default names its cost'
assert_contains "$normalized_text" 'may take one bounded size probe' \
    'a large first read may be sized once'
assert_contains "$normalized_text" 'this SKILL.md included' \
    'the size-probe exception admits this skill is over the threshold'
assert_not_contains "$normalized_text" 'nothing in this skill consumes a line count' \
    'the skill no longer claims nothing consumes a line count while permitting a probe'

assert_contains "$text" 'Root-checkout cross-write fence' \
    'dispatch documents the root dirt snapshot boundary'
assert_contains "$text" 'cross-write-check.sh' \
    'dispatch names the deterministic cross-write checker'
assert_contains "$normalized_text" 'Never fold dirt first observed inside a dispatch window' \
    'handoff never misattributes run-window dirt to the human'
assert_contains "$worker_prompts_text" 'paths-touched.ndjson' \
    'worker prompts preserve per-tool write-target evidence'

# --- issue #254: Collect detects, attributes, and disposes cross-writes -----
cross_write="$root/agentkit/skills/parallel-issues/scripts/cross-write-check.sh"
assert_eq yes "$( [[ -x $cross_write ]] && printf yes || printf no )" \
    'cross-write checker is executable'

cross_root="$tmp/cross-root"
cross_worker="$tmp/cross-worker"
mkdir -p "$cross_root"
git -C "$cross_root" init -q -b main
cross_exclude=$(git -C "$cross_root" rev-parse --git-path info/exclude)
[[ $cross_exclude == /* ]] || cross_exclude="$cross_root/$cross_exclude"
printf '.agent/*\n.worktrees/\n' >> "$cross_exclude"
mkdir -p "$cross_root/src" "$cross_root/.agent"
printf 'base\n' > "$cross_root/src/data.txt"
git -C "$cross_root" add src/data.txt
git -C "$cross_root" -c user.name=t -c user.email=t@example.invalid \
    commit -qm base
git -C "$cross_root" worktree add -q -b feat/worker "$cross_worker"
printf 'worker bytes\n' > "$cross_worker/src/data.txt"

snapshot="$cross_root/.agent/cross-write.snapshot"
snapshot_out=$(
    "$cross_write" snapshot --root "$cross_root" --output "$snapshot" \
        --write-set 'src/**'
)
assert_contains "$snapshot_out" 'snapshot=' \
    'dispatch snapshot reports its persisted path'

# Porcelain -z must preserve spaces and non-ASCII path bytes instead of
# silently dropping Git's quoted representation.
printf 'worker space\n' > "$cross_worker/src/space café.txt"
printf 'worker space\n' > "$cross_root/src/space café.txt"
space_out=$(
    "$cross_write" collect --root "$cross_root" --snapshot "$snapshot" \
        --worker-worktree "$cross_worker" --issue 254 \
        --worker-start 1 --worker-end 2147483647 --write-set 'src/**' || true
)
assert_contains "$space_out" 'src/space café.txt' \
    'Collect preserves a space and non-ASCII path from NUL-delimited status'
rm -- "$cross_root/src/space café.txt"

# A single-star component cannot cross a path separator; globstar remains
# recursive. Both cases are exercised through the public Collect interface.
mkdir -p "$cross_root/src/nested"
mkdir -p "$cross_worker/src/nested"
printf 'nested worker\n' > "$cross_worker/src/nested/deep.txt"
printf 'nested worker\n' > "$cross_root/src/nested/deep.txt"
single_star_out=$(
    "$cross_write" collect --root "$cross_root" --snapshot "$snapshot" \
        --worker-worktree "$cross_worker" --issue 254 \
        --worker-start 1 --worker-end 2147483647 --write-set 'src/*' || true
)
assert_not_contains "$single_star_out" 'src/nested/deep.txt' \
    'a single-star write-set does not cross a directory component'
recursive_out=$(
    "$cross_write" collect --root "$cross_root" --snapshot "$snapshot" \
        --worker-worktree "$cross_worker" --issue 254 --worker-start 1 \
        --worker-end 2147483647 --write-set 'src/**' || true
)
assert_contains "$recursive_out" 'src/nested/deep.txt' \
    'a recursive write-set matches nested paths'
rm -- "$cross_root/src/nested/deep.txt"

# Collect must never compare or dispose the observation checkout with itself.
self_err=$(
    "$cross_write" collect --root "$cross_root" --snapshot "$snapshot" \
        --worker-worktree "$cross_root" --issue 254 --write-set 'src/**' \
        2>&1 >/dev/null
)
self_rc=$?
assert_eq 2 "$self_rc" 'Collect rejects the root checkout as its worker worktree'
assert_contains "$self_err" 'must differ from root' \
    'self-worktree rejection explains the destructive hazard'

# Plant the same bytes in the root checkout. Collect must attribute this to the
# worker window, compare it to the matching branch worktree, and restore the
# root to its exact pre-dispatch state when explicitly asked to dispose it.
printf 'worker bytes\n' > "$cross_root/src/data.txt"
now=$(date +%s)
collect_out=$(
    "$cross_write" collect --root "$cross_root" --snapshot "$snapshot" \
        --worker-worktree "$cross_worker" --issue 254 \
        --worker-start $((now - 5)) --worker-end $((now + 5)) \
        --write-set 'src/**' --dispose-duplicates
)
assert_contains "$collect_out" 'cross-write=' \
    'Collect names the planted cross-write'
assert_contains "$collect_out" 'issue=254' \
    'Collect attributes the incident to the worker window'
assert_contains "$collect_out" 'disposition=restored-exact-duplicate' \
    'Collect disposes an exact branch duplicate explicitly'
assert_eq '' "$(git -C "$cross_root" status --porcelain --untracked-files=all)" \
    'disposing an exact duplicate restores root cleanliness'
assert_eq 'base' "$(<"$cross_root/src/data.txt")" \
    'duplicate disposal restores the root bytes from HEAD'

printf 'worker bytes\n' > "$cross_root/src/data.txt"
outside_window_out=$(
    "$cross_write" collect --root "$cross_root" --snapshot "$snapshot" \
        --worker-worktree "$cross_worker" --issue 254 --worker-start 1 --worker-end 1 \
        --write-set 'src/**' --dispose-duplicates
)
assert_contains "$outside_window_out" 'disposition=surface-exact-outside-window' \
    'an exact copy outside the worker mtime window is not auto-disposed'
assert_eq 'worker bytes' "$(<"$cross_root/src/data.txt")" \
    'outside-window exact bytes remain for explicit disposition'
git -C "$cross_root" restore --source=HEAD --worktree -- src/data.txt

# A path that was already dirty at snapshot time is never auto-disposed when a
# worker overwrites those human bytes. The overwrite remains visible.
printf 'human pre-dispatch bytes\n' > "$cross_root/src/data.txt"
baseline_snapshot="$cross_root/.agent/cross-write-baseline.snapshot"
"$cross_write" snapshot --root "$cross_root" --output "$baseline_snapshot" \
    --write-set 'src/**' >/dev/null
printf 'worker bytes\n' > "$cross_root/src/data.txt"
baseline_out=$(
    "$cross_write" collect --root "$cross_root" --snapshot "$baseline_snapshot" \
        --worker-worktree "$cross_worker" --issue 254 --worker-start 1 \
        --worker-end 2147483647 --write-set 'src/**' --dispose-duplicates || true
)
assert_contains "$baseline_out" 'surface-overwrote-baseline' \
    'a worker overwrite of pre-existing human bytes is surfaced'
assert_eq 'worker bytes' "$(<"$cross_root/src/data.txt")" \
    'baseline-overwrite handling never auto-restores the root path'
git -C "$cross_root" restore --source=HEAD --worktree -- src/data.txt

# An unreadable hash sentinel is not a stable byte value. Even when baseline
# and current both report "unreadable", Collect must surface the incident and
# leave the root bytes untouched rather than auto-disposing an alleged match.
hash_stub="$tmp/hash-stub"
mkdir -p "$hash_stub"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$hash_stub/sha256sum"
chmod 700 -- "$hash_stub/sha256sum"
printf 'human unreadable baseline\n' > "$cross_root/src/data.txt"
unreadable_snapshot="$cross_root/.agent/cross-write-unreadable.snapshot"
PATH="$hash_stub:$PATH" "$cross_write" snapshot --root "$cross_root" \
    --output "$unreadable_snapshot" --write-set 'src/**' >/dev/null
printf 'worker bytes\n' > "$cross_root/src/data.txt"
unreadable_out=$(
    PATH="$hash_stub:$PATH" "$cross_write" collect --root "$cross_root" \
        --snapshot "$unreadable_snapshot" --worker-worktree "$cross_worker" \
        --issue 254 --worker-start 1 --worker-end 2147483647 \
        --write-set 'src/**' --dispose-duplicates || true
)
assert_contains "$unreadable_out" 'surface-unreadable' \
    'unreadable baseline/current hashes are surfaced as an incident'
assert_eq 'worker bytes' "$(<"$cross_root/src/data.txt")" \
    'unreadable hash handling never auto-disposes the root path'
git -C "$cross_root" restore --source=HEAD --worktree -- src/data.txt

# A divergent root copy is still an incident, but must be surfaced rather than
# silently overwritten by the matching worker branch.
printf 'divergent root bytes\n' > "$cross_root/src/data.txt"
divergent_out=$(
    "$cross_write" collect --root "$cross_root" --snapshot "$snapshot" \
        --worker-worktree "$cross_worker" --issue 254 \
        --worker-start 1 --worker-end 2147483647 \
        --write-set 'src/**'
)
assert_contains "$divergent_out" 'disposition=surface-divergent' \
    'Collect surfaces a divergent cross-write for explicit human disposition'
assert_eq 'divergent root bytes' "$(<"$cross_root/src/data.txt")" \
    'divergent disposal never overwrites the root copy'

# Disposal resolves parent symlinks before hashing or removing anything. A
# lexical path under the checkout that lands outside it is refused and leaves
# the outside target untouched.
dispose_outside="$tmp/cross-dispose-outside"
mkdir -p "$dispose_outside" "$cross_worker/src/unsafe"
printf 'outside bytes\n' > "$dispose_outside/escape.txt"
ln -s "$dispose_outside" "$cross_root/src/unsafe"
printf 'worker unsafe bytes\n' > "$cross_worker/src/unsafe/escape.txt"
dispose_err=$(
    "$cross_write" dispose --root "$cross_root" --worker-worktree "$cross_worker" \
        --path src/unsafe/escape.txt 2>&1 >/dev/null
)
dispose_rc=$?
assert_eq 2 "$dispose_rc" 'disposal rejects a symlinked parent outside the root'
assert_contains "$dispose_err" 'escapes root' \
    'symlink disposal refusal explains the containment failure'
assert_eq 'outside bytes' "$(<"$dispose_outside/escape.txt")" \
    'refused disposal does not touch the outside target'

# --- harness-aware worker model resolution (issue #301) --------------------
# AGENT_WORKER_MODEL is Codex-shaped data by convention (gpt-5.6-*); a Claude
# session reading it unmodified stopped for authorization on every run. The
# spawn contract must re-resolve per the running harness instead of stopping
# on a cross-harness declaration.
spawn_contract="$root/agentkit/skills/.shared/spawn-contract.md"
spawn_contract_text=$(<"$spawn_contract")
spawn_contract_flat=$(tr '\n' ' ' <<<"$spawn_contract_text" | tr -s '[:space:]' ' ')

assert_contains "$spawn_contract_text" '### Harness-aware pivot' \
    'spawn contract names the harness-aware pivot subsection'
assert_contains "$spawn_contract_text" '--get harness.name' \
    'spawn contract resolves the running harness from the environment contract'
assert_contains "$spawn_contract_text" 'claude-sonnet-5' \
    'spawn contract documents the native Claude worker tier'
assert_contains "$spawn_contract_flat" "pivoted from cross-harness declaration" \
    'spawn contract records a cross-harness pivot by name'
assert_contains "$spawn_contract_flat" 'Never pivot a same-family value that merely fails the' \
    'spawn contract never silently pivots a same-family unsanctioned declaration'
assert_contains "$spawn_contract_flat" 'explicit user authorization required' \
    'spawn contract still stops a same-harness unsanctioned declaration'
assert_not_contains "$spawn_contract_text" 'AGENT_WORKER_MODEL_CODEX' \
    'spawn contract does not introduce a second, harness-keyed declaration key'
assert_contains "$spawn_contract_flat" 'so a substitution is always evidence, never inferred' \
    'spawn contract requires the completion table to record a pivot'
# The pre-existing Codex-scoped gate paragraph must survive untouched: it is
# pinned verbatim by test-skills-contract.sh and remains true on Codex.
assert_contains "$spawn_contract_flat" \
    'sanctioned no-extra-authorization model set is exactly **`gpt-5.6-luna`** and **`gpt-5.6-terra`**' \
    'spawn contract keeps the original Codex sanctioned-set sentence intact'

# Text assertions above cannot catch a subshell/exit-status bug: a resolver
# helper wrapped in `$(...)` forks a subshell, and an `exit 1` inside it only
# kills that subshell while the real script runs on with an empty resolved
# value -- silently defeating the authorization stop this gate exists for.
# Execute the actual extracted fence against real fixtures so that class of
# bug fails a test, not just a live spike.
spawn_fence="$tmp/spawn-contract-fence.sh"
awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$spawn_contract" > "$spawn_fence"

run_spawn_fence() {
    # $1=harness $2=config.env contents
    local harness=$1 config=$2 fixture
    fixture=$(mktemp -d "$tmp/fence-fixture.XXXXXX")
    mkdir -p "$fixture/.agent"
    git -C "$fixture" init -q
    printf '%s' "$config" > "$fixture/.agent/config.env"
    printf 'harness= name=%s trailer="X <noreply@example.com>" other=none\n' "$harness" \
        > "$fixture/.agent/env-contract.txt"
    {
        printf 'agentkit=%q\n' "$root/agentkit/skills"
        printf 'agentkit_provenance=ok\n'
        printf 'repository_root=%q\n' "$fixture"
        cat "$spawn_fence"
        printf 'printf "%%s %%s %%s\\n" "$worker_model" "$worker_model_fallback" "$model_pivot_note"\n'
    } > "$tmp/fence-run.sh"
    bash "$tmp/fence-run.sh" 2>/dev/null
}

# Mirrors the "During capability selection" bullet in spawn-contract.md's
# Model/effort selection section verbatim: selected_worker_pivot_note binds to
# whichever slot's own note applies, at the same moment selected_worker_model
# does. Executed as real bash (not re-described) so a doc/behavior drift here
# fails a test, the same way the resolution bug above did.
run_spawn_fence_selection() {
    # $1=harness $2=config $3=preferred_advertised(yes/no)
    local harness=$1 config=$2 preferred_advertised=$3 fixture
    fixture=$(mktemp -d "$tmp/fence-fixture.XXXXXX")
    mkdir -p "$fixture/.agent"
    git -C "$fixture" init -q
    printf '%s' "$config" > "$fixture/.agent/config.env"
    printf 'harness= name=%s trailer="X <noreply@example.com>" other=none\n' "$harness" \
        > "$fixture/.agent/env-contract.txt"
    {
        printf 'agentkit=%q\n' "$root/agentkit/skills"
        printf 'agentkit_provenance=ok\n'
        printf 'repository_root=%q\n' "$fixture"
        cat "$spawn_fence"
        printf 'if [[ %q == yes ]]; then\n' "$preferred_advertised"
        printf '    selected_worker_model=$worker_model\n'
        printf '    selected_worker_pivot_note=$model_pivot_note\n'
        printf 'else\n'
        printf '    selected_worker_model=$worker_model_fallback\n'
        printf '    selected_worker_pivot_note=$fallback_pivot_note\n'
        printf 'fi\n'
        printf 'printf "%%s|%%s\\n" "$selected_worker_model" "$selected_worker_pivot_note"\n'
    } > "$tmp/fence-selection-run.sh"
    bash "$tmp/fence-selection-run.sh" 2>/dev/null
}

codex_declared_config=$'AGENT_WORKER_MODEL=gpt-5.6-luna\nAGENT_WORKER_MODEL_FALLBACK=gpt-5.6-terra\n'
claude_out=$(run_spawn_fence claude "$codex_declared_config")
claude_rc=$?
assert_eq 0 "$claude_rc" 'a Claude session on a Codex-declared repo dispatches with no round trip'
assert_contains "$claude_out" 'claude-sonnet-5 claude-sonnet-5' \
    'a Claude session pivots both slots to its native worker tier'
assert_contains "$claude_out" "pivoted from cross-harness declaration 'gpt-5.6-luna'" \
    'the pivot is recorded for the completion table, not silently applied'

codex_out=$(run_spawn_fence codex "$codex_declared_config")
codex_rc=$?
assert_eq 0 "$codex_rc" 'a Codex session on the same repo is unchanged'
assert_contains "$codex_out" 'gpt-5.6-luna gpt-5.6-terra' \
    'a Codex session resolves its own declared models verbatim, with no pivot'

# The regression this bug produced: an unsanctioned same-harness model must
# actually terminate the script (nonzero exit, no further output), not just
# print a warning and continue on an empty resolved value.
typo_config=$'AGENT_WORKER_MODEL=gpt-5.6-luna\nAGENT_WORKER_MODEL_FALLBACK=gpt-5.6-sol\n'
typo_out=$(run_spawn_fence codex "$typo_config")
typo_rc=$?
assert_eq 1 "$typo_rc" \
    'an unsanctioned same-harness fallback (AGENT_WORKER_MODEL_FALLBACK validated) actually stops the script'
assert_eq '' "$typo_out" \
    'a stopped resolution prints nothing further -- the exit is real, not confined to a subshell'

# A foreign-family value is only a pivot candidate when it is ITSELF the
# sanctioned worker tier on its own harness. claude-opus-5 is a real Claude
# model id (the root/reviewer tier, per Tier mapping) but is NOT the sanctioned
# Claude WORKER tier -- pattern-matching the family alone must not silently
# substitute a Codex model for it; this is an unsupported configured model and
# must stop for explicit authorization, the same as any other unsanctioned value.
foreign_unsanctioned_config=$'AGENT_WORKER_MODEL_FALLBACK=claude-opus-5\n'
foreign_out=$(run_spawn_fence codex "$foreign_unsanctioned_config")
foreign_rc=$?
assert_eq 1 "$foreign_rc" \
    'a foreign-family value that is not its own harness sanctioned worker tier stops, not pivots'
assert_eq '' "$foreign_out" \
    'the foreign-unsanctioned stop actually terminates the script'

# CodeRabbit finding on PR #314: the pivot notes are per-slot, but selection
# only bound selected_worker_model -- a fallback selected after a
# cross-harness pivot had no bound note of its own for the completion table.
# Preferred advertised: the note must be the PREFERRED slot's own pivot note.
preferred_selection=$(run_spawn_fence_selection claude "$codex_declared_config" yes)
assert_contains "$preferred_selection" 'claude-sonnet-5|' \
    'selecting the preferred model selects its own resolved value'
assert_contains "$preferred_selection" "pivoted from cross-harness declaration 'gpt-5.6-luna'" \
    'the preferred selection carries the PREFERRED slot'"'"'s own pivot note'
assert_not_contains "$preferred_selection" 'gpt-5.6-terra' \
    'the preferred selection does not leak the fallback slot'"'"'s note'

# Fallback advertised (preferred not): the note must be the FALLBACK slot's
# own pivot note, not the preferred's (and not empty).
fallback_selection=$(run_spawn_fence_selection claude "$codex_declared_config" no)
assert_contains "$fallback_selection" 'claude-sonnet-5|' \
    'selecting the fallback model selects its own resolved value'
assert_contains "$fallback_selection" "pivoted from cross-harness declaration 'gpt-5.6-terra'" \
    'the fallback selection carries the FALLBACK slot'"'"'s own pivot note'
assert_not_contains "$fallback_selection" "declaration 'gpt-5.6-luna'" \
    'the fallback selection does not leak the preferred slot'"'"'s note'

# --- OpenCode's provider/model-id worker tier (issue #318) ------------------
# OpenCode has no fixed vendor tier: the sanctioned worker tier is whatever
# this repository declares in `provider/model-id` form, and a cross-harness
# pivot INTO OpenCode has no invented OpenCode-native model to fall back to
# -- it resolves to OpenCode's own provider-qualified address for the exact
# foreign model that was declared. These three scenarios mirror the
# claude/codex fence-execution pattern above.
opencode_declared_config=$'AGENT_WORKER_MODEL=wrzcluster/qwen3-coder\nAGENT_WORKER_MODEL_FALLBACK=wrzcluster/qwen3-coder-fast\n'
opencode_out=$(run_spawn_fence opencode "$opencode_declared_config")
opencode_rc=$?
assert_eq 0 "$opencode_rc" \
    'an OpenCode session with its own provider/model-id declared dispatches with no round trip'
assert_contains "$opencode_out" 'wrzcluster/qwen3-coder wrzcluster/qwen3-coder-fast' \
    'an OpenCode session resolves its own declared provider/model-id verbatim, with no pivot'
assert_not_contains "$opencode_out" 'pivoted' \
    'a well-formed OpenCode-native declaration never records a pivot'

codex_on_opencode_out=$(run_spawn_fence opencode "$codex_declared_config")
codex_on_opencode_rc=$?
assert_eq 0 "$codex_on_opencode_rc" \
    'a codex-shaped declaration read on OpenCode pivots rather than stopping'
assert_contains "$codex_on_opencode_out" 'openai/gpt-5.6-luna openai/gpt-5.6-terra' \
    'OpenCode pivots a codex-declared model to its own provider-qualified address, not an invented OpenCode model'
assert_contains "$codex_on_opencode_out" "pivoted from cross-harness declaration 'gpt-5.6-luna' (declared for codex) to native 'openai/gpt-5.6-luna'" \
    'the OpenCode pivot is recorded for the completion table, exactly like the claude/codex pivots above'

opencode_unsanctioned_config=$'AGENT_WORKER_MODEL=some-random-model\n'
opencode_unsanctioned_out=$(run_spawn_fence opencode "$opencode_unsanctioned_config")
opencode_unsanctioned_rc=$?
assert_eq 1 "$opencode_unsanctioned_rc" \
    'a value with no "/" is not a well-formed provider/model-id and stops on OpenCode, never pivots'
assert_eq '' "$opencode_unsanctioned_out" \
    'the OpenCode unsanctioned-value stop actually terminates the script'

# A `case` glob cannot express "exactly one '/'" -- `[^/]` matches exactly
# one character, so `[^/]*` reads as a quantified character class but is
# actually "one non-slash char, then a plain unrestricted `*`", which still
# matches a second or third '/'. With no allowlist behind this check for
# OpenCode, a malformed multi-slash value must stop just like any other
# unsanctioned value, never silently dispatch against a nonexistent model.
opencode_extra_slash_config=$'AGENT_WORKER_MODEL=provider/model/extra\nAGENT_WORKER_MODEL_FALLBACK=wrzcluster/qwen3-coder\n'
opencode_extra_slash_out=$(run_spawn_fence opencode "$opencode_extra_slash_config")
opencode_extra_slash_rc=$?
assert_eq 1 "$opencode_extra_slash_rc" \
    'a value with more than one "/" is not a well-formed provider/model-id and stops on OpenCode'
assert_eq '' "$opencode_extra_slash_out" \
    'the OpenCode extra-slash stop actually terminates the script'

opencode_undeclared_out=$(run_spawn_fence opencode '')
opencode_undeclared_rc=$?
assert_eq 1 "$opencode_undeclared_rc" \
    'OpenCode has no fixed vendor default: an OpenCode repo declaring nothing stops for explicit configuration'
assert_eq '' "$opencode_undeclared_out" \
    'the OpenCode no-declaration stop actually terminates the script, printing nothing further'

# A well-formed provider/model-id declared for a Claude/Codex repo is itself
# a foreign-family (opencode) value on those harnesses, and pivots to THEIR
# fixed native default exactly like any other foreign-family declaration --
# a pivot out of OpenCode is unaffected by OpenCode having no fixed default.
opencode_declared_on_claude_out=$(run_spawn_fence claude "$opencode_declared_config")
assert_contains "$opencode_declared_on_claude_out" 'claude-sonnet-5 claude-sonnet-5' \
    'a provider/model-id declaration read on Claude pivots to the Claude native worker tier'
assert_contains "$opencode_declared_on_claude_out" "pivoted from cross-harness declaration 'wrzcluster/qwen3-coder' (declared for opencode) to native 'claude-sonnet-5'" \
    'the pivot out of OpenCode is recorded the same way as any other cross-harness pivot'

worker_gate_flat_301=$(tr '\n' ' ' <<<"$worker_gate_text" | tr -s '[:space:]' ' ')
assert_contains "$worker_gate_flat_301" 'harness-aware' \
    'worker gate points to harness-aware resolution rather than restating it'
assert_not_contains "$worker_gate_flat_301" 'gpt-5.6-luna' \
    'worker gate never hardcodes a Codex model id itself -- it defers to spawn-contract.md'

finish
