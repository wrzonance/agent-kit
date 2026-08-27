#!/usr/bin/env bash
# Discover and verify a stable serial queue of pull requests.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
GH_BIN=${PR_QUEUE_GH:-gh}
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/gh-budget.sh"
readonly EXIT_RATE_LIMITED=$GH_BUDGET_RATE_LIMIT_EXIT
# Per-PR REST-call estimate for the --write-confirmed-queue preflight warning
# (agent-kit#475): pr-to-green's own SKILL.md documents --full running at
# several phases per queued PR (pre-review digest, post-push refresh,
# pre-gate refresh) at ~8 REST calls apiece on a cache miss, plus one
# --wait-ci cycle at its default --rounds (~5 REST calls on round 1, ~3/round
# after -- rounded up to a flat ~5/round here since the estimate only needs
# to be a believable order of magnitude, not exact).
readonly FULL_READS_PER_PR=3
readonly REST_CALLS_PER_FULL_READ=8
readonly WAIT_ROUNDS_PER_PR=4
readonly REST_CALLS_PER_WAIT_ROUND=5
repo=''
repo_root=''
merge_plan=''
plan_option=''
format=table
write_confirmed_queue=0
no_providers=0
declare -a providers=()
declare -a explicit_prs=()
work_dir=''
output_tmp=''

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

warn() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }

# Wraps a "gh api ... unavailable" die path: a rate-limit refusal
# (agent-kit#475) gets the reset time appended and exits EXIT_RATE_LIMITED
# instead of the ordinary usage/API-failure exit, so a caller can tell "stop
# and report the reset time" apart from any other failure.
die_on_gh_failure() {
    local context=$1 err=$2 reset
    if gh_budget_is_exhausted "$err"; then
        reset=$(gh_budget_reset_for_error "$err" "$GH_BIN") || reset=unknown
        printf '%s: %s: %s reset=%s\n' "$PROGRAM" "$context" "$err" "$reset" >&2
        exit "$EXIT_RATE_LIMITED"
    fi
    die "$context: $err"
}

usage() {
    cat >&2 <<EOF
usage: $PROGRAM --repo OWNER/REPO [--repo-root DIR]
                [--merge-plan FILE, --dispatch-plan FILE]
                [--pr N ...] [--format records|table|json]
                [--write-confirmed-queue
                   (--provider NAME:ACTION:SOURCE ... | --no-providers)]

  --merge-plan FILE, --dispatch-plan FILE
      aliases for the same file after the ready-flip upgrade; dispatch-plan
      names its schema-1 stage and merge-plan names its schema-2 stage
EOF
    exit "${1:-2}"
}

while (($#)); do
    case $1 in
        --repo)
            (($# >= 2)) || usage
            repo=$2
            shift 2
            ;;
        --repo-root)
            (($# >= 2)) || usage
            repo_root=$2
            shift 2
            ;;
        --merge-plan|--dispatch-plan)
            (($# >= 2)) || usage
            merge_plan=$2
            plan_option=merge-plan
            shift 2
            ;;
        --pr)
            (($# >= 2)) || usage
            explicit_prs+=("$2")
            shift 2
            ;;
        --format)
            (($# >= 2)) || usage
            format=$2
            shift 2
            ;;
        --write-confirmed-queue)
            write_confirmed_queue=1
            shift
            ;;
        --provider)
            (($# >= 2)) || usage
            providers+=("$2")
            shift 2
            ;;
        --no-providers)
            ((no_providers == 0)) || die '--no-providers may be passed only once'
            no_providers=1
            shift
            ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

[[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
    die '--repo must have the form OWNER/REPO'
[[ $format == records || $format == table || $format == json ]] ||
    die '--format must be records, table, or json'
for pr in "${explicit_prs[@]}"; do
    [[ $pr =~ ^[1-9][0-9]*$ ]] || die "--pr expects a positive integer: $pr"
done
command -v "$GH_BIN" >/dev/null 2>&1 || die "required tool not found: $GH_BIN"
command -v jq >/dev/null 2>&1 || die 'jq is required; queue evidence unavailable'

if [[ -n $repo_root ]]; then
    [[ -d $repo_root ]] || die "--repo-root is not a directory: $repo_root"
    repo_root=$(cd -- "$repo_root" && pwd -P) || die 'could not resolve --repo-root'
fi
if ((write_confirmed_queue)); then
    [[ -n $repo_root ]] || die '--write-confirmed-queue requires --repo-root'
    [[ ! -L $repo_root && -O $repo_root ]] ||
        die '--repo-root must be an owned directory, not a symlink'
    [[ -d $repo_root/.agent && ! -L $repo_root/.agent && -O $repo_root/.agent ]] ||
        die '.agent must be an owned directory, not a symlink'
    if ((no_providers)); then
        ((${#providers[@]} == 0)) || die '--no-providers cannot be combined with --provider'
    else
        ((${#providers[@]} > 0)) ||
            die 'pass each --provider NAME:ACTION:SOURCE or pass --no-providers explicitly'
    fi
else
    ((no_providers == 0 && ${#providers[@]} == 0)) ||
        die 'provider decisions require --write-confirmed-queue'
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/pr-queue.XXXXXX") || die 'could not create work directory'
chmod 700 "$work_dir"
cleanup() {
    rm -rf -- "$work_dir"
    [[ -z $output_tmp || ! -e $output_tmp ]] || rm -f -- "$output_tmp"
}
trap cleanup EXIT HUP INT TERM

if ((write_confirmed_queue)); then
    : >"$work_dir/providers.jsonl"
    declare -A seen_providers=()
    for provider in "${providers[@]}"; do
        IFS=: read -r name action source extra <<<"$provider"
        [[ -n $name && -n $action && -n $source && -z ${extra:-} ]] ||
            die '--provider must have the form NAME:ACTION:SOURCE'
        [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid provider name: $name"
        case $action in trigger|observe|disabled) ;;
            *) die "invalid provider action for $name: $action" ;;
        esac
        [[ -z ${seen_providers[$name]+set} ]] || die "duplicate provider: $name"
        seen_providers[$name]=1
        jq -cn --arg name "$name" --arg action "$action" --arg source "$source" \
            '{name:$name,action:$action,source:$source}' >>"$work_dir/providers.jsonl"
    done
    jq -s '.' "$work_dir/providers.jsonl" >"$work_dir/providers.json"
fi

api() {
    "$GH_BIN" api "$@"
}

api "repos/$repo" >"$work_dir/repo.json" 2>"$work_dir/api.err" ||
    die_on_gh_failure 'repository metadata unavailable' "$(head -n 1 "$work_dir/api.err")"
default_branch=$(jq -er '.default_branch | select(type == "string" and length > 0)' \
    "$work_dir/repo.json" 2>/dev/null) || die 'repository metadata omitted default_branch'

validate_prs() {
    jq -e '
      type == "array" and all(.[];
        (.number | type) == "number" and .number > 0 and
        ((.state == "open") or (.state == "closed")) and
        ((.draft | type) == "boolean") and
        ((.merged | type) == "boolean") and
        ((.mergeable == null) or ((.mergeable | type) == "boolean")) and
        ((.created_at | type) == "string") and
        ((.head.ref | type) == "string" and (.head.ref | length) > 0) and
        ((.head.sha | type) == "string" and (.head.sha | test("^[0-9a-f]{40}$"))) and
        ((.base.ref | type) == "string" and (.base.ref | length) > 0)
      )
    ' "$1" >/dev/null 2>&1
}

fetch_one() {
    local number=$1 out=$2
    api "repos/$repo/pulls/$number" >"$out" 2>"$work_dir/api.err" ||
        die_on_gh_failure "pull request #$number is unavailable" "$(head -n 1 "$work_dir/api.err")"
    jq -e 'type == "object"' "$out" >/dev/null 2>&1 ||
        die "pull request #$number returned malformed JSON"
}

# An explicitly named PR is queued by number alone; a closed PR must never
# reach classification, where a stale mergeable:true could still read RUNNABLE.
fetch_open_one() {
    local number=$1 out=$2
    fetch_one "$number" "$out"
    [[ $(jq -r '.state' "$out") == open ]] || die "pull request #$number is not open"
}

plan_active=0
# shellcheck disable=SC2034 # retained for transition diagnostics
plan_drift=0
if [[ -n $merge_plan ]]; then
    [[ -f $merge_plan && ! -L $merge_plan && -O $merge_plan ]] ||
        die "--merge-plan must be an owned regular file, not a symlink: $merge_plan"
    plan_schema=$(jq -er '
      if type == "object" and (.schemaVersion | type) == "number"
      then .schemaVersion else empty end
    ' "$merge_plan" 2>/dev/null) ||
        die 'input is not a recognized dispatch/merge plan (schemaVersion is missing or invalid)'
    case $plan_schema in
        1)
            die 'schema-1 dispatch plan still needs the ready-flip upgrade; run write-merge-plan.sh'
            ;;
        2) ;;
        *) die "input is not a recognized dispatch/merge plan (unsupported schemaVersion: $plan_schema)" ;;
    esac
    jq -e '
      def uint: type == "number" and . > 0 and floor == .;
      def sha: type == "string" and test("^[0-9a-f]{40}$");
      def branch: type == "string" and test("^[A-Za-z0-9._/-]+$") and
        (startswith("-") | not) and (contains("..") | not);
      def record: (.issue | uint) and (.pr | uint) and (.branch | branch) and
        (.headSha | sha) and ((.chainBaseSha == null) or (.chainBaseSha | sha));
      .schemaVersion == 2 and
      ((.generatedAt | type) == "string") and
      ((.independent | type) == "array") and ((.chains | type) == "array") and
      all(.independent[]; record and .chainBaseSha == null) and
      all(.chains[]; . as $chain |
        ($chain | type) == "array" and ($chain | length) >= 2 and
        all($chain[]; record) and $chain[0].chainBaseSha == null and
        all(range(1; $chain | length); . as $i |
          $chain[$i].chainBaseSha == $chain[$i-1].headSha)) and
      ([.independent[], .chains[][]] as $all |
        ($all | length) > 0 and
        (($all | map(.pr) | unique | length) == ($all | length)) and
        (($all | map(.issue) | unique | length) == ($all | length)) and
        (($all | map(.branch) | unique | length) == ($all | length)))
    ' "$merge_plan" >/dev/null 2>&1 ||
        die 'schema-2 merge plan has invalid topology: malformed records, cycles, joins, or ambiguity'

    jq --arg base "$default_branch" '([.chains | to_entries[] as $chain |
          $chain.value | to_entries[] as $entry |
          $entry.value + {group:("chain-" + ($chain.key|tostring)), position:$entry.key,
            expectedBase:(if $entry.key == 0 then $base else $chain.value[$entry.key - 1].branch end)}] +
         [.independent | to_entries[] as $entry |
         $entry.value + {group:("independent-" + ($entry.key|tostring)), position:0, expectedBase:$base}])' \
        "$merge_plan" >"$work_dir/plan-records.json"

    while IFS= read -r number; do
        fetch_one "$number" "$work_dir/pr-$number.json"
    done < <(jq -r '.[].pr' "$work_dir/plan-records.json")
    jq -s '.' "$work_dir"/pr-*.json >"$work_dir/live.json"
    validate_prs "$work_dir/live.json" || die 'a merge-plan verification response was malformed'

    if ! jq -e --slurpfile live "$work_dir/live.json" '
      all(.[]; . as $record |
        ([ $live[0][] | select(.number == $record.pr) ] | length) == 1 and
        ([ $live[0][] | select(.number == $record.pr) ][0].head.ref == $record.branch) and
        ([ $live[0][] | select(.number == $record.pr) ][0].head.sha == $record.headSha) and
        ([ $live[0][] | select(.number == $record.pr) ][0].base.ref == $record.expectedBase))
    ' "$work_dir/plan-records.json" >/dev/null; then
        plan_drift=1
        while IFS=$'\t' read -r refreshed_pr old_sha new_sha; do
            warn "refreshed=#$refreshed_pr old=${old_sha:0:7} new=${new_sha:0:7}"
        done < <(jq -r --slurpfile live "$work_dir/live.json" '
          .[] as $record |
          ([ $live[0][] | select(.number == $record.pr) ][0]) as $pr |
          select($pr.head.sha != $record.headSha or $pr.base.ref != $record.expectedBase) |
          [$record.pr,$record.headSha,$pr.head.sha] | @tsv
        ' "$work_dir/plan-records.json")
    fi
    plan_active=1
    : "$plan_drift"
fi

if ((plan_active == 0)); then
    if [[ -z $merge_plan || ${#explicit_prs[@]} -gt 0 ]]; then
        if ((${#explicit_prs[@]})); then
            for number in "${explicit_prs[@]}"; do
                fetch_open_one "$number" "$work_dir/explicit-$number.json"
            done
            jq -s '.' "$work_dir"/explicit-*.json >"$work_dir/live.json"
        else
            # The list representation omits fields (.merged, .mergeable) that
            # validate_prs and the classifier require. Use it only to enumerate
            # candidate numbers, then fetch each candidate's full representation.
            api "repos/$repo/pulls?state=open&per_page=100" --paginate --slurp \
                >"$work_dir/list.json" \
                2>"$work_dir/api.err" ||
                die_on_gh_failure 'open pull request discovery failed' "$(head -n 1 "$work_dir/api.err")"
            jq 'if type == "array" and length > 0 and all(.[]; type == "array") then add else . end |
                map(select(.draft == true)) | map(.number)' \
                "$work_dir/list.json" >"$work_dir/candidate-numbers.json" 2>/dev/null ||
                die 'open pull request discovery returned malformed JSON'
            if [[ $(jq 'length' "$work_dir/candidate-numbers.json") -eq 0 ]]; then
                printf '[]' >"$work_dir/live.json"
            else
                while IFS= read -r number; do
                    fetch_one "$number" "$work_dir/discovered-$number.json"
                done < <(jq -r '.[]' "$work_dir/candidate-numbers.json")
                # Defensive: the list query already selected state=open, but a
                # candidate can close between that read and this fetch.
                jq -s 'map(select(.state == "open"))' "$work_dir"/discovered-*.json \
                    >"$work_dir/live.json"
            fi
        fi
    fi
    validate_prs "$work_dir/live.json" || die 'pull request discovery returned malformed records'

    source=forge
    issue_map='[]'
    [[ ! -f $work_dir/plan-records.json ]] || issue_map=$(jq '[.[] | {pr,issue}]' "$work_dir/plan-records.json")

    # Forge bases form a graph with one possible predecessor per PR. Reject an
    # unknown base, duplicate head, fork, or cycle before emitting any queue.
    if ! jq -e --arg base "$default_branch" '
      . as $prs |
      (map(.number) | unique | length) == length and
      (map(.head.ref) | unique | length) == length and
      all(.[]; (.base.ref == $base) or (.base.ref as $b | any($prs[]; .head.ref == $b))) and
      all($prs[]; . as $parent |
        ([ $prs[] | select(.base.ref == $parent.head.ref) ] | length) <= 1)
    ' "$work_dir/live.json" >/dev/null; then
        die 'forge graph has an invalid base, join, or ambiguous fork'
    fi

    jq --arg base "$default_branch" --arg source "$source" --argjson issues "$issue_map" '
      . as $prs |
      def issue_for($number): ([ $issues[] | select(.pr == $number) | .issue ][0] // 0);
      def child($branch): [ $prs[] | select(.base.ref == $branch) ];
      def walk($pr):
        [$pr] + (child($pr.head.ref) as $children |
          if ($children|length) == 1 then walk($children[0]) else [] end);
      ([ $prs[] | select(.base.ref == $base) ] | sort_by(.created_at, .number) |
        map(walk(.)) | add // []) as $ordered |
      if ($ordered | length) != ($prs | length) then error("cycle") else
        $ordered | map({
          pr:.number, issue:issue_for(.number),
          state:(if .mergeable == true then
                   (if .base.ref == $base then "RUNNABLE" else "WAITING_FOR_MERGE" end)
                 elif .mergeable == false then "BLOCKED"
                 else "MERGEABLE_UNKNOWN" end),
          source:$source, base:.base.ref, head:.head.ref, sha:.head.sha
        })
      end
    ' "$work_dir/live.json" >"$work_dir/queue.json" 2>/dev/null ||
        die 'forge graph contains a cycle or could not be serialized'
else
    # A current artifact is the primary topology. Live reads verify its heads,
    # bases, draft/open state, mergeability, and predecessor state only.
    jq --slurpfile records "$work_dir/plan-records.json" '
      . as $live |
      [ $records[0][] as $record |
        ([ $live[] | select(.number == $record.pr) ][0]) as $pr |
        $record + {live:$pr} ]
    ' "$work_dir/live.json" >"$work_dir/planned-live.json"

    if ! jq -e --arg base "$default_branch" '
      . as $all |
      all(.[];
        if .position == 0 then
          (.live.base.ref == $base) or (.live.merged == true)
        else
          . as $item |
          ([ $all[] | select(.group == $item.group and .position == ($item.position - 1)) ][0]) as $pred |
          ($item.live.base.ref == $pred.branch) or
          ($pred.live.merged == true and $item.live.base.ref == $base)
        end)
    ' "$work_dir/planned-live.json" >/dev/null; then
        die 'live base refs disagree with the persisted merge plan; unsafe retarget state'
    fi

    # A plan remains the authoritative topology even when one or more records
    # drifted. Explicit --pr selectors only narrow that same plan-derived set.
    jq --arg base "$default_branch" --argjson selected "$(printf '%s\n' "${explicit_prs[@]}" | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')" '
      . as $all |
      def predecessor($item):
        [ $all[] | select(.group == $item.group and .position == ($item.position - 1)) ][0];
      group_by(.group) |
      map(sort_by(.position) | {created:.[0].live.created_at, members:.}) |
      sort_by(.created) |
      map(.members) | add |
      map(select(.live.state == "open") |
        . as $item |
        (if .position == 0 then null else predecessor($item) end) as $pred |
        select(($selected | length) == 0 or (.pr as $pr | $selected | index($pr) != null)) |
        {
          pr:.pr, issue:.issue,
          state:(if .live.mergeable == true then
                   (if $pred == null then "RUNNABLE"
                    elif $pred.live.merged == true and .live.base.ref != $base then "RETARGET_REQUIRED"
                    elif $pred.live.merged == true then "RUNNABLE"
                    else "WAITING_FOR_MERGE" end)
                 elif .live.mergeable == false then "BLOCKED"
                 else "MERGEABLE_UNKNOWN" end),
          source:"plan", base:.live.base.ref, head:.live.head.ref, sha:.live.head.sha
        })
    ' "$work_dir/planned-live.json" >"$work_dir/queue.json"
fi

if [[ -f $work_dir/planned-live.json ]]; then
    while IFS= read -r merged_pr; do
        warn "merged PR #$merged_pr dropped from queue"
    done < <(jq -r '.[] | select(.live.merged == true) | .pr' "$work_dir/planned-live.json")
fi

# GitHub can return a transient null mergeability while it recomputes after a
# base move. Re-read only those rows a bounded number of times; an unresolved
# row is explicit SETTLING and never silently treated as runnable.
settle_interval=${PR_QUEUE_SETTLE_INTERVAL:-15}
settle_rounds=${PR_QUEUE_SETTLE_ROUNDS:-3}
[[ $settle_interval =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'PR_QUEUE_SETTLE_INTERVAL must be a non-negative number'
[[ $settle_rounds =~ ^[0-9]+$ ]] || die 'PR_QUEUE_SETTLE_ROUNDS must be a non-negative integer'
for ((settle_round=1; settle_round<=settle_rounds; settle_round++)); do
    unknown_count=$(jq '[.[] | select(.state == "MERGEABLE_UNKNOWN")] | length' "$work_dir/queue.json")
    ((unknown_count == 0)) && break
    sleep "$settle_interval"
    while IFS= read -r settle_pr; do
        fetch_one "$settle_pr" "$work_dir/settled-$settle_pr.json"
    done < <(jq -r '.[] | select(.state == "MERGEABLE_UNKNOWN") | .pr' "$work_dir/queue.json")
    jq -s '.' "$work_dir"/settled-*.json >"$work_dir/settled-all.json"
    jq --arg base "$default_branch" --slurpfile settled "$work_dir/settled-all.json" '
      . as $queue |
      map(. as $item |
        ([ $settled[0][] | select(.number == $item.pr) ][0]) as $pr |
        if $pr == null or $pr.merged == true or $pr.state != "open" then empty
        else . as $old |
          $old + {
            state:(if $pr.mergeable == true then
                     (if $old.base == $base then "RUNNABLE" else "WAITING_FOR_MERGE" end)
                   elif $pr.mergeable == false then "BLOCKED"
                   else "MERGEABLE_UNKNOWN" end),
            base:$pr.base.ref, head:$pr.head.ref, sha:$pr.head.sha
          }
        end
      )
    ' "$work_dir/queue.json" >"$work_dir/settled-queue.json" &&
        mv -f -- "$work_dir/settled-queue.json" "$work_dir/queue.json"
done
jq 'map(if .state == "MERGEABLE_UNKNOWN" then .state = "SETTLING" else . end)' "$work_dir/queue.json" >"$work_dir/settling-queue.json" &&
    mv -f -- "$work_dir/settling-queue.json" "$work_dir/queue.json"

# Attach a content-sensitive diffFingerprint to every queue entry: a
# sha256 over the sorted per-file {filename, blob sha, patch} list from
# pulls/N/files, so a descendant commit that swaps reviewed content while
# preserving aggregate add/delete/file counts is never mistaken for a
# no-op merge-down (issue #450 review finding F2 -- aggregate counts are
# not a content identity). null when the read fails, the response is not
# a JSON array, or the PR has more files than this is willing to fetch and
# hash (300 -- generous for a real PR, cheap to fail closed on for the
# rare far-outlier where the endpoint's own documented truncation would
# make an equality compare meaningless anyway); authorize-queue.sh treats
# a null fingerprint as never eligible for a mechanical advance.
compute_diff_fingerprint() {
    local number=$1 out=$2 raw flat count fp
    raw="$work_dir/pr-files-$number.raw"
    if ! api "repos/$repo/pulls/$number/files?per_page=100" --paginate --slurp \
        >"$raw" 2>"$work_dir/api.err"; then
        printf 'null' >"$out"
        return 0
    fi
    flat="$work_dir/pr-files-$number.json"
    jq 'if type == "array" and length > 0 and all(.[]; type == "array") then add else . end' \
        "$raw" >"$flat" 2>/dev/null || { printf 'null' >"$out"; return 0; }
    jq -e 'type == "array"' "$flat" >/dev/null 2>&1 || { printf 'null' >"$out"; return 0; }
    count=$(jq 'length' "$flat" 2>/dev/null) || count=''
    [[ $count =~ ^[0-9]+$ ]] || { printf 'null' >"$out"; return 0; }
    ((count <= 300)) || { printf 'null' >"$out"; return 0; }
    # Hunk-header line ranges (@@ -a,b +c,d @@) are position, not content: a
    # base-only shift with no real edit changes them while every line the
    # hunk carries stays identical. Normalize them to "@@ @@" so that shift
    # alone never flips the fingerprint -- the hunk's own content lines,
    # filename, and blob sha still fully participate.
    fp=$(jq -cS '
        sort_by(.filename) | map({filename, sha:(.sha // ""),
          patch:((.patch // "") |
            gsub("@@ -[0-9]+(,[0-9]+)? \\+[0-9]+(,[0-9]+)? @@"; "@@ @@"))})
      ' "$flat" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}') || fp=''
    [[ $fp =~ ^[0-9a-f]{64}$ ]] || { printf 'null' >"$out"; return 0; }
    printf '"%s"' "$fp" >"$out"
}

: >"$work_dir/fingerprints.jsonl"
while IFS= read -r number; do
    fp_out="$work_dir/fp-$number.json"
    compute_diff_fingerprint "$number" "$fp_out"
    jq -cn --argjson pr "$number" --argjson fp "$(cat -- "$fp_out")" \
        '{pr:$pr, diffFingerprint:$fp}' >>"$work_dir/fingerprints.jsonl"
done < <(jq -r '.[].pr' "$work_dir/queue.json")
jq -s '.' "$work_dir/fingerprints.jsonl" >"$work_dir/fingerprints.json"
jq --slurpfile fp "$work_dir/fingerprints.json" '
  map(. as $item |
    $item + {diffFingerprint: (([$fp[0][] | select(.pr == $item.pr) | .diffFingerprint][0]) // null)})
' "$work_dir/queue.json" >"$work_dir/queue-with-fingerprint.json" ||
    die 'could not attach diff fingerprints to the live queue'
mv -f -- "$work_dir/queue-with-fingerprint.json" "$work_dir/queue.json"

# GitHub API budget preflight (agent-kit#475): every gh-authenticated tool on
# this account shares the same hourly REST/GraphQL pools, and a queue this
# large can plausibly exhaust one mid-run with no warning. Read-only,
# best-effort -- an unavailable rate_limit endpoint degrades to no budget
# line and no warning, never a die, since the queue itself is still valid
# evidence without it.
budget_json=null
if ((write_confirmed_queue)); then
    pr_count=$(jq 'length' "$work_dir/queue.json")
    if budget_raw=$("$GH_BIN" api rate_limit 2>"$work_dir/budget.err"); then
        estimated_cost=$((pr_count * (FULL_READS_PER_PR * REST_CALLS_PER_FULL_READ + WAIT_ROUNDS_PER_PR * REST_CALLS_PER_WAIT_ROUND)))
        rest_remaining=$(jq -r '.resources.core.remaining' <<<"$budget_raw" 2>/dev/null) || rest_remaining=''
        over_budget=false
        if [[ $rest_remaining =~ ^[0-9]+$ ]] && ((estimated_cost > rest_remaining)); then
            over_budget=true
            warn "estimated REST cost ($estimated_cost) for $pr_count queued PR(s) exceeds remaining budget ($rest_remaining) -- see .shared/wait-discipline.md"
        fi
        budget_json=$(jq -n --argjson raw "$budget_raw" --argjson estimated "$estimated_cost" \
            --argjson prCount "$pr_count" --argjson over "$over_budget" '{
              restRemaining: $raw.resources.core.remaining, restLimit: $raw.resources.core.limit,
              restReset: ($raw.resources.core.reset | todate),
              graphqlRemaining: $raw.resources.graphql.remaining, graphqlLimit: $raw.resources.graphql.limit,
              graphqlReset: ($raw.resources.graphql.reset | todate),
              prCount: $prCount, estimatedRestCost: $estimated, warning: $over
            }') || budget_json=null
        if [[ $budget_json != null ]]; then
            budget_line=$(printf 'budget: rest=%s/%s reset=%s graphql=%s/%s reset=%s estimated-rest-cost=%s' \
                "$(jq -r .restRemaining <<<"$budget_json")" "$(jq -r .restLimit <<<"$budget_json")" \
                "$(jq -r .restReset <<<"$budget_json")" \
                "$(jq -r .graphqlRemaining <<<"$budget_json")" "$(jq -r .graphqlLimit <<<"$budget_json")" \
                "$(jq -r .graphqlReset <<<"$budget_json")" "$estimated_cost")
            # --format json must stay pure JSON on stdout (the budget snapshot
            # already lives in the confirmed-queue JSON itself); every other
            # format keeps the human-readable line on stdout as before.
            if [[ $format == json ]]; then
                printf '%s\n' "$budget_line" >&2
            else
                printf '%s\n' "$budget_line"
            fi
        fi
    else
        warn "GitHub API budget unavailable: $(head -n 1 "$work_dir/budget.err")"
    fi
fi

if ((write_confirmed_queue)); then
    confirmed_output=$repo_root/.agent/pr-to-green-confirmed-queue.json
    if [[ -e $confirmed_output &&
          ( ! -f $confirmed_output || -L $confirmed_output || ! -O $confirmed_output ) ]]; then
        die 'confirmed queue output must be an owned regular file, not a symlink'
    fi
    jq --arg repo "$repo" --arg plan "$merge_plan" --arg planOption "$plan_option" \
      --argjson prs "$(printf '%s\n' "${explicit_prs[@]}" | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')" \
      --slurpfile providers "$work_dir/providers.json" --argjson budget "$budget_json" '{
      repository:$repo,
      argv:{plan:(if $plan == "" then null else {flag:$planOption,path:$plan} end),prs:$prs},
      providers:$providers[0],
      budget:$budget,
      queue:map({pr,state,headSha:.sha,base,diffFingerprint})
    }' "$work_dir/queue.json" >"$work_dir/confirmed-queue.json" ||
        die 'could not compose confirmed queue evidence'
    output_tmp=$(mktemp "$repo_root/.agent/.pr-to-green-confirmed-queue.XXXXXX") ||
        die 'could not create confirmed queue output'
    chmod 600 "$output_tmp"
    cp -- "$work_dir/confirmed-queue.json" "$output_tmp"
    mv -f -- "$output_tmp" "$confirmed_output"
    output_tmp=''
fi

if [[ $format == json ]]; then
    jq -c . "$work_dir/queue.json"
elif [[ $format == records ]]; then
    jq -r '.[] | "pr=\(.pr) issue=\(.issue) state=\(.state) source=\(.source) base=\(.base) head=\(.head) sha=\(.sha)"' \
        "$work_dir/queue.json"
else
    printf '%-6s %-7s %-18s %-9s %-24s %s\n' PR ISSUE STATE SOURCE BASE HEAD
    jq -r '.[] | [.pr,.issue,.state,.source,.base,.head] | @tsv' "$work_dir/queue.json" |
        while IFS=$'\t' read -r pr issue state source base head; do
            printf '#%-5s #%-6s %-18s %-9s %-24s %s\n' \
                "$pr" "$issue" "$state" "$source" "$base" "$head"
        done
fi
