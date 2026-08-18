#!/usr/bin/env bash
# Discover and verify a stable serial queue of pull requests.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
GH_BIN=${PR_QUEUE_GH:-gh}
repo=''
repo_root=''
merge_plan=''
format=table
declare -a explicit_prs=()
work_dir=''

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

warn() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }

usage() {
    cat >&2 <<EOF
usage: $PROGRAM --repo OWNER/REPO [--repo-root DIR] [--merge-plan FILE]
                [--pr N ...] [--format records|table|json]
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

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/pr-queue.XXXXXX") || die 'could not create work directory'
chmod 700 "$work_dir"
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT HUP INT TERM

api() {
    "$GH_BIN" api "$@"
}

api "repos/$repo" >"$work_dir/repo.json" 2>"$work_dir/api.err" ||
    die "repository metadata unavailable: $(head -n 1 "$work_dir/api.err")"
default_branch=$(jq -er '.default_branch | select(type == "string" and length > 0)' \
    "$work_dir/repo.json" 2>/dev/null) || die 'repository metadata omitted default_branch'

validate_prs() {
    jq -e '
      type == "array" and all(.[];
        (.number | type) == "number" and .number > 0 and
        ((.state == "open") or (.state == "closed")) and
        ((.draft | type) == "boolean") and
        ((.merged | type) == "boolean") and
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
        die "pull request #$number is unavailable: $(head -n 1 "$work_dir/api.err")"
    jq -e 'type == "object"' "$out" >/dev/null 2>&1 ||
        die "pull request #$number returned malformed JSON"
}

plan_active=0
plan_drift=0
if [[ -n $merge_plan ]]; then
    [[ -f $merge_plan && ! -L $merge_plan && -O $merge_plan ]] ||
        die "--merge-plan must be an owned regular file, not a symlink: $merge_plan"
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
        die 'merge plan is malformed or contains cycles, joins, or ambiguous records'

    jq '([.chains | to_entries[] as $chain |
          $chain.value | to_entries[] |
          .value + {group:("chain-" + ($chain.key|tostring)), position:.key}] +
         [.independent | to_entries[] |
          .value + {group:("independent-" + (.key|tostring)), position:0}])' \
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
        ([ $live[0][] | select(.number == $record.pr) ][0].head.sha == $record.headSha))
    ' "$work_dir/plan-records.json" >/dev/null; then
        plan_drift=1
        warn 'recorded head drift detected; re-deriving the queue from verified forge relationships'
    else
        plan_active=1
    fi
fi

if ((plan_active == 0)); then
    if [[ -z $merge_plan || ${#explicit_prs[@]} -gt 0 ]]; then
        if ((${#explicit_prs[@]})); then
            for number in "${explicit_prs[@]}"; do
                fetch_one "$number" "$work_dir/explicit-$number.json"
            done
            jq -s '.' "$work_dir"/explicit-*.json >"$work_dir/live.json"
        else
            api "repos/$repo/pulls?state=open&per_page=100" --paginate --slurp \
                >"$work_dir/list.json" \
                2>"$work_dir/api.err" ||
                die "open pull request discovery failed: $(head -n 1 "$work_dir/api.err")"
            jq 'if type == "array" and length > 0 and all(.[]; type == "array") then add else . end |
                map(select(.draft == true))' "$work_dir/list.json" >"$work_dir/live.json" \
                2>/dev/null || die 'open pull request discovery returned malformed JSON'
        fi
    fi
    validate_prs "$work_dir/live.json" || die 'pull request discovery returned malformed records'

    source=forge
    ((plan_drift == 0)) || source=fallback
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
          state:(if .mergeable == false then "BLOCKED"
                 elif .base.ref == $base then "RUNNABLE"
                 else "WAITING_FOR_MERGE" end),
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

    jq --arg base "$default_branch" '
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
        {
          pr:.pr, issue:.issue,
          state:(if .live.mergeable == false then "BLOCKED"
                 elif $pred == null then "RUNNABLE"
                 elif $pred.live.merged == true and .live.base.ref != $base then "RETARGET_REQUIRED"
                 elif $pred.live.merged == true then "RUNNABLE"
                 else "WAITING_FOR_MERGE" end),
          source:"plan", base:.live.base.ref, head:.live.head.ref, sha:.live.head.sha
        })
    ' "$work_dir/planned-live.json" >"$work_dir/queue.json"
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
