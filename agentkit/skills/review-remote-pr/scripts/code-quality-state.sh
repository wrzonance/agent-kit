#!/usr/bin/env bash
# Fetch GitHub Code Quality findings for inspection.  This helper is
# deliberately retrieval-only: GitHub exposes no supported per-finding
# dismissal mutation here, so dismissal remains a human/provider action.
set -uo pipefail

readonly PROGRAM=${0##*/}
readonly SHA_RE='^[0-9a-f]{40}$'
repository=''
state=open
per_page=100
summary=no
probe=no
head_sha=''

usage() {
    cat <<'EOF'
Usage: code-quality-state.sh --repo OWNER/REPO [--state open|dismissed] [--per-page N] [--summary]
       code-quality-state.sh --repo OWNER/REPO --probe
       code-quality-state.sh --repo OWNER/REPO --head SHA40

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

--head SHA40 decides the merge-gate's per-head scan-state token directly
from the Code Quality API's own completed-analysis record for that commit
(never from a check-run app slug). It prints exactly one line:
  scan-state=complete head=<sha> findings-on-head=<n>
  scan-state=pending head=<sha>
  scan-state=not-enabled
  scan-state=unknown reason=<first line of the underlying error>
and exits 0 for complete/pending/not-enabled, 1 for unknown -- an unreadable
record never maps to complete. findings-on-head is the completed analysis's
own attributed-to-this-commit finding count, distinct from the repository-
wide open-finding count --state/--summary report above. --head always
queries its own minimal page; --state and --per-page are ignored (and
--head cannot be combined with --probe or --summary).
EOF
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

while (($#)); do
    case $1 in
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
fi
case $state in
    open|dismissed) ;;
    *) die '--state must be open or dismissed' ;;
esac
((per_page <= 100)) || die '--per-page must be between 1 and 100'
command -v gh >/dev/null 2>&1 || die 'gh is not installed; evidence unavailable'
command -v jq >/dev/null 2>&1 || die 'jq is not installed; evidence unavailable'

if [[ $head_sha != '' ]]; then
    analyses_response=''
    # -X GET is required here: gh api infers POST whenever -f/-F fields are
    # present, and this is a filtered read, never a write (issue #472 review).
    if analyses_response=$(gh api -X GET "repos/$repository/code-quality/analyses" \
        -f "ref=$head_sha" -F per_page=100 -H 'X-GitHub-Api-Version: 2026-03-10' 2>&1); then
        if ! jq -e 'type == "array"' <<<"$analyses_response" >/dev/null 2>&1; then
            printf 'scan-state=unknown reason=%s\n' \
                'Code Quality analyses response was not a readable JSON array'
            exit 1
        fi
        # Only a completed analysis actually recorded against this exact
        # commit counts as proof of completion -- an empty (but readable)
        # array is a normal, still-outstanding scan, not an error.
        match_count=$(jq --arg sha "$head_sha" '[.[] | select(.commit_sha == $sha)] | length' \
            <<<"$analyses_response" 2>/dev/null) || match_count=''
        if [[ $match_count =~ ^[0-9]+$ ]] && ((match_count > 0)); then
            # No `// 0` fallback here: a missing or null findings_count must
            # never be read as a clean zero-finding scan (issue #472 review,
            # F1) -- it prints as the bare token `null`, which the readable-
            # integer check below correctly refuses same as any other
            # unreadable value.
            findings_on_head=$(jq --arg sha "$head_sha" '
                [.[] | select(.commit_sha == $sha)] | sort_by(.created_at // "") | last
                | .findings_count
            ' <<<"$analyses_response" 2>/dev/null) || findings_on_head=''
            if [[ $findings_on_head =~ ^[0-9]+$ ]]; then
                printf 'scan-state=complete head=%s findings-on-head=%s\n' "$head_sha" "$findings_on_head"
                exit 0
            fi
            printf 'scan-state=unknown reason=%s\n' \
                'the completed analysis for this head carried no readable findings_count'
            exit 1
        elif [[ $match_count =~ ^[0-9]+$ ]]; then
            printf 'scan-state=pending head=%s\n' "$head_sha"
            exit 0
        fi
        printf 'scan-state=unknown reason=%s\n' \
            'Code Quality analyses response could not be filtered for this head'
        exit 1
    fi
    # Same not-enabled classification as --probe: only a 403 whose message
    # specifically says Code Quality is not enabled is a decided, stable
    # repository fact. Everything else is unknown, never complete.
    if [[ $analyses_response == *'HTTP 403'* ]] && grep -qi 'not enabled' <<<"$analyses_response"; then
        printf 'scan-state=not-enabled\n'
        exit 0
    fi
    printf 'scan-state=unknown reason=%s\n' "$(head -n 1 <<<"$analyses_response")"
    exit 1
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
    printf 'state=unknown reason=%s\n' "$(head -n 1 <<<"$probe_response")"
    exit 1
fi

endpoint="repos/$repository/code-quality/findings?state=$state&per_page=$per_page"
response=''
if ! response=$(gh api "$endpoint" -H 'X-GitHub-Api-Version: 2026-03-10' 2>&1); then
    die "Code Quality findings request failed: $(head -n 1 <<<"$response")"
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
