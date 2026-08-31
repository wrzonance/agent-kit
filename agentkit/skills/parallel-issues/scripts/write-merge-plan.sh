#!/usr/bin/env bash
# Validate and atomically persist the ready-flip merge plan in a dispatch plan.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
dispatch_plan=''
merge_plan=''
validate_only=0
chain_base=''
fix=0

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    printf 'usage: %s --dispatch-plan FILE [--chain-base PATH|REF] [--fix] (--validate-only | --merge-plan FILE)\n' "$PROGRAM" >&2
    exit "${1:-2}"
}

while (($#)); do
    case $1 in
        --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
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
        --fix)
            fix=1
            shift
            ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

[[ -n $dispatch_plan ]] || usage
if ((validate_only)); then
    [[ -z $merge_plan ]] || usage
    # --fix mutates dispatch-plan test-root-exclusion decisions computed from
    # the chain-base tree; with no chain base there is nothing to compute a
    # remedy from.
    ((! fix)) || [[ -n $chain_base ]] || usage
else
    [[ -n $merge_plan ]] || usage
    ((! fix)) || usage
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

    # A "project test root" is a directory a declared verify command actually
    # runs -- never any directory whose name merely looks like "test"/"spec".
    # Two declaration shapes name one: AGENT_RUNDIR_<NAME> (the working
    # directory a named command runs in) and the directory component of
    # AGENT_CMD_<NAME>'s argv[0], for any NAME containing "_TEST". A
    # directory-name heuristic over the chain-base tree previously stood in
    # here too and misclassified any incidental test/spec-named directory
    # (docs/superpowers/specs/**, bench/gold/**/test/**) as a required root;
    # it is gone. Detection is declaration-driven only -- there is no
    # unconditional docs/** or bench/gold/** filter here, so a repository that
    # genuinely declares a test root under one of those paths is honored too.
    # The roots below are suggestions, never shell input.
    normalize_test_root() {
        local candidate=$1
        while [[ $candidate == */ ]]; do candidate=${candidate%/}; done
        while [[ $candidate == ./* ]]; do candidate=${candidate#./}; done
        printf '%s' "$candidate"
    }
    # An argv[0]-derived root is trustworthy only when it is repository-
    # relative (no leading "/", no ".." segment) AND its directory actually
    # exists in the chain-base tree; an absolute or parent-traversing argv[0]
    # (/usr/bin/pytest, ../x/run) must never mint a bogus required root that
    # the write set can never satisfy.
    test_root_dir_exists() {
        local candidate=$1 path
        for path in "${chain_tree_paths[@]}"; do
            [[ $path == "$candidate"/* || $path == "$candidate" ]] && return 0
        done
        return 1
    }
    # Resolve which .agent/config.env to read. A worktree chain base's
    # checked-out tree already matches the live filesystem, so the live
    # checkout is authoritative. A ref/SHA chain base may not match the live
    # checkout at all (a different commit is on disk), so read the config
    # tracked AT THAT REF instead, staged into a private owner-only directory
    # so repo-config.sh never touches the operator's real config file. Fall
    # back to the live checkout only when the ref carries no tracked
    # .agent/config.env (untracked or absent there).
    config_root=$chain_root
    config_source='live checkout'
    if [[ $chain_ref != HEAD ]]; then
        config_bytes=''
        if config_bytes=$(git -C "$chain_root" show "$chain_ref:.agent/config.env" 2>/dev/null); then
            config_stage=$(mktemp -d) || die 'could not stage chain-base config for reading'
            chmod 700 -- "$config_stage" || die 'could not secure chain-base config staging dir'
            trap 'rm -rf -- "$config_stage"' EXIT HUP INT TERM
            mkdir -p -- "$config_stage/.agent" || die 'could not stage chain-base config for reading'
            printf '%s\n' "$config_bytes" >"$config_stage/.agent/config.env" ||
                die 'could not write staged chain-base config'
            config_root=$config_stage
            config_source="chain-base ref $chain_ref"
        else
            config_source="live checkout (no .agent/config.env tracked at $chain_ref)"
        fi
    fi
    config_reader=$script_dir/../../.shared/scripts/repo-config.sh
    if [[ -x $config_reader ]]; then
        printf '%s: test-root config source: %s\n' "$PROGRAM" "$config_source" >&2
        declare -a cmd_test_keys=()
        while IFS='=' read -r config_key config_value; do
            if [[ $config_key == AGENT_RUNDIR_* && $config_key == *_TEST* && -n $config_value ]]; then
                test_root=$(normalize_test_root "$config_value")
                [[ -n $test_root && $test_root != . ]] || continue
                chain_test_roots+=("$test_root")
            elif [[ $config_key == AGENT_CMD_* && $config_key == *_TEST* ]]; then
                cmd_test_keys+=("$config_key")
            fi
        done < <("$config_reader" --repo-root "$config_root" --list 2>/dev/null || true)
        for cmd_key in "${cmd_test_keys[@]}"; do
            argv0=''
            while IFS= read -r -d '' argv_token; do
                [[ -n $argv0 ]] || argv0=$argv_token
            done < <("$config_reader" --repo-root "$config_root" --get-argv "$cmd_key" 2>/dev/null || true)
            [[ $argv0 == */* ]] || continue
            [[ $argv0 != /* ]] || continue
            case $argv0 in
                ../*|*/../*|*/..) continue ;;
            esac
            test_root=$(normalize_test_root "${argv0%/*}")
            [[ -n $test_root && $test_root != . && $test_root != ..* ]] || continue
            test_root_dir_exists "$test_root" || continue
            chain_test_roots+=("$test_root")
        done
    fi
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
            '.'|'^'|'$'|'+'|'|'|'('|')'|'{'|'}')
                regex+="\\$character"
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

# --- protected-path collision matching --------------------------------------
# A predictedWriteSet entry that names, or globs over, a path this repository
# (or the shared defaults) protects means the assigned worker structurally
# cannot land its own commit -- worktree-commit.sh refuses the same paths at
# publish time. Flag that at plan time instead of after a full worker run.
protected_paths_lib=$script_dir/../../.shared/scripts/lib/protected-paths.sh
[[ -f $protected_paths_lib ]] || die "protected-path policy library missing: $protected_paths_lib"
# shellcheck source=../../.shared/scripts/lib/protected-paths.sh
source "$protected_paths_lib"

# True (rc 0) when $1 is path-component-equal to, or a component-wise
# ancestor directory of, $2. Never a bare string-prefix test: that would
# false-positive ".github/workflows-extra" against ".github/workflows".
path_is_ancestor_or_equal() {
    local a=${1%/} b=${2%/}
    [[ $a == "$b" || $b == "$a"/* ]]
}

# Prints the first protected pattern predictedWriteSet entry $1 collides
# with and returns 0; returns 1 when it collides with none of the remaining
# arguments. $1 is either a literal repo-relative path or a "dir/**"
# directory-prefix glob -- the two shapes a predictedWriteSet entry actually
# takes (SKILL.md predicts literals and "**" directory globs); other glob
# shapes (mid-path "*", "?", character classes) are not evaluated here, to
# avoid false positives no dispatcher could safely act on.
protected_write_set_collision() {
    local write_pattern=$1 candidate pattern base
    shift
    if [[ $write_pattern == */** ]]; then
        candidate=${write_pattern%/**}
    elif [[ $write_pattern != *[\*\?\[]* ]]; then
        candidate=$write_pattern
    else
        return 1
    fi
    for pattern in "$@"; do
        base=${pattern%/}
        [[ -n $base ]] || continue
        if path_is_ancestor_or_equal "$base" "$candidate" || path_is_ancestor_or_equal "$candidate" "$base"; then
            printf '%s' "$pattern"
            return 0
        fi
    done
    return 1
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
      def protected_path_acknowledgement:
        (has("protectedPathAcknowledgement") | not) or
        ((.protectedPathAcknowledgement | type) == "array" and
          (.protectedPathAcknowledgement | length) > 0 and
          all(.protectedPathAcknowledgement[]; path));
      def issue_set_or_count:
        (type == "number" and . >= 0 and floor == .) or
        (type == "array" and all(.[]; uint) and (map(.) | unique | length) == length);
      def issue_count:
        if type == "array" then length else . end;
      def disjoint_lists($left; $right):
        if (($left | type) != "array" or ($right | type) != "array") then true
        else all($left[]; . as $id | ($right | index($id)) == null) end;
      def selection:
        if (has("selection") | not) then true
        elif (.selection | type) != "object" then false
        else .selection as $s |
          ($s.requested | uint) and ($s.eligible | type) == "number" and ($s.eligible >= 0) and ($s.eligible | floor) == $s.eligible and
          ($s.dispatched | type) == "number" and ($s.dispatched >= 0) and ($s.dispatched | floor) == $s.dispatched and ($s.dispatched <= $s.eligible) and ($s.dispatched <= $s.requested) and
          ($s.queued | issue_set_or_count) and
          ($s.tracker | issue_set_or_count) and
          (disjoint_lists($s.queued; $s.tracker)) and
          ($s.dispatched + ($s.queued | issue_count) <= $s.eligible)
        end;
      type == "object" and .schemaVersion == 1 and test_root_exclusions and protected_path_acknowledgement and
      ((.entries | type) == "array" and (.entries | length) > 0) and
      all(.entries[];
        (type == "object") and (.issue | uint) and
        ((.predictedWriteSet | type) == "array" and
          (.predictedWriteSet | length) > 0) and
        all(.predictedWriteSet[]; path) and
        work_shape and test_root_exclusions and protected_path_acknowledgement) and
      ((.entries | map(.issue) | unique | length) == (.entries | length)) and
      ((.conflictMap | type) == "object") and
      ((.conflictMap.pairs | type) == "array") and
      all(.conflictMap.pairs[]; pair) and
      ((.conflictMap.revisions | type) == "array") and
      all(.conflictMap.revisions[]; revision) and
      selection
    ' "$dispatch_plan" >/dev/null 2>&1 ||
        die 'dispatch plan is invalid: expected schemaVersion 1 with entries and conflictMap'

    # Every entry is checked and every finding is collected before any exit,
    # so one invocation reports everything a second invocation could
    # otherwise only discover one fix-and-retry turn at a time.
    declare -a violation_lines=()
    declare -A missing_roots_by_issue=()
    declare -a missing_issue_order=()

    # --- protected-path collision check: runs unconditionally, independent
    # of --chain-base, because it is pure pattern matching over the plan's
    # own declared write sets -- it needs no chain-base tree to resolve. The
    # repo root used to read a repo-declared AGENT_PROTECTED_PATHS reuses
    # chain_root when the earlier chain-base resolution already validated
    # one (a worktree's checkout or a validated ref's repository) and
    # otherwise falls back to the live checkout.
    protected_root=${chain_root:-}
    [[ -n $protected_root ]] || protected_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    protected_declared=''
    protected_config_reader=$script_dir/../../.shared/scripts/repo-config.sh
    if [[ -n $protected_root && -x $protected_config_reader ]]; then
        protected_declared=$("$protected_config_reader" --repo-root "$protected_root" \
            --get AGENT_PROTECTED_PATHS 2>/dev/null || true)
    fi
    declare -a protected_patterns=("${SHARED_PROTECTED_DEFAULTS[@]}")
    if [[ -n $protected_declared ]]; then
        declare -a protected_extra=()
        IFS=',' read -r -a protected_extra <<< "$protected_declared"
        protected_patterns+=("${protected_extra[@]}")
    fi
    while IFS=$'\t' read -r issue patterns acknowledged; do
        IFS=',' read -ra prediction_patterns <<< "$patterns"
        IFS=',' read -ra acknowledged_patterns <<< "${acknowledged:-}"
        for pattern in "${prediction_patterns[@]}"; do
            collision=$(protected_write_set_collision "$pattern" "${protected_patterns[@]}") || continue
            is_acknowledged=0
            for acked in "${acknowledged_patterns[@]}"; do
                [[ -n $acked && $acked == "$pattern" ]] || continue
                is_acknowledged=1
                break
            done
            ((is_acknowledged)) && continue
            violation_lines+=("issue #$issue predictedWriteSet path collides with a protected pattern: $pattern (matches $collision); drop it from the write set, route it through an operator step, or add \"$pattern\" to protectedPathAcknowledgement to accept the collision explicitly")
        done
    done < <(jq -r '
      (.protectedPathAcknowledgement // []) as $planAcknowledgement |
      .entries[] | [
        .issue,
        (.predictedWriteSet | join(",")),
        (((.protectedPathAcknowledgement // []) + $planAcknowledgement) | join(","))
      ] | @tsv
    ' "$dispatch_plan")

    if [[ -n $chain_base ]]; then
        while IFS=$'\t' read -r issue patterns exclusions; do
            IFS=',' read -ra prediction_patterns <<< "$patterns"
            for pattern in "${prediction_patterns[@]}"; do
                tree_glob_matches "$pattern" || tree_literal_parent_exists "$pattern" || {
                    sibling=$(nearest_tree_sibling "$pattern")
                    if [[ $sibling != none && $pattern == */** ]]; then sibling+="/**"; fi
                    violation_lines+=("issue #$issue predictedWriteSet glob matches no paths in chain-base tree: $pattern; nearest existing sibling: $sibling")
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
                violation_lines+=("issue #$issue write set names source but omits project test root: $test_root/**; include it in predictedWriteSet or explicitly list it in testRootExclusions")
                if [[ -z ${missing_roots_by_issue[$issue]+yes} ]]; then
                    missing_roots_by_issue[$issue]=$test_root
                    missing_issue_order+=("$issue")
                else
                    missing_roots_by_issue[$issue]+=",$test_root"
                fi
            done
        done < <(jq -r '
          (.testRootExclusions // []) as $planExclusions |
          .entries[] | [
            .issue,
            (.predictedWriteSet | join(",")),
            (((.testRootExclusions // []) + $planExclusions) | join(","))
          ] | @tsv
        ' "$dispatch_plan")
    fi

    # Protected-path collisions are never auto-fixable (dropping, splitting to
    # an operator step, or acknowledging is a human decision), so they are
    # reported alongside any test-root violations but excluded from the
    # missing-test-root remedy/--fix machinery below, which only ever
    # understands testRootExclusions patches.
    if ((${#violation_lines[@]})); then
        for violation in "${violation_lines[@]}"; do
            printf '%s: %s\n' "$PROGRAM" "$violation" >&2
        done
        if ((${#missing_issue_order[@]})); then
            if ((fix)); then
                fix_filter='.'
                for issue in "${missing_issue_order[@]}"; do
                    IFS=',' read -ra roots <<< "${missing_roots_by_issue[$issue]}"
                    missing_globs_json=$(printf '%s\n' "${roots[@]}" | jq -R '. + "/**"' | jq -sc .)
                    fix_filter+=" | (.entries[] | select(.issue == $issue) | .testRootExclusions) |= ((. // []) + $missing_globs_json | unique)"
                done
                target_dir=$(dirname -- "$dispatch_plan")
                fixed=$(mktemp "$target_dir/.dispatch-plan.XXXXXX") || die 'could not stage --fix patch'
                jq "$fix_filter" "$dispatch_plan" >"$fixed" || die 'could not apply --fix patch'
                chmod --reference="$dispatch_plan" "$fixed" 2>/dev/null || chmod 600 "$fixed"
                mv -- "$fixed" "$dispatch_plan"
                # --fix only ever patches missing-test-root violations; an
                # unmatched-glob violation, a protected-path collision, or
                # anything else collected in violation_lines is not fixable
                # by this patch, so the updated plan must be revalidated
                # before claiming success -- exiting 0 unconditionally
                # previously let a remaining, non-fixable violation through
                # silently.
                recheck_rc=0
                recheck_err=$("${BASH_SOURCE[0]}" --dispatch-plan "$dispatch_plan" \
                    --chain-base "$chain_base" --validate-only 2>&1 >/dev/null) || recheck_rc=$?
                if ((recheck_rc == 0)); then
                    printf 'dispatch-plan=%s fix=applied issues=%s\n' \
                        "$dispatch_plan" "$(IFS=,; printf '%s' "${missing_issue_order[*]}")"
                    exit 0
                fi
                printf '%s: fix=applied issues=%s but violations remain:\n' \
                    "$PROGRAM" "$(IFS=,; printf '%s' "${missing_issue_order[*]}")" >&2
                printf '%s\n' "$recheck_err" >&2
                exit 1
            fi
            # The remedy is built as data and printed shell-escaped
            # (printf %q per argument): a repository-derived test-root
            # value must never be interpolated inside a literal
            # single-quoted jq argument, where an embedded quote would
            # escape the operator's copy-pasted shell command.
            # $issue and $roots below are jq --argjson variables, not
            # shell variables -- the single quotes are load-bearing.
            # shellcheck disable=SC2016
            remedy_filter='(.entries[] | select(.issue == $issue) | .testRootExclusions) |= ((. // []) + $roots | unique)'
            printf '%s: remedy -- apply each entry testRootExclusions patch below, then re-run:\n' "$PROGRAM" >&2
            for issue in "${missing_issue_order[@]}"; do
                IFS=',' read -ra roots <<< "${missing_roots_by_issue[$issue]}"
                missing_globs_json=$(printf '%s\n' "${roots[@]}" | jq -R '. + "/**"' | jq -sc .)
                printf '  jq --argjson issue %q --argjson roots %q %q %q >%q.tmp && mv %q.tmp %q\n' \
                    "$issue" "$missing_globs_json" "$remedy_filter" \
                    "$dispatch_plan" "$dispatch_plan" "$dispatch_plan" "$dispatch_plan" >&2
            done
            printf '%s: or re-run with --fix to apply the same patches automatically\n' "$PROGRAM" >&2
        fi
        exit 1
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
