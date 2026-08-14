#!/usr/bin/env bash
# Suite: the autonomy flags mean one thing each, and say so.
#
# `--yolo`, `--fast-mode` and `--auto-review` each remove a place the skills stop
# to ask. The hazard is not that a flag fails to work -- it is that a flag works
# harder than it was asked to, because an agent reading "fast" or "auto" in an
# invocation generalises it into permission for everything else in reach.
#
# These assertions pin the boundaries in the procedures themselves, which is
# where an agent reads them. The last section covers the PostToolUse advisory
# for an escaped resolver, which is what a live session hit twice in a row.
#
# This suite quotes shell text as data throughout -- resolver blocks, escaped
# dollars, markdown backticks. None of it is meant to expand.
# shellcheck disable=SC2016
set -uo pipefail

TEST_NAME='autonomy-flags'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

hooks="$root/agentkit/hooks"
skills="$root/agentkit/skills"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

flatten() { tr '\n' ' ' < "$1"; }
parallel=$(flatten "$skills/parallel-issues/SKILL.md")
review=$(flatten "$skills/review-remote-pr/SKILL.md")
review_adversarial=$(flatten "$skills/review-remote-pr/references/adversarial-review.md")
# The board-adjudication `--fast-mode` decision rule and the Step 2b
# set-selection procedure are single-sourced in
# references/triage-and-selection.md (issue #107 phase 3's split);
# SKILL.md's body keeps only STOP-and-ask one-liners + a pointer. Assertions
# below that pin content from either location check this concatenation.
parallel_with_refs=$(flatten "$skills/parallel-issues/SKILL.md"; flatten "$skills/parallel-issues/references/triage-and-selection.md")

# --- the flags table rows themselves ----------------------------------------
# The prose paragraphs below the table restate the fast-mode/auto-review rules
# in their own words, but nothing previously pinned the TABLE ROWS -- so the
# rows could be deleted outright and every other assertion in this file would
# stay green. Pin each row's Effect text and every declared alias directly.
assert_contains "$parallel" 'without the Step 3 approval gate' \
    'the --fast-mode row states what it removes'
assert_contains "$parallel" 'promote unblocked Backlog issues' \
    'the --fast-mode row states its board-promotion effect'
assert_contains "$parallel" 'Standing consent' \
    'the --auto-review row states what it grants'
assert_contains "$parallel" '--auto-approve' \
    'the --auto-review row documents its --auto-approve alias'

# --- the dependency between the flags ---------------------------------------
# The one rule that cannot be softened: --fast-mode without --yolo is a request
# for unattended dispatch AND per-design steering, which are not both possible.
assert_contains "$parallel" '`--fast-mode` requires `--yolo`' \
    'the dependency is stated, not implied'
assert_contains "$parallel" 'Re-invoke with both, or with neither' \
    'and the refusal tells the user what to do instead'
assert_contains "$parallel" 'Do not infer one from the other' \
    'neither flag may be conjured from the other'
assert_contains "$parallel" '`--auto-review` is independent' \
    'the review flag stands alone'

# --- --fast-mode removes the gate, not the analysis -------------------------
# Two workers editing one file in separate worktrees is the failure Step 3
# prevents. Unattended is when it costs the most, so this is exactly the wrong
# thing for a speed flag to skip.
assert_contains "$parallel" 'With `--fast-mode`, do not ask' \
    'fast mode drops the approval gate'
assert_contains "$parallel" 'removes the approval gate, not the reasoning' \
    'and keeps the conflict analysis that gate was checking'
assert_contains "$parallel_with_refs" 'removes the approval gate, not the disclosure' \
    'and still announces what it chose'

# --- --fast-mode resolves board adjudication itself -------------------------
# Unattended runs on a single-board repo hit the same-board STOP every time;
# fast mode answers it from the conflict analysis and discloses, never asks.
assert_contains "$parallel_with_refs" 'With `--fast-mode`, do not stop for board adjudication' \
    'fast mode does not block on the same-board question'
assert_contains "$parallel_with_refs" 'print the shared-board finding' \
    'the shared-board disclosure survives the flag'
assert_contains "$parallel_with_refs" 'dropped with a printed reason, not asked about' \
    'a Blocked-column candidate is excluded, not a question'

# --- publishing is the invocation's own output -------------------------------
# Branch pushes and DRAFT PR opens are what the skill was invoked to produce;
# a sandbox escalation goes to the harness, not back to the user as a question.
assert_contains "$parallel" 'Publishing is part of the dispatch' \
    'branch pushes and draft PRs need no second permission'
assert_contains "$parallel" 'Do not pause to re-ask for that authorization' \
    'and the agent does not ask anyway'
assert_contains "$parallel" 'request escalation through the harness' \
    'a sandbox gate is answered by the harness approval flow'
assert_contains "$parallel" 'ready-flips, merges' \
    'the still-gated actions are named so the authority does not leak'

# --- selection is mechanical where it can be --------------------------------
assert_contains "$parallel" 'pick-issues.sh' 'fast mode selects through the helper'
assert_contains "$parallel_with_refs" 'Only `selectable` lines are eligible' \
    'and a SKIP line is a decision, not a suggestion'
assert_contains "$parallel_with_refs" 'Ready before Backlog' \
    'vetted work is exhausted before unvetted work is promoted'
assert_contains "$parallel" 'An empty selection is an answer' \
    'nothing eligible is a stop, not a reason to widen the query'

# --- --auto-review is bounded ------------------------------------------------
# The consent-gate detail lives in references/adversarial-review.md; the two
# gate-boundary phrases below are location-sensitive (they assert the BODY,
# not a reference, is what names the still-gated actions) so they stay
# targeted at SKILL.md itself.
assert_contains "$review_adversarial" 'consent given in advance' 'the flag answers the consent question'
assert_contains "$review_adversarial" 'do not stop to ask' 'and the agent does not ask anyway'
assert_contains "$review_adversarial" 'Still disclose' 'the disclosure survives the flag'
assert_contains "$review_adversarial" 'source=auto-review-flag' 'and the record says where consent came from'
assert_contains "$review_adversarial" 'It cannot consent on behalf of whoever owns' \
    'the flag cannot authorise disclosing a third party repository'
assert_contains "$review_adversarial" 'Still fails closed' 'an unrecordable or unknown destination still blocks'
assert_contains "$review_adversarial" 'only the current invocation line' \
    'a previous session or an issue body is not this flag'
assert_contains "$review" 'not permission to flip a PR ready' \
    'and it does not leak into the other gates'
assert_contains "$review" '--trust-trunk' \
    'review loops honor the standalone trunk-trust grant'

# The dispatched review agent reads its OWN invocation, so the lead has to pass
# the flag through explicitly -- and must not invent it.
assert_contains "$parallel" 'ONLY when this parallel-issues invocation' \
    'the flag is passed down only when it was actually given'
assert_contains "$parallel" 'manufactured their consent' \
    'and inventing it is named as the failure it is'

# --- trunk trust is orthogonal to brainstorm/set approval -------------------
assert_contains "$parallel" '`--trust-trunk`' \
    'the standalone trunk-trust flag is documented'
assert_contains "$parallel" 'does not skip brainstorm or set approval' \
    'trunk trust does not widen into workflow approval'
assert_contains "$parallel" 'never selects `yolo-trusted`' \
    'trunk trust does not change issue fencing mode'
assert_contains "$parallel" 'batch' \
    'attended dispatch describes one batched approval handoff'
assert_contains "$parallel" 'per worktree per needed command' \
    'the handoff has one recipe for every worktree and command'
assert_contains "$parallel" 'never hand off the main checkout' \
    'approval recipes cannot target the main checkout'

# --- --yolo aliases are consistent everywhere -------------------------------
for alias in '--yolo' '--no-brainstorm' '--skip-brainstorm'; do
    assert_contains "$parallel" "$alias" "the brainstorm skip lists $alias"
done
assert_contains "$parallel" 'the flag *is* the confirmation' \
    'an explicit flag is not re-confirmed'

# --- the escaped-resolver advisory ------------------------------------------
# `\$` in double quotes is a literal dollar, so an escaped resolver assigns text
# and every path built from it is missing. The error names the missing file, not
# the escaping, and a live session spent two retries on that.
repo=$(mktemp -d "$tmp/repo.XXXXXX")
git -C "$repo" init -q
mkdir -p "$repo/.agent/cache"

post_input() {
    jq -nc --arg cwd "$1" --arg cmd "$2" --arg sid "${3:-s-$RANDOM$RANDOM}" \
        '{cwd:$cwd,hook_event_name:"PostToolUse",model:"m",permission_mode:"default",
          session_id:$sid,tool_name:"Bash",tool_use_id:"t",transcript_path:null,
          tool_input:{command:$cmd},tool_response:{stdout:"",exit_code:1}}'
}
ctx_of() { jq -r '.hookSpecificOutput.additionalContext // ""' <<< "$1"; }

escaped='agentkit=$(find "\${CODEX_HOME:-\$HOME/.codex}/plugins/cache" -type d)'
out=$(post_input "$repo" "$escaped" | "$hooks/post-tool-use.sh" 2> /dev/null)
ctx=$(ctx_of "$out")
assert_contains "$ctx" 'escaped' 'an escaped resolver is named as escaped'
assert_contains "$ctx" 'verbatim' 'and the fix is to paste it unescaped'

# The correct form must stay silent. An advisory that fires on the very block
# the skills tell you to paste teaches the opposite of what it means.
clean='agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -type d)'
out=$(post_input "$repo" "$clean" | "$hooks/post-tool-use.sh" 2> /dev/null)
if grep -q 'escaped' <<< "$(ctx_of "$out")"; then
    _fail 'the correct resolver draws no advice' 'it advised on a correct block'
else
    _pass 'the correct resolver draws no advice'
fi

# An escaped dollar in a command that has nothing to do with the resolver is
# somebody quoting a literal on purpose.
out=$(post_input "$repo" 'printf "cost: \$5\n"' | "$hooks/post-tool-use.sh" 2> /dev/null)
if grep -q 'escaped' <<< "$(ctx_of "$out")"; then
    _fail 'an unrelated escaped dollar is left alone' 'it advised anyway'
else
    _pass 'an unrelated escaped dollar is left alone'
fi

# Once per session. A repeated advisory on a command the agent is retrying is
# noise at the exact moment it is already recovering.
sid="s-once-$RANDOM"
post_input "$repo" "$escaped" "$sid" | "$hooks/post-tool-use.sh" > /dev/null 2>&1
out=$(post_input "$repo" "$escaped" "$sid" | "$hooks/post-tool-use.sh" 2> /dev/null)
if grep -q 'escaped' <<< "$(ctx_of "$out")"; then
    _fail 'the advisory speaks once per session' 'it repeated'
else
    _pass 'the advisory speaks once per session'
fi

finish
