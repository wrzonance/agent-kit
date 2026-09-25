#!/usr/bin/env bash
# Compose the existing draft-open and review-finalization bookkeeping recipes.
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
readonly UINT_RE='^[1-9][0-9]*$'
SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)
readonly SCRIPT_DIR
SKILLS_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
readonly SKILLS_DIR

RUN_DIR_SH=${PR_STAGE_RUN_DIR_SH:-$SKILLS_DIR/review-remote-pr/scripts/run-dir.sh}
RUN_STATE_SH=${PR_STAGE_RUN_STATE_SH:-$SKILLS_DIR/.shared/scripts/run-state.sh}
COMPOSE_SH=${PR_STAGE_COMPOSE_SH:-$SCRIPT_DIR/compose-pr-body.sh}
GH_BODY_SH=${PR_STAGE_GH_BODY_SH:-$SKILLS_DIR/.shared/scripts/gh-body.sh}
BOARD_SH=${PR_STAGE_BOARD_SH:-$SCRIPT_DIR/move-github-project-item.sh}
GH_PR_STATE_SH=${PR_STAGE_GH_PR_STATE_SH:-$SKILLS_DIR/review-remote-pr/scripts/gh-pr-state.sh}
POST_RECEIPT_SH=${PR_STAGE_POST_RECEIPT_SH:-$SKILLS_DIR/review-remote-pr/scripts/post-receipt.sh}
CONTRACT_READ_SH=${PR_STAGE_CONTRACT_READ_SH:-$SKILLS_DIR/.shared/scripts/contract-read.sh}
GH_BIN=${PR_STAGE_GH:-gh}

ACTION=''
RUN_ID=''
REPO_ROOT=''
DISPATCH_PLAN=''
ISSUE=''
PR=''
REPO=''
HEAD_REF=''
TITLE=''
WHY_FILE=''
WHAT_FILE=''
DECISIONS_FILE=''
TESTING_FILE=''
BASELINE_FILE=''
BASELINE_EXCLUSION_FILE=''
BLOCKER_FILE=''
AGENT=''
AGENT_IDENTITY=''
SKIP_RATIONALE=''
ORACLE=''
MODE_REASON=''
PROVIDER=''
MODEL=''
EFFORT=''
MODE=''

usage() {
    cat <<EOF
Usage: $PROGNAME open --run-id ID --repo-root DIR --dispatch-plan FILE --issue N \\
       --repo OWNER/REPO --head BRANCH --title TITLE --why-file FILE --what-file FILE \\
       --decisions-file FILE --testing-file FILE --agent ID [--baseline-file FILE] \\
       [--baseline-exclusion-file FILE] [--blocker-file FILE]
       $PROGNAME finalize [--run-id ID] --repo-root DIR --pr N --repo OWNER/REPO \\
       --agent-identity ID [--provider S --model S --effort S --mode S] \\
       [--mode-reason S] [--skip-rationale S --oracle S]

open composes the canonical four-section body, durably binds its repo/head/body
identity before creating the draft, registers the PR, and moves its issue to In review.
finalize takes one fresh PR digest, publishes or reconciles the receipt, classifies it,
and records the existing run summary. Repeating a completed stage is a no-op.
EOF
}

die() { printf '%s: %s\n' "$PROGNAME" "$1" >&2; exit 1; }
die_usage() { printf '%s: %s\n' "$PROGNAME" "$1" >&2; usage >&2; exit 2; }
require_value() { [[ -n ${2-} ]] || die_usage "$1 requires a value"; }

parse_args() {
    (($#)) || die_usage 'a subcommand is required'
    if [[ $1 == -- ]]; then
        shift
        (($# == 0)) || die_usage "unexpected argument after --: $1"
        die_usage 'a subcommand is required'
    fi
    ACTION=$1
    shift
    case $ACTION in open|finalize) ;; -h|--help) usage; exit 0 ;; *) die_usage "unknown subcommand: $ACTION" ;; esac
    while (($#)); do
        case $1 in
            --) shift; (($# == 0)) || die_usage "unexpected argument after --: $1"; break ;;
            --run-id|--repo-root|--dispatch-plan|--issue|--pr|--repo|--head|--title|--why-file|--what-file|--decisions-file|--testing-file|--baseline-file|--baseline-exclusion-file|--blocker-file|--agent|--agent-identity|--skip-rationale|--oracle|--mode-reason|--provider|--model|--effort|--mode)
                require_value "$1" "${2-}"
                case $1 in
                    --run-id) RUN_ID=$2 ;; --repo-root) REPO_ROOT=$2 ;; --dispatch-plan) DISPATCH_PLAN=$2 ;;
                    --issue) ISSUE=$2 ;; --pr) PR=$2 ;; --repo) REPO=$2 ;; --head) HEAD_REF=$2 ;;
                    --title) TITLE=$2 ;; --why-file) WHY_FILE=$2 ;; --what-file) WHAT_FILE=$2 ;;
                    --decisions-file) DECISIONS_FILE=$2 ;; --testing-file) TESTING_FILE=$2 ;;
                    --baseline-file) BASELINE_FILE=$2 ;; --baseline-exclusion-file) BASELINE_EXCLUSION_FILE=$2 ;;
                    --blocker-file) BLOCKER_FILE=$2 ;; --agent) AGENT=$2 ;;
                    --agent-identity) AGENT_IDENTITY=$2 ;; --skip-rationale) SKIP_RATIONALE=$2 ;;
                    --oracle) ORACLE=$2 ;; --mode-reason) MODE_REASON=$2 ;; --provider) PROVIDER=$2 ;;
                    --model) MODEL=$2 ;; --effort) EFFORT=$2 ;; --mode) MODE=$2 ;;
                esac
                shift 2
                ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
}

require_common() {
    [[ -n $REPO_ROOT && -d $REPO_ROOT ]] || die_usage '--repo-root must be an existing directory'
    [[ $REPO == */* && $REPO != */ && $REPO != /* ]] || die_usage '--repo must look like OWNER/REPO'
    command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
    [[ -x $RUN_DIR_SH && -x $RUN_STATE_SH ]] || die 'run-state helpers are unavailable'
}

state_get() {
    local path=$1 rc=0
    [[ -n $RUN_ID ]] || return 11
    "$RUN_STATE_SH" get --run-id "$RUN_ID" --repo-root "$REPO_ROOT" --path "$path" || rc=$?
    return "$rc"
}

state_set_json() {
    local path=$1 json=$2
    "$RUN_STATE_SH" set --run-id "$RUN_ID" --repo-root "$REPO_ROOT" --path "$path" --json "$json"
}

compose_body() {
    local body=$1
    local -a args=(--issue "$ISSUE" --why-file "$WHY_FILE" --what-file "$WHAT_FILE"
        --decisions-file "$DECISIONS_FILE" --testing-file "$TESTING_FILE" --agent "$AGENT" --output "$body")
    [[ -z $BASELINE_FILE ]] || args+=(--baseline-file "$BASELINE_FILE")
    [[ -z $BASELINE_EXCLUSION_FILE ]] || args+=(--baseline-exclusion-file "$BASELINE_EXCLUSION_FILE")
    [[ -z $BLOCKER_FILE ]] || args+=(--blocker-file "$BLOCKER_FILE")
    "$COMPOSE_SH" "${args[@]}"
}

recover_created_pr() {
    local body=$1 listed matches count
    listed=$($GH_BIN pr list --repo "$REPO" --head "$HEAD_REF" --state all --limit 100 \
        --json number,url,headRefName,body) || die 'PR create response was lost and the exact-head lookup failed; do not retry'
    matches=$(jq -c --arg head "$HEAD_REF" --rawfile body "$body" \
        '[.[] | select(.headRefName == $head and .body == $body)]' <<<"$listed") ||
        die 'PR create response was lost and the exact-head lookup was invalid; do not retry'
    count=$(jq 'length' <<<"$matches")
    ((count == 1)) || {
        if ((count > 1)); then
            die 'PR create response was lost and recovery is ambiguous; multiple PRs match the exact head and body'
        fi
        die 'PR create response was lost and no exact head/body match was found; remote state is uncertain, do not retry'
    }
    jq -c '.[0] | {number,html_url:.url}' <<<"$matches"
}

open_stage() {
    require_common
    [[ -n $RUN_ID ]] || die_usage 'open requires --run-id'
    [[ $ISSUE =~ $UINT_RE ]] || die_usage 'open requires a positive --issue'
    [[ -n $HEAD_REF && -n $TITLE && -n $AGENT ]] || die_usage 'open requires --head, --title, and --agent'
    [[ -f $DISPATCH_PLAN && ! -L $DISPATCH_PLAN && -O $DISPATCH_PLAN ]] ||
        die_usage 'open requires an owned regular --dispatch-plan'
    [[ -x $COMPOSE_SH && -x $GH_BODY_SH && -x $BOARD_SH ]] || die 'open-stage helpers are unavailable'

    local run_dir body body_sha key saved='' get_rc=0 had_intent=0 intent pr_json='' pr_number source=create
    run_dir=$($RUN_DIR_SH --run-id "$RUN_ID" --repo-root "$REPO_ROOT") || die 'could not resolve run directory'
    body=$run_dir/pr-stage-$ISSUE-body.md
    compose_body "$body"
    body_sha=$(sha256sum -- "$body" | cut -d ' ' -f 1)
    key=pr_stage.issue_$ISSUE.open
    intent=$(jq -nc --arg repo "$REPO" --arg head "$HEAD_REF" --arg body_sha256 "$body_sha" \
        '{repo:$repo,head:$head,body_sha256:$body_sha256}')
    saved=$(state_get "$key") || get_rc=$?
    case $get_rc in
        0)
            had_intent=1
            jq -e --argjson intent "$intent" '.intent == $intent' <<<"$saved" >/dev/null ||
                die 'saved open-stage intent does not match repo/head/body; refusing a different PR mutation'
            ;;
        11)
            saved=$(jq -nc --argjson intent "$intent" '{intent:$intent}')
            state_set_json "$key" "$saved"
            ;;
        *) die 'open-stage run state is unavailable' ;;
    esac

    if jq -e '.create_failure == true' <<<"$saved" >/dev/null 2>&1; then
        pr_number=$(jq -er '.pr | select(type=="number" and .>0)' <<<"$saved") || die 'failed open state has no PR identity'
        die "PR #$pr_number was created but closing-link verification failed; return to PR-open handling"
    fi
    if jq -e '.board == true' <<<"$saved" >/dev/null 2>&1; then
        pr_number=$(jq -er '.pr | select(type=="number" and .>0)' <<<"$saved") || die 'completed open state has no PR identity'
        printf 'stage=open pr=%s completed=compose,create,register,board outstanding=none\n' "$pr_number"
        return 0
    fi
    if jq -e '.pr | type == "number" and . > 0' <<<"$saved" >/dev/null 2>&1; then
        pr_number=$(jq -r '.pr' <<<"$saved")
        source=$(jq -r '.identity_source // "create"' <<<"$saved")
    else
        if ((had_intent)); then
            source=recover
            pr_json=$(recover_created_pr "$body")
        else
            local create_rc=0
            pr_json=$($GH_BODY_SH pr create --json --run-id "$RUN_ID" --repo-root "$REPO_ROOT" \
                --dispatch-plan "$DISPATCH_PLAN" --plan-issue "$ISSUE" --body-file "$body" \
                --repo "$REPO" --head "$HEAD_REF" --title "$TITLE" --expect-closing-issue "$ISSUE") || create_rc=$?
            if ((create_rc != 0)); then
                if jq -e '.number | type=="number" and .>0' <<<"$pr_json" >/dev/null 2>&1; then
                    if jq -e '.closing_issue.state == "failed"' <<<"$pr_json" >/dev/null 2>&1; then
                        pr_number=$(jq -r '.number' <<<"$pr_json")
                        saved=$(jq -c --argjson pr "$pr_number" '. + {pr:$pr,identity_source:"create",create_failure:true}' <<<"$saved")
                        state_set_json "$key" "$saved"
                        die "PR #$pr_number was created but closing-link verification failed; return to PR-open handling"
                    fi
                else
                    source=recover
                    pr_json=$(recover_created_pr "$body")
                fi
            fi
        fi
        pr_number=$(jq -er '.number | select(type=="number" and .>0 and floor==.)' <<<"$pr_json") ||
            die 'PR creation/recovery returned no positive PR number'
        saved=$(jq -c --argjson pr "$pr_number" --arg source "$source" \
            '. + {pr:$pr,identity_source:$source}' <<<"$saved")
        state_set_json "$key" "$saved"
    fi

    "$RUN_STATE_SH" record-summary --run-id "$RUN_ID" --repo-root "$REPO_ROOT" \
        --path opened_prs --json "$pr_number" ||
        die "stage=open pr=$pr_number completed=compose,$source outstanding=register,board failure=registration"
    saved=$(jq -c '. + {registered:true}' <<<"$saved")
    state_set_json "$key" "$saved"
    "$BOARD_SH" --issue-number "$ISSUE" --status 'In review' --repo "$REPO" --repo-root "$REPO_ROOT" >/dev/null ||
        die "stage=open pr=$pr_number completed=compose,$source,register outstanding=board failure=board-move"
    saved=$(jq -c '. + {board:true}' <<<"$saved")
    state_set_json "$key" "$saved"
    printf 'stage=open pr=%s completed=compose,%s,register,board outstanding=none\n' "$pr_number" "$source"
}

load_attempt() {
    local attempt=$1
    [[ -f $attempt && ! -L $attempt && -O $attempt && -r $attempt ]] ||
        die 'review attempt evidence is unavailable; return to the review phase'
    IFS=$'\t' read -r PROVIDER MODEL EFFORT MODE HEAD_REF payload substituted < <(
        jq -er '[.provider,.model,.effort,.mode,.head,.payload,(.modelSubstitutedFrom // "")] |
            select((.[0:6] | all(.[]; type=="string" and length>0)) and (.[6] | type=="string")) | @tsv' "$attempt") ||
        die 'review attempt evidence is incomplete; return to the review phase'
    REVIEW_PAYLOAD=$payload
    MODEL_SUBSTITUTED_FROM=$substituted
}

finalize_stage() {
    require_common
    [[ $PR =~ $UINT_RE ]] || die_usage 'finalize requires a positive --pr'
    [[ -n $AGENT_IDENTITY ]] || die_usage 'finalize requires --agent-identity'
    [[ -x $GH_PR_STATE_SH && -x $POST_RECEIPT_SH ]] || die 'finalize-stage helpers are unavailable'
    [[ -z $SKIP_RATIONALE && -z $ORACLE || -n $SKIP_RATIONALE && -n $ORACLE ]] ||
        die_usage '--skip-rationale and --oracle must be provided together'

    local key=pr_stage.pr_$PR.finalize saved='' get_rc=11
    if [[ -n $RUN_ID ]]; then get_rc=0; saved=$(state_get "$key") || get_rc=$?; fi
    if ((get_rc == 0)) && jq -e '.complete == true' <<<"$saved" >/dev/null 2>&1; then
        local receipt
        receipt=$(jq -r '.receipt' <<<"$saved")
        printf 'stage=finalize pr=%s receipt=%s completed=digest,publish,classify,summary outstanding=none\n' "$PR" "$receipt"
        return 0
    fi
    ((get_rc == 11)) || die 'finalize-stage run state is unavailable'

    local run_dir state_dir comments digest findings p1 p2 receipt collection publish_rc=0 harness=''
    run_dir=$($RUN_DIR_SH --pr "$PR") || die 'could not resolve PR run directory'
    state_dir=$run_dir/state
    mkdir -p -- "$state_dir"
    comments=$state_dir/pr_${PR}_issue_comments.json
    digest=$state_dir/pr_${PR}_final.digest
    findings=$run_dir/findings.ndjson
    [[ -f $findings && ! -L $findings && -O $findings && -r $findings ]] ||
        die 'findings evidence is unavailable; return to the review phase'
    [[ -f $run_dir/accepted-findings.ndjson && ! -L $run_dir/accepted-findings.ndjson &&
        -O $run_dir/accepted-findings.ndjson && -r $run_dir/accepted-findings.ndjson ]] ||
        die 'accepted findings evidence is unavailable; return to classification'

    local -a acceptance_args=()
    if [[ -f $REPO_ROOT/.agent/acceptance.txt && ! -L $REPO_ROOT/.agent/acceptance.txt ]]; then
        local acceptance_command
        while IFS= read -r acceptance_command || [[ -n $acceptance_command ]]; do
            [[ -z $acceptance_command ]] || acceptance_args+=(--acceptance-command "$acceptance_command")
        done <"$REPO_ROOT/.agent/acceptance.txt"
    fi
    "$GH_PR_STATE_SH" --pr "$PR" --repo "$REPO" --repo-root "$REPO_ROOT" --full --no-cache \
        --tmpdir "$state_dir" --digest-out "$digest" "${acceptance_args[@]}" >/dev/null ||
        die "stage=finalize pr=$PR completed=none outstanding=digest,publish,classify,summary failure=fresh-pr-evidence"

    local REVIEW_PAYLOAD='' MODEL_SUBSTITUTED_FROM=''
    if [[ -z $SKIP_RATIONALE ]]; then
        load_attempt "$state_dir/review-attempt.json"
    else
        [[ -n $PROVIDER && -n $MODEL && -n $EFFORT && -n $MODE ]] ||
            die_usage 'verified skip requires --provider, --model, --effort, and --mode'
        HEAD_REF=''
    fi
    [[ $MODE != blind-fallback || -n $MODE_REASON ]] || die_usage 'blind-fallback requires --mode-reason'
    if [[ -x $CONTRACT_READ_SH ]]; then
        harness=$($CONTRACT_READ_SH --repo-root "$REPO_ROOT" --get harness.name 2>/dev/null) || harness=''
    fi
    p1=$(jq -s '[.[] | select(.severity=="P1")] | length' "$findings") || die 'could not count P1 findings'
    p2=$(jq -s '[.[] | select(.severity=="P2")] | length' "$findings") || die 'could not count P2 findings'
    local -a publish_args=(publish --pr "$PR" --repo "$REPO" --issue-comments "$comments"
        --pr-state-digest "$digest" --provider "$PROVIDER" --model "$MODEL" --effort "$EFFORT"
        --mode "$MODE" --p1 "$p1" --p2 "$p2" --agent-identity "$AGENT_IDENTITY" --require-pushed)
    [[ -z $MODE_REASON ]] || publish_args+=(--mode-reason "$MODE_REASON")
    [[ -z $MODEL_SUBSTITUTED_FROM ]] || publish_args+=(--model-substituted-from "$MODEL_SUBSTITUTED_FROM")
    [[ -z $HEAD_REF ]] || publish_args+=(--head-sha "$HEAD_REF")
    [[ -z $REVIEW_PAYLOAD ]] || publish_args+=(--diff-payload "$REVIEW_PAYLOAD")
    [[ -z $harness ]] || publish_args+=(--harness "$harness")
    [[ -z $SKIP_RATIONALE ]] || publish_args+=(--skip-rationale "$SKIP_RATIONALE" --oracle "$ORACLE")
    RUN_DIR=$run_dir "$POST_RECEIPT_SH" "${publish_args[@]}" || publish_rc=$?
    case $publish_rc in
        0|11) ;;
        12) die "stage=finalize pr=$PR completed=digest outstanding=publish,classify,summary failure=fixes-not-pushed" ;;
        13) die "stage=finalize pr=$PR completed=digest outstanding=publish,classify,summary failure=finding-order" ;;
        *) die "stage=finalize pr=$PR completed=digest outstanding=publish,classify,summary failure=publication-uncertain" ;;
    esac
    receipt=$($POST_RECEIPT_SH status --issue-comments "$comments") ||
        die "stage=finalize pr=$PR completed=digest,publish outstanding=classify,summary failure=receipt-classification"
    case $receipt in
        receipt=adversarial) receipt=adversarial; collection=receipt_prs ;;
        receipt=verified-skip) receipt=verified-skip; collection=skipped_prs ;;
        *) die "unexpected receipt classification: $receipt" ;;
    esac
    if [[ -n $RUN_ID ]]; then
        "$RUN_STATE_SH" record-summary --run-id "$RUN_ID" --repo-root "$REPO_ROOT" \
            --path "$collection" --json "$PR" ||
            die "stage=finalize pr=$PR receipt=$receipt completed=digest,publish,classify outstanding=summary failure=summary-recording"
        saved=$(jq -nc --arg receipt "$receipt" '{complete:true,receipt:$receipt}')
        state_set_json "$key" "$saved"
    fi
    printf 'stage=finalize pr=%s receipt=%s completed=digest,publish,classify,summary outstanding=none\n' "$PR" "$receipt"
}

parse_args "$@"
case $ACTION in open) open_stage ;; finalize) finalize_stage ;; esac
