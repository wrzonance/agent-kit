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
ci_workflow="$root/.github/workflows/ci.yml"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

text=$(<"$skill")
normalized_text=$(tr '\n' ' ' <<<"$text" | tr -s '[:space:]' ' ')
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
worker_gate_text=$(<"$worker_gate")
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
assert_contains "$worker_prompts_text" '--yolo --yolo-base $chain_base_sha' \
    'chained WHEN-yolo threading pins the base'
assert_contains "$text" 'only after the root has validated, committed, and pushed' \
    'chain successors defer on root publication, not PR state'
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
assert_contains "$root_fence_section" 'if [[ $yolo_invocation == true ]]; then' \
    'root derives boundary mode from the explicit invocation'
assert_contains "$root_fence_section" 'boundary_mode=private-trusted' \
    'private visibility selects the trusted boundary'
assert_contains "$root_fence_section" 'boundary_mode=public-fenced' \
    'unknown visibility has a public fenced fallback'
assert_contains "$prepare_script_text" 'if [[ $boundary_mode == public-fenced ]]; then' \
    'trusted modes persist exact bytes without invoking the fence helper'
assert_contains "$root_fence_section" 'printf '\''boundary mode: %s\n'\'' "$boundary_mode"' \
    'root prints the selected boundary mode'
dispatch_handoff=$(sed -n '/^Per-issue prompt:/,/^### Collect (per-completion/p' <<< "$text")
assert_contains "$dispatch_handoff" 'trap cleanup_prompt_file EXIT HUP INT TERM' \
    'dispatch handoff cleans its private prompt file on every exit path'
assert_contains "$dispatch_handoff" 'if ! "$compose_script" "${compose_args[@]}"; then' \
    'dispatch handoff stops when prompt composition fails'
assert_contains "$dispatch_handoff" 'cat -- "$prompt_file"' \
    'dispatch handoff emits the composed prompt bytes'
assert_not_contains "$dispatch_handoff" ': "$worker_prompt"' \
    'dispatch handoff does not discard the composed prompt'
boundary_snippet=$(awk '
    /^if \[\[ \$yolo_invocation == true \]\]; then$/ { capture=1 }
    capture { print }
    capture && /^printf '\''boundary mode:/ { exit }
' "$skill")
assert_contains "$boundary_snippet" 'boundary_mode=public-fenced' \
    'boundary selector snippet is extractable for regression checks'
for visibility in false unknown ''; do
    selected=$(repository_visibility="$visibility" yolo_invocation=false bash -c "$boundary_snippet" 2>/dev/null | tail -n 1)
    assert_eq 'boundary mode: public-fenced' "$selected" \
        "visibility '$visibility' fails closed to public-fenced"
done
selected=$(repository_visibility=false yolo_invocation=true bash -c "$boundary_snippet" 2>/dev/null | tail -n 1)
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
assert_contains "$text" '`--trust-trunk`' \
    'dispatch contract documents the standalone trunk-trust flag'
assert_contains "$text" 'Attended command-approval handoff' \
    'attended dispatch has one approval handoff section'
assert_contains "$text" 'one line per worktree per needed' \
    'approval handoff batches every predictable command approval'
assert_contains "$text" 'agent-run.sh --approve --cmd <name>' \
    'approval handoff carries a copy-pasteable command recipe'
assert_contains "$text" 'never hand off the main checkout' \
    'approval recipes reject the main checkout'
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
    assert_contains "$prompt_text" 'report the incident and restoration in the handback' "$prompt_label reports restored incidents"
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
    assert_contains "$prompt_text" '<WHEN this parallel-issues invocation carried --yolo' \
        "$prompt_label carries the --yolo WHEN placeholder"
done
assert_contains "$text" 'set its working directory to the assigned worktree' 'dispatcher sets worker cwd when supported'
assert_contains "$issue_lead_prompt" 'publication handback' 'issue lead returns a publication handback'
assert_contains "$draft_loop_prompt" 'publication handback' 'phase lead returns a publication handback'
for prompt_label in 'issue-lead prompt' 'draft-loop prompt'; do
    prompt_text=$([[ $prompt_label == 'issue-lead prompt' ]] && printf '%s' "$issue_lead_prompt" || printf '%s' "$draft_loop_prompt")
    assert_contains "$prompt_text" 'contract="$worktree/.agent/env-contract.txt"' "$prompt_label derives its contract trailer"
    assert_contains "$prompt_text" 'AGENT_TRAILER=$(sed -n' "$prompt_label parses the harness trailer"
    assert_contains "$prompt_text" '[ -n "$AGENT_TRAILER" ] ||' "$prompt_label guards an empty harness trailer"
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
assert_contains "$text" 'push the branch' 'root pushes after executing the handback'
assert_contains "$text" 'open a DRAFT PR' 'root opens the draft PR after publication'
assert_contains "$normalized_text" 'Why, What, Design decisions, tickable Testing, agent credit, and Closes #NNN' \
    'root draft PR carries the required report fields'
assert_contains "$text" 'PR URL feeds Collect and Step 3a' \
    'root feeds the resulting PR URL into collection and draft dispatch'
assert_contains "$text" 'worker leaves scoped changes unstaged and returns a publication handback' \
    'Finish leaves worker changes unstaged for root publication'
assert_contains "$text" 'Step 3b workers receive only root-approved fix batches' \
    'Step 3b restricts workers to root-approved mechanical batches'
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
assert_contains "$text" 'mapfile -d' \
    'parallel dispatch consumes validated handback argv without re-parsing shell text'
assert_contains "$text" '((${#validated_argv[@]})) || exit 1' \
    'parallel dispatch rejects empty validated argv'
assert_contains "$text" 'cd -- "$worktree"' \
    'parallel dispatch executes the validated argv in the worktree'
assert_contains "$text" 'expected worktree-commit.sh helper' \
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
# The draft-PR body template heredoc recipe is single-sourced in
# references/worker-prompts.md (issue #107 phase 3's split) -- it is
# dispatch-output content read at publication time, not a worker prompt, but
# it lives beside the worker prompts it is read alongside. SKILL.md's body
# keeps only a gate statement + pointer at the binding step.
publication_section=$(
    sed -n '/^## Draft PR body template$/,/^## Fix-batch worker prompt$/p' "$worker_prompts"
)
assert_contains "$publication_section" 'gh pr create --draft --body-file "$pr_body_file"' \
    'draft PR publication passes a newline-preserving body file to gh'
assert_contains "$publication_section" 'Never pass a multiline PR body through inline `--body`' \
    'draft PR publication forbids inline multiline body strings'
assert_contains "$publication_section" "cat >\"\$pr_body_template\" <<'EOF'" \
    'draft PR publication uses a quoted heredoc for literal body bytes'
assert_not_contains "$publication_section" 'body=${body//__AGENT_IDENTITY__/$agent_identity}' \
    'draft PR publication never uses replacement-string expansion for identity bytes'
assert_not_contains "$publication_section" 'body=${body//__PR_CLOSE_LINE__/$pr_close_line}' \
    'draft PR publication never uses replacement-string expansion for close-line bytes'
assert_contains "$publication_section" 'body_prefix=${body%%__AGENT_IDENTITY__*}' \
    'draft PR publication isolates the identity prefix without replacement expansion'
assert_contains "$publication_section" 'body_remainder=${body#*__AGENT_IDENTITY__}' \
    'draft PR publication isolates the body remainder without replacement expansion'
assert_contains "$publication_section" 'body_middle=${body_remainder%%__PR_CLOSE_LINE__*}' \
    'draft PR publication isolates the close-line prefix without replacement expansion'
assert_contains "$publication_section" 'body_suffix=${body_remainder#*__PR_CLOSE_LINE__}' \
    'draft PR publication isolates the close-line suffix without replacement expansion'
assert_contains "$publication_section" 'printf %s "$body" >"$pr_body_file"' \
    'draft PR publication writes the substituted body without shell expansion'
assert_not_contains "$publication_section" '<<EOF' \
    'draft PR publication has no interpolating heredoc'
assert_contains "$publication_section" 'chmod 600 -- "$pr_body_file"' \
    'draft PR publication secures the body file with mode 600'
assert_contains "$publication_section" 'pr_body_template=$(mktemp "${TMPDIR:-/tmp}/parallel-issues-pr-body-template.XXXXXXXXXX")' \
    'draft PR publication allocates an independent template file'
assert_not_contains "$publication_section" 'pr_body_template="$pr_body_file.template"' \
    'draft PR publication never derives a predictable template path'
assert_contains "$publication_section" 'chmod 600 -- "$pr_body_file" "$pr_body_template"' \
    'draft PR publication secures both body files with mode 600'
assert_not_contains "$publication_section" 'cat >"$pr_body_file.template"' \
    'draft PR publication never writes through the derived template path'
assert_contains "$publication_section" 'trap '\''rm -f -- "$pr_body_file" "$pr_body_template"'\'' EXIT' \
    'draft PR publication removes both body files on exit'
assert_contains "$publication_section" 'agent_identity=${agent_identity:?' \
    'draft PR publication requires an agent identity before interpolation'
assert_contains "$publication_section" 'pr_close_line=${pr_close_line:?' \
    'draft PR publication requires a close line before interpolation'
assert_contains "$publication_section" '__AGENT_IDENTITY__' \
    'draft PR publication keeps the identity placeholder literal in the template'
assert_contains "$publication_section" '__PR_CLOSE_LINE__' \
    'draft PR publication keeps the close placeholder literal in the template'
assert_contains "$publication_section" 'Stacked on #' \
    'stacked PRs declare their base PR in the body'
assert_contains "$publication_section" 'retarget this PR to the default branch' \
    'stacked body instructs an explicit retarget, never reliance on branch deletion'
assert_contains "$text" 'verify the successor'"'"'s baseRefName' \
    'chain merge order requires verified retargeting before a successor merges'
assert_contains "$publication_section" 'only retargets automatically when the base branch is deleted' \
    'stacked body explains the auto-retarget unwind'
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
assert_not_contains "$text" '` --yolo`' \
    'parallel dispatch has no MD038-leading-space code span'

# Root safeguards are asserted only in bounded orchestration/publication
# sections. Worker prompt prose may mention the same words with different
# ownership semantics and must not satisfy these root-only checks.
root_sections=$(
    sed -n '/^### Root canonical issue fetch and fence preparation$/,/^Per-issue prompt:$/p' "$skill"
    sed -n '/^### Root publication after a worker handback$/,/^### Polling discipline/p' "$skill"
    sed -n '/^## Runtime and provider neutrality$/,/^## Automated review provider rules/p' "$review_skill"
    sed -n '/^## Implementation-worker gate$/,/^## Root-owned publication handback$/p' "$worker_gate"
    sed -n '/^## Root-owned publication handback$/,$p' "$worker_gate"
    sed -n '/^## Step 0: Setup/,/^## Step 3 (Phase B)/p' "$review_skill"
)
assert_contains "$root_sections" 'never rebase' 'root-facing prose preserves merge-never-rebase guard'
assert_contains "$root_sections" 'git add -A' 'root-facing prose preserves explicit staging guard'
assert_contains "$root_sections" 'peer-cli= <name> absent' 'root-facing prose owns peer availability'
assert_contains "$root_sections" 'blind same-harness fallback' 'root-facing prose owns blind fallback'
assert_contains "$worker_gate_text" 'Workers are turn-and-burn' \
    'worker-gate.md pins the turn-and-burn handback contract'
assert_contains "$worker_gate_text" 'preserves the raw handback command text for audit' \
    'worker-gate.md pins the raw-command-text audit guard'
assert_contains "$worker_gate_text" 'validated argv without `eval`' \
    'worker-gate.md pins argv-without-eval parsing'
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
assert_eq '2' "$inner_open_count" \
    'inner bash examples retain their triple-backtick openings'
assert_eq '2' "$inner_close_count" \
    'inner bash examples retain their triple-backtick closers'

snippet=$(awk '
    index($0, "config_file=\"${CODEX_HOME:-$HOME/.codex}/config.toml\"") == 1 { capture=1 }
    capture && /^```$/ { exit }
    capture { print }
' "$skill")

configured_home="$tmp/configured"
mkdir -p "$configured_home/.codex"
printf '%s\n' '[multi_agent_v2]' 'max_concurrent_threads_per_session = 10' \
    > "$configured_home/.codex/config.toml"
out=$(env -u CODEX_HOME HOME="$configured_home" bash -c "$snippet" 2>/dev/null)
status=$?
assert_contains "$out" 'runtime concurrency cap: 10 total threads, including the root' \
    'dispatch advertises the configured runtime cap'
assert_eq '0' "$status" 'an advertised cap exits zero'

codex_home="$tmp/codex-home"
mkdir -p "$codex_home"
printf '%s\n' '[multi_agent_v2]' 'max_concurrent_threads_per_session = 7' \
    > "$codex_home/config.toml"
out=$(CODEX_HOME="$codex_home" HOME="$tmp/no-such-home" bash -c "$snippet" 2>/dev/null)
assert_contains "$out" 'runtime concurrency cap: 7 total threads, including the root' \
    'a CODEX_HOME override is honored over $HOME/.codex'

v1_home="$tmp/v1-home"
mkdir -p "$v1_home"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 10' 'max_depth = 2' \
    > "$v1_home/config.toml"
out=$(CODEX_HOME="$v1_home" HOME="$tmp/no-such-home" bash -c "$snippet" 2>/dev/null)
status=$?
assert_contains "$out" 'runtime concurrency cap: 10 total threads, including the root' \
    'the v1 [agents] section advertises the cap'
assert_eq '0' "$status" 'a v1 [agents] cap exits zero'

v2_home="$tmp/v2-home"
mkdir -p "$v2_home"
printf '%s\n' '[features.multi_agent_v2]' 'enabled = true' \
    'max_concurrent_threads_per_session = 8' > "$v2_home/config.toml"
out=$(CODEX_HOME="$v2_home" HOME="$tmp/no-such-home" bash -c "$snippet" 2>/dev/null)
status=$?
assert_contains "$out" 'runtime concurrency cap: 8 total threads, including the root' \
    'the v2 [features.multi_agent_v2] section advertises the cap'
assert_eq '0' "$status" 'a v2 [features.multi_agent_v2] cap exits zero'

commented_home="$tmp/commented-home"
mkdir -p "$commented_home"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 10' \
    '# [features.multi_agent_v2]' '# max_concurrent_threads_per_session = 99' \
    > "$commented_home/config.toml"
out=$(CODEX_HOME="$commented_home" HOME="$tmp/no-such-home" bash -c "$snippet" 2>/dev/null)
assert_contains "$out" 'runtime concurrency cap: 10 total threads, including the root' \
    'a commented-out v2 block does not shadow the live [agents] cap'

missing_home="$tmp/missing"
mkdir -p "$missing_home"
err=$(env -u CODEX_HOME HOME="$missing_home" bash -c "$snippet" 2>&1 >/dev/null)
status=$?
assert_contains "$err" 'Unable to advertise concurrency' \
    'missing runtime config explains why the cap is unavailable'
assert_eq 'nonzero' "$( (( status != 0 )) && printf nonzero || printf zero )" \
    'missing runtime config exits nonzero so dispatch stops'

finish
