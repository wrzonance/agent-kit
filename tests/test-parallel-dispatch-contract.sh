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
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

text=$(<"$skill")
assert_not_contains "$text" 'Between waits, read durable state instead of waiting again' \
    'polling does not inspect durable state between empty waits'
assert_contains "$text" 'Between waits, wait again; read durable state only when a wait reports an actual completion.' \
    'polling reads durable state only after completion'
assert_contains "$text" 'do not load `review-remote-pr/SKILL.md`' \
    'dispatch is self-contained without loading the worker skill'
assert_not_contains "$text" 'Four total slots including the root' \
    'dispatch does not hardcode the old slot count'
assert_not_contains "$text" 'Max 5 issues' \
    'limits do not hardcode the old issue count'
assert_contains "$text" 'max_concurrent_threads_per_session' \
    'dispatch reads the runtime concurrency setting'
assert_contains "$text" 'target="$worktree/.agent/fenced-spec.txt"' \
    'issue fencing uses the established excluded per-worktree path'
assert_contains "$text" 'target="$worktree/.agent/fenced-prior-art.txt"' \
    'issue preparation persists prior-art fence bytes'
root_fence_section=$(sed -n '/^### Root canonical issue fetch and fence preparation$/,/^Per-issue prompt:$/p' "$skill")
assert_contains "$root_fence_section" 'if [[ $yolo_invocation == true ]]; then' \
    'root derives boundary mode from the explicit invocation'
assert_contains "$root_fence_section" 'boundary_mode=private-trusted' \
    'private visibility selects the trusted boundary'
assert_contains "$root_fence_section" 'boundary_mode=public-fenced' \
    'unknown visibility has a public fenced fallback'
assert_contains "$root_fence_section" 'if [[ $boundary_mode == public-fenced ]]; then' \
    'trusted modes persist exact bytes without invoking the fence helper'
assert_contains "$root_fence_section" 'printf '\''boundary mode: %s\n'\'' "$boundary_mode"' \
    'root prints the selected boundary mode'
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
assert_contains "$text" 'that issue/status/phase is complete' \
    'a moved output line is terminal for its issue phase'
assert_not_contains "$text" 'target="$PWD/fenced-spec.txt"' \
    'issue fencing never writes untrusted bytes to the worktree root'
issue_lead_prompt=$(awk '
    /^Per-issue prompt:/ { capture=1; next }
    capture && /^````$/ { exit }
    capture { print }
' "$skill")
draft_loop_prompt=$(awk '
    /^\*\*Per-agent prompt template:\*\*$/ { capture=1; next }
    capture == 1 && /^```$/ { capture=2; next }
    capture == 2 && /^### Step 3c:/ { exit }
    capture == 2 {
        if (previous != "") print previous
        previous=$0
    }
' "$skill")

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
done
assert_not_contains "$issue_lead_prompt" 'issue_contents' 'issue lead does not produce fence content'
assert_not_contains "$issue_lead_prompt" 'prior_art_contents' 'issue lead does not produce prior-art fence content'
assert_not_contains "$issue_lead_prompt" 'fence-untrusted-data.sh' 'issue lead does not invoke the fence helper'
assert_not_contains "$draft_loop_prompt" 'issue_contents' 'phase lead does not produce fence content'
assert_not_contains "$draft_loop_prompt" 'prior_art_contents' 'phase lead does not produce prior-art fence content'
assert_not_contains "$draft_loop_prompt" 'fence-untrusted-data.sh' 'phase lead does not invoke the fence helper'
assert_contains "$root_fence_section" 'issue_contents=$(jq -r' 'root owns issue rendering'
assert_contains "$root_fence_section" 'fence-untrusted-data.sh' 'root owns fence helper invocation'
assert_contains "$root_fence_section" 'mv -f -- "$tmp" "$target"' 'root atomically publishes the spec fence'
assert_contains "$root_fence_section" 'mv -f -- "$prior_tmp" "$prior_target"' 'root atomically publishes the prior-art fence'
assert_contains "$text" 'push the branch' 'root pushes after executing the handback'
assert_contains "$text" 'open a DRAFT PR' 'root opens the draft PR after publication'
assert_contains "$text" 'Why, What, Design decisions, tickable Testing, agent credit, and Closes #NNN' \
    'root draft PR carries the required report fields'
assert_contains "$text" 'PR URL feeds Collect and Step 3a' \
    'root feeds the resulting PR URL into collection and draft dispatch'
root_sections=$(cat "$skill" "$review_skill")
assert_contains "$root_sections" 'never rebase' 'root-facing prose preserves merge-never-rebase guard'
assert_contains "$root_sections" 'git add -A' 'root-facing prose preserves explicit staging guard'
assert_contains "$root_sections" 'peer-cli= <name> absent' 'root-facing prose owns peer availability'
assert_contains "$root_sections" 'blind same-harness fallback' 'root-facing prose owns blind fallback'
assert_contains "$issue_lead_prompt" 'Read the authoritative `instructions=` line from `.agent/env-contract.txt`' \
    'issue leads use the preflight instruction contract'
assert_contains "$draft_loop_prompt" 'Use the authoritative `instructions=` line from `.agent/env-contract.txt`; inspect only' \
    'draft-loop workers use the bounded instruction contract'

outer_open_count=$(awk '$0 == "````text" { count++ } END { print count + 0 }' "$skill")
outer_close_count=$(awk '$0 == "````" { count++ } END { print count + 0 }' "$skill")
assert_eq '1' "$outer_open_count" \
    'the per-issue prompt has one four-backtick opening fence'
assert_eq '1' "$outer_close_count" \
    'the per-issue prompt has one four-backtick closing fence'

prompt_body=$(awk '
    $0 == "````text" { capture=1; next }
    capture && $0 == "````" { exit }
    capture { print }
' "$skill")
assert_contains "$prompt_body" '<PASTE the complete output selected by the boundary mode' \
    'the prompt placeholders remain inside the outer fence'
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
