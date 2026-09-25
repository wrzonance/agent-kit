#!/usr/bin/env bash
# Issue #873: review-remote-pr's documented remediation path must run as written.
# shellcheck disable=SC2016 # assertions match literal $VAR text in the skill recipe.
set -uo pipefail

TEST_NAME='review-remote-pr remediation contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skills="$root/agentkit/skills"
rrp_skill="$skills/review-remote-pr/SKILL.md"
pr_stage="$skills/parallel-issues/scripts/pr-stage.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# --- item 1: the finalizer preserves the frozen receipt payload -------------
assert_contains "$(cat -- "$pr_stage")" 'REVIEW_PAYLOAD=$payload' \
    'the one-call finalizer derives the frozen payload from review-attempt evidence'
assert_contains "$(cat -- "$pr_stage")" 'publish_args+=(--diff-payload "$REVIEW_PAYLOAD")' \
    'the one-call finalizer passes the original payload to receipt publication'

# --- item 5: the receipt credits the posting agent --------------------------
publish_block=$(sed -n '/finalize_args=(finalize/,/pr-stage.sh"/p' "$rrp_skill")
identity_line=$(grep -F 'AGENT_IDENTITY=$(' "$rrp_skill" || true)
assert_contains "$identity_line" '--get harness.identity --worker-model "$ROOT_MODEL"' \
    'the recipe derives AGENT_IDENTITY from the contract harness identity and the root model'
recipe_block=$(sed -n '/The agent posting this receipt/,/pr-stage.sh"/p' "$rrp_skill")
assert_contains "$recipe_block" 'never the reviewer' \
    'the recipe says the identity is the posting agent, never the reviewer'
assert_contains "$recipe_block" ': "${ROOT_MODEL:?' \
    'the recipe stops loudly when the root model is unset'
assert_contains "$recipe_block" 'AGENT_IDENTITY=${AGENT_IDENTITY% <*}' \
    'the recipe strips the contact address from the credited identity'
assert_contains "$publish_block" '--agent-identity "$AGENT_IDENTITY"' \
    'publish still consumes the defined identity'

# --- item 2/3: cover prose names the real ID source and --repo-root ----------
adv_ref="$skills/review-remote-pr/references/adversarial-review.md"
assert_not_contains "$(cat -- "$adv_ref")" 'fix:FINDING_ID' \
    'the prose no longer names an ID that finding records do not carry'
assert_contains "$(cat -- "$adv_ref")" 'finding-ledger.sh ids --file' \
    'the prose points at the ID source'
assert_contains "$(cat -- "$adv_ref")" '--findings-file FILE --repo-root' \
    'the cover recipe passes --repo-root with --findings-file'

# --- item 4/8: prose routes evidence through the producer ---------------------
assert_contains "$(cat -- "$adv_ref")" 'finding-ledger.sh evidence' \
    'the evidence contract names the producer'
assert_contains "$(cat -- "$rrp_skill")" 'finding-ledger.sh" evidence' \
    'the SKILL recipe comment uses the producer'
worker_gate="$skills/review-remote-pr/references/worker-gate.md"
assert_contains "$(cat -- "$worker_gate")" 'unfocused' \
    'the worker completion report names the unfocused test log'
assert_contains "$(cat -- "$worker_gate")" 'after the repair commit and before push' \
    'the repair handback orders full verification on the commit that will be pushed'
assert_contains "$(cat -- "$worker_gate")" 'clean committed HEAD' \
    'the repair handback requires the log to bind the committed head'
fix_prompt=$(sed -n '/## PR-fix-batch worker prompt/,/## Exit Report/p' \
    "$skills/parallel-issues/references/worker-prompts.md")
assert_contains "$fix_prompt" '4. Commit the repair' \
    'the composed fix-worker prompt commits before full verification'
assert_contains "$fix_prompt" '6. Push the branch only after that clean committed-HEAD run passes' \
    'the composed fix-worker prompt cannot push an unverified commit'

# Step 2's runnable phases must not execute the full suite before the worker
# commits. Execute its first fence with a recording runner, then ensure the
# committed-head test is a separate fence after an explicit commit boundary.
ci_fix_section=$(sed -n '/^## Step 2: Fix CI Failures/,/^For red\/green iterations/p' "$rrp_skill")
fence() {
    local number=$1
    awk -v wanted="$number" '
        /^```bash$/ { count++; capture=(count==wanted); next }
        /^```$/ { if (capture) exit }
        capture
    ' <<<"$ci_fix_section"
}
precommit_fence=$(fence 1)
postcommit_fence=$(fence 2)
recipe_kit="$tmp/recipe-kit"
recipe_calls="$tmp/recipe-calls"
mkdir -p "$recipe_kit/.shared/scripts"
cat >"$recipe_kit/.shared/scripts/agent-run.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AGENTKIT_RECIPE_CALLS"
EOF
chmod +x "$recipe_kit/.shared/scripts/agent-run.sh"
AGENTKIT_RECIPE_CALLS="$recipe_calls" agentkit="$recipe_kit" agentkit_provenance=ok \
    bash -c "$precommit_fence"
assert_eq '--cmd lint --if-declared' "$(cat "$recipe_calls")" \
    'executing the precommit fence cannot run the full test on a dirty repair'
assert_contains "$postcommit_fence" '"$agent_run" --cmd test' \
    'committed-head verification has its own runnable fence'
commit_line=$(grep -nF 'Commit the repair' <<<"$ci_fix_section" | cut -d: -f1 | head -n1)
test_line=$(grep -nF '"$agent_run" --cmd test' <<<"$ci_fix_section" | cut -d: -f1 | head -n1)
assert_eq yes "$([[ -n $commit_line && -n $test_line && $commit_line -lt $test_line ]] && printf yes || printf no)" \
    'the actual commit step precedes the runnable full-test phase'
cadence_line=$(grep -F 'Run only declared `agent-run.sh --cmd` commands' "$rrp_skill")
assert_not_contains "$cadence_line" 'full suite before commit' \
    'the review workflow no longer contradicts its committed-head runnable fence'
assert_contains "$cadence_line" 'full suite after commit and before push' \
    'the review workflow states the same order as its runnable fence'

# Execute the shipped merge-publication chain itself with recording process
# edges.  This pins both order/count on success and the && failure boundary;
# it is not a test-local reconstruction of the recipe.
extract_publication_chain() {
    local source=$1 marker_count block expected
    marker_count=$(grep -c '^# Chained:' "$source" || true)
    [[ $marker_count == 1 ]] || return 1
    block=$(awk '
        /^```bash$/ { in_bash=1; next }
        /^```$/ {
            if (capture) { closed=1; exit }
            in_bash=0
            next
        }
        in_bash && /^# Chained:/ { found++; capture=1 }
        capture { print }
        END { if (found != 1 || closed != 1) exit 1 }
    ' "$source") || return 1
    expected=$(cat <<'EOF'
# Chained: no `set -e` here, so unchained these would push even after the commit
# helper or a verification failed -- what the rule below forbids.
"$agentkit/.shared/scripts/worktree-commit.sh" --message 'fix(example): resolve merge conflicts with the base branch' \
  --trailer "$worker_attribution" -- "$resolved" &&
"$agentkit/.shared/scripts/agent-run.sh" --cmd lint --if-declared &&
"$agentkit/.shared/scripts/agent-run.sh" --cmd test &&
git push   # upstream set in 0a; fork PRs push to the fork via gh pr checkout's config
EOF
)
    [[ $block == "$expected" ]] || return 1
    printf '%s\n' "$block"
}

repeated_chain="$tmp/repeated-publication-chain.md"
{
    printf '%s\n' '# Chained: unrelated example'
    cat -- "$rrp_skill"
} >"$repeated_chain"
repeated_rc=0
extract_publication_chain "$repeated_chain" >"$tmp/repeated-chain.out" || repeated_rc=$?
assert_eq 1 "$repeated_rc" \
    'publication recipe extraction rejects repeated Chained markers'

malformed_chain="$tmp/malformed-publication-chain.md"
awk '
    /^"\$agentkit\/\.shared\/scripts\/agent-run\.sh" --cmd lint/ {
        print "\"$agentkit/.shared/scripts/agent-run.sh\" --cmd lint \"$(touch \"$PUBLICATION_SENTINEL\")\" &&"
        next
    }
    { print }
' "$rrp_skill" >"$malformed_chain"
malformed_rc=0
extract_publication_chain "$malformed_chain" >"$tmp/malformed-chain.out" || malformed_rc=$?
assert_eq 1 "$malformed_rc" \
    'publication recipe extraction rejects unexpected command substitution syntax'

if ! publication_chain=$(extract_publication_chain "$rrp_skill"); then
    printf '%s\n' 'invalid merge-publication recipe; refusing to execute extracted text' >&2
    exit 1
fi
publication_kit="$tmp/publication-kit"
publication_bin="$tmp/publication-bin"
publication_cwd="$tmp/publication-cwd"
publication_calls="$tmp/publication-calls"
mkdir -p "$publication_kit/.shared/scripts" "$publication_bin" "$publication_cwd"
cat >"$publication_kit/.shared/scripts/worktree-commit.sh" <<'EOF'
#!/usr/bin/env bash
printf 'commit:%s\n' "$*" >>"$AGENTKIT_RECIPE_CALLS"
EOF
cat >"$publication_kit/.shared/scripts/agent-run.sh" <<'EOF'
#!/usr/bin/env bash
printf 'verify:%s\n' "$*" >>"$AGENTKIT_RECIPE_CALLS"
[[ ${FAIL_FULL:-0} != 1 || $* != *'--cmd test'* ]]
EOF
cat >"$publication_bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'push:%s\n' "$*" >>"$AGENTKIT_RECIPE_CALLS"
EOF
chmod +x "$publication_kit/.shared/scripts/worktree-commit.sh" \
    "$publication_kit/.shared/scripts/agent-run.sh" "$publication_bin/git"
(
    cd -- "$publication_cwd" || exit 1
    AGENTKIT_RECIPE_CALLS="$publication_calls" agentkit="$publication_kit" \
        worker_attribution='Co-Authored-By: Test <test@example.invalid>' resolved=src/example.ts \
        PATH="$publication_bin:/usr/bin:/bin" bash -c "$publication_chain"
)
assert_eq $'commit:--message fix(example): resolve merge conflicts with the base branch --trailer Co-Authored-By: Test <test@example.invalid> -- src/example.ts\nverify:--cmd lint --if-declared\nverify:--cmd test\npush:push' \
    "$(cat "$publication_calls")" \
    'the shipped publication chain executes commit, one full test, then push'
assert_eq 1 "$(grep -cF 'verify:--cmd test' "$publication_calls")" \
    'the shipped publication chain schedules the full test once'

: >"$publication_calls"
failed_chain_rc=0
(
    cd -- "$publication_cwd" || exit 1
    AGENTKIT_RECIPE_CALLS="$publication_calls" FAIL_FULL=1 agentkit="$publication_kit" \
        worker_attribution='Co-Authored-By: Test <test@example.invalid>' resolved=src/example.ts \
        PATH="$publication_bin:/usr/bin:/bin" bash -c "$publication_chain"
) || failed_chain_rc=$?
assert_eq 1 "$failed_chain_rc" 'a failed full test makes the shipped publication chain fail'
assert_not_contains "$(cat "$publication_calls")" 'push:' \
    'a failed full test prevents the shipped publication chain from pushing'

# --- item 6: the spawn contract names the primary checkout's ledger ----------
assert_contains "$(cat -- "$skills/.shared/spawn-contract.md")" "primary checkout's \`.agent/runs/active-workers.ndjson\`" \
    'the spawn contract says the ledger lives in the primary checkout'

# --- item 7: Step 0 keeps check's flags and preflight's flags apart -----------
for skill in review-remote-pr pr-to-green onboard-repo parallel-issues; do
    step0=$(sed -n '/Step 0 prerequisite/,/^Missing challenge/p' "$skills/$skill/SKILL.md")
    check_sentence=$(grep -F 'check --require pre-tool-use' <<<"$step0" || true)
    assert_contains "$check_sentence" "--repo-root R --session ID --skill $skill" \
        "$skill Step 0 spells check's full flag set on one line"
    assert_not_contains "$check_sentence" '--activation-session' \
        "$skill Step 0 keeps preflight flags out of the check sentence"
    # Preflight runs from a linked worktree, where the ack receipt is not; it
    # needs --activation-origin naming the checkout check received.
    assert_contains "$step0" '`$agentkit/.shared/scripts/agent-preflight.sh` carries '"\`--activation-session ID --activation-origin R --workflow $skill --activation-nonce N\`" \
        "$skill Step 0 attributes the session flags, including the activation origin, to preflight"
    assert_not_contains "$step0" 'separately takes' \
        "$skill Step 0 no longer invites a redundant second preflight call"
done

rrp_step0=$(sed -n '/Step 0 prerequisite/,/^Missing challenge/p' "$rrp_skill")
assert_contains "$rrp_step0" "Standalone invocation: run UserPromptSubmit's exact" \
    'review-remote-pr keeps its own challenge and preflight for standalone invocation'
assert_contains "$rrp_step0" 'Delegate only when dispatched inside active `parallel-issues`/`pr-to-green` and `check` reports that owner' \
    'review-remote-pr requires an active named owner before reusing delegated activation'
assert_contains "$rrp_step0" 'do not run or acknowledge review-remote-pr preflight' \
    'review-remote-pr forbids a competing delegated preflight acknowledgement'
assert_contains "$rrp_step0" 'Otherwise standalone native/natural-language activation delivers its own challenge' \
    'review-remote-pr routes every non-owner call through standalone activation'

# --- adversarial findings on #873: the receipt block uses the finalizer -------
receipt_section=$(sed -n '/^### Adversarial-review receipt/,/^```$/p' "$rrp_skill")
assert_contains "$receipt_section" 'finalize_args=(finalize --repo-root "$contract_root"' \
    'standalone review supplies explicit finalization context without claiming parallel run binding'
assert_contains "$receipt_section" 'finalize_args+=(--mode-reason "$MODE_REASON")' \
    'a mode reason is passed only when one is set'
assert_contains "$(cat -- "$pr_stage")" \
    'p1=$(jq -s '\''[.[] | select(.severity=="P1")] | length'\'' "$findings")' \
    'the finalizer derives finding counts from the durable ledger'
assert_contains "$(cat -- "$pr_stage")" 'load_attempt "$state_dir/review-attempt.json"' \
    'a reviewed run derives head/provider/model/effort/mode from its attempt record'
assert_contains "$(cat -- "$pr_stage")" \
    'verified skip requires --provider, --model, --effort, and --mode' \
    'a verified skip without an attempt must supply its explicit receipt fields'

# --- the after-repair comment is a complete command -----------------------------
after_repair=$(sed -n '/^# After repair/,/declines require/p' "$rrp_skill")
assert_contains "$after_repair" 'RUN_DIR="$RUN_DIR" "$agentkit/review-remote-pr/scripts/finding-ledger.sh" add --title '"'SHORT_TITLE'"' --severity P1 --verdict fixed' \
    'the fixed-verdict add names RUN_DIR, the same title and a severity'
assert_contains "$after_repair" '--repair-sha' 'the evidence step names the repair commit'
assert_not_contains "$after_repair" '--reviewed-head' 'the evidence step needs no reviewed head'
assert_not_contains "$(cat -- "$adv_ref")" '--reviewed-head' 'the evidence contract needs no reviewed head'
assert_contains "$(cat -- "$adv_ref")" 'after the repair commit and before push' \
    'the evidence recipe says when the binding full run occurs'
assert_contains "$(cat -- "$adv_ref")" 'tested head and tracked-tree cleanliness' \
    'the evidence recipe explains what the log binding proves'
assert_not_contains "$(cat -- "$adv_ref")" 'defaults to the last commit' \
    'the evidence contract no longer promises a guessed repair commit'

finish
