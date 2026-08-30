#!/usr/bin/env bash
#
# classify-issue-comment-findings.sh — pull triage-grade findings out of
# CodeRabbit/Code-Quality PLAIN ISSUE COMMENTS (agent-kit#566).
#
# gh-pr-state.sh's `nitpicks:` line already counts review bodies and PR
# conversation comments matching /nitpick/i or the broom emoji. It never
# catches a bot's chat-reply issue comment that carries a real
# `**P1 — ...**` priority call-out, a `**Actionable**` block, or an
# "outside diff range" note -- agent-kit PR #552's blocking P1 landed
# exactly that way and was never triaged (issues/552 comments, no matching
# reviews/552 entry, inline=0). This script is the missing classifier: it
# reads an already-fetched `pr_N_issue_comments.json`-shaped artifact
# (gh-pr-state.sh --full's own output; no network call here) and turns each
# matching block into one finding, keyed `<comment_id>#<index>` so two
# distinct call-outs in the same comment (e.g. "Actionable" AND "outside
# diff range") never collide into a single open/answered state.
#
# There is no GitHub review thread for a plain issue comment, so "resolved"
# is not a concept here. Instead, a lightweight append-only local ledger (an
# ndjson file the caller names with --answered) records which finding ids
# have already been answered -- by replying in the conversation
# (`gh-comment.sh`, banner on) quoting the finding's header, with the fix
# commit SHA. `mark-answered` appends to that ledger; `list`/`count` read it
# back to report each finding's `state`.
#
# A comment carrying findings but posted as a plain chat reply (rather than
# a formal review) MAY also be a misparsed trigger phrase in the sense of
# issue #565 -- that classification (TRIGGER_MISPARSED) lives in pr-to-green's
# own trigger-detection path on another branch and is not reimplemented here;
# this script only ever answers "does this issue comment carry a
# triage-worthy finding," never "was the trigger itself malformed."
#
# Subcommands:
#   list  --comments FILE [--answered FILE]
#       Prints one compact JSON object per finding (newline-delimited) to
#       stdout: {surface, id, comment_id, anchor, author, priority, kind,
#       header, state}. state is "answered" when --answered names a ledger
#       already carrying that finding's id, else "open" (including when
#       --answered is omitted entirely -- every finding is open by
#       default). Read-only; never touches --answered.
#
#   count --comments FILE [--answered FILE]
#       Prints exactly one line: "open=N answered=M total=T". Read-only.
#
#   mark-answered --answered FILE --id ID --sha SHA
#       Appends {"id":ID,"sha":SHA,"answered_at":TIMESTAMP} to FILE
#       (created 0600 if absent). Idempotent: an id already present prints
#       "already-answered" and exits 0 without appending a duplicate.
#
# Exit status: 0 success; 1 evidence unavailable (missing tool, unreadable
# or malformed --comments/--answered file); 2 usage error.
#
# Requires: bash >= 4.2, jq >= 1.6.
set -euo pipefail
umask 077

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/provider-identity.sh"

readonly PROGNAME=${0##*/}
readonly ID_RE='^[0-9]+#[0-9]+$'
readonly SHA_RE='^[[:xdigit:]]{7,64}(,[[:xdigit:]]{7,64})*$'
# A priority call-out: **P<digit> <dash-or-colon> <header text>**. \p{Pd}
# covers hyphen-minus and every Unicode dash (en/em dash included) without
# embedding a literal non-ASCII byte in this source file.
readonly RE_PRIORITY='\*\*P([0-9])\s*[\p{Pd}:]\s*([^*\n]+)\*\*'
# **Actionable ...** blocks (e.g. "**Actionable comments posted: 2**").
readonly RE_ACTIONABLE='\*\*(?<h>[Aa]ctionable[^*\n]*)\*\*'
# A plain "outside diff range" note; CodeRabbit does not always bold it.
readonly RE_OUTSIDE_DIFF='(?i)(?<h>[^\n]*outside diff range[^\n]*)'

usage() {
    cat <<EOF
Usage: $PROGNAME list  --comments FILE [--answered FILE]
       $PROGNAME count --comments FILE [--answered FILE]
       $PROGNAME mark-answered --answered FILE --id ID --sha SHA

See the script header comment for the full contract.
EOF
}

die_usage() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    usage >&2
    exit 2
}

die_evidence() {
    printf '%s: %s; evidence unavailable\n' "$PROGNAME" "$1" >&2
    exit 1
}

require_tools() {
    command -v jq >/dev/null 2>&1 || die_evidence 'jq not found on PATH'
}

require_comments_file() {
    local file=$1
    [[ -n $file ]] || die_usage '--comments is required'
    [[ -f $file && ! -L $file && -r $file ]] ||
        die_evidence "comments artifact is not a readable regular file: $file"
    jq -e 'type == "array"' "$file" >/dev/null 2>&1 ||
        die_evidence "comments artifact is not a valid JSON array: $file"
}

# answered_ids FILE -- prints a jq array (compact JSON) of every "id" already
# recorded in the answered ledger, or "[]" when FILE is empty/absent. A
# present-but-malformed ledger fails closed (die_evidence), matching the
# repo's other local ledgers (finding-ledger.sh's validate_existing_ledger).
answered_ids() {
    local file=$1
    [[ -n $file ]] || { printf '[]'; return 0; }
    [[ -e $file ]] || { printf '[]'; return 0; }
    [[ -f $file && ! -L $file && -r $file ]] ||
        die_evidence "answered ledger is not a readable regular file: $file"
    jq -c -s --arg id_re "$ID_RE" '
        [.[] | select(type == "object") |
          (.id // "") | select(test($id_re))]
    ' "$file" 2>/dev/null || die_evidence "answered ledger is not valid ndjson: $file"
}

# classify_findings COMMENTS_FILE -- prints a compact JSON array of every
# finding (no "state" field yet; list/count annotate that from the answered
# ledger). One priority-marker match takes precedence over the
# actionable/outside-diff-range scan for that SAME comment body: a comment
# already carrying an explicit **P<N> — ...** call-out is fully described by
# its priority findings, and re-matching "Actionable"/"outside diff range"
# phrases inside that same block would double-count the identical issue
# under a second, less specific kind.
classify_findings() {
    local file=$1
    jq -c "$PROVIDER_IDENTITY_JQ"'
      [ .[]?
        | select(((.user.login // "") | ascii_downcase) | known_provider_login)
        | . as $c
        | ($c.body // "") as $body
        | ([$body | scan($re_p)]) as $pmatches
        | (if ($pmatches | length) > 0 then
             [ $pmatches[] | {priority: ("P" + .[0]),
                              header: (.[1] | gsub("^\\s+|\\s+$";"")),
                              kind: "priority"} ]
           else
             ( (if ($body | test($re_a)) then
                  [{priority: null, header: ($body | capture($re_a).h), kind: "actionable"}]
                else [] end)
               + (if ($body | test($re_o)) then
                    [{priority: null,
                      header: ($body | capture($re_o).h | gsub("^\\s+|\\s+$";"")),
                      kind: "outside-diff-range"}]
                  else [] end) )
           end) as $findings
        | range(0; ($findings | length)) as $i
        | ($findings[$i]) as $f
        | {surface: "issue-comment",
           id: (($c.id | tostring) + "#" + ($i | tostring)),
           comment_id: ($c.id | tostring),
           anchor: ($c.id | tostring),
           author: $c.user.login,
           priority: $f.priority, kind: $f.kind, header: $f.header}
      ]' \
        --arg re_p "$RE_PRIORITY" --arg re_a "$RE_ACTIONABLE" --arg re_o "$RE_OUTSIDE_DIFF" \
        "$file" || die_evidence "could not classify issue-comment findings: $file"
}

cmd_list() {
    local comments='' answered=''
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || die_usage "unexpected argument after --: $1"; break ;;
            --comments) [[ ${2-} ]] || die_usage '--comments requires a path'; comments=$2; shift 2 ;;
            --answered) [[ ${2-} ]] || die_usage '--answered requires a path'; answered=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    require_tools
    require_comments_file "$comments"

    local findings ids
    findings=$(classify_findings "$comments")
    ids=$(answered_ids "$answered")
    # `(.id) as $fid | ($answered | index($fid))` -- NOT `$answered | index(.id)`:
    # the pipe into $answered replaces `.` for its right-hand side, so a bare
    # `.id` there would index the answered-ids ARRAY with the string "id"
    # instead of reading the current finding's id.
    jq -c --argjson answered "$ids" '
      .[] | (.id) as $fid |
      . + {state: (if ($answered | index($fid)) != null then "answered" else "open" end)}
    ' <<<"$findings" || die_evidence 'could not annotate finding state'
}

cmd_count() {
    local comments='' answered=''
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || die_usage "unexpected argument after --: $1"; break ;;
            --comments) [[ ${2-} ]] || die_usage '--comments requires a path'; comments=$2; shift 2 ;;
            --answered) [[ ${2-} ]] || die_usage '--answered requires a path'; answered=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    require_tools
    require_comments_file "$comments"

    local findings ids counts
    findings=$(classify_findings "$comments")
    ids=$(answered_ids "$answered")
    counts=$(jq -r --argjson answered "$ids" '
      ([.[] | (.id) as $fid | ($answered | index($fid)) != null]
        | map(select(.)) | length) as $answered_n
      | (length - $answered_n) as $open_n
      | "\($open_n)\t\($answered_n)\t\(length)"
    ' <<<"$findings") || die_evidence 'could not count issue-comment findings'
    local open answered_n total
    IFS=$'\t' read -r open answered_n total <<<"$counts"
    printf 'open=%s answered=%s total=%s\n' "$open" "$answered_n" "$total"
}

cmd_mark_answered() {
    local answered='' id='' sha=''
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || die_usage "unexpected argument after --: $1"; break ;;
            --answered) [[ ${2-} ]] || die_usage '--answered requires a path'; answered=$2; shift 2 ;;
            --id) [[ ${2-} ]] || die_usage '--id requires a value'; id=$2; shift 2 ;;
            --sha) [[ ${2-} ]] || die_usage '--sha requires a value'; sha=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -n $answered ]] || die_usage '--answered is required'
    [[ -n $id ]] || die_usage '--id is required'
    [[ $id =~ $ID_RE ]] || die_usage "--id must look like COMMENT_ID#INDEX, got: $id"
    [[ -n $sha ]] || die_usage '--sha is required'
    [[ $sha =~ $SHA_RE ]] || die_usage '--sha (SHA) must be hexadecimal (or comma-separated hexadecimal)'
    require_tools

    [[ ! -L $answered ]] || die_evidence "answered ledger is a symlink: $answered"
    if [[ -e $answered ]]; then
        [[ -f $answered && -O $answered && -r $answered ]] ||
            die_evidence "answered ledger is not an owned regular file: $answered"
        local existing
        existing=$(answered_ids "$answered")
        if jq -e --arg id "$id" '. as $a | ($a | index($id)) != null' <<<"$existing" >/dev/null 2>&1; then
            printf 'already-answered\n'
            return 0
        fi
    fi

    local entry
    entry=$(jq -cn --arg id "$id" --arg sha "$sha" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:$id, sha:$sha, answered_at:$at}') ||
        die_evidence 'could not encode the answered-ledger entry'
    printf '%s\n' "$entry" >>"$answered" ||
        die_evidence "could not append to answered ledger: $answered"
    chmod 600 -- "$answered" || die_evidence "could not secure answered ledger: $answered"
    printf 'marked-answered id=%s\n' "$id"
}

main() {
    (($#)) || die_usage 'a subcommand is required: list, count, or mark-answered'
    local sub=$1
    shift
    case $sub in
        list) cmd_list "$@" ;;
        count) cmd_count "$@" ;;
        mark-answered) cmd_mark_answered "$@" ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown subcommand: $sub (expected list, count, or mark-answered)" ;;
    esac
}

main "$@"
