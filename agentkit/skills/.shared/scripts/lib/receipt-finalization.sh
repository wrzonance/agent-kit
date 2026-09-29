#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153
# Callers supply post-receipt.sh's publish globals and evidence_unavailable.
# Receipt finalization: identity checks that make every later check
# meaningless refuse at once; every independent evidence gap is collected and
# refused together, one line per gap naming its next command, so one publish
# attempt names the whole repair instead of one gap per retry.

RECEIPT_GAPS=()

receipt_gap() {
    RECEIPT_GAPS+=("$1")
}

# An omitted --head-sha defaults to the reviewed head the canonical attempt
# recorded; an explicit one must agree with it.
resolve_receipt_head() {
    [[ -z $SKIP_RATIONALE ]] || return 0
    local entry recorded
    entry="$(dirname -- "$FINDINGS_FILE")/state/review-attempt.json"
    [[ -f $entry && ! -L $entry && -O $entry ]] || return 0
    recorded=$(jq -r '.head | strings' "$entry" 2>/dev/null) || return 0
    [[ $recorded =~ ^[0-9a-f]{7,40}$ ]] || return 0
    if [[ -z $HEAD_SHA ]]; then
        HEAD_SHA=$recorded
        return 0
    fi
    [[ $HEAD_SHA == "$recorded" ]] ||
        evidence_unavailable "--head-sha $HEAD_SHA conflicts with reviewed head $recorded recorded in $entry; omit --head-sha to use the recorded head"
}

receipt_final_identity() {
    [[ -f $PR_STATE_DIGEST && ! -L $PR_STATE_DIGEST && -O $PR_STATE_DIGEST && -r $PR_STATE_DIGEST ]] ||
        evidence_unavailable "finalization evidence is not an owned readable regular file: $PR_STATE_DIGEST"
    local root current_head summary_re summary digest_pr digest_sha
    root=$(git rev-parse --show-toplevel 2>/dev/null) ||
        evidence_unavailable 'finalization evidence cannot be bound outside a git worktree'
    current_head=$(git -C "$root" rev-parse --verify HEAD 2>/dev/null) ||
        evidence_unavailable 'finalization evidence cannot resolve the current checkout HEAD'
    summary_re='^pr=[0-9]+ draft=(true|false) mergeable=[A-Z_]+ head=\S+ sha=[0-9a-f]{40}$'
    [[ $(grep -cE "$summary_re" "$PR_STATE_DIGEST" || true) == 1 ]] ||
        evidence_unavailable 'finalization evidence requires exactly one canonical PR/head summary'
    summary=$(grep -E "$summary_re" "$PR_STATE_DIGEST")
    digest_pr=$(sed -nE 's/^pr=([0-9]+) .*$/\1/p' <<<"$summary")
    digest_sha=$(sed -nE 's/^.* sha=([0-9a-f]{40})$/\1/p' <<<"$summary")
    [[ $digest_pr == "$PR" ]] ||
        evidence_unavailable "finalization evidence is for PR #$digest_pr, not PR #$PR"
    [[ $digest_sha == "$current_head" ]] ||
        evidence_unavailable "finalization evidence head $digest_sha does not match current HEAD $current_head"
    FINAL_HEAD_SHA=$digest_sha
    FINAL_REPO_ROOT=$root
}

receipt_ci_gaps() {
    local digest=$PR_STATE_DIGEST refresh ci_line
    refresh='next: refresh the digest with gh-pr-state.sh --digest-out at the final head'
    [[ $(grep -cE '^base: ref=\S+ behind=[0-9]+ stale=no$' "$digest" || true) == 1 ]] ||
        receipt_gap "finalization evidence does not prove a current integrated base; next: merge the base down, push, and refresh the digest"
    if [[ $(grep -cE '^ci=' "$digest" || true) != 1 ]]; then
        receipt_gap "finalization evidence requires exactly one CI status line; $refresh"
        return 0
    fi
    ci_line=$(grep -E '^ci=' "$digest")
    FINAL_CI_LINE=$ci_line
    [[ ! $ci_line =~ ^ci=[0-9]+/[0-9]+\ green\ pending=0\ failing=0$ ]] || {
        ! grep -qE '^ready-eligible=no( |$)' "$digest" ||
            receipt_gap "finalization evidence reports ready-eligible=no; $refresh once it clears"
        return 0
    }
    if grep -qE '^verification=(partial|no)-ci-on-stacked-base$' "$digest"; then
        receipt_gap "finalization waits for retarget: $ci_line is stacked on its predecessor; next: publish after the predecessor is finalized, merged down, and this PR retargeted (parallel-issues references/chains.md \"Merge order and the stacked-PR retarget\")"
        return 0
    fi
    receipt_gap "finalization evidence is not green: $ci_line; next: make final-head CI green (gh-pr-state.sh --wait-ci), then refresh the digest"
}

receipt_classification_gaps() {
    local line_re='^finding-classification: cq=(known|unavailable) icf=(known|unavailable)$' line
    if [[ $(grep -cE "$line_re" "$PR_STATE_DIGEST" || true) != 1 ]]; then
        receipt_gap 'finalization evidence requires exactly one canonical finding-classification line; next: refresh the digest with gh-pr-state.sh --digest-out'
        return 0
    fi
    line=$(grep -E "$line_re" "$PR_STATE_DIGEST")
    [[ $line == 'finding-classification: cq=known icf=known' ]] ||
        receipt_gap "finalization evidence has unavailable required finding classification: $line; next: restore the classifier and refresh the digest"
}

receipt_acceptance_gaps() {
    local acceptance_file=$FINAL_REPO_ROOT/.agent/acceptance.txt command matches line
    if [[ -e $acceptance_file || -L $acceptance_file ]]; then
        if [[ -f $acceptance_file && ! -L $acceptance_file && -r $acceptance_file ]]; then
            while IFS= read -r command || [[ -n $command ]]; do
                [[ -n $command ]] || continue
                matches=$(awk -v expected="repo-verify=green acceptance=$command:pass" \
                    '$0 == expected { count++ } END { print count + 0 }' "$PR_STATE_DIGEST")
                [[ $matches == 1 ]] ||
                    receipt_gap "finalization evidence lacks one passing record for required acceptance command: $command; next: run it at the final head and refresh the digest"
            done <"$acceptance_file"
        else
            receipt_gap "declared acceptance commands are unavailable: $acceptance_file"
        fi
    fi
    while IFS= read -r line; do
        [[ $line == repo-verify=green\ acceptance=*':pass' ]] ||
            receipt_gap "finalization evidence has an unmet acceptance result: $line"
    done < <(grep -E '^repo-verify=' "$PR_STATE_DIGEST" || true)
}

# Lists each unresolved adversarial finding and the one call that records its
# terminal evidence.
receipt_finding_gaps() {
    [[ $(jq -r '.remediation // ""' <<<"$REMEDIATION") != complete ]] || return 0
    local ledger dir ids line
    ledger="$(cd -- "$STACKED_CI_DIR" && pwd)/finding-ledger.sh"
    dir=$(dirname -- "$FINDINGS_FILE")
    ids=$("$ledger" ids --file "$FINDINGS_FILE" 2>/dev/null | jq -Rn '[inputs | split("\t") | {(.[1]): .[0]}] | add // {}') ||
        ids='{}'
    while IFS= read -r line; do
        receipt_gap "$line"
    done < <(jq -r --argjson ids "$ids" '.unresolved[]
        | "unresolved adversarial finding \"\(.title)\" (id \($ids[.title] // "?")); next: \(.nextAction)"' \
        <<<"$REMEDIATION")
    receipt_gap "record terminal evidence for unresolved adversarial findings: RUN_DIR=\"$dir\" \"$ledger\" evidence --title T --path P --log LOG --repo-root \"$FINAL_REPO_ROOT\" --repair-sha SHA (a decline: RUN_DIR=\"$dir\" \"$ledger\" add --title T --severity P1|P2 --verdict declined --rationale R --evidence FILE --repo-root \"$FINAL_REPO_ROOT\" --head $FINAL_HEAD_SHA)"
}

receipt_accepted_gaps() {
    local file status titles
    file="$(dirname -- "$FINDINGS_FILE")/accepted-findings.ndjson"
    if [[ ! -e $file && ! -L $file ]]; then
        if grep -qx 'alerts: code-scanning open=0' "$PR_STATE_DIGEST" &&
            grep -qx 'issue-comment-findings: 0 open' "$PR_STATE_DIGEST"; then
            receipt_gap "accepted findings evidence is missing: $file; the digest shows code-scanning open=0 and 0 open issue-comment findings; if you accepted none, next: : > \"$file\" && chmod 600 \"$file\""
        else
            receipt_gap "accepted findings evidence is missing: $file; next: write accepted Code Quality and issue-comment records there, or create it empty only after accepting none"
        fi
        return 0
    fi
    [[ -f $file && ! -L $file && -O $file && -r $file ]] || {
        receipt_gap "accepted findings evidence is not an owned readable regular file: $file"
        return 0
    }
    status=$("$STACKED_CI_DIR/finding-ledger.sh" status --file "$file" \
        --repo-root "$FINAL_REPO_ROOT" --head "$FINAL_HEAD_SHA" 2>/dev/null) || {
        receipt_gap "accepted findings evidence is invalid or its terminal proof is stale: $file"
        return 0
    }
    [[ $(jq -r '.remediation // ""' <<<"$status") != complete ]] || return 0
    titles=$(jq -r '[.unresolved[] | "\"\(.title)\""] | join(", ")' <<<"$status")
    receipt_gap "accepted findings evidence has incomplete or unknown dispositions: $titles; next: replace each with validated fixed or declined terminal evidence in $file"
}

validate_finalization_evidence() {
    receipt_final_identity
    RECEIPT_GAPS=()
    receipt_ci_gaps
    receipt_classification_gaps
    receipt_acceptance_gaps
    receipt_finding_gaps
    receipt_accepted_gaps
    ((${#RECEIPT_GAPS[@]})) || return 0
    printf '%s: finalization refused, %d gap(s); evidence unavailable\n' "$PROGNAME" "${#RECEIPT_GAPS[@]}" >&2
    printf -- '- %s\n' "${RECEIPT_GAPS[@]}" >&2
    exit 1
}
