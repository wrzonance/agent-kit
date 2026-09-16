#!/usr/bin/env bash
# Canonical review launcher options; caller supplies die_usage and require_value.
# shellcheck disable=SC2034
MAX_BUDGET_USD=5.00
MAX_BUDGET_EXPLICIT=0
MAX_OUTPUT_TOKENS=''
MAX_DURATION_SECONDS=900
RETRY_ATTEMPT_ID=''
RETRY_AUTHORIZATION=''
STOPPED_TIMEOUT_PROOF=''

usage() {
    cat <<EOF
Usage: $PROGNAME --worktree DIR --pr N --repo OWNER/REPO --run-dir DIR [--peer-cli-absent]
                 [--review-base-sha SHA]
                 [--max-budget-usd AMOUNT] [--max-output-tokens N]
                 [--max-duration-seconds N]
                 [--retry-attempt ID --retry-authorization TEXT]
                 [--stopped-timeout-proof FILE]
                 [--reaffirm-if-covered --comments FILE] [--provenance TEXT]
                 [--reviewer MODEL-EFFORT --override-authorization TEXT]

Builds DIR/adversarial.diff, runs exactly one consent-gated blind reviewer, and
publishes DIR/adversarial.result.json. On success stdout is one receipt-shaped
line containing provider, model, effort, mode, P1, and P2.

Reviewer selection comes from the running harness and peer-cli facts in the
untracked environment contract at the repository root. The optional
--peer-cli-absent flag must agree with a peer-cli= ... absent contract fact.

--reviewer MODEL-EFFORT and --override-authorization TEXT are required together.
MODEL is a claude-*, gpt-5.6-*, or gpt-6-* model ID; EFFORT is low, medium,
high, xhigh, or max (repo-config.sh --list-adversarial-efforts is authoritative).
Example: --reviewer claude-opus-5-xhigh --override-authorization "\$OPERATOR_AUTHORIZATION"
The authorization records the operator's explicit override; it does not replace
payload consent or prove live model availability. It overrides configured model/effort.

--provenance TEXT carries launch authorization (session-ledger RUN_ID, consent
record, verbatim invocation) as one argv element visible to harness approval.
Never eval'd or re-parsed: echoed to stderr as "provenance:" and saved to
DIR/state/provenance (mode 600) before any external call. Pass a shell variable;
never compose the text into shell source.

This is the real PR-diff review path. Capability probes use the provider helper
with --mode probe --no-payload, send only a synthetic snippet, and never spend
the one-review-per-PR receipt budget.

--review-base-sha SHA explicitly anchors a combined review at a full commit
SHA that is an ancestor of both the observed PR base and checked-out PR head.
The consent payload hashes the exact diff from that anchor; the attempt records
both the current PR base and the selected review base. Omitting it preserves
the ordinary current-base review.

--max-budget-usd controls Claude's spend ceiling (default 5.00); an explicit
--max-output-tokens controls Claude's response allowance, including thinking
(default: Claude Code's own setting). Provider model caps still apply.
--max-duration-seconds bounds either provider (default 900).
--retry-attempt ID and --retry-authorization TEXT request one new attempt after
an explicitly named failed canonical attempt. Only an explicit operator retry
authorization permits this; previous evidence is preserved, never reset.
For a finalized unknown timeout, also pass --stopped-timeout-proof FILE: private
operator evidence plus independently verified stopped processes. See the proof
schema in references/adversarial-review.md; missing or live identities block.

The consent record is always DIR/state/$CONSENT_STATE_FILENAME. There is no
caller-supplied consent flag.

--reaffirm-if-covered --comments FILE (issue #477): before launching a
reviewer, consults the sibling review-ledger.sh's status for this PR's
already-fetched comments artifact. A covered-head or covered-diff verdict
(the exact tree, or a base-merge-only advance of a tree, already reviewed)
appends a "reaffirmed_from" ledger entry and exits 0 WITHOUT spawning a
reviewer -- the DIR/adversarial.result.json this run would otherwise have
produced is never written. Only an absent ledger permits a first review;
stale or unreadable evidence requires reconciliation without another send.
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
            --worktree) require_value "$1" "${2:-}"; WORKTREE=$2; shift 2 ;;
            --worktree=*) WORKTREE=${1#*=}; shift ;;
            --pr) require_value "$1" "${2:-}"; PR=$2; shift 2 ;;
            --pr=*) PR=${1#*=}; shift ;;
            --repo) require_value "$1" "${2:-}"; REPO=$2; shift 2 ;;
            --repo=*) REPO=${1#*=}; shift ;;
            --run-dir) require_value "$1" "${2:-}"; RUN_DIR=$2; shift 2 ;;
            --run-dir=*) RUN_DIR=${1#*=}; shift ;;
            --review-base-sha) require_value "$1" "${2:-}"; REQUESTED_REVIEW_BASE_SHA=$2; shift 2 ;;
            --review-base-sha=*) REQUESTED_REVIEW_BASE_SHA=${1#*=}; shift ;;
            --peer-cli-absent) PEER_CLI_ABSENT=1; shift ;;
            --reaffirm-if-covered) REAFFIRM_IF_COVERED=1; shift ;;
            --comments) require_value "$1" "${2:-}"; LEDGER_COMMENTS=$2; shift 2 ;;
            --comments=*) LEDGER_COMMENTS=${1#*=}; shift ;;
            --provenance) require_value "$1" "${2:-}"; PROVENANCE=$2; shift 2 ;;
            --provenance=*) PROVENANCE=${1#*=}; shift ;;
            --reviewer) require_value "$1" "${2:-}"; REVIEWER_OVERRIDE=$2; shift 2 ;;
            --override-authorization) require_value "$1" "${2:-}"; OVERRIDE_AUTHORIZATION=$2; shift 2 ;;
            --max-budget-usd) require_value "$1" "${2:-}"; MAX_BUDGET_USD=$2; MAX_BUDGET_EXPLICIT=1; shift 2 ;;
            --max-output-tokens) require_value "$1" "${2:-}"; MAX_OUTPUT_TOKENS=$2; shift 2 ;;
            --max-duration-seconds) require_value "$1" "${2:-}"; MAX_DURATION_SECONDS=$2; shift 2 ;;
            --retry-attempt) require_value "$1" "${2:-}"; RETRY_ATTEMPT_ID=$2; shift 2 ;;
            --retry-authorization) require_value "$1" "${2:-}"; RETRY_AUTHORIZATION=$2; shift 2 ;;
            --stopped-timeout-proof) require_value "$1" "${2:-}"; STOPPED_TIMEOUT_PROOF=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown option: $1" ;;
        esac
    done
}

validate_review_limits() {
    if ! [[ $MAX_BUDGET_USD =~ ^[0-9]{1,4}([.][0-9]{1,2})?$ ]] ||
        ! LC_ALL=C awk -v value="$MAX_BUDGET_USD" 'BEGIN {exit !(value >= 0.01 && value <= 1000)}'; then
        die_usage '--max-budget-usd must be 0.01-1000 with at most two decimal places'
    fi
    MAX_BUDGET_USD=$(LC_ALL=C printf '%.2f' "$MAX_BUDGET_USD")
    if [[ -n $MAX_OUTPUT_TOKENS ]]; then
        if ! [[ $MAX_OUTPUT_TOKENS =~ ^[1-9][0-9]{0,5}$ ]] || ((MAX_OUTPUT_TOKENS > 128000)); then
            die_usage '--max-output-tokens must be an integer from 1 to 128000'
        fi
    fi
    if ! [[ $MAX_DURATION_SECONDS =~ ^[1-9][0-9]{0,4}$ ]] || ((MAX_DURATION_SECONDS > 86400)); then
        die_usage '--max-duration-seconds must be an integer from 1 to 86400'
    fi
    if [[ -n $RETRY_ATTEMPT_ID || -n $RETRY_AUTHORIZATION ]]; then
        [[ -n $RETRY_ATTEMPT_ID && -n $RETRY_AUTHORIZATION ]] ||
            die_usage '--retry-attempt and --retry-authorization are required together'
    fi
    [[ -z $STOPPED_TIMEOUT_PROOF || -n $RETRY_ATTEMPT_ID ]] ||
        die_usage '--stopped-timeout-proof requires an explicitly authorized retry'
}

validate_provider_limits() {
    if [[ $PROVIDER != anthropic && ( $MAX_BUDGET_EXPLICIT == 1 || -n $MAX_OUTPUT_TOKENS ) ]]; then
        die_usage '--max-budget-usd and --max-output-tokens require the Claude reviewer'
    fi
}

guard_fresh_retry_directory() {
    [[ -n $RETRY_ATTEMPT_ID ]] || return 0
    local artifact
    for artifact in adversarial.result.json claude.ndjson codex.jsonl state/review-attempt.json state/launch-attempted; do
        if [[ -e $RUN_DIR/$artifact || -L $RUN_DIR/$artifact ]]; then
            die 'an authorized retry requires a fresh run directory; original evidence is preserved'
        fi
    done
}
