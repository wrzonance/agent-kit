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
shared_six_step_loop="$root/agentkit/skills/.shared/six-step-loop.md"
verification_isolation="$root/agentkit/skills/parallel-issues/references/verification-isolation.md"
reference_manifest="$root/agentkit/skills/references.md"
pr_stage="$root/agentkit/skills/parallel-issues/scripts/pr-stage.sh"
pr_stage_text=$(<"$pr_stage")
ci_workflow="$root/.github/workflows/ci.yml"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

text=$(<"$skill")
normalized_text=$(tr '\n' ' ' <<<"$text" | tr -s '[:space:]' ' ')
assert_contains "$text" 'The injected body is authoritative' \
    'the skill tells a root not to read its already-injected body again'
assert_contains "$text" 'agent-preflight.sh" --help' \
    'the body points at helper-owned Step 0 recipes'
assert_contains "$text" 'session-ledger.sh" --help' \
    'the body points at helper-owned ledger recipes'

agent_preflight_help=$("$root/agentkit/skills/.shared/scripts/agent-preflight.sh" --help)
session_ledger_help=$("$root/agentkit/skills/.shared/scripts/session-ledger.sh" --help)
repo_config_help=$("$root/agentkit/skills/.shared/scripts/repo-config.sh" --help)
triage_help=$("$root/agentkit/skills/.shared/scripts/triage-issues.sh" --help)
concurrency_help=$("$root/agentkit/skills/parallel-issues/scripts/concurrency-cap.sh" --help)
move_help=$("$root/agentkit/skills/parallel-issues/scripts/move-github-project-item.sh" --help)
boundary_help=$("$root/agentkit/skills/parallel-issues/scripts/select-boundary-mode.sh" --help)
prepare_help=$("$root/agentkit/skills/parallel-issues/scripts/prepare-issue-artifacts.sh" --help)
assert_contains "$agent_preflight_help" 'Recipe: resolve, rehydrate, and run once' \
    'agent-preflight help owns the removed Step 0 recipe'
assert_contains "$agent_preflight_help" 'keyed_contract=' \
    'the moved resolver preserves harness-keyed contract selection'
assert_contains "$agent_preflight_help" '! -L $contract_root/.agent' \
    'the moved resolver preserves symlink rejection'
assert_contains "$agent_preflight_help" '-O $contract' \
    'the moved resolver preserves owner validation'
assert_contains "$agent_preflight_help" 'ls-files --error-unmatch' \
    'the moved resolver preserves the untracked-contract proof'
assert_contains "$agent_preflight_help" "printf '%s\\n' '.agent/*'" \
    'the moved preflight preserves the local exclusion allowlist'
assert_contains "$agent_preflight_help" 'contract skills path mismatch' \
    'the moved preflight preserves contract provenance validation'
assert_contains "$agent_preflight_help" '[[ $agentkit == /* ]]' \
    'the moved resolver requires an absolute skills path before helper use'
assert_contains "$session_ledger_help" 'Recipe: establish and reuse one run ID' \
    'session-ledger help owns the removed ledger recipe'
assert_contains "$session_ledger_help" 'trust-trunk=${trust_trunk:-false}' \
    'the moved ledger recipe preserves the invocation flag tuple'
assert_contains "$repo_config_help" 'Recipe: establish repository facts' \
    'repo-config help owns the removed repository-facts recipe'
assert_contains "$triage_help" 'Recipe: triage once' \
    'triage help owns the removed one-call recipe'
triage_recipe="$tmp/triage-recipe.sh"
printf '%s\n' "$triage_help" | awk '
    /^Recipe: triage once$/ { inside=1; next }
    /^The digest is evidence:/ { exit }
    inside { sub(/^  /, ""); print }
' >"$triage_recipe"
triage_agentkit="$tmp/triage-agentkit"
mkdir -p "$triage_agentkit/.shared/scripts"
cat >"$triage_agentkit/.shared/scripts/triage-issues.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TRIAGE_CALLS"
EOF
chmod +x "$triage_agentkit/.shared/scripts/triage-issues.sh"
triage_calls="$tmp/triage-calls"
agentkit="$triage_agentkit" agentkit_provenance=ok TRIAGE_CALLS="$triage_calls" \
    bash "$triage_recipe"
assert_eq 1 "$(wc -l <"$triage_calls")" \
    'the copied triage recipe executes exactly one query'
assert_eq '--limit 30' "$(<"$triage_calls")" \
    'the default copied triage recipe selects only the automatic backlog query'
assert_contains "$concurrency_help" 'Recipe: read the dispatch cap' \
    'concurrency-cap help owns its removed invocation recipe'
assert_contains "$move_help" 'Recipe: move a selected issue set' \
    'project-item help owns its removed invocation recipe'
assert_contains "$move_help" ': "${issue_numbers_csv:?replace with the selected issue numbers}"' \
    'the board recipe requires the caller-selected issue set'
assert_contains "$move_help" ': "${target_status:?set In progress at dispatch or In review when the draft opens}"' \
    'the board recipe requires the lifecycle target status'
assert_contains "$move_help" '--status "$target_status"' \
    'the board recipe forwards the selected lifecycle target'
move_recipe="$tmp/move-recipe.sh"
printf '%s\n' "$move_help" | awk '
    /^Recipe: move a selected issue set$/ { inside=1; next }
    inside && /^  # BEGIN session-context recovery$/ { recovery=1; next }
    recovery && /^  # END session-context recovery$/ { recovery=0; next }
    recovery { next }
    inside { sub(/^  /, ""); print }
' >"$move_recipe"
move_agentkit="$tmp/move-agentkit"
mkdir -p "$move_agentkit/.shared/scripts" "$move_agentkit/parallel-issues/scripts"
cat >"$move_agentkit/.shared/scripts/contract-read.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' owner/repo
EOF
cat >"$move_agentkit/parallel-issues/scripts/move-github-project-item.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOVE_CALLS"
EOF
chmod +x "$move_agentkit/.shared/scripts/contract-read.sh" \
    "$move_agentkit/parallel-issues/scripts/move-github-project-item.sh"
move_missing_rc=0
move_missing_err=$(env -u issue_numbers_csv -u target_status agentkit="$move_agentkit" \
    agentkit_provenance=ok contract_root="$tmp" bash "$move_recipe" 2>&1) || move_missing_rc=$?
assert_eq 1 "$move_missing_rc" \
    'the copied board recipe refuses an unspecified issue set and lifecycle status'
assert_contains "$move_missing_err" 'replace with the selected issue numbers' \
    'the board recipe refusal tells the caller which input is missing'
move_calls="$tmp/move-calls"
agentkit="$move_agentkit" agentkit_provenance=ok contract_root="$tmp" \
    issue_numbers_csv=777 target_status='In review' MOVE_CALLS="$move_calls" bash "$move_recipe"
assert_eq '--issue-numbers 777 --status In review --repo owner/repo' "$(<"$move_calls")" \
    'the copied board recipe forwards the selected issue and In review lifecycle target'
assert_contains "$boundary_help" 'Recipe: select once before fetching' \
    'boundary-mode help owns its removed selection recipe'
assert_contains "$boundary_help" '# BEGIN session-context recovery' \
    'boundary selection carries the canonical session-context loader'
assert_contains "$boundary_help" 'expected_agentkit' \
    'boundary selection validates the loaded skills path before use'
assert_contains "$prepare_help" 'Recipe: publish canonical issue artifacts' \
    'artifact helper help owns its removed preparation recipe'
assert_contains "$prepare_help" '--scratch-label "prior-art-$issue_number-$RUN_ID"' \
    'the moved artifact recipe preserves unique prior-art scratch allocation'
assert_contains "$prepare_help" 'if [[ -n $prior_art_file ]]' \
    'the moved artifact recipe passes --prior-art only when a digest exists'
assert_contains "$prepare_help" 'rm -f -- "$prior_art_file"' \
    'the moved artifact recipe preserves scratch cleanup'
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
implementation_worker="${worker_prompts%/*}/implementation-worker.md"
worker_prompts_text=$(cat "$worker_prompts" "$implementation_worker")
worker_prompts_only_text=$(<"$worker_prompts")
implementation_worker_text=$(<"$implementation_worker")
# The bulk-mutation ledger recipe and the triage/prior-art/board adjudication
# detail are single-sourced in references/triage-and-selection.md (issue
# #107 phase 3's split); SKILL.md's body keeps only the one-line verdict
# table, the ledger/REST-first mandate, and pointers.
triage_and_selection="$root/agentkit/skills/parallel-issues/references/triage-and-selection.md"
triage_and_selection_text=$(<"$triage_and_selection")
normalized_triage_and_selection_text=$(tr '\n' ' ' <<<"$triage_and_selection_text" | tr -s '[:space:]' ' ')
wait_discipline_text=$(<"$shared_wait_discipline")
six_step_loop_text=$(<"$shared_six_step_loop")
verification_isolation_text=$(<"$verification_isolation")
reference_manifest_text=$(<"$reference_manifest")
worker_gate_text=$(<"$worker_gate")
repair_recipe="$tmp/repair-recipe.sh"
awk '
    /^### Compose review repairs$/ { section=1; next }
    section && /^```bash$/ { capture=1; next }
    capture && /^```$/ { exit }
    capture { print }
' "$worker_gate" >"$repair_recipe"
[[ -s $repair_recipe ]] || {
    printf 'could not extract review repair recipe from %s\n' "$worker_gate" >&2
    exit 1
}
repair_agentkit="$tmp/repair-agentkit"
repair_root="$tmp/repair-root"
mkdir -p "$repair_agentkit/.shared/scripts" "$repair_agentkit/parallel-issues/scripts" "$repair_root/.agent"
cat >"$repair_agentkit/parallel-issues/scripts/cross-write-check.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$REPAIR_CROSS_CALLS"
[[ $1 == snapshot ]] || exit 2
for ((i=1; i<=$#; i++)); do
    [[ ${!i} == --output ]] || continue
    j=$((i + 1))
    output=${!j}
    break
done
[[ ${SNAPSHOT_FAIL:-no} != yes ]] || exit 1
printf '%s\n' original >"$output"
EOF
cat >"$repair_agentkit/parallel-issues/scripts/compose-worker-prompt.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$REPAIR_COMPOSE_CALLS"
for ((i=1; i<=$#; i++)); do
    [[ ${!i} == --output ]] || continue
    j=$((i + 1))
    output=${!j}
    break
done
printf '%s\n' '--cmd test' >"$output"
[[ ${COMPOSE_FAIL:-no} != yes ]] || exit 1
EOF
chmod +x "$repair_agentkit/parallel-issues/scripts/"*.sh
repair_cross_calls="$tmp/repair-cross-calls"
repair_compose_calls="$tmp/repair-compose-calls"
repair_run() {
    local run_dir=${repair_run_dir:-"$repair_root/.agent"}
    agentkit="$repair_agentkit" agentkit_provenance=ok RUN_DIR="$run_dir" REPO_ROOT="$repair_root" \
        PR=42 repair_worktree="$repair_root" repair_branch=feat/repair repair_scope='src/**' \
        accepted_findings="$tmp/accepted-findings.ndjson" repair_prompt="$tmp/repair-prompt" \
        worker_model=gpt-5.6-luna worker_effort=high REPAIR_CROSS_CALLS="$repair_cross_calls" \
        REPAIR_COMPOSE_CALLS="$repair_compose_calls" bash "$repair_recipe"
}
repair_first_output=$(repair_run)
repair_snapshot="$repair_root/.agent/repair-42-pre-dispatch.snapshot"
repair_started_at_file="$repair_root/.agent/repair-42-started-at"
repair_snapshot_bytes=$(<"$repair_snapshot")
repair_started_at=$(<"$repair_started_at_file")
assert_contains "$repair_first_output" "repair_started_at=$repair_started_at" \
    'review repair recipe prints the persisted interval start'
repair_resume_output=$(repair_run)
assert_eq 1 "$(wc -l <"$repair_cross_calls")" \
    'review repair resume preserves the original root snapshot'
assert_eq "$repair_snapshot_bytes" "$(<"$repair_snapshot")" \
    'review repair resume never overwrites the root snapshot bytes'
assert_eq "$repair_started_at" "$(<"$repair_started_at_file")" \
    'review repair resume preserves the original interval start'
assert_contains "$repair_resume_output" "repair_started_at=$repair_started_at" \
    'review repair resume reports the original interval start'
assert_eq 2 "$(wc -l <"$repair_compose_calls")" \
    'review repair resume composes a fresh leaf prompt'
missing_started_at_root="$tmp/missing-started-at-root"
mkdir -p "$missing_started_at_root/.agent"
printf '%s\n' original >"$missing_started_at_root/.agent/repair-42-pre-dispatch.snapshot"
missing_started_at_rc=0
repair_run_dir="$missing_started_at_root/.agent" repair_run >/dev/null 2>&1 || missing_started_at_rc=$?
assert_eq nonzero "$([[ $missing_started_at_rc != 0 ]] && printf nonzero || printf zero)" \
    'review repair resume stops when its original interval start is absent'
assert_eq 2 "$(wc -l <"$repair_compose_calls")" \
    'missing interval start does not compose a leaf prompt'
snapshot_failure_root="$tmp/snapshot-failure-root"
mkdir -p "$snapshot_failure_root/.agent"
snapshot_failure_rc=0
# This invocation intentionally exercises no-argument failure handling.
# shellcheck disable=SC2119
repair_run_dir="$snapshot_failure_root/.agent" SNAPSHOT_FAIL=yes repair_run || snapshot_failure_rc=$?
assert_eq nonzero "$([[ $snapshot_failure_rc != 0 ]] && printf nonzero || printf zero)" \
    'review repair recipe stops when snapshot creation fails'
assert_eq 2 "$(wc -l <"$repair_compose_calls")" \
    'snapshot failure does not compose a leaf prompt'
compose_failure_rc=0
# This invocation intentionally exercises no-argument failure handling.
# shellcheck disable=SC2119
COMPOSE_FAIL=yes repair_run || compose_failure_rc=$?
assert_eq nonzero "$([[ $compose_failure_rc != 0 ]] && printf nonzero || printf zero)" \
    'review repair recipe stops when prompt composition fails'
unset_context_cross_calls=$(wc -l <"$repair_cross_calls")
unset_context_compose_calls=$(wc -l <"$repair_compose_calls")
unset_context_rc=0
env -u RUN_DIR agentkit="$repair_agentkit" agentkit_provenance=ok REPO_ROOT="$repair_root" \
    PR=42 repair_worktree="$repair_root" repair_branch=feat/repair repair_scope='src/**' \
    accepted_findings="$tmp/accepted-findings.ndjson" repair_prompt="$tmp/repair-prompt" \
    worker_model=gpt-5.6-luna worker_effort=high REPAIR_CROSS_CALLS="$repair_cross_calls" \
    REPAIR_COMPOSE_CALLS="$repair_compose_calls" bash "$repair_recipe" >/dev/null 2>&1 || unset_context_rc=$?
assert_eq nonzero "$([[ $unset_context_rc != 0 ]] && printf nonzero || printf zero)" \
    'review repair recipe stops before constructing paths without its run directory'
assert_eq "$unset_context_cross_calls" "$(wc -l <"$repair_cross_calls")" \
    'unset run directory does not create a root snapshot'
assert_eq "$unset_context_compose_calls" "$(wc -l <"$repair_compose_calls")" \
    'unset run directory does not compose a leaf prompt'
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
' "${worker_prompts%/*}/implementation-worker.md")
# The opening fence may carry a language tag (markdownlint MD040 requires one);
# only the CLOSING fence is bare. Matching `^```$` for the opener silently
# extracted nothing the moment the tag was added, and an empty haystack fails
# every positive assertion at once rather than pointing at the real cause.
draft_loop_prompt=$(awk '
    /^## PR-fix-batch worker prompt$/ { section=1; next }
    section == 1 && /^\*\*Per-agent prompt template:\*\*$/ { capture=1; next }
    capture == 1 && /^```/ { capture=2; next }
    capture == 2 && /^```$/ { exit }
    capture == 2 { print }
' "$worker_prompts")
[[ -n $draft_loop_prompt ]] || {
    printf 'could not extract the draft-loop prompt block from %s\n' "$worker_prompts" >&2
    exit 1
}
setup_prompt=$(awk '
    /^## PR-loop setup worker prompt$/ { section=1; next }
    section == 1 && /^\*\*Per-agent prompt template:\*\*$/ { capture=1; next }
    capture == 1 && /^```/ { capture=2; next }
    capture == 2 && /^```$/ { exit }
    capture == 2 { print }
' "$worker_prompts")
[[ -n $setup_prompt ]] || {
    printf 'could not extract the PR-loop setup prompt block from %s\n' "$worker_prompts" >&2
    exit 1
}

# The fix-batch worker runs full verification through the same wrapper as an
# issue lead, so the Compose isolation rules must reach BOTH templates. Pinning
# them only on the whole-file text would pass while the fix-batch prompt carried
# none of them.
fix_batch_prompt=$(awk '
    /^## PR-fix-batch worker prompt$/ { capture=1; next }
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
compose_script_text=$(cat "$root/agentkit/skills/parallel-issues/scripts/compose-worker-prompt.sh" "$root/agentkit/skills/parallel-issues/scripts/lib/worker-leaf-contract.sh")
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
assert_contains "$text" '4-link depth window' 'chain depth window is pinned'
assert_contains "$normalized_text" 'deeper tails enter the same refill queue as slot-cap overflow' \
    'chain-depth overflow shares the slot-cap refill queue'
assert_not_contains "$normalized_text" 'deeper tails are dropped' \
    'chain-depth overflow is not a membership exclusion'
assert_contains "$normalized_text" 'depth limits the number of links in flight, not chain membership' \
    'chain depth is documented as a concurrency limit'
assert_contains "$normalized_text" 'refill the next queued successor from that exact pushed SHA' \
    'chain-depth refill is gated by the predecessor pushed SHA'
assert_contains "$text" 'cycle' 'cycles fall back instead of chaining'
assert_contains "$text" 'chain_base_sha' 'chain base sha variable is named'
assert_contains "$text" 'git worktree add "$worktree" -b "$branch" "${chain_base_sha:-origin/$base}"' \
    'worktree recipe parameterizes its start point'
assert_contains "$text" '--dispatch-plan "$dispatch_plan" --run-id "$RUN_ID"' \
    'worktree setup consumes the saved expected set and accepted publications'
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
assert_contains "$normalized_chains_text" 'initialPublications.<issue>' \
    'join assembly consumes immutable accepted worker publications'
assert_contains "$normalized_chains_text" 'expectedPredecessors' \
    'the saved plan remains authoritative for the complete predecessor set'
assert_contains "$normalized_chains_text" 'integrationBaseSha' \
    'join publication records the exact complete integration base'
assert_contains "$normalized_chains_text" 'resolution-only worker' \
    'a merge conflict automatically routes to the sole-writer resolution worker'
assert_contains "$normalized_chains_text" 'validate-handback.sh --classify-completion' \
    'failed automatic conflict resolution uses the existing blocker lifecycle'
assert_contains "$normalized_chains_text" 'Publishing a locally-built chain base' \
    'chains reference documents the general pushed-base requirement'
assert_contains "$normalized_chains_text" 'a linear chain is not protected from this just because it only had one predecessor' \
    'the pushed-base requirement is generalized past the join case'
assert_contains "$normalized_text" 'for a join, this means every predecessor pushed AND the merged join base itself pushed' \
    'the deferred-dispatch gate names the join-specific push requirement'
assert_contains "$normalized_chains_text" 'interface dependency' \
    'chain edges require an interface dependency'
assert_contains "$normalized_chains_text" 'a successor that would extend the in-flight depth enters the same refill queue' \
    'chain reference queues depth overflow instead of dropping it'
assert_contains "$normalized_chains_text" 'depth-6 fixture' \
    'chain reference includes the depth-six acceptance fixture'
assert_contains "$normalized_chains_text" 'queued=1[#6]' \
    'depth-six fixture reports the queued tail at the funnel'
assert_contains "$normalized_chains_text" 'dispatch #6 from #5' \
    'depth-six fixture dispatches the tail after predecessor push'
assert_contains "$normalized_chains_text" 'chain-advance.sh --finalize-successor' \
    'chain draft finalization uses the executable evidence boundary'
assert_contains "$normalized_chains_text" 'does not enumerate or update descendants' \
    'a predecessor repair causes no eager descendant cascade'
assert_contains "$normalized_chains_text" 'chainFinalizations.<pr>' \
    'topological finalization reuses the existing run-state PR namespace'
assert_contains "$normalized_chains_text" 'merge-down:<exact-predecessor-final-head>' \
    'review coverage bridges the original snapshot to the integrated head'
assert_contains "$normalized_chains_text" '--pr-state-digest' \
    'finalization inherits the final-head CI digest contract'
assert_contains "$normalized_chains_text" '--accepted-findings' \
    'finalization inherits the explicit accepted-finding proof contract'
assert_contains "$normalized_chains_text" 'known code-quality and inline-comment classifications' \
    'finalization requires both persisted finding channels to be available'
assert_contains "$normalized_chains_text" 'chain-advance.sh --finalization-status' \
    'the driver checks sealed evidence before any repeated integration work'
assert_contains "$normalized_chains_text" 'commit -> full verification -> push' \
    'the documented driver verifies the committed head before pushing it'
assert_contains "$normalized_chains_text" '--include-staged --yolo --allow-base-inherited' \
    'deferred merge commits retain the sanctioned protected-path recipe'
assert_contains "$normalized_chains_text" 'git rev-parse MERGE_HEAD' \
    'the inherited-path allowance binds the active merge head'
assert_contains "$normalized_chains_text" 'verified-skip' \
    'normal review-policy skips remain an explicit supported finalization path'
assert_not_contains "$normalized_chains_text" 'The response is a merge-down cascade' \
    'chain repair no longer prescribes eager merge-down cascades'
retarget_heading_line=$(grep -n '^## Merge order and the stacked-PR retarget$' \
    "$root/agentkit/skills/parallel-issues/references/chains.md" | cut -d: -f1)
retarget_exception_line=$(grep -n '^Two proofs tolerate evidence a retarget' \
    "$root/agentkit/skills/parallel-issues/references/chains.md" | cut -d: -f1)
assert_eq yes "$([[ $retarget_exception_line -gt $retarget_heading_line ]] && printf yes || printf no)" \
    'retarget-only proof exceptions stay inside the retarget section'
assert_contains "$normalized_text" 'test files or prose does not serialize' \
    'test/prose overlap runs in parallel with an end merge-down'
assert_contains "$text" 'root-owned dispatch plan' \
    'dispatch creates the root-owned plan before selection is dispatched'
assert_contains "$triage_and_selection_text" 'predictedWriteSet' \
    'dispatch-plan entries pin predicted write sets'
assert_contains "$triage_and_selection_text" 'expectedPredecessors' \
    'dispatch-plan entries pin the ordered complete predecessor set'
assert_contains "$triage_and_selection_text" 'integrationBaseSha' \
    'dispatch-plan entries separate join integration identity from PR targeting'
assert_contains "$triage_and_selection_text" 'publicationTarget' \
    'dispatch-plan entries pin and preserve the single PR publication target before dispatch'
assert_contains "$triage_and_selection_text" 'conflictMap.revisions' \
    'dispatch-plan records post-selection conflict-map revisions'
assert_contains "$triage_and_selection_text" 'shared build config, lockfiles, and generated contracts' \
    'issue-path extraction remains a seed for code-aware shared-root expansion'
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
assert_contains "$text" '--validate-only' \
    'dispatch validates schema 1 immediately after persisting the plan'
assert_contains "$normalized_text" 'require `schemaVersion=1 valid`' \
    'dispatch requires the schema-1 validation success marker'
assert_contains "$triage_and_selection_text" 'same owner-only file' \
    'dispatch-plan and merge-plan names are documented as lifecycle aliases'
assert_contains "$triage_and_selection_text" 'body-free `predictedWriteSet` in `pick-issues.sh` output' \
    'conflict analysis seeds predictions from picker path evidence'
assert_contains "$triage_and_selection_text" \
    'printf '\''%s'\'' "$cached_issue_body" | "$agentkit/parallel-issues/scripts/issue-paths.sh" --issue "${issue_number:?set the selected issue number}" --repo-root "$repository_root" --body-file -' \
    'conflict analysis seeds paths from the cached issue body without another forge read'
assert_contains "$triage_and_selection_text" \
    '[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ]' \
    'the issue-path recipe fails closed without provenance-bound installed helpers'
assert_contains "$triage_and_selection_text" 'chain-conversion' \
    'late overlap has an explicit chain-conversion disposition'
assert_contains "$triage_and_selection_text" 'merge-down' \
    'late overlap has an explicit merge-down disposition'
assert_contains "$triage_and_selection_text" 'inherited #137' \
    'late overlap points at the inherited #137 response'
assert_contains "$agent_preflight_help" '"$agentkit/.shared/scripts/contract-read.sh" --repo-root "$repository_root" --get skills.path' \
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
assert_not_contains "$wait_discipline_text" 'collect test-runner logs inside one bounded harness cell' \
    'worker test-runner guidance lives only in the composed verify line'
six_step_loop_flat=$(tr '\n' ' ' <<<"$six_step_loop_text" | tr -s '[:space:]' ' ')
assert_contains "$six_step_loop_flat" '## How to write a file' \
    'the shared loop names the write-mechanism section'
assert_contains "$six_step_loop_flat" 'edit/patch tool; a whole-file shell write' \
    'the shared loop states the write-mechanism preference order'
assert_contains "$six_step_loop_flat" 'Never hand-author a unified diff and feed it to `git apply`' \
    'the shared loop prohibits hand-authored unified diffs'
assert_contains "$six_step_loop_flat" 'byte-exact context lines, which a model reconstructing' \
    'the shared loop states the reason a hand-authored diff fails'
assert_contains "$six_step_loop_flat" 'A refused harness patch *tool* is not a refused *shell*' \
    'the shared loop distinguishes a refused patch tool from a refused shell'
assert_contains "$six_step_loop_flat" 'probe the shell with a trivial write' \
    'the shared loop requires a shell probe before an environment refusal'
assert_contains "$six_step_loop_flat" 'report the refusal only once that probe fails too' \
    'the shared loop reports the refusal only after the probe'
assert_contains "$six_step_loop_flat" 'fully applied or fully reverted' \
    'the shared loop requires a coherent tree on an interrupted change'
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
assert_contains "$text" 'Selection funnel:' \
    'parallel skill requires the named selection reconciliation line'
assert_contains "$normalized_text" 'exactly once after the final conflict and slot-cap decisions and before dispatch' \
    'selection reconciliation is emitted once at the dispatch boundary'
assert_contains "$normalized_text" \
    'The helper answers only the mechanical half; the root applies Backlog ranking, Step 3 conflict analysis, the slot cap, and the batch board move in order' \
    'selection keeps judgment and board mutation root-owned'
assert_contains "$triage_and_selection_text" \
    'Selection funnel: requested=3 eligible=3 dispatched=3 exclusions=none' \
    'selection reconciliation covers a full requested queue'
assert_contains "$triage_and_selection_text" \
    'Selection funnel: requested=3 eligible=2 dispatched=1 exclusions=blocked-by:1[#11],conflict-serialized:1[#12]' \
    'selection reconciliation covers a thin dispatch with per-candidate reasons'
assert_contains "$triage_and_selection_text" \
    'Selection funnel: requested=3 eligible=0 dispatched=0 exclusions=tier:1[#20],already-implemented:1[#21]' \
    'selection reconciliation covers an empty dispatch'
assert_contains "$normalized_triage_and_selection_text" 'Each considered candidate appears exactly once' \
    'selection funnel requires mutually exclusive candidate outcomes'
assert_contains "$normalized_triage_and_selection_text" \
    'For automatic selection with no supplied count, `requested` is the effective Limits-section slot cap.' \
    'automatic selection reports requested slots from the effective cap'
assert_contains "$triage_and_selection_text" 'slot-cap' \
    'selection funnel accounts for eligible candidates beyond the requested slots'
assert_contains "$triage_and_selection_text" 'queued=<queue-count>[#<issue>,...]' \
    'selection funnel prints queued issue identities'
assert_contains "$normalized_triage_and_selection_text" 'chain-depth overflow enters this same queue' \
    'selection classifies chain-depth overflow as queued'
assert_contains "$triage_and_selection_text" 'queued=1[#6]' \
    'selection examples show a queued chain tail'
assert_contains "$normalized_text" 'At handoff, print each queued reason and exact resume command' \
    'handoff surfaces queue entries instead of claiming completion'
assert_contains "$normalized_text" \
    'queued=1[#222] reason=chain-depth resume=/parallel-issues --yolo --fast-mode --auto-serialize 222' \
    'handoff prints an exact resume command for a queued chain issue'
assert_contains "$wait_discipline_text" 'A `sleep N` + re-check issued as its own tool call is churn' \
    'parallel wait rule rejects sleep and re-check tool churn'
assert_contains "$wait_discipline_text" 'A bounded wait must be silent until its terminal condition.' \
    'parallel wait rule is silent until terminal'
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
assert_contains "$wait_discipline_text" 'Inspect durable state for a completion or actionable blocker, not merely because time passed.' \
    'polling reads durable state only for actionable events'
assert_not_contains "$wait_discipline_text" 'run-state.sh" append --run-id "$RUN_ID" --repo-root "$repository_root" --path root_turns' \
    'empty root wakes do not append per-turn telemetry'
assert_not_contains "$wait_discipline_text" 'except required user updates' \
    'native collection has no generic narration exception'
assert_contains "$wait_discipline_text" 're-issue the same wait with no message text' \
    'an empty native wait resumes with no model narration'
assert_contains "$wait_discipline_text" 'Heartbeat: outstanding=<IDs> deadline=<deadline>' \
    'the allowed heartbeat has a measurable fixed shape'
assert_contains "$wait_discipline_text" 'no sooner than 10 minutes' \
    'mid-wait heartbeats have an explicit minimum interval'
assert_contains "$wait_discipline_text" "overrides the harness's default of narrating before each tool call" \
    'bounded collection silence overrides the generic harness narration default'
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
assert_contains "$text" 'Root launches every consent-bearing call itself as `AGENTKIT_PARALLEL_RUN_ID="$RUN_ID"' \
    'the consent holder launches real reviews rather than forwarding consent'
assert_contains "$text" 'review attempts and native worker reservations share the same atomic admission lock' \
    'parallel review launch names the executable shared-cap boundary'
assert_contains "$text" 'launch all currently eligible reviews without waiting for an earlier review result' \
    'distinct eligible reviews are dispatched concurrently'
assert_contains "$text" 'available upstream findings' \
    'fix batches receive known upstream findings without waiting for future results'
assert_contains "$text" 'confirmed terminal release' \
    'same-worktree fix and merge-down work waits for confirmed writer release'
assert_contains "$text" 'Publish one root-owned receipt at a time' \
    'root publication remains serial across concurrent review and fix completion'
assert_contains "$concurrency_help" '# BEGIN session-context recovery' \
    'concurrency dispatch carries the canonical session-context loader'
assert_contains "$concurrency_help" 'agentkit_provenance' \
    'concurrency dispatch validates resolver provenance'
assert_contains "$text" '### Spawn discipline (applies to every spawn in this skill)' \
    'spawn discipline is cross-cutting instead of dispatch-phase scoped'
assert_contains "$normalized_text" \
    'issue leads, waiters, assessors, reviewers, draft loops, and any improvised role' \
    'the universal gate names lead and non-lead fan-outs'
assert_contains "$text" '--assert-count "$prospective_total" --agent-kind "$agent_kind"' \
    'every fan-out passes its prospective total and kind to the cap helper'
assert_contains "$normalized_text" \
    'A refusal is terminal for that unchanged request: reduce the requested batch or wait for slots to free' \
    'overflow retry guidance cannot repeat the refused count unchanged'
assert_contains "$normalized_text" \
    'A cap-advertisement error stops spawning and is reported separately from a capacity refusal.' \
    'an unavailable cap stops the fan-out without masquerading as capacity exhaustion'
assert_contains "$normalized_triage_and_selection_text" \
    'Vetting uses only the slots available under the same spawn cap; process a larger Backlog in slot-sized batches or do not fan out.' \
    'thin-Ready vetting states its ceiling where it states the obligation'
assert_contains "$normalized_text" \
    'A triage fallback cannot justify `eligible=0` or an empty Ready column; any assessor fan-out still uses only the slots available under the spawn cap.' \
    'empty-Ready fallback guidance carries the universal assessor ceiling'
assert_contains "$text" 'Maximum 10 concurrent agents of every kind (root counted)' \
    'the Limits maximum covers every concurrent role'
assert_not_contains "$text" 'Maximum 10 per wave' \
    'the Limits maximum is no longer dispatch-wave scoped'
assert_not_contains "$text" 'PR_LOOP_CONCURRENCY_CAP=2' \
    'dispatch does not hardcode a two-loop cap'
assert_contains "$text" 'pr_loop_dispatch_cap' \
    'dispatch derives an effective loop cap before launching agents'
assert_contains "$text" 'runtime_loop_budget=$((max_concurrent_threads_per_session - active_leads - 1))' \
    'dispatch reserves the root and active issue leads from the runtime cap'
assert_contains "$text" 'pr_loop_dispatch_cap=$((open_pr_count < runtime_loop_budget ? open_pr_count : runtime_loop_budget))' \
    'dispatch bounds loops by open PRs and remaining runtime capacity'
assert_contains "$text" 'pr-loop-setup' \
    'dispatch uses the read-only PR-loop setup template'
assert_contains "$text" 'pr-fix-batch' \
    'dispatch gates the fix-batch template on accepted findings'
assert_contains "$text" 'open_pr_count == 0' \
    'dispatch treats zero open PRs as an explicit no-op case'
assert_contains "$text" 'exit 0' \
    'dispatch exits successfully when there are no open PRs'
assert_eq yes "$([[ $(sed -n '/^### Step 3b: Dispatch review-remote-pr agents (parallel)$/,/^### Adversarial-review receipt:/p' "$skill" | sed -n '2p') == '' ]] && printf yes || printf no)" \
    'Step 3b heading keeps its required Markdown blank line'
assert_contains "$normalized_text" 'origin/${base_branch}' \
    'setup materiality base has an origin-base default'
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
assert_contains "$bulk_section" '--json' \
    'bulk recipe names gh-body.sh --json as the documented mutation adapter'
assert_contains "$bulk_section" 'mutation_json=$(perform_rest_mutation "$planning_id") || mutation_rc=$?' \
    'bulk recipe captures the mutation call whether it exits zero or non-zero'
assert_contains "$bulk_section" 'if [[ -z $mutation_json ]]; then' \
    'bulk recipe stops when the mutation produced no usable object at all'
assert_contains "$bulk_section" 'report_batch_failure "mutation failed for $planning_id"' \
    'bulk recipe reports a mutation failure for the correct planning id'
assert_contains "$bulk_section" 'if ! "$apply_ledger" record --ledger "$ledger"' \
    'bulk recipe stops on a record failure'
assert_contains "$bulk_section" 'closing-issue verification did not pass' \
    'bulk recipe reports a closing-issue verification failure distinctly from a hard mutation failure'
record_line=$(grep -n -- '--number "\$created_number" --url "\$created_url"; then' <<<"$bulk_section" | head -n1 | cut -d: -f1)
closing_check_line=$(grep -n 'closing-issue verification did not pass' <<<"$bulk_section" | head -n1 | cut -d: -f1)
if [[ -n $record_line && -n $closing_check_line ]] && ((closing_check_line > record_line)); then
    _pass 'bulk recipe records the ledger before reporting a closing-issue verification failure'
else
    _fail 'bulk recipe records the ledger before reporting a closing-issue verification failure' \
        "record=$record_line closing-check=$closing_check_line"
fi
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
assert_contains "$boundary_help" 'printf '\''boundary mode: %s\n'\'' "$boundary_mode"' \
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
assert_contains "$dispatch_handoff" 'compose_output=$("$compose_script" "${compose_args[@]}") || exit 1' \
    'dispatch handoff stops when prompt composition fails'
compose_invocations=$(grep -Fxc 'compose_output=$("$compose_script" "${compose_args[@]}") || exit 1' <<< "$dispatch_handoff" || true)
assert_eq '1' "$compose_invocations" \
    'dispatch invokes the prompt composer exactly once per worker'
assert_contains "$dispatch_handoff" 'classification=majority-uncovered' \
    'dispatch reporting makes a majority-uncovered issue visible at a glance'
assert_contains "$dispatch_handoff" 'dispatch_plan=${dispatch_plan:?root-owned dispatch-plan artifact for this run}' \
    'dispatch defines the root-owned plan before composing'
assert_contains "$dispatch_handoff" '[[ $dispatch_plan == /* && -f $dispatch_plan && ! -L $dispatch_plan ]]' \
    'dispatch validates the plan before passing it to the composer'
assert_contains "$dispatch_handoff" 'spec-verification-plan=' \
    'dispatch consumes the composer plan-record report'
assert_contains "$dispatch_handoff" '--scratch-near "$dispatch_plan"' \
    'dispatch plan replacement scratch is allocated beside its arbitrary destination'
assert_contains "$dispatch_handoff" '$(plan_digest "$plan_replace_tmp") == "$plan_sha"' \
    'dispatch verifies copied replacement bytes before publication'
assert_contains "$dispatch_handoff" 'dispatch-plan verification failed before spawn' \
    'dispatch verifies the exact final record before spawn'
assert_not_contains "$dispatch_handoff" 'declare -A dispatch_verification_reports' \
    'dispatch does not require parent-shell associative-array state'
assert_contains "$dispatch_handoff" '${spec_verification:-none}' \
    'dispatch prints the current coverage report without Bash-only storage'
assert_contains "$dispatch_handoff" '[[ $spec_verification != *$' \
    'dispatch accepts an empty zero-step report while still rejecting multiple report lines'
assert_contains "$dispatch_handoff" 'dispatch_reports_dir="$dispatch_plan.verification-reports"' \
    'dispatch derives durable report storage from the root-owned run plan'
assert_contains "$dispatch_handoff" 'persist_dispatch_verification_report()' \
    'dispatch defines durable per-issue report persistence'
assert_contains "$dispatch_handoff" 'mv -f -- "$dispatch_report_tmp" "$dispatch_report"' \
    'dispatch atomically replaces one issue report without overwriting peers'
assert_contains "$dispatch_handoff" '--scratch-near "$dispatch_report"' \
    'dispatch report scratch is allocated beside its replacement destination'
assert_contains "$triage_and_selection_text" '--scratch-near "$dispatch_plan"' \
    'dispatch plan scratch is allocated beside an arbitrary absolute plan destination'
assert_contains "$dispatch_handoff" '--dispatch-plan "$dispatch_plan"' \
    'dispatch makes the composer check the plan record before spawn'

plan_publish_recipe=$(awk '
    /^if \[\[ \$plan_update != none \]\]; then/ { capture=1 }
    capture { print }
    capture && /^\[\[ \$\(plan_digest "\$dispatch_plan"\)/ { exit }
' <<< "$dispatch_handoff")
[[ -n $plan_publish_recipe ]] || _fail 'dispatch plan publication recipe is extractable' 'recipe body is empty'
same_fs_bin="$tmp/same-fs-bin"
mkdir -p "$same_fs_bin"
cat >"$same_fs_bin/mv" <<'SCRIPT'
#!/usr/bin/env bash
args=("$@")
count=${#args[@]}
source_path=${args[count-2]}
target_path=${args[count-1]}
source_dir=$(cd -- "$(dirname -- "$source_path")" && pwd -P) || exit 1
target_dir=$(cd -- "$(dirname -- "$target_path")" && pwd -P) || exit 1
[[ $source_dir == "$target_dir" ]] || exit 18
exec /bin/mv "$@"
SCRIPT
chmod +x "$same_fs_bin/mv"
plan_destination_dir="$tmp/arbitrary absolute destination"
prompt_dir="$tmp/prompt staging"
mkdir -p "$plan_destination_dir" "$prompt_dir"
dispatch_plan="$plan_destination_dir/dispatch-plan.json"
plan_update="$prompt_dir/issue-57.dispatch-plan-update"
printf 'old plan\n' >"$dispatch_plan"
chmod 640 "$dispatch_plan"
printf 'verified replacement\n' >"$plan_update"
plan_sha=$(sha256sum -- "$plan_update" | cut -d ' ' -f 1)
plan_publish_rc=0
PATH="$same_fs_bin:$PATH" bash -c '
agentkit=$1; prompt_dir=$2; plan_update=$3; dispatch_plan=$4; plan_sha=$5
plan_digest() { sha256sum -- "$1" | cut -d " " -f 1; }
'"$plan_publish_recipe" _ "$root/agentkit/skills" "$prompt_dir" "$plan_update" "$dispatch_plan" "$plan_sha" || plan_publish_rc=$?
assert_eq 0 "$plan_publish_rc" \
    'dispatch plan recipe uses a same-directory final rename for an arbitrary absolute destination'
assert_eq 'verified replacement' "$(<"$dispatch_plan")" \
    'dispatch plan recipe publishes the verified staged bytes'
assert_eq 640 "$(stat -c %a -- "$dispatch_plan")" \
    'dispatch plan recipe preserves the destination mode'
assert_eq no "$([[ -e $plan_update ]] && printf yes || printf no)" \
    'dispatch plan recipe removes the original staged update'
assert_eq 0 "$(find "$plan_destination_dir" -maxdepth 1 -type f ! -name dispatch-plan.json | wc -l)" \
    'dispatch plan recipe leaves no destination-adjacent scratch file'
persist_report_function=$(awk '
    /^persist_dispatch_verification_report\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}/ { exit }
' <<< "$dispatch_handoff")
[[ -n $persist_report_function ]] || _fail 'durable dispatch report function is extractable' 'function body is empty'
durable_plan="$tmp/dispatch plan.md"
: > "$durable_plan"
durable_repo="$tmp/durable-repo"
mkdir -p -- "$durable_repo"
first_report='spec-verification= issue=57 steps=2 covered=1 uncovered=1 uncovered-steps=2 coverage=1/2 classification=partially-covered'
second_report='spec-verification= issue=54 steps=1 covered=1 uncovered=0 uncovered-steps=none coverage=1/1 classification=fully-covered'
bash -c "$persist_report_function
dispatch_plan=\$1; issue_number=57; spec_verification=\$2; agentkit=\$3; repository_root=\$4
persist_dispatch_verification_report" _ "$durable_plan" "$first_report" "$root/agentkit/skills" "$durable_repo"
bash -c "$persist_report_function
dispatch_plan=\$1; issue_number=54; spec_verification=\$2; agentkit=\$3; repository_root=\$4
persist_dispatch_verification_report" _ "$durable_plan" "$second_report" "$root/agentkit/skills" "$durable_repo"
assert_eq "$first_report" "$(<"$durable_plan.verification-reports/issue-57.report")" \
    'first shell composition leaves its exact durable report'
assert_eq "$second_report" "$(<"$durable_plan.verification-reports/issue-54.report")" \
    'second shell composition preserves its peer and writes its own report'
zero_step_plan="$tmp/zero-step-plan.md"
: > "$zero_step_plan"
zero_step_rc=0
bash -c "$persist_report_function
dispatch_plan=\$1; issue_number=72; spec_verification=''; agentkit=\$2
persist_dispatch_verification_report" _ "$zero_step_plan" "$root/agentkit/skills" || zero_step_rc=$?
assert_eq 0 "$zero_step_rc" 'zero-step composer output passes the dispatch report consumer'
assert_eq no "$([[ -e $zero_step_plan.verification-reports ]] && printf yes || printf no)" \
    'zero-step dispatch creates no empty durable report'
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
assert_contains "$text" 'run-state.sh" summary --run-id "$RUN_ID" --repo-root "$repository_root"' \
    'final handoff pastes the computed durable run summary'
assert_contains "$text" '--reports-dir "$dispatch_plan.verification-reports"' \
    'final handoff replays durable spec-verification reports beside the summary'
assert_not_contains "$text" 'requests_per_wait_minute` metrics' \
    'final handoff no longer asks the live agent for post-hoc wait telemetry'

# --- issue #494: auto-review completion coverage and recoverable redrive ----
assert_contains "$normalized_text" 'Final draft sweep' \
    'auto-review performs a named final draft sweep before handoff'
opt_out_section=$(sed -n '/^### Opt-out/,/^## Do NOT Delete Worktrees/p' "$skill")
assert_contains "$text" '`--no-followup`'"'"'s Step 3d opt-out remains recognized' \
    'the flag summary names the same narrow opt-out as the workflow section'
assert_not_contains "$text" '`--no-followup`'"'"'s Phase 3 opt-out remains recognized' \
    'the flag summary does not retain the stale Phase 3 scope'
assert_contains "$opt_out_section" 'still run the mandatory Final draft sweep before handoff' \
    '--no-followup skips follow-up creation without bypassing final verification'
assert_not_contains "$opt_out_section" 'skip Phase 3 and jump straight to handoff' \
    '--no-followup no longer makes the mandatory sweep unreachable'
assert_contains "$normalized_text" 'CI settled' \
    'the final sweep requires settled CI for every opened PR'
assert_contains "$normalized_text" 'Code Quality dispositioned' \
    'the final sweep requires Code Quality disposition for every opened PR'
assert_contains "$normalized_text" 'exactly one of {adversarial receipt, verified skip receipt}' \
    'the final sweep requires exactly one receipt kind per opened PR'
final_sweep_section=$(sed -n '/^### Final draft sweep/,/^### Opt-out/p' "$skill")
assert_contains "$final_sweep_section" 'run-state.sh" get --run-id "$RUN_ID" --repo-root "$repository_root" --path opened_prs' \
    'the final sweep rehydrates opened PRs from invocation run-state'
assert_contains "$final_sweep_section" 'type == "array"' \
    'the final sweep validates the durable opened PR array'
assert_not_contains "$final_sweep_section" 'sweep `opened_prs`' \
    'the final sweep no longer relies on a context-only opened_prs value'
assert_contains "$final_sweep_section" 'gh-pr-state.sh' \
    'the final sweep refreshes live PR evidence before classifying receipts'
assert_contains "$final_sweep_section" '--full --no-cache' \
    'the final sweep forces a fresh live comment fetch'
assert_contains "$final_sweep_section" 'post-receipt.sh" status --issue-comments' \
    'the final sweep classifies the refreshed comment artifact with a complete command'
assert_eq yes "$([[ $(awk '/gh-pr-state\.sh/{fetch=NR} /post-receipt\.sh.*status/{status=NR} END {print (fetch < status ? "yes" : "no")}' <<< "$final_sweep_section") == yes ]] && printf yes || printf no)" \
    'the live refresh precedes receipt classification'
assert_contains "$final_sweep_section" '10:receipt=none' \
    'only a missing receipt is eligible for final-sweep recovery'
assert_contains "$final_sweep_section" 'receipt-redrive.<pr>' \
    'receipt recovery is tracked per PR in run-state for a one-shot limit'
assert_contains "$final_sweep_section" 'record-summary --run-id "$RUN_ID" --repo-root "$repository_root" --path receipt_prs --json "$pr"' \
    'successful review receipts are stored idempotently as numeric PR identities'
assert_contains "$final_sweep_section" '--path skipped_prs' \
    'verified skips use their own durable PR collection'
assert_contains "$final_sweep_section" 'duplicate/invalid' \
    'duplicate or invalid receipts are explicitly non-recoverable'
assert_contains "$final_sweep_section" 'handed-back' \
    'non-recoverable receipt evidence is recorded in the lifecycle ledger'
# issue #689 (CR-689-3): the final sweep's redrive bookkeeping is durable and
# one-shot -- gated by a run-state.sh get that must exit 11 (absent) before
# the redrive runs, with the set write recorded only after it succeeds.
if [[ $final_sweep_section == *'run-state.sh" get --run-id "$RUN_ID" --path receipt-redrive.<pr>'*'exits 11'*'run-state.sh" set --run-id "$RUN_ID" --path receipt-redrive.<pr>'* ]]; then
    _pass 'the final sweep gates the receipt-redrive get, exit-11 check, and set in durable order'
else
    _fail 'the final sweep gates the receipt-redrive get, exit-11 check, and set in durable order' \
        "final sweep section: ${final_sweep_section:0:600}"
fi
assert_contains "$normalized_text" 're-enters the draft loop' \
    'a final-sweep miss re-enters the draft loop'
assert_contains "$normalized_text" 'handoff cannot print' \
    'a final-sweep miss prevents the handoff'
assert_contains "$normalized_text" 'run-state.sh" summary' \
    'handoff emits helper-computed opened-PR receipt coverage totals'
assert_contains "$normalized_text" 'run-state.sh" bind "${bind_args[@]}"' \
    'startup and resume recover durable context through one run-state operation'
assert_contains "$normalized_text" '--activation-session "$activation_session"' \
    'run binding keys recovery to the actual acknowledged harness session'
assert_contains "$normalized_text" '--rebind' \
    'a known run can explicitly recover under an independently authorized new session'
assert_contains "$normalized_text" 'candidate IDs' \
    'ambiguous recovery explains how to use the candidate IDs already emitted by the helper'
assert_contains "$normalized_text" 'Never choose by modification time' \
    'resume guidance preserves deterministic selection without an mtime fallback'
for binding_field in run_id activation_session repository_root decision_ledger worker_ledger; do
    assert_contains "$normalized_text" ".$binding_field" \
        "run setup restores the $binding_field binding field"
done
assert_not_contains "$normalized_text" 'activation_session=SESSION_ID' \
    'worktree setup does not ask the model to reconstruct the activation session'
assert_contains "$normalized_text" 'record-summary --run-id "$RUN_ID" --repo-root "$repository_root" --path queued --json "$issue"' \
    'queue producers persist issue identities idempotently'
assert_contains "$normalized_text" 'dequeue-summary --run-id "$RUN_ID" --repo-root "$repository_root" --json "$issue"' \
    'dispatch and refill remove the issue from durable queue coverage'
assert_contains "$pr_stage_text" 'record-summary --run-id "$RUN_ID"' \
    'draft publication persists PR identities idempotently'
assert_contains "$normalized_text" 'recoverable' \
    'Collect classifies recoverable blocked leads'
assert_contains "$normalized_text" 'baseline-red' \
    'Collect recognizes baseline-red as recoverable'
assert_contains "$normalized_text" 'write-set' \
    'Collect recognizes write-set as recoverable'
assert_contains "$normalized_text" 'one automatic re-drive' \
    'recoverable blocked leads receive one automatic re-drive'
assert_contains "$normalized_text" 'exact resume command' \
    'parked leads print an exact resume command'
assert_contains "$normalized_text" 'only after the blocker clears' \
    'recoverable redrive waits until the blocker is cleared'
assert_contains "$normalized_text" 'widen the fence' \
    'write-set recovery requires the root to widen its fence'
assert_contains "$normalized_text" 'every active worker' \
    'write-set recovery rechecks every active worker'
assert_contains "$normalized_text" 'same lead is unavailable' \
    'blocked recovery falls back to a fresh lead when needed'
assert_contains "$normalized_text" 'partial-pushed' \
    'Collect classifies pushed green BLOCKED handbacks as partial delivery'
assert_contains "$normalized_text" 'pr=open' \
    'partial-pushed completion opens a draft PR'
assert_contains "$normalized_text" '--blocker' \
    'partial-pushed publication carries protected paths into the PR body'
assert_contains "$normalized_text" 'Operator action required' \
    'partial-pushed publication names the PR body disclosure section'
assert_contains "$normalized_text" 'Completion report' \
    'ordinary clean completion retains its direct publication route'
assert_contains "$normalized_text" 'verification=unbound' \
    'partial publication carries the unresolved verification limitation'
assert_contains "$normalized_text" 'both completion paths' \
    'clean and partial delivery retain chain dispatch guidance'

# issue #689 (CR-689-3): the BLOCKED bullet's redrive bookkeeping is durable
# and one-shot -- gated by a run-state.sh get that must exit 11 (absent)
# before the redrive runs, with the set write recorded only after it succeeds.
blocked_bullet=$(grep '^- \*\*BLOCKED\*\*' "$skill")
assert_contains "$blocked_bullet" 'same one-call open stage' \
    'partial-pushed draft publication records the PR in durable coverage'
assert_contains "$blocked_bullet" 'exit 11 (absent)' \
    'the BLOCKED bullet names the absent-key exit code before redriving'
if [[ $blocked_bullet == *'run-state.sh" get --run-id "$RUN_ID" --path redrive.<N>'*'exit 11 (absent)'*'run-state.sh" set --run-id "$RUN_ID" --path redrive.<N>'* ]]; then
    _pass 'the BLOCKED bullet gates the redrive get, exit-11 check, and set in durable order'
else
    _fail 'the BLOCKED bullet gates the redrive get, exit-11 check, and set in durable order' \
        "bullet: ${blocked_bullet:0:600}"
fi

# The doc pins "exit 11 (absent)" as run-state.sh's actual get-on-absent-key
# exit code; verify the real helper still behaves that way rather than
# trusting the prose to stay in sync with the script.
real_run_state="$root/agentkit/skills/.shared/scripts/run-state.sh"
real_absent_state="$tmp/real-run-state-absent.json"
real_get_absent_rc=0
"$real_run_state" get --file "$real_absent_state" --path redrive.999 >/dev/null 2>&1 || real_get_absent_rc=$?
assert_eq '11' "$real_get_absent_rc" \
    "run-state.sh get on an absent key really exits 11, matching the SKILL.md's pinned exit code"

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
assert_contains "$normalized_text" 'one canonical body fetch by the picker' \
    'triage digest limits each issue body to its picker fetch'
assert_contains "$text" 'Set `body_cache` from the selected record' \
    'preparation consumes the picker body-cache reference'
assert_contains "$normalized_text" 'Do not fetch timelines, `projectItems`' \
    'triage flow forbids redundant timeline and project item reads'
assert_contains "$move_help" '--issue-numbers "$issue_numbers_csv"' \
    'dispatch moves selected issues with one batch invocation'
assert_contains "$issue_lead_prompt" '--only NAME[,NAME...]' \
    'red/green iteration documents the focused suite selector'
assert_contains "$issue_lead_prompt" 'AGENT_CMD_TEST_FOCUS' \
    'focused iteration is gated by the repository declaration'
assert_contains "$issue_lead_prompt" 'exactly once through `agent-run.sh`' \
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
assert_contains "$setup_prompt" 'gh-pr-state.sh' 'setup prompt fetches PR state'
assert_not_contains "$setup_prompt" '--wait-ci' 'setup prompt snapshots CI without polling'
assert_contains "$setup_prompt" 'code-quality-state.sh' 'setup prompt triages Code Quality'
assert_contains "$setup_prompt" 'materiality-check.sh' 'setup prompt performs materiality precheck'
assert_contains "$setup_prompt" 'Zero in-diff findings are a successful' \
    'setup prompt treats a zero-finding loop as success'
assert_contains "$setup_prompt" 'launch-ready' 'setup prompt names its launch-ready terminal line'
assert_contains "$setup_prompt" 'ci-observed=' 'setup prompt preserves actual CI beside launch eligibility'
assert_contains "$setup_prompt" 'cq-open:' 'setup prompt names its Code Quality finding signal'
assert_contains "$setup_prompt" 'source=pr_NNN_code_quality_comments.json' \
    'setup prompt names the PR-scoped Code Quality source artifact'
assert_contains "$setup_prompt" 'cq-repo: M' \
    'setup prompt reports repository-global Code Quality findings separately'
assert_contains "$setup_prompt" '--comments-file' \
    'setup prompt attributes findings from the persisted PR artifact'
assert_contains "$setup_prompt" '--diff-base' \
    'setup prompt attributes findings against the PR diff base'
assert_contains "$setup_prompt" '--repo-root FULL_PATH' \
    'setup prompt passes the checkout root for Code Quality attribution'
assert_contains "$setup_prompt" 'if ! cq_state=' \
    'setup prompt fails closed when Code Quality attribution fails'
assert_contains "$setup_prompt" 'cq-open: unavailable' \
    'setup prompt names unavailable Code Quality evidence'
assert_contains "$setup_prompt" 'in-diff findings' \
    'setup prompt gates only on in-diff Code Quality findings'
assert_contains "$setup_prompt" 'never return BLOCKED merely because' \
    'setup prompt does not encode a zero-finding BLOCKED result'
assert_contains "$setup_prompt" 'test -s "$run_dir/state/pr_NNN_threads.json"' \
    'setup completion acceptance requires a non-empty threads artifact'
assert_contains "$setup_prompt" 'gh-pr-state.sh" --pr NNN --repo OWNER/REPO --repo-root' \
    'setup completion acceptance regenerates missing state through gh-pr-state'
assert_contains "$setup_prompt" 'setup-artifacts-missing' \
    'setup completion acceptance records missing-artifact evidence'
assert_contains "$setup_prompt" 'exactly once' \
    'setup completion acceptance bounds artifact regeneration to one retry'
assert_contains "$setup_prompt" 'run-dir=' \
    'setup completion line names the canonical run directory'
assert_contains "$setup_prompt" 'ci_digest=$(' \
    'setup prompt captures the bounded CI digest'
assert_contains "$setup_prompt" 'ci_line=$(sed -n' \
    'setup prompt parses the captured CI digest'
assert_contains "$setup_prompt" 'ci_failing=' \
    'setup prompt retains the failing CI count'
assert_contains "$setup_prompt" 'failing-checks=' \
    'setup prompt receives stable failing-check names'
assert_contains "$setup_prompt" 'ci_failing_checks=$(sed -n' \
    'setup prompt parses stable failing-check names'
assert_contains "$setup_prompt" 'ci_observed="red: $ci_failing_checks"' \
    'setup prompt names the failing check in observed CI evidence'
assert_not_contains "$setup_prompt" 'setup_terminal="ci-red:' \
    'failing CI does not replace review launch eligibility'
assert_not_contains "$setup_prompt" 'setup_terminal="cq-open:' \
    'Code Quality findings do not replace review launch eligibility'
assert_not_contains "$setup_prompt" "setup_terminal='cq-open:" \
    'unavailable Code Quality evidence does not replace review launch eligibility'
assert_not_contains "$setup_prompt" 'setup_terminal="icf-open:' \
    'issue-comment findings do not replace review launch eligibility'
assert_not_contains "$setup_prompt" "setup_terminal='icf-open:" \
    'unavailable issue-comment evidence does not replace review launch eligibility'
assert_contains "$setup_prompt" "printf '%s run-dir=%s\\n'" \
    'setup prompt appends the run-dir to every terminal line'
assert_contains "$setup_prompt" 'Rebuild `acceptance_args` inside this root block' \
    'setup prompt rebuilds acceptance arguments during root recovery'

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
    if [[ $prompt_label == 'issue-lead prompt' ]]; then
        assert_contains "$prompt_text" 'git -C "$affected_worktree" diff --binary' "$prompt_label carries affected-worktree restoration"
    else
        assert_contains "$prompt_text" 'git diff --binary | git apply -R' "$prompt_label carries incident restoration"
    fi
    assert_contains "$prompt_text" 'report the incident and restoration in the completion report' "$prompt_label reports restored incidents"
    assert_not_contains "$prompt_text" 'Co-Authored-By: Codex' "$prompt_label has no literal Codex provider trailer"
    assert_not_contains "$prompt_text" 'Co-Authored-By: Claude' "$prompt_label has no literal Claude provider trailer"
    assert_not_contains "$prompt_text" 'Co-Authored-By: gpt-' "$prompt_label has no literal model trailer"
    assert_not_contains "$prompt_text" 'merge origin/main' "$prompt_label has no root conflict merge command"
    assert_not_contains "$prompt_text" 'NEVER rebase' "$prompt_label has no rebase guard"
    # A blanket ban on the substring "force-push" was correct before commit
    # caecaa7 ("move privileged publication to root"): workers never touched
    # git beyond producing a diff, so any mention of force-push in a worker
    # prompt could only be a leaked root-authored INSTRUCTION. Workers now
    # publish their own branch (see "you publish your own branch" below), and
    # issue #374 adds the opposite thing: a worker-authored PROHIBITION on
    # ever force-pushing once the first push has landed. A blind substring
    # scan cannot tell those two apart, so this asserts both halves instead
    # of one blind ban -- do not restore the old blanket "no force-push at
    # all" check; that would make issue #374's freeze clause untestable.
    assert_contains "$prompt_text" 'do not amend, rebase, reset, or force-push' \
        "$prompt_label states the post-push history-freeze prohibition"
    prompt_text_without_freeze=${prompt_text//'do not amend, rebase, reset, or force-push'/}
    assert_not_contains "$prompt_text_without_freeze" 'force-push' \
        "$prompt_label has no force-push mention outside the freeze prohibition"
    assert_not_contains "$prompt_text" 'git add -A' "$prompt_label has no broad staging instruction"
    assert_not_contains "$prompt_text" 'peer-cli=' "$prompt_label has no reviewer provider selection"
    assert_not_contains "$prompt_text" 'gpt-5.6-terra' "$prompt_label has no blind reviewer fallback"
    assert_contains "$prompt_text" '<PASTE, verbatim, the agent-preflight.sh contract' \
        "$prompt_label carries the environment-contract paste placeholder"
done
assert_contains "$issue_lead_prompt" 'git -C "$affected_worktree" diff --binary -- "$path"' \
    'issue-lead restoration reads the affected worktree and scopes the tracked path'
assert_contains "$issue_lead_prompt" 'git -C "$affected_worktree" apply -R' \
    'issue-lead restoration reverses the patch in the affected worktree'
assert_contains "$issue_lead_prompt" 'worker-owned untracked' \
    'issue-lead restoration handles proven worker-owned untracked files separately'
assert_contains "$issue_lead_prompt" 'only when all emitted changes are proven worker-owned' \
    'issue-lead whole-path restoration never reverses unrelated shared-file changes'
assert_contains "$issue_lead_prompt" 'For mixed ownership, apply a verified own patch/preimage' \
    'issue-lead mixed-ownership restoration scopes reversal to verified worker bytes'
assert_contains "$issue_lead_prompt" 'or stop and report' \
    'issue-lead restoration stops instead of guessing at ambiguous ownership'
assert_contains "$text" 'set its working directory to the assigned worktree' 'dispatcher sets worker cwd when supported'
assert_contains "$issue_lead_prompt" 'completion report' 'issue lead returns a completion report'
assert_contains "$draft_loop_prompt" 'completion report' 'phase lead returns a completion report'
assert_contains "$issue_lead_prompt" 'git push -u origin' 'issue lead pushes its own branch'
assert_contains "$draft_loop_prompt" 'Push the branch' 'phase lead pushes its own branch'
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
for prompt_flat_label in 'issue-lead prompt' 'draft-loop prompt'; do
    prompt_flat=$([[ $prompt_flat_label == 'issue-lead prompt' ]] && printf '%s' "$issue_lead_flat" || printf '%s' "$draft_loop_flat")
    assert_contains "$prompt_flat" 'How to write a file' \
        "$prompt_flat_label names the write-mechanism section"
    assert_contains "$prompt_flat" 'in preference order: your own edit/patch tool' \
        "$prompt_flat_label states the write-mechanism preference order"
    assert_contains "$prompt_flat" 'Never hand-author a unified diff for `git apply`' \
        "$prompt_flat_label prohibits hand-authored unified diffs"
    assert_contains "$prompt_flat" 'byte-exact context lines you cannot reconstruct from memory' \
        "$prompt_flat_label states the reason a hand-authored diff fails"
    assert_contains "$prompt_flat" 'A refused patch tool is not a refused shell' \
        "$prompt_flat_label distinguishes a refused patch tool from a refused shell"
    assert_contains "$prompt_flat" 'probe the shell with a trivial write before reporting an environment refusal' \
        "$prompt_flat_label requires a shell probe before an environment refusal"
    assert_contains "$prompt_flat" 'Leave an interrupted change fully applied or fully reverted' \
        "$prompt_flat_label requires a coherent tree on an interrupted change"
done
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
normal_completion_branch=$(grep -F '**Completion report (branch + pushed SHA)**' "$skill")
assert_contains "$normal_completion_branch" 'pr-stage.sh open' \
    'the normal completion branch names the one-call publication stage inline'
assert_contains "$normal_completion_branch" 'composes the four approved sections' \
    'the normal completion branch preserves canonical body composition'
assert_contains "$normal_completion_branch" 'registers `opened_prs`' \
    'the normal completion branch preserves durable PR identity recording'
blocked_completion_branch=$(grep -F '**BLOCKED**' "$skill")
assert_contains "$blocked_completion_branch" 'same one-call open stage' \
    'the BLOCKED completion branch names the same publication stage'
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
    sed -n '/^## Draft PR body template$/,/^## PR-fix-batch worker prompt$/p' "$worker_prompts"
)
assert_contains "$publication_section" '"$agentkit/parallel-issues/scripts/pr-stage.sh" open' \
    'draft PR publication uses the resumable one-call stage'
assert_contains "$publication_section" '--run-id "$RUN_ID"' \
    'draft PR publication attributes the created PR to the invocation run'
assert_contains "$publication_section" '--repo-root "$repository_root"' \
    'draft PR publication binds run state to the repository root'
assert_contains "$publication_section" '--default-branch "$base"' \
    'draft PR publication binds closing verification to the environment default branch'
assert_contains "$publication_section" '--dispatch-plan "$dispatch_plan" --issue "$issue_number"' \
    'draft PR publication binds its target to the current issue saved in the dispatch plan'
assert_contains "$publication_section" 'dispatch_plan=${dispatch_plan:?root-owned dispatch-plan artifact for this run}' \
    'draft PR publication requires the root-owned dispatch plan before composing the body'
assert_contains "$publication_section" '[.entries[]? | select(.issue == $issue) | .publicationTarget]' \
    'draft PR publication reads its target from the matching saved-plan entry'
assert_not_contains "$publication_section" '--title "$pr_title" --base "$base"' \
    'draft PR publication does not duplicate or guess the recorded target'
assert_not_contains "$publication_section" 'gh pr create --draft --body-file "$pr_body_file"' \
    'draft PR publication does not bypass the byte-verifying transport'
assert_contains "$pr_stage_text" 'COMPOSE_SH=' \
    'draft PR publication uses the canonical body composer'
assert_contains "$publication_section" '--why-file "$pr_why_file"' \
    'draft PR publication supplies the root-approved Why file'
assert_contains "$publication_section" '--testing-file "$pr_testing_file"' \
    'draft PR publication supplies the root-approved Testing file'
assert_contains "$pr_stage_text" '--expect-closing-issue "$ISSUE"' \
    'the one-call stage can forward target-scoped GitHub closing-link verification'
assert_contains "$publication_section" '--expect-closing-issue "$issue_number"' \
    'default-branch PR publication can request GitHub closing linkage'
assert_contains "$publication_section" '[[ $publication_target != "$base" ]] || closing_issue_args+=(--expect-closing-issue "$issue_number")' \
    'only a recorded default-branch publication requests closing linkage at creation'
assert_contains "$publication_section" '"${closing_issue_args[@]}"' \
    'draft PR publication passes the target-derived closing-linkage arguments'
assert_contains "$publication_section" 'This was written agentically; verify its assertions:' \
    'canonical composer documents the fixed attribution banner'
assert_contains "$publication_section" 'Never pass a multiline PR body through inline `--body`' \
    'draft PR publication forbids inline multiline body strings'
assert_contains "$pr_stage_text" 'body=$run_dir/pr-stage-$ISSUE-body.md' \
    'draft PR publication keeps the intended body beneath trusted run state'
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
assert_contains "$worker_gate_flat" 'refused harness patch *tool* is not a refused *shell*' \
    'worker-gate.md distinguishes a refused patch tool from a refused shell'
assert_contains "$worker_gate_flat" 'probes the shell with a trivial write' \
    'worker-gate.md requires a shell probe before an environment refusal'
assert_contains "$worker_gate_flat" 'How to write a file' \
    'worker-gate.md points to the shared write-mechanism guidance'
assert_contains "$worker_gate_flat" 'fully applied or fully reverted' \
    'worker-gate.md requires a coherent tree on an interrupted change'
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
outer_open_count=$(awk '$0 == "````text" { count++ } END { print count + 0 }' "${worker_prompts%/*}/implementation-worker.md")
outer_close_count=$(awk '$0 == "````" { count++ } END { print count + 0 }' "${worker_prompts%/*}/implementation-worker.md")
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
' "${worker_prompts%/*}/implementation-worker.md")
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
# The raw template carries no inner ```bash fence: compose-worker-prompt.sh embeds
# every recipe itself (issue #334 removed the hand-copied `cat` recipe; the size
# wave removed the standalone `git branch --show-current` example, which Branch
# Rules step 2 already states), so a worker prompt never documents a command for
# the worker to run by hand.
assert_eq '0' "$inner_open_count" \
    'the issue-lead template carries no inner triple-backtick bash fence'
assert_eq '0' "$inner_close_count" \
    'the issue-lead template carries no inner triple-backtick closer'

cap_helper="$root/agentkit/skills/parallel-issues/scripts/concurrency-cap.sh"
assert_eq yes "$( [[ -x $cap_helper ]] && printf yes || printf no )" \
    'concurrency cap helper is executable'
configured_home="$tmp/configured"
mkdir -p "$configured_home/.codex"
printf '%s\n' '[multi_agent_v2]' 'max_concurrent_threads_per_session = 10' \
    > "$configured_home/.codex/config.toml"
out=$("$cap_helper" --config "$configured_home/.codex/config.toml" 2>/dev/null)
status=$?
assert_contains "$out" 'effective concurrency cap: 10 total threads, including the root' \
    'dispatch advertises the configured effective cap'
assert_eq '0' "$status" 'an advertised cap exits zero'

codex_home="$tmp/codex-home"
mkdir -p "$codex_home"
printf '%s\n' '[multi_agent_v2]' 'max_concurrent_threads_per_session = 7' \
    > "$codex_home/config.toml"
out=$("$cap_helper" --config "$codex_home/config.toml" 2>/dev/null)
assert_contains "$out" 'effective concurrency cap: 7 total threads, including the root' \
    'a CODEX_HOME override is honored over $HOME/.codex'

# Issue #832: the cap is a property of every spawn, including an improvised
# non-lead fan-out. The effective skill maximum remains 10 even when the
# runtime offers more threads, and the refusal carries enough state to retry
# with a smaller batch instead of repeating the same request.
wide_home="$tmp/wide-runtime"
mkdir -p "$wide_home"
printf '%s\n' '[multi_agent_v2]' 'max_concurrent_threads_per_session = 20' \
    > "$wide_home/config.toml"
overflow_err="$tmp/assessor-overflow.err"
out=$("$cap_helper" --config "$wide_home/config.toml" 2>/dev/null)
assert_contains "$out" 'effective concurrency cap: 10 total threads, including the root' \
    'a runtime above the skill maximum advertises the enforced cap'
out=$("$cap_helper" --config "$wide_home/config.toml" \
    --assert-count 11 --agent-kind assessor 2>"$overflow_err")
status=$?
assert_eq '1' "$status" 'an assessor fan-out above the effective cap is refused'
assert_eq '' "$out" 'a refused assessor fan-out prints no success evidence'
assert_contains "$(<"$overflow_err")" \
    'spawn refused: cap=10 observed=11 agent-kind=assessor helper=concurrency-cap.sh' \
    'the refusal names the cap, observed total, non-lead kind, and cap helper'
wrapped_count=18446744073709551616
out=$("$cap_helper" --config "$wide_home/config.toml" \
    --assert-count "$wrapped_count" --agent-kind assessor 2>"$overflow_err")
status=$?
assert_eq '1' "$status" 'a prospective total cannot wrap through shell integer arithmetic'
assert_contains "$(<"$overflow_err")" "observed=$wrapped_count" \
    'an overflow-sized refusal preserves the original observed decimal'

huge_runtime_home="$tmp/huge-runtime"
mkdir -p "$huge_runtime_home"
printf '%s\n' '[multi_agent_v2]' \
    'max_concurrent_threads_per_session = 18446744073709551616' > "$huge_runtime_home/config.toml"
out=$("$cap_helper" --config "$huge_runtime_home/config.toml" 2>/dev/null)
status=$?
assert_eq '0' "$status" 'an overflow-sized positive runtime cap clamps safely'
assert_contains "$out" 'effective concurrency cap: 10 total threads, including the root' \
    'an overflow-sized runtime cap advertises the skill maximum'

for missing_args in '--assert-count 2' '--agent-kind assessor'; do
    read -r -a missing_argv <<< "$missing_args"
    err=$("$cap_helper" --config "$configured_home/.codex/config.toml" \
        "${missing_argv[@]}" 2>&1 >/dev/null)
    status=$?
    assert_eq 'nonzero' "$( ((status != 0)) && printf nonzero || printf zero )" \
        "a missing assertion partner is rejected: $missing_args"
    assert_contains "$err" 'must be supplied together' \
        "a missing assertion partner names the pair contract: $missing_args"
done
err=$("$cap_helper" --config "$configured_home/.codex/config.toml" \
    --assert-count '' --agent-kind '' 2>&1 >/dev/null)
status=$?
assert_eq 'nonzero' "$( ((status != 0)) && printf nonzero || printf zero )" \
    'explicitly empty assertion values are rejected'
assert_contains "$err" 'assertion values must be non-empty' \
    'empty assertion values explain the value requirement'

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
assert_contains "$text" 'No facts waive review or chunking.' \
    'diff-size facts still forbid skipping review or chunking on facts alone'
assert_contains "$text" 'references/worker-prompts.md](references/worker-prompts.md#diff-size-disclosure)' \
    'diff-size facts point at the worker-prompts disclosure recipe'
assert_contains "$text" 'Diff size is never a reason to withhold this' \
    'the Collect completion-report bullet carries the same no-park rule'
assert_contains "$worker_prompts_text" '### Diff-size disclosure' \
    'worker-prompts.md carries the diff-size disclosure subsection'
assert_contains "$worker_prompts_text" '"$agentkit/.shared/scripts/diff-facts.sh" --repo-root "$worktree"' \
    'the disclosure recipe runs diff-facts.sh against the worktree'
assert_contains "$worker_prompts_text" "'Diff-size disclosure:' >> \"\$pr_decisions_file\"" \
    'the disclosure recipe labels machine-readable facts as Decisions prose'
assert_contains "$publication_section" "if ! grep -qxF 'Diff-size disclosure:' \"\$pr_decisions_file\"; then" \
    'the disclosure recipe guards its in-place append for resumable publication'
assert_contains "$worker_prompts_text" '--base "${chain_base_sha:-origin/$base}"' \
    'the disclosure recipe pins the chain base for a chained issue'
assert_contains "$worker_prompts_text" '>> "$pr_decisions_file"' \
    'the disclosure recipe folds facts into the Decisions section, not a separate gate'
assert_contains "$worker_prompts_text" 'still gets the same draft PR a small one gets' \
    'the disclosure recipe states parity between over-guideline and small packets'
assert_contains "$worker_prompts_text" 'is never an unattended default' \
    'the disclosure recipe states trimming is attended-only, never automatic'

disclosure_recipe=$(sed -n "/^if ! grep -qxF 'Diff-size disclosure:'/,/^fi$/p" <<<"$publication_section")
if [[ -n $disclosure_recipe ]]; then
    disclosure_agentkit="$tmp/disclosure-agentkit"
    disclosure_calls="$tmp/disclosure-calls"
    disclosure_decisions="$tmp/disclosure-decisions.md"
    mkdir -p "$disclosure_agentkit/.shared/scripts"
    cat >"$disclosure_agentkit/.shared/scripts/diff-facts.sh" <<'EOF'
#!/usr/bin/env bash
printf 'diff-facts\n' >>"$DISCLOSURE_CALLS"
printf 'base=origin/main\nfiles=1\n'
EOF
    chmod +x "$disclosure_agentkit/.shared/scripts/diff-facts.sh"
    printf 'root-approved decision\n' >"$disclosure_decisions"
    for _retry in 1 2; do
        DISCLOSURE_CALLS="$disclosure_calls" agentkit="$disclosure_agentkit" \
            pr_decisions_file="$disclosure_decisions" worktree="$tmp" base=main \
            bash -c "$disclosure_recipe"
    done
    assert_eq 1 "$(grep -c '^Diff-size disclosure:$' "$disclosure_decisions")" \
        're-running the actual disclosure recipe preserves one body section'
    assert_eq 1 "$(grep -c '^diff-facts$' "$disclosure_calls")" \
        're-running the actual disclosure recipe computes facts only once'
else
    assert_eq present missing 'the publication section exposes an executable disclosure guard'
fi

# The end-of-draft adversarial review on PR #280 confirmed a P2: the first
# draft of the disclosure recipe stood alone as its own code fence, ahead of
# the block that establishes $pr_decisions_file and $agentkit -- under
# `set -euo pipefail` that aborts the whole draft-PR recipe on an unbound
# variable, for every workstream, which is worse than the stall this issue
# exists to prevent. The fix folds the diff-facts.sh call into the existing
# recipe, after both prerequisites are established. Pin the ordering
# directly so a future edit cannot silently pull it back out ahead of them.
mapfile -t pub_lines <<< "$publication_section"
decisions_guard_idx=-1 resolver_guard_idx=-1 dispatch_guard_idx=-1 target_lookup_idx=-1 diff_facts_idx=-1 compose_idx=-1
for _pub_i in "${!pub_lines[@]}"; do
    _pub_line=${pub_lines[$_pub_i]}
    if ((decisions_guard_idx < 0)) && [[ $_pub_line == *'pr_decisions_file=${pr_decisions_file:?'* ]]; then
        decisions_guard_idx=$_pub_i
    fi
    if ((resolver_guard_idx < 0)) && [[ $_pub_line == *'agentkit unresolved: prepend the Step 0 resolver block'* ]]; then
        resolver_guard_idx=$_pub_i
    fi
    if ((dispatch_guard_idx < 0)) && [[ $_pub_line == *'dispatch_plan=${dispatch_plan:?root-owned dispatch-plan artifact for this run}'* ]]; then
        dispatch_guard_idx=$_pub_i
    fi
    if ((target_lookup_idx < 0)) && [[ $_pub_line == *'publication_target=$(jq -er'* ]]; then
        target_lookup_idx=$_pub_i
    fi
    if ((diff_facts_idx < 0)) && [[ $_pub_line == *'"$agentkit/.shared/scripts/diff-facts.sh" --repo-root "$worktree"'* ]]; then
        diff_facts_idx=$_pub_i
    fi
    if ((compose_idx < 0)) && [[ $_pub_line == *'"$agentkit/parallel-issues/scripts/pr-stage.sh" open'* ]]; then
        compose_idx=$_pub_i
    fi
done
assert_eq yes "$([[ $decisions_guard_idx -ge 0 && $diff_facts_idx -ge 0 && $diff_facts_idx -gt $decisions_guard_idx ]] && printf yes || printf no)" \
    'the disclosure recipe runs after $pr_decisions_file is guarded, never before'
assert_eq yes "$([[ $resolver_guard_idx -ge 0 && $diff_facts_idx -ge 0 && $diff_facts_idx -gt $resolver_guard_idx ]] && printf yes || printf no)" \
    'the disclosure recipe runs after the resolver establishes $agentkit, never before'
assert_eq yes "$([[ $dispatch_guard_idx -ge 0 && $target_lookup_idx -gt $dispatch_guard_idx && $target_lookup_idx -lt $compose_idx ]] && printf yes || printf no)" \
    'the publication recipe validates and reads its dispatch plan before composing the body'
assert_eq yes "$([[ $compose_idx -ge 0 && $diff_facts_idx -ge 0 && $diff_facts_idx -lt $compose_idx ]] && printf yes || printf no)" \
    'the disclosure recipe runs before pr-stage.sh consumes the Decisions file'

v1_home="$tmp/v1-home"
mkdir -p "$v1_home"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 10' 'max_depth = 2' \
    > "$v1_home/config.toml"
out=$("$cap_helper" --config "$v1_home/config.toml" 2>/dev/null)
status=$?
assert_contains "$out" 'effective concurrency cap: 10 total threads, including the root' \
    'the v1 [agents] section advertises the cap'
assert_eq '0' "$status" 'a v1 [agents] cap exits zero'

v2_home="$tmp/v2-home"
mkdir -p "$v2_home"
printf '%s\n' '[features.multi_agent_v2]' 'enabled = true' \
    'max_concurrent_threads_per_session = 8' > "$v2_home/config.toml"
out=$("$cap_helper" --config "$v2_home/config.toml" 2>/dev/null)
status=$?
assert_contains "$out" 'effective concurrency cap: 8 total threads, including the root' \
    'the v2 [features.multi_agent_v2] section advertises the cap'
assert_eq '0' "$status" 'a v2 [features.multi_agent_v2] cap exits zero'

commented_home="$tmp/commented-home"
mkdir -p "$commented_home"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 10' \
    '# [features.multi_agent_v2]' '# max_concurrent_threads_per_session = 99' \
    > "$commented_home/config.toml"
out=$("$cap_helper" --config "$commented_home/config.toml" 2>/dev/null)
assert_contains "$out" 'effective concurrency cap: 10 total threads, including the root' \
    'a commented-out v2 block does not shadow the live [agents] cap'

missing_home="$tmp/missing"
mkdir -p "$missing_home"
err=$("$cap_helper" --config "$missing_home/config.toml" 2>&1 >/dev/null)
status=$?
assert_contains "$err" 'Unable to advertise concurrency' \
    'missing runtime config explains why the cap is unavailable'
assert_not_contains "$err" 'spawn refused:' \
    'cap-advertisement failure remains distinct from capacity refusal'
assert_eq 'nonzero' "$( (( status != 0 )) && printf nonzero || printf zero )" \
    'missing runtime config exits nonzero so dispatch stops'
assert_rc 0 'state-backed admission uses the Codex V2 runtime default when config is absent' -- \
    "$cap_helper" --config "$missing_home/config.toml" --spawn-capable \
    --assert-count 4 --agent-kind reviewer
assert_rc 1 'state-backed admission refuses above the Codex V2 runtime default without config' -- \
    "$cap_helper" --config "$missing_home/config.toml" --spawn-capable \
    --assert-count 5 --agent-kind reviewer

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
assert_contains "$normalized_text" 'Worker collection windows are **900 s**, draft-loop/review/CI observation windows **600 s**' \
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
assert_contains "$normalized_text" 'In the next user-visible update, name any non-zero `last-rc` and its `last-verification` log basename' \
    'the next root update preserves a failed verification outcome'

# Issue #810: the liveness sample also carries the newest completed verification
# outcome, so failed retries cannot disappear between worker handbacks.
stall_helper="$root/agentkit/skills/parallel-issues/scripts/stall-check.sh"
failed_wt="$tmp/stall-failed"
mkdir -p "$failed_wt/.agent/logs" "$failed_wt/src"
printf 'work\n' >"$failed_wt/src/a.txt"
printf '=== agent-run exited rc=0 after 1s\n' >"$failed_wt/.agent/logs/20260918T030013Z-test.log"
printf '=== agent-run exited rc=1 after 2s\n' >"$failed_wt/.agent/logs/20260918T031501Z-test.log"
printf '=== agent-run test still-running\n' >"$failed_wt/.agent/logs/20260918T031902Z-test.log"
touch -d '2026-09-18 03:00:13 UTC' "$failed_wt/.agent/logs/20260918T030013Z-test.log"
touch -d '2026-09-18 03:15:01 UTC' "$failed_wt/.agent/logs/20260918T031501Z-test.log"
touch -d '2026-09-18 03:19:02 UTC' "$failed_wt/.agent/logs/20260918T031902Z-test.log"
out=$("$stall_helper" --worktree "$failed_wt" --state "$tmp/stall-failed-state")
assert_eq 0 $? 'a failed last verification does not change the active exit code'
assert_contains "$out" 'last-verification=20260918T031501Z-test.log last-rc=1' \
    'the newest completed failure is reported while a newer run is in flight'

passed_wt="$tmp/stall-passed"
mkdir -p "$passed_wt/.agent/logs" "$passed_wt/src"
printf 'work\n' >"$passed_wt/src/a.txt"
printf '=== agent-run exited rc=1 after 1s\n' >"$passed_wt/.agent/logs/20260918T030013Z-test.log"
printf '=== agent-run exited rc=0 after 2s\n' >"$passed_wt/.agent/logs/20260918T031501Z-test.log"
touch -d '2026-09-18 03:00:13 UTC' "$passed_wt/.agent/logs/20260918T030013Z-test.log"
touch -d '2026-09-18 03:15:01 UTC' "$passed_wt/.agent/logs/20260918T031501Z-test.log"
out=$("$stall_helper" --worktree "$passed_wt" --state "$tmp/stall-passed-state")
assert_contains "$out" 'last-verification=20260918T031501Z-test.log last-rc=0' \
    'the newest completed passing verification is reported'

empty_wt="$tmp/stall-empty"
mkdir -p "$empty_wt/.agent/logs" "$empty_wt/src"
printf 'work\n' >"$empty_wt/src/a.txt"
out=$("$stall_helper" --worktree "$empty_wt" --state "$tmp/stall-empty-state")
assert_contains "$out" 'last-verification=none last-rc=none' \
    'an empty log directory reports the absence of verification evidence'

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

# --- issue #224: references read once (WS2d), now shared -------------------
reading_discipline_text=$(<"$root/agentkit/skills/.shared/reading-discipline.md")
normalized_reading_discipline=$(tr '\n' ' ' <<<"$reading_discipline_text" | tr -s '[:space:]' ' ')
assert_contains "$normalized_reading_discipline" 'fully once per uninterrupted context' \
    'parallel skill still reads each reference once, in batches'
assert_contains "$normalized_text" 'references whose conditions match' \
    'reference loading follows manifest conditions on the selected execution path'
assert_contains "$normalized_reading_discipline" 'Start the read directly' \
    'named references are fully loaded at their binding step'
assert_contains "$normalized_reading_discipline" 'batching independent reads' \
    'references reached together are batched'
assert_contains "$normalized_reading_discipline" 'Reuse loaded content' \
    'a loaded reference is not read twice'
assert_contains "$reading_discipline_text" 'wc -l' \
    'the no-sizing rule names the observed probe explicitly'
assert_contains "$reading_discipline_text" '`wc -l`, `stat`, `head`' \
    'routine reference sizing forbids all named probes'
assert_contains "$normalized_reading_discipline" 'There is no size threshold to discover first' \
    'the no-sizing default explains that no preliminary probe is needed'
assert_contains "$normalized_reading_discipline" 'injected skill body is already authoritative context' \
    'shared discipline forbids rereading an injected body'

# --- issue #427: reference reads follow the selected execution path ----------
assert_contains "$normalized_text" 'Single issue, no chain:' \
    'the common single-issue path names its dispatch reference set explicitly'
single_issue_reference_set=$(awk '
    /Single issue, no chain:/ { capture=1 }
    capture { print }
    capture && /Defer chain\/review references/ { exit }
' "$skill")
assert_not_contains "$single_issue_reference_set" 'references/chains.md' \
    'the single-issue no-chain dispatch set excludes chain material'
assert_not_contains "$single_issue_reference_set" 'review-remote-pr/references/' \
    'the dispatch set excludes review-phase references'
assert_contains "$single_issue_reference_set" '"$agentkit/references.md"' \
    'the single-issue dispatch set retains the reference manifest'
assert_contains "$single_issue_reference_set" 'references/triage-and-selection.md' \
    'the single-issue dispatch set retains triage and selection rules'
# Issue #708: Step 2 must agree with the section-conditional read policy.
assert_not_contains "$normalized_text" '(references/triage-and-selection.md) in full' \
    'triage never requests an unanchored whole-reference read'
assert_contains "$normalized_text" '(references/triage-and-selection.md#prior-art-adjudication-only-for-merged-ref-in-flight-and-attempted)' \
    'triage links directly to prior-art adjudication'
assert_contains "$normalized_text" '(references/triage-and-selection.md#board-adjudication)' \
    'triage links directly to board adjudication'
assert_contains "$normalized_text" 'Digest flags: read [prior-art]' \
    'adjudication section reads remain conditional on digest flags'
assert_contains "$normalized_text" '; skip `clean`.' \
    'clean issues require no adjudication reference reads'
assert_contains "$single_issue_reference_set" 'references/implementation-worker.md' \
    'the common dispatch path reads only the issue-lead template'
assert_not_contains "$single_issue_reference_set" 'references/worker-prompts.md' \
    'the common dispatch path does not read setup and publication templates'
assert_contains "$single_issue_reference_set" '.shared/spawn-contract.md' \
    'the single-issue dispatch set retains the spawn contract'
assert_contains "$single_issue_reference_set" '.shared/six-step-loop.md' \
    'the single-issue dispatch set retains the six-step loop'
assert_contains "$normalized_text" 'never preload review material during dispatch/worker waits' \
    'review references remain gated until the review phase'
assert_contains "$normalized_text" 'Read `references/chains.md` in full only when the selected set contains a chain' \
    'chain material is gated on an actual selected chain'
assert_contains "$normalized_text" 'Read [references/chains.md](references/chains.md) in full before applying a revised dispatch plan whenever late overlap selects chain-conversion or merge-down' \
    'late-overlap chain conversion loads chain rules before revising the plan'
assert_contains "$normalized_text" 'successor swaps require a revision' \
    'dispatch-plan compaction preserves the successor-swap audit rule'
assert_contains "$normalized_text" 'non-empty repository-relative `predictedWriteSet`' \
    'dispatch-plan compaction preserves repository-relative non-empty predictions'
assert_contains "$normalized_text" 'shared build config, lockfiles, and generated contracts' \
    'dispatch-plan compaction preserves shared conflict inputs'
assert_contains "$normalized_text" 'Selection consumes `$agentkit/.shared/scripts/pick-issues.sh` output only' \
    'selection uses the body-free picker record as its sole mechanical input'
assert_contains "$normalized_text" 'workShape: "no-code"' \
    'selection holds the picker-record no-code verdict before worktree creation'
assert_contains "$normalized_text" '(references/triage-and-selection.md#work-shape-verdict)' \
    'the compact no-code rule retains its adjudication anchor'
assert_contains "$normalized_text" 'never sufficient conflict evidence by itself' \
    'an empty or partial literal path seed cannot prove no conflict'
assert_contains "$normalized_text" 'requirementsDigest' \
    'conflict analysis expands paths from cached issue requirements'
assert_not_contains "$normalized_text" 'Read each issue' \
    'root conflict analysis does not reread issue bodies or repository documents'
assert_not_contains "$worker_prompts_only_text" '## Issue-lead prompt' \
    'the broad prompt reference no longer contains issue-lead material'
assert_not_contains "$worker_prompts_only_text" '### Root completion classification' \
    'root completion classification lives with the issue-lead contract'
assert_contains "$implementation_worker_text" '## Issue-lead prompt' \
    'the dedicated implementation-worker reference owns the issue-lead template'
assert_contains "$implementation_worker_text" '### Root completion classification' \
    'the dedicated implementation-worker reference owns root completion classification'
assert_contains "$normalized_text" 'validate dispatch, ownership, Git and logs before accepting' \
    'Collect validates a worker result before accepting it'
assert_contains "$normalized_text" 'Keep root CI/review obligations' \
    'Collect preserves root CI and review duties across resume'
assert_contains "$normalized_text" 'unchanged accepted receipts resume without repeated work' \
    'Collect reuses only receipts already accepted by root'
call_site_boundary=$(sed -n '/^## Resident call-site map$/,/^\*\*Single issue/p' "$skill")
assert_contains "$call_site_boundary" $'lazy references |\n\n**Single issue' \
    'the resident call-site table ends before the following single-issue paragraph'
# Issue #904 adds explicit commit -> full verification -> push recovery steps
# to both worker contracts so an unchanged candidate is verified only once.
# #903 adds the concurrent review/fix ownership contract at the dispatch site.
# #902 review adds evidence-bearing terminal recipes and remote-spend reuse flags.
prose_lines=$(wc -l < "$skill")
prose_lines=$((prose_lines + $(wc -l < "$triage_and_selection") + $(wc -l < "$worker_prompts") + $(wc -l < "$implementation_worker")))
# #907: the one-call startup/resume binding recipe replaces remembered run,
# session, ledger, and explicit rebind operands; preserve that boundary in the combined contract.
# #909: eight review-repair lines pin the saved-target lookup and default-target
# closing-linkage condition before PR body composition.
# #911 adds the protected preparation/approval/resume contract at the worker
# and dispatch-plan boundaries; keep that deliberate growth ratcheted here.
# #910 adds the complete join/resolution recipe that prevents partial-base
# dispatch and repeated recovery turns; ratchet the exact combined boundary.
# #914 integration preserves both complete source contracts.
# #908: eleven publication lines make the diff disclosure retry-idempotent and
# bind the saved publication target to the environment default branch.
assert_eq yes "$([[ $prose_lines -le 2388 ]] && printf yes || printf no)" \
    'combined workflow prose stays below its measured aggregate line count'
assert_contains "$normalized_text" 'upgrade the same owner-only file from schema-1 `--dispatch-plan` to schema-2 `--merge-plan`' \
    'ready-flip handoff preserves the in-place lifecycle upgrade'
assert_contains "$normalized_text" 'merge updated default down and push' \
    'ready-flip handoff preserves the default-branch merge-down and push'
assert_contains "$normalized_text" 'Exit 1 means no confirmed edit; exit 2 means applied base, then proof failure' \
    'ready-flip handoff preserves chain-advance exit semantics'
assert_contains "$normalized_text" 'baseRefName, ancestry, CI/approval, and closing linkage' \
    'ready-flip handoff preserves the complete successor proof'
assert_contains "$normalized_text" 'verification-isolation.md"](references/verification-isolation.md) in full when the repository declares a Compose-driven command or any `agent-run.sh` result must be interpreted' \
    'verification isolation covers Compose and result interpretation paths'
assert_contains "$reference_manifest_text" $'```text\n- `$agentkit/<path relative to the skills tree>`' \
    'the reference-manifest grammar fence declares text syntax'
assert_contains "$reference_manifest_text" 'verification-isolation.md` -- Compose project isolation and how to read an `agent-run.sh` failure, including the environment-retry-eligible finding | Read when: the repository declares a Compose-driven command or any `agent-run.sh` result must be interpreted' \
    'dispatch reads verification isolation for Compose or agent-run result interpretation'
assert_contains "$reference_manifest_text" 'adversarial-review.md` -- the Step 1b adversarial-review contract: materiality, attribution, external-service authorization, cross-provider consent, and the exit-code table | Read when: review Phase A reaches Step 1b or any skill runs an adversarial cross-review' \
    'dispatch reads adversarial-review for Step 1b or any cross-review caller'

assert_contains "$text" 'Root-checkout cross-write fence' \
    'dispatch documents the root dirt snapshot boundary'
assert_contains "$text" 'cross-write-check.sh' \
    'dispatch names the deterministic cross-write checker'
cross_write_snapshot_recipe="$tmp/cross-write-snapshot-recipe.sh"
awk '
    /^### Root-checkout cross-write fence$/ { section=1; next }
    section && /^```bash$/ { capture=1; next }
    capture && /^```$/ { exit }
    capture { print }
' "$skill" >"$cross_write_snapshot_recipe"
cross_write_collect_recipe="$tmp/cross-write-collect-recipe.sh"
awk '
    /^### Root-checkout cross-write fence$/ { section=1; next }
    section && /^```bash$/ { block++; next }
    block == 2 && /^```$/ { exit }
    block == 2 { print }
' "$skill" >"$cross_write_collect_recipe"
assert_contains "$(<"$cross_write_snapshot_recipe")" '--run-id "$RUN_ID"' \
    'the pre-dispatch recipe binds the snapshot to the run identity'
assert_contains "$(<"$cross_write_collect_recipe")" '--baseline-id "$cross_baseline_id"' \
    'the canonical fence recipe reuses the recorded baseline identity'
assert_contains "$(<"$cross_write_snapshot_recipe")" 'cross-write-dispatch-$RUN_ID.snapshot' \
    'the canonical fence recipe scopes immutable snapshots to the run identity'
assert_contains "$normalized_text" 'Never fold dirt first observed inside a dispatch window' \
    'handoff never misattributes run-window dirt to the human'
assert_contains "$normalized_text" 'date -u +%FT%T.%NZ' \
    'dispatch records worker boundaries with subsecond precision'
assert_contains "$normalized_text" 'dispatch audit rejects it as ambiguous' \
    'dispatch documents fail-closed coarse same-second chronology'
assert_contains "$worker_prompts_text" 'paths-touched.ndjson' \
    'worker prompts preserve per-tool write-target evidence'
assert_contains "$worker_prompts_text" '__BLOCKER_CONTRACT__' \
    'worker prompt template reserves the blocker contract insertion point'

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

recipe_root="$tmp/cross-recipe-root"
recipe_worker="$tmp/cross-recipe-worker"
mkdir -p "$recipe_root/.agent" "$recipe_root/src"
git -C "$recipe_root" init -q -b main
printf 'base\n' >"$recipe_root/src/data.txt"
git -C "$recipe_root" add src/data.txt
git -C "$recipe_root" -c user.name=t -c user.email=t@example.invalid commit -qm base
git -C "$recipe_root" worktree add -q -b feat/recipe "$recipe_worker"
run_cross_snapshot_recipe() {
    local recipe_run_id=$1
    local recipe_agentkit=${2:-$root/agentkit/skills}
    REAL_RUN_STATE="$root/agentkit/skills/.shared/scripts/run-state.sh" \
        agentkit="$recipe_agentkit" repository_root="$recipe_root" RUN_ID="$recipe_run_id" \
        bash -c 'all_dispatched_write_sets=("src/**"); source "$1"' \
        _ "$cross_write_snapshot_recipe"
}
run_cross_collect_recipe() {
    local recipe_run_id=$1 recipe_start=$2
    agentkit="$root/agentkit/skills" repository_root="$recipe_root" \
        RUN_ID="$recipe_run_id" worktree="$recipe_worker" issue_number=830 \
        worker_started_at="$recipe_start" worker_finished_at=2147483647 \
        bash -c 'worker_write_sets=("src/**"); source "$1"' \
        _ "$cross_write_collect_recipe"
}
snapshot_recipe_rc=0
run_cross_snapshot_recipe recipe-830 >/dev/null || snapshot_recipe_rc=$?
assert_eq 0 "$snapshot_recipe_rc" 'the canonical pre-dispatch recipe creates its baseline'
recipe_start=$(date -u +%FT%T.%NZ)
recipe_out=''
recipe_rc=0
recipe_out=$(run_cross_collect_recipe recipe-830 "$recipe_start") || recipe_rc=$?
assert_eq 0 "$recipe_rc" 'the canonical cross-write recipe completes against real worktrees'
assert_contains "$recipe_out" 'cross-write=none' \
    'a baseline captured before the worker produces valid clean dispatch evidence'
recipe_baseline_id=$(
    "$root/agentkit/skills/.shared/scripts/run-state.sh" get --run-id recipe-830 \
        --repo-root "$recipe_root" --path cross_write.baseline_id
)
assert_eq yes "$([[ $recipe_baseline_id =~ ^[0-9a-f]{64}$ ]] && printf yes || printf no)" \
    'the canonical recipe durably records the original baseline identity'
recipe_snapshot="$recipe_root/.agent/cross-write-dispatch-recipe-830.snapshot"
recipe_snapshot_hash=$(sha256sum "$recipe_snapshot" 2>/dev/null || true)
resume_rc=0
resume_out=$(run_cross_collect_recipe recipe-830 "$recipe_start") || resume_rc=$?
assert_eq 0 "$resume_rc" 'same-run resume reuses the recorded dispatch baseline'
assert_contains "$resume_out" 'cross-write=none' 'same-run resume retains clean dispatch evidence'
assert_eq "$recipe_snapshot_hash" "$(sha256sum "$recipe_snapshot" 2>/dev/null || true)" \
    'same-run resume leaves the immutable snapshot byte-identical'

second_rc=0
run_cross_snapshot_recipe recipe-831 >/dev/null || second_rc=$?
second_start=$(date -u +%FT%T.%NZ)
second_out=$(run_cross_collect_recipe recipe-831 "$second_start") || second_rc=$?
assert_eq 0 "$second_rc" 'a distinct run creates and uses an independent baseline'
assert_contains "$second_out" 'cross-write=none' 'a distinct run can produce clean dispatch evidence'
assert_eq yes "$([[ -f $recipe_root/.agent/cross-write-dispatch-recipe-831.snapshot ]] && printf yes || printf no)" \
    'distinct run identities use distinct snapshot paths'

printf 'unrecorded\n' >"$recipe_root/.agent/cross-write-dispatch-recipe-orphan.snapshot"
orphan_rc=0
run_cross_snapshot_recipe recipe-orphan >/dev/null 2>&1 || orphan_rc=$?
assert_eq 1 "$orphan_rc" 'the recipe refuses an unrecorded pre-existing snapshot'
orphan_state_rc=0
"$root/agentkit/skills/.shared/scripts/run-state.sh" get --run-id recipe-orphan \
    --repo-root "$recipe_root" --path cross_write.baseline_id >/dev/null 2>&1 || orphan_state_rc=$?
assert_eq 11 "$orphan_state_rc" 'refusal never adopts the unrecorded snapshot identity'

missing_rc=0
run_cross_collect_recipe recipe-missing "$(date +%s)" >/dev/null 2>&1 || missing_rc=$?
assert_eq 1 "$missing_rc" 'Collect refuses a run with no persisted baseline identity'
assert_eq no "$([[ -e $recipe_root/.agent/cross-write-dispatch-recipe-missing.snapshot ]] && printf yes || printf no)" \
    'Collect never creates a missing pre-dispatch baseline'

failing_agentkit="$tmp/failing-agentkit"
mkdir -p "$failing_agentkit/parallel-issues/scripts" "$failing_agentkit/.shared/scripts"
ln -s "$cross_write" "$failing_agentkit/parallel-issues/scripts/cross-write-check.sh"
cat >"$failing_agentkit/.shared/scripts/run-state.sh" <<'EOF'
#!/usr/bin/env bash
[[ ${1-} != set ]] || exit 1
exec "$REAL_RUN_STATE" "$@"
EOF
chmod +x "$failing_agentkit/.shared/scripts/run-state.sh"
persist_rc=0
run_cross_snapshot_recipe recipe-persist-fail "$failing_agentkit" >/dev/null 2>&1 || persist_rc=$?
assert_eq 1 "$persist_rc" 'the pre-dispatch recipe fails immediately when baseline persistence fails'
persist_state_rc=0
"$root/agentkit/skills/.shared/scripts/run-state.sh" get --run-id recipe-persist-fail \
    --repo-root "$recipe_root" --path cross_write.baseline_id >/dev/null 2>&1 || persist_state_rc=$?
assert_eq 11 "$persist_state_rc" 'a persistence failure never records a baseline identity'

snapshot="$cross_root/.agent/cross-write.snapshot"
snapshot_out=$(
    "$cross_write" snapshot --root "$cross_root" --output "$snapshot" \
        --write-set 'src/**'
)
assert_contains "$snapshot_out" 'snapshot=' \
    'dispatch snapshot reports its persisted path'

# --- issue #698: dispatch-fence folds the snapshot and collect calls into one
# subcommand, routed by the presence of --worker-worktree, so the SKILL.md
# recipe names a single entry point for both halves of the fence.
fence_snapshot="$cross_root/.agent/cross-write-fence.snapshot"
fence_snapshot_out=$(
    "$cross_write" dispatch-fence --root "$cross_root" --output "$fence_snapshot" \
        --run-id run-698 --write-set 'src/**'
)
assert_contains "$fence_snapshot_out" 'snapshot=' \
    'dispatch-fence with no --worker-worktree snapshots like the snapshot subcommand'
fence_baseline_id=${fence_snapshot_out##*baseline-id=}
printf 'fence worker bytes\n' > "$cross_worker/src/fence.txt"
printf 'fence worker bytes\n' > "$cross_root/src/fence.txt"
fence_start=$(date -u +%FT%T.%NZ)
fence_collect_out=$(
    "$cross_write" dispatch-fence --root "$cross_root" --snapshot "$fence_snapshot" \
        --worker-worktree "$cross_worker" --issue 698 --run-id run-698 \
        --baseline-id "$fence_baseline_id" \
        --worker-start "$fence_start" --worker-end 2147483647 --write-set 'src/**' || true
)
assert_contains "$fence_collect_out" 'src/fence.txt' \
    'dispatch-fence with --worker-worktree collects like the collect subcommand'
rm -f -- "$cross_root/src/fence.txt"

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
    "${3:-bash}" -f "$tmp/fence-run.sh" 2>/dev/null
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
if command -v zsh >/dev/null; then
    zsh_out=$(run_spawn_fence claude "$codex_declared_config" zsh)
    assert_eq 0 "$?" 'zsh runs the complete resolver with ordinary parent assignments'
    assert_contains "$zsh_out" 'claude-sonnet-5 claude-sonnet-5' 'zsh receives resolver model outputs'
    assert_contains "$zsh_out" "pivoted from cross-harness declaration 'gpt-5.6-luna'" 'zsh receives the resolver pivot note'
    zsh_out=$(run_spawn_fence codex "$typo_config" zsh)
    assert_eq 1 "$?" 'zsh stops after an unsanctioned resolver result'
    assert_eq '' "$zsh_out" 'zsh does not dispatch after failed resolution'
else
    printf 'SKIP: zsh resolver runtime checks (shell unavailable)\n'
fi

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
