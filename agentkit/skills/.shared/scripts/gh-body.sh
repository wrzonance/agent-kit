#!/usr/bin/env bash
# gh-body.sh — create or edit a GitHub PR/issue from a file-backed body,
# then prove GitHub stored the exact bytes that were authored.

set -euo pipefail

readonly PROGNAME=${0##*/}
readonly UINT_RE='^[1-9][0-9]*$'
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
readonly FRONT_BANNER='This was written agentically; verify its assertions:'
readonly ATTRIBUTION_RE='^🤖 Co-authored by .+\.( (Closes|Fixes|Resolves) #[1-9][0-9]*)?$'
readonly SIGNATURE_RE='^🤖 Co-authored by .+\.$'
readonly CLOSING_RE='^(Closes|Fixes|Resolves) #[1-9][0-9]*$'

GH_BIN=${GH_BODY_GH:-gh}
RESOURCE=''
ACTION=''
BODY_FILE=''
TARGET=''
TARGET_NUMBER=''
REPO=''
GH_ARGS=()
WORK_DIR=''
VERIFY_ENDPOINT=''
VERIFY_HOST=''
MUTATION_COMPLETED=0
EXPECT_CLOSING_ISSUE=''

usage() {
    cat <<EOF
Usage: $PROGNAME pr|issue create|edit [NUMBER|URL] --body-file FILE [gh options...]

Runs gh's file-backed create/edit command, re-fetches the resulting PR or issue,
and compares its stored body byte-for-byte with FILE. --expect-closing-issue N
also proves that GitHub registered the closing issue reference.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

require_value() {
    [[ -n ${2-} ]] || die "$1 requires a value"
}

parse_args() {
    if (($# == 1)) && [[ $1 == -h || $1 == --help ]]; then
        usage
        exit 0
    fi
    (($# >= 2)) || { usage >&2; exit 1; }
    RESOURCE=$1
    ACTION=$2
    shift 2

    case "$RESOURCE:$ACTION" in
        pr:create|pr:edit|issue:create|issue:edit) ;;
        *) die 'expected pr|issue followed by create|edit' ;;
    esac

    if [[ $ACTION == edit ]]; then
        [[ -n ${1-} && ${1-} != -* ]] ||
            die 'edit requires a numeric target or canonical GitHub URL before gh options'
        TARGET=$1
    fi

    while (($#)); do
        case $1 in
            --body-file)
                require_value "$1" "${2-}"
                BODY_FILE=$2
                GH_ARGS+=("$1" "$2")
                shift 2
                ;;
            --body-file=*)
                BODY_FILE=${1#*=}
                GH_ARGS+=("$1")
                shift
                ;;
            --body|-b|--body=*|-b?*)
                die 'inline body options are not allowed; use --body-file FILE'
                ;;
            --repo)
                require_value "$1" "${2-}"
                REPO=$2
                GH_ARGS+=("$1" "$2")
                shift 2
                ;;
            --repo=*)
                REPO=${1#*=}
                GH_ARGS+=("$1")
                shift
                ;;
            --expect-closing-issue)
                require_value "$1" "${2-}"
                EXPECT_CLOSING_ISSUE=$2
                shift 2
                ;;
            --expect-closing-issue=*)
                EXPECT_CLOSING_ISSUE=${1#*=}
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                GH_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

validate_body() {
    [[ -n $BODY_FILE ]] || die '--body-file is required'
    [[ -f $BODY_FILE && ! -L $BODY_FILE && -r $BODY_FILE && -O $BODY_FILE ]] ||
        die "--body-file must be an owned readable regular file: $BODY_FILE"
    [[ -s $BODY_FILE ]] || die "body file is empty: $BODY_FILE"
    LC_ALL=C grep -qE '[^[:space:]]' "$BODY_FILE" ||
        die "body file is whitespace-only: $BODY_FILE"

    local first_line
    IFS= read -r first_line <"$BODY_FILE" || true
    [[ $first_line == "$FRONT_BANNER" ]] ||
        die 'body must start with the front banner: This was written agentically; verify its assertions:'
    validate_footer

    [[ -z $REPO || $REPO =~ $SLUG_RE ]] ||
        die "--repo must look like OWNER/REPO, got: $REPO"
    [[ -z $EXPECT_CLOSING_ISSUE || $EXPECT_CLOSING_ISSUE =~ $UINT_RE ]] ||
        die '--expect-closing-issue must be a positive integer'
    command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
    command -v cmp >/dev/null 2>&1 || die 'cmp not found on PATH; evidence unavailable'
    command -v diff >/dev/null 2>&1 || die 'diff not found on PATH; evidence unavailable'
    command -v "$GH_BIN" >/dev/null 2>&1 || die "required tool not found: $GH_BIN"
}

validate_footer() {
    local last_line signature separator
    last_line=$(tail -n 1 -- "$BODY_FILE")
    if [[ $last_line =~ $CLOSING_RE ]]; then
        local -a footer_lines=()
        mapfile -t footer_lines < <(tail -n 3 -- "$BODY_FILE")
        ((${#footer_lines[@]} == 3)) ||
            die 'canonical footer must be signature, blank line, and closing keyword'
        signature=${footer_lines[0]}
        separator=${footer_lines[1]}
        [[ $signature =~ $SIGNATURE_RE && -z $separator ]] ||
            die 'canonical footer must be signature, blank line, and closing keyword'
        return 0
    fi
    [[ $last_line =~ $ATTRIBUTION_RE ]] ||
        die 'body must end with a closing attribution: 🤖 Co-authored by <agent>.'
}

cleanup() {
    local exit_status=$?
    if ((exit_status != 0)) && [[ $ACTION == create && $MUTATION_COMPLETED == 1 &&
        -s $WORK_DIR/mutation.out ]]; then
        cat "$WORK_DIR/mutation.out"
    fi
    [[ -n $WORK_DIR && -d $WORK_DIR ]] && rm -rf -- "$WORK_DIR"
}

run_mutation() {
    local rc=0
    "$GH_BIN" "$RESOURCE" "$ACTION" "${GH_ARGS[@]}" \
        >"$WORK_DIR/mutation.out" 2>"$WORK_DIR/mutation.err" || rc=$?
    if ((rc != 0)); then
        [[ ! -s $WORK_DIR/mutation.out ]] || cat "$WORK_DIR/mutation.out"
        [[ ! -s $WORK_DIR/mutation.err ]] || cat "$WORK_DIR/mutation.err" >&2
        die "gh $RESOURCE $ACTION failed (rc=$rc); body was not verified"
    fi
    MUTATION_COMPLETED=1
}

endpoint_from_url() {
    local line
    while IFS= read -r line; do
        if [[ $line =~ ^https://([A-Za-z0-9.:-]+)/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/(pull|issues)/([1-9][0-9]*)/?$ ]]; then
            [[ ${BASH_REMATCH[4]} == pull && $RESOURCE == pr ||
                ${BASH_REMATCH[4]} == issues && $RESOURCE == issue ]] ||
                die "gh returned a URL for the wrong resource type: $line"
            VERIFY_HOST=${BASH_REMATCH[1]}
            VERIFY_ENDPOINT="repos/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
            if [[ ${BASH_REMATCH[4]} == pull ]]; then
                VERIFY_ENDPOINT+="/pulls/${BASH_REMATCH[5]}"
            else
                VERIFY_ENDPOINT+="/issues/${BASH_REMATCH[5]}"
            fi
            return 0
        fi
    done <"$WORK_DIR/mutation.out"
    die "gh $RESOURCE create did not return a usable GitHub URL; body was not verified"
}

endpoint_from_target() {
    local repo_path
    if [[ $TARGET =~ $UINT_RE ]]; then
        TARGET_NUMBER=$TARGET
        repo_path=${REPO:-'{owner}/{repo}'}
        VERIFY_ENDPOINT="repos/$repo_path"
        if [[ $RESOURCE == pr ]]; then
            VERIFY_ENDPOINT+="/pulls/$TARGET"
        else
            VERIFY_ENDPOINT+="/issues/$TARGET"
        fi
        return 0
    fi
    if [[ $TARGET =~ ^https://([A-Za-z0-9.:-]+)/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/(pull|issues)/([1-9][0-9]*)/?$ ]]; then
        [[ ${BASH_REMATCH[4]} == pull && $RESOURCE == pr ||
            ${BASH_REMATCH[4]} == issues && $RESOURCE == issue ]] ||
            die "edit target is for the wrong resource type: $TARGET"
        TARGET_NUMBER=${BASH_REMATCH[5]}
        VERIFY_HOST=${BASH_REMATCH[1]}
        VERIFY_ENDPOINT="repos/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
        if [[ ${BASH_REMATCH[4]} == pull ]]; then
            VERIFY_ENDPOINT+="/pulls/${BASH_REMATCH[5]}"
        else
            VERIFY_ENDPOINT+="/issues/${BASH_REMATCH[5]}"
        fi
        return 0
    fi
    die "edit target must be a positive number or canonical GitHub URL: $TARGET"
}

fetch_stored_body() {
    local rc=0
    # Verify against the host the mutation actually landed on. Without this,
    # gh api falls back to the ambient host (repo context, GH_HOST, else
    # github.com), so an Enterprise URL would be checked against the wrong
    # server. A numeric edit target carries no host and keeps that ambient
    # resolution, which is what gh itself used for the mutation.
    # The endpoint is appended last so the array is never empty: expanding an
    # empty array under nounset is unsafe on Bash 4.2.
    local -a api_args=()
    [[ -z $VERIFY_HOST ]] || api_args+=(--hostname "$VERIFY_HOST")
    api_args+=("$VERIFY_ENDPOINT")
    "$GH_BIN" api "${api_args[@]}" \
        >"$WORK_DIR/stored.json" 2>"$WORK_DIR/verify.err" || rc=$?
    if ((rc != 0)); then
        [[ ! -s $WORK_DIR/verify.err ]] || cat "$WORK_DIR/verify.err" >&2
        die 'GitHub body re-fetch failed; stored body is unverified'
    fi
    jq -e 'has("body") and (.body | type == "string")' \
        "$WORK_DIR/stored.json" >/dev/null ||
        die 'GitHub response has no usable string body; stored body is unverified'
    jq -j '.body' "$WORK_DIR/stored.json" >"$WORK_DIR/stored.body" ||
        die 'could not decode the stored body; stored body is unverified'
}

compare_body() {
    if cmp -s "$BODY_FILE" "$WORK_DIR/stored.body"; then
        return 0
    fi
    printf '%s: stored body does not match the intended body; mutation is unverified.\n' \
        "$PROGNAME" >&2
    diff -u --label intended --label stored \
        "$BODY_FILE" "$WORK_DIR/stored.body" 2>&1 |
        head -n 40 >&2 || true
    return 1
}

verify_closing_reference() {
    [[ -z $EXPECT_CLOSING_ISSUE ]] && return 0
    jq -e --arg expected "$EXPECT_CLOSING_ISSUE" '
        (.closingIssuesReferences // []) as $references
        | (if ($references | type) == "array" then $references
           else ($references.nodes // []) end)
        | any(.[]?; ((.number // "") | tostring) == $expected)
    ' "$WORK_DIR/stored.json" >/dev/null ||
        die "GitHub response closingIssuesReferences does not contain #$EXPECT_CLOSING_ISSUE"
}

main() {
    parse_args "$@"
    validate_body
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gh-body.XXXXXX")
    trap cleanup EXIT
    run_mutation

    if [[ $ACTION == create ]]; then
        endpoint_from_url
    else
        endpoint_from_target
    fi
    fetch_stored_body
    compare_body || exit 1
    verify_closing_reference

    if [[ $ACTION == create ]]; then
        cat "$WORK_DIR/mutation.out"
    else
        printf 'updated %s #%s verified=exact\n' "$RESOURCE" "$TARGET_NUMBER"
    fi
}

main "$@"
