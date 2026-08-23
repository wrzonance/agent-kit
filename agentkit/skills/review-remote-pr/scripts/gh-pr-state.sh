#!/usr/bin/env bash
#
# gh-pr-state.sh — one dense command reporting everything the PR-review loop
# needs to know about a pull request.
#
# It replaces the repeated poll cluster of PR metadata plus checks calls
# which was run over and over. That cluster dumped a full commits array (author
# emails, node ids, message bodies) that nothing consumed, and cost two separate
# command approvals per poll. This makes one pass and prints a fixed-shape
# digest — never raw JSON. --wait-ci ignores the review bot's own check when
# deciding settledness: it can sit pending under a rate limit and never settle.
# --wait-ci also treats zero registered checks (ci=0/0) as pending, not
# settled, for a short grace window right after a push: GitHub has not always
# registered the head's first check run yet, and a caller that trusted an
# immediate 0/0 as "done" would proceed on no evidence (agent-kit#396). If the
# window elapses with still no checks, the digest reports that explicitly as
# ci=0/0 none-configured rather than silently reusing the "no CI here at all"
# 'none' word.
#
# A base advance whose new commits touch ONLY the repository-declared
# AGENT_GENERATED_PATHS prefixes (e.g. a post-merge results-recording workflow
# like record-tier0.yml) is not reported stale: without this, every such
# commit forces a merge-down plus a full CI re-run on the next queued PR
# (agent-kit#394). The exemption is resolved from <repo-root>/.agent/config.env
# via repo-config.sh (--repo-root DIR, default: git toplevel) and fails closed --
# an undeclared list, an unreadable comparison, a possibly-truncated compare
# response (see COMPARE_FILES_PAGE_CAP), a rename whose old or new path is
# undeclared, or any file outside the declared prefixes leaves the advance
# staling exactly as before.
#
# Digest lines (a line is omitted only when it does not apply):
#   pr=42 draft=true mergeable=MERGEABLE head=feat/issue-NNN sha=abc1234def5678901234567890123456789ab01
#   base: ref=main behind=1 stale=yes
#   ci=3/3 green pending=0 failing=0
#   provider: coderabbit=reviewed state=APPROVED threads=0 since=2026-08-22T06:36:18Z
#   threads: coderabbit=0 unresolved  code-quality=0 open  human=0  generic=0
#   classification: known-provider=0 type=Bot=0 login-suffix=0 human=0
#   nitpicks: 0 unhandled
#   agent-docs: 0 eligible
#   next: human=2 -> per-item confirmation gate (Step 1a)
#   alerts: code-scanning open=0
#   saved: DIR/pr_42_{reviews,comments,issue_comments,threads,code_quality_comments}.json
# A stale base makes passing checks report 'stale', never 'green'.
#
# 'provider', 'agent-docs' and 'next' print in every mode (--digest, --full,
# --wait-ci): the queries they read (issue comments, review threads) already
# run before any digest is printed, so nothing about them costs an extra API
# call in --digest mode. Only 'saved' is --full-only, because writing the
# artifact files themselves is the thing --digest skips.
#
# Exit status: 0 = digest printed; 1 = usage error or API failure.
#
# Requires: bash >= 4.2, gh (authenticated), jq >= 1.6, GNU coreutils.

set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/provider-identity.sh"
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/private-dir.sh"
# CHECK NAMES only. Deliberately a substring: the rollup entry is named
# "CodeRabbit" in some repos and "coderabbitai" in others, and a check name is a
# display/CI concern, not an identity boundary.
readonly CR_RE='coderabbit'
# AUTHOR LOGINS. Anchored, like CQ_RE below, because this one decides the
# known-provider lane -- and that lane is what lets a thread be replied to and
# resolved WITHOUT the human confirmation gate. An unanchored `coderabbit`
# handed that lane to any human who registers `mycoderabbit`.
readonly CR_LOGIN_RE='^coderabbitai(\[bot\])?$'
readonly CQ_RE='^github-code-quality(\[bot\])?$'
readonly AGENT_MARKER='<!-- review-remote-pr:agent-'
readonly AGENT_DOC_MARKER='<!-- review-remote-pr:agent-doc -->'
# U+1F9F9 BROOM, spelled as a codepoint so this file stays ASCII and the match
# needs no regex-engine support for \x{...}.
readonly BROOM_CP=129529
# GitHub's "compare two commits" REST endpoint returns at most this many
# entries in `.files` on a single (unpaginated) page; a response carrying
# this many or more cannot prove the full file list was read, only that at
# least this many files changed. base_advance_is_automation_only treats that
# as unreadable evidence and fails closed rather than risk missing an
# out-of-page file outside the declared paths.
readonly COMPARE_FILES_PAGE_CAP=300

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
BASE_REF=""
BASE_BEHIND=""
BASE_STATUS=unknown
THREADS_AVAILABLE=1
CI_NONE_CONFIGURED=0
REPO_ROOT=""
# Declared AGENT_GENERATED_PATHS prefixes (comma-separated); resolved once in
# main() via resolve_automation_paths. Empty means the exemption is inert.
AUTOMATION_PATHS=""
# --wait-ci rounds of ci=0/0 (no registered checks at all) tolerated as
# "pending" before reporting none-configured; see the header comment.
readonly CI_ZERO_CHECKS_GRACE_ROUNDS=3

usage() {
    cat <<EOF
Usage: $PROGNAME [--pr N | N] [--repo OWNER/REPO] [--repo-root DIR]
                 [--digest|--full|--wait-ci]
                 [--tmpdir DIR] [--rounds N] [--interval SECONDS] [-h]

Prints one compact digest of a pull request's draft/mergeable state, CI, review
threads, outstanding nitpicks, and open code-scanning alerts. Never prints JSON.

Required:
  --pr N                 Pull request number (e.g. 42). A bare N is also accepted.

Options:
  --repo OWNER/REPO      Repository. Default: derived from the current checkout
                         from the current checkout's origin remote.
  --repo-root DIR        Local checkout to resolve AGENT_GENERATED_PATHS from,
                         for the base-staleness exemption below. Default: the
                         current directory's git toplevel; absent either way,
                         the exemption stays inert and every base advance
                         stales exactly as before.
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
  base        behind>0 stales unless every file the base gained since divergence
              falls under a declared AGENT_GENERATED_PATHS prefix (see --repo-root).
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
  provider    the most recent terminal (APPROVED/CHANGES_REQUESTED/COMMENTED)
              CodeRabbit review on the reviews endpoint: 'reviewed
              state=STATE threads=N since=TIMESTAMP', where threads is that
              review's own inline-comment count and since is its submission
              time. An acknowledgement-only issue comment never satisfies
              this -- it is not a review submission. Absent a terminal
              review, falls back to an issue-comment rate-limit phrase scan:
              /review limit reached|rate limit/i means 'rate-limited',
              otherwise 'none'. Informational only -- never a trigger
              decision.
  agent-docs  unresolved threads whose FIRST comment is marked
              '$AGENT_DOC_MARKER' and which carry no unmarked human-lane
              comment; eligible for this workflow to resolve at exit (Step 6).
  next        one fixed-vocabulary hint per lane above (coderabbit, code-quality,
              human, generic, nitpicks, agent-docs) that is currently non-zero;
              omitted entirely when every lane is zero.
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
    private_dir_ensure "$OUT_DIR" "--tmpdir"
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
        --repo-root) require_value "$1" "${2:-}"; REPO_ROOT=$2; shift 2 ;;
        --repo-root=*) REPO_ROOT=${1#*=}; shift ;;
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
        *)
            if [[ -z $PR && $1 =~ ^[1-9][0-9]*$ ]]; then
                PR=$1
                shift
            else
                die "unexpected argument: $1 (did you mean --pr N?)"
            fi
            ;;
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
    local remote
    remote=$(git remote get-url origin 2>/dev/null) ||
        die "could not derive OWNER/REPO from the current directory; pass --repo OWNER/REPO"
    case $remote in
        https://github.com/*|http://github.com/*|ssh://git@github.com/*)
            REPO=${remote#*github.com/}
            ;;
        git@github.com:*)
            REPO=${remote#git@github.com:}
            ;;
        *)
            die "could not derive OWNER/REPO from the current directory; pass --repo OWNER/REPO"
            ;;
    esac
    REPO=${REPO%.git}
    [[ $REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
        die "could not derive OWNER/REPO from the current directory; pass --repo OWNER/REPO"
    return 0
}

# --- fetch -------------------------------------------------------------------

first_error() {
    tr '\n' ' ' <"$WORK_DIR/err" | cut -c1-300
}

# REST pull-request metadata and check runs are normalized to the internal
# digest shape. The former gh pr view call used GraphQL for data REST already
# serves, and statusCheckRollup mixed check-run and status-context objects.
fetch_meta() {
    local head_sha
    gh api "repos/$REPO/pulls/$PR" \
        >"$WORK_DIR/pr-raw.json" 2>"$WORK_DIR/err" ||
        die "gh api pull request failed for $REPO#$PR: $(first_error)"
    head_sha=$(jq -er '.head.sha // empty' <"$WORK_DIR/pr-raw.json" 2>/dev/null) ||
        die "REST pull request metadata has no head SHA for $REPO#$PR"
    gh api "repos/$REPO/commits/$head_sha/check-runs?per_page=100" --paginate \
        >"$WORK_DIR/check-runs.raw" 2>"$WORK_DIR/err" ||
        die "gh api check runs failed for $REPO#$PR: $(first_error)"
    gh api "repos/$REPO/commits/$head_sha/status?per_page=100" --paginate \
        >"$WORK_DIR/status.raw" 2>"$WORK_DIR/err" ||
        die "gh api commit statuses failed for $REPO#$PR: $(first_error)"
    if ! jq -n --slurpfile pr "$WORK_DIR/pr-raw.json" \
        --slurpfile pages "$WORK_DIR/check-runs.raw" \
        --slurpfile status_pages "$WORK_DIR/status.raw" '
        $pr[0] as $p
        | {
            number: $p.number,
            isDraft: ($p.draft // false),
            mergeable: (if $p.mergeable == true then "MERGEABLE"
                        elif $p.mergeable == false then "CONFLICTING"
                        else "UNKNOWN" end),
            headRefName: ($p.head.ref // ""),
            headRefOid: ($p.head.sha // ""),
            baseRefName: ($p.base.ref // ""),
            statusCheckRollup: (
              [$pages[]? | select(type == "object") | .check_runs[]?]
              + [$status_pages[]? | select(type == "object") | .statuses[]?
                 | {name: (.context // ""), state: (.state // "")}]
            )
          }' >"$WORK_DIR/pr.json"; then
        preserve_raw_and_die "could not normalize REST pull-request metadata for $REPO#$PR"
    fi
    return 0
}

# Resolves AUTOMATION_PATHS once from the declared AGENT_GENERATED_PATHS key,
# the same repository-relative comma-separated prefix list diff-facts.sh
# already reads for its 'generated' evidence category. --repo-root wins;
# otherwise the current directory's git toplevel; either way absent, this
# stays empty and the staleness exemption below is inert. Never dies: a
# missing resolver, repo root, or config file is a normal "not declared" case.
resolve_automation_paths() {
    [[ -n $REPO_ROOT ]] || REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
    [[ -n $REPO_ROOT ]] || return 0
    local resolver="$SCRIPT_DIR/../../.shared/scripts/repo-config.sh"
    [[ -x $resolver ]] || return 0
    AUTOMATION_PATHS=$("$resolver" --repo-root "$REPO_ROOT" --get AGENT_GENERATED_PATHS 2>/dev/null) || AUTOMATION_PATHS=""
    return 0
}

# Prefix match against the declared AUTOMATION_PATHS list, mirroring
# diff-facts.sh's matches_generated: a trailing slash is a directory prefix,
# leading './' is normalized away, and an empty/'.' spec matches nothing here
# (never treat "no declaration" as "everything is generated").
matches_automation_path() {
    local path=$1 spec
    local -a specs=()
    IFS=, read -ra specs <<< "$AUTOMATION_PATHS"
    for spec in "${specs[@]}"; do
        [[ -n $spec ]] || continue
        while [[ $spec == ./* ]]; do spec=${spec#./}; done
        while [[ $spec == */ ]]; do spec=${spec%/}; done
        [[ -n $spec && $spec != . ]] || continue
        [[ $path == "$spec" || $path == "$spec/"* ]] && return 0
    done
    return 1
}

# True only when EVERY file the base gained since divergence (the files in
# the reverse compare head...base, i.e. diff(merge-base, base)) matches a
# declared AUTOMATION_PATHS prefix. Fails closed on anything unreadable,
# unparsable, empty, or possibly truncated -- an empty file list proves
# nothing was actually compared, so it is never read as "confined to
# nothing, therefore fine", and a file count at or above
# COMPARE_FILES_PAGE_CAP proves only a lower bound, never the full list, so
# it is never read as "everything returned matched, therefore fine" either.
# A renamed file carries BOTH `filename` (the new path) and
# `previous_filename` (the old one); both must match a declared prefix, so a
# rename that moves application code INTO a declared path -- or a declared
# artifact OUT of one -- still fails closed on whichever side is undeclared.
base_advance_is_automation_only() {
    local head_ref=$1 out="$WORK_DIR/base-advance.json"
    [[ -n $AUTOMATION_PATHS ]] || return 1
    gh api "repos/$REPO/compare/$head_ref...$BASE_REF" \
        >"$out" 2>"$WORK_DIR/err" || return 1
    jq -e 'type == "object" and has("files") and (.files | type == "array")' "$out" >/dev/null 2>&1 || return 1
    local file_count
    file_count=$(jq -r '.files | length' "$out" 2>/dev/null) || return 1
    [[ $file_count =~ ^[0-9]+$ ]] || return 1
    ((file_count > 0)) || return 1
    ((file_count < COMPARE_FILES_PAGE_CAP)) || return 1
    local -a rows=()
    mapfile -t rows < <(jq -r '.files[]? | [(.filename // ""), (.previous_filename // "")] | @tsv' "$out")
    ((${#rows[@]} == file_count)) || return 1
    local row filename previous
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r filename previous <<<"$row"
        [[ -n $filename ]] || return 1
        matches_automation_path "$filename" || return 1
        [[ -z $previous ]] || matches_automation_path "$previous" || return 1
    done
    return 0
}

# Compare the live base and head ancestry: after parent-merge retargeting, a
# child can be behind its new base while its old checks remain attached. The
# PR's baseRefOid is live metadata and cannot identify what an earlier check
# tested, so it is deliberately not used as evidence. Missing or unavailable
# comparison data is unknown, never silently current. A behind>0 advance
# confined entirely to declared AGENT_GENERATED_PATHS prefixes (see
# base_advance_is_automation_only) is reported current, not stale --
# record-tier0.yml-style post-merge commits otherwise force a merge-down and a
# full CI re-run on every queued PR (agent-kit#394).
fetch_base_state() {
    BASE_REF=$(jq -r '.baseRefName // ""' <"$WORK_DIR/pr.json")
    local head_ref
    head_ref=$(jq -r '.headRefName // ""' <"$WORK_DIR/pr.json")
    BASE_BEHIND=""
    BASE_STATUS=unknown
    [[ -n $BASE_REF && -n $head_ref ]] || return 0
    if ! gh api "repos/$REPO/compare/$BASE_REF...$head_ref" \
        >"$WORK_DIR/base.json" 2>"$WORK_DIR/err"; then
        note "base comparison unavailable for $REPO ($BASE_REF...$head_ref): $(first_error)"
        return 0
    fi
    BASE_BEHIND=$(jq -r '.behind_by? // empty' <"$WORK_DIR/base.json") || {
        note "base comparison unavailable for $REPO ($BASE_REF...$head_ref): invalid JSON"
        BASE_BEHIND=""
        return 0
    }
    if [[ ! $BASE_BEHIND =~ ^[0-9]+$ ]]; then
        note "base comparison unavailable for $REPO ($BASE_REF...$head_ref): missing behind_by"
        BASE_BEHIND=""
        return 0
    fi
    if ((BASE_BEHIND > 0)); then
        if base_advance_is_automation_only "$head_ref"; then
            BASE_STATUS=current
            note "base advance ($BASE_REF, $BASE_BEHIND commit(s)) touches only declared AGENT_GENERATED_PATHS -- not staling"
        else
            BASE_STATUS=stale
        fi
    else
        BASE_STATUS=current
    fi
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
    nameWithOwner
    pullRequest(number:$pr){
      number
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
    # routing-allow: review-threads -- isResolved and thread comments have no REST equivalent
    if ! gh api graphql -F owner="$owner" -F name="$name" -F pr="$PR" -f query="$query" \
        >"$WORK_DIR/threads.json" 2>"$WORK_DIR/err"; then
        THREADS_AVAILABLE=0
        if ((WANT_FULL)); then
            preserve_raw_and_die \
                "review-thread data unavailable for $REPO#$PR; --full cannot publish durable artifacts without GraphQL evidence: $(first_error)"
        fi
        note "review-thread data unavailable for $REPO#$PR (named wait: GraphQL review-thread reset; continuing without thread data): $(first_error)"
        jq -cn --arg repo "$REPO" --argjson pr "$PR" \
            '{data:{repository:{nameWithOwner:$repo,pullRequest:{number:$pr,reviewThreads:{pageInfo:{hasNextPage:false},nodes:[]}}}}}' \
            >"$WORK_DIR/threads.json" || die 'could not write unavailable thread evidence'
        return 0
    fi
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
#        <TAB>login-suffix<TAB>human-signal<TAB>truncated<TAB>agent-doc-threads
#        <TAB>agent-docs-eligible.
# 'agent-doc-threads' (field 10) counts ALL threads (any resolution state)
# whose first comment carries the marker -- it feeds the nitpick 'unhandled'
# subtraction below, where a resolved documentation thread still proves the
# nitpick was handled. 'agent-docs-eligible' (field 11) is the stricter,
# reader-facing count: unresolved, first-comment-marked, and untouched by any
# unmarked human comment -- ports the Step 6 python classifier's 'agent_docs'
# list exactly, so this workflow only offers to auto-resolve threads it fully
# owns.
thread_counts() {
    jq -r --arg cr "$CR_LOGIN_RE" --arg cq "$CQ_RE" --arg mark "$AGENT_MARKER" --arg doc "$AGENT_DOC_MARKER" "$PROVIDER_IDENTITY_JQ"'
        def author_login: ((.author.login // "") | ascii_downcase);
        def known_provider:
          (author_login | known_provider_login);
        def type_is_bot:
          ((.author.type // "") == "Bot") or ((.author.__typename // "") == "Bot");
        def login_suffix: (author_login | test("\\[bot\\]$"));
        def classification:
          if known_provider then
            {lane:"known-provider", signal:"known-provider", provider:
              (if (author_login | is_coderabbit_login) then "coderabbit" else "github-code-quality" end)}
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
        def has_human_signal: [.comments.nodes[] | select((classification.signal == "human") and (is_agent | not))] | length > 0;
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
            ($open | map(select(has_human_signal)) | length),
            (if (($rt.pageInfo.hasNextPage // false)
                 or ([$all[] | .comments.pageInfo.hasNextPage // false] | any)) then 1 else 0 end),
            ($all | map(select(((.comments.nodes[0].body) // "") | test("(^|\r?\n)" + $doc))) | length),
            ($open | map(select((((.comments.nodes[0].body) // "") | test("(^|\r?\n)" + $doc))
                                 and ((human_touched) | not))) | length) ]
        | @tsv' <"$WORK_DIR/threads.json"
}

# Body-only nitpicks: CodeRabbit review bodies and PR conversation comments.
# Inline review comments are excluded on purpose — they live in review threads
# and are already counted on the 'threads:' line.
nitpick_count() {
    local file=$1
    jq --arg re "$CR_LOGIN_RE" --argjson broom "$BROOM_CP" '
        ([$broom] | implode) as $b
        | map(select((((.user.login // "") | test($re; "i")))
              and (((.body // "") | test("nitpick"; "i")) or ((.body // "") | contains($b)))))
        | length' <"$file"
}

# CodeRabbit's own check can sit green on a bare "finished" ack or a rate-limit
# warning, and a landed review can be APPROVED/CHANGES_REQUESTED with zero
# actionable threads -- neither a check conclusion nor an issue-comment phrase
# scan proves a review actually landed (agent-kit#395: PR #386 read
# coderabbit=none for 15 one-minute rounds after an APPROVED, zero-thread
# review). The real signal is CodeRabbit's own PullRequestReview object on the
# reviews endpoint: the initial "Reviewing files that changed..."
# acknowledgement is posted as a plain issue comment, never as a review
# submission, so it can never satisfy this check -- only a genuine submitted
# review (APPROVED, CHANGES_REQUESTED, or COMMENTED; PENDING and DISMISSED are
# excluded as non-terminal) does. Ties on submitted_at break on the higher
# review id (insertion order). 'threads' counts this review's own inline
# comments via pull_request_review_id -- already-fetched evidence, no extra
# API call. Falls back to the issue-comment rate-limit phrase scan only when
# no terminal review exists yet; that fallback never reports 'reviewed' on its
# own, since a phrase alone is not proof a review landed.
provider_state() {
    local review
    review=$(jq -r "$PROVIDER_IDENTITY_JQ"'
        [ .[] | select(((.user.login // "") | ascii_downcase) | is_coderabbit_login)
               | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "COMMENTED") ]
        | sort_by([(.submitted_at // ""), (.id // 0)])
        | last
        | if . == null then empty else
            [(.state), (.submitted_at // ""), ((.id // 0) | tostring)] | @tsv
          end' <"$WORK_DIR/reviews.json") || review=""
    if [[ -n $review ]]; then
        local state submitted_at review_id threads
        IFS=$'\t' read -r state submitted_at review_id <<< "$review"
        threads=$(jq -r --argjson rid "${review_id:-0}" \
            '[.[] | select((.pull_request_review_id // -1) == $rid)] | length' \
            <"$WORK_DIR/comments.json")
        printf 'reviewed state=%s threads=%s since=%s' "$state" "$threads" "${submitted_at:-unknown}"
        return 0
    fi
    jq -r --arg re "$CR_LOGIN_RE" '
        map(select((.user.login // "") | test($re; "i")) | (.body // ""))
        | reduce .[] as $b ("none";
            if ($b | test("review limit reached|rate limit"; "i")) then "rate-limited"
            else . end)' <"$WORK_DIR/issue_comments.json"
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
    local zero_rounds=0
    for ((round = 1; round <= ROUNDS; round++)); do
        fetch_meta
        fetch_base_state
        IFS=$'\t' read -r total pass pending fail pending_nb < <(ci_counts)
        if ((total == 0)); then
            ((++zero_rounds))
            if ((zero_rounds >= CI_ZERO_CHECKS_GRACE_ROUNDS || round >= ROUNDS)); then
                CI_NONE_CONFIGURED=1
                note "round=$round/$ROUNDS no checks registered after $zero_rounds round(s) — reporting none-configured"
                return 0
            fi
            note "round=$round/$ROUNDS no checks registered yet (grace $zero_rounds/$CI_ZERO_CHECKS_GRACE_ROUNDS) — treating as pending"
            sleep "$INTERVAL"
            continue
        fi
        zero_rounds=0
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
        if ((CI_NONE_CONFIGURED)); then
            word=none-configured
        else
            word=none
        fi
    elif ((fail > 0)); then
        word=failing
    elif ((pending > 0)); then
        word=pending
    elif [[ $BASE_STATUS == stale && $pass -gt 0 ]]; then
        word=stale
    else
        word=green
    fi
    printf 'ci=%s/%s %s pending=%s failing=%s\n' "$pass" "$total" "$word" "$pending" "$fail"
}

print_base_line() {
    [[ -n $BASE_REF ]] || return 0
    if [[ $BASE_STATUS == unknown ]]; then
        printf 'base: ref=%s behind=unknown stale=unknown\n' "$BASE_REF"
    else
        printf 'base: ref=%s behind=%s stale=%s\n' \
            "$BASE_REF" "$BASE_BEHIND" "$([[ $BASE_STATUS == stale ]] && printf yes || printf no)"
    fi
}

print_thread_lines() {
    local cq cr human generic known type_bot suffix human_signal trunc doc eligible
    local nits reviews_n issues_n unhandled
    if ((THREADS_AVAILABLE == 0)); then
        printf 'threads: unavailable (GraphQL review-thread capability)\n'
        printf 'classification: unavailable (GraphQL review-thread capability)\n'
        printf 'nitpicks: unavailable (GraphQL review-thread capability; de-duplication unknown)\n'
        printf 'agent-docs: unavailable (GraphQL review-thread capability)\n'
        return 0
    fi
    IFS=$'\t' read -r cq cr human generic known type_bot suffix human_signal trunc doc eligible \
        < <(thread_counts)
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
    printf 'agent-docs: %s eligible\n' "$eligible"
    print_next_lines "$cr" "$cq" "$human" "$generic" "$unhandled" "$eligible"
}

# One fixed-vocabulary routing hint per lane that is currently non-zero, in
# the same order the lanes were reported above. A lane sitting at zero prints
# no line at all -- silence, not a "next: none", is the "nothing to do" signal.
print_next_lines() {
    local cr=$1 cq=$2 human=$3 generic=$4 nits=$5 eligible=$6
    ((cr)) && printf 'next: coderabbit=%s -> canonical reply then settle (Step 5)\n' "$cr"
    ((cq)) && printf 'next: code-quality=%s -> verbatim fix or reasoned dismiss (Step 5)\n' "$cq"
    ((human)) && printf 'next: human=%s -> per-item confirmation gate (Step 1a)\n' "$human"
    ((generic)) && printf 'next: generic=%s -> smallest fix or decline reply (Step 5)\n' "$generic"
    ((nits)) && printf 'next: nitpicks=%s -> fix if trivial or decline (Step 5)\n' "$nits"
    ((eligible)) && printf 'next: agent-docs=%s -> resolve at exit if still bot-only\n' "$eligible"
    return 0
}

print_digest() {
    local alerts provider
    # The full head SHA, never a 7-character abbreviation: pr-to-green's
    # merge-gate.sh consumes this field as merge authorization evidence,
    # binding CI/thread/nitpick/code-scanning evidence to the head being
    # merged. A short prefix can collide across commits (28 bits of entropy),
    # so it cannot prove the evidence was captured for THIS commit -- only
    # for some commit sharing those characters. Every other identity in that
    # decision path (merge-gate.sh --head-sha, the auto-merge authorization
    # record, merge-pr.sh's merge call) is already full-width; this is the
    # one field that must match.
    jq -r '"pr=" + (.number | tostring)
           + " draft=" + (.isDraft | tostring)
           + " mergeable=" + (.mergeable // "UNKNOWN")
           + " head=" + (.headRefName // "?")
           + " sha=" + (.headRefOid // "")' <"$WORK_DIR/pr.json"
    print_base_line
    print_ci_line
    provider=$(provider_state)
    printf 'provider: coderabbit=%s\n' "$provider"
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
    resolve_automation_paths
    ((WANT_FULL)) && ensure_private_output_dir
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gh-pr-state.XXXXXX") || die "could not create a work directory"
    chmod 700 -- "$WORK_DIR" || die "could not secure work directory: $WORK_DIR"
    trap cleanup EXIT
    if ((WANT_WAIT)); then
        wait_for_ci
    else
        fetch_meta
        fetch_base_state
    fi
    HEAD_REF=$(jq -r '.headRefName // ""' <"$WORK_DIR/pr.json")
    fetch_all
    ((WANT_FULL)) && save_artifacts
    print_digest
    return 0
}

main "$@"
