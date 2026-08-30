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
#       header, fingerprint, state}. state is "answered" when --answered
#       names a ledger carrying an entry whose id AND fingerprint both match
#       this finding, else "open" (including when --answered is omitted
#       entirely -- every finding is open by default, and including when the
#       comment was edited since it was answered: an id match with a
#       DIFFERENT fingerprint is still open, never answered). Read-only;
#       never touches --answered.
#
#   count --comments FILE [--answered FILE]
#       Prints exactly one line: "open=N answered=M total=T". Read-only.
#
#   mark-answered --answered FILE --id ID --sha SHA --fingerprint FP
#       Appends {"id":ID,"sha":SHA,"fingerprint":FP,"answered_at":TIMESTAMP}
#       to FILE (created 0600 if absent). Idempotent on the (id, fingerprint)
#       PAIR, not id alone (mirrors review-ledger.sh cmd_cover's (sha, reason)
#       keying, issue #567) -- an id already answered under a DIFFERENT
#       fingerprint is a genuinely new record (the underlying comment
#       changed), so it is appended, not skipped. An identical (id,
#       fingerprint) pair already present prints "already-answered" and
#       exits 0 without appending a duplicate.
#
# Exit status: 0 success; 1 evidence unavailable (missing tool, unreadable
# or malformed --comments/--answered file); 2 usage error.
#
# Requires: bash >= 4.2, jq >= 1.6, sha256sum (or shasum -a 256).
set -euo pipefail
umask 077

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/provider-identity.sh"

readonly PROGNAME=${0##*/}
readonly ID_RE='^[0-9]+#[0-9]+$'
readonly SHA_RE='^[[:xdigit:]]{7,64}(,[[:xdigit:]]{7,64})*$'
readonly FINGERPRINT_RE='^[0-9a-f]{64}$'
# A priority call-out: **P<digit> <dash-or-colon> <header text>**. \p{Pd}
# covers hyphen-minus and every Unicode dash (en/em dash included) without
# embedding a literal non-ASCII byte in this source file.
readonly RE_PRIORITY='\*\*P([0-9])\s*[\p{Pd}:]\s*([^*\n]+)\*\*'
# CodeRabbit's own findings-count summary line, e.g.
# "**Actionable comments posted: 2**". Captured SEPARATELY from the generic
# Actionable matcher below so a zero count -- "nothing to do" -- never reads
# as a finding (agent-kit#566 review finding F2).
readonly RE_ACTIONABLE_COUNT='(?i)\*\*Actionable comments posted:\s*([0-9]+)\*\*'
# Any OTHER **Actionable ...** block. The negative lookahead excludes the
# count-summary phrasing above so the two regexes never both match the same
# bolded text as two separate findings.
readonly RE_ACTIONABLE_GENERIC='\*\*(?<h>[Aa]ctionable(?!\s+comments\s+posted)[^*\n]*)\*\*'
# A plain "outside diff range" note; CodeRabbit does not always bold it.
readonly RE_OUTSIDE_DIFF='(?i)(?<h>[^\n]*outside diff range[^\n]*)'

usage() {
    cat <<EOF
Usage: $PROGNAME list  --comments FILE [--answered FILE]
       $PROGNAME count --comments FILE [--answered FILE]
       $PROGNAME mark-answered --answered FILE --id ID --sha SHA --fingerprint FP

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
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
        die_evidence 'sha256sum (or shasum) not found on PATH'
}

require_comments_file() {
    local file=$1
    [[ -n $file ]] || die_usage '--comments is required'
    [[ -f $file && ! -L $file && -r $file ]] ||
        die_evidence "comments artifact is not a readable regular file: $file"
    jq -e 'type == "array"' "$file" >/dev/null 2>&1 ||
        die_evidence "comments artifact is not a valid JSON array: $file"
}

# answered_records FILE -- prints a jq array (compact JSON) of every
# {id, fingerprint} pair already recorded in the answered ledger, or "[]"
# when FILE is empty/absent. A present-but-malformed ledger fails closed
# (die_evidence), matching the repo's other local ledgers (finding-ledger.sh's
# validate_existing_ledger). Every entry MUST carry a fingerprint (agent-kit#566
# review finding F4): an entry recorded before that field existed cannot prove
# it answered the SAME finding text, so it is rejected rather than silently
# trusted.
answered_records() {
    local file=$1
    [[ -n $file ]] || { printf '[]'; return 0; }
    [[ -e $file ]] || { printf '[]'; return 0; }
    [[ -f $file && ! -L $file && -r $file ]] ||
        die_evidence "answered ledger is not a readable regular file: $file"
    jq -c -s --arg id_re "$ID_RE" --arg fp_re "$FINGERPRINT_RE" '
        [.[] | select(type == "object") |
          select((.id // "") | test($id_re)) |
          select((.fingerprint // "") | test($fp_re)) |
          {id: .id, fingerprint: .fingerprint}]
    ' "$file" 2>/dev/null || die_evidence "answered ledger is not valid ndjson: $file"
}

# classify_findings COMMENTS_FILE -- prints a compact JSON array of every
# finding (no "fingerprint"/"state" field yet; with_fingerprints and
# list/count add those). All three finding shapes (priority call-out,
# Actionable block, outside-diff-range note) are collected independently per
# comment, THEN deduplicated by header containment (agent-kit#566 review
# finding F3): a priority match no longer silently suppresses every other
# finding in the same comment the way an exclusive if/else once did. Two
# candidates dedupe only when one header contains the other (the common
# real-world case: an "outside diff range" scan spanning the whole line that
# also holds a **P1 — ...** call-out) -- genuinely distinct findings in the
# same comment (e.g. a priority call-out AND an unrelated Actionable count)
# both survive. Earlier-constructed candidates (priority, then Actionable,
# then outside-diff-range) win a dedup collision, since they are the more
# specific match.
classify_findings() {
    local file=$1
    jq -c "$PROVIDER_IDENTITY_JQ"'
      [ .[]?
        | select(((.user.login // "") | ascii_downcase) | known_provider_login)
        | . as $c
        | ($c.body // "") as $body
        | ([$body | scan($re_p)] | map({priority: ("P" + .[0]),
                                         header: (.[1] | gsub("^\\s+|\\s+$";"")),
                                         kind: "priority"})) as $priority_findings
        # A zero count is "nothing to do", never a finding (F2).
        | ([$body | scan($re_ac)]
            | map(select((.[0] | tonumber) > 0))
            | map({priority: null, header: ("Actionable comments posted: " + .[0]),
                   kind: "actionable"})) as $actionable_count_findings
        | (if ($body | test($re_ag)) then
             [{priority: null, header: ($body | capture($re_ag).h), kind: "actionable"}]
           else [] end) as $actionable_generic_findings
        | ($actionable_count_findings + $actionable_generic_findings) as $actionable_findings
        | (if ($body | test($re_o)) then
             [{priority: null,
               header: ($body | capture($re_o).h | gsub("^\\s+|\\s+$";"")),
               kind: "outside-diff-range"}]
           else [] end) as $outside_findings
        | ($priority_findings + $actionable_findings + $outside_findings) as $candidates
        | [ range(0; ($candidates | length)) as $i
            | $candidates[$i] as $f
            | ([range(0; $i)] | map($candidates[.].header)) as $earlier
            | select(
                (any($earlier[]; . as $eh | ($eh | contains($f.header)) or ($f.header | contains($eh))))
                | not
              )
            | $f
          ] as $findings
        | range(0; ($findings | length)) as $i
        | ($findings[$i]) as $f
        | {surface: "issue-comment",
           id: (($c.id | tostring) + "#" + ($i | tostring)),
           comment_id: ($c.id | tostring),
           anchor: ($c.id | tostring),
           author: $c.user.login,
           priority: $f.priority, kind: $f.kind, header: $f.header}
      ]' \
        --arg re_p "$RE_PRIORITY" --arg re_ac "$RE_ACTIONABLE_COUNT" \
        --arg re_ag "$RE_ACTIONABLE_GENERIC" --arg re_o "$RE_OUTSIDE_DIFF" \
        "$file" || die_evidence "could not classify issue-comment findings: $file"
}

# fingerprint_of KIND PRIORITY HEADER -- sha256 hex digest of the normalized
# finding content (agent-kit#566 review finding F4): identity by
# comment_id#index alone means a bot edit that swaps what occupies index 0
# would silently inherit any prior answered state at that id. Including kind
# and priority alongside header (not header alone) keeps two same-text
# findings of different kinds in the same comment from colliding.
fingerprint_of() {
    local kind=$1 priority=$2 header=$3
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s\x00%s\x00%s' "$kind" "$priority" "$header" | sha256sum | cut -d' ' -f1
    else
        printf '%s\x00%s\x00%s' "$kind" "$priority" "$header" | shasum -a 256 | cut -d' ' -f1
    fi
}

# with_fingerprints FINDINGS_JSON -- prints FINDINGS_JSON with a
# "fingerprint" field added to every element. Shells out per finding (sha256
# has no jq builtin); the per-PR finding count this classifies is small
# enough that this is a one-shot classification, not a hot loop.
with_fingerprints() {
    local findings=$1 count i obj kind priority header fp
    count=$(jq 'length' <<<"$findings") || die_evidence 'could not count findings for fingerprinting'
    local -a fingerprinted=()
    for ((i = 0; i < count; i++)); do
        obj=$(jq -c ".[$i]" <<<"$findings")
        kind=$(jq -r '.kind' <<<"$obj")
        priority=$(jq -r '.priority // ""' <<<"$obj")
        header=$(jq -r '.header' <<<"$obj")
        fp=$(fingerprint_of "$kind" "$priority" "$header")
        fingerprinted+=("$(jq -c --arg fp "$fp" '. + {fingerprint: $fp}' <<<"$obj")")
    done
    if ((${#fingerprinted[@]} == 0)); then
        printf '[]'
    else
        (IFS=,; printf '[%s]' "${fingerprinted[*]}")
    fi
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

    local findings records
    findings=$(with_fingerprints "$(classify_findings "$comments")")
    records=$(answered_records "$answered")
    # `(.id) as $fid | (.fingerprint) as $ffp | any($records[]; ...)` -- an id
    # match alone is never enough (F4): the fingerprint must ALSO match, or
    # the underlying comment changed since it was answered and this is a
    # different finding wearing the same id.
    jq -c --argjson records "$records" '
      .[] | (.id) as $fid | (.fingerprint) as $ffp |
      . + {state: (if (any($records[]; .id == $fid and .fingerprint == $ffp))
                   then "answered" else "open" end)}
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

    local findings records counts
    findings=$(with_fingerprints "$(classify_findings "$comments")")
    records=$(answered_records "$answered")
    counts=$(jq -r --argjson records "$records" '
      ([.[] | (.id) as $fid | (.fingerprint) as $ffp |
        any($records[]; .id == $fid and .fingerprint == $ffp)]
        | map(select(.)) | length) as $answered_n
      | (length - $answered_n) as $open_n
      | "\($open_n)\t\($answered_n)\t\(length)"
    ' <<<"$findings") || die_evidence 'could not count issue-comment findings'
    local open answered_n total
    IFS=$'\t' read -r open answered_n total <<<"$counts"
    printf 'open=%s answered=%s total=%s\n' "$open" "$answered_n" "$total"
}

cmd_mark_answered() {
    local answered='' id='' sha='' fingerprint=''
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || die_usage "unexpected argument after --: $1"; break ;;
            --answered) [[ ${2-} ]] || die_usage '--answered requires a path'; answered=$2; shift 2 ;;
            --id) [[ ${2-} ]] || die_usage '--id requires a value'; id=$2; shift 2 ;;
            --sha) [[ ${2-} ]] || die_usage '--sha requires a value'; sha=$2; shift 2 ;;
            --fingerprint) [[ ${2-} ]] || die_usage '--fingerprint requires a value'; fingerprint=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -n $answered ]] || die_usage '--answered is required'
    [[ -n $id ]] || die_usage '--id is required'
    [[ $id =~ $ID_RE ]] || die_usage "--id must look like COMMENT_ID#INDEX, got: $id"
    [[ -n $sha ]] || die_usage '--sha is required'
    [[ $sha =~ $SHA_RE ]] || die_usage '--sha (SHA) must be hexadecimal (or comma-separated hexadecimal)'
    [[ -n $fingerprint ]] || die_usage '--fingerprint is required'
    [[ $fingerprint =~ $FINGERPRINT_RE ]] ||
        die_usage '--fingerprint must be a 64-character lowercase hexadecimal sha256 digest (see list'"'"'s "fingerprint" field)'
    require_tools

    [[ ! -L $answered ]] || die_evidence "answered ledger is a symlink: $answered"
    if [[ -e $answered ]]; then
        [[ -f $answered && -O $answered && -r $answered ]] ||
            die_evidence "answered ledger is not an owned regular file: $answered"
        local existing
        existing=$(answered_records "$answered")
        if jq -e --arg id "$id" --arg fp "$fingerprint" \
            'any(.[]; .id == $id and .fingerprint == $fp)' <<<"$existing" >/dev/null 2>&1; then
            printf 'already-answered\n'
            return 0
        fi
    fi

    local entry
    entry=$(jq -cn --arg id "$id" --arg sha "$sha" --arg fp "$fingerprint" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:$id, sha:$sha, fingerprint:$fp, answered_at:$at}') ||
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
