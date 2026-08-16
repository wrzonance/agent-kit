#!/usr/bin/env bash
# adversarial-run.sh — one blocking, consent-gated adversarial review launch.
# The provider helpers own isolation and model-specific stream validation. This
# wrapper owns diff construction, provider selection, consent, one launch, and
# the neutral receipt metadata line.
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/private-dir.sh"

PR=''
REPO=''
RUN_DIR=''
PEER_CLI_ABSENT=0
BASE_REF=''
PROVIDER=''
MODEL=''
EFFORT=''
MODE=''
HELPER=''
TRANSCRIPT_NAME=''

usage() {
    cat <<EOF
Usage: $PROGNAME --pr N --repo OWNER/REPO --run-dir DIR [--peer-cli-absent]

Builds DIR/adversarial.diff, runs exactly one consent-gated blind reviewer, and
publishes DIR/adversarial.result.json. On success stdout is one receipt-shaped
line containing provider, model, effort, mode, P1, and P2.

The consent record is always DIR/state/cross-provider-consent. There is no
caller-supplied consent flag.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit 1
}

die_usage() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    printf 'run "%s --help" for usage\n' "$PROGNAME" >&2
    exit 2
}

require_value() {
    [[ -n ${2:-} ]] || die_usage "$1 requires a value"
}

parse_args() {
    while (($#)); do
        case $1 in
            --pr) require_value "$1" "${2:-}"; PR=$2; shift 2 ;;
            --pr=*) PR=${1#*=}; shift ;;
            --repo) require_value "$1" "${2:-}"; REPO=$2; shift 2 ;;
            --repo=*) REPO=${1#*=}; shift ;;
            --run-dir) require_value "$1" "${2:-}"; RUN_DIR=$2; shift 2 ;;
            --run-dir=*) RUN_DIR=${1#*=}; shift ;;
            --peer-cli-absent) PEER_CLI_ABSENT=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown option: $1" ;;
        esac
    done
}

validate_args() {
    [[ $PR =~ ^[1-9][0-9]*$ ]] || die_usage '--pr must be a positive integer'
    [[ $REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
        die_usage '--repo must look like OWNER/REPO'
    [[ -n $RUN_DIR ]] || die_usage '--run-dir is required'
    command -v gh >/dev/null 2>&1 || die 'gh is required to resolve the pull request base'
    command -v jq >/dev/null 2>&1 || die 'jq is required to validate the review result'

    if ((PEER_CLI_ABSENT)); then
        PROVIDER=openai
        MODEL=gpt-5.6-terra
        EFFORT=xhigh
        MODE=blind-fallback
        HELPER=$SCRIPT_DIR/codex-adversarial-review.sh
        TRANSCRIPT_NAME=codex.jsonl
    else
        PROVIDER=anthropic
        MODEL=claude-opus-5
        EFFORT=high
        MODE=cross-provider
        HELPER=$SCRIPT_DIR/claude-adversarial-review.sh
        TRANSCRIPT_NAME=claude.ndjson
    fi
    [[ -x $HELPER ]] || die "review helper is missing or not executable: $HELPER"
}

prepare_owned_artifact() {
    local path=$1
    [[ ! -L $path ]] || die "refusing to use an artifact symlink: $path"
    if [[ -e $path ]]; then
        [[ -f $path && -O $path ]] || die "refusing to replace an artifact not owned by this user: $path"
        rm -f -- "$path" || die "could not clear stale artifact: $path"
    fi
    local tmp="$path.tmp"
    [[ ! -L $tmp ]] || die "refusing to use an artifact temp symlink: $tmp"
    if [[ -e $tmp ]]; then
        [[ -f $tmp && -O $tmp ]] || die "refusing to replace an artifact temp not owned by this user: $tmp"
        rm -f -- "$tmp" || die "could not clear stale artifact temp: $tmp"
    fi
}

resolve_base() {
    local head_oid current_oid
    BASE_REF=$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq .baseRefName 2>/dev/null) ||
        die "could not resolve the base branch for $REPO#$PR"
    [[ -n $BASE_REF ]] || die 'the pull request base branch is empty'
    git check-ref-format --branch "$BASE_REF" >/dev/null 2>&1 ||
        die "the pull request base branch is invalid: $BASE_REF"
    head_oid=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null) ||
        die "could not resolve the pull request head for $REPO#$PR"
    [[ $head_oid =~ ^[[:xdigit:]]{40}$ ]] ||
        die "the pull request head OID is invalid: $head_oid"
    current_oid=$(git rev-parse HEAD 2>/dev/null) || die 'could not resolve the checkout HEAD'
    [[ $current_oid == "$head_oid" ]] ||
        die "checkout HEAD $current_oid does not match PR head $head_oid"
}

build_diff() {
    local diff_path=$RUN_DIR/adversarial.diff tmp="$RUN_DIR/adversarial.diff.tmp"
    prepare_owned_artifact "$diff_path"
    [[ ! -L $tmp ]] || die "refusing to use an adversarial diff temp symlink: $tmp"
    git fetch --quiet origin "$BASE_REF" || die "could not fetch origin/$BASE_REF"
    git --no-pager diff --find-renames --unified=25 "origin/$BASE_REF...HEAD" >"$tmp" ||
        die 'could not build the adversarial diff'
    chmod 600 -- "$tmp" || die "could not secure the adversarial diff: $tmp"
    mv -f -- "$tmp" "$diff_path" || die "could not publish the adversarial diff: $diff_path"
    [[ -s $diff_path ]] || die 'the adversarial diff is empty; review is blocked'
    grep -q '[^[:space:]]' -- "$diff_path" || die 'the adversarial diff is empty; review is blocked'
}

verify_consent() {
    local consent_script=$SCRIPT_DIR/consent-record.sh
    local payload state=$RUN_DIR/state/cross-provider-consent
    [[ -x $consent_script ]] || die "consent record helper is missing: $consent_script"
    payload=$(
        "$consent_script" payload --repo "$REPO" --pr "$PR" --diff "$RUN_DIR/adversarial.diff"
    ) || die 'cannot derive the exact consent payload; refusing to launch review'
    "$consent_script" check --state "$state" --provider "$PROVIDER" --payload "$payload" \
        >/dev/null 2>&1 || die 'valid consent-record.sh check is required; refusing to launch review'
}

write_blocked_result() {
    local reason=$1 detail=$2 path=$RUN_DIR/adversarial.result.json tmp="$RUN_DIR/adversarial.result.json.tmp"
    prepare_owned_artifact "$path"
    jq -cn --arg reason "$reason" --arg detail "$detail" --arg provider "$PROVIDER" \
        --arg model "$MODEL" --arg effort "$EFFORT" --arg mode "$MODE" \
        '{status:"blocked", blockedReason:$reason, detail:$detail, provider:$provider,
          requestedModel:$model, effort:$effort, mode:$mode}' >"$tmp" ||
        die 'could not encode the blocked result'
    chmod 600 -- "$tmp" || die "could not secure the blocked result: $tmp"
    mv -f -- "$tmp" "$path" || die "could not publish the blocked result: $path"
}

valid_completed_result() {
    local path=$1
    [[ -f $path && ! -L $path && -O $path ]] || return 1
    jq -e '
      type == "object" and .status == "completed" and
      (.exitCode | type) == "number" and .exitCode == 0 and
      (.requestedModel | type) == "string" and (.transcript | type) == "string" and
      (.verdict | type) == "object" and
      ((.verdict | keys) - ["verdict", "findings"] | length) == 0 and
      (.verdict.verdict == "findings" or .verdict.verdict == "no_findings") and
      (.verdict.findings | type) == "array" and
      (if .verdict.verdict == "no_findings" then (.verdict.findings | length) == 0
       else (.verdict.findings | length) > 0 end) and
      all(.verdict.findings[];
        (type == "object") and
        ((keys - ["priority", "location", "failureScenario", "smallestFix"]) | length == 0) and
        (.priority == "P1" or .priority == "P2") and
        (.location | type) == "string" and
        (.failureScenario | type) == "string" and
        (.smallestFix | type) == "string")
    ' <"$path" >/dev/null 2>&1
}

# A blocked run produced no review, so it carries no verdict. Accepting an
# object here let a provider return status="blocked" alongside a findings-shaped
# verdict, which receipt_line then reported as verdict=findings with P1/P2 counts
# -- a blocked review reading as a completed one, which is exactly the state this
# runner exists to make impossible.
valid_blocked_result() {
    local path=$1
    [[ -f $path && ! -L $path && -O $path ]] || return 1
    jq -e 'type == "object" and .status == "blocked" and
      (.blockedReason | type) == "string" and
      ((has("verdict") | not) or (.verdict | type) == "null")' \
        <"$path" >/dev/null 2>&1
}

receipt_line() {
    local path=$RUN_DIR/adversarial.result.json p1 p2 verdict
    # Status is authoritative over the verdict object: even if a blocked result
    # reaches here by some other path, it must never report findings.
    p1=$(jq -r 'if .status == "blocked" then 0 else [.verdict | objects | .findings[]? | select(.priority == "P1")] | length end' <"$path")
    p2=$(jq -r 'if .status == "blocked" then 0 else [.verdict | objects | .findings[]? | select(.priority == "P2")] | length end' <"$path")
    verdict=$(jq -r 'if .status == "blocked" then "blocked" else (.verdict | objects | .verdict) // "blocked" end' <"$path")
    printf 'provider=%s model=%s effort=%s mode=%s P1=%s P2=%s verdict=%s\n' \
        "$PROVIDER" "$MODEL" "$EFFORT" "$MODE" "$p1" "$p2" "$verdict"
}

run_provider() {
    local result=$RUN_DIR/adversarial.result.json transcript=$RUN_DIR/$TRANSCRIPT_NAME
    local stdout_path=$RUN_DIR/$PROVIDER.stdout stderr_path=$RUN_DIR/$PROVIDER.stderr rc=0
    local -a helper_args=(
        --mode review --model "$MODEL" --effort "$EFFORT" --pr "$PR" --repo "$REPO"
        --consent-state "$RUN_DIR/state/cross-provider-consent"
        --diff "$RUN_DIR/adversarial.diff" --transcript "$transcript" --output "$result"
        --max-duration-seconds 900
    )
    if [[ $PROVIDER == anthropic ]]; then
        helper_args+=(--max-budget-usd 5.00)
    else
        helper_args+=(--max-tokens 400000)
    fi
    prepare_owned_artifact "$result"
    prepare_owned_artifact "$stdout_path"
    prepare_owned_artifact "$stderr_path"
    "$HELPER" "${helper_args[@]}" >"$stdout_path" 2>"$stderr_path" || rc=$?
    cat -- "$stderr_path" >&2 || true

    if ((rc == 0)); then
        valid_completed_result "$result" || {
            write_blocked_result invalid-verdict 'provider returned an unparseable or schema-invalid verdict'
            receipt_line
            return 1
        }
        receipt_line
        return 0
    fi
    if ((rc == 3)) && valid_blocked_result "$result"; then
        receipt_line
        return 3
    fi
    write_blocked_result provider-failure "review helper exited $rc without a validated verdict"
    receipt_line
    return 1
}

main() {
    parse_args "$@"
    validate_args
    private_dir_ensure "$RUN_DIR" '--run-dir'
    private_dir_ensure "$RUN_DIR/state" '--run-dir/state'
    prepare_owned_artifact "$RUN_DIR/adversarial.result.json"
    resolve_base
    build_diff
    verify_consent
    run_provider
}

main "$@"
