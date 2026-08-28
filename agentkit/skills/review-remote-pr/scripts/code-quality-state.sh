#!/usr/bin/env bash
# Fetch GitHub Code Quality findings for inspection.  This helper is
# deliberately retrieval-only: GitHub exposes no supported per-finding
# dismissal mutation here, so dismissal remains a human/provider action.
set -uo pipefail

readonly PROGRAM=${0##*/}
readonly SHA_RE='^[0-9a-f]{40}$'
# GitHub's `code-quality/findings` list is the only Code Quality REST surface
# that is actually live (issue #472 rework): `code-quality/analyses` and
# `pulls/N/code-quality` both 404 in a real repository, and the findings
# list's own ref=/pull_request= filters are silently ignored. --head derives
# its per-head evidence from two surfaces that ARE real and per-head: the
# Checks API (for an in-flight scan) and PR review comments (for completed,
# attributable findings).
readonly CQ_BOT_RE='^github-code-quality(\[bot\])?$'
repository=''
state=open
per_page=100
summary=no
probe=no
head_sha=''
pr=''
baseline_file=''
comments_file=''
diff_base=''
diff_head=HEAD

usage() {
    cat <<'EOF'
Usage: code-quality-state.sh --repo OWNER/REPO [--state open|dismissed] [--per-page N] [--summary]
       code-quality-state.sh --repo OWNER/REPO --probe
       code-quality-state.sh --repo OWNER/REPO --head SHA40 --pr N [--baseline-file FILE]
       code-quality-state.sh --repo OWNER/REPO --pr N --comments-file FILE --diff-base REF [--diff-head REF]

Reads Code Quality findings through the public read-only API. The default
output is the API JSON; --summary emits one compact line per finding.

--probe performs a single lightweight request to decide whether GitHub Code
Quality is enabled for the repository, without fetching findings. It prints
exactly one line and exits 0 for a decided answer:
  state=enabled
  state=not-enabled
or, when the answer cannot be decided (a network failure, an auth/scope
problem, a 5xx, or any other unrecognized response), prints one line and
exits 1 -- an inconclusive probe is never treated as proof the feature is
disabled:
  state=unknown reason=<first line of the underlying error>
--probe always queries its own minimal page; --state and --per-page are
ignored (and --probe cannot be combined with --summary).

--head SHA40 (requires --pr N) decides the merge-gate's per-head scan-state
token from two real, per-head evidence surfaces -- never from a fictitious
analyses record. It prints exactly one line:
  scan-state=complete head=<sha> findings-on-head=<n>
  scan-state=pending head=<sha>
  scan-state=not-enabled
  scan-state=unknown reason=<first line of the underlying error>
and exits 0 for complete/pending/not-enabled, 1 for unknown -- an unreadable
record never maps to complete. Order of evidence: (1) the head's check-runs
-- any run whose app.slug is exactly "github-code-quality" and whose status
is not "completed" reports pending; (2) otherwise, the PR's review comments
whose user.login matches github-code-quality[bot] and whose commit_id or
original_commit_id equals the head SHA are counted as findings-on-head (zero
such comments is a valid, complete, zero-finding scan) and the repository's
findings?state=open list additionally decides not-enabled (a confirmed 403)
vs an unreadable repository (unknown). --head always queries its own pages;
--state, --per-page, and --summary are ignored/rejected (--head cannot be
combined with --probe or --summary). --baseline-file FILE additionally
writes a mode-600 JSON evidence artifact
{head, findingsOnHead, repoWideOpen, timestamp} for this run.

--pr N --comments-file FILE --diff-base REF reports the open findings attributed
to a PR's persisted Code Quality comments artifact and the remaining
repository-wide findings. A finding is PR-attributed only when its path and
line are inside a changed-line range in REF...HEAD (or --diff-head REF).
It prints:
  cq-repo: M
  cq-open: N source=pr_N_code_quality_comments.json
EOF
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

# A gh api failure's combined stdout+stderr is often a pretty-printed JSON
# error body -- `head -n 1` on that yields a bare, useless "{" rather than
# the actual message. Prefer the JSON body's own .message field; fall back
# to the first line only when the body isn't parseable JSON at all.
first_error_line() {
    local raw=$1 msg
    if msg=$(jq -r '.message // empty' <<<"$raw" 2>/dev/null) && [[ -n $msg ]]; then
        printf '%s\n' "$msg"
        return 0
    fi
    head -n 1 <<<"$raw"
}

while (($#)); do
    case $1 in
        --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
        --repo|--repository)
            (($# >= 2)) || die "$1 requires OWNER/REPO"
            repository=$2
            shift 2
            ;;
        --state)
            (($# >= 2)) || die '--state requires open or dismissed'
            state=$2
            shift 2
            ;;
        --per-page)
            (($# >= 2)) || die '--per-page must be 1-100'
            [[ $2 =~ ^[1-9][0-9]{0,2}$ ]] || die '--per-page must be 1-100'
            per_page=$2
            shift 2
            ;;
        --summary) summary=yes; shift ;;
        --probe) probe=yes; shift ;;
        --head)
            (($# >= 2)) || die '--head requires a 40-character SHA'
            head_sha=$2
            shift 2
            ;;
        --pr)
            (($# >= 2)) || die '--pr requires a positive integer'
            pr=$2
            shift 2
            ;;
        --comments-file)
            (($# >= 2)) || die '--comments-file requires a path'
            comments_file=$2
            shift 2
            ;;
        --diff-base)
            (($# >= 2)) || die '--diff-base requires a git ref'
            diff_base=$2
            shift 2
            ;;
        --diff-head)
            (($# >= 2)) || die '--diff-head requires a git ref'
            diff_head=$2
            shift 2
            ;;
        --baseline-file)
            (($# >= 2)) || die '--baseline-file requires a path'
            baseline_file=$2
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

[[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die '--repo must have the form OWNER/REPO'
if [[ -n $head_sha ]]; then
    [[ $probe == no ]] || die '--head cannot be combined with --probe'
    [[ $summary == no ]] || die '--head cannot be combined with --summary'
    [[ $head_sha =~ $SHA_RE ]] || die '--head must be a full 40-character SHA'
    [[ -n $pr ]] || die '--head requires --pr N'
    [[ $pr =~ ^[1-9][0-9]*$ ]] || die '--pr must be a positive integer'
else
    if [[ -n $pr || -n $comments_file || -n $diff_base ]]; then
        [[ $pr =~ ^[1-9][0-9]*$ ]] || die '--pr requires a positive integer'
        [[ -n $comments_file && -n $diff_base ]] ||
            die '--pr requires --comments-file and --diff-base'
        [[ -f $comments_file && ! -L $comments_file && -r $comments_file ]] ||
            die '--comments-file must be a readable regular file'
        [[ -n $diff_head ]] || die '--diff-head must not be empty'
        [[ $probe == no && $summary == no ]] ||
            die '--pr attribution cannot be combined with --probe or --summary'
    else
        [[ -z $pr ]] || die '--pr is only meaningful with --head or attribution'
        [[ -z $comments_file && -z $diff_base ]] || die '--comments-file and --diff-base require --pr'
    fi
    [[ -z $baseline_file ]] || die '--baseline-file is only meaningful with --head'
fi
case $state in
    open|dismissed) ;;
    *) die '--state must be open or dismissed' ;;
esac
((per_page <= 100)) || die '--per-page must be between 1 and 100'
command -v gh >/dev/null 2>&1 || die 'gh is not installed; evidence unavailable'
command -v jq >/dev/null 2>&1 || die 'jq is not installed; evidence unavailable'

if [[ $head_sha != '' ]]; then
    # --- Step 1: is a github-code-quality check-run still running for this
    # head? A generic Checks API read -- always live, unrelated to whether
    # Code Quality itself is reachable -- so an in-flight run always reports
    # pending before anything else is consulted.
    check_runs_response=''
    if ! check_runs_response=$(gh api -X GET \
        "repos/$repository/commits/$head_sha/check-runs?per_page=100" --paginate \
        -H 'X-GitHub-Api-Version: 2026-03-10' 2>&1); then
        printf 'scan-state=unknown reason=%s\n' "$(first_error_line "$check_runs_response")"
        exit 1
    fi
    cq_pending=$(jq -s '
        [.[]? | select(type == "object") | .check_runs[]?
         | select((.app.slug // "") == "github-code-quality")]
        | any(.status != "completed")
    ' <<<"$check_runs_response" 2>/dev/null) || cq_pending=''
    case $cq_pending in
        true)
            printf 'scan-state=pending head=%s\n' "$head_sha"
            exit 0
            ;;
        false) ;;
        *)
            printf 'scan-state=unknown reason=%s\n' \
                'check-runs response could not be read for this head'
            exit 1
            ;;
    esac

    # --- Step 2: is Code Quality reachable at all, and what is the
    # repository-wide open-finding count (also feeds --baseline-file)? The
    # same confirmed-403 rule as --probe decides not-enabled; anything else
    # unreadable is unknown, never complete.
    findings_response=''
    if ! findings_response=$(gh api -X GET \
        "repos/$repository/code-quality/findings?state=open&per_page=100" --paginate \
        -H 'X-GitHub-Api-Version: 2026-03-10' 2>&1); then
        if [[ $findings_response == *'HTTP 403'* ]] && grep -qi 'not enabled' <<<"$findings_response"; then
            printf 'scan-state=not-enabled\n'
            exit 0
        fi
        printf 'scan-state=unknown reason=%s\n' "$(first_error_line "$findings_response")"
        exit 1
    fi
    # --paginate concatenates one JSON value per page; slurp them, same as
    # the check-runs/comments reads above, so repoWideOpen counts every page
    # instead of the first 100 findings (issue #486 item 1). `all` over an
    # EMPTY array is vacuously true, so an empty/blank response would
    # otherwise validate as readable and silently print repoWideOpen=0 --
    # require at least one page before trusting the shape check (root review
    # finding on this PR).
    if ! jq -se '
        (length >= 1) and
        all(.[]; (type == "array") or ((.findings? | type) == "array"))
    ' <<<"$findings_response" >/dev/null 2>&1; then
        printf 'scan-state=unknown reason=%s\n' \
            'Code Quality findings response was not readable JSON'
        exit 1
    fi
    repo_wide_open=$(jq -s '
        [.[]? | if type == "array" then .[]
                 elif (.findings? | type) == "array" then .findings[]
                 else empty end]
        | length
    ' <<<"$findings_response" 2>/dev/null) || repo_wide_open=''
    [[ $repo_wide_open =~ ^[0-9]+$ ]] || repo_wide_open=0

    # --- Step 3: no in-flight scan and Code Quality is reachable --
    # findings-on-head is counted from github-code-quality[bot]'s own PR
    # review comments attributed to this exact commit (commit_id or, for a
    # comment whose thread outlived a force-push, original_commit_id). Zero
    # such comments is a valid, complete, zero-finding scan for this head.
    comments_response=''
    if ! comments_response=$(gh api -X GET \
        "repos/$repository/pulls/$pr/comments?per_page=100" --paginate \
        -H 'X-GitHub-Api-Version: 2026-03-10' 2>&1); then
        printf 'scan-state=unknown reason=%s\n' "$(first_error_line "$comments_response")"
        exit 1
    fi
    findings_on_head=$(jq -s --arg sha "$head_sha" --arg re "$CQ_BOT_RE" '
        [.[]? | select(type == "array") | .[]
         | select(((.user.login // "") | test($re; "i"))
                  and ((.commit_id // "") == $sha or (.original_commit_id // "") == $sha))]
        | length
    ' <<<"$comments_response" 2>/dev/null) || findings_on_head=''
    [[ $findings_on_head =~ ^[0-9]+$ ]] || {
        printf 'scan-state=unknown reason=%s\n' \
            'PR review comments response could not be read for this head'
        exit 1
    }

    if [[ -n $baseline_file ]]; then
        timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '{"head":"%s","findingsOnHead":%s,"repoWideOpen":%s,"timestamp":"%s"}\n' \
            "$head_sha" "$findings_on_head" "$repo_wide_open" "$timestamp" >"$baseline_file" ||
            die "could not write --baseline-file: $baseline_file"
        chmod 600 "$baseline_file" || die "could not chmod 600 --baseline-file: $baseline_file"
    fi

    printf 'scan-state=complete head=%s findings-on-head=%s\n' "$head_sha" "$findings_on_head"
    exit 0
fi

if [[ -n $comments_file ]]; then
    # The public findings endpoint is repository-wide. Attribute only the
    # path/line pairs present in the PR's persisted bot-comment artifact and
    # inside an actual changed-line range from the local PR diff.
    comments_json=''
    if ! comments_json=$(cat -- "$comments_file" 2>&1); then
        die "could not read Code Quality comments artifact: $comments_file"
    fi
    jq -e 'type == "array" and all(.[]; type == "object")' <<<"$comments_json" >/dev/null 2>&1 ||
        die 'Code Quality comments artifact was not a JSON array of objects'

    diff_output=''
    if ! diff_output=$(git diff --no-ext-diff --unified=0 --no-renames \
        "$diff_base...$diff_head" -- 2>&1); then
        die "could not read PR diff $diff_base...$diff_head: $diff_output"
    fi
    changed_ranges=$(awk '
        /^\+\+\+ / {
            path = substr($0, 5)
            sub(/^b\//, "", path)
            next
        }
        /^@@ / {
            hunk = $0
            sub(/^.*\+/, "", hunk)
            sub(/ .*/, "", hunk)
            split(hunk, fields, ",")
            start = fields[1] + 0
            count = (fields[2] == "" ? 1 : fields[2] + 0)
            if (count > 0 && path != "") {
                printf "%s\t%d\t%d\n", path, start, start + count - 1
            }
        }
    ' <<<"$diff_output")

    findings_response=''
    if ! findings_response=$(gh api -X GET \
        "repos/$repository/code-quality/findings?state=open&per_page=100" --paginate \
        -H 'X-GitHub-Api-Version: 2026-03-10' 2>&1); then
        die "Code Quality findings request failed: $(first_error_line "$findings_response")"
    fi
    if ! jq -se '
        (length >= 1) and
        all(.[]; (type == "array") or ((.findings? | type) == "array"))
    ' <<<"$findings_response" >/dev/null 2>&1; then
        die 'Code Quality findings response was not readable JSON'
    fi

    source_file=${comments_file##*/}
    cq_open=$(jq -nr --arg range_text "$changed_ranges" --argjson comments "$comments_json" '
        def changed_ranges:
          [$range_text | split("\n")[] | select(length > 0) | split("\t")
           | {path: .[0], start: (.[1] | tonumber), end: (.[2] | tonumber)}];
        def line_of:
          (.line // .original_line // .location.start_line // empty) | tonumber;
        ($comments | map(select((.path // "") != "")
          | {path: .path, line: line_of})) as $comment_records
        |
        (changed_ranges) as $ranges
        | [$comment_records[] | . as $comment
          | select(any($ranges[]; . as $range
              | $range.path == $comment.path and $comment.line >= $range.start and $comment.line <= $range.end))
          | $comment]
        | length
    ' 2>/dev/null) || cq_open=''
    [[ $cq_open =~ ^[0-9]+$ ]] || die 'Code Quality comments artifact could not be attributed'

    cq_repo=$(jq -s --arg range_text "$changed_ranges" --argjson comments "$comments_json" '
        def changed_ranges:
          [$range_text | split("\n")[] | select(length > 0) | split("\t")
           | {path: .[0], start: (.[1] | tonumber), end: (.[2] | tonumber)}];
        def line_of:
          (.line // .original_line // empty) | tonumber;
        (changed_ranges) as $ranges
        | ($comments
          | [$comments[] | . as $comment
            | select(($comment.path // "") != "")
            | {path: $comment.path, line: ($comment | line_of)}
            | . as $comment_record
            | select(any($ranges[]; . as $range
                | $range.path == $comment_record.path and $comment_record.line >= $range.start and $comment_record.line <= $range.end))
            | $comment_record]
          | unique) as $attributed
        | [ .[]? | if type == "array" then .[]
                  elif (.findings? | type) == "array" then .findings[]
                  else empty end
          | .location? // empty
          | select((.path // "") != "" and (.start_line? != null)) ] as $findings
        | [$findings[] | . as $finding
          | select(any($attributed[]; . as $attributed_finding
              | $attributed_finding.path == $finding.path and $attributed_finding.line == ($finding.start_line | tonumber)) | not)
          | $finding]
        | length
    ' <<<"$findings_response" 2>/dev/null) || cq_repo=''
    [[ $cq_repo =~ ^[0-9]+$ ]] || die 'Code Quality findings could not be classified'

    printf 'cq-repo: %s\n' "$cq_repo"
    printf 'cq-open: %s source=%s\n' "$cq_open" "$source_file"
    exit 0
fi

if [[ $probe == yes ]]; then
    [[ $summary == no ]] || die '--probe cannot be combined with --summary'
    probe_response=''
    if probe_response=$(gh api "repos/$repository/code-quality/findings?state=open&per_page=1" \
        -H 'X-GitHub-Api-Version: 2026-03-10' 2>&1); then
        printf 'state=enabled\n'
        exit 0
    fi
    # A 403 whose message specifically says Code Quality is not enabled is a
    # stable repository fact and may be treated as a decided "not-enabled"
    # answer. Anything else -- a network failure, a 5xx, an auth/scope 403
    # with a different message, gh being unreachable -- is NOT proof of
    # disablement: report unknown and fail closed rather than silently
    # downgrading the provider.
    if [[ $probe_response == *'HTTP 403'* ]] && grep -qi 'not enabled' <<<"$probe_response"; then
        printf 'state=not-enabled\n'
        exit 0
    fi
    printf 'state=unknown reason=%s\n' "$(first_error_line "$probe_response")"
    exit 1
fi

endpoint="repos/$repository/code-quality/findings?state=$state&per_page=$per_page"
response=''
if ! response=$(gh api "$endpoint" -H 'X-GitHub-Api-Version: 2026-03-10' 2>&1); then
    die "Code Quality findings request failed: $(first_error_line "$response")"
fi
jq -e . <<<"$response" >/dev/null 2>&1 || die 'Code Quality API returned malformed JSON'

if [[ $summary == yes ]]; then
    jq -r '
        if type == "array" then .[]
        elif (.findings? | type) == "array" then .findings[]
        else empty end
        | "finding=\(.number // "unknown") path=\(.location.path // "unknown") line=\(.location.start_line // "unknown") state=\(.state // "unknown")"
    ' <<<"$response"
else
    printf '%s\n' "$response"
fi
