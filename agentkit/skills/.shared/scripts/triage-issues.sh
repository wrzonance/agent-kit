#!/usr/bin/env bash
# Triage the candidate issue set in ONE GraphQL request.
#
# The single response satisfies four call sites that used to be separate, two of
# them per issue: issue fetch, board membership + Status, cross-referenced pull
# requests, and the project-item IDs the board cache needs. It also warms
# .agent/cache/board-items.json, so the next board move costs one call.
#
# The verdict vocabulary is limited to what the query PROVES. This script can
# show that a merged pull request references an issue; it cannot show that the
# pull request covered the whole ask, so it reports `merged-ref` and leaves the
# reading to the agent. Likewise `adr=` only locates candidates by token
# overlap -- a pointer, never a gate.
#
# Usage:
#   triage-issues.sh [--repo-root DIR] [--limit N] [--issues N,N,N]
#                    [--fuzzy N] [--json]
#   triage-issues.sh --classify-shape FILE
#
# --classify-shape is a standalone, offline mode: it classifies the work
# shape of an already-fetched issue body (the same bytes Step 3's conflict
# analysis already read -- never a fetch performed for this check alone) and
# exits before any gh/network preflight. It never combines with the query
# flags above.
#
# Exit: 0 success (including a partial response or a --classify-shape
#       verdict), 1 the query failed, 2 bad usage, 3 gh unavailable/
#       unauthenticated (environment-blocked; --classify-shape never reaches
#       this check).
set -euo pipefail

readonly PROGRAM=${0##*/}
readonly CACHE_SCHEMA_VERSION=1
readonly DEFAULT_LIMIT=30

warn() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }
die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}
die_blocked() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 3
}
die_usage() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    printf 'usage: %s [--repo-root DIR] [--limit N] [--issues N,N,N] [--fuzzy N] [--json]\n' \
        "$PROGRAM" >&2
    printf '       %s --classify-shape FILE\n' "$PROGRAM" >&2
    exit 2
}

# Deliberately crude, but defined precisely so it is reproducible -- same
# posture as adr_candidates below: a miss is silence (verdict
# "implementation"), never a blocked run, and a hit is a signal to read and
# confirm, never a final verdict on its own. Anchored to the concrete
# mechanics (branch/commit/pull request/worktree/forge mutation) rather than
# generic words like "read-only" or "research only", which false-positive on
# ordinary feature prose (e.g. "add a read-only mode flag").
#
# Every signal requires PROHIBITIVE framing, not just the bare noun: a bare
# `no commits?` also matches a purely descriptive sentence like "No commits
# currently exist on the bootstrap branch; add the initial configuration",
# which is an implementation ask, not a hold. Each alternative below is
# either an explicit directive verb (do/does/must/should/shall not, never,
# without) acting on the mechanics, or a bare "no X" noun phrase anchored to
# an explicit allow/permit/create verb on either side, so a standalone
# descriptive mention of the noun never fires.
classify_work_shape() {
    local file=$1
    [[ -f $file && -r $file ]] || die_usage "--classify-shape file not readable: $file"
    local -a signals=(
        '\b(do|does|must|should|shall) not (open|create|make|push) (a |any )?(pull requests?|branch(es)?|commits?|worktrees?)'
        '\b(do|does|must|should|shall) not (branch|commit)\b'
        '\bnever (open|create|make|push) (a |any )?(pull requests?|branch(es)?|commits?|worktrees?)'
        '\bnever (branch|commit)\b'
        '\bwithout (opening|creating|making|pushing) (a |any )?(pull requests?|branch(es)?|commits?|worktrees?)'
        '\b(prohibit|forbid|disallow)(s|ed)? (any )?(branch(es)?|worktrees?|commits?|pull requests?|forge mutations?|code changes?)'
        '\bno (commits?|branch(es)?|pull requests?|worktrees?|forge mutations?) (are |is |may be |should be |shall be |will be )?(allowed|permitted|made|created|opened)\b'
        '\b(make|create|open|push) no (commits?|branch(es)?|pull requests?)\b'
        '\bno (code changes?|implementation) (are |is |should be |shall be |will be )?(allowed|permitted|needed|required|expected)\b'
    )
    local pattern
    pattern=$(IFS='|'; printf '%s' "${signals[*]}")
    local matched
    matched=$(grep -iE -m 1 -- "$pattern" "$file" || true)
    # The matched bytes are untrusted issue-body text about to reach a
    # terminal verbatim -- strip every control character (CR/LF/ESC/etc.)
    # before anything else touches it, so an embedded OSC/ANSI escape
    # sequence (e.g. an OSC 52 clipboard write) can never ride along in the
    # printed evidence.
    matched=$(printf '%s' "$matched" | tr -d '[:cntrl:]')
    # Trim surrounding whitespace (markdown indentation, list markers) and cap
    # length so one long paragraph line can't blow up the printed evidence.
    matched="${matched#"${matched%%[![:space:]]*}"}"
    matched="${matched%"${matched##*[![:space:]]}"}"
    if [[ -n $matched ]]; then
        ((${#matched} <= 160)) || matched="${matched:0:160}..."
        printf 'work-shape=no-code signal=%s\n' "$matched"
    else
        printf 'work-shape=implementation signal=-\n'
    fi
}

repo_root=''
repo_root_supplied=0
limit=$DEFAULT_LIMIT
limit_supplied=0
issues=''
issues_supplied=0
fuzzy=''
fuzzy_supplied=0
as_json=0
classify_shape_file=''
classify_shape_supplied=0

# Every query flag tracks whether it was actually SUPPLIED, not just its
# final value: an explicit `--limit 30` is indistinguishable from the
# default by value alone, and would otherwise silently pass the
# --classify-shape combination check below.
while (($#)); do
    case $1 in
        --repo-root)
            shift
            (($#)) || die_usage '--repo-root requires a directory'
            repo_root=$1
            repo_root_supplied=1
            ;;
        --limit)
            shift
            (($#)) || die_usage '--limit requires a number'
            limit=$1
            limit_supplied=1
            ;;
        --issues)
            shift
            (($#)) || die_usage '--issues requires a comma-separated list'
            issues=$1
            issues_supplied=1
            ;;
        --fuzzy)
            shift
            (($#)) || die_usage '--fuzzy requires an issue number'
            fuzzy=$1
            fuzzy_supplied=1
            ;;
        --json) as_json=1 ;;
        --classify-shape)
            shift
            (($#)) || die_usage '--classify-shape requires a file path'
            classify_shape_file=$1
            classify_shape_supplied=1
            ;;
        -h | --help) die_usage 'help requested' ;;
        *) die_usage "unknown argument: $1" ;;
    esac
    shift
done

# classify_shape_supplied -- never a bare `-n $classify_shape_file` check --
# is what routes into the offline classifier: an empty `--classify-shape ""`
# must never fall through into the live gh query path below.
if ((classify_shape_supplied)); then
    [[ -n $classify_shape_file ]] || die_usage '--classify-shape requires a non-empty file path'
    ((repo_root_supplied == 0 && limit_supplied == 0 && issues_supplied == 0 &&
        fuzzy_supplied == 0 && as_json == 0)) ||
        die_usage '--classify-shape does not combine with the query flags'
    classify_work_shape "$classify_shape_file"
    exit 0
fi

[[ $limit =~ ^[0-9]{1,3}$ ]] || die_usage "--limit must be a number, got: $limit"
[[ -z $issues || $issues =~ ^[0-9]+(,[0-9]+)*$ ]] ||
    die_usage "--issues must be comma-separated numbers, got: $issues"
[[ -z $fuzzy || $fuzzy =~ ^[0-9]+$ ]] || die_usage "--fuzzy must be an issue number, got: $fuzzy"

# Preflight before ANY external command, so a stripped PATH reports the honest
# reason rather than dying at 127 inside a coreutil. jq is the evidence parser:
# its absence is blocked evidence, never an empty digest.
command -v jq > /dev/null 2>&1 || die_blocked 'jq is not installed; evidence unavailable'
for tool in gh jq dirname readlink mktemp; do
    command -v "$tool" > /dev/null 2>&1 || die_blocked "$tool is not installed"
done

# Deliberately NOT `gh auth status` up front: that is itself an API round-trip,
# and this script runs every session. The query below is attempted first, and a
# call is spent classifying the failure only when there is a failure to classify.
classify_failure() {
    gh auth status > /dev/null 2>&1 || die_blocked 'gh is not authenticated'
    die "$1"
}

if [[ -z $repo_root ]]; then
    repo_root=$(git rev-parse --show-toplevel 2> /dev/null || true)
fi
[[ -n $repo_root ]] || die_usage 'not inside a git repository; pass --repo-root'

self_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
resolver="$self_dir/repo-config.sh"

slug=''
adr_dir=''
if [[ -x $resolver ]]; then
    slug=$("$resolver" --repo-root "$repo_root" --get AGENT_REPO_SLUG 2> /dev/null || true)
    adr_dir=$("$resolver" --repo-root "$repo_root" --get AGENT_ADR_DIR 2> /dev/null || true)
fi
if [[ -z $slug ]]; then
    slug=$(gh repo view --json nameWithOwner -q .nameWithOwner 2> /dev/null || true)
fi
[[ $slug =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die 'could not resolve the repository slug'
owner=${slug%%/*}
name=${slug#*/}

# --------------------------------------------------------------- the query ---
# Verified against a live Projects v2 board: fieldValueByName("Status"),
# timelineItems(itemTypes:[CROSS_REFERENCED_EVENT]), projectItems{id}, and
# subIssues all resolve. Issue bodies remain outside this digest: the selected
# issue's canonical preparation read supplies task-list tracker evidence.
readonly ISSUE_FIELDS='
    number
    title
    labels(first: 20) { nodes { name } }
    subIssues(first: 1) { totalCount }
    projectItems(first: 5) {
      nodes {
        id
        project { id number title }
        fieldValueByName(name: "Status") {
          ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
        }
      }
    }
    timelineItems(first: 50, itemTypes: [CROSS_REFERENCED_EVENT]) {
      nodes {
        ... on CrossReferencedEvent {
          source {
            ... on PullRequest { number state merged mergedAt updatedAt title }
          }
        }
      }
    }'

# The query documents are single constants so that ONE shellcheck annotation
# covers each: a disable directive applies only to the next command, not to a
# whole function full of printfs.
#
# shellcheck disable=SC2016  # $owner/$name/$first are GraphQL variables declared
# in the document and bound by gh's -F flags. Single quotes are precisely what
# stops the shell from substituting them.
readonly AUTO_QUERY='query($owner: String!, $name: String!, $first: Int!) {
  repository(owner: $owner, name: $name) {
    issues(first: $first, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes { @FIELDS@ }
    }
  }
}'

# Explicit mode aliases one sub-query per issue, so naming issues is still a
# single request rather than one call each.
#
# shellcheck disable=SC2016  # GraphQL variables again; see AUTO_QUERY.
readonly EXPLICIT_HEAD='fragment IssueBits on Issue { @FIELDS@ }
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {'

readonly EXPLICIT_TAIL='  }
}'

build_auto_query() { printf '%s\n' "${AUTO_QUERY//@FIELDS@/$ISSUE_FIELDS}"; }

build_explicit_query() {
    local n
    local -a numbers=()
    IFS=, read -ra numbers <<< "$1"
    printf '%s\n' "${EXPLICIT_HEAD//@FIELDS@/$ISSUE_FIELDS}"
    for n in "${numbers[@]}"; do
        printf '    i%s: issue(number: %s) { ...IssueBits }\n' "$n" "$n"
    done
    printf '%s\n' "$EXPLICIT_TAIL"
}

raw_response_file="$repo_root/.agent/cache/triage-response.json"
raw_response_tmp=''
if [[ ! -L $raw_response_file ]] &&
    mkdir -p -- "${raw_response_file%/*}" 2>/dev/null; then
    raw_response_tmp=$(mktemp "${raw_response_file%/*}/.triage-response.XXXXXX" 2>/dev/null || true)
fi
if [[ -z $raw_response_tmp ]]; then
    raw_response_tmp=$(mktemp "${TMPDIR:-/tmp}/triage-response.XXXXXX" 2>/dev/null || true)
    [[ -n $raw_response_tmp ]] || die 'could not create a raw triage evidence cache; evidence unavailable'
    raw_response_file="$raw_response_tmp"
    warn "repo-local raw cache unavailable; using temporary evidence cache $raw_response_file"
fi
chmod 600 -- "$raw_response_tmp" || die 'could not secure the raw triage response file'
if [[ -n $issues ]]; then
    query=$(build_explicit_query "$issues")
    gh api graphql -F "owner=$owner" -F "name=$name" -f "query=$query" \
        >"$raw_response_tmp" 2> /dev/null || true
else
    query=$(build_auto_query)
    gh api graphql -F "owner=$owner" -F "name=$name" -F "first=$limit" \
        -f "query=$query" >"$raw_response_tmp" 2> /dev/null || true
fi
if [[ "$raw_response_tmp" != "$raw_response_file" ]]; then
    if [[ -s $raw_response_tmp ]]; then
        if ! mv -- "$raw_response_tmp" "$raw_response_file"; then
            warn "could not publish repo-local raw cache; using temporary evidence cache $raw_response_tmp"
            raw_response_file="$raw_response_tmp"
        fi
    else
        rm -f -- "$raw_response_tmp"
        classify_failure 'the GraphQL query returned nothing'
    fi
elif [[ ! -s $raw_response_file ]]; then
    rm -f -- "$raw_response_file"
    classify_failure 'the GraphQL query returned nothing'
fi
# Keep the fetched bytes on disk before the first parser invocation. If jq
# rejects malformed evidence, the raw response remains available for diagnosis.
jq -e . <"$raw_response_file" > /dev/null 2>&1 ||
    classify_failure 'the GraphQL response was not valid JSON'

if jq -e '.errors' <"$raw_response_file" > /dev/null 2>&1; then
    warn "the query reported errors; affected issues are classified 'unknown'"
fi

# Both query shapes normalize to one flat array, so there is exactly one classifier.
nodes=$(jq -c '
    if (.data.repository.issues.nodes? != null)
    then .data.repository.issues.nodes
    else [ (.data.repository // {}) | to_entries[] | .value | select(type == "object") ]
    end' <"$raw_response_file")

# ---------------------------------------------------------- classification ---
# Precedence, highest first: unknown, done, active, in-flight, attempted,
# merged-ref, clean. A state that should stop a dispatch outranks a state that
# merely warrants reading, so the most restrictive applicable verdict wins.
# shellcheck disable=SC2016  # $i/$prs/$st/$c are jq bindings, not shell ones.
readonly CLASSIFY_JQ='
def pulls:
  [ .timelineItems.nodes[]? | .source? | select(type == "object" and .number != null) ];
def board_status:
  (.projectItems.nodes[0]?.fieldValueByName?.name // "-");
def winner($c): ($c | sort_by(.updatedAt // "") | reverse | .[0]);
def tracker_reasons($selected):
  . as $i
  | ([ $i.labels.nodes[]?.name? | select(type == "string") | ascii_downcase
       | select(. == "epic" or . == "tracker")
       | "label:\(.)" ]
     + (if (($i.subIssues.totalCount // 0) > 0)
        then ["sub-issues"] else [] end));
(. as $input | ($input | map(.number)) as $selected | $input | map(
  . as $i
  | (pulls) as $prs
  | (board_status) as $st
  | (tracker_reasons($selected)) as $tracker_reasons
  | (if ($i.number == null) or ($i.timelineItems == null) or ($i.projectItems == null)
     then {verdict: "unknown", pr: null, extra: 0}
     elif $st == "Done" then {verdict: "done", pr: null, extra: 0}
     elif ($st == "In progress" or $st == "In review")
       then {verdict: "active", pr: null, extra: 0}
     else
       ([$prs[] | select(.state == "OPEN")]) as $open
       | ([$prs[] | select(.state == "CLOSED" and (.merged != true))]) as $dead
       | ([$prs[] | select(.merged == true)]) as $merged
       | (if ($open | length) > 0
            then {verdict: "in-flight", pr: winner($open), extra: (($prs | length) - 1)}
          elif ($dead | length) > 0
            then {verdict: "attempted", pr: winner($dead), extra: (($prs | length) - 1)}
          elif ($merged | length) > 0
            then {verdict: "merged-ref", pr: winner($merged), extra: (($prs | length) - 1)}
          else {verdict: "clean", pr: null, extra: 0}
          end)
     end) as $c
  | {number: ($i.number // 0),
     title: ($i.title // ""),
     status: $st,
     itemId: ($i.projectItems.nodes[0]?.id // null),
     projectId: ($i.projectItems.nodes[0]?.project?.id // null),
     verdict: $c.verdict,
     pr: $c.pr,
     extra: (if ($c.extra // 0) > 0 then $c.extra else 0 end),
     tracker: (($tracker_reasons | length) > 0),
     trackerReason: $tracker_reasons}
)
)
| map(select(.verdict != "done"))
| sort_by(.number) | reverse'

records=$(jq -c "$CLASSIFY_JQ" <<< "$nodes")

# ------------------------------------------------------------ ADR pointers ---
# Deliberately crude, but defined precisely so it is reproducible: lowercase the
# title, drop short tokens and a small stopword list, and score each ADR by how
# many surviving tokens appear in its filename or its "# "/"title:" line. A miss
# is silence, never a blocked run.
adr_candidates() {
    local title=$1
    [[ -n $adr_dir && -d $repo_root/$adr_dir ]] || {
        printf -- '-'
        return 0
    }

    local -a tokens=()
    local word
    for word in $(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' '); do
        ((${#word} >= 4)) || continue
        case $word in
            with | that | this | from | into | when | have | your | ours | then | than | make | been) continue ;;
        esac
        tokens+=("$word")
    done
    ((${#tokens[@]})) || {
        printf -- '-'
        return 0
    }

    local file haystack score
    local -a scored=()
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        haystack=$(printf '%s\n%s' "$(basename -- "$file")" \
            "$(grep -m2 -E '^(# |title:)' "$file" 2> /dev/null || true)" |
            tr '[:upper:]' '[:lower:]')
        score=0
        for word in "${tokens[@]}"; do
            [[ $haystack == *"$word"* ]] && score=$((score + 1))
        done
        ((score >= 2)) && scored+=("$score	${file#"$repo_root"/}")
    done < <(find "$repo_root/$adr_dir" -maxdepth 2 -type f -name '*.md' 2> /dev/null | sort)

    ((${#scored[@]})) || {
        printf -- '-'
        return 0
    }
    printf '%s\n' "${scored[@]}" | sort -rn | head -n 2 | cut -f2 | paste -sd, -
}

# ------------------------------------------------------------- item cache ----
write_item_cache() {
    local project_id staged cache_dir="$repo_root/.agent/cache"
    project_id=$(jq -r 'map(select(.projectId != null)) | .[0].projectId // empty' <<< "$records")
    [[ -n $project_id ]] || return 0
    mkdir -p -- "$cache_dir" 2> /dev/null || return 0
    staged=$(mktemp "$cache_dir/.items.XXXXXX") || return 0
    if jq --argjson v "$CACHE_SCHEMA_VERSION" --arg p "$project_id" '{
            schemaVersion: $v,
            project: $p,
            items: (map(select(.itemId != null and .projectId == $p))
                    | map({key: (.number | tostring), value: .itemId})
                    | from_entries)
        }' <<< "$records" > "$staged" 2> /dev/null; then
        mv -- "$staged" "$cache_dir/board-items.json"
    else
        rm -f -- "$staged"
    fi
}
write_item_cache

# ----------------------------------------------------------------- output ----
if ((as_json)); then
    printf '%s\n' "$records" | jq .
    exit 0
fi

count=$(jq 'length' <<< "$records")
cached=0
if [[ -r $repo_root/.agent/cache/board-items.json ]]; then
    cached=$(jq '.items | length' < "$repo_root/.agent/cache/board-items.json" 2> /dev/null || printf '0')
fi
printf 'triage= repo=%s issues=%s calls=1 items-cached=%s\n\n' "$slug" "$count" "$cached"

while IFS=$'\t' read -r number title status verdict pr_num pr_state pr_merged_at extra tracker tracker_reason; do
    [[ -n $number ]] || continue
    pr_cell='-'
    if [[ $pr_num != '-' ]]; then
        case $pr_state in
            MERGED) pr_cell="#$pr_num merged ${pr_merged_at%%T*}" ;;
            OPEN) pr_cell="#$pr_num open" ;;
            CLOSED) pr_cell="#$pr_num closed-unmerged" ;;
            *) pr_cell="#$pr_num $pr_state" ;;
        esac
        if ((extra > 0)); then
            pr_cell="$pr_cell (+$extra more)"
        fi
    fi
    tracker_cell=''
    [[ $tracker == true ]] && tracker_cell=" tracker(${tracker_reason:--})"
    printf '#%-5s %-13s %-11s adr=%-24s pr=%s%s\n' \
        "$number" "$status" "$verdict" "$(adr_candidates "$title")" "$pr_cell" "$tracker_cell"
    # Every column uses "-" for absent, never "". Tab is an IFS *whitespace*
    # character, so `read` collapses consecutive tabs -- one empty field would
    # silently shift every later column left.
done < <(jq -r '.[] | [.number, .title, .status, .verdict,
    (.pr.number // "-"), (.pr.state // "-"), (.pr.mergedAt // "-"), .extra,
    .tracker, (.trackerReason | join(","))] | @tsv' <<< "$records")

# ------------------------------------------------------------------ fuzzy ----
# Opt-in only. Finds pull requests that never referenced the issue -- the
# lowest-yield call in the set, and running it per issue is exactly the storm
# this script exists to remove.
if [[ -n $fuzzy ]]; then
    fuzzy_title=$(jq -r --argjson n "$fuzzy" \
        'map(select(.number == $n)) | .[0].title // empty' <<< "$records")
    if [[ -n $fuzzy_title ]]; then
        printf '\nfuzzy prior art for #%s:\n' "$fuzzy"
        gh pr list --repo "$slug" --state merged --limit 50 \
            --json number,title,mergedAt --search "$fuzzy_title" 2> /dev/null |
            jq -r '.[]? | "  #\(.number) \(.title) (merged \(.mergedAt[0:10]))"' ||
            printf '  (search unavailable)\n'
    fi
fi

exit 0
