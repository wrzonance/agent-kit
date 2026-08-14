#!/usr/bin/env bash
# Safely reply to a review thread and resolve it after an exact verified post.
set -euo pipefail

readonly PROGNAME=${0##*/}
readonly UINT_RE='^[1-9][0-9]*$'
readonly SHA_RE='^[0-9a-fA-F]{7,64}$'
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
readonly AGENT_MARKER_RE='(^|\r?\n)<!-- review-remote-pr:agent-'

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
GH_BIN=${THREAD_ACTION_GH:-gh}
COMMENT_HELPER=${THREAD_ACTION_COMMENT:-$SCRIPT_DIR/gh-comment.sh}

PR=''
REPO=''
THREADS_ARTIFACT=''
THREAD_ID=''
COMMENT_ID=''
KIND=''
TEXT=''
SHA=''
AGENT_IDENTITY=${THREAD_ACTION_AGENT_IDENTITY:-'Codex gpt-5.6-luna'}
ANCHOR_PATH=''
ANCHOR_LINE=''
SIDE='RIGHT'
START_LINE=''
WORK_DIR=''

usage() {
    cat <<EOF
Usage: $PROGNAME --pr N --repo OWNER/REPO --threads-artifact FILE
                 (--thread-id ID | --comment-id N)
                 --kind fixed|declined --text TEXT --sha SHA
                 [--agent-identity ID] [--anchor PATH:LINE]
                 [--side RIGHT|LEFT] [--start-line N]

Re-derives the target human lane from FILE, posts a verified reply, then
resolves the thread. An anchor 422 is retried as a top-level comment.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

require_value() {
    [[ -n ${2:-} ]] || die "$1 requires a value"
}

require_uint() {
    [[ $2 =~ $UINT_RE ]] || die "$1 expects a positive integer, got: $2"
}

split_anchor() {
    local spec=$1
    [[ $spec == *:* ]] || die "--anchor expects PATH:LINE, got: $spec"
    ANCHOR_PATH=${spec%:*}
    ANCHOR_LINE=${spec##*:}
    [[ -n $ANCHOR_PATH ]] || die '--anchor has an empty path'
    require_uint '--anchor line' "$ANCHOR_LINE"
}

parse_args() {
    while (($#)); do
        case $1 in
        --pr) require_value "$1" "${2:-}"; PR=$2; shift 2 ;;
        --repo) require_value "$1" "${2:-}"; REPO=$2; shift 2 ;;
        --threads-artifact|--artifact)
            require_value "$1" "${2:-}"; THREADS_ARTIFACT=$2; shift 2 ;;
        --thread-id) require_value "$1" "${2:-}"; THREAD_ID=$2; shift 2 ;;
        --comment-id) require_value "$1" "${2:-}"; COMMENT_ID=$2; shift 2 ;;
        --kind) require_value "$1" "${2:-}"; KIND=$2; shift 2 ;;
        --text) require_value "$1" "${2:-}"; TEXT=$2; shift 2 ;;
        --sha) require_value "$1" "${2:-}"; SHA=$2; shift 2 ;;
        --agent-identity) require_value "$1" "${2:-}"; AGENT_IDENTITY=$2; shift 2 ;;
        --anchor) require_value "$1" "${2:-}"; split_anchor "$2"; shift 2 ;;
        --side) require_value "$1" "${2:-}"; SIDE=$2; shift 2 ;;
        --start-line) require_value "$1" "${2:-}"; START_LINE=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; (($# == 0)) || die "unexpected argument: $1" ;;
        -*) die "unknown option: $1" ;;
        *) die "unexpected argument: $1" ;;
        esac
    done
}

validate_args() {
    require_uint '--pr' "$PR"
    [[ $REPO =~ $SLUG_RE ]] || die "--repo must look like OWNER/REPO, got: $REPO"
    [[ -n $THREAD_ID || -n $COMMENT_ID ]] ||
        die '--thread-id or --comment-id is required'
    [[ -z $COMMENT_ID ]] || require_uint '--comment-id' "$COMMENT_ID"
    [[ $KIND == fixed || $KIND == declined ]] ||
        die "--kind must be fixed or declined, got: $KIND"
    [[ $TEXT =~ [^[:space:]] ]] || die '--text must contain non-whitespace text'
    [[ $SHA =~ $SHA_RE ]] || die "--sha must be a 7-64 character hexadecimal SHA, got: $SHA"
    [[ -n $AGENT_IDENTITY && $AGENT_IDENTITY != *$'\n'* && $AGENT_IDENTITY != *$'\r'* ]] ||
        die '--agent-identity must be a single non-empty line'
    [[ $SIDE == RIGHT || $SIDE == LEFT ]] || die '--side must be RIGHT or LEFT'
    if [[ -n $START_LINE ]]; then
        require_uint '--start-line' "$START_LINE"
        [[ -n $ANCHOR_PATH ]] || die '--start-line requires --anchor'
        ((START_LINE <= ANCHOR_LINE)) ||
            die "--start-line ($START_LINE) must not exceed --anchor line ($ANCHOR_LINE)"
    fi
    [[ -f $THREADS_ARTIFACT && ! -L $THREADS_ARTIFACT && -O $THREADS_ARTIFACT ]] ||
        die "--threads-artifact must be an owned regular file, not a symlink: $THREADS_ARTIFACT"
    command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
    command -v "$GH_BIN" >/dev/null 2>&1 || die "required tool not found: $GH_BIN"
    [[ -x $COMMENT_HELPER ]] || die "gh-comment.sh is not executable: $COMMENT_HELPER"
}

cleanup() {
    [[ -n $WORK_DIR && -d $WORK_DIR ]] && rm -rf -- "$WORK_DIR"
}

read_target() {
    local schema count human_count original_author
    schema=$(jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array"' \
        "$THREADS_ARTIFACT" 2>/dev/null) ||
        die 'threads artifact has no usable reviewThreads.nodes array'
    [[ $schema == true ]] || die 'threads artifact has no usable reviewThreads.nodes array'
    count=$(jq -r --arg thread "$THREAD_ID" --arg comment "$COMMENT_ID" '
        [.data.repository.pullRequest.reviewThreads.nodes[]
         | select((($thread == "") or ((.id // "") | tostring == $thread)) and
                  (($comment == "") or
                   any(.comments.nodes[]?; ((.databaseId // "") | tostring) == $comment)))]
        | length' "$THREADS_ARTIFACT") || die 'could not inspect threads artifact'
    [[ $count == 1 ]] || {
        if [[ -n $THREAD_ID && -n $COMMENT_ID ]]; then
            die 'thread-id does not match comment-id in one artifact thread'
        fi
        die 'selector does not identify exactly one artifact thread'
    }
    jq -c --arg thread "$THREAD_ID" --arg comment "$COMMENT_ID" '
        [.data.repository.pullRequest.reviewThreads.nodes[]
         | select((($thread == "") or ((.id // "") | tostring == $thread)) and
                  (($comment == "") or
                   any(.comments.nodes[]?; ((.databaseId // "") | tostring) == $comment)))]
        | .[0]' "$THREADS_ARTIFACT" >"$WORK_DIR/target.json" ||
        die 'could not read selected artifact thread'
    TARGET_THREAD_ID=$(jq -r '.id // empty' "$WORK_DIR/target.json")
    [[ -n $TARGET_THREAD_ID ]] || die 'selected artifact thread has no node ID'
    [[ $(jq -r 'if (.isResolved // false) then "resolved" else "open" end' \
        "$WORK_DIR/target.json") == open ]] || die 'target thread is already resolved'
    original_author=$(jq -r '(.comments.nodes[0].author.login // "") | ascii_downcase' \
        "$WORK_DIR/target.json") || die 'could not identify the original thread author'
    if [[ $original_author == github-code-quality ||
        $original_author == 'github-code-quality[bot]' ]]; then
        die 'target thread is an original github-code-quality[bot] finding; it must auto-clear or be dismissed with a reason'
    fi
    human_count=$(jq -r --arg re "$AGENT_MARKER_RE" '
        [.comments.nodes[]? | select(
          (
            (((.author.login // "") | ascii_downcase) == "coderabbitai" or
             ((.author.login // "") | ascii_downcase) == "coderabbitai[bot]" or
             ((.author.login // "") | ascii_downcase) == "github-code-quality" or
             ((.author.login // "") | ascii_downcase) == "github-code-quality[bot]") | not
          ) and (
            (((.author.type // "") == "Bot") or
             ((.author.__typename // "") == "Bot") or
             (((.author.login // "") | ascii_downcase) | test("\\[bot\\]$"))) | not
          ) and (
            (((.body // "") | test($re)) | not)
          )
        )] | length' "$WORK_DIR/target.json") ||
        die 'could not classify target thread human lane'
    ((human_count == 0)) || die 'target thread is human-touched; refusing to resolve'
    if [[ -z $COMMENT_ID && -z $ANCHOR_PATH ]]; then
        COMMENT_ID=$(jq -r '.comments.nodes[0].databaseId // empty' "$WORK_DIR/target.json")
        require_uint 'derived comment ID' "$COMMENT_ID"
    fi
}

build_body() {
    # shellcheck disable=SC2016  # Markdown backticks are literal body bytes.
    {
        printf '%s\n' 'This was written agentically; verify its assertions:'
        printf '%s\n' '<!-- review-remote-pr:agent-reply -->'
        if [[ $KIND == fixed ]]; then
            printf 'Fixed in commit `%s`. %s\n' "$SHA" "$TEXT"
        else
            printf 'Declining — %s (commit `%s`).\n' "$TEXT" "$SHA"
        fi
        printf '🤖 Co-authored by %s.\n' "$AGENT_IDENTITY"
    } >"$WORK_DIR/body.md"
}

post_comment() {
    local -a args=(--pr "$PR" --repo "$REPO" --body-file "$WORK_DIR/body.md")
    local post_rc=0
    if [[ -n $COMMENT_ID ]]; then
        args+=(--reply-to "$COMMENT_ID")
    elif [[ -n $ANCHOR_PATH ]]; then
        args+=(--anchor "$ANCHOR_PATH:$ANCHOR_LINE" --side "$SIDE")
        [[ -n $START_LINE ]] && args+=(--start-line "$START_LINE")
    fi
    POST_OUTPUT=$(bash "$COMMENT_HELPER" "${args[@]}" 2>"$WORK_DIR/comment.err") || post_rc=$?
    if ((post_rc != 0)) && [[ -n $ANCHOR_PATH ]] && \
        grep -Eq '(^|[^[:digit:]])422([^[:digit:]]|$)' "$WORK_DIR/comment.err"; then
        # Anchor failures are a routine API outcome. Retry once as the
        # documented top-level fallback, preserving the exact body.
        post_rc=0
        POST_OUTPUT=$(bash "$COMMENT_HELPER" --pr "$PR" --repo "$REPO" \
            --body-file "$WORK_DIR/body.md" 2>"$WORK_DIR/comment-fallback.err") || post_rc=$?
    fi
    ((post_rc == 0)) || {
        [[ -s $WORK_DIR/comment.err ]] && sed -n '1,10p' "$WORK_DIR/comment.err" >&2
        [[ -s $WORK_DIR/comment-fallback.err ]] && sed -n '1,10p' "$WORK_DIR/comment-fallback.err" >&2
        die 'gh-comment.sh did not verify the reply; thread was not resolved'
    }
    [[ $POST_OUTPUT == *'verified=exact'* ]] ||
        die 'gh-comment.sh returned no verified=exact result; thread was not resolved'
}

resolve_thread() {
    local query response rc=0
    # shellcheck disable=SC2016  # GraphQL variables are bound by -F below.
    query='mutation($threadId:ID!){resolveReviewThread(input:{threadId:$threadId}){thread{isResolved}}}'
    response=$("$GH_BIN" api graphql -F "threadId=$TARGET_THREAD_ID" -f "query=$query" \
        2>"$WORK_DIR/resolve.err") || rc=$?
    ((rc == 0)) || {
        [[ -s $WORK_DIR/resolve.err ]] && sed -n '1,10p' "$WORK_DIR/resolve.err" >&2
        die 'resolveReviewThread failed; the verified reply remains posted'
    }
    jq -e '.data.resolveReviewThread.thread.isResolved == true' <<<"$response" >/dev/null ||
        die 'resolveReviewThread did not prove isResolved=true'
}

main() {
    parse_args "$@"
    validate_args
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/thread-action.XXXXXX") || die 'could not create work directory'
    chmod 700 -- "$WORK_DIR"
    trap cleanup EXIT
    read_target
    build_body
    post_comment
    resolve_thread
    printf '%s\n' "$POST_OUTPUT"
    printf 'resolved thread=%s\n' "$TARGET_THREAD_ID"
}

main "$@"
