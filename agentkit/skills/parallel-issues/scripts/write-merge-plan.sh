#!/usr/bin/env bash
# Validate and atomically persist the ready-flip merge plan in a dispatch plan.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
dispatch_plan=''
merge_plan=''
validate_only=0
chain_base=''

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    printf 'usage: %s --dispatch-plan FILE [--chain-base PATH|REF] (--validate-only | --merge-plan FILE)\n' "$PROGRAM" >&2
    exit "${1:-2}"
}

while (($#)); do
    case $1 in
        --dispatch-plan)
            (($# >= 2)) || usage
            dispatch_plan=$2
            shift 2
            ;;
        --merge-plan)
            (($# >= 2)) || usage
            merge_plan=$2
            shift 2
            ;;
        --chain-base|--chain-base-tree|--tree-root)
            (($# >= 2)) || usage
            chain_base=$2
            shift 2
            ;;
        --validate-only)
            validate_only=1
            shift
            ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

[[ -n $dispatch_plan ]] || usage
if ((validate_only)); then
    [[ -z $merge_plan ]] || usage
else
    [[ -n $merge_plan ]] || usage
fi
command -v jq >/dev/null 2>&1 || die 'jq is required; merge-plan evidence unavailable'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'could not resolve script directory'
inputs=("$dispatch_plan")
[[ -z $merge_plan ]] || inputs+=("$merge_plan")
for file in "${inputs[@]}"; do
    [[ -f $file && ! -L $file && -O $file ]] ||
        die "input must be an owned regular file, not a symlink: $file"
done

# Resolve predictions against an immutable git tree when the dispatcher gives
# us its chain base.  The argument may be a worktree (use its HEAD) or a git
# ref/SHA (use the current repository); omitting it keeps the ready-flip
# validator backward-compatible for callers that only validate schema shape.
declare -a chain_tree_paths=()
declare -a chain_test_roots=()
if ((validate_only)) && [[ -n $chain_base ]]; then
    chain_root=''
    chain_ref='HEAD'
    if [[ -d $chain_base ]]; then
        chain_root=$(git -C "$chain_base" rev-parse --show-toplevel 2>/dev/null) ||
            die "chain base is not a git worktree: $chain_base"
    else
        chain_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
            die "chain base ref requires a git worktree: $chain_base"
        chain_ref=$chain_base
    fi
    chain_root=$(cd -P -- "$chain_root" && pwd -P) || die "could not resolve chain base root: $chain_base"
    [[ $chain_ref != -* && $chain_ref != *[[:space:]]* ]] || die "unsafe chain base ref: $chain_ref"
    git -C "$chain_root" rev-parse --verify "$chain_ref^{tree}" >/dev/null 2>&1 ||
        die "chain base does not resolve to a git tree: $chain_base"
    mapfile -t chain_tree_paths < <(git -C "$chain_root" ls-tree -r --name-only "$chain_ref^{tree}")
    ((${#chain_tree_paths[@]})) || die "chain base tree is empty: $chain_base"

    # Test roots are declared beside test commands, or discovered from the
    # conventional test-directory names present in the chain-base tree. The
    # roots are suggestions, never shell input.
    config_reader=$script_dir/../../.shared/scripts/repo-config.sh
    if [[ -x $config_reader ]]; then
        while IFS='=' read -r config_key config_value; do
            if [[ $config_key == AGENT_RUNDIR_* && $config_key == *_TEST* && -n $config_value ]]; then
                test_root=$config_value
                while [[ $test_root == */ ]]; do test_root=${test_root%/}; done
                while [[ $test_root == ./* ]]; do test_root=${test_root#./}; done
                [[ -n $test_root && $test_root != . ]] || continue
                chain_test_roots+=("$test_root")
            fi
        done < <("$config_reader" --repo-root "$chain_root" --list 2>/dev/null || true)
    fi
    for tree_path in "${chain_tree_paths[@]}"; do
        tree_dir=$tree_path
        while [[ $tree_dir == */* ]]; do
            tree_dir=${tree_dir%/*}
            case ${tree_dir##*/} in
                test|tests|spec|specs) chain_test_roots+=("$tree_dir") ;;
            esac
        done
    done
    if ((${#chain_test_roots[@]})); then
        mapfile -t chain_test_roots < <(printf '%s\n' "${chain_test_roots[@]}" | awk 'NF && !seen[$0]++')
    fi
fi

# Translate the repository's deliberately small glob language to a Bash ERE.
# Unlike pathname expansion this keeps `*` inside one path component while
# letting `**` cross directories, and it never evaluates plan data as code.
glob_regex() {
    local pattern=$1 regex='^' index=0 character closing
    while ((index < ${#pattern})); do
        character=${pattern:index:1}
        case $character in
            '*')
                if [[ ${pattern:index:2} == '**' ]]; then
                    ((index += 2))
                    if [[ ${pattern:index:1} == '/' ]]; then
                        regex+='(.*/)?'
                        ((index++))
                    else
                        regex+='.*'
                    fi
                else
                    regex+='[^/]*'
                    ((index++))
                fi
                ;;
            '?') regex+='[^/]'; ((index++)) ;;
            '[')
                closing=$((index + 1))
                while ((closing < ${#pattern})) && [[ ${pattern:closing:1} != ']' ]]; do ((closing++)); done
                if ((closing < ${#pattern})); then
                    regex+=${pattern:index:$((closing - index + 1))}
                    index=$((closing + 1))
                else
                    regex+='\['
                    ((index++))
                fi
                ;;
            [.^$'+'\'|'('')'])
                    # shellcheck disable=SC1003
                    regex+='\'
                regex+=$character
                ((index++))
                ;;
            *) regex+=$character; ((index++)) ;;
        esac
    done
    printf '%s$' "$regex"
}

tree_glob_matches() {
    local pattern=$1 path regex
    regex=$(glob_regex "$pattern")
    for path in "${chain_tree_paths[@]}"; do
        [[ $path =~ $regex ]] && return 0
    done
    return 1
}

tree_literal_parent_exists() {
    local pattern=$1 parent
    [[ $pattern != *[\*\?\[]* ]] || return 1
    if [[ $pattern != */* ]]; then
        return 0
    fi
    parent=${pattern%/*}
    for path in "${chain_tree_paths[@]}"; do
        [[ $path == "$parent"/* ]] && return 0
    done
    return 1
}

nearest_tree_sibling() {
    local pattern=$1 candidate path segment score best_score=-1 best_depth=-1
    local literal=${pattern%%[\*\?\[]*}
    literal=${literal%/}
    [[ -n $literal ]] || { printf 'none'; return 0; }
    declare -A candidate_dirs=()
    for path in "${chain_tree_paths[@]}"; do
        candidate=$path
        while [[ $candidate == */* ]]; do
            candidate=${candidate%/*}
            candidate_dirs[$candidate]=1
        done
    done
    for candidate in "${!candidate_dirs[@]}"; do
        score=0
        IFS=/ read -ra literal_parts <<< "$literal"
        IFS=/ read -ra candidate_parts <<< "$candidate"
        for segment in "${literal_parts[@]}"; do
            for path in "${candidate_parts[@]}"; do
                [[ $segment == "$path" ]] && ((score += 100))
            done
        done
        depth=${#candidate_parts[@]}
        if ((score > best_score || (score == best_score && depth > best_depth))); then
            best_score=$score
            best_depth=$depth
            best_candidate=$candidate
        fi
    done
    [[ -n ${best_candidate:-} ]] && printf '%s' "$best_candidate" || printf 'none'
}

if ((validate_only)); then
    jq -e '
      def uint: type == "number" and . > 0 and floor == .;
      def path:
        type == "string" and length > 0 and
        (startswith("/") | not) and (contains("\\") | not) and
        (test("[\\r\\n]") | not) and
        all(split("/")[]; . != "" and . != "." and . != "..");
      def pair:
        if type != "object" then false else
          ((.issues | type) == "array" and (.issues | length) == 2) and
          all(.issues[]; uint) and (.issues[0] != .issues[1]) and
          ((.overlap | type) == "array" and (.overlap | length) > 0) and
          all(.overlap[]; path)
        end;
      def revision:
        if type != "object" then false else
          ((.reason | type) == "string" and (.reason | test("[^[:space:]]"))) and
          ((has("issues") | not) or
            (((.issues | type) == "array" and (.issues | length) > 0) and
              all(.issues[]; uint))) and
          ((has("paths") | not) or
            (((.paths | type) == "array" and (.paths | length) > 0) and
              all(.paths[]; path)))
        end;
      # workShape/holdReason are optional and travel together: a HOLD needs a
      # named reason, and a reason with no HOLD is a stray, confusing signal.
      # Absent entirely is the backward-compatible default (implementation).
      def work_shape:
        if type != "object" then false else
          ((has("workShape") | not) and (has("holdReason") | not)) or
          (.workShape == "implementation" and (has("holdReason") | not)) or
          (.workShape == "no-code" and
            (.holdReason | type) == "string" and (.holdReason | test("[^[:space:]]")))
          end;
      def test_root_exclusions:
        (has("testRootExclusions") | not) or
        ((.testRootExclusions | type) == "array" and
          (.testRootExclusions | length) > 0 and
          all(.testRootExclusions[]; path));
      type == "object" and .schemaVersion == 1 and
      ((.entries | type) == "array" and (.entries | length) > 0) and
      all(.entries[];
        (type == "object") and (.issue | uint) and
        ((.predictedWriteSet | type) == "array" and
          (.predictedWriteSet | length) > 0) and
        all(.predictedWriteSet[]; path) and
        work_shape and test_root_exclusions) and
      ((.entries | map(.issue) | unique | length) == (.entries | length)) and
      ((.conflictMap | type) == "object") and
      ((.conflictMap.pairs | type) == "array") and
      all(.conflictMap.pairs[]; pair) and
      ((.conflictMap.revisions | type) == "array") and
      all(.conflictMap.revisions[]; revision)
    ' "$dispatch_plan" >/dev/null 2>&1 ||
        die 'dispatch plan is invalid: expected schemaVersion 1 with entries and conflictMap'
    if [[ -n $chain_base ]]; then
        while IFS=$'\t' read -r issue patterns exclusions; do
            IFS=',' read -ra prediction_patterns <<< "$patterns"
            for pattern in "${prediction_patterns[@]}"; do
                tree_glob_matches "$pattern" || tree_literal_parent_exists "$pattern" || {
                    sibling=$(nearest_tree_sibling "$pattern")
                    if [[ $sibling != none && $pattern == */** ]]; then sibling+="/**"; fi
                    die "issue #$issue predictedWriteSet glob matches no paths in chain-base tree: $pattern; nearest existing sibling: $sibling"
                }
            done
            ((${#chain_test_roots[@]})) || continue
            source_prediction=0
            for pattern in "${prediction_patterns[@]}"; do
                regex=$(glob_regex "$pattern")
                for tree_path in "${chain_tree_paths[@]}"; do
                    [[ $tree_path =~ $regex ]] || continue
                    case ${tree_path%%/*} in
                        .github|docs|doc|README*|CHANGELOG*|LICENSE*|test|tests|spec|specs) ;;
                        *) source_prediction=1; break 2 ;;
                    esac
                done
            done
            ((source_prediction)) || continue
            IFS=',' read -ra excluded_roots <<< "${exclusions:-}"
            for test_root in "${chain_test_roots[@]}"; do
                covered=0
                for pattern in "${prediction_patterns[@]}"; do
                    regex=$(glob_regex "$pattern")
                    for tree_path in "${chain_tree_paths[@]}"; do
                        if [[ $tree_path == "$test_root"/* && $tree_path =~ $regex ]]; then
                            covered=1
                            break 2
                        fi
                    done
                done
                ((covered)) && continue
                excluded=0
                for pattern in "${excluded_roots[@]}"; do
                    [[ -n $pattern ]] || continue
                    regex=$(glob_regex "$pattern")
                    for tree_path in "${chain_tree_paths[@]}"; do
                        if [[ $tree_path == "$test_root"/* && $tree_path =~ $regex ]]; then
                            excluded=1
                            break 2
                        fi
                    done
                done
                ((excluded)) && continue
                die "issue #$issue write set names source but omits project test root: $test_root/**; include it in predictedWriteSet or explicitly list it in testRootExclusions"
            done
        done < <(jq -r '.entries[] | [.issue, (.predictedWriteSet | join(",")), (.testRootExclusions // [] | join(","))] | @tsv' "$dispatch_plan")
    fi
    printf 'dispatch-plan=%s schemaVersion=1 valid\n' "$dispatch_plan"
    exit 0
fi

jq -e '
  type == "object" and
  ((.schemaVersion == 1) or (.schemaVersion == 2)) and
  ((.entries | type) == "array") and
  ((.conflictMap | type) == "object")
' "$dispatch_plan" >/dev/null 2>&1 || die 'dispatch plan has an unsupported schema'

# Keep this validation declarative: merge-plan bytes are untrusted run data and
# must never become shell syntax. Every IMPLEMENTATION-shaped selected issue
# appears exactly once (a workShape=no-code hold has no worktree/branch/PR/
# head to record -- it stays in entries for audit/funnel accounting, but is
# never expected in the merge plan, and its presence there is rejected as an
# issue-set mismatch same as any other unexpected record), roots use null
# chainBaseSha, and each successor pins its immediate predecessor.
jq -e --slurpfile dispatch "$dispatch_plan" '
  def uint: type == "number" and . > 0 and floor == .;
  def sha: type == "string" and test("^[0-9a-f]{40}$");
  def branch:
    type == "string" and
    test("^[A-Za-z0-9._/-]+$") and
    (startswith("-") | not) and
    (contains("..") | not) and
    (endswith("/") | not) and
    (endswith(".lock") | not);
  def record:
    (keys | sort) == (["branch","chainBaseSha","headSha","issue","pr"] | sort) and
    (.issue | uint) and (.pr | uint) and (.branch | branch) and
    (.headSha | sha) and
    ((.chainBaseSha == null) or (.chainBaseSha | sha));
  type == "object" and
  ((.generatedAt | type) == "string") and
  (.generatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  ((.independent | type) == "array") and
  ((.chains | type) == "array") and
  all(.independent[]; record and .chainBaseSha == null) and
  all(.chains[]; . as $chain |
    ($chain | type) == "array" and ($chain | length) >= 2 and
    all($chain[]; record) and
    $chain[0].chainBaseSha == null and
    all(range(1; $chain | length); . as $i |
      $chain[$i].chainBaseSha == $chain[$i - 1].headSha)
  ) and
  ([.independent[], .chains[][]] as $records |
    ($records | length) > 0 and
    (($records | map(.pr) | unique | length) == ($records | length)) and
    (($records | map(.issue) | unique | length) == ($records | length)) and
    (($records | map(.branch) | unique | length) == ($records | length)) and
    (($records | map(.issue) | sort) ==
      ($dispatch[0].entries | map(select(.workShape != "no-code") | .issue) | sort)))
' "$merge_plan" >/dev/null 2>&1 || {
    # The boolean gate above is the sole accept/reject authority and is left
    # byte-for-byte unchanged; this second pass only names which field made it
    # fail, so a diagnostic bug can never loosen validation -- at worst it
    # falls back to the generic message below.
    reason=$(jq -r --slurpfile dispatch "$dispatch_plan" '
      def uint: type == "number" and . > 0 and floor == .;
      def sha: type == "string" and test("^[0-9a-f]{40}$");
      def branch:
        type == "string" and
        test("^[A-Za-z0-9._/-]+$") and
        (startswith("-") | not) and
        (contains("..") | not) and
        (endswith("/") | not) and
        (endswith(".lock") | not);
      def record_issue($ctx; $require_root):
        if (type != "object") then "\($ctx) must be an object"
        elif (keys | sort) != (["branch","chainBaseSha","headSha","issue","pr"] | sort)
        then "\($ctx) must have exactly these keys: branch, chainBaseSha, headSha, issue, pr"
        elif (.issue | uint | not) then "\($ctx).issue must be a positive integer"
        elif (.pr | uint | not) then "\($ctx).pr must be a positive integer"
        elif (.branch | branch | not) then "\($ctx).branch is not a safe branch name"
        elif (.headSha | sha | not) then "\($ctx).headSha must be a 40-character lowercase hex commit SHA"
        elif ($require_root and .chainBaseSha != null) then "\($ctx).chainBaseSha must be null (no predecessor)"
        elif ((.chainBaseSha != null) and (.chainBaseSha | sha | not))
        then "\($ctx).chainBaseSha must be null or a 40-character lowercase hex commit SHA"
        else null
        end;
      def chain_issue($ctx):
        if (type != "array") then "\($ctx) must be an array"
        elif (length) < 2 then "\($ctx) must contain at least 2 records (a chain root and at least one successor)"
        else
          (. as $chain | first(
            range(0; $chain | length) as $i
            | ($chain[$i] | record_issue("\($ctx)[\($i)]"; $i == 0))
            | select(. != null)
          ))
          // (. as $chain | first(
            range(1; $chain | length) as $i
            | (if $chain[$i].chainBaseSha != $chain[$i - 1].headSha
               then "\($ctx)[\($i)].chainBaseSha must equal \($ctx)[\($i - 1)].headSha"
               else null end)
            | select(. != null)
          ))
        end;
      def reason:
        if type != "object" then "merge plan must be a JSON object"
        elif (.generatedAt | type) != "string" then "merge plan is missing required field: generatedAt"
        elif (.generatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not)
        then "merge plan field generatedAt is not a valid ISO-8601 UTC timestamp (want YYYY-MM-DDTHH:MM:SSZ)"
        elif (.independent | type) != "array" then "merge plan is missing required field: independent (must be an array)"
        elif (.chains | type) != "array" then "merge plan is missing required field: chains (must be an array)"
        else
          (first(
            range(0; .independent | length) as $i
            | (.independent[$i] | record_issue("independent[\($i)]"; true))
            | select(. != null)
          ))
          // (first(
            range(0; .chains | length) as $i
            | (.chains[$i] | chain_issue("chains[\($i)]"))
            | select(. != null)
          ))
          // (
            ([.independent[], .chains[][]]) as $records
            | if ($records | length) == 0
              then "merge plan must contain at least one record across independent and chains"
              elif ($records | map(.pr) | unique | length) != ($records | length)
              then "merge plan pr values must be unique across independent and chains"
              elif ($records | map(.issue) | unique | length) != ($records | length)
              then "merge plan issue values must be unique across independent and chains"
              elif ($records | map(.branch) | unique | length) != ($records | length)
              then "merge plan branch values must be unique across independent and chains"
              elif ($records | map(.issue) | sort) !=
                ($dispatch[0].entries | map(select(.workShape != "no-code") | .issue) | sort)
              then "merge plan issue set does not match the dispatch plan implementation-shaped entries (a workShape=no-code hold is excluded)"
              else null
              end
          )
        end;
      reason // empty
    ' "$merge_plan" 2>/dev/null) || true
    if [[ -n ${reason:-} ]]; then
        die "merge plan is invalid: $reason"
    else
        die 'merge plan is malformed, ambiguous, or does not match dispatch entries'
    fi
}

target_dir=$(dirname -- "$dispatch_plan")
staged=$(mktemp "$target_dir/.dispatch-plan.XXXXXX") || die 'could not stage dispatch plan'
cleanup() { rm -f -- "$staged"; }
trap cleanup EXIT HUP INT TERM

jq --slurpfile merge "$merge_plan" '
  .schemaVersion = 2 |
  .generatedAt = $merge[0].generatedAt |
  .independent = $merge[0].independent |
  .chains = $merge[0].chains
' "$dispatch_plan" >"$staged" || die 'could not compose schemaVersion 2 dispatch plan'
chmod --reference="$dispatch_plan" "$staged" 2>/dev/null || chmod 600 "$staged"
mv -- "$staged" "$dispatch_plan"
trap - EXIT HUP INT TERM
printf 'merge-plan=%s schemaVersion=2 independent=%s chains=%s\n' \
    "$dispatch_plan" \
    "$(jq -r '.independent | length' "$dispatch_plan")" \
    "$(jq -r '.chains | length' "$dispatch_plan")"
