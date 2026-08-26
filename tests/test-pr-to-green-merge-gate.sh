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

fixtures="$here/fixtures"

cat >"$tmp/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
endpoint=''
ref_param=''
ref_param_set=no
prev=''
for arg in "\$@"; do
    [[ \$arg == repos/* ]] && endpoint=\$arg
    if [[ \$prev == -f && \$arg == ref=* ]]; then
        ref_param=\${arg#ref=}
        ref_param_set=yes
    fi
    prev=\$arg
done
# F3 (issue #390 follow-up): the analyses endpoint's ref must arrive as its
# own -f field, never embedded in the URL -- logged here so a test can assert
# the exact argv shape, not just the resulting response.
if [[ \$endpoint == repos/owner/repo/code-scanning/analyses ]]; then
    {
        for a in "\$@"; do printf 'ARG:%s\n' "\$a"; done
        printf -- '---\n'
    } >> "$tmp/gh-analyses-args.log"
fi
# Held in its own variable, never inlined literally inside a \${VAR:-...}
# default: bash's brace-matching for that construct gets confused by the
# unescaped { and } this JSON itself contains.
default_pr_analyses='[{"ref":"refs/pull/9/merge","commit_sha":"$HEAD_SHA","tool":{"name":"CodeQL"},"created_at":"2026-08-20T00:00:00Z"}]'
default_check_runs='{"check_runs":[]}'
case \$endpoint in
repos/owner/repo/pulls/9)
    mergeable=\${PR_MERGEABLE:-true}
    draft=\${PR_DRAFT:-false}
    state=\${PR_STATE:-open}
    sha=\${PR_HEAD_SHA:-$HEAD_SHA}
    base=\${PR_BASE:-main}
    reviewers=\${PR_REQUESTED_REVIEWERS:-[]}
    teams=\${PR_REQUESTED_TEAMS:-[]}
    if [[ -n \${PR_MERGE_SHA:-} ]]; then
        merge_sha_json="\"\$PR_MERGE_SHA\""
    else
        merge_sha_json=null
    fi
    printf '{"number":9,"state":"%s","draft":%s,"head":{"sha":"%s","ref":"feat/demo"},"base":{"ref":"%s"},"mergeable":%s,"merge_commit_sha":%s,"requested_reviewers":%s,"requested_teams":%s}\n' \\
        "\$state" "\$draft" "\$sha" "\$base" "\$mergeable" "\$merge_sha_json" "\$reviewers" "\$teams"
    ;;
repos/owner/repo/pulls/9/reviews*)
    printf '%s\n' "\${PR_REVIEWS_JSON:-[]}"
    ;;
repos/owner/repo/code-scanning/analyses)
    case "\$ref_param_set:\$ref_param" in
    yes:refs/pull/9/merge)
        case \${CS_PR_ANALYSES_MODE:-ok} in
        ok)
            printf '%s\n' "\${CS_PR_ANALYSES_JSON:-\$default_pr_analyses}"
            ;;
        empty)
            printf '{"message":"no analysis found","documentation_url":"https://docs.github.com/rest","status":"404"}\n'
            exit 1
            ;;
        error)
            printf '{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com/rest"}\n'
            exit 1
            ;;
        esac
        ;;
    yes:refs/pull/9/head)
        case \${CS_PR_HEAD_ANALYSES_MODE:-empty} in
        ok)
            printf '%s\n' "\${CS_PR_HEAD_ANALYSES_JSON:-[]}"
            ;;
        empty)
            printf '{"message":"no analysis found","documentation_url":"https://docs.github.com/rest","status":"404"}\n'
            exit 1
            ;;
        error)
            printf '{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com/rest"}\n'
            exit 1
            ;;
        esac
        ;;
    yes:refs/heads/main)
        case \${CS_BASE_ANALYSES_MODE:-empty} in
        ok)
            printf '%s\n' "\${CS_BASE_ANALYSES_JSON:-[]}"
            ;;
        empty)
            printf '{"message":"no analysis found","documentation_url":"https://docs.github.com/rest","status":"404"}\n'
            exit 1
            ;;
        error)
            printf '{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com/rest"}\n'
            exit 1
            ;;
        esac
        ;;
    no:)
        case \${CS_RECENT_ANALYSES_MODE:-ok} in
        ok)
            printf '%s\n' "\${CS_RECENT_ANALYSES_JSON:-[]}"
            ;;
        error)
            printf '{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com/rest"}\n'
            exit 1
            ;;
        esac
        ;;
    *)
        printf 'unexpected analyses ref param set=%s value=%s\n' "\$ref_param_set" "\$ref_param" >&2
        exit 1
        ;;
    esac
    ;;
repos/owner/repo/commits/*/check-runs*)
    if [[ \${CS_RUNS_UNREADABLE:-0} == 1 ]]; then
        printf 'not found\n' >&2
        exit 1
    fi
    printf '%s\n' "\${CS_RUNS_JSON:-\$default_check_runs}"
    ;;
repos/owner/repo/code-scanning/default-setup)
    printf '{"state":"%s"}\n' "\${CS_DEFAULT_SETUP_STATE:-configured}"
    ;;
repos/owner/repo/code-scanning/alerts*)
    case \${CS_ALERTS_PROBE:-ok} in
    ok)
        printf '[]\n'
        ;;
    definitive-404)
        printf '{"message":"no analysis found","documentation_url":"https://docs.github.com/rest/code-scanning/code-scanning#list-code-scanning-alerts-for-a-repository","status":"404"}\n'
        exit 1
        ;;
    forbidden-403)
        printf '{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com/rest"}\n'
        exit 1
        ;;
    esac
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

# Bare invocation with no fixed --code-quality-scan-state default, so
# --code-quality-state-file tests can supply their own combination of flags.
run_gate_raw() {
    MERGE_GATE_GH="$tmp/gh" bash "$gate" --repo owner/repo --pr 9 \
        --head-sha "$HEAD_SHA" --base main --pr-state-digest "$tmp/digest.txt" \
        --provider-result "${GATE_PROVIDER_RESULT:-AUTO_REVIEW}" \
        --human-items-decided "${GATE_HUMAN_DECIDED:-yes}" \
        "$@"
}

write_cq_state_file() {
    # $1: full scan-state= line content (without the trailing newline)
    printf '%s\n' "$1" >"$tmp/cq-state.txt"
    chmod 600 "$tmp/cq-state.txt"
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

# agent-kit#395: review-transition.sh --observe confirms a terminal review
# postdates the trigger and reports LANDED -- the gate accepts it exactly
# like AUTO_REVIEW/ALREADY_SPENT, replacing a blind re-entry into the
# ALREADY_SPENT dance just to learn the same fact.
good_digest
out=$(GATE_PROVIDER_RESULT=LANDED run_gate)
assert_contains "$out" 'gate=PASS pr=9' 'a LANDED provider result passes the gate like AUTO_REVIEW'

# agent-kit#395 adversarial-review follow-up: a review that postdates the
# trigger but targets a stale (non-current) head is real evidence, but not
# for THIS head -- it must block exactly like an in-flight TRIGGERED review,
# never pass as if it were LANDED.
good_digest
set +e
out=$(GATE_PROVIDER_RESULT=STALE_HEAD run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'a STALE_HEAD provider result blocks the merge'
assert_contains "$out" 'blocked reason=CodeRabbit review is against a stale head' \
    'the stale-head block names the reason'

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

# --- issue #403: a repository with Code Quality disabled reports the scan
# state as not-enabled -- a stable repository fact, not a scan in flight --
# and the gate must accept it exactly like complete, never like pending.

good_digest
out=$(GATE_CQ_STATE=not-enabled run_gate)
assert_contains "$out" 'gate=PASS pr=9' \
    'a not-enabled github-code-quality scan state passes the gate like complete'

good_digest
set +e
out=$(GATE_CQ_STATE=unknown run_gate 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" '--code-quality-scan-state rejects a value other than complete, pending, or not-enabled'
assert_contains "$out" '--code-quality-scan-state must be complete, pending, or not-enabled' \
    'the rejection names the accepted values'

# --- issue #472: --code-quality-state-file, the sole sanctioned producer of
# complete/pending (code-quality-state.sh --head), as a standalone source and
# reconciled against --code-quality-scan-state when both are supplied. -------

good_digest
write_cq_state_file "scan-state=complete head=$HEAD_SHA findings-on-head=0"
out=$(run_gate_raw --code-quality-state-file "$tmp/cq-state.txt")
assert_contains "$out" 'gate=PASS pr=9' \
    'a complete code-quality-state-file alone passes the gate with no --code-quality-scan-state flag'

good_digest
write_cq_state_file "scan-state=pending head=$HEAD_SHA"
set +e
out=$(run_gate_raw --code-quality-state-file "$tmp/cq-state.txt")
rc=$?
set -e
assert_eq '1' "$rc" 'a pending code-quality-state-file blocks the merge'
assert_contains "$out" 'blocked reason=github-code-quality scan is still pending' \
    'the file-sourced pending block uses the same reason as the flag'

good_digest
write_cq_state_file 'scan-state=not-enabled'
out=$(run_gate_raw --code-quality-state-file "$tmp/cq-state.txt")
assert_contains "$out" 'gate=PASS pr=9' 'a not-enabled code-quality-state-file passes the gate'

good_digest
write_cq_state_file 'scan-state=unknown reason=analyses response was not a readable JSON array'
set +e
out=$(run_gate_raw --code-quality-state-file "$tmp/cq-state.txt")
rc=$?
set -e
assert_eq '1' "$rc" 'an unknown code-quality-state-file blocks the merge -- unknown never passes as complete'
assert_contains "$out" 'blocked reason=github-code-quality scan state is unknown' \
    'the unknown block is named'
assert_contains "$out" 'analyses response was not a readable JSON array' \
    'the unknown block surfaces the reason carried by the file'

good_digest
write_cq_state_file "scan-state=complete head=$HEAD_SHA findings-on-head=0"
out=$(run_gate_raw --code-quality-scan-state complete --code-quality-state-file "$tmp/cq-state.txt")
assert_contains "$out" 'gate=PASS pr=9' \
    'an agreeing flag and code-quality-state-file pass the gate together'

good_digest
write_cq_state_file "scan-state=complete head=$HEAD_SHA findings-on-head=0"
set +e
out=$(run_gate_raw --code-quality-scan-state pending --code-quality-state-file "$tmp/cq-state.txt" 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a disagreeing --code-quality-scan-state and --code-quality-state-file die instead of silently choosing one'
assert_contains "$out" 'disagree' 'the disagreement error is named'

good_digest
write_cq_state_file "scan-state=complete head=${HEAD_SHA7}bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb findings-on-head=0"
set +e
out=$(run_gate_raw --code-quality-state-file "$tmp/cq-state.txt")
rc=$?
set -e
assert_eq '1' "$rc" 'a code-quality-state-file whose head predates the current head blocks the merge'
assert_contains "$out" 'blocked reason=code-quality state file predates the current head' \
    'the stale code-quality-state-file is caught as stale evidence'

# Regression (issue #472 review, F2): complete/pending require exactly one
# well-formed, full 40-character head= field -- a missing or short one must
# die as malformed evidence, never silently skip the staleness check and be
# accepted.
good_digest
write_cq_state_file 'scan-state=complete findings-on-head=0'
set +e
out=$(run_gate_raw --code-quality-state-file "$tmp/cq-state.txt" 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a complete code-quality-state-file with no head= field dies instead of skipping the staleness check'
assert_contains "$out" 'code-quality state file is malformed' 'the missing-head=field error is named'

good_digest
write_cq_state_file "scan-state=complete head=$HEAD_SHA7 findings-on-head=0"
set +e
out=$(run_gate_raw --code-quality-state-file "$tmp/cq-state.txt" 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a complete code-quality-state-file with a short (7-char) head= dies instead of being silently accepted'
assert_contains "$out" 'code-quality state file is malformed' 'the short-head=field error is named'

good_digest
write_cq_state_file "scan-state=pending head=$HEAD_SHA7"
set +e
out=$(run_gate_raw --code-quality-state-file "$tmp/cq-state.txt" 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a pending code-quality-state-file with a short (7-char) head= dies instead of being silently accepted'
assert_contains "$out" 'code-quality state file is malformed' 'the short-head=field error is named for pending too'

# Regression: a findings-on-head value that is itself 7+ hex-valid digits
# (e.g. a large finding count) must never be mistaken for the head= field --
# "findings-on-head=" contains its own "head=" substring with no space
# before it, unlike the real " head=<sha>" field.
good_digest
write_cq_state_file "scan-state=complete head=$HEAD_SHA findings-on-head=1234567"
out=$(run_gate_raw --code-quality-state-file "$tmp/cq-state.txt")
assert_contains "$out" 'gate=PASS pr=9' \
    'a large all-hex-digit findings-on-head count is never mistaken for a stale/mismatched head SHA'

good_digest
printf 'not a scan-state line at all\n' >"$tmp/cq-state.txt"
chmod 600 "$tmp/cq-state.txt"
set +e
out=$(run_gate_raw --code-quality-state-file "$tmp/cq-state.txt" 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a malformed code-quality-state-file dies instead of blocking as if it were readable evidence'
assert_contains "$out" 'code-quality state file is malformed' 'the malformed-file error is named'

good_digest
set +e
out=$(run_gate_raw 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'omitting both --code-quality-scan-state and --code-quality-state-file dies'
assert_contains "$out" '--code-quality-scan-state or --code-quality-state-file is required' \
    'the missing-input error names both accepted sources'

good_digest
write_cq_state_file "scan-state=complete head=$HEAD_SHA findings-on-head=0"
chmod 660 "$tmp/cq-state.txt"
set +e
out=$(run_gate_raw --code-quality-state-file "$tmp/cq-state.txt" 2>&1)
rc=$?
set -e
chmod 600 "$tmp/cq-state.txt"
assert_eq '1' "$rc" 'a group-writable code-quality-state-file is refused'
assert_contains "$out" '--code-quality-state-file must not be group- or world-writable' \
    'the group-writable code-quality-state-file refusal is named'

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
out=$(CS_PR_ANALYSES_MODE=empty \
    CS_RUNS_JSON='{"check_runs":[{"app":{"slug":"github-code-scanning"},"status":"in_progress"}]}' run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'a code-scanning analysis still in progress blocks the merge, even with zero open alerts reported'
assert_contains "$out" 'blocked reason=code-scanning analysis has not completed for the current head' \
    'the pending-analysis block is named'

good_digest
out=$(CS_RUNS_JSON='{"check_runs":[{"app":{"slug":"github-code-scanning"},"status":"completed"}]}' run_gate)
assert_contains "$out" 'gate=PASS pr=9' \
    'a completed analysis recorded for the current head passes the gate regardless of check-run state'

good_digest
set +e
out=$(CS_PR_ANALYSES_MODE=error run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'an unreadable analyses endpoint blocks the merge (never treated as complete)'
assert_contains "$out" 'blocked reason=code-scanning analysis status is unreadable for the current head' \
    'the unreadable-completion block is named'

good_digest
set +e
out=$(CS_PR_ANALYSES_MODE=empty run_gate)
rc=$?
set -e
assert_eq '1' "$rc" \
    'no analysis recorded for the current head anywhere (PR ref or base ref) blocks the merge (absence of evidence is never evidence of completion)'
assert_contains "$out" 'blocked reason=no code-scanning analysis is recorded for the current head' \
    'the no-analysis block is named, and distinct from the unreadable-status block'

# --- issue #390: the analyses endpoint is authoritative; the check-run app
# slug is at most a secondary "still running" signal.

good_digest
out=$(CS_PR_ANALYSES_JSON="$(cat "$fixtures/merge-gate-honkhonk-249-analyses.json")" \
    CS_RUNS_JSON="$(cat "$fixtures/merge-gate-honkhonk-249-check-runs.json")" run_gate)
assert_contains "$out" 'gate=PASS pr=9' \
    'HonkHonk #249: analyses recorded under app.slug=github-advanced-security pass the gate (a slug-only lookup would false-block this head)'

good_digest
set +e
out=$(CS_PR_ANALYSES_MODE=empty CS_RUNS_UNREADABLE=1 run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'a check-run fetch failure alone does not block as "unreadable" -- it is a demoted, non-authoritative signal'
assert_contains "$out" 'blocked reason=no code-scanning analysis is recorded for the current head' \
    'the block is the analyses-absence reason, never the old check-run-unreadable reason'
assert_not_contains "$out" 'blocked reason=code-scanning analysis status is unreadable for the current head' \
    'a bare check-run failure is not, by itself, an unreadable-completion-signal block'

for slug in github-code-scanning github-advanced-security; do
    good_digest
    set +e
    out=$(CS_PR_ANALYSES_MODE=empty \
        CS_RUNS_JSON="{\"check_runs\":[{\"app\":{\"slug\":\"$slug\"},\"status\":\"in_progress\"}]}" run_gate)
    rc=$?
    set -e
    assert_eq '1' "$rc" "a still-running check run under app.slug=$slug blocks the merge as pending"
    assert_contains "$out" 'blocked reason=code-scanning analysis has not completed for the current head' \
        "the pending block is named for app.slug=$slug"
done

# --- PR #413 follow-up F1: a still-running scan blocks as pending even when
# an earlier analysis already matches the head (a rerun or a second SARIF
# upload in flight is real, incomplete evidence; scan_check_run_pending is
# now consulted before the head-match short-circuit, never after it).

good_digest
set +e
out=$(CS_PR_ANALYSES_JSON="$(cat "$fixtures/merge-gate-honkhonk-249-analyses.json")" \
    CS_RUNS_JSON='{"check_runs":[{"app":{"slug":"github-advanced-security"},"status":"in_progress"}]}' \
    run_gate)
rc=$?
set -e
assert_eq '1' "$rc" \
    'a still-running check run blocks the merge as pending even when a matching analysis for the current head already exists'
assert_contains "$out" 'blocked reason=code-scanning analysis has not completed for the current head' \
    'the pending block wins over the already-matched analysis'

# --- PR #413 CodeRabbit review, F1 (Major): a refs/pull/N/merge analysis
# legitimately records the GitHub-generated MERGE commit as its commit_sha
# for a pull_request-event upload, not the PR's own head SHA -- comparing
# only against head_sha there false-blocked every such PR. merge_commit_sha
# is read from the PR metadata already fetched for the live-state read, and
# a null value must never widen matching.

readonly MERGE_SHA='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
readonly UNRELATED_SHA='ffffffffffffffffffffffffffffffffffffffff'

good_digest
out=$(PR_MERGE_SHA="$MERGE_SHA" \
    CS_PR_ANALYSES_JSON="[{\"ref\":\"refs/pull/9/merge\",\"commit_sha\":\"$MERGE_SHA\",\"tool\":{\"name\":\"CodeQL\"},\"created_at\":\"2026-08-20T00:00:00Z\"}]" \
    run_gate)
assert_contains "$out" 'gate=PASS pr=9' \
    'an analysis recorded against the current PR merge commit (distinct from the head SHA) passes the gate'

good_digest
set +e
out=$(PR_MERGE_SHA="$MERGE_SHA" \
    CS_PR_ANALYSES_JSON="[{\"ref\":\"refs/pull/9/merge\",\"commit_sha\":\"$UNRELATED_SHA\",\"tool\":{\"name\":\"CodeQL\"},\"created_at\":\"2026-08-20T00:00:00Z\"}]" \
    run_gate)
rc=$?
set -e
assert_eq '1' "$rc" \
    'an analysis matching neither the head SHA nor the current merge SHA still blocks the merge'
assert_contains "$out" 'blocked reason=no code-scanning analysis is recorded for the current head' \
    'the merge-SHA widening never accepts an unrelated commit_sha'

good_digest
set +e
out=$(CS_PR_ANALYSES_JSON="[{\"ref\":\"refs/pull/9/merge\",\"commit_sha\":\"$UNRELATED_SHA\",\"tool\":{\"name\":\"CodeQL\"},\"created_at\":\"2026-08-20T00:00:00Z\"}]" \
    run_gate)
rc=$?
set -e
assert_eq '1' "$rc" \
    'with no merge_commit_sha on the PR (null, the un-mergeable/not-yet-computed default), an unrelated commit_sha never accidentally matches'
assert_contains "$out" 'blocked reason=no code-scanning analysis is recorded for the current head' \
    'a null merge_commit_sha never widens matching'

good_digest
out=$(CS_PR_ANALYSES_MODE=empty \
    CS_PR_HEAD_ANALYSES_MODE=ok \
    CS_PR_HEAD_ANALYSES_JSON="[{\"ref\":\"refs/pull/9/head\",\"commit_sha\":\"$HEAD_SHA\",\"tool\":{\"name\":\"CodeQL\"},\"created_at\":\"2026-08-20T00:00:00Z\"}]" \
    run_gate)
assert_contains "$out" 'gate=PASS pr=9' \
    'an analysis recorded against refs/pull/N/head matching the head SHA also passes the gate, for tools that scan the head ref directly'

# --- PR #413 follow-up F2: scheduled-only is granted only when the
# repository's own recent analysis history carries NO refs/pull/* entry at
# all; a repository that has ever analyzed a pull request demonstrably scans
# PRs, so a missing analysis for THIS PR is ambiguous absence, not a
# schedule -- and even when granted, scheduled-only is not exempt from the
# alerts-line readability requirement (only the two-signal never-used
# exception is).

good_digest
set +e
out=$(CS_PR_ANALYSES_MODE=empty CS_BASE_ANALYSES_MODE=ok \
    CS_BASE_ANALYSES_JSON='[{"ref":"refs/heads/main","commit_sha":"cccccccccccccccccccccccccccccccccccccccc","created_at":"2026-08-15T04:00:00Z","tool":{"name":"CodeQL"}}]' \
    CS_RECENT_ANALYSES_JSON='[{"ref":"refs/pull/7/merge","commit_sha":"dddddddddddddddddddddddddddddddddddddddd","created_at":"2026-07-01T00:00:00Z","tool":{"name":"CodeQL"}}]' \
    run_gate)
rc=$?
set -e
assert_eq '1' "$rc" \
    'a repository whose recent history includes a pull-request analysis is never granted scheduled-only, even with base-ref analyses present'
assert_contains "$out" 'blocked reason=no code-scanning analysis is recorded for the current head' \
    'this PR is missing analysis evidence and stays blocked as absent, not scheduled-only'

good_digest
out=$(CS_PR_ANALYSES_MODE=empty CS_BASE_ANALYSES_MODE=ok \
    CS_BASE_ANALYSES_JSON='[{"ref":"refs/heads/main","commit_sha":"cccccccccccccccccccccccccccccccccccccccc","created_at":"2026-08-15T04:00:00Z","tool":{"name":"CodeQL"}}]' \
    CS_RECENT_ANALYSES_JSON='[]' \
    run_gate)
assert_contains "$out" 'gate=PASS pr=9' \
    'scheduled-only code scanning (base-ref analyses exist, no PR-ref analysis anywhere in recent history) is reported, not blocked, when the alerts line is readable'
assert_contains "$out" 'code-scanning: scheduled-only, last analysis 2026-08-15T04:00:00Z on refs/heads/main' \
    'the scheduled-only report names the last analysis date and ref'

good_digest
sed -i 's/alerts: code-scanning open=0/alerts: code-scanning n\/a/' "$tmp/digest.txt"
set +e
out=$(CS_PR_ANALYSES_MODE=empty CS_BASE_ANALYSES_MODE=ok \
    CS_BASE_ANALYSES_JSON='[{"ref":"refs/heads/main","commit_sha":"cccccccccccccccccccccccccccccccccccccccc","created_at":"2026-08-15T04:00:00Z","tool":{"name":"CodeQL"}}]' \
    CS_RECENT_ANALYSES_JSON='[]' \
    run_gate)
rc=$?
set -e
assert_eq '1' "$rc" \
    'a scheduled-only repository still blocks on an unreadable alerts line -- n/a is not exempted for it, only the never-used exception is'
assert_contains "$out" 'blocked reason=code-scanning evidence is unreadable' \
    'the alerts-readability block applies to scheduled-only the same as any other status'
assert_contains "$out" 'code-scanning: scheduled-only, last analysis 2026-08-15T04:00:00Z on refs/heads/main' \
    'the scheduled-only report still prints even though the gate blocks for the separate alerts reason'

# --- PR #413 CodeRabbit review, N2: an unreadable recent-history probe never
# grants scheduled-only -- same fail-closed default as everywhere else.

good_digest
set +e
out=$(CS_PR_ANALYSES_MODE=empty CS_BASE_ANALYSES_MODE=ok \
    CS_BASE_ANALYSES_JSON='[{"ref":"refs/heads/main","commit_sha":"cccccccccccccccccccccccccccccccccccccccc","created_at":"2026-08-15T04:00:00Z","tool":{"name":"CodeQL"}}]' \
    CS_RECENT_ANALYSES_MODE=error \
    run_gate)
rc=$?
set -e
assert_eq '1' "$rc" \
    'an unreadable recent-history probe never grants scheduled-only, even with base-ref analyses present'
assert_contains "$out" 'blocked reason=no code-scanning analysis is recorded for the current head' \
    'the absent block fires when the scheduled-only discriminator itself cannot be read'
assert_not_contains "$out" 'code-scanning: scheduled-only' \
    'no scheduled-only report is printed when the discriminator could not be confirmed'

# --- PR #413 follow-up F3: the analyses endpoint's ref is sent as its own
# -f field, never interpolated into the URL (a base branch containing & or #
# would otherwise split or truncate the query string).

good_digest
: > "$tmp/gh-analyses-args.log"
out=$(run_gate)
assert_contains "$out" 'gate=PASS pr=9' 'sanity: the baseline run still passes before inspecting its recorded argv'
analyses_argv=$(cat "$tmp/gh-analyses-args.log")
assert_contains "$analyses_argv" $'ARG:-f\nARG:ref=refs/pull/9/merge' \
    'the ref for the PR-ref analyses query arrives as a separate -f ref= argument, not embedded in the URL'
assert_not_contains "$analyses_argv" 'analyses?ref=' \
    'the endpoint token itself never carries an embedded ?ref= query string'
assert_not_contains "$analyses_argv" 'ARG:repos/owner/repo/code-scanning/analyses?' \
    'the logged endpoint argument is the bare path, with no query string of any kind appended'

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

# --- issue #383: code-scanning not-configured + definitive-404 corroboration
# Two independent positive signals -- default-setup == not-configured AND a
# definitive 404 "no analysis found" from the alerts endpoint -- are required
# before "no code-scanning evidence" is read as "code scanning is unused"
# rather than "evidence is unreadable". All five acceptance-criteria cases:

good_digest
sed -i 's/alerts: code-scanning open=0/alerts: code-scanning n\/a/' "$tmp/digest.txt"
out=$(CS_PR_ANALYSES_MODE=empty CS_DEFAULT_SETUP_STATE=not-configured \
    CS_ALERTS_PROBE=definitive-404 run_gate)
assert_contains "$out" 'gate=PASS pr=9' \
    'not-configured default-setup corroborated by a definitive 404 passes the code-scanning portion of the gate'

good_digest
sed -i 's/alerts: code-scanning open=0/alerts: code-scanning n\/a/' "$tmp/digest.txt"
set +e
out=$(CS_PR_ANALYSES_MODE=empty CS_DEFAULT_SETUP_STATE=not-configured \
    CS_ALERTS_PROBE=forbidden-403 run_gate)
rc=$?
set -e
assert_eq '1' "$rc" \
    'not-configured default-setup alone, without the definitive 404 corroboration, still blocks the merge'
assert_contains "$out" 'blocked reason=no code-scanning analysis is recorded for the current head' \
    'a 403 on the alerts probe is never treated as corroborating absence'
assert_contains "$out" 'blocked reason=code-scanning evidence is unreadable' \
    'the digest n/a case still blocks too, since neither probe corroborated non-use'

good_digest
set +e
out=$(CS_PR_ANALYSES_MODE=empty CS_DEFAULT_SETUP_STATE=configured CS_ALERTS_PROBE=ok \
    CS_RUNS_JSON='{"check_runs":[{"app":{"slug":"github-code-scanning"},"status":"in_progress"}]}' run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'a configured repository with a still-pending analysis keeps blocking, unaffected by the corroboration'
assert_contains "$out" 'blocked reason=code-scanning analysis has not completed for the current head' \
    'the pending-analysis block is unchanged'

good_digest
sed -i 's/alerts: code-scanning open=0/alerts: code-scanning open=1/' "$tmp/digest.txt"
set +e
out=$(CS_DEFAULT_SETUP_STATE=configured CS_ALERTS_PROBE=ok run_gate)
rc=$?
set -e
assert_eq '1' "$rc" 'a configured repository with an open alert keeps blocking, unaffected by the corroboration'
assert_contains "$out" 'blocked reason=an open code-scanning alert is attributable to this PR' \
    'the open-alert block is unchanged'

good_digest
out=$(CS_DEFAULT_SETUP_STATE=configured CS_ALERTS_PROBE=ok run_gate)
assert_contains "$out" 'gate=PASS pr=9' \
    'a configured repository with zero open alerts keeps passing, unaffected by the corroboration'

finish
