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
#   publish --pr N --repo OWNER/REPO --comments FILE --findings-file FILE
#           --provider S --model S --effort S
#           --mode cross-provider|blind-fallback [--mode-reason S]
#           --p1 N --p2 N
#           [--skip-rationale S --oracle S]
#           --agent-identity S [--require-pushed]
#       Renders the receipt body (agentic banner, agent-doc marker, the
#       "## Adversarial review receipt" section, exactly one spent marker,
#       agentic footer) from the validated NDJSON findings ledger into a private
#       0600 temp file and posts it through the sibling gh-comment.sh, which
#       byte-verifies the stored body. Runs its own precheck against --comments
#       first and refuses to double-spend.
#
# Exit status:
#   0   success (precheck: spent; publish: comment posted and verified)
#   1   evidence unavailable: jq missing, --comments/findings-file
#       missing/unreadable/invalid, live recovery unavailable, or the
#       downstream gh-comment.sh post/verify failed with no recovered marker
#   2   usage error (bad/missing arguments or the sibling gh-comment.sh is
#       missing)
#   10  precheck only: marker provably absent (not spent)
#   11  publish only: refused -- the receipt marker is already present
#   12  publish only: --require-pushed refused a dirty or unpushed tree
#   13  publish only: the findings pipeline is out of order
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
# Keep the source ASCII; jq renders the codepoint in the durable body.
ROBOT=$(printf '\U1F916')
readonly ROBOT

usage() {
    cat <<EOF
Usage: $PROGNAME precheck --comments FILE
       $PROGNAME --require-pushed publish ...
       $PROGNAME publish --pr N --repo OWNER/REPO --comments FILE \\
                 --findings-file FILE \\
                 --provider S --model S --effort S \\
                 --mode cross-provider|blind-fallback [--mode-reason S] \\
                 --p1 N --p2 N \\
                 [--skip-rationale S --oracle S] \\
                 --agent-identity S [--require-pushed]

precheck: reports whether the PR's fetched comment artifact already carries
the stable adversarial-review spent marker.
  stdout 'spent'     and exit 0   marker found
  stdout 'not-spent' and exit 10  marker provably absent
  exit 1 (stderr only, fails closed) missing jq, unreadable FILE, invalid JSON

publish: validates the NDJSON findings ledger, renders the one-spend receipt,
and posts it via gh-comment.sh's byte-verified transport. Runs the same
precheck against --comments first and refuses (exit 11) when the marker is
already present. --require-pushed additionally requires a clean tree whose HEAD
is reachable from an origin/* remote-tracking ref.

Capability probes are not receipts: probe invocations send only a synthetic
snippet, no PR diff, and never count against the one-review-per-PR budget.
Probe mode is rejected before any receipt transport.

The findings file is one JSON record per line. A fixed record has title,
verdict=fixed, and sha; a declined record has title, verdict=declined, and
rationale. Use an empty file for a clean review. --skip-rationale and --oracle
are optional and must be given together, for a verified trivial-diff skip.

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
FINDINGS_FILE=''
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
REQUIRE_PUSHED=0
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
            --findings-file) [[ ${2-} ]] || die_usage '--findings-file requires a path'; FINDINGS_FILE=$2; shift 2 ;;
            --provider) [[ ${2-} ]] || die_usage '--provider requires a value'; PROVIDER=$2; shift 2 ;;
            --model) [[ ${2-} ]] || die_usage '--model requires a value'; MODEL=$2; shift 2 ;;
            --effort) [[ ${2-} ]] || die_usage '--effort requires a value'; EFFORT=$2; shift 2 ;;
            --mode) [[ ${2-} ]] || die_usage '--mode requires a value'; MODE=$2; shift 2 ;;
            --mode-reason) [[ ${2-} ]] || die_usage '--mode-reason requires a value'; MODE_REASON=$2; shift 2 ;;
            --p1) [[ ${2-} ]] || die_usage '--p1 requires a value'; P1=$2; shift 2 ;;
            --p2) [[ ${2-} ]] || die_usage '--p2 requires a value'; P2=$2; shift 2 ;;
            --skip-rationale) [[ ${2-} ]] || die_usage '--skip-rationale requires a value'; SKIP_RATIONALE=$2; shift 2 ;;
            --oracle) [[ ${2-} ]] || die_usage '--oracle requires a value'; ORACLE=$2; shift 2 ;;
            --agent-identity) [[ ${2-} ]] || die_usage '--agent-identity requires a value'; AGENT_IDENTITY=$2; shift 2 ;;
            --require-pushed) REQUIRE_PUSHED=1; shift ;;
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
    [[ -n $FINDINGS_FILE ]] || die_usage '--findings-file is required'
    [[ -n $PROVIDER ]] || die_usage '--provider is required'
    [[ -n $MODEL ]] || die_usage '--model is required'
    [[ -n $EFFORT ]] || die_usage '--effort is required'
    [[ $MODE != probe ]] ||
        die_usage 'probes never count against the one-review-per-PR budget; probe mode cannot publish a receipt'
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
    # Every free-text field that reaches the rendered body. Ledger fields are
    # validated as a complete NDJSON document below, before any POST.
    reject_unsafe_field '--provider' "$PROVIDER"
    reject_unsafe_field '--model' "$MODEL"
    reject_unsafe_field '--effort' "$EFFORT"
    reject_unsafe_field '--mode-reason' "$MODE_REASON"
    reject_unsafe_field '--agent-identity' "$AGENT_IDENTITY"
    reject_unsafe_field '--skip-rationale' "$SKIP_RATIONALE"
    reject_unsafe_field '--oracle' "$ORACLE"
}

# The receipt asserts that a review happened and how many findings it produced.
# Neither was checked: an owned, well-formed but EMPTY ledger satisfies the
# jq `all` below vacuously, and --p1/--p2 were taken on the caller's word. A
# receipt could therefore be published without adversarial-run.sh ever running.
# The ledger lives beside the runner's result, so require that result here and
# derive the counts from the ledger's own severities.
validate_runner_provenance() {
    local run_dir result
    run_dir=$(dirname -- "$FINDINGS_FILE")
    result=$run_dir/adversarial.result.json
    [[ -f $result && ! -L $result && -O $result ]] ||
        evidence_unavailable "a validated adversarial review result is required beside the findings file: $result"
    jq -s -e '
        length == 1 and
        (.[0] |
            type == "object" and .status == "completed" and
            (.exitCode | type) == "number" and .exitCode == 0 and
            (.requestedModel | type) == "string" and (.transcript | type) == "string" and
            (.verdict | type) == "object" and
            (.verdict.verdict == "findings" or .verdict.verdict == "no_findings") and
            (.verdict.findings | type) == "array")
    ' "$result" >/dev/null 2>&1 ||
        evidence_unavailable "adversarial review result is not a completed validated result: $result"
}


validate_findings_file() {
    [[ -f $FINDINGS_FILE && ! -L $FINDINGS_FILE && -O $FINDINGS_FILE && -r $FINDINGS_FILE ]] ||
        evidence_unavailable "findings file is not an owned readable regular file: $FINDINGS_FILE"
    command -v jq >/dev/null 2>&1 || evidence_unavailable 'jq is not installed'
    jq -s -e --arg receipt "$RECEIPT_MARKER" --arg doc "$DOC_MARKER" '
        all(.[];
          type == "object" and
          ((keys - ["title", "severity", "verdict", "sha", "rationale"]) | length == 0) and
          (.severity == "P1" or .severity == "P2") and
          (.title | type == "string") and
          (.title | length > 0) and
          (.title | test("[\\r\\n]") | not) and
          (.title | contains($receipt) | not) and
          (.title | contains($doc) | not) and
          ((.verdict == "fixed" and has("sha") and (has("rationale") | not) and
              (.sha | type == "string" and test("^[[:xdigit:]]{7,64}(,[[:xdigit:]]{7,64})*$"))) or
           (.verdict == "declined" and has("rationale") and (has("sha") | not) and
              (.rationale | type == "string") and (.rationale | length > 0) and
              (.rationale | test("[\\r\\n]") | not) and
              (.rationale | contains($receipt) | not) and
              (.rationale | contains($doc) | not)))
        )
    ' "$FINDINGS_FILE" >/dev/null 2>&1 ||
        evidence_unavailable 'findings file must not contain a line break; it must not contain the receipt marker; it must match the ledger schema'

    local finding_count total
    finding_count=$(jq -s 'length' "$FINDINGS_FILE") ||
        evidence_unavailable 'could not count the findings ledger'
    total=$((P1 + P2))
    if ((finding_count != total)); then
        printf '%s: finding counts P1=%s P2=%s total=%s but ledger has %s record(s)\n' \
            "$PROGNAME" "$P1" "$P2" "$total" "$finding_count" >&2
        exit 13
    fi

    # The total alone does not pin the split: one record satisfies P1=1,P2=0 and
    # P1=0,P2=1 equally, so the receipt could report either severity for it.
    local ledger_p1 ledger_p2
    ledger_p1=$(jq -s '[.[] | select(.severity == "P1")] | length' "$FINDINGS_FILE") ||
        evidence_unavailable 'could not count P1 findings in the ledger'
    ledger_p2=$(jq -s '[.[] | select(.severity == "P2")] | length' "$FINDINGS_FILE") ||
        evidence_unavailable 'could not count P2 findings in the ledger'
    if [[ $P1 != "$ledger_p1" || $P2 != "$ledger_p2" ]]; then
        printf '%s: finding counts P1=%s P2=%s but ledger severities are P1=%s P2=%s\n' \
            "$PROGNAME" "$P1" "$P2" "$ledger_p1" "$ledger_p2" >&2
        exit 13
    fi
}

refuse_push() {
    printf '%s: --require-pushed refused: %s\n' "$PROGNAME" "$1" >&2
    exit 12
}

require_pushed_state() {
    command -v git >/dev/null 2>&1 || refuse_push 'git is not available'
    local root status head refs ref
    root=$(git rev-parse --show-toplevel 2>/dev/null) || refuse_push 'not inside a git worktree'
    status=$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null) ||
        refuse_push 'could not inspect worktree status'
    [[ -z $status ]] || refuse_push 'the worktree is dirty'
    head=$(git -C "$root" rev-parse HEAD 2>/dev/null) || refuse_push 'could not resolve HEAD'
    refs=$(git -C "$root" for-each-ref --format='%(refname)' refs/remotes/origin 2>/dev/null) ||
        refuse_push 'could not inspect origin remote-tracking refs'
    while IFS= read -r ref; do
        [[ -n $ref ]] || continue
        if git -C "$root" merge-base --is-ancestor "$head" "$ref" >/dev/null 2>&1; then
            return 0
        fi
    done <<<"$refs"
    refuse_push "HEAD $head is not reachable from an origin/* remote-tracking ref"
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

render_findings_block() {
    if [[ ! -s $FINDINGS_FILE ]]; then
        printf '%s\n' '- Confirmed finding: none confirmed'
        return 0
    fi
    jq -r -s '
      .[] |
      if .verdict == "fixed" then
        "- Confirmed finding: \(.title) \u2014 verdict=fixed; fix commit SHA(s)=\(.sha)"
      else
        "- Confirmed finding: \(.title) \u2014 verdict=declined; decline rationale=\(.rationale)"
      end
    ' "$FINDINGS_FILE"
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

recover_after_failed_publish() {
    local post_rc=$1 gh_bin=${GH_COMMENT_GH:-gh}
    local fresh_file fresh_err fetch_rc=0 marker_rc=0
    command -v "$gh_bin" >/dev/null 2>&1 || {
        printf '%s: receipt POST/verify failed (rc=%s); live recovery tool is unavailable; do not retry\n' \
            "$PROGNAME" "$post_rc" >&2
        exit 1
    }
    fresh_file=$(mktemp "${TMPDIR:-/tmp}/post-receipt-live.XXXXXXXXXX") || {
        printf '%s: receipt POST/verify failed (rc=%s); could not create fresh recovery evidence; do not retry\n' \
            "$PROGNAME" "$post_rc" >&2
        exit 1
    }
    fresh_err="$fresh_file.err"
    "$gh_bin" api "repos/$REPO/issues/$PR/comments" --paginate \
        -H 'Accept: application/vnd.github+json' >"$fresh_file" 2>"$fresh_err" || fetch_rc=$?
    if ((fetch_rc != 0)); then
        printf '%s: receipt POST/verify failed (rc=%s); fresh live comment re-fetch failed (rc=%s); do not retry\n' \
            "$PROGNAME" "$post_rc" "$fetch_rc" >&2
        [[ ! -s $fresh_err ]] || head -n 10 -- "$fresh_err" >&2
        rm -f -- "$fresh_file" "$fresh_err"
        exit 1
    fi
    jq -s -e --arg marker "$RECEIPT_MARKER" \
        'add | type == "array" and any(.[]?; ((.body // "") | contains($marker)))' \
        "$fresh_file" >/dev/null 2>&1 || marker_rc=$?
    if ((marker_rc == 0)); then
        printf '%s: receipt POST/verify failed (rc=%s), but fresh live comments contain the receipt marker; do not retry\n' \
            "$PROGNAME" "$post_rc" >&2
        rm -f -- "$fresh_file" "$fresh_err"
        exit 11
    fi
    if ((marker_rc != 1)); then
        printf '%s: receipt POST/verify failed (rc=%s); fresh live comment evidence was invalid; do not retry\n' \
            "$PROGNAME" "$post_rc" >&2
        rm -f -- "$fresh_file" "$fresh_err"
        exit 1
    fi
    printf '%s: receipt POST/verify failed (rc=%s); fresh live comments contain no receipt marker; retry remains blocked until this evidence is reviewed\n' \
        "$PROGNAME" "$post_rc" >&2
    rm -f -- "$fresh_file" "$fresh_err"
    exit 1
}

cmd_publish() {
    parse_publish_args "$@"
    validate_publish_args
    validate_findings_file
    validate_runner_provenance
    ((REQUIRE_PUSHED == 0)) || require_pushed_state
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

    if "$GH_COMMENT_SCRIPT" --pr "$PR" --repo "$REPO" --body-file "$RECEIPT_BODY_FILE"; then
        record_spend
    else
        local post_rc=$?
        recover_after_failed_publish "$post_rc"
    fi
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
# Deliberately BEST-EFFORT, and deliberately never fatal. By the time this runs
# the receipt is already posted and byte-verified on the PR. Exit 1 is defined
# above as "nothing durable landed", and SKILL.md routes anything other than 0
# and 11 to "receipt publication failed" -- so failing here would tell the agent
# to re-run publish, whose precheck would read the unmodified artifact, report
# not-spent, and post a SECOND durable receipt. That is precisely the duplicate
# this local record exists to prevent, so an unwritable artifact directory or a
# full filesystem degrades to a warning and exit 0: the receipt landed, and the
# durable marker on the PR still stops any later precheck.
record_spend() {
    local tmp
    if ! tmp=$(mktemp "$COMMENTS.XXXXXXXXXX" 2> /dev/null); then
        warn_spend_unrecorded 'could not stage a temporary file beside it'
        return 0
    fi
    if jq --rawfile body "$RECEIPT_BODY_FILE" '. + [{id: null, body: $body}]' \
        "$COMMENTS" > "$tmp" 2> /dev/null &&
        chmod 600 -- "$tmp" 2> /dev/null &&
        mv -f -- "$tmp" "$COMMENTS" 2> /dev/null; then
        return 0
    fi
    rm -f -- "$tmp"
    warn_spend_unrecorded 'the rewrite failed'
    return 0
}

warn_spend_unrecorded() {
    printf '%s: receipt POSTED and verified, but the local spend record in %s was not updated (%s).\n' \
        "$PROGNAME" "$COMMENTS" "$1" >&2
    printf '%s: do NOT re-run publish -- re-fetch the PR comments instead; the durable marker is on the PR.\n' \
        "$PROGNAME" >&2
}

main() {
    (($#)) || die_usage 'a subcommand is required: precheck or publish'
    if [[ $1 == --require-pushed ]]; then
        REQUIRE_PUSHED=1
        shift
        [[ ${1-} == publish ]] || die_usage '--require-pushed applies to publish'
    fi
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
