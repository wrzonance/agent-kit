#!/usr/bin/env bash
# Boundary contract for issue #491's fast-mode review accounting.
# shellcheck disable=SC2016
set -uo pipefail

TEST_NAME='fast-mode-contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

parallel="$root/agentkit/skills/parallel-issues/SKILL.md"
review="$root/agentkit/skills/review-remote-pr/SKILL.md"
body_policy="$root/agentkit/skills/.shared/github-body-policy.md"
comment_composer="$root/agentkit/skills/review-remote-pr/scripts/compose-comment-body.sh"
worker_prompts="$root/agentkit/skills/parallel-issues/references/worker-prompts.md"
fast_reference="$root/agentkit/skills/parallel-issues/references/worker-prompts.md"
triage_reference="$root/agentkit/skills/parallel-issues/references/triage-and-selection.md"

parallel_text=$(<"$parallel")
review_text=$(<"$review")
policy_text=$(<"$body_policy")
worker_text=$(<"$worker_prompts")
fast_text=$(<"$fast_reference")
triage_text=$(<"$triage_reference")

# Fast mode must make one pushed diff and one combined finding batch observable.
assert_contains "$parallel_text$review_text$fast_text" 'same first pushed diff' \
    'fast mode binds root and adversarial review to the first pushed diff'
assert_contains "$parallel_text$review_text$fast_text" 'one combined fix batch' \
    'fast mode combines confirmed findings into one fix batch'
assert_contains "$parallel_text$review_text$fast_text" 'focused verification' \
    'fast mode uses focused verification during fix rounds'
assert_contains "$parallel_text$review_text$fast_text" 'full suite' \
    'fast mode requires one final full suite'
assert_contains "$parallel_text$review_text$fast_text" 'code-bearing fixes step effort down' \
    'code-bearing fix rounds reduce worker effort'
assert_contains "$parallel_text$review_text$fast_text" 'Initial work retains the declared worker tier' \
    'initial work keeps the declared worker tier'
assert_contains "$parallel_text$review_text$fast_text" 'tiny docs-only fixes' \
    'tiny docs-only fixes use the fastest tier'
assert_contains "$parallel_text$review_text$fast_text" 'mechanical fix batch' \
    'mechanical batches may compress design stages'
assert_contains "$parallel_text$review_text$fast_text" '28 full runs, 18 commits, 13 rounds, 2h42m' \
    'fast-mode accounting records the baseline comparison'

# Canonical helper argv belongs in a single reference and names all three helpers.
assert_contains "$fast_text" 'gh-pr-state.sh --full' \
    'fast-mode reference documents canonical full PR-state argv'
assert_contains "$fast_text" 'review-transition.sh' \
    'fast-mode reference documents canonical review-transition argv'
assert_contains "$fast_text" 'merge-pr.sh' \
    'fast-mode reference documents canonical merge argv'

# Trigger-only comments have no agent-authorship banner; composed comments are file-backed.
assert_contains "$parallel_text$review_text$fast_text" 'trigger/command comments' \
    'trigger-only comments skip attribution banners'
assert_contains "$policy_text$parallel_text$review_text$fast_text" 'compose-comment-body.sh' \
    'comment composition is centralized in the safe composer'
assert_contains "$policy_text$parallel_text$review_text$fast_text" 'forbid hand-rolled shell heredocs' \
    'comment policy forbids hand-rolled heredoc composition'
assert_eq 'yes' "$([[ -x "$comment_composer" ]] && printf yes || printf no)" \
    'safe comment composer is executable'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
part_one="$tmp/one.md"
part_two="$tmp/two.md"
plain="$tmp/plain.md"
printf '%s' 'trigger `literal` $(not-run)' >"$part_one"
printf '%s\n' 'command body' >"$part_two"
assert_rc 0 'composer writes a plain trigger/command comment from files' -- bash "$comment_composer" \
    --output "$plain" --body-file "$part_one" --body-file "$part_two"
plain_text=$(<"$plain")
assert_eq 'trigger `literal` $(not-run)command body' "$plain_text" \
    'plain comment content survives byte-for-byte without attribution'
assert_not_contains "$plain_text" 'This was written agentically' \
    'plain trigger/command comments omit the attribution banner'

identity="$tmp/identity.txt"
agent="$tmp/agent.md"
printf '%s' 'Codex gpt-5.6-luna' >"$identity"
assert_rc 0 'composer adds attribution only when explicitly requested' -- bash "$comment_composer" \
    --output "$agent" --body-file "$part_one" --agent-identity-file "$identity"
agent_text=$(<"$agent")
assert_contains "$agent_text" 'This was written agentically; verify its assertions:' \
    'agent comments receive the canonical front banner'
assert_contains "$agent_text" '🤖 Co-authored by Codex gpt-5.6-luna.' \
    'agent comments receive the canonical signature'
assert_eq '600' "$(stat -c '%a' "$agent")" 'composed comment is private on disk'

# The worker prompt contract must carry the fast-mode behavior as dispatch data,
# not leave it to a worker to infer from the invocation name.
assert_contains "$worker_text" 'fast-mode' \
    'worker prompt reference carries fast-mode context'

# Named active issues are re-adjudicated with local liveness evidence rather
# than silently dropped by the fast-mode selection funnel.
assert_contains "$parallel_text$fast_text$triage_text" 'stale-active' \
    'fast mode names stale active candidates'
assert_contains "$parallel_text$fast_text$triage_text" 'held-active' \
    'fast mode names genuinely active candidates'
assert_contains "$parallel_text$fast_text$triage_text" 'reason=pr' \
    'held active output identifies an open PR'
assert_contains "$parallel_text$fast_text$triage_text" 'reason=worktree' \
    'held active output identifies a live worktree'
assert_contains "$parallel_text$fast_text$triage_text" 'reason=heartbeat' \
    'held active output identifies a fresh worker heartbeat'
assert_contains "$parallel_text$fast_text$triage_text" \
    'requested = dispatched + queued + tracker + duplicate + held-active + sum(exclusions)' \
    'fast mode funnel accounts for every named issue and exclusions'
assert_contains "$triage_text" 'stale-active is a disclosure sub-count' \
    'stale-active is not double-counted in the funnel invariant'
assert_contains "$triage_text" \
    'requested=<requested-count> eligible=<eligible-count> dispatched=<dispatch-count> queued=<queue-count>' \
    'funnel declares one canonical field order'
assert_contains "$triage_text" 'Legacy forms are compatibility-only and are not emitted' \
    'legacy funnel forms are explicitly demoted'
assert_contains "$parallel_text$fast_text$triage_text" 'stale-active=1[#' \
    'fast mode example prints stale-active issue identity'
assert_contains "$parallel_text$fast_text$triage_text" 'held-active:#' \
    'fast mode example prints held-active issue identity'

# Parse every currently emitted canonical example and verify the accounting
# invariant, including exclusion groups. Compatibility-only legacy strings do
# not match this shape and are intentionally excluded from the parse.
canonical_funnels=$(printf '%s\n' "$triage_text" | grep -E \
    '^Selection funnel: requested=[0-9]+ eligible=[0-9]+ dispatched=[0-9]+ queued=[0-9]+(\[[^]]*\])?[[:space:]]tracker=[0-9]+ duplicate=[0-9]+ held-active=[0-9]+ stale-active=[0-9]+(\[[^]]*\])?[[:space:]]exclusions=')
canonical_count=$(printf '%s\n' "$canonical_funnels" | sed '/^$/d' | wc -l | tr -d '[:space:]')
assert_eq '8' "$canonical_count" 'all canonical funnel examples are discoverable'
canonical_mismatches=0
while IFS= read -r funnel; do
    [[ -n $funnel ]] || continue
    requested=$(grep -oE 'requested=[0-9]+' <<< "$funnel" | cut -d= -f2)
    dispatched=$(grep -oE 'dispatched=[0-9]+' <<< "$funnel" | cut -d= -f2)
    queued=$(grep -oE 'queued=[0-9]+' <<< "$funnel" | cut -d= -f2)
    tracker=$(grep -oE 'tracker=[0-9]+' <<< "$funnel" | cut -d= -f2)
    duplicate=$(grep -oE 'duplicate=[0-9]+' <<< "$funnel" | cut -d= -f2)
    held=$(grep -oE 'held-active=[0-9]+' <<< "$funnel" | cut -d= -f2)
    exclusions=${funnel#* exclusions=}
    exclusion_total=0
    if [[ $exclusions != none ]]; then
        while IFS= read -r group; do
            count=${group#*:}
            count=${count%%\[*}
            exclusion_total=$((exclusion_total + count))
        done < <(tr ',' '\n' <<< "$exclusions")
    fi
    expected=$((dispatched + queued + tracker + duplicate + held + exclusion_total))
    [[ $requested == "$expected" ]] || canonical_mismatches=$((canonical_mismatches + 1))
done <<< "$canonical_funnels"
assert_eq '0' "$canonical_mismatches" \
    'every canonical funnel example satisfies the accounting invariant'

finish
