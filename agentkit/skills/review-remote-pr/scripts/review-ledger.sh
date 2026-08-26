#!/usr/bin/env bash
#
# review-ledger.sh — the durable per-PR review ledger: one machine-readable
# record of every review already performed on a PR (agent adversarial
# reviews and bot reviews alike), so a later run can answer "has this exact
# tree already been reviewed, by whom, with what outcome?" from a single
# cheap read of an already-fetched comments artifact.
#
# The ledger lives in exactly one issue comment per PR, fenced with
#   <!-- review-ledger:v1 --> ```json {...} ``` <!-- /review-ledger:v1 -->
# Human-readable prose (the receipt rendering callers layer on top) stays
# above the fence; only the fenced JSON is machine-authoritative. Entries are
# append-only -- a later review adds a record, nothing already recorded is
# ever rewritten or removed.
#
# Subcommands:
#   read   --repo OWNER/REPO --pr N --comments FILE
#       Extracts and validates the ledger from an already-fetched
#       pr_N_issue_comments.json-shaped artifact. On success prints
#       "comment_id=ID" then the ledger's canonical compact JSON, and exits 0.
#
#   status --repo OWNER/REPO --pr N --comments FILE --head SHA
#          [--diff-payload ID] [--kind adversarial|bot] [--provider NAME]
#       Prints exactly one verdict word. Zero network calls: it only reads
#       --comments. See the exit-status table below.
#
#   append --repo OWNER/REPO --pr N --comments FILE --entry-file FILE
#          --agent-identity NAME [--repo-root DIR] [--gh-comment-script PATH]
#       Validates the one new entry in --entry-file, appends it to the
#       ledger found via read (or starts a fresh one when absent), renders
#       the one-comment body, and posts/updates it through the sibling
#       gh-comment.sh, which byte-verifies the stored body. --entry-file
#       carries a single JSON object shaped like one element of "reviews" in
#       the schema below (kind, head_sha, provider are always required; the
#       remaining fields are carried through verbatim).
#
# status verdicts:
#   covered-head   an entry's head_sha equals --head                    exit 0
#   covered-diff   head_sha differs but diff_payload matches (the tree
#                  under review is byte-identical); requires --diff-payload
#                  on the call AND a non-empty diff_payload on the entry     exit 0
#   stale          entries exist for the --kind/--provider filter, but
#                  neither head nor diff matches -- or the matching entry's
#                  head_sha is proven (via --repo-root) unreachable from
#                  --head, e.g. a force-push rewrote history               exit 10
#   absent         no ledger, or no entry for this kind/provider           exit 11
#   (nothing)      ledger present but unparseable/fence malformed -- BLOCKS,
#                  never read as absent                                    exit 1
#
# Exit status (all subcommands):
#   0   success (read: ledger found & valid; status: covered-*; append: posted)
#   1   evidence unavailable / present-but-unparseable ledger (fails closed)
#   2   usage error
#   10  status only: stale
#   11  read/status only: absent (no ledger, or no matching entry)
#
# Requires: bash >= 4.2, jq >= 1.6. append additionally requires the sibling
# gh-comment.sh and everything it requires (gh, diff, cmp).
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
readonly OPEN_MARKER='<!-- review-ledger:v1 -->'
readonly CLOSE_MARKER='<!-- /review-ledger:v1 -->'
readonly DOC_MARKER='<!-- review-remote-pr:agent-doc -->'
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
readonly UINT_RE='^(0|[1-9][0-9]*)$'
readonly SHA_RE='^[0-9a-f]{7,40}$'
ROBOT=$(printf '\U1F916')
readonly ROBOT

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.

usage() {
    cat <<EOF
Usage: $PROGNAME read   --repo OWNER/REPO --pr N --comments FILE
       $PROGNAME status --repo OWNER/REPO --pr N --comments FILE --head SHA
                 [--diff-payload ID] [--kind adversarial|bot] [--provider NAME]
       $PROGNAME append --repo OWNER/REPO --pr N --comments FILE \\
                 --entry-file FILE --agent-identity NAME \\
                 [--repo-root DIR] [--gh-comment-script PATH]

See the script header comment for the full contract and exit-status table.
EOF
}

die_usage() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    usage >&2
    exit 2
}

evidence_unavailable() {
    printf '%s: %s; evidence unavailable\n' "$PROGNAME" "$1" >&2
    exit 1
}

require_uint() {
    local flag=$1 value=$2
    [[ $value =~ $UINT_RE ]] || die_usage "$flag expects a non-negative integer, got: $value"
}

require_tools() {
    command -v jq >/dev/null 2>&1 || evidence_unavailable 'jq not found on PATH'
}

# jq filter validating one complete ledger document. kind/head_sha/provider
# are the only fields every consumer relies on; everything else is carried
# through verbatim (per-kind fields differ -- adversarial vs bot).
readonly LEDGER_SCHEMA_JQ='
  type == "object" and
  .version == 1 and
  (.pr | type) == "number" and
  (.repo | type) == "string" and (.repo | length) > 0 and
  (.reviews | type) == "array" and
  all(.reviews[];
    type == "object" and
    (.kind == "adversarial" or .kind == "bot") and
    (.head_sha | type) == "string" and (.head_sha | test("^[0-9a-f]{7,40}$")) and
    (.provider | type) == "string" and (.provider | length) > 0 and
    ((has("diff_payload") | not) or (.diff_payload | type) == "string"))
'

# jq filter validating one NEW entry (a single object, same per-entry shape
# as above). Kept separate from LEDGER_SCHEMA_JQ so a malformed existing
# ledger and a malformed new entry are reported distinctly.
readonly ENTRY_SCHEMA_JQ='
  type == "object" and
  (.kind == "adversarial" or .kind == "bot") and
  (.head_sha | type) == "string" and (.head_sha | test("^[0-9a-f]{7,40}$")) and
  (.provider | type) == "string" and (.provider | length) > 0 and
  ((has("diff_payload") | not) or (.diff_payload | type) == "string")
'

# ledger_fence_regex -- the oniguruma regex (jq's capture/test flavor) that
# pulls the fenced JSON text out from between the two literal markers. Built
# once here rather than inlined, since the markers contain regex
# metacharacters (`<`, `!`, `-`) that must be escaped before use.
ledger_fence_regex() {
    # shellcheck disable=SC2016  # single-quoted on purpose: this is a printf
    # format string and a literal sed pattern, neither meant to expand here.
    printf '(?s)%s\\r?\\n```json\\r?\\n(?<json>.*?)\\r?\\n```\\r?\\n%s' \
        "$(printf '%s' "$OPEN_MARKER" | sed -e 's/[.[\*^$()+?{|\\]/\\&/g')" \
        "$(printf '%s' "$CLOSE_MARKER" | sed -e 's/[.[\*^$()+?{|\\]/\\&/g')"
}

# find_ledger_comments FILE -- prints "ID\tJSON_TEXT" for every comment body
# whose fence parses (json text possibly still schema-invalid; that is
# checked by the caller). A body carrying the markers but no parseable
# fenced json is silently skipped here -- the caller's zero-vs-one-vs-many
# accounting over ALL marker-carrying bodies (find_marker_comment_count)
# is what actually distinguishes "absent" from "malformed".
# The captured json field is base64-encoded before joining into the @tsv row:
# @tsv escapes embedded newlines/tabs as literal backslash-n/backslash-t
# sequences rather than real control characters, and a pretty-printed JSON
# document is full of structural newlines. Read back through `read` (which
# does not un-escape @tsv's backslash sequences) those would land in the
# "json" field as literal backslash-n text -- outside any JSON string, so
# jq then refuses to parse it. Base64 has no embedded tabs/newlines at all,
# so it round-trips through @tsv and `read` unchanged.
find_ledger_comments() {
    local file=$1 regex
    regex=$(ledger_fence_regex)
    jq -r --arg re "$regex" '
      .[]? |
      select(((.body // "") | test($re)) ) |
      [(.id // "" | tostring), ((.body // "") | capture($re).json | @base64)] | @tsv
    ' "$file" 2>/dev/null
}

# Count of comments carrying BOTH markers, regardless of whether the fenced
# content between them parses. Used only to tell "no ledger comment at all"
# (0) apart from "a ledger comment exists but its fence/JSON is broken" (>=1
# marker-carrying comments but find_ledger_comments returned fewer rows).
count_marker_comments() {
    local file=$1
    jq -r --arg open "$OPEN_MARKER" --arg close "$CLOSE_MARKER" '
      [.[]? | select(((.body // "") | contains($open)) and ((.body // "") | contains($close)))] | length
    ' "$file" 2>/dev/null
}

# read_ledger FILE -- on success prints "ID\t<compact JSON>" to stdout and
# returns 0. Returns 11 with nothing printed when there is no ledger comment
# at all. Returns 1 with nothing printed (message on stderr) when a ledger
# comment exists but is unparseable/schema-invalid, or when more than one
# comment carries the fence (the "exactly one ledger comment" invariant
# broken) -- fail-closed per spec rule 1: never read a broken ledger as
# absent.
read_ledger() {
    local file=$1 marker_count rows row_count id json
    [[ -f $file && -r $file ]] || evidence_unavailable "comments artifact is not a readable file: $file"
    jq -e 'type == "array"' "$file" >/dev/null 2>&1 ||
        evidence_unavailable "comments artifact is not valid JSON: $file"

    marker_count=$(count_marker_comments "$file") || marker_count=0
    [[ $marker_count =~ ^[0-9]+$ ]] || marker_count=0
    if ((marker_count == 0)); then
        return 11
    fi

    rows=$(find_ledger_comments "$file") || rows=''
    row_count=0
    [[ -z $rows ]] || row_count=$(wc -l <<<"$rows")
    if ((row_count != marker_count)); then
        printf '%s: a review-ledger comment fence is present but malformed (unparseable JSON block)\n' \
            "$PROGNAME" >&2
        return 1
    fi
    if ((row_count != 1)); then
        printf '%s: expected exactly one review-ledger comment, found %s\n' \
            "$PROGNAME" "$row_count" >&2
        return 1
    fi

    local json_b64
    IFS=$'\t' read -r id json_b64 <<<"$rows"
    json=$(jq -Rrc '@base64d' <<<"$json_b64" 2>/dev/null | jq -c . 2>/dev/null) || {
        printf '%s: review-ledger comment fence does not contain valid JSON\n' "$PROGNAME" >&2
        return 1
    }
    [[ -n $json ]] || {
        printf '%s: review-ledger comment fence does not contain valid JSON\n' "$PROGNAME" >&2
        return 1
    }
    jq -e "$LEDGER_SCHEMA_JQ" <<<"$json" >/dev/null 2>&1 || {
        printf '%s: review-ledger JSON does not match the ledger schema\n' "$PROGNAME" >&2
        return 1
    }
    printf '%s\t%s\n' "$id" "$json"
    return 0
}

cmd_read() {
    local repo='' pr='' comments=''
    while (($#)); do
        case $1 in
            --repo) [[ ${2-} ]] || die_usage '--repo requires a value'; repo=$2; shift 2 ;;
            --pr) [[ ${2-} ]] || die_usage '--pr requires a value'; pr=$2; shift 2 ;;
            --comments) [[ ${2-} ]] || die_usage '--comments requires a path'; comments=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -n $repo ]] || die_usage '--repo is required'
    [[ $repo =~ $SLUG_RE ]] || die_usage "--repo must look like OWNER/REPO, got: $repo"
    [[ -n $pr ]] || die_usage '--pr is required'
    require_uint '--pr' "$pr"
    [[ -n $comments ]] || die_usage '--comments is required'
    require_tools

    local rc=0 out
    out=$(read_ledger "$comments") || rc=$?
    if ((rc == 11)); then
        printf '%s: no review-ledger comment found for PR #%s\n' "$PROGNAME" "$pr" >&2
        exit 11
    elif ((rc != 0)); then
        exit 1
    fi
    local id json
    IFS=$'\t' read -r id json <<<"$out"
    printf 'comment_id=%s\n' "$id"
    printf '%s\n' "$json"
}

# git_ancestor OLD_SHA NEW_SHA REPO_ROOT -- best-effort local-only reachability
# check (rule 5: a force-pushed history rewrite makes an old head_sha
# unreachable from the current head even when diff bytes happen to still
# match). Prints "yes", "no", or "unknown" (no repo-root given, git absent,
# or the object is simply not present locally -- e.g. a shallow clone).
# "unknown" never demotes a verdict: this check can only ever make a result
# MORE conservative (covered-diff -> stale), never less, and only when it can
# prove the negative.
git_ancestor() {
    local old=$1 new=$2 root=$3
    [[ -n $root ]] || { printf 'unknown\n'; return 0; }
    command -v git >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
    [[ -d $root ]] || { printf 'unknown\n'; return 0; }
    if git -C "$root" cat-file -e "${old}^{commit}" 2>/dev/null &&
        git -C "$root" cat-file -e "${new}^{commit}" 2>/dev/null; then
        if git -C "$root" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
            printf 'yes\n'
        else
            printf 'no\n'
        fi
        return 0
    fi
    printf 'unknown\n'
}

cmd_status() {
    local repo='' pr='' comments='' head='' diff_payload='' kind='' provider='' repo_root=''
    while (($#)); do
        case $1 in
            --repo) [[ ${2-} ]] || die_usage '--repo requires a value'; repo=$2; shift 2 ;;
            --pr) [[ ${2-} ]] || die_usage '--pr requires a value'; pr=$2; shift 2 ;;
            --comments) [[ ${2-} ]] || die_usage '--comments requires a path'; comments=$2; shift 2 ;;
            --head) [[ ${2-} ]] || die_usage '--head requires a value'; head=$2; shift 2 ;;
            --diff-payload) [[ ${2-} ]] || die_usage '--diff-payload requires a value'; diff_payload=$2; shift 2 ;;
            --kind) [[ ${2-} ]] || die_usage '--kind requires a value'; kind=$2; shift 2 ;;
            --provider) [[ ${2-} ]] || die_usage '--provider requires a value'; provider=$2; shift 2 ;;
            --repo-root) [[ ${2-} ]] || die_usage '--repo-root requires a path'; repo_root=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -n $repo ]] || die_usage '--repo is required'
    [[ $repo =~ $SLUG_RE ]] || die_usage "--repo must look like OWNER/REPO, got: $repo"
    [[ -n $pr ]] || die_usage '--pr is required'
    require_uint '--pr' "$pr"
    [[ -n $comments ]] || die_usage '--comments is required'
    [[ -n $head ]] || die_usage '--head is required'
    [[ $head =~ $SHA_RE ]] || die_usage "--head must look like a git SHA, got: $head"
    [[ -z $kind || $kind == adversarial || $kind == bot ]] ||
        die_usage "--kind must be adversarial or bot, got: $kind"
    require_tools

    local rc=0 out
    out=$(read_ledger "$comments") || rc=$?
    if ((rc == 11)); then
        printf 'absent\n'
        exit 11
    elif ((rc != 0)); then
        exit 1
    fi
    local id json
    IFS=$'\t' read -r id json <<<"$out"

    local candidates
    candidates=$(jq -c --arg kind "$kind" --arg provider "$provider" '
      [.reviews[] |
        select(($kind == "") or (.kind == $kind)) |
        select(($provider == "") or (.provider == $provider))]
    ' <<<"$json") || evidence_unavailable 'could not filter ledger entries'

    if [[ $(jq 'length' <<<"$candidates") == 0 ]]; then
        printf 'absent\n'
        exit 11
    fi

    if jq -e --arg head "$head" 'any(.[]; .head_sha == $head)' <<<"$candidates" >/dev/null 2>&1; then
        printf 'covered-head\n'
        exit 0
    fi

    if [[ -n $diff_payload ]]; then
        local match_entry
        match_entry=$(jq -c --arg dp "$diff_payload" \
            '[.[] | select((.diff_payload // "") == $dp and (.diff_payload // "") != "")] | first // empty' \
            <<<"$candidates") || match_entry=''
        if [[ -n $match_entry && $match_entry != null ]]; then
            local entry_head reach
            entry_head=$(jq -r '.head_sha' <<<"$match_entry")
            reach=$(git_ancestor "$entry_head" "$head" "$repo_root")
            # Root review finding F1 (fail-closed rule 5): reachability must
            # be POSITIVELY PROVEN, not merely "not disproven". Treating
            # "unknown" (no --repo-root, git absent, or an object simply not
            # present locally) as good enough silently accepted a covered-
            # diff verdict with NO ancestry evidence at all -- exactly the
            # force-push case rule 5 exists to catch, just with the check
            # never actually run. Only reach=yes may pass; reach=unknown
            # falls through to stale below, same as reach=no, with a named
            # reason on stderr so a caller can tell "proven stale" apart
            # from "reachability could not be proven".
            if [[ $reach == yes ]]; then
                printf 'covered-diff\n'
                exit 0
            fi
            if [[ $reach == unknown ]]; then
                printf '%s: reachability of %s from %s could not be proven (pass --repo-root to prove ancestry); reporting stale rather than covered-diff\n' \
                    "$PROGNAME" "$entry_head" "$head" >&2
            fi
        fi
    fi

    printf 'stale\n'
    exit 10
}

resolve_gh_comment_script() {
    local override=$1
    if [[ -n $override ]]; then
        [[ -x $override ]] || die_usage "--gh-comment-script is not executable: $override"
        printf '%s\n' "$override"
        return 0
    fi
    local here="$SCRIPT_DIR/gh-comment.sh"
    [[ -x $here ]] || die_usage "sibling gh-comment.sh not found or not executable: $here"
    printf '%s\n' "$here"
}

render_ledger_body() {
    local ledger_json=$1 agent_identity=$2
    printf 'This was written agentically; verify its assertions:\n'
    printf '%s\n' "$DOC_MARKER"
    printf '## Review ledger\n'
    printf 'Machine-readable record of every review already performed on this PR.\n'
    printf '%s\n' "$OPEN_MARKER"
    printf '```json\n'
    jq . <<<"$ledger_json"
    printf '```\n'
    printf '%s\n' "$CLOSE_MARKER"
    printf '%s Co-authored by %s.\n' "$ROBOT" "$agent_identity"
}

cmd_append() {
    # body_file is deliberately NOT local: the EXIT trap below fires after
    # this function returns, and a deferred "$body_file" expansion in the
    # trap needs the variable to still be in scope at that point (the same
    # reason post-receipt.sh's RECEIPT_BODY_FILE is global).
    body_file=''
    local repo='' pr='' comments='' entry_file='' agent_identity='' repo_root='' gh_comment_override=''
    while (($#)); do
        case $1 in
            --repo) [[ ${2-} ]] || die_usage '--repo requires a value'; repo=$2; shift 2 ;;
            --pr) [[ ${2-} ]] || die_usage '--pr requires a value'; pr=$2; shift 2 ;;
            --comments) [[ ${2-} ]] || die_usage '--comments requires a path'; comments=$2; shift 2 ;;
            --entry-file) [[ ${2-} ]] || die_usage '--entry-file requires a path'; entry_file=$2; shift 2 ;;
            --agent-identity) [[ ${2-} ]] || die_usage '--agent-identity requires a value'; agent_identity=$2; shift 2 ;;
            --repo-root) [[ ${2-} ]] || die_usage '--repo-root requires a path'; repo_root=$2; shift 2 ;;
            --gh-comment-script) [[ ${2-} ]] || die_usage '--gh-comment-script requires a path'; gh_comment_override=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -n $repo ]] || die_usage '--repo is required'
    [[ $repo =~ $SLUG_RE ]] || die_usage "--repo must look like OWNER/REPO, got: $repo"
    [[ -n $pr ]] || die_usage '--pr is required'
    require_uint '--pr' "$pr"
    [[ -n $comments ]] || die_usage '--comments is required'
    [[ -n $entry_file ]] || die_usage '--entry-file is required'
    [[ -n $agent_identity ]] || die_usage '--agent-identity is required'
    require_tools

    [[ -f $entry_file && ! -L $entry_file && -r $entry_file ]] ||
        evidence_unavailable "entry file is not a readable regular file: $entry_file"
    local entry
    entry=$(jq -c . "$entry_file" 2>/dev/null) ||
        evidence_unavailable "entry file is not valid JSON: $entry_file"
    jq -e "$ENTRY_SCHEMA_JQ" <<<"$entry" >/dev/null 2>&1 ||
        evidence_unavailable "entry does not match the ledger entry schema: $entry_file"
    # Defense in depth: a free-text field inside the entry (e.g. a bot's
    # "state", or a copied-forward "reaffirmed_from" sub-object) carrying the
    # literal fence markers would land inside the rendered ```json block and
    # could confuse a LATER read_ledger's non-greedy extraction regex into
    # stopping early. The rendered JSON is always machine-encoded (jq never
    # lets a marker escape its string quoting), so this can only ever matter
    # for the raw entry text before that encoding; reject it outright rather
    # than accept it and hope it round-trips.
    [[ $entry != *"$OPEN_MARKER"* && $entry != *"$CLOSE_MARKER"* ]] ||
        evidence_unavailable "entry must not contain a review-ledger fence marker: $entry_file"

    local gh_comment_script
    gh_comment_script=$(resolve_gh_comment_script "$gh_comment_override")

    local rc=0 out
    out=$(read_ledger "$comments") || rc=$?
    local comment_id='' ledger_json=''
    if ((rc == 11)); then
        ledger_json=$(jq -cn --argjson pr "$pr" --arg repo "$repo" --argjson entry "$entry" \
            '{version:1, pr:$pr, repo:$repo, reviews:[$entry]}')
    elif ((rc == 0)); then
        IFS=$'\t' read -r comment_id ledger_json <<<"$out"
        [[ $(jq -r '.repo' <<<"$ledger_json") == "$repo" && $(jq -r '.pr' <<<"$ledger_json") == "$pr" ]] ||
            evidence_unavailable 'existing ledger repo/pr does not match this call'
        ledger_json=$(jq -c --argjson entry "$entry" '.reviews += [$entry]' <<<"$ledger_json")
    else
        exit 1
    fi

    body_file=$(mktemp "${TMPDIR:-/tmp}/review-ledger.XXXXXXXXXX")
    chmod 600 -- "$body_file"
    trap 'rm -f -- "$body_file"' EXIT
    render_ledger_body "$ledger_json" "$agent_identity" >"$body_file"

    if [[ -n $comment_id ]]; then
        "$gh_comment_script" --pr "$pr" --repo "$repo" --update "$comment_id" --body-file "$body_file"
    else
        "$gh_comment_script" --pr "$pr" --repo "$repo" --body-file "$body_file"
    fi
}

main() {
    (($#)) || die_usage 'a subcommand is required: read, status, or append'
    local sub=$1
    shift
    case $sub in
        read) cmd_read "$@" ;;
        status) cmd_status "$@" ;;
        append) cmd_append "$@" ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown subcommand: $sub (expected read, status, or append)" ;;
    esac
}

main "$@"
