#!/usr/bin/env bash
# Pre-merge review-completion gate contract for --auto-merge.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='pr to green: merge gate'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
gate="$root/agentkit/skills/pr-to-green/scripts/merge-gate.sh"

readonly HEAD_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
readonly HEAD_SHA7='aaaaaaa'

cat >"$tmp/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
endpoint=''
for arg in "\$@"; do [[ \$arg == repos/* ]] && endpoint=\$arg; done
case \$endpoint in
repos/owner/repo/pulls/9)
    mergeable=\${PR_MERGEABLE:-true}
    draft=\${PR_DRAFT:-false}
    state=\${PR_STATE:-open}
    sha=\${PR_HEAD_SHA:-$HEAD_SHA}
    base=\${PR_BASE:-main}
    reviewers=\${PR_REQUESTED_REVIEWERS:-[]}
    teams=\${PR_REQUESTED_TEAMS:-[]}
    printf '{"number":9,"state":"%s","draft":%s,"head":{"sha":"%s","ref":"feat/demo"},"base":{"ref":"%s"},"mergeable":%s,"requested_reviewers":%s,"requested_teams":%s}\n' \\
        "\$state" "\$draft" "\$sha" "\$base" "\$mergeable" "\$reviewers" "\$teams"
    ;;
repos/owner/repo/pulls/9/reviews*)
    printf '%s\n' "\${PR_REVIEWS_JSON:-[]}"
    ;;
repos/owner/repo/commits/*/check-runs*)
    if [[ \${CS_RUNS_UNREADABLE:-0} == 1 ]]; then
        printf 'not found\n' >&2
        exit 1
    fi
    if [[ -n \${CS_RUNS_JSON:-} ]]; then
        printf '%s\n' "\$CS_RUNS_JSON"
    else
        printf '{"check_runs":[{"app":{"slug":"github-code-scanning"},"status":"completed"}]}\n'
    fi
    ;;
*) printf 'unexpected endpoint %s\n' "\$endpoint" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/gh"

good_digest() {
    cat >"$tmp/digest.txt" <<EOF
pr=9 draft=false mergeable=MERGEABLE head=feat/demo sha=$HEAD_SHA7
base: ref=main behind=0 stale=no
ci=3/3 green pending=0 failing=0
provider: coderabbit=reviewed
threads: coderabbit=0 unresolved  code-quality=0 open  human=0  generic=0
nitpicks: 0 unhandled
alerts: code-scanning open=0
EOF
}

run_gate() {
    MERGE_GATE_GH="$tmp/gh" bash "$gate" --repo owner/repo --pr 9 \
        --head-sha "$HEAD_SHA" --base main --pr-state-digest "$tmp/digest.txt" \
        --provider-result "${GATE_PROVIDER_RESULT:-AUTO_REVIEW}" \
        --human-items-decided "${GATE_HUMAN_DECIDED:-yes}" \
        --code-quality-scan-state "${GATE_CQ_STATE:-complete}"
}

good_digest
out=$(run_gate)
assert_contains "$out" 'gate=PASS pr=9' 'a fully clean PR passes the gate'

good_digest
set +e
out=$(GATE_PROVIDER_RESULT=TRIGGERED run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'an in-flight CodeRabbit review blocks the merge'
assert_contains "$out" 'blocked reason=CodeRabbit review is still in flight' \
    'the in-flight block names CodeRabbit'

good_digest
sed -i 's/coderabbit=0 unresolved/coderabbit=2 unresolved/' "$tmp/digest.txt"
set +e
out=$(run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'an unresolved CodeRabbit thread blocks the merge'
assert_contains "$out" 'blocked reason=2 unresolved CodeRabbit thread' \
    'the unresolved-thread block names the count'

good_digest
sed -i 's/alerts: code-scanning open=0/alerts: code-scanning n\/a/' "$tmp/digest.txt"
set +e
out=$(run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'an unreadable code-scanning endpoint blocks the merge'
assert_contains "$out" 'blocked reason=code-scanning evidence is unreadable' \
    'unreadable code-scanning is reported, never treated as zero findings'

good_digest
sed -i 's/code-quality=0 open/code-quality=1 open/' "$tmp/digest.txt"
set +e
out=$(run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'an open github-code-quality finding blocks the merge'
assert_contains "$out" 'blocked reason=1 open github-code-quality finding' \
    'the code-quality block names the count'

good_digest
set +e
out=$(GATE_CQ_STATE=pending run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'a pending github-code-quality scan blocks the merge'
assert_contains "$out" 'blocked reason=github-code-quality scan is still pending' \
    'the pending-scan block is named'

good_digest
set +e
out=$(GATE_HUMAN_DECIDED=no run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'an undecided human item blocks the merge'
assert_contains "$out" 'blocked reason=an observed human item has no explicit per-item decision' \
    'the undecided-human block is named'

good_digest
set +e
out=$(PR_REVIEWS_JSON='[{"user":{"login":"alice","type":"User"},"state":"CHANGES_REQUESTED","submitted_at":"2026-08-20T00:00:00Z"}]' run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'an undecided CHANGES_REQUESTED human review blocks the merge'
assert_contains "$out" 'blocked reason=a human review is CHANGES_REQUESTED and undecided' \
    'the CHANGES_REQUESTED block is named'

good_digest
out=$(PR_REVIEWS_JSON='[{"user":{"login":"alice","type":"User"},"state":"CHANGES_REQUESTED","submitted_at":"2026-08-20T00:00:00Z"},{"user":{"login":"alice","type":"User"},"state":"APPROVED","submitted_at":"2026-08-20T01:00:00Z"}]' run_gate)
assert_contains "$out" 'gate=PASS pr=9' \
    'a later APPROVED review from the same human supersedes an earlier CHANGES_REQUESTED'

good_digest
set +e
out=$(PR_REQUESTED_REVIEWERS='[{"login":"bob"}]' run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'a pending requested reviewer blocks the merge'
assert_contains "$out" 'blocked reason=a requested reviewer is still pending' \
    'the pending-reviewer block is named'

good_digest
set +e
out=$(PR_HEAD_SHA='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'a head that moved since evidence was captured blocks the merge'
assert_contains "$out" 'blocked reason=pull request head changed since evidence was captured' \
    'the stale-head block is named'

good_digest
set +e
out=$(PR_MERGEABLE=false run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'a non-mergeable PR blocks the merge'
assert_contains "$out" 'blocked reason=pull request is not mergeable' \
    'the not-mergeable block is named'

good_digest
sed -i 's/^ci=3\/3 green pending=0 failing=0$/ci=2\/3 pending pending=1 failing=0/' "$tmp/digest.txt"
set +e
out=$(run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'CI still pending blocks the merge'
assert_contains "$out" 'blocked reason=CI is not fully green' 'the pending-CI block is named'

# --- F3 (accepted): code scanning must have completed for the current head --

good_digest
set +e
out=$(CS_RUNS_JSON='{"check_runs":[{"app":{"slug":"github-code-scanning"},"status":"in_progress"}]}' run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'a code-scanning analysis still in progress blocks the merge, even with zero open alerts reported'
assert_contains "$out" 'blocked reason=code-scanning analysis has not completed for the current head' \
    'the pending-analysis block is named'

good_digest
out=$(CS_RUNS_JSON='{"check_runs":[{"app":{"slug":"github-code-scanning"},"status":"completed"}]}' run_gate)
assert_contains "$out" 'gate=PASS pr=9' \
    'a completed code-scanning analysis with zero open alerts passes the gate'

good_digest
set +e
out=$(CS_RUNS_UNREADABLE=1 run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'an unreadable code-scanning completion signal blocks the merge (never treated as complete)'
assert_contains "$out" 'blocked reason=code-scanning analysis status is unreadable for the current head' \
    'the unreadable-completion block is named'

# --- F1 (accepted): a group/other-writable digest file is rejected ----------

good_digest
chmod 660 "$tmp/digest.txt"
set +e
out=$(run_gate 2>&1)
rc=$?
set -e
chmod 600 "$tmp/digest.txt"
assert_eq '1' "$rc" 'a group-writable pr-state digest is refused'
assert_contains "$out" '--pr-state-digest must not be group- or world-writable' \
    'the group-writable digest refusal is named'

# --- F4 (accepted, in-scope half): the SHA binding matches the digest length -

good_digest
out=$(run_gate)
assert_contains "$out" 'gate=PASS pr=9' 'a 7-char digest SHA still binds (weak but functional) against the current head'

FULL_SHA="$HEAD_SHA"
good_digest
sed -i "s/sha=$HEAD_SHA7\$/sha=$FULL_SHA/" "$tmp/digest.txt"
out=$(run_gate)
assert_contains "$out" 'gate=PASS pr=9' 'a full 40-char digest SHA binds fully against the matching current head'

MISMATCHED_FULL_SHA="${HEAD_SHA7}bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
good_digest
sed -i "s/sha=$HEAD_SHA7\$/sha=$MISMATCHED_FULL_SHA/" "$tmp/digest.txt"
set +e
out=$(run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'a full 40-char digest SHA that mismatches the current head is caught as stale evidence'
assert_contains "$out" 'blocked reason=pr-state digest predates the current head' \
    'the full-SHA mismatch is caught by the same staleness check'

finish
