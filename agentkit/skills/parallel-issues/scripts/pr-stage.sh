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
RUN_REPO_ROOT=''
DISPATCH_PLAN=''
ISSUE=''
PR=''
REPO=''
HEAD_REF=''
EXPECT_CLOSING_ISSUE=''
DEFAULT_BRANCH=''
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
       --default-branch BRANCH [--baseline-exclusion-file FILE] [--blocker-file FILE] \
       [--expect-closing-issue N]
       $PROGNAME finalize [--run-id ID --run-repo-root DIR] --repo-root DIR --pr N --repo OWNER/REPO \\
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
            --run-id|--repo-root|--run-repo-root|--dispatch-plan|--issue|--pr|--repo|--head|--expect-closing-issue|--default-branch|--title|--why-file|--what-file|--decisions-file|--testing-file|--baseline-file|--baseline-exclusion-file|--blocker-file|--agent|--agent-identity|--skip-rationale|--oracle|--mode-reason|--provider|--model|--effort|--mode)
                require_value "$1" "${2-}"
                case $1 in
                    --run-id) RUN_ID=$2 ;; --repo-root) REPO_ROOT=$2 ;; --run-repo-root) RUN_REPO_ROOT=$2 ;;
                    --dispatch-plan) DISPATCH_PLAN=$2 ;;
                    --issue) ISSUE=$2 ;; --pr) PR=$2 ;; --repo) REPO=$2 ;; --head) HEAD_REF=$2 ;;
                    --expect-closing-issue) EXPECT_CLOSING_ISSUE=$2 ;;
                    --default-branch) DEFAULT_BRANCH=$2 ;;
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
    REPO_ROOT=$(cd -P -- "$REPO_ROOT" && pwd -P) || die 'could not resolve --repo-root'
    local checkout_root
    checkout_root=$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null) ||
        die_usage '--repo-root must be a Git checkout root'
    checkout_root=$(cd -P -- "$checkout_root" && pwd -P) || die 'could not resolve the Git checkout root'
    [[ $checkout_root == "$REPO_ROOT" ]] || die_usage '--repo-root must name the Git checkout root'
    if [[ -n $RUN_REPO_ROOT ]]; then
        [[ -d $RUN_REPO_ROOT ]] || die_usage '--run-repo-root must be an existing directory'
        RUN_REPO_ROOT=$(cd -P -- "$RUN_REPO_ROOT" && pwd -P) || die 'could not resolve --run-repo-root'
    fi
    [[ $REPO == */* && $REPO != */ && $REPO != /* ]] || die_usage '--repo must look like OWNER/REPO'
    command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
    [[ -x $RUN_DIR_SH && -x $RUN_STATE_SH ]] || die 'run-state helpers are unavailable'
}

state_get() {
    local path=$1 rc=0
    [[ -n $RUN_ID ]] || return 11
    "$RUN_STATE_SH" get --run-id "$RUN_ID" --repo-root "${RUN_REPO_ROOT:-$REPO_ROOT}" --path "$path" || rc=$?
    return "$rc"
}

state_set_json() {
    local path=$1 json=$2
    "$RUN_STATE_SH" set --run-id "$RUN_ID" --repo-root "${RUN_REPO_ROOT:-$REPO_ROOT}" --path "$path" --json "$json"
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

list_open_head_prs() {
    local listed
    listed=$($GH_BIN pr list --repo "$REPO" --head "$HEAD_REF" --state open --limit 100 \
        --json number,url,state,isDraft,title,baseRefName,headRefName,headRefOid,body) ||
        die 'the exact-head PR lookup failed; no create mutation was retried'
    jq -ce 'select(type == "array")' <<<"$listed" || die 'the exact-head PR lookup returned invalid evidence'
}

recover_created_pr() {
    local body=$1 base=$2 head_sha=$3 preexisting=$4 listed matches count
    listed=$(list_open_head_prs) || die 'PR create response was lost and the exact-head lookup failed; do not retry'
    matches=$(jq -c --arg head "$HEAD_REF" --arg base "$base" --arg sha "$head_sha" --arg title "$TITLE" \
        --rawfile body "$body" --argjson preexisting "$preexisting" '
        [.[] | select(.number | type == "number" and . > 0 and floor == .)
         | select(.state == "OPEN" and .isDraft == true and .title == $title and .baseRefName == $base
             and .headRefName == $head and .headRefOid == $sha and .body == $body)
         | select(.number as $number | ($preexisting | index($number)) == null)]' <<<"$listed") ||
        die 'PR create response was lost and the exact-head lookup was invalid; do not retry'
    count=$(jq 'length' <<<"$matches")
    ((count == 1)) || {
        if ((count > 1)); then
            die 'PR create response was lost and recovery is ambiguous; multiple new open draft PRs match the exact target/head/body'
        fi
        die 'PR create response was lost and no new open draft PR matches the exact target/head/body; remote state is uncertain, do not retry'
    }
    jq -c '.[0] | {number,html_url:.url}' <<<"$matches"
}

open_stage() {
    require_common
    [[ -n $RUN_ID ]] || die_usage 'open requires --run-id'
    [[ $ISSUE =~ $UINT_RE ]] || die_usage 'open requires a positive --issue'
    [[ -n $HEAD_REF && -n $TITLE && -n $AGENT ]] || die_usage 'open requires --head, --title, and --agent'
    [[ -n $DEFAULT_BRANCH ]] || die_usage 'open requires --default-branch'
    [[ -z $EXPECT_CLOSING_ISSUE || $EXPECT_CLOSING_ISSUE == "$ISSUE" ]] ||
        die_usage '--expect-closing-issue must equal --issue'
    [[ -f $DISPATCH_PLAN && ! -L $DISPATCH_PLAN && -O $DISPATCH_PLAN ]] ||
        die_usage 'open requires an owned regular --dispatch-plan'
    [[ -x $COMPOSE_SH && -x $GH_BODY_SH && -x $BOARD_SH ]] || die 'open-stage helpers are unavailable'
    [[ -z $RUN_REPO_ROOT ]] || die_usage 'open does not accept --run-repo-root'
    RUN_REPO_ROOT=$REPO_ROOT

    local run_dir body candidate outcome body_sha key saved='' get_rc=0 had_intent=0 intent pr_json='' pr_number source=create
    local base head_sha preexisting='[]' listed delivery
    run_dir=$($RUN_DIR_SH --run-id "$RUN_ID" --repo-root "$REPO_ROOT") || die 'could not resolve run directory'
    body=$run_dir/pr-stage-$ISSUE-body.md
    candidate=$run_dir/pr-stage-$ISSUE-candidate.md
    outcome=$run_dir/pr-stage-$ISSUE-create-outcome.json
    compose_body "$candidate"
    body_sha=$(sha256sum -- "$candidate" | cut -d ' ' -f 1)
    base=$(jq -er --argjson issue "$ISSUE" \
        '[.entries[] | select(.issue == $issue) | .publicationTarget] |
         select(length == 1) | .[0] | select(type == "string" and length > 0)' "$DISPATCH_PLAN") ||
        { rm -f -- "$candidate"; die 'dispatch plan has no unique publication target for this issue'; }
    if [[ $base == "$DEFAULT_BRANCH" ]]; then
        [[ $EXPECT_CLOSING_ISSUE == "$ISSUE" ]] || {
            rm -f -- "$candidate"; die_usage 'default-target open requires --expect-closing-issue matching --issue'
        }
    else
        [[ -z $EXPECT_CLOSING_ISSUE ]] || {
            rm -f -- "$candidate"; die_usage 'stacked-target open must omit --expect-closing-issue'
        }
    fi
    head_sha=$(git -C "$REPO_ROOT" rev-parse --verify "refs/heads/$HEAD_REF^{commit}" 2>/dev/null) ||
        { rm -f -- "$candidate"; die 'could not resolve the intended branch head commit'; }
    key=pr_stage.issue_$ISSUE.open
    saved=$(state_get "$key") || get_rc=$?
    case $get_rc in
        0)
            had_intent=1
            jq -e --arg repo "$REPO" --arg head "$HEAD_REF" --arg head_sha "$head_sha" \
                --arg base "$base" --arg default_branch "$DEFAULT_BRANCH" --arg title "$TITLE" \
                --arg closing "$EXPECT_CLOSING_ISSUE" \
                --arg body_sha256 "$body_sha" '
                .intent.repo == $repo and .intent.head == $head and .intent.head_sha == $head_sha
                and .intent.base == $base and .intent.default_branch == $default_branch
                and .intent.title == $title
                and .intent.expect_closing_issue == $closing
                and .intent.body_sha256 == $body_sha256' <<<"$saved" >/dev/null || {
                    rm -f -- "$candidate"
                    die 'saved open-stage intent does not match repo/target/head/title/body; refusing a different PR mutation'
                }
            [[ -f $body && ! -L $body && -O $body ]] || {
                rm -f -- "$candidate"; die 'saved open-stage body evidence is unavailable'
            }
            [[ $(sha256sum -- "$body" | cut -d ' ' -f 1) == "$body_sha" ]] || {
                rm -f -- "$candidate"; die 'saved open-stage body evidence does not match its intent'
            }
            preexisting=$(jq -ce '.intent.preexisting_prs | select(type == "array")' <<<"$saved") || {
                rm -f -- "$candidate"; die 'saved open-stage intent lacks pre-existing PR evidence'
            }
            rm -f -- "$candidate"
            ;;
        11)
            listed=$(list_open_head_prs) || { rm -f -- "$candidate"; die 'could not snapshot pre-existing exact-head PRs'; }
            preexisting=$(jq -ce '[.[] | .number | select(type == "number" and . > 0 and floor == .)] | unique' \
                <<<"$listed") || { rm -f -- "$candidate"; die 'could not classify pre-existing exact-head PRs'; }
            intent=$(jq -nc --arg repo "$REPO" --arg head "$HEAD_REF" --arg head_sha "$head_sha" \
                --arg base "$base" --arg default_branch "$DEFAULT_BRANCH" --arg title "$TITLE" \
                --arg closing "$EXPECT_CLOSING_ISSUE" \
                --arg body_sha256 "$body_sha" \
                --argjson preexisting "$preexisting" \
                '{repo:$repo,head:$head,head_sha:$head_sha,base:$base,default_branch:$default_branch,title:$title,
                  expect_closing_issue:$closing,body_sha256:$body_sha256,
                  preexisting_prs:$preexisting}')
            mv -f -- "$candidate" "$body"
            saved=$(jq -nc --argjson intent "$intent" '{intent:$intent,create_delivery:"not-started"}')
            state_set_json "$key" "$saved"
            ;;
        *) rm -f -- "$candidate"; die 'open-stage run state is unavailable' ;;
    esac

    if jq -e '.create_failure == true' <<<"$saved" >/dev/null 2>&1; then
        pr_number=$(jq -er '.pr | select(type=="number" and .>0)' <<<"$saved") || die 'failed open state has no PR identity'
        if [[ $(jq -r '.create_failure_kind // "verification"' <<<"$saved") == closing-link ]]; then
            die "PR #$pr_number was created but closing-link verification failed; return to PR-open handling"
        fi
        die "PR #$pr_number was created but create verification failed; return to PR-open handling"
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
        delivery=$(jq -r '.create_delivery // "uncertain"' <<<"$saved")
        if ((had_intent)) && [[ $delivery != not-started && $delivery != not-attempted ]]; then
            source=recover
            pr_json=$(recover_created_pr "$body" "$base" "$head_sha" "$preexisting")
        else
            local create_rc=0
            local -a create_args=(pr create --json --run-id "$RUN_ID" --repo-root "$REPO_ROOT" \
                --dispatch-plan "$DISPATCH_PLAN" --plan-issue "$ISSUE" --body-file "$body" \
                --repo "$REPO" --head "$HEAD_REF" --title "$TITLE" \
                --mutation-outcome-file "$outcome")
            [[ -z $EXPECT_CLOSING_ISSUE ]] || create_args+=(--expect-closing-issue "$ISSUE")
            saved=$(jq -c '.create_delivery = "uncertain"' <<<"$saved")
            state_set_json "$key" "$saved"
            rm -f -- "$outcome" || die 'could not reset stale create-outcome evidence'
            pr_json=$($GH_BODY_SH "${create_args[@]}") || create_rc=$?
            if ((create_rc != 0)); then
                if jq -e '.number | type=="number" and .>0' <<<"$pr_json" >/dev/null 2>&1; then
                    pr_number=$(jq -r '.number' <<<"$pr_json")
                    local failure_kind=verification
                    if jq -e '.closing_issue.state == "failed"' <<<"$pr_json" >/dev/null 2>&1; then
                        failure_kind=closing-link
                    fi
                    saved=$(jq -c --argjson pr "$pr_number" --arg kind "$failure_kind" \
                        '. + {pr:$pr,identity_source:"create",create_delivery:"created",
                              create_failure:true,create_failure_kind:$kind}' <<<"$saved")
                    state_set_json "$key" "$saved"
                    if [[ $failure_kind == closing-link ]]; then
                        die "PR #$pr_number was created but closing-link verification failed; return to PR-open handling"
                    fi
                    die "PR #$pr_number was created but create verification failed (rc=$create_rc); return to PR-open handling"
                else
                    if jq -e '.schemaVersion == 1 and .mutation == "not-attempted"' \
                        "$outcome" >/dev/null 2>&1; then
                        saved=$(jq -c '.create_delivery = "not-attempted"' <<<"$saved")
                        state_set_json "$key" "$saved"
                        die 'PR creation was not attempted; fix the reported local refusal and re-run this stage'
                    fi
                    source=recover
                    pr_json=$(recover_created_pr "$body" "$base" "$head_sha" "$preexisting")
                fi
            fi
        fi
        pr_number=$(jq -er '.number | select(type=="number" and .>0 and floor==.)' <<<"$pr_json") ||
            die 'PR creation/recovery returned no positive PR number'
        saved=$(jq -c --argjson pr "$pr_number" --arg source "$source" \
            '. + {pr:$pr,identity_source:$source,create_delivery:"created"}' <<<"$saved")
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
    IFS=$'\x1f' read -r PROVIDER MODEL EFFORT MODE HEAD_REF payload substituted < <(
        jq -er 'select((.canonical // false) != true or
                       (.payload | type=="string" and length>0)) |
            [.provider,.model,.effort,.mode,.head,(.payload // ""),(.modelSubstitutedFrom // "")] |
            select((.[0:5] | all(.[]; type=="string" and length>0)) and
                   (.[5:7] | all(.[]; type=="string")) and
                   all(.[]; contains("\u001f") | not)) | join("\u001f")' "$attempt") ||
        die 'review attempt evidence is incomplete; return to the review phase'
    REVIEW_PAYLOAD=$payload
    MODEL_SUBSTITUTED_FROM=$substituted
}

finalize_stage() {
    require_common
    [[ $PR =~ $UINT_RE ]] || die_usage 'finalize requires a positive --pr'
    [[ -z $EXPECT_CLOSING_ISSUE ]] || die_usage '--expect-closing-issue is valid only for open'
    [[ -z $DEFAULT_BRANCH ]] || die_usage '--default-branch is valid only for open'
    [[ -n $AGENT_IDENTITY ]] || die_usage 'finalize requires --agent-identity'
    if [[ -n $RUN_ID ]]; then
        [[ -n $RUN_REPO_ROOT ]] || die_usage 'finalize with --run-id requires --run-repo-root'
        local binding
        binding=$(state_get binding) || die 'bound run identity is unavailable; restore the #907 run binding before finalization'
        jq -e --arg run_id "$RUN_ID" --arg root "$RUN_REPO_ROOT" '
            .run_id == $run_id and .repository_root == $root
            and (.activation_session | type == "string" and length > 0)
            and (.decision_ledger | type == "string" and length > 0)
            and (.worker_ledger | type == "string" and length > 0)' <<<"$binding" >/dev/null ||
            die 'bound run identity does not match --run-id/--run-repo-root; refusing a second run record'
    else
        [[ -z $RUN_REPO_ROOT ]] || die_usage '--run-repo-root requires --run-id'
    fi
    [[ -x $GH_PR_STATE_SH && -x $POST_RECEIPT_SH ]] || die 'finalize-stage helpers are unavailable'
    [[ -z $SKIP_RATIONALE && -z $ORACLE || -n $SKIP_RATIONALE && -n $ORACLE ]] ||
        die_usage '--skip-rationale and --oracle must be provided together'

    local run_dir state_dir comments digest findings accepted p1 p2 receipt collection publish_rc=0 harness=''
    local final_head findings_sha accepted_sha input key=pr_stage.pr_$PR.finalize saved='' get_rc=11
    run_dir=$($RUN_DIR_SH --pr "$PR" --repo-root "$REPO_ROOT") || die 'could not resolve PR run directory'
    state_dir=$run_dir/state
    mkdir -p -- "$state_dir"
    comments=$state_dir/pr_${PR}_issue_comments.json
    digest=$state_dir/pr_${PR}_final.digest
    findings=$run_dir/findings.ndjson
    accepted=$run_dir/accepted-findings.ndjson
    [[ -f $findings && ! -L $findings && -O $findings && -r $findings ]] ||
        die 'findings evidence is unavailable; return to the review phase'
    [[ -f $accepted && ! -L $accepted && -O $accepted && -r $accepted ]] ||
        die 'accepted findings evidence is unavailable; return to classification'

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
    final_head=$(git -C "$REPO_ROOT" rev-parse --verify HEAD 2>/dev/null) ||
        die 'could not resolve the intended checkout HEAD'
    findings_sha=$(sha256sum -- "$findings" | cut -d ' ' -f 1)
    accepted_sha=$(sha256sum -- "$accepted" | cut -d ' ' -f 1)
    p1=$(jq -s '[.[] | select(.severity=="P1")] | length' "$findings") || die 'could not count P1 findings'
    p2=$(jq -s '[.[] | select(.severity=="P2")] | length' "$findings") || die 'could not count P2 findings'
    input=$(jq -nc --arg repo "$REPO" --argjson pr "$PR" --arg final_head "$final_head" \
        --arg reviewed_head "$HEAD_REF" --arg review_payload "$REVIEW_PAYLOAD" \
        --arg provider "$PROVIDER" --arg model "$MODEL" --arg effort "$EFFORT" --arg mode "$MODE" \
        --arg mode_reason "$MODE_REASON" --arg substituted "$MODEL_SUBSTITUTED_FROM" \
        --arg skip "$SKIP_RATIONALE" --arg oracle "$ORACLE" --arg agent "$AGENT_IDENTITY" \
        --arg harness "$harness" --arg findings_sha "$findings_sha" --arg accepted_sha "$accepted_sha" \
        --argjson p1 "$p1" --argjson p2 "$p2" \
        '{repo:$repo,pr:$pr,final_head:$final_head,reviewed_head:$reviewed_head,
          review_payload:$review_payload,provider:$provider,model:$model,effort:$effort,mode:$mode,
          mode_reason:$mode_reason,model_substituted_from:$substituted,skip_rationale:$skip,
          oracle:$oracle,agent_identity:$agent,harness:$harness,findings_sha256:$findings_sha,
          accepted_findings_sha256:$accepted_sha,p1:$p1,p2:$p2}')

    if [[ -n $RUN_ID ]]; then get_rc=0; saved=$(state_get "$key") || get_rc=$?; fi
    if ((get_rc == 0)) && jq -e --argjson input "$input" \
        '.complete == true and .input == $input' <<<"$saved" >/dev/null 2>&1; then
        receipt=$(jq -r '.receipt' <<<"$saved")
        printf 'stage=finalize pr=%s receipt=%s completed=digest,publish,classify,summary outstanding=none\n' "$PR" "$receipt"
        return 0
    fi
    ((get_rc == 0 || get_rc == 11)) || die 'finalize-stage run state is unavailable'

    local -a acceptance_args=()
    if [[ -f $REPO_ROOT/.agent/acceptance.txt && ! -L $REPO_ROOT/.agent/acceptance.txt ]]; then
        local acceptance_command
        while IFS= read -r acceptance_command || [[ -n $acceptance_command ]]; do
            [[ -z $acceptance_command ]] || acceptance_args+=(--acceptance-command "$acceptance_command")
        done <"$REPO_ROOT/.agent/acceptance.txt"
    fi
    (cd -- "$REPO_ROOT" && "$GH_PR_STATE_SH" --pr "$PR" --repo "$REPO" --repo-root "$REPO_ROOT" \
        --full --no-cache --tmpdir "$state_dir" --digest-out "$digest" "${acceptance_args[@]}" >/dev/null) ||
        die "stage=finalize pr=$PR completed=none outstanding=digest,publish,classify,summary failure=fresh-pr-evidence"
    local -a publish_args=(publish --pr "$PR" --repo "$REPO" --issue-comments "$comments"
        --pr-state-digest "$digest" --provider "$PROVIDER" --model "$MODEL" --effort "$EFFORT"
        --mode "$MODE" --p1 "$p1" --p2 "$p2" --agent-identity "$AGENT_IDENTITY" --require-pushed)
    [[ -z $MODE_REASON ]] || publish_args+=(--mode-reason "$MODE_REASON")
    [[ -z $MODEL_SUBSTITUTED_FROM ]] || publish_args+=(--model-substituted-from "$MODEL_SUBSTITUTED_FROM")
    [[ -z $HEAD_REF ]] || publish_args+=(--head-sha "$HEAD_REF")
    [[ -z $REVIEW_PAYLOAD ]] || publish_args+=(--diff-payload "$REVIEW_PAYLOAD")
    [[ -z $harness ]] || publish_args+=(--harness "$harness")
    [[ -z $SKIP_RATIONALE ]] || publish_args+=(--skip-rationale "$SKIP_RATIONALE" --oracle "$ORACLE")
    (cd -- "$REPO_ROOT" && RUN_DIR=$run_dir "$POST_RECEIPT_SH" "${publish_args[@]}") || publish_rc=$?
    case $publish_rc in
        0|11) ;;
        12) die "stage=finalize pr=$PR completed=digest outstanding=publish,classify,summary failure=fixes-not-pushed" ;;
        13) die "stage=finalize pr=$PR completed=digest outstanding=publish,classify,summary failure=finding-order" ;;
        *) die "stage=finalize pr=$PR completed=digest outstanding=publish,classify,summary failure=publication-uncertain" ;;
    esac
    receipt=$(cd -- "$REPO_ROOT" && "$POST_RECEIPT_SH" status --issue-comments "$comments") ||
        die "stage=finalize pr=$PR completed=digest,publish outstanding=classify,summary failure=receipt-classification"
    case $receipt in
        receipt=adversarial) receipt=adversarial; collection=receipt_prs ;;
        receipt=verified-skip) receipt=verified-skip; collection=skipped_prs ;;
        *) die "unexpected receipt classification: $receipt" ;;
    esac
    jq -e --arg final "$final_head" --arg reviewed "$HEAD_REF" --arg payload "$REVIEW_PAYLOAD" '
        [.[] | .body? | select(type == "string")
         | select(contains("<!-- adversarial-review:spent -->"))
         | select(contains("- Final verified head: " + $final))
         | select($reviewed == "" or contains("- Reviewed head: " + $reviewed))
         | select($payload == "" or contains("- Diff payload: " + $payload))] | length > 0' \
        "$comments" >/dev/null ||
        die "stage=finalize pr=$PR completed=digest,publish,classify outstanding=summary failure=receipt-input-mismatch"
    if [[ -n $RUN_ID ]]; then
        "$RUN_STATE_SH" record-summary --run-id "$RUN_ID" --repo-root "$RUN_REPO_ROOT" \
            --path "$collection" --json "$PR" ||
            die "stage=finalize pr=$PR receipt=$receipt completed=digest,publish,classify outstanding=summary failure=summary-recording"
        saved=$(jq -nc --arg receipt "$receipt" --argjson input "$input" \
            '{complete:true,receipt:$receipt,input:$input}')
        state_set_json "$key" "$saved"
    fi
    printf 'stage=finalize pr=%s receipt=%s completed=digest,publish,classify,summary outstanding=none\n' "$PR" "$receipt"
}

parse_args "$@"
case $ACTION in open) open_stage ;; finalize) finalize_stage ;; esac
