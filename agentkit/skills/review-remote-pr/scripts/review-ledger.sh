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
# Trust boundary: any PR commenter can post a well-formed fenced comment. A
# comment counts as THE ledger only when its author matches the trusted
# ledger identity, resolved once per invocation, in order:
#   1. --trusted-author LOGIN, when given.
#   2. the AGENT_LEDGER_AUTHOR key from .agent/config.env (via repo-config.sh,
#      --repo-root DIR required for this source to be consulted).
#   3. the REVIEW_LEDGER_VIEWER environment variable if set (a cache/override
#      for the next source, so tests and repeat callers need not hit the API);
#      otherwise the authenticated `gh api user --jq .login` identity.
# A comment from any other author that carries the fence is never treated as
# the ledger -- it is silently excluded from every count/read/verdict, and
# its presence is reported as a warning on stderr (never fatal, never a
# reason to block) so an operator can see a forgery was ignored. If no
# trusted identity resolves at all (no flag, no config, gh absent or
# unauthenticated), the call fails closed with evidence-unavailable: without
# a trust boundary there is no safe way to say what the ledger even is.
#
# Subcommands:
#   read   --repo OWNER/REPO --pr N --comments FILE
#          [--trusted-author LOGIN] [--repo-root DIR]
#       Extracts and validates the ledger from an already-fetched
#       pr_N_issue_comments.json-shaped artifact. On success prints
#       "comment_id=ID" then the ledger's canonical compact JSON, and exits 0.
#
#   status --repo OWNER/REPO --pr N --comments FILE --head SHA
#          [--diff-payload ID] [--kind adversarial|bot] [--provider NAME]
#          [--trusted-author LOGIN] [--repo-root DIR]
#       Prints exactly one verdict word. Zero network calls: it only reads
#       --comments (--repo-root is a local git check, not a network call).
#       See the exit-status table below.
#
#   append --repo OWNER/REPO --pr N --comments FILE --entry-file FILE
#          --agent-identity NAME [--trusted-author LOGIN] [--repo-root DIR]
#          [--gh-comment-script PATH]
#       Validates the one new entry in --entry-file, appends it to the
#       TRUSTED author's ledger found via read (or starts a fresh comment
#       when the trusted author has none yet -- a forged comment from
#       another author is never updated), renders the one-comment body, and
#       posts/updates it through the sibling gh-comment.sh, which byte-
#       verifies the stored body. --entry-file carries a single JSON object
#       shaped like one element of "reviews" in the schema below (kind,
#       head_sha, provider are always required; the remaining fields are
#       carried through verbatim).
#
#   cover --repo OWNER/REPO --pr N --comments FILE --head SHA
#          --reason (fix:ID|merge-down:SHA|retarget:REF)
#          [--kind adversarial|bot] [--provider NAME] [--agent-identity NAME]
#          [--trusted-author LOGIN] [--repo-root DIR] [--gh-comment-script PATH]
#       Append-only lineage extension (issue #567): a receipt is written ONCE
#       at publish time (post-receipt.sh), but a later fix commit, merge-down,
#       or retarget still needs to be provably the SAME reviewed tree plus a
#       recorded, ancestry-proven transition -- never a second review spend.
#       Finds the LATEST review entry matching --kind/--provider (unfiltered
#       when omitted) in the TRUSTED ledger, requires --head to be a PROVEN
#       git descendant of that entry's head_sha (via --repo-root; "unknown"
#       reachability, like every other read in this script, never counts),
#       then extends its covered_heads with --head and appends
#       {sha, reason, covered_at} to a sibling "coverage" array on that same
#       entry, so provenance stays auditable. --head already covered is a
#       silent no-op (prints "already-covered", exit 0, no post). Posts/
#       updates the ledger comment exactly like append.
#
# status verdicts:
#   covered-head   an entry's head_sha or covered_heads includes --head exit 0
#   covered-lineage review head is an ancestor and every intervening commit
#                  is explicitly recorded in covered_heads              exit 0
#   covered-diff   head_sha differs but diff_payload matches (the tree
#                  under review is byte-identical) on AT LEAST ONE matching
#                  entry whose head_sha is PROVEN (via --repo-root; "unknown"
#                  reachability never counts) an ancestor of --head --
#                  requires --diff-payload on the call AND a non-empty
#                  diff_payload on that entry                               exit 0
#   stale          entries exist for the --kind/--provider filter, but
#                  neither head nor a proven-ancestor diff match -- e.g. no
#                  matching diff_payload entry, every matching entry's
#                  head_sha is proven unreachable (a force-push rewrote
#                  history), or reachability could not be proven at all      exit 10
#   absent         no ledger, or no entry for this kind/provider           exit 11
#   (nothing)      ledger present but unparseable/fence malformed -- BLOCKS,
#                  never read as absent                                    exit 1
#
# Exit status (all subcommands):
#   0   success (read: ledger found & valid; status: covered-*; append: posted;
#       cover: extended, or --head already covered)
#   1   evidence unavailable / present-but-unparseable ledger (fails closed)
#   2   usage error
#   10  status only: stale
#   11  read/status/cover: absent (no ledger, or no matching entry)
#   12  cover only: refused -- --head is not a PROVEN descendant of the
#       matching entry's head_sha
#
# Requires: bash >= 4.2, jq >= 1.6. append/cover additionally require the
# sibling gh-comment.sh and everything it requires (gh, diff, cmp).
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
readonly REPO_CONFIG_SH="$SCRIPT_DIR/../../.shared/scripts/repo-config.sh"
GH_BIN=${REVIEW_LEDGER_GH:-gh}

usage() {
    cat <<EOF
Usage: $PROGNAME read   --repo OWNER/REPO --pr N --comments FILE
                 [--trusted-author LOGIN] [--repo-root DIR]
       $PROGNAME status --repo OWNER/REPO --pr N --comments FILE --head SHA
                 [--diff-payload ID] [--kind adversarial|bot] [--provider NAME]
                 [--trusted-author LOGIN] [--repo-root DIR]
       $PROGNAME append --repo OWNER/REPO --pr N --comments FILE \\
                 --entry-file FILE --agent-identity NAME \\
                 [--trusted-author LOGIN] [--repo-root DIR] [--gh-comment-script PATH]
       $PROGNAME cover  --repo OWNER/REPO --pr N --comments FILE --head SHA \\
                 --reason (fix:ID|merge-down:SHA|retarget:REF) \\
                 [--kind adversarial|bot] [--provider NAME] [--agent-identity NAME] \\
                 [--trusted-author LOGIN] [--repo-root DIR] [--gh-comment-script PATH]

See the script header comment for the full contract, trust-boundary
resolution order, and exit-status table.
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

# resolve_trusted_author FLAG_VALUE REPO_ROOT -- the ledger's trust boundary
# (root review finding F1). Prints the trusted login and returns 0, or
# returns 1 with nothing printed when no source resolves. Order:
#   1. FLAG_VALUE (--trusted-author), when non-empty.
#   2. AGENT_LEDGER_AUTHOR from .agent/config.env, via repo-config.sh, only
#      when REPO_ROOT is non-empty and the resolver is executable. A key
#      repo-config.sh does not (yet) recognize as accepted degrades to
#      "not declared" here exactly like every other undeclared value in this
#      codebase -- never a hard failure on its own, since sources 3/4 still
#      apply.
#   3. REVIEW_LEDGER_VIEWER, if set -- a cache/override for source 4, so a
#      test or a repeat caller in one process need not re-hit the API.
#   4. `gh api user --jq .login`, one call, the authenticated identity.
resolve_trusted_author() {
    local flag_value=$1 repo_root=$2
    [[ -z $flag_value ]] || {
        printf '%s\n' "$flag_value"
        return 0
    }
    if [[ -n $repo_root && -x $REPO_CONFIG_SH ]]; then
        local declared
        if declared=$("$REPO_CONFIG_SH" --repo-root "$repo_root" --get AGENT_LEDGER_AUTHOR 2>/dev/null) &&
            [[ -n $declared ]]; then
            printf '%s\n' "$declared"
            return 0
        fi
    fi
    [[ -z ${REVIEW_LEDGER_VIEWER:-} ]] || {
        printf '%s\n' "$REVIEW_LEDGER_VIEWER"
        return 0
    }
    command -v "$GH_BIN" >/dev/null 2>&1 || return 1
    local login
    login=$("$GH_BIN" api user --jq .login 2>/dev/null) || return 1
    [[ -n $login ]] || return 1
    printf '%s\n' "$login"
    return 0
}

# jq filter validating one complete ledger document. kind/head_sha/provider
# are the only fields every consumer relies on; everything else is carried
# through verbatim (per-kind fields differ -- adversarial vs bot). The
# optional "coverage" array (issue #567's cover subcommand) is the auditable
# {sha, reason, covered_at} provenance for each covered_heads extension --
# kept in lockstep with the identical block in ENTRY_SCHEMA_JQ below.
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
    ((has("diff_payload") | not) or (.diff_payload | type) == "string") and
    ((has("covered_heads") | not) or
      ((.covered_heads | type) == "array") and
      all(.covered_heads[]; type == "string" and test("^[0-9a-f]{7,40}$"))) and
    ((has("coverage") | not) or
      ((.coverage | type) == "array") and
      all(.coverage[];
        type == "object" and
        (.sha | type) == "string" and (.sha | test("^[0-9a-f]{7,40}$")) and
        (.reason | type) == "string" and
        (.reason | test("^(fix|merge-down|retarget):[A-Za-z0-9._/-]+$")) and
        (.covered_at | type) == "string" and (.covered_at | length) > 0)))
'

# jq filter validating one NEW entry (a single object, same per-entry shape
# as above). Kept separate from LEDGER_SCHEMA_JQ so a malformed existing
# ledger and a malformed new entry are reported distinctly.
readonly ENTRY_SCHEMA_JQ='
  type == "object" and
  (.kind == "adversarial" or .kind == "bot") and
  (.head_sha | type) == "string" and (.head_sha | test("^[0-9a-f]{7,40}$")) and
  (.provider | type) == "string" and (.provider | length) > 0 and
  ((has("diff_payload") | not) or (.diff_payload | type) == "string") and
  ((has("covered_heads") | not) or
    ((.covered_heads | type) == "array") and
    all(.covered_heads[]; type == "string" and test("^[0-9a-f]{7,40}$"))) and
  ((has("coverage") | not) or
    ((.coverage | type) == "array") and
    all(.coverage[];
      type == "object" and
      (.sha | type) == "string" and (.sha | test("^[0-9a-f]{7,40}$")) and
      (.reason | type) == "string" and
      (.reason | test("^(fix|merge-down|retarget):[A-Za-z0-9._/-]+$")) and
      (.covered_at | type) == "string" and (.covered_at | length) > 0))
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

# find_ledger_comments FILE AUTHOR -- prints "ID\tJSON_TEXT" for every
# TRUSTED-AUTHOR comment body whose fence parses (json text possibly still
# schema-invalid; that is checked by the caller). A body carrying the
# markers but no parseable fenced json, or authored by anyone other than
# AUTHOR, is silently skipped here -- the caller's zero-vs-one-vs-many
# accounting over ALL trusted-author marker-carrying bodies
# (count_marker_comments) is what actually distinguishes "absent" from
# "malformed"; untrusted-author bodies are reported separately, as a
# warning, by untrusted_marker_authors.
# The captured json field is base64-encoded before joining into the @tsv row:
# @tsv escapes embedded newlines/tabs as literal backslash-n/backslash-t
# sequences rather than real control characters, and a pretty-printed JSON
# document is full of structural newlines. Read back through `read` (which
# does not un-escape @tsv's backslash sequences) those would land in the
# "json" field as literal backslash-n text -- outside any JSON string, so
# jq then refuses to parse it. Base64 has no embedded tabs/newlines at all,
# so it round-trips through @tsv and `read` unchanged.
find_ledger_comments() {
    local file=$1 author=$2 regex
    regex=$(ledger_fence_regex)
    jq -r --arg re "$regex" --arg author "$author" '
      .[]? |
      select(((.body // "") | test($re))) |
      select((((.user.login // "") | ascii_downcase)) == ($author | ascii_downcase)) |
      [(.id // "" | tostring), ((.body // "") | capture($re).json | @base64)] | @tsv
    ' "$file" 2>/dev/null
}

# Count of TRUSTED-AUTHOR comments carrying BOTH markers, regardless of
# whether the fenced content between them parses. Used only to tell "no
# trusted ledger comment at all" (0) apart from "a trusted ledger comment
# exists but its fence/JSON is broken" (>=1 trusted marker-carrying comments
# but find_ledger_comments returned fewer rows).
count_marker_comments() {
    local file=$1 author=$2
    jq -r --arg open "$OPEN_MARKER" --arg close "$CLOSE_MARKER" --arg author "$author" '
      [.[]? | select(((.body // "") | contains($open)) and ((.body // "") | contains($close))) |
        select((((.user.login // "") | ascii_downcase)) == ($author | ascii_downcase))] | length
    ' "$file" 2>/dev/null
}

# untrusted_marker_authors FILE AUTHOR -- prints a comma-joined, deduplicated
# list of the (as-recorded) logins of every OTHER commenter who posted a
# fence-carrying comment, or an empty string when there are none. Purely for
# the stderr warning read_ledger prints -- it never affects any verdict.
untrusted_marker_authors() {
    local file=$1 author=$2
    jq -r --arg open "$OPEN_MARKER" --arg close "$CLOSE_MARKER" --arg author "$author" '
      [.[]? | select(((.body // "") | contains($open)) and ((.body // "") | contains($close))) |
        select((((.user.login // "") | ascii_downcase)) != ($author | ascii_downcase)) |
        (.user.login // "unknown")] | unique | join(",")
    ' "$file" 2>/dev/null
}

# read_ledger FILE AUTHOR -- on success prints "ID\t<compact JSON>" to
# stdout and returns 0, considering only comments whose author is AUTHOR (the
# resolved trusted ledger identity; see resolve_trusted_author). Returns 11
# with nothing printed when there is no TRUSTED ledger comment at all (a
# forged comment from another author does not count, and is reported as a
# warning on stderr instead). Returns 1 with nothing printed on stdout
# (message on stderr) when a trusted ledger comment exists but is
# unparseable/schema-invalid, or when more than one TRUSTED comment carries
# the fence (the "exactly one ledger comment" invariant broken) -- fail-
# closed per spec rule 1: never read a broken ledger as absent.
read_ledger() {
    local file=$1 author=$2 marker_count rows row_count id json
    [[ -f $file && -r $file ]] || evidence_unavailable "comments artifact is not a readable file: $file"
    jq -e 'type == "array"' "$file" >/dev/null 2>&1 ||
        evidence_unavailable "comments artifact is not valid JSON: $file"

    local ignored ignored_count
    ignored=$(untrusted_marker_authors "$file" "$author") || ignored=''
    if [[ -n $ignored ]]; then
        ignored_count=$(($(tr -cd ',' <<<"$ignored" | wc -c) + 1))
        printf '%s: ignored %s review-ledger fence(s) from untrusted author(s): %s\n' \
            "$PROGNAME" "$ignored_count" "$ignored" >&2
    fi

    marker_count=$(count_marker_comments "$file" "$author") || marker_count=0
    [[ $marker_count =~ ^[0-9]+$ ]] || marker_count=0
    if ((marker_count == 0)); then
        return 11
    fi

    rows=$(find_ledger_comments "$file" "$author") || rows=''
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
    local repo='' pr='' comments='' trusted_author_flag='' repo_root=''
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
            --repo) [[ ${2-} ]] || die_usage '--repo requires a value'; repo=$2; shift 2 ;;
            --pr) [[ ${2-} ]] || die_usage '--pr requires a value'; pr=$2; shift 2 ;;
            --comments) [[ ${2-} ]] || die_usage '--comments requires a path'; comments=$2; shift 2 ;;
            --trusted-author) [[ ${2-} ]] || die_usage '--trusted-author requires a value'; trusted_author_flag=$2; shift 2 ;;
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
    require_tools

    local author
    author=$(resolve_trusted_author "$trusted_author_flag" "$repo_root") ||
        evidence_unavailable 'no trusted ledger author identity could be resolved (--trusted-author, AGENT_LEDGER_AUTHOR, or an authenticated gh login)'

    local rc=0 out
    out=$(read_ledger "$comments" "$author") || rc=$?
    if ((rc == 11)); then
        printf '%s: no review-ledger comment found for PR #%s from trusted author %s\n' \
            "$PROGNAME" "$pr" "$author" >&2
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
    local repo='' pr='' comments='' head='' diff_payload='' kind='' provider='' repo_root='' trusted_author_flag=''
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
            --repo) [[ ${2-} ]] || die_usage '--repo requires a value'; repo=$2; shift 2 ;;
            --pr) [[ ${2-} ]] || die_usage '--pr requires a value'; pr=$2; shift 2 ;;
            --comments) [[ ${2-} ]] || die_usage '--comments requires a path'; comments=$2; shift 2 ;;
            --head) [[ ${2-} ]] || die_usage '--head requires a value'; head=$2; shift 2 ;;
            --diff-payload) [[ ${2-} ]] || die_usage '--diff-payload requires a value'; diff_payload=$2; shift 2 ;;
            --kind) [[ ${2-} ]] || die_usage '--kind requires a value'; kind=$2; shift 2 ;;
            --provider) [[ ${2-} ]] || die_usage '--provider requires a value'; provider=$2; shift 2 ;;
            --repo-root) [[ ${2-} ]] || die_usage '--repo-root requires a path'; repo_root=$2; shift 2 ;;
            --trusted-author) [[ ${2-} ]] || die_usage '--trusted-author requires a value'; trusted_author_flag=$2; shift 2 ;;
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

    local author
    author=$(resolve_trusted_author "$trusted_author_flag" "$repo_root") ||
        evidence_unavailable 'no trusted ledger author identity could be resolved (--trusted-author, AGENT_LEDGER_AUTHOR, or an authenticated gh login)'

    local rc=0 out
    out=$(read_ledger "$comments" "$author") || rc=$?
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

    # A receipt may be posted before a mechanically-required fix or merge-down
    # advances the PR. Those transitions are recorded append-only in the
    # review entry's covered_heads set. A current head in that set is an exact
    # coverage match, even though the original review head remains head_sha.
    if jq -e --arg head "$head" \
        'any(.[]; ((.covered_heads // []) | index($head)) != null)' \
        <<<"$candidates" >/dev/null 2>&1; then
        printf 'covered-head\n'
        exit 0
    fi

    # A covered lineage is stronger than a matching diff payload: it proves
    # locally that the review head reaches the requested head and that every
    # intervening fix/merge-down commit was recorded by the workflow. Include
    # the current tip in that check: a tip produced by a fix or merge-down is
    # itself a transition that must be recorded in covered_heads.
    local lineage_unknown=0 lineage_candidate_count=0
    local i entry entry_head covered_heads reach commits missing
    local candidate_count
    candidate_count=$(jq 'length' <<<"$candidates") || candidate_count=0
    for ((i = 0; i < candidate_count; i++)); do
        entry=$(jq -c ".[$i]" <<<"$candidates") || continue
        entry_head=$(jq -r '.head_sha' <<<"$entry") || continue
        covered_heads=$(jq -c '.covered_heads // []' <<<"$entry") || continue
        [[ $covered_heads != '[]' ]] || continue
        reach=$(git_ancestor "$entry_head" "$head" "$repo_root")
        if [[ $reach == unknown ]]; then
            lineage_unknown=1
            continue
        fi
        [[ $reach == yes ]] || continue
        commits=$(git -C "$repo_root" rev-list --reverse "$entry_head..$head" 2>/dev/null) || continue
        missing=$(while IFS= read -r commit; do
            jq -e --arg commit "$commit" 'index($commit) != null' <<<"$covered_heads" \
                >/dev/null 2>&1 || printf '%s\n' "$commit"
        done <<<"$commits")
        if [[ -z $missing ]]; then
            printf 'covered-lineage\n'
            exit 0
        fi
        printf '%s: uncovered-head=%s commits-between=%s\n' "$PROGNAME" "$head" \
            "${missing//$'\n'/,}" >&2
        lineage_candidate_count=$((lineage_candidate_count + 1))
    done
    if [[ -n $diff_payload ]]; then
        local matches match_count
        matches=$(jq -c --arg dp "$diff_payload" \
            '[.[] | select((.diff_payload // "") == $dp and (.diff_payload // "") != "")]' \
            <<<"$candidates") || matches='[]'
        match_count=$(jq 'length' <<<"$matches" 2>/dev/null) || match_count=0
        [[ $match_count =~ ^[0-9]+$ ]] || match_count=0

        # Root review finding F2: `first` on the diff_payload matches let an
        # OLDER, force-pushed (non-ancestor) entry shadow a LATER entry with
        # the same payload that IS a proven ancestor, reporting stale for a
        # tree that genuinely is covered. Every matching entry is checked in
        # turn now; any single proven ancestor is sufficient to pass.
        local any_unknown=0 i entry entry_head reach
        for ((i = 0; i < match_count; i++)); do
            entry=$(jq -c ".[$i]" <<<"$matches")
            entry_head=$(jq -r '.head_sha' <<<"$entry")
            reach=$(git_ancestor "$entry_head" "$head" "$repo_root")
            # Root review finding F1 (fail-closed rule 5): reachability must
            # be POSITIVELY PROVEN, not merely "not disproven". Treating
            # "unknown" (no --repo-root, git absent, or an object simply not
            # present locally) as good enough silently accepted a covered-
            # diff verdict with NO ancestry evidence at all -- exactly the
            # force-push case rule 5 exists to catch, just with the check
            # never actually run. Only reach=yes may pass.
            if [[ $reach == yes ]]; then
                printf 'covered-diff\n'
                exit 0
            fi
            [[ $reach != unknown ]] || any_unknown=1
        done
        if ((any_unknown)); then
            printf '%s: reachability of one or more diff-payload-matching entries could not be proven (pass --repo-root to prove ancestry); reporting stale rather than covered-diff\n' \
                "$PROGNAME" >&2
        fi
    fi

    # A matching diff payload can cover an advanced tree only after its review
    # head is proven reachable. Therefore defer the uncovered-lineage refusal
    # until after the diff-payload path above has had a chance to establish
    # that stronger proof.
    if ((lineage_unknown)); then
        printf '%s: covered lineage reachability could not be proven; reporting stale\n' \
            "$PROGNAME" >&2
    fi
    ((lineage_candidate_count > 0)) && {
        printf 'stale\n'
        exit 10
    }

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
    local repo='' pr='' comments='' entry_file='' agent_identity='' repo_root='' gh_comment_override='' trusted_author_flag=''
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
            --repo) [[ ${2-} ]] || die_usage '--repo requires a value'; repo=$2; shift 2 ;;
            --pr) [[ ${2-} ]] || die_usage '--pr requires a value'; pr=$2; shift 2 ;;
            --comments) [[ ${2-} ]] || die_usage '--comments requires a path'; comments=$2; shift 2 ;;
            --entry-file) [[ ${2-} ]] || die_usage '--entry-file requires a path'; entry_file=$2; shift 2 ;;
            --agent-identity) [[ ${2-} ]] || die_usage '--agent-identity requires a value'; agent_identity=$2; shift 2 ;;
            --repo-root) [[ ${2-} ]] || die_usage '--repo-root requires a path'; repo_root=$2; shift 2 ;;
            --gh-comment-script) [[ ${2-} ]] || die_usage '--gh-comment-script requires a path'; gh_comment_override=$2; shift 2 ;;
            --trusted-author) [[ ${2-} ]] || die_usage '--trusted-author requires a value'; trusted_author_flag=$2; shift 2 ;;
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

    local author
    author=$(resolve_trusted_author "$trusted_author_flag" "$repo_root") ||
        evidence_unavailable 'no trusted ledger author identity could be resolved (--trusted-author, AGENT_LEDGER_AUTHOR, or an authenticated gh login)'

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
    out=$(read_ledger "$comments" "$author") || rc=$?
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

# cmd_cover -- issue #567: append-only extension of the latest matching
# review entry's covered_heads, proving --head is a git descendant of that
# entry's head_sha before recording it. See the script header comment for
# the full contract.
readonly REASON_RE='^(fix|merge-down|retarget):[A-Za-z0-9._/-]+$'

cmd_cover() {
    # body_file is deliberately NOT local -- see the identical note on
    # cmd_append's own body_file: the EXIT trap fires after this function
    # returns and needs the variable to still be in scope then.
    body_file=''
    local repo='' pr='' comments='' head='' reason='' kind='' provider='' \
        agent_identity='' repo_root='' trusted_author_flag='' gh_comment_override=''
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
            --repo) [[ ${2-} ]] || die_usage '--repo requires a value'; repo=$2; shift 2 ;;
            --pr) [[ ${2-} ]] || die_usage '--pr requires a value'; pr=$2; shift 2 ;;
            --comments) [[ ${2-} ]] || die_usage '--comments requires a path'; comments=$2; shift 2 ;;
            --head) [[ ${2-} ]] || die_usage '--head requires a value'; head=$2; shift 2 ;;
            --reason) [[ ${2-} ]] || die_usage '--reason requires a value'; reason=$2; shift 2 ;;
            --kind) [[ ${2-} ]] || die_usage '--kind requires a value'; kind=$2; shift 2 ;;
            --provider) [[ ${2-} ]] || die_usage '--provider requires a value'; provider=$2; shift 2 ;;
            --agent-identity) [[ ${2-} ]] || die_usage '--agent-identity requires a value'; agent_identity=$2; shift 2 ;;
            --repo-root) [[ ${2-} ]] || die_usage '--repo-root requires a path'; repo_root=$2; shift 2 ;;
            --trusted-author) [[ ${2-} ]] || die_usage '--trusted-author requires a value'; trusted_author_flag=$2; shift 2 ;;
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
    [[ -n $head ]] || die_usage '--head is required'
    [[ $head =~ $SHA_RE ]] || die_usage "--head must look like a git SHA, got: $head"
    [[ -n $reason ]] || die_usage '--reason is required'
    [[ $reason =~ $REASON_RE ]] ||
        die_usage "--reason must look like fix:<finding-id>, merge-down:<base-sha>, or retarget:<old-base>, got: $reason"
    [[ -z $kind || $kind == adversarial || $kind == bot ]] ||
        die_usage "--kind must be adversarial or bot, got: $kind"
    [[ -n $agent_identity ]] || agent_identity='agentkit review-ledger cover'
    require_tools

    local author
    author=$(resolve_trusted_author "$trusted_author_flag" "$repo_root") ||
        evidence_unavailable 'no trusted ledger author identity could be resolved (--trusted-author, AGENT_LEDGER_AUTHOR, or an authenticated gh login)'

    local rc=0 out
    out=$(read_ledger "$comments" "$author") || rc=$?
    if ((rc == 11)); then
        printf '%s: no review-ledger comment found for PR #%s from trusted author %s; nothing to cover\n' \
            "$PROGNAME" "$pr" "$author" >&2
        exit 11
    elif ((rc != 0)); then
        exit 1
    fi
    local comment_id ledger_json
    IFS=$'\t' read -r comment_id ledger_json <<<"$out"
    [[ $(jq -r '.repo' <<<"$ledger_json") == "$repo" && $(jq -r '.pr' <<<"$ledger_json") == "$pr" ]] ||
        evidence_unavailable 'existing ledger repo/pr does not match this call'

    # The LATEST entry (last in append-only array order) matching the
    # optional kind/provider filter is the one this SHA extends -- mirrors
    # cmd_status's own candidate filtering.
    local candidates candidate_count
    candidates=$(jq -c --arg kind "$kind" --arg provider "$provider" '
      [range(0; (.reviews | length)) as $i | .reviews[$i] |
        select(($kind == "") or (.kind == $kind)) |
        select(($provider == "") or (.provider == $provider)) |
        {index: $i, head_sha, covered_heads: (.covered_heads // []),
         coverage: (.coverage // [])}]
    ' <<<"$ledger_json") || evidence_unavailable 'could not filter ledger entries'
    candidate_count=$(jq 'length' <<<"$candidates") || candidate_count=0
    if [[ $candidate_count == 0 ]]; then
        printf '%s: no review entry matches this cover call for PR #%s; nothing to extend\n' \
            "$PROGNAME" "$pr" >&2
        exit 11
    fi

    local target target_index target_head
    target=$(jq -c '.[-1]' <<<"$candidates")
    target_index=$(jq -r '.index' <<<"$target")
    target_head=$(jq -r '.head_sha' <<<"$target")

    # Idempotence keys on the (sha, reason) PAIR, not the sha alone (fix
    # batch #2 F2): the ordinary retarget case covers an UNCHANGED head under
    # a NEW base, so keying on sha alone would silently drop that retarget's
    # own coverage/audit record as a same-sha no-op. A sha already recorded
    # (as the review head itself, or already in covered_heads) with this
    # exact reason already logged is a true no-op; a sha already recorded
    # but under a reason not yet logged still needs its coverage event
    # appended (covered_heads itself stays a no-op there via `unique` below).
    local sha_covered=0 reason_recorded=0
    if [[ $target_head == "$head" ]] ||
        jq -e --arg head "$head" '(.covered_heads // []) | index($head) != null' <<<"$target" >/dev/null 2>&1; then
        sha_covered=1
    fi
    if jq -e --arg head "$head" --arg reason "$reason" \
        'any((.coverage // [])[]; .sha == $head and .reason == $reason)' \
        <<<"$target" >/dev/null 2>&1; then
        reason_recorded=1
    fi
    if ((sha_covered)) && ((reason_recorded)); then
        printf 'already-covered\n'
        exit 0
    fi

    if ((sha_covered == 0)); then
        # Fail-closed exactly like cmd_status's force-push demotion, but
        # extended per fix batch #2 F1: ancestry must be proven against the
        # ENTIRE covered frontier -- the entry's original head_sha AND every
        # SHA already recorded in its covered_heads -- not head_sha alone.
        # Otherwise a force-push to C, a SIBLING child of head_sha that
        # drops an already-covered fix commit B, would still pass purely
        # because C descends from head_sha, even though C's history silently
        # discards B's reviewed lineage. Only reach=yes may pass for every
        # frontier SHA; "unknown" (no --repo-root, git absent, or the object
        # simply not present locally) never counts as proof.
        local frontier frontier_count i sha reach
        frontier=$(jq -c '([.head_sha] + (.covered_heads // [])) | unique' <<<"$target")
        frontier_count=$(jq 'length' <<<"$frontier") || frontier_count=0
        for ((i = 0; i < frontier_count; i++)); do
            sha=$(jq -r ".[$i]" <<<"$frontier")
            reach=$(git_ancestor "$sha" "$head" "$repo_root")
            if [[ $reach != yes ]]; then
                printf '%s: refused: %s is not a proven descendant of %s (reachability=%s); pass --repo-root to prove ancestry\n' \
                    "$PROGNAME" "$head" "$sha" "$reach" >&2
                exit 12
            fi
        done
    fi

    local covered_at
    covered_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local updated_json
    updated_json=$(jq -c --argjson idx "$target_index" --arg head "$head" \
        --arg reason "$reason" --arg at "$covered_at" '
      .reviews[$idx].covered_heads =
        (((.reviews[$idx].covered_heads // []) + [$head]) | unique) |
      .reviews[$idx].coverage =
        ((.reviews[$idx].coverage // []) + [{sha: $head, reason: $reason, covered_at: $at}])
    ' <<<"$ledger_json") || evidence_unavailable 'could not encode the extended ledger entry'
    jq -e "$LEDGER_SCHEMA_JQ" <<<"$updated_json" >/dev/null 2>&1 ||
        evidence_unavailable 'extended ledger does not match the ledger schema'

    local gh_comment_script
    gh_comment_script=$(resolve_gh_comment_script "$gh_comment_override")

    body_file=$(mktemp "${TMPDIR:-/tmp}/review-ledger.XXXXXXXXXX")
    chmod 600 -- "$body_file"
    trap 'rm -f -- "$body_file"' EXIT
    render_ledger_body "$updated_json" "$agent_identity" >"$body_file"
    "$gh_comment_script" --pr "$pr" --repo "$repo" --update "$comment_id" --body-file "$body_file"
}

main() {
    (($#)) || die_usage 'a subcommand is required: read, status, append, or cover'
    local sub=$1
    shift
    case $sub in
        read) cmd_read "$@" ;;
        status) cmd_status "$@" ;;
        append) cmd_append "$@" ;;
        cover) cmd_cover "$@" ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown subcommand: $sub (expected read, status, append, or cover)" ;;
    esac
}

main "$@"
