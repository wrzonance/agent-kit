#!/usr/bin/env bash
#
# gh-comment.sh — post or update a GitHub pull-request comment whose body comes
# from a FILE, then prove the stored body matches the intended body byte-for-byte.
#
# Why this exists: a body interpolated into a double-quoted shell string is
# expanded by the shell before gh ever sees it. A backticked commit SHA inside
# such a body is executed as a command and silently stripped from the posted
# comment, leaving a comment that cites no commit at all. This script never puts
# the body on a command line: it reads the body from a file, encodes it with
# jq --rawfile, sends it with --input -, then re-fetches the stored comment and
# byte-compares it. Nothing downstream (resolving a thread, dismissing a finding)
# may proceed unless that comparison is exact.
#
# Exit status: 0 = posted/updated AND the stored body matches exactly.
#              1 = usage error, API error, or body mismatch (nothing resolved).
#
# Requires: bash >= 4.2, gh (authenticated), jq >= 1.6, GNU coreutils/diffutils.
#           git is required only for --anchor (to resolve commit_id).

set -euo pipefail

readonly PROGNAME=${0##*/}
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
readonly UINT_RE='^[1-9][0-9]*$'
readonly ERR_CONTEXT_LINES=10
readonly DIFF_CONTEXT_LINES=40
readonly ACCEPT_HEADER='Accept: application/vnd.github+json'

# Overridable so the script can be exercised against a local stub in tests
# without touching a forge. Mirrors CLAUDE_EXECUTABLE in the sibling script.
GH_BIN=${GH_COMMENT_GH:-gh}

PR=""
BODY_ARG=""
BODY_FILE=""
REPO=""
MODE="issue"
REPLY_TO=""
UPDATE_ID=""
ANCHOR_PATH=""
ANCHOR_LINE=""
SIDE="RIGHT"
START_LINE=""
WORK_DIR=""

usage() {
    cat <<EOF
Usage: $PROGNAME --pr N --body-file FILE [--repo OWNER/REPO]
         [--reply-to COMMENT_ID | --anchor PATH:LINE [--side RIGHT|LEFT] [--start-line N] | --update COMMENT_ID]

Posts a PR comment from a file and verifies the stored body byte-for-byte.
The body is never interpolated into a shell string, so backticks, dollar signs
and newlines in the body survive intact.

Required:
  --pr N               Pull-request number (also required by --update, which
                       uses it only for context, not in its endpoint).
  --body-file FILE     File holding the exact comment body. Use - for stdin.
                       An empty or whitespace-only body is rejected.

Options:
  --repo OWNER/REPO    Target repository. Default: GH_REPO, else the repository
                       of the current git remote, else gh's own resolution of
                       the current working directory.
  -h, --help           Print this help and exit 0.

Modes (at most one; default is a top-level conversation comment):
  --reply-to ID        Reply inside the review thread of inline comment ID.
  --anchor PATH:LINE   Open a NEW review thread anchored at PATH line LINE.
                       Requires a git checkout; commit_id is HEAD.
  --side RIGHT|LEFT    Diff side for --anchor (default: RIGHT).
  --start-line N       First line of a multi-line --anchor range; start_side
                       follows --side.
  --update ID          Edit an existing conversation comment ID in place.

Output (stdout, one line):
  posted id=ID url=URL verified=exact
  updated id=ID url=URL verified=exact

Exit status:
  0  comment posted/updated and the stored body matches exactly
  1  usage error, API error, or body mismatch (a unified diff is printed)

Examples:
  $PROGNAME --pr 42 --body-file reply.md --repo OWNER/REPO
  $PROGNAME --pr 42 --body-file reply.md --reply-to 1234567890
  $PROGNAME --pr 42 --body-file note.md --anchor src/example.ts:42
  $PROGNAME --pr 42 --body-file note.md --anchor src/example.ts:48 --start-line 42
  printf 'Fixed in abc1234.\\n' | $PROGNAME --pr 42 --body-file -
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf 'run "%s --help" for usage\n' "$PROGNAME" >&2
    exit 1
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

set_mode() {
    local requested=$1
    if [[ "$MODE" != "issue" ]]; then
        usage_error "modes are mutually exclusive: --$MODE and --$requested"
    fi
    MODE=$requested
}

require_uint() {
    local flag=$1 value=$2
    [[ "$value" =~ $UINT_RE ]] ||
        usage_error "$flag expects a positive integer, got: $value"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
        --pr) PR=${2-}; shift 2 || usage_error "--pr needs a value" ;;
        --body-file) BODY_ARG=${2-}; shift 2 || usage_error "--body-file needs a value" ;;
        --repo) REPO=${2-}; shift 2 || usage_error "--repo needs a value" ;;
        --reply-to) set_mode reply-to; REPLY_TO=${2-}; shift 2 || usage_error "--reply-to needs a value" ;;
        --update) set_mode update; UPDATE_ID=${2-}; shift 2 || usage_error "--update needs a value" ;;
        --anchor) set_mode anchor; split_anchor "${2-}"; shift 2 || usage_error "--anchor needs a value" ;;
        --side) SIDE=${2-}; shift 2 || usage_error "--side needs a value" ;;
        --start-line) START_LINE=${2-}; shift 2 || usage_error "--start-line needs a value" ;;
        -h | --help) usage; exit 0 ;;
        --) shift; (($# == 0)) || usage_error "unexpected argument: $1" ;;
        -*) usage_error "unknown option: $1" ;;
        *) usage_error "unexpected argument: $1" ;;
        esac
    done
}

# PATH:LINE, split on the LAST colon so paths containing a colon still work.
split_anchor() {
    local spec=$1
    [[ -n "$spec" ]] || usage_error "--anchor needs a value"
    [[ "$spec" == *:* ]] || usage_error "--anchor expects PATH:LINE, got: $spec"
    ANCHOR_PATH=${spec%:*}
    ANCHOR_LINE=${spec##*:}
    [[ -n "$ANCHOR_PATH" ]] || usage_error "--anchor has an empty PATH: $spec"
    require_uint "--anchor line" "$ANCHOR_LINE"
}

validate_args() {
    [[ -n "$PR" ]] || usage_error "--pr is required"
    require_uint "--pr" "$PR"
    [[ -n "$BODY_ARG" ]] || usage_error "--body-file is required"
    [[ "$SIDE" == "RIGHT" || "$SIDE" == "LEFT" ]] ||
        usage_error "--side must be RIGHT or LEFT, got: $SIDE"
    if [[ "$MODE" != "anchor" ]]; then
        [[ -z "$START_LINE" ]] || usage_error "--start-line is only valid with --anchor"
    fi
    case "$MODE" in
    reply-to) require_uint "--reply-to" "$REPLY_TO" ;;
    update) require_uint "--update" "$UPDATE_ID" ;;
    anchor) validate_anchor_range ;;
    *) : ;;
    esac
    require_tools
}

validate_anchor_range() {
    [[ -z "$START_LINE" ]] && return 0
    require_uint "--start-line" "$START_LINE"
    ((START_LINE <= ANCHOR_LINE)) ||
        usage_error "--start-line ($START_LINE) must not exceed the --anchor line ($ANCHOR_LINE)"
}

require_tools() {
    local tool missing=()
    command -v jq >/dev/null 2>&1 || die "jq not found on PATH; evidence unavailable"
    for tool in "$GH_BIN" jq diff cmp; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [[ "$MODE" == "anchor" ]]; then
        command -v git >/dev/null 2>&1 || missing+=(git)
    fi
    ((${#missing[@]} == 0)) || die "required tool(s) not on PATH: ${missing[*]}"
}

slug_from_url() {
    local url=${1%/}
    url=${url%.git}
    url=${url%/}
    local repo=${url##*/}
    local rest=${url%/*}
    local owner=${rest##*[/:]}
    printf '%s/%s' "$owner" "$repo"
}

# Local git only — reads configured remote URLs, never contacts a remote.
remote_url() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    local name
    for name in origin upstream; do
        git remote get-url "$name" 2>/dev/null && return 0
    done
    name=$(git remote 2>/dev/null | head -n 1) || name=""
    [[ -n "$name" ]] || return 1
    git remote get-url "$name" 2>/dev/null || return 1
}

resolve_repo() {
    if [[ -n "$REPO" ]]; then
        [[ "$REPO" =~ $SLUG_RE ]] || usage_error "--repo must look like OWNER/REPO, got: $REPO"
        return 0
    fi
    if [[ -n "${GH_REPO:-}" && "${GH_REPO}" =~ $SLUG_RE ]]; then
        REPO=$GH_REPO
        return 0
    fi
    local url slug
    url=$(remote_url) || url=""
    if [[ -n "$url" ]]; then
        slug=$(slug_from_url "$url")
        if [[ "$slug" =~ $SLUG_RE ]]; then
            REPO=$slug
            return 0
        fi
    fi
    # Last resort: gh substitutes these placeholders from the current directory's
    # repository, and reports a clear error itself when it cannot resolve one.
    REPO='{owner}/{repo}'
}

read_body() {
    if [[ "$BODY_ARG" == "-" ]]; then
        [[ -t 0 ]] && die "--body-file - reads the body from stdin; pipe or redirect it"
        BODY_FILE="$WORK_DIR/body.txt"
        cat >"$BODY_FILE"
    else
        [[ -e "$BODY_ARG" ]] || die "--body-file does not exist: $BODY_ARG"
        [[ -r "$BODY_ARG" ]] || die "--body-file is not readable: $BODY_ARG"
        [[ -d "$BODY_ARG" ]] && die "--body-file is a directory: $BODY_ARG"
        BODY_FILE=$BODY_ARG
    fi
    [[ -s "$BODY_FILE" ]] || die "comment body is empty: $BODY_ARG"
    LC_ALL=C grep -qE '[^[:space:]]' "$BODY_FILE" ||
        die "comment body is whitespace-only: $BODY_ARG"
}

# Body goes in via --rawfile, so no shell expansion ever touches it.
build_payload() {
    local payload="$WORK_DIR/payload.json"
    if [[ "$MODE" != "anchor" ]]; then
        jq -n --rawfile body "$BODY_FILE" '{body: $body}' >"$payload"
        return 0
    fi
    local commit
    commit=$(git rev-parse HEAD 2>/dev/null) ||
        die "--anchor needs a git checkout to resolve commit_id (git rev-parse HEAD failed)"
    jq -n --rawfile body "$BODY_FILE" \
        --arg commit "$commit" --arg path "$ANCHOR_PATH" --arg side "$SIDE" \
        --argjson line "$ANCHOR_LINE" --arg start "$START_LINE" \
        '{body: $body, commit_id: $commit, path: $path, line: $line, side: $side}
         + (if $start == "" then {} else {start_line: ($start | tonumber), start_side: $side} end)' \
        >"$payload"
}

report_api_failure() {
    local rc=$1 err_file=$2 context=$3
    printf '%s: gh api failed (rc=%s) during %s\n' "$PROGNAME" "$rc" "$context" >&2
    if [[ -s "$err_file" ]]; then
        head -n "$ERR_CONTEXT_LINES" "$err_file" >&2
    fi
}

# A 422 on --anchor means the line is not part of the PR diff; that is a routine,
# recoverable outcome, so name the fallback instead of just echoing gh's error.
report_anchor_hint() {
    local err_file=$1
    grep -qE '\b422\b' "$err_file" || return 0
    printf '%s: hint: %s line %s is not in PR #%s'"'"'s diff (or the commit is not the PR head).\n' \
        "$PROGNAME" "$ANCHOR_PATH" "$ANCHOR_LINE" "$PR" >&2
    printf '%s: hint: re-run without --anchor to post a top-level comment quoting the finding.\n' \
        "$PROGNAME" >&2
}

send_payload() {
    local method=$1 endpoint=$2
    local out="$WORK_DIR/created.json" err="$WORK_DIR/create.err" rc=0
    <"$WORK_DIR/payload.json" "$GH_BIN" api "$endpoint" -X "$method" \
        -H "$ACCEPT_HEADER" --input - >"$out" 2>"$err" || rc=$?
    if ((rc != 0)); then
        report_api_failure "$rc" "$err" "$method $endpoint"
        [[ "$MODE" == "anchor" ]] && report_anchor_hint "$err"
        exit 1
    fi
}

fetch_stored_body() {
    local endpoint=$1
    local out="$WORK_DIR/stored.json" err="$WORK_DIR/verify.err" rc=0
    "$GH_BIN" api "$endpoint" -H "$ACCEPT_HEADER" >"$out" 2>"$err" || rc=$?
    if ((rc != 0)); then
        report_api_failure "$rc" "$err" "verification GET $endpoint"
        printf '%s: the comment may exist but its body is UNVERIFIED; do not resolve anything.\n' \
            "$PROGNAME" >&2
        exit 1
    fi
    jq -j '.body // ""' <"$out" >"$WORK_DIR/stored.txt"
}

# jq -j writes the decoded string with no added newline, so both sides are the
# exact bytes GitHub received and returned.
compare_bodies() {
    jq -j '.body' <"$WORK_DIR/payload.json" >"$WORK_DIR/intended.txt"
    if cmp -s "$WORK_DIR/intended.txt" "$WORK_DIR/stored.txt"; then
        return 0
    fi
    printf '%s: stored body does not match the intended body; nothing was resolved.\n' \
        "$PROGNAME" >&2
    diff -u --label intended --label stored \
        "$WORK_DIR/intended.txt" "$WORK_DIR/stored.txt" 2>&1 |
        head -n "$DIFF_CONTEXT_LINES" >&2 || true
    return 1
}

endpoint_for_create() {
    case "$MODE" in
    reply-to) printf 'repos/%s/pulls/%s/comments/%s/replies' "$REPO" "$PR" "$REPLY_TO" ;;
    anchor) printf 'repos/%s/pulls/%s/comments' "$REPO" "$PR" ;;
    update) printf 'repos/%s/issues/comments/%s' "$REPO" "$UPDATE_ID" ;;
    *) printf 'repos/%s/issues/%s/comments' "$REPO" "$PR" ;;
    esac
}

endpoint_for_verify() {
    local id=$1
    case "$MODE" in
    reply-to | anchor) printf 'repos/%s/pulls/comments/%s' "$REPO" "$id" ;;
    *) printf 'repos/%s/issues/comments/%s' "$REPO" "$id" ;;
    esac
}

main() {
    parse_args "$@"
    validate_args
    resolve_repo
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gh-comment.XXXXXX")
    trap cleanup EXIT
    read_body
    build_payload

    local method="POST"
    [[ "$MODE" == "update" ]] && method="PATCH"
    send_payload "$method" "$(endpoint_for_create)"

    local id url
    id=$(jq -r '.id // empty' <"$WORK_DIR/created.json")
    [[ "$id" =~ $UINT_RE ]] ||
        die "GitHub returned no usable comment id; body is UNVERIFIED, do not resolve anything."
    url=$(jq -r '.html_url // empty' <"$WORK_DIR/created.json")
    [[ -n "$url" ]] || url="unknown"

    fetch_stored_body "$(endpoint_for_verify "$id")"
    compare_bodies || exit 1

    local verb="posted"
    [[ "$MODE" == "update" ]] && verb="updated"
    printf '%s id=%s url=%s verified=exact\n' "$verb" "$id" "$url"
}

main "$@"
