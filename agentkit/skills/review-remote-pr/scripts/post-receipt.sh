#!/usr/bin/env bash
#
# post-receipt.sh — the one-spend adversarial-review receipt: check whether a
# PR has already spent its receipt marker, and publish the receipt exactly
# once when it has not.
#
# This absorbs the "Spent-budget precheck" and "Adversarial-review receipt"
# recipes duplicated in review-remote-pr/SKILL.md and parallel-issues/SKILL.md
# so both skills call one tested command instead of copy-pasted shell.
#
# Subcommands:
#   precheck --comments FILE
#       Inspects the Step 1 pr_N_issue_comments.json artifact for the stable
#       spent marker. Prints exactly one word on stdout.
#         spent      marker found            -> exit 0
#         not-spent  marker provably absent  -> exit 10
#       A missing parser, unreadable artifact, or invalid JSON never reports
#       either word; it fails closed (see Exit status).
#
#   publish --pr N --repo OWNER/REPO --comments FILE
#           --provider S --model S --effort S
#           --mode cross-provider|blind-fallback [--mode-reason S]
#           --p1 N --p2 N
#           [--finding 'TITLE|fixed|SHAS'] [--finding 'TITLE|declined|RATIONALE'] ...
#           [--skip-rationale S --oracle S]
#           --agent-identity S
#       Renders the receipt body (agentic banner, agent-doc marker, the
#       "## Adversarial review receipt" section, exactly one spent marker,
#       agentic footer) into a private 0600 temp file and posts it through
#       the sibling gh-comment.sh, which byte-verifies the stored body. Runs
#       its own precheck against --comments first and refuses to double-spend.
#
# Exit status:
#   0   success (precheck: spent; publish: comment posted and verified)
#   1   evidence unavailable: jq missing, --comments missing/unreadable, or
#       its JSON is invalid -- OR the downstream gh-comment.sh post/verify
#       failed (nothing durable landed on the PR)
#   2   usage error (bad/missing arguments, malformed --finding, or the
#       sibling gh-comment.sh is missing)
#   10  precheck only: marker provably absent (not spent)
#   11  publish only: refused -- the receipt marker is already present
#
# Requires: bash >= 4.2, jq >= 1.6. publish additionally requires the sibling
# gh-comment.sh and everything it requires (gh, diff, cmp).

set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
readonly RECEIPT_MARKER='<!-- adversarial-review:spent -->'
readonly DOC_MARKER='<!-- review-remote-pr:agent-doc -->'
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
readonly UINT_RE='^(0|[1-9][0-9]*)$'
# Kept as codepoint escapes (bash's printf interprets \uXXXX/\UXXXXXXXX in the
# format string itself) so this source file stays ASCII -- only the rendered
# receipt body, which is data, carries the literal UTF-8 bytes.
EM_DASH=$(printf '\u2014')
readonly EM_DASH
ROBOT=$(printf '\U1F916')
readonly ROBOT

usage() {
    cat <<EOF
Usage: $PROGNAME precheck --comments FILE
       $PROGNAME publish --pr N --repo OWNER/REPO --comments FILE \\
                 --provider S --model S --effort S \\
                 --mode cross-provider|blind-fallback [--mode-reason S] \\
                 --p1 N --p2 N \\
                 [--finding 'TITLE|fixed|SHAS'] \\
                 [--finding 'TITLE|declined|RATIONALE'] ... \\
                 [--skip-rationale S --oracle S] \\
                 --agent-identity S

precheck: reports whether the PR's fetched comment artifact already carries
the stable adversarial-review spent marker.
  stdout 'spent'     and exit 0   marker found
  stdout 'not-spent' and exit 10  marker provably absent
  exit 1 (stderr only, fails closed) missing jq, unreadable FILE, invalid JSON

publish: renders the one-spend receipt and posts it via gh-comment.sh's
byte-verified transport. Runs the same precheck against --comments first and
refuses (exit 11) when the marker is already present.

Repeat --finding once per confirmed finding; omit it entirely for a clean
review (the receipt then records 'none confirmed'). --skip-rationale and
--oracle are optional and must be given together, for a verified trivial-diff
skip.

Exit status: see the script header comment.
EOF
}

die_usage() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    printf 'run "%s --help" for usage\n' "$PROGNAME" >&2
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

# Caller text lands verbatim in a durable audit comment, so it must not be able
# to forge that comment's structure. A field carrying a newline writes extra
# receipt lines of its own; a field carrying a reserved marker writes a second
# spend record, and the marker is the only durable evidence that the one-time
# review budget was consumed. Both are rejected loudly rather than escaped:
# a newline in a finding title is a caller bug, not content worth preserving.
reject_unsafe_field() {
    local flag=$1 value=$2
    [[ $value != *$'\n'* && $value != *$'\r'* ]] ||
        die_usage "$flag must not contain a line break"
    [[ $value != *"$RECEIPT_MARKER"* ]] ||
        die_usage "$flag must not contain the receipt marker $RECEIPT_MARKER"
    [[ $value != *"$DOC_MARKER"* ]] ||
        die_usage "$flag must not contain the agent-doc marker $DOC_MARKER"
}

# check_receipt_spent FILE
# Prints 'spent' and returns 0, prints 'not-spent' and returns 10, or prints
# nothing and returns 1 (message already sent to stderr by the caller's
# evidence_unavailable, or by this function for the jq/file checks it owns).
check_receipt_spent() {
    local file=$1
    command -v jq >/dev/null 2>&1 || {
        printf '%s\n' 'jq not found on PATH' >&2
        return 1
    }
    [[ -e $file ]] || {
        printf 'PR comment artifact does not exist: %s\n' "$file" >&2
        return 1
    }
    [[ -r $file ]] || {
        printf 'PR comment artifact is not readable: %s\n' "$file" >&2
        return 1
    }
    local jq_rc=0
    jq -e --arg marker "$RECEIPT_MARKER" \
        'any(.[]?; ((.body // "") | contains($marker)))' <"$file" >/dev/null || jq_rc=$?
    case $jq_rc in
        0)
            printf 'spent\n'
            return 0
            ;;
        1)
            printf 'not-spent\n'
            return 10
            ;;
        *)
            printf 'PR comment artifact is not valid JSON: %s\n' "$file" >&2
            return 1
            ;;
    esac
}

cmd_precheck() {
    local comments=''
    while (($#)); do
        case $1 in
            --comments)
                [[ ${2-} ]] || die_usage '--comments requires a path'
                comments=$2
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                die_usage "unknown argument: $1"
                ;;
        esac
    done
    [[ -n $comments ]] || die_usage '--comments is required'

    local rc=0
    local result
    result=$(check_receipt_spent "$comments") || rc=$?
    if ((rc != 0 && rc != 10)); then
        evidence_unavailable "receipt precheck could not read $comments"
    fi
    printf '%s\n' "$result"
    exit "$rc"
}

# --- publish -----------------------------------------------------------

PR=''
REPO=''
COMMENTS=''
PROVIDER=''
MODEL=''
EFFORT=''
MODE=''
MODE_REASON='n/a'
P1=''
P2=''
SKIP_RATIONALE=''
ORACLE=''
AGENT_IDENTITY=''
FINDINGS=()
GH_COMMENT_SCRIPT=''
# Global, not local to cmd_publish: an EXIT trap fires after the function that
# set it has returned, so a deferred '"$var"' expansion in the trap needs the
# variable to still be in scope at that point.
RECEIPT_BODY_FILE=''

parse_publish_args() {
    while (($#)); do
        case $1 in
            --pr) [[ ${2-} ]] || die_usage '--pr requires a value'; PR=$2; shift 2 ;;
            --repo) [[ ${2-} ]] || die_usage '--repo requires a value'; REPO=$2; shift 2 ;;
            --comments) [[ ${2-} ]] || die_usage '--comments requires a path'; COMMENTS=$2; shift 2 ;;
            --provider) [[ ${2-} ]] || die_usage '--provider requires a value'; PROVIDER=$2; shift 2 ;;
            --model) [[ ${2-} ]] || die_usage '--model requires a value'; MODEL=$2; shift 2 ;;
            --effort) [[ ${2-} ]] || die_usage '--effort requires a value'; EFFORT=$2; shift 2 ;;
            --mode) [[ ${2-} ]] || die_usage '--mode requires a value'; MODE=$2; shift 2 ;;
            --mode-reason) [[ ${2-} ]] || die_usage '--mode-reason requires a value'; MODE_REASON=$2; shift 2 ;;
            --p1) [[ ${2-} ]] || die_usage '--p1 requires a value'; P1=$2; shift 2 ;;
            --p2) [[ ${2-} ]] || die_usage '--p2 requires a value'; P2=$2; shift 2 ;;
            --finding) [[ ${2-} ]] || die_usage '--finding requires a value'; FINDINGS+=("$2"); shift 2 ;;
            --skip-rationale) [[ ${2-} ]] || die_usage '--skip-rationale requires a value'; SKIP_RATIONALE=$2; shift 2 ;;
            --oracle) [[ ${2-} ]] || die_usage '--oracle requires a value'; ORACLE=$2; shift 2 ;;
            --agent-identity) [[ ${2-} ]] || die_usage '--agent-identity requires a value'; AGENT_IDENTITY=$2; shift 2 ;;
            -h | --help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
}

validate_publish_args() {
    [[ -n $PR ]] || die_usage '--pr is required'
    require_uint '--pr' "$PR"
    [[ -n $REPO ]] || die_usage '--repo is required'
    [[ $REPO =~ $SLUG_RE ]] || die_usage "--repo must look like OWNER/REPO, got: $REPO"
    [[ -n $COMMENTS ]] || die_usage '--comments is required'
    [[ -n $PROVIDER ]] || die_usage '--provider is required'
    [[ -n $MODEL ]] || die_usage '--model is required'
    [[ -n $EFFORT ]] || die_usage '--effort is required'
    # Accept the human-prose spelling ("blind fallback") as well as the
    # canonical flag value: SKILL.md's receipt prose describes the mode in
    # words, and an agent following it verbatim would otherwise get die_usage
    # on the very first publish attempt. Normalize before use so the rendered
    # receipt body always records the canonical, hyphenated spelling.
    [[ $MODE != 'blind fallback' ]] || MODE='blind-fallback'
    [[ $MODE == cross-provider || $MODE == blind-fallback ]] ||
        die_usage "--mode must be cross-provider or blind-fallback, got: ${MODE:-<missing>}"
    [[ -n $P1 ]] || die_usage '--p1 is required'
    require_uint '--p1' "$P1"
    [[ -n $P2 ]] || die_usage '--p2 is required'
    require_uint '--p2' "$P2"
    [[ -n $AGENT_IDENTITY ]] || die_usage '--agent-identity is required'
    if [[ -n $SKIP_RATIONALE || -n $ORACLE ]]; then
        [[ -n $SKIP_RATIONALE && -n $ORACLE ]] ||
            die_usage '--skip-rationale and --oracle must be given together'
    fi
    # Every free-text field that reaches the rendered body. --finding is
    # checked per-field in render_finding_line, after it is split.
    reject_unsafe_field '--provider' "$PROVIDER"
    reject_unsafe_field '--model' "$MODEL"
    reject_unsafe_field '--effort' "$EFFORT"
    reject_unsafe_field '--mode-reason' "$MODE_REASON"
    reject_unsafe_field '--agent-identity' "$AGENT_IDENTITY"
    reject_unsafe_field '--skip-rationale' "$SKIP_RATIONALE"
    reject_unsafe_field '--oracle' "$ORACLE"
}

# Resolved lazily (publish only) so precheck never depends on dirname/pwd
# being reachable -- it has no sibling script to find.
resolve_gh_comment_script() {
    local here
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    GH_COMMENT_SCRIPT="$here/gh-comment.sh"
    [[ -x $GH_COMMENT_SCRIPT ]] ||
        die_usage "sibling gh-comment.sh not found or not executable: $GH_COMMENT_SCRIPT"
}

# render_finding_line 'TITLE|fixed|SHAS'  or  'TITLE|declined|RATIONALE'
render_finding_line() {
    local raw=$1 title verdict detail rest shas='' rationale=''
    title=${raw%%|*}
    rest=${raw#*|}
    [[ $rest != "$raw" ]] || die_usage "--finding must be TITLE|VERDICT|DETAIL, got: $raw"
    verdict=${rest%%|*}
    detail=${rest#*|}
    [[ $detail != "$rest" ]] || die_usage "--finding must be TITLE|VERDICT|DETAIL, got: $raw"
    [[ -n $title ]] || die_usage "--finding has an empty TITLE: $raw"
    [[ -n $detail ]] || die_usage "--finding has an empty DETAIL: $raw"
    case $verdict in
        fixed) shas=$detail ;;
        declined) rationale=$detail ;;
        *) die_usage "--finding VERDICT must be fixed or declined, got: $verdict ($raw)" ;;
    esac
    reject_unsafe_field '--finding TITLE' "$title"
    reject_unsafe_field '--finding DETAIL' "$detail"
    # printf arguments, never pattern substitution: in bash 5.2 an unquoted `&`
    # in a ${var//pat/repl} replacement expands to the matched text, so a title
    # like "R&D failure" rendered as "R__TITLE__D failure".
    printf -- '- Confirmed finding: %s %s verdict=%s; fix commit SHA(s)=%s; decline rationale=%s\n' \
        "$title" "$EM_DASH" "$verdict" "$shas" "$rationale"
}

render_findings_block() {
    if ((${#FINDINGS[@]} == 0)); then
        printf '%s\n' '- Confirmed finding: none confirmed'
        return 0
    fi
    local raw
    for raw in "${FINDINGS[@]}"; do
        render_finding_line "$raw"
    done
}

render_skip_line() {
    [[ -n $SKIP_RATIONALE ]] || return 0
    printf -- '- Verified-skip rationale: %s; mechanical oracle=%s\n' \
        "$SKIP_RATIONALE" "$ORACLE"
}

render_body() {
    local total=$((P1 + P2))
    printf 'This was written agentically; verify its assertions:\n'
    printf '%s\n' "$DOC_MARKER"
    printf '## Adversarial review receipt\n'
    printf -- '- Reviewer: provider=%s; model=%s; effort=%s; mode=%s (reason: %s)\n' \
        "$PROVIDER" "$MODEL" "$EFFORT" "$MODE" "$MODE_REASON"
    printf -- '- Counts: P1=%s; P2=%s; total=%s\n' "$P1" "$P2" "$total"
    render_findings_block
    render_skip_line
    printf '%s\n' "$RECEIPT_MARKER"
    printf '%s Co-authored by %s.\n' "$ROBOT" "$AGENT_IDENTITY"
}

cmd_publish() {
    parse_publish_args "$@"
    validate_publish_args
    resolve_gh_comment_script

    local rc=0
    local result
    result=$(check_receipt_spent "$COMMENTS") || rc=$?
    if ((rc == 0)); then
        printf '%s: receipt already spent for PR #%s\n' "$PROGNAME" "$PR" >&2
        exit 11
    elif ((rc != 10)); then
        evidence_unavailable "receipt precheck could not read $COMMENTS"
    fi

    RECEIPT_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/post-receipt.XXXXXXXXXX")
    chmod 600 -- "$RECEIPT_BODY_FILE"
    trap 'rm -f -- "$RECEIPT_BODY_FILE"' EXIT
    render_body >"$RECEIPT_BODY_FILE"

    "$GH_COMMENT_SCRIPT" --pr "$PR" --repo "$REPO" --body-file "$RECEIPT_BODY_FILE"
    record_spend
}

# The precheck above reads a snapshot fetched before this post existed, and
# nothing writes the result back. Without this, publishing twice against the
# same artifact -- the ordinary shape of a retry -- passes the guard both times
# and posts two durable receipts, so the advertised exit-11 exactly-once holds
# only against comments someone else re-fetched. Recording the posted body makes
# the guard true for the artifact this invocation was given.
#
# Not a substitute for ordering between concurrent publishers: two processes
# racing on the same PR can still interleave between the precheck and the post.
# The skills run this serially, and the durable marker means a later precheck
# against freshly fetched comments still refuses.
record_spend() {
    local tmp
    tmp=$(mktemp "$COMMENTS.XXXXXXXXXX") ||
        evidence_unavailable "cannot stage the spend record beside $COMMENTS"
    if jq --rawfile body "$RECEIPT_BODY_FILE" '. + [{id: null, body: $body}]' \
        "$COMMENTS" >"$tmp"; then
        chmod 600 -- "$tmp"
        mv -f -- "$tmp" "$COMMENTS" ||
            { rm -f -- "$tmp"; evidence_unavailable "cannot record the spend in $COMMENTS"; }
    else
        rm -f -- "$tmp"
        evidence_unavailable "cannot record the spend in $COMMENTS"
    fi
}

main() {
    (($#)) || die_usage 'a subcommand is required: precheck or publish'
    local sub=$1
    shift
    case $sub in
        precheck) cmd_precheck "$@" ;;
        publish) cmd_publish "$@" ;;
        -h | --help) usage; exit 0 ;;
        *) die_usage "unknown subcommand: $sub (expected precheck or publish)" ;;
    esac
}

main "$@"
