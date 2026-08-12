#!/usr/bin/env bash
#
# gh-pr-state.sh — one dense command reporting everything the PR-review loop
# needs to know about a pull request.
#
# It replaces the repeated poll cluster
#   gh pr view N --json commits,isDraft,mergeable && gh pr checks N || true
# which was run over and over. That cluster dumped a full commits array (author
# emails, node ids, message bodies) that nothing consumed, and cost two separate
# command approvals per poll. This makes one pass and prints a fixed-shape
# digest — never raw JSON. --wait-ci ignores the review bot's own check when
# deciding settledness: it can sit pending under a rate limit and never settle.
#
# Digest lines (a line is omitted only when it does not apply):
#   pr=42 draft=true mergeable=MERGEABLE head=feat/issue-NNN sha=abc1234
#   ci=3/3 green pending=0 failing=0
#   threads: coderabbit=0 unresolved  code-quality=0 open  human=0  generic=0
#   classification: known-provider=0 type=Bot=0 login-suffix=0 human=0
#   nitpicks: 0 unhandled
#   alerts: code-scanning open=0
#   saved: DIR/pr_42_{reviews,comments,issue_comments,threads,code_quality_comments}.json
#
# Exit status: 0 = digest printed; 1 = usage error or API failure.
#
# Requires: bash >= 4.2, gh (authenticated), jq >= 1.6, GNU coreutils.

set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
readonly CR_RE='coderabbit'
readonly CQ_RE='^github-code-quality(\[bot\])?$'
readonly AGENT_MARKER='<!-- review-remote-pr:agent-'
readonly AGENT_DOC_MARKER='<!-- review-remote-pr:agent-doc -->'
# U+1F9F9 BROOM, spelled as a codepoint so this file stays ASCII and the match
# needs no regex-engine support for \x{...}.
readonly BROOM_CP=129529

PR=""
REPO=""
OUT_DIR=${TMPDIR:-/tmp}
ROUNDS=4
INTERVAL=60
WANT_FULL=0
WANT_WAIT=0
SAW_DIGEST=0
PRESERVE_WORK_DIR=0
WORK_DIR=""
HEAD_REF=""

usage() {
    cat <<EOF
Usage: $PROGNAME --pr N [--repo OWNER/REPO] [--digest|--full|--wait-ci]
                 [--tmpdir DIR] [--rounds N] [--interval SECONDS] [-h]

Prints one compact digest of a pull request's draft/mergeable state, CI, review
threads, outstanding nitpicks, and open code-scanning alerts. Never prints JSON.

Required:
  --pr N                 Pull request number (e.g. 42).

Options:
  --repo OWNER/REPO      Repository. Default: derived from the current checkout
                         via 'gh repo view'.
  --digest               Print the digest only (default).
  --full                 Also write the durable artifacts later steps read, as
                         DIR/pr_N_{reviews,comments,issue_comments,threads,
                         code_quality_comments}.json
  --wait-ci              Poll until checks settle, then print the digest.
  --tmpdir DIR           Private 0700 directory where --full writes artifacts.
                         A new directory is created when absent; shared /tmp is rejected.
  --rounds N             --wait-ci rounds, 1-60 (default: $ROUNDS).
  --interval SECONDS     --wait-ci seconds between rounds, 1-3600 (default: $INTERVAL).
  -h, --help             Show this help.

Counting rules:
  coderabbit/code-quality  unresolved threads owned by that known provider with no
                           human comment.
  generic     unresolved threads from other authoritative automated accounts with
              no human comment.
  human       unresolved threads carrying any comment that is neither a recognised
              automated account nor marked '$AGENT_MARKER...'; the authenticated
              gh login counts as human.
  nitpicks    CodeRabbit review bodies and PR conversation comments matching
              /nitpick|broom-emoji/i (the body-only surfaces, which have no review
              thread), minus the threads this workflow already opened to document
              them ('$AGENT_DOC_MARKER').
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit 1
}

note() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
}

cleanup() {
    if ((PRESERVE_WORK_DIR)); then
        note "raw evidence preserved in $WORK_DIR"
        return 0
    fi
    [[ -n $WORK_DIR && -d $WORK_DIR ]] && rm -rf -- "$WORK_DIR"
    return 0
}

preserve_raw_and_die() {
    PRESERVE_WORK_DIR=1
    die "$1; raw evidence preserved in $WORK_DIR"
}

ensure_private_output_dir() {
    if [[ ! -e $OUT_DIR && ! -L $OUT_DIR ]]; then
        mkdir -m 700 -- "$OUT_DIR" || die "could not create private --tmpdir: $OUT_DIR"
    fi
    [[ -d $OUT_DIR && ! -L $OUT_DIR ]] ||
        die "--tmpdir must be an existing directory, not a symlink: $OUT_DIR"
    local mode
    mode=$(stat -c %a -- "$OUT_DIR") || die "could not inspect --tmpdir: $OUT_DIR"
    [[ $mode == 700 ]] || die "--tmpdir must have mode 0700: $OUT_DIR"
    [[ -O $OUT_DIR ]] || die "--tmpdir is not owned by this user: $OUT_DIR"
}

require_value() {
    [[ -n ${2:-} ]] || die "option $1 requires a value"
}

parse_args() {
    while (($#)); do
        case $1 in
        --pr) require_value "$1" "${2:-}"; PR=$2; shift 2 ;;
        --pr=*) PR=${1#*=}; shift ;;
        --repo) require_value "$1" "${2:-}"; REPO=$2; shift 2 ;;
        --repo=*) REPO=${1#*=}; shift ;;
        --tmpdir) require_value "$1" "${2:-}"; OUT_DIR=$2; shift 2 ;;
        --tmpdir=*) OUT_DIR=${1#*=}; shift ;;
        --rounds) require_value "$1" "${2:-}"; ROUNDS=$2; shift 2 ;;
        --rounds=*) ROUNDS=${1#*=}; shift ;;
        --interval) require_value "$1" "${2:-}"; INTERVAL=$2; shift 2 ;;
        --interval=*) INTERVAL=${1#*=}; shift ;;
        --digest) SAW_DIGEST=1; shift ;;
        --full) WANT_FULL=1; shift ;;
        --wait-ci) WANT_WAIT=1; shift ;;
        -h | --help) usage; exit 0 ;;
        --) shift; break ;;
        *) die "unknown argument: $1 (try --help)" ;;
        esac
    done
    (($# == 0)) || die "unexpected trailing argument: $1"
}

validate_args() {
    [[ -n $PR ]] || die "--pr is required (try --help)"
    [[ $PR =~ ^[1-9][0-9]*$ ]] || die "--pr must be a positive integer, got: $PR"
    ((SAW_DIGEST && WANT_FULL)) && die "--digest and --full are mutually exclusive"
    [[ -z $REPO || $REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
        die "--repo must look like OWNER/REPO, got: $REPO"
    if [[ ! $ROUNDS =~ ^[1-9][0-9]*$ ]] || ((ROUNDS > 60)); then
        die "--rounds must be an integer 1-60, got: $ROUNDS"
    fi
    if [[ ! $INTERVAL =~ ^[1-9][0-9]*$ ]] || ((INTERVAL > 3600)); then
        die "--interval must be an integer 1-3600, got: $INTERVAL"
    fi
    command -v gh >/dev/null 2>&1 || die "gh not found on PATH"
    command -v jq >/dev/null 2>&1 || die "jq not found on PATH; evidence unavailable"
    return 0
}

resolve_repo() {
    [[ -n $REPO ]] && return 0
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) ||
        die "could not derive OWNER/REPO from the current directory; pass --repo OWNER/REPO"
    [[ -n $REPO ]] || die "gh repo view returned an empty repository name; pass --repo OWNER/REPO"
    return 0
}

# --- fetch -------------------------------------------------------------------

first_error() {
    tr '\n' ' ' <"$WORK_DIR/err" | cut -c1-300
}

# Deliberately does NOT request 'commits': it dumps author emails, node ids and
# message bodies on every poll and nothing downstream consumes them.
fetch_meta() {
    gh pr view "$PR" --repo "$REPO" \
        --json number,isDraft,mergeable,headRefName,headRefOid,statusCheckRollup \
        >"$WORK_DIR/pr.json" 2>"$WORK_DIR/err" ||
        die "gh pr view failed for $REPO#$PR: $(first_error)"
    return 0
}

# REST list endpoints default to 30 per page, oldest first, so an unpaginated
# fetch silently drops the NEWEST items on a chatty PR.
fetch_list() {
    local endpoint=$1 out=$2
    gh api "$endpoint" --paginate >"$WORK_DIR/raw" 2>"$WORK_DIR/err" ||
        die "gh api $endpoint failed: $(first_error)"
    if ! jq -s 'add // []' <"$WORK_DIR/raw" >"$out"; then
        preserve_raw_and_die "could not parse the response from $endpoint"
    fi
    return 0
}

fetch_threads() {
    local owner=${REPO%%/*} name=${REPO##*/} query
    # shellcheck disable=SC2016  # $owner/$name/$pr are GraphQL variables bound by
    # the -F flags below; the shell must NOT expand them.
    query='query($owner:String!,$name:String!,$pr:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$pr){
      reviewThreads(first:100){
        pageInfo{hasNextPage}
        nodes{
          id
          isResolved
          comments(first:100){
            pageInfo{hasNextPage}
            nodes{ databaseId body author{login __typename} }
          }
        }
      }
    }
  }
}'
    gh api graphql -F owner="$owner" -F name="$name" -F pr="$PR" -f query="$query" \
        >"$WORK_DIR/threads.json" 2>"$WORK_DIR/err" ||
        die "GraphQL reviewThreads query failed for $REPO#$PR: $(first_error)"
    if ! jq -e '.data.repository.pullRequest.reviewThreads' <"$WORK_DIR/threads.json" >/dev/null; then
        preserve_raw_and_die \
            "GraphQL returned no reviewThreads for $REPO#$PR (check the PR number and gh auth)"
    fi
    return 0
}

fetch_all() {
    fetch_list "repos/$REPO/pulls/$PR/reviews" "$WORK_DIR/reviews.json"
    fetch_list "repos/$REPO/pulls/$PR/comments" "$WORK_DIR/comments.json"
    fetch_list "repos/$REPO/issues/$PR/comments" "$WORK_DIR/issue_comments.json"
    # Derived locally from the inline comments — no extra API round trip.
    if ! jq --arg re "$CQ_RE" 'map(select(((.user.login // "") | test($re; "i"))))' \
        <"$WORK_DIR/comments.json" >"$WORK_DIR/code_quality_comments.json"; then
        preserve_raw_and_die 'could not parse inline review comments for code-quality evidence'
    fi
    fetch_threads
    return 0
}

# --- derive ------------------------------------------------------------------

# Emits: total<TAB>pass<TAB>pending<TAB>fail<TAB>pending-excluding-review-bot.
# Shape-driven rather than __typename-driven so it holds for both CheckRun
# (status/conclusion) and StatusContext (state) rollup entries.
ci_counts() {
    jq -r --arg re "$CR_RE" '
        def bucket:
          if (has("status") or has("conclusion")) then
            if ((.status // "") | ascii_upcase) != "COMPLETED" then "pending"
            elif ((.conclusion // "") | ascii_upcase
                  | . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "pass"
            else "fail" end
          else
            if ((.state // "") | ascii_upcase) == "SUCCESS" then "pass"
            elif ((.state // "") | ascii_upcase
                  | . == "PENDING" or . == "EXPECTED" or . == "") then "pending"
            else "fail" end
          end;
        [ .statusCheckRollup[]? | { n: (.name // .context // ""), b: bucket } ] as $c
        | [ ($c | length),
            ([$c[] | select(.b == "pass")]    | length),
            ([$c[] | select(.b == "pending")] | length),
            ([$c[] | select(.b == "fail")]    | length),
            ([$c[] | select((.b == "pending") and ((.n | test($re; "i")) | not))] | length) ]
        | @tsv' <"$WORK_DIR/pr.json"
}

# Emits: code-quality<TAB>coderabbit<TAB>human<TAB>generic<TAB>known<TAB>type-bot
#        <TAB>login-suffix<TAB>human-signal<TAB>truncated<TAB>agent-doc-threads.
thread_counts() {
    jq -r --arg cr "$CR_RE" --arg cq "$CQ_RE" --arg mark "$AGENT_MARKER" --arg doc "$AGENT_DOC_MARKER" '
        def author_login: ((.author.login // "") | ascii_downcase);
        def known_provider:
          (author_login | test($cr; "i"))
          or author_login == "github-code-quality"
          or author_login == "github-code-quality[bot]";
        def type_is_bot:
          ((.author.type // "") == "Bot") or ((.author.__typename // "") == "Bot");
        def login_suffix: (author_login | test("\\[bot\\]$"));
        def classification:
          if known_provider then
            {lane:"known-provider", signal:"known-provider", provider:
              (if (author_login | test($cr; "i")) then "coderabbit" else "github-code-quality" end)}
          elif login_suffix then
            {lane:"generic-automated", signal:"login-suffix", provider:null}
          elif type_is_bot then
            {lane:"generic-automated", signal:"type=Bot", provider:null}
          else
            {lane:"human", signal:"human", provider:null}
          end;
        def is_cr: (classification.provider == "coderabbit");
        def is_cq: (classification.provider == "github-code-quality");
        def has_signal($signal): [.comments.nodes[]? | select(classification.signal == $signal)] | length > 0;
        # Anchored to the start of a LINE, not merely present somewhere. This
        # marker decides whether a thread counts as human-touched, and therefore
        # whether it reaches the operator for confirmation -- so a comment
        # mentioning the marker anywhere became invisible. A reviewer quoting an
        # agent reply inside their own actionable comment silently dropped their
        # own feedback out of the queue.
        #
        # The agent emits the marker on its own line, under the attribution
        # banner. Markdown quoting prefixes "> ", and indentation prefixes
        # spaces, so neither survives the anchor. A human who begins a line with
        # a raw HTML comment is opting out deliberately; one who quotes it is
        # not, and that is the case that happens by accident. Uncertainty
        # resolves toward "human": the cost is one extra item to confirm, versus
        # one lost silently.
        def is_agent: (.body // "") | test("(^|\r?\n)" + $mark);
        def human_touched: [.comments.nodes[] | select(((classification.lane == "human") and (is_agent | not)))] | length > 0;
        def has_cr: [.comments.nodes[] | select(is_cr)] | length > 0;
        def has_cq: [.comments.nodes[] | select(is_cq)] | length > 0;
        .data.repository.pullRequest.reviewThreads as $rt
        | ($rt.nodes // []) as $all
        | ($all | map(select((.isResolved // false) | not))) as $open
        | ($open | map(select((human_touched) | not))) as $bot
        | [ ($bot | map(select(has_cq)) | length),
            ($bot | map(select((has_cr) and ((has_cq) | not))) | length),
            ($open | map(select(human_touched)) | length),
            ($bot | map(select(has_signal("type=Bot") or has_signal("login-suffix"))) | length),
            ($bot | map(select(has_signal("known-provider"))) | length),
            ($bot | map(select(has_signal("type=Bot"))) | length),
            ($bot | map(select(has_signal("login-suffix"))) | length),
            ($open | map(select(has_signal("human"))) | length),
            (if (($rt.pageInfo.hasNextPage // false)
                 or ([$all[] | .comments.pageInfo.hasNextPage // false] | any)) then 1 else 0 end),
            ($all | map(select(((.comments.nodes[0].body) // "") | test("(^|\r?\n)" + $doc))) | length) ]
        | @tsv' <"$WORK_DIR/threads.json"
}

# Body-only nitpicks: CodeRabbit review bodies and PR conversation comments.
# Inline review comments are excluded on purpose — they live in review threads
# and are already counted on the 'threads:' line.
nitpick_count() {
    local file=$1
    jq --arg re "$CR_RE" --argjson broom "$BROOM_CP" '
        ([$broom] | implode) as $b
        | map(select((((.user.login // "") | test($re; "i")))
              and (((.body // "") | test("nitpick"; "i")) or ((.body // "") | contains($b)))))
        | length' <"$file"
}

# Code scanning is optional per repository: the endpoint 403s or 404s where it is
# not enabled. That is reported as n/a, never as an error.
alert_count() {
    if ! gh api "repos/$REPO/code-scanning/alerts?state=open&per_page=100" --paginate \
        >"$WORK_DIR/raw" 2>"$WORK_DIR/err"; then
        note "code-scanning alerts unavailable ($(first_error)) -> reporting n/a"
        printf 'n/a\n'
        return 0
    fi
    jq -s --arg ref "refs/heads/$HEAD_REF" --arg pr "$PR" '
        (add // [])
        | map(.most_recent_instance.ref // "")
        | map(select(. == $ref or . == ("refs/pull/" + $pr + "/merge")
                     or . == ("refs/pull/" + $pr + "/head")))
        | length' <"$WORK_DIR/raw"
}

# --- wait --------------------------------------------------------------------

wait_for_ci() {
    local round total pass pending fail pending_nb
    for ((round = 1; round <= ROUNDS; round++)); do
        fetch_meta
        IFS=$'\t' read -r total pass pending fail pending_nb < <(ci_counts)
        if ((pending_nb == 0)); then
            note "round=$round/$ROUNDS settled checks=$total pass=$pass failing=$fail"
            return 0
        fi
        note "round=$round/$ROUNDS pending=$pending (excl. review bot: $pending_nb) failing=$fail checks=$total"
        ((round < ROUNDS)) && sleep "$INTERVAL"
    done
    note "checks still pending after $ROUNDS rounds x ${INTERVAL}s — reporting current state"
    return 0
}

# --- report ------------------------------------------------------------------

save_artifacts() {
    local name target
    for name in reviews comments issue_comments threads code_quality_comments; do
        target=$OUT_DIR/pr_${PR}_${name}.json
        [[ ! -L $target ]] || die "refusing to overwrite artifact symlink: $target"
        [[ ! -e $target || ( -f $target && -O $target) ]] ||
            die "refusing to overwrite artifact unless it is an owned regular file: $target"
        local staged
        staged=$(mktemp "$OUT_DIR/.review-artifact.XXXXXXXXXX") ||
            die "could not create artifact exclusively in $OUT_DIR"
        if ! cp -- "$WORK_DIR/$name.json" "$staged"; then
            rm -f -- "$staged"
            die "could not stage $target"
        fi
        if ! mv -f -- "$staged" "$target"; then
            rm -f -- "$staged"
            die "could not publish artifact atomically: $target"
        fi
    done
    return 0
}

print_ci_line() {
    local total pass pending fail pending_nb word
    IFS=$'\t' read -r total pass pending fail pending_nb < <(ci_counts)
    if ((total == 0)); then
        word=none
    elif ((fail > 0)); then
        word=failing
    elif ((pending > 0)); then
        word=pending
    else
        word=green
    fi
    printf 'ci=%s/%s %s pending=%s failing=%s\n' "$pass" "$total" "$word" "$pending" "$fail"
}

print_thread_lines() {
    local cq cr human generic known type_bot suffix human_signal trunc doc nits reviews_n issues_n unhandled
    IFS=$'\t' read -r cq cr human generic known type_bot suffix human_signal trunc doc < <(thread_counts)
    if ((trunc)); then
        printf 'threads: coderabbit=%s unresolved  code-quality=%s open  human=%s  generic=%s  truncated=yes\n' \
            "$cr" "$cq" "$human" "$generic"
        note "more than 100 review threads (or >100 comments in one thread): counts are lower bounds"
    else
        printf 'threads: coderabbit=%s unresolved  code-quality=%s open  human=%s  generic=%s\n' \
            "$cr" "$cq" "$human" "$generic"
    fi
    printf 'classification: known-provider=%s type=Bot=%s login-suffix=%s human=%s\n' \
        "$known" "$type_bot" "$suffix" "$human_signal"
    reviews_n=$(nitpick_count "$WORK_DIR/reviews.json")
    issues_n=$(nitpick_count "$WORK_DIR/issue_comments.json")
    nits=$((reviews_n + issues_n))
    unhandled=$((nits - doc))
    ((unhandled < 0)) && unhandled=0
    printf 'nitpicks: %s unhandled\n' "$unhandled"
}

print_digest() {
    local alerts
    jq -r '"pr=" + (.number | tostring)
           + " draft=" + (.isDraft | tostring)
           + " mergeable=" + (.mergeable // "UNKNOWN")
           + " head=" + (.headRefName // "?")
           + " sha=" + ((.headRefOid // "") | .[0:7])' <"$WORK_DIR/pr.json"
    print_ci_line
    print_thread_lines
    alerts=$(alert_count)
    if [[ $alerts == "n/a" ]]; then
        printf 'alerts: code-scanning n/a\n'
    else
        printf 'alerts: code-scanning open=%s\n' "$alerts"
    fi
    ((WANT_FULL)) || return 0
    printf 'saved: %s/pr_%s_{reviews,comments,issue_comments,threads,code_quality_comments}.json\n' \
        "$OUT_DIR" "$PR"
}

main() {
    parse_args "$@"
    validate_args
    resolve_repo
    ((WANT_FULL)) && ensure_private_output_dir
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gh-pr-state.XXXXXX") || die "could not create a work directory"
    chmod 700 -- "$WORK_DIR" || die "could not secure work directory: $WORK_DIR"
    trap cleanup EXIT
    if ((WANT_WAIT)); then
        wait_for_ci
    else
        fetch_meta
    fi
    HEAD_REF=$(jq -r '.headRefName // ""' <"$WORK_DIR/pr.json")
    fetch_all
    ((WANT_FULL)) && save_artifacts
    print_digest
    return 0
}

main "$@"
