#!/usr/bin/env bash
# cross-write-check.sh -- snapshot a root checkout and account for dirt that
# appears in a dispatched worker's predicted write set.
#
# The root checkout is the observation point.  A worker worktree is only the
# byte-comparison source; it never becomes the target of this helper's writes.
# A Collect check is deliberately data-bearing: clean output is
# `cross-write=none`, while an incident names its mtime attribution and an
# explicit duplicate/divergent disposition.
set -euo pipefail

PROGRAM=${0##*/}

die() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
    exit 2
}

usage() {
    cat >&2 <<'EOF'
Usage:
  cross-write-check.sh snapshot --root PATH --output FILE --write-set GLOB [--write-set GLOB ...]
  cross-write-check.sh collect --root PATH --snapshot FILE --worker-worktree PATH --issue N \
      --write-set GLOB [--write-set GLOB ...] [--worker-start EPOCH --worker-end EPOCH] \
      [--dispose-duplicates]
  cross-write-check.sh dispose --root PATH --worker-worktree PATH --path RELATIVE [--expected-hash HASH]
EOF
    exit 2
}

canonical_dir() {
    local value=$1
    [[ -d $value ]] || return 1
    (cd -P -- "$value" && pwd -P)
}

canonical_file_parent() {
    local value=$1 parent base
    parent=${value%/*}
    base=${value##*/}
    [[ $parent != "$value" ]] || parent=.
    parent=$(canonical_dir "$parent") || return 1
    printf '%s/%s\n' "$parent" "$base"
}

require_root() {
    local value=$1 resolved
    [[ -d $value ]] || die "root is not a directory: $value"
    resolved=$(canonical_dir "$value") || die "cannot resolve root: $value"
    git -C "$resolved" rev-parse --show-toplevel >/dev/null 2>&1 ||
        die "root is not a Git checkout: $resolved"
    printf '%s\n' "$resolved"
}

git_common_dir() {
    local checkout=$1 common
    common=$(git -C "$checkout" rev-parse --git-common-dir 2>/dev/null) || return 1
    case $common in
        /*) ;;
        *) common=$checkout/$common;;
    esac
    canonical_dir "$common"
}

require_matching_worktree() {
    local root=$1 worker=$2 root_common worker_common worker_root
    [[ $root != "$worker" ]] || die 'worker worktree must differ from root'
    worker_root=$(git -C "$worker" rev-parse --show-toplevel 2>/dev/null) ||
        die "worker worktree is not a Git checkout: $worker"
    worker_root=$(canonical_dir "$worker_root") || die "cannot resolve worker root"
    [[ $worker == "$worker_root" ]] || die "worker path is not a worktree root: $worker"
    root_common=$(git_common_dir "$root") || die "cannot resolve root Git common directory"
    worker_common=$(git_common_dir "$worker") || die "cannot resolve worker Git common directory"
    [[ $root_common == "$worker_common" ]] ||
        die "worker worktree belongs to a different repository: $worker"
}

path_is_inside() {
    local root=$1 target=$2
    [[ $target == "$root" || $target == "$root"/* ]]
}

# Resolve every existing component, including symlinks in the parent. A
# missing leaf is safe to inspect only after its existing parent is proven to
# remain inside the checkout. Return 3 for a resolved escape so callers can
# report the containment failure rather than silently skipping it.
resolve_inside_root() {
    local root=$1 path=$2 candidate parent base resolved resolved_root
    [[ -n $path && $path != /* && $path != . && $path != ../* &&
        $path != */../* && $path != */.. ]] || return 2
    resolved_root=$(canonical_dir "$root") || return 2
    candidate="$resolved_root/$path"
    if [[ -e $candidate || -L $candidate ]]; then
        resolved=$(realpath -e -- "$candidate" 2>/dev/null) || return 2
    else
        parent=${candidate%/*}
        base=${candidate##*/}
        resolved=$(realpath -e -- "$parent" 2>/dev/null) || return 2
        resolved="$resolved/$base"
    fi
    path_is_inside "$resolved_root" "$resolved" || return 3
    printf '%s\n' "$candidate"
}

path_mtime() {
    local path=$1
    if [[ -e $path || -L $path ]]; then
        stat -c '%Y' -- "$path" 2>/dev/null || printf '0\n'
    else
        printf '0\n'
    fi
}

path_hash() {
    local path=$1 hash
    if [[ -f $path ]]; then
        hash=$(sha256sum -- "$path" 2>/dev/null | awk '{print $1}') || hash=''
        printf '%s\n' "${hash:-unreadable}"
    elif [[ -d $path ]]; then
        printf '%s\n' directory
    else
        printf '%s\n' absent
    fi
}

status_record() {
    local root=$1 path=$2 status=$3 safe_path
    [[ -n $path && $path != *$'\t'* && $path != *$'\n'* ]] ||
        die 'Git status path cannot be represented safely in the ledger'
    safe_path=$(resolve_inside_root "$root" "$path") ||
        die "Git status path resolves outside root: $path"
    printf '%s\t%s\t%s\t%s\n' "$path" "$status" \
        "$(path_mtime "$safe_path")" "$(path_hash "$safe_path")"
}

status_file() {
    local root=$1 output=$2 entry status path old_path
    git -C "$root" status --porcelain=v1 -z --untracked-files=all >"$output" ||
        die "could not snapshot Git status for $root"
    while IFS= read -r -d '' entry; do
        ((${#entry} >= 4)) || die 'malformed NUL Git status record'
        status=${entry:0:2}
        [[ ${entry:2:1} == ' ' ]] || die 'malformed NUL Git status status field'
        path=${entry:3}
        status_record "$root" "$path" "$status"
        # Porcelain v1 emits a second NUL record for rename/copy sources.
        # Consume and retain it; dropping it would hide a write-set path.
        case $status in
            R*|C*|*R|*C)
                IFS= read -r -d '' old_path || die 'truncated NUL rename record'
                status_record "$root" "$old_path" "$status"
                ;;
        esac
    done <"$output"
}

snapshot_at() {
    local snapshot=$1
    sed -n 's/^captured-at=//p' "$snapshot" | head -n 1
}

snapshot_write_sets() {
    local snapshot=$1
    sed -n 's/^write-set=//p' "$snapshot"
}

# capture_head_ref -- the symbolic ref name HEAD currently points at
# (e.g. "refs/heads/main"), or the literal "HEAD" when detached. This is the
# same distinction `git symbolic-ref` makes: a resolvable symbolic ref means
# an ordinary branch checkout, and its absence means a detached HEAD.
capture_head_ref() {
    local root=$1
    git -C "$root" symbolic-ref -q HEAD || printf 'HEAD\n'
}

capture_head_sha() {
    local root=$1
    git -C "$root" rev-parse HEAD
}

# capture_ref_reflog_count -- how many reflog entries a fully-qualified ref
# currently carries, or 0 when the ref has no reflog at all (reflogs
# disabled, or a ref Git never logs). Counting entries -- rather than reading
# wall-clock timestamps -- is what lets Collect notice a mutation with
# certainty: Git's reflog timestamps are whole-second and a fast dispatch can
# snapshot and mutate inside the same second, so a timestamp-only comparison
# cannot reliably tell "before" from "after". A monotonically growing entry
# count can: any count above the snapshot-time baseline means something was
# appended to that ref's reflog since the snapshot, full stop.
capture_ref_reflog_count() {
    local root=$1 fullref=$2
    git -C "$root" reflog show "$fullref" 2>/dev/null | wc -l | tr -d '[:space:]'
}

# capture_ref_reflog_usable -- "yes" when Git actually maintains a reflog for
# this ref, "no" otherwise (reflogs disabled via core.logAllRefUpdates=false,
# or a ref Git never logs). `reflog show` on an unlogged ref still exits 0
# with empty output -- indistinguishable from "logged, but zero entries so
# far" -- so usability has to be its own check (`reflog exists`), never
# inferred from an entry count of 0.
capture_ref_reflog_usable() {
    local root=$1 fullref=$2
    if git -C "$root" reflog exists "$fullref" >/dev/null 2>&1; then
        printf 'yes\n'
    else
        printf 'no\n'
    fi
}

# list_worktree_branches -- branch short names currently checked out by any
# *other* worktree of this same repository (i.e. every `git worktree list`
# entry except the one at $root itself). In parallel-issues, worker branches
# live in the SAME repository as the root checkout -- worktrees share
# `refs/heads/*` -- so a worker committing and pushing its own branch is a
# perfectly normal dispatch, not a root mutation. Ownership is decided from
# Git's own worktree metadata (`git worktree list --porcelain`), never by
# name pattern: a worktree's checked-out branch is filtered out unless that
# worktree's path canonicalizes to $root. Root's own branch is never
# filtered out by this function, even though the root checkout is itself one
# of the entries `git worktree list` reports.
list_worktree_branches() {
    local root=$1 line wt_path='' branch resolved
    while IFS= read -r line; do
        case $line in
            worktree\ *) wt_path=${line#worktree } ;;
            branch\ refs/heads/*)
                branch=${line#branch refs/heads/}
                resolved=$(canonical_dir "$wt_path" 2>/dev/null) || resolved=$wt_path
                [[ $resolved == "$root" ]] || printf '%s\n' "$branch"
                ;;
            '') wt_path='' ;;
        esac
    done < <(git -C "$root" worktree list --porcelain)
}

# capture_branch_shas -- one "name<TAB>sha<TAB>reflog-count<TAB>reflog-usable"
# line per local branch NOT checked out by another worktree, sorted by
# refname for deterministic snapshot/report ordering. `exclude` is a
# newline-delimited set of branch names (leading newline included; a
# *trailing* newline is not guaranteed -- it is built via `$(...)`, which
# strips trailing newlines, so a name may be the literal end of the string)
# to skip entirely -- branches owned by other worktrees are not this
# checkout's concern, and must not appear in either the baseline or the
# current capture.
capture_branch_shas() {
    local root=$1 exclude=$2 branch_name branch_sha fullref
    while IFS=$'\t' read -r branch_name branch_sha; do
        [[ -n $branch_name ]] || continue
        [[ $exclude == *$'\n'"$branch_name"$'\n'* || $exclude == *$'\n'"$branch_name" ]] && continue
        fullref="refs/heads/$branch_name"
        printf '%s\t%s\t%s\t%s\n' "$branch_name" "$branch_sha" \
            "$(capture_ref_reflog_count "$root" "$fullref")" \
            "$(capture_ref_reflog_usable "$root" "$fullref")"
    done < <(git -C "$root" for-each-ref --sort=refname \
        --format='%(refname:short)%09%(objectname)' refs/heads/)
}

# branch_name_set -- join branch names (one per positional arg) into the
# newline-delimited set format capture_branch_shas' `exclude` expects.
branch_name_set() {
    local name out=$'\n'
    for name in "$@"; do
        [[ -n $name ]] || continue
        out+="$name"$'\n'
    done
    printf '%s' "$out"
}

snapshot_head_ref() {
    local snapshot=$1
    sed -n 's/^head-ref=//p' "$snapshot" | head -n 1
}

snapshot_head_sha() {
    local snapshot=$1
    sed -n 's/^head-sha=//p' "$snapshot" | head -n 1
}

snapshot_head_reflog_count() {
    local snapshot=$1
    sed -n 's/^head-reflog-count=//p' "$snapshot" | head -n 1
}

snapshot_head_reflog_usable() {
    local snapshot=$1
    sed -n 's/^head-reflog-usable=//p' "$snapshot" | head -n 1
}

snapshot_branch_shas() {
    local snapshot=$1
    sed -n 's/^branch-sha=//p' "$snapshot"
}

# snapshot_excluded_branches -- branch names that were checked out by another
# worktree at snapshot time, and were therefore left out of the snapshot's
# branch-sha baseline entirely.
snapshot_excluded_branches() {
    local snapshot=$1
    sed -n 's/^excluded-branch=//p' "$snapshot"
}

# reflog_activity -- has a fully-qualified ref's reflog grown past
# baseline_count since the snapshot was taken, and if so, was the newest new
# entry's own timestamp inside [start, end]? Prints four tab-separated
# fields: activity (yes|no), the current entry count, the newest entry's
# subject ("none" when there is no new activity), and window
# (in-window|outside-window|unknown). "unknown" covers a ref whose reflog
# entry disappeared entirely (count fell, e.g. `git reflog expire`) -- still
# real activity, just not attributable to a single new entry.
reflog_activity() {
    local root=$1 fullref=$2 baseline_count=$3 start=$4 end=$5
    local current_count newest selector subject ts window=unknown _
    current_count=$(capture_ref_reflog_count "$root" "$fullref")
    if ((current_count == baseline_count)); then
        printf 'no\t%s\tnone\tunknown\n' "$current_count"
        return
    fi
    if ((current_count > baseline_count)); then
        # -1 (not a `| head -n1` pipe): under `set -o pipefail`, git writing
        # past a `head`-closed pipe dies from SIGPIPE and the pipeline's
        # non-zero status would trip `set -e` on this assignment.
        newest=$(git -C "$root" log -g -1 --date=unix --pretty='%H%x09%gd%x09%gs' \
            "$fullref" 2>/dev/null)
        IFS=$'\t' read -r _ selector subject <<<"$newest"
        window=outside-window
        if [[ $selector =~ @\{([0-9]+)\}$ ]]; then
            ts=${BASH_REMATCH[1]}
            ((ts >= start && ts <= end)) && window=in-window
        fi
        printf 'yes\t%s\t%s\t%s\n' "$current_count" "${subject//$'\t'/ }" "$window"
        return
    fi
    printf 'yes\t%s\treflog-count-decreased\tunknown\n' "$current_count"
}

normalise_pattern() {
    local pattern=$1 root=$2
    case $pattern in
        "$root"/*) pattern=${pattern#"$root"/};;
        ./*) pattern=${pattern#./};;
    esac
    printf '%s\n' "$pattern"
}

MATCH_PATTERN_PARTS=()
MATCH_PATH_PARTS=()

repo_path_match_at() {
    local pattern_index=$1 path_index=$2 component
    if ((pattern_index == ${#MATCH_PATTERN_PARTS[@]})); then
        ((path_index == ${#MATCH_PATH_PARTS[@]}))
        return
    fi
    component=${MATCH_PATTERN_PARTS[pattern_index]}
    if [[ $component == '**' ]]; then
        repo_path_match_at $((pattern_index + 1)) "$path_index" && return 0
        ((path_index < ${#MATCH_PATH_PARTS[@]})) || return 1
        repo_path_match_at "$pattern_index" $((path_index + 1))
        return
    fi
    ((path_index < ${#MATCH_PATH_PARTS[@]})) || return 1
    # A component is slash-free here, so ordinary shell component globs have
    # the repository pathspec semantics: '*' cannot consume '/'.
    # shellcheck disable=SC2053
    [[ ${MATCH_PATH_PARTS[path_index]} == $component ]] || return 1
    repo_path_match_at $((pattern_index + 1)) $((path_index + 1))
}

repo_path_match() {
    local pattern=$1 path=$2
    MATCH_PATTERN_PARTS=()
    MATCH_PATH_PARTS=()
    IFS=/ read -r -a MATCH_PATTERN_PARTS <<< "$pattern"
    IFS=/ read -r -a MATCH_PATH_PARTS <<< "${path%/}"
    repo_path_match_at 0 0
}

matches_write_set() {
    local root=$1 path=$2 pattern
    shift 2
    for pattern in "$@"; do
        pattern=$(normalise_pattern "$pattern" "$root")
        [[ -n $pattern ]] || continue
        repo_path_match "$pattern" "$path" && return 0
    done
    return 1
}

tracked_path() {
    local root=$1 path=$2
    git -C "$root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1
}

restore_exact_duplicate() {
    local root=$1 path=$2 expected_hash=${3:-} actual_hash root_file
    root_file=$(resolve_inside_root "$root" "$path") ||
        die "path escapes root during disposal: $path"
    [[ ! -L $root_file ]] || die "symlink target cannot be disposed: $path"
    actual_hash=$(path_hash "$root_file")
    [[ -z $expected_hash || $expected_hash == "$actual_hash" ]] ||
        die "root path changed during disposal: $path"
    if tracked_path "$root" "$path"; then
        git -C "$root" restore --source=HEAD --worktree -- "$path" ||
            die "could not restore tracked duplicate: $path"
    else
        rm -- "$root_file" || die "could not remove untracked duplicate: $path"
    fi
}

dispose_path() {
    local root=$1 worker=$2 path=$3 expected_hash=${4:-}
    local worker_file root_file worker_hash
    [[ -n $path && $path != /* && $path != . && $path != ../* &&
        $path != */../* && $path != */.. ]] ||
        die "dispose path must be repository-relative: $path"
    root_file=$(resolve_inside_root "$root" "$path") ||
        die "path escapes root during disposal: $path"
    [[ ! -L $root_file ]] || die "symlink target cannot be disposed: $path"
    [[ -e $root_file || -L $root_file ]] || die "root path does not exist: $path"
    worker=$(canonical_dir "$worker") || die "cannot resolve worker worktree"
    require_matching_worktree "$root" "$worker"
    worker_file=$(resolve_inside_root "$worker" "$path") ||
        die "worker path escapes worktree: $path"
    [[ ! -L $worker_file ]] || die "worker symlink target cannot be disposed: $path"
    [[ -e $worker_file || -L $worker_file ]] ||
        die "worker path does not exist for comparison: $path"
    worker_hash=$(path_hash "$worker_file")
    [[ -z $expected_hash || $expected_hash == "$worker_hash" ]] ||
        die "worker bytes do not match expected hash: $path"
    [[ $(path_hash "$root_file") == "$worker_hash" ]] ||
        die "root path is divergent; refusing disposal: $path"
    restore_exact_duplicate "$root" "$path" "$worker_hash"
    printf 'disposition=restored-exact-duplicate path=%s worker-worktree=%s\n' \
        "$path" "$worker"
}

snapshot_cmd() {
    local root='' output='' arg write_set branch_name branch_sha
    local branch_reflog_count branch_reflog_usable exclude_set excluded_branch
    local -a write_sets=() worktree_excluded=()
    while (($#)); do
        arg=$1
        case $arg in
            --root) (($# >= 2)) || die '--root requires a value'; root=$2; shift 2;;
            --output) (($# >= 2)) || die '--output requires a value'; output=$2; shift 2;;
            --write-set) (($# >= 2)) || die '--write-set requires a value'; write_sets+=("$2"); shift 2;;
            -h|--help) usage;;
            *) die "unknown snapshot option: $arg";;
        esac
    done
    [[ -n $root && -n $output && ${#write_sets[@]} -gt 0 ]] || usage
    root=$(require_root "$root")
    [[ -d $root/.agent && ! -L $root/.agent ]] || die "root .agent state directory is unavailable: $root"
    output=$(canonical_file_parent "$output") || die "cannot resolve snapshot parent: $output"
    case $output in
        "$root/.agent"/*) ;;
        *) die "snapshot output must stay under root .agent state: $output";;
    esac
    local output_parent=${output%/*} temp status_path captured
    [[ -d $output_parent ]] || die "snapshot parent is not a directory: $output_parent"
    temp=$(mktemp "$output.tmp.XXXXXXXXXX") || die "could not create snapshot temporary file"
    status_path=$(mktemp "$output.status.XXXXXXXXXX") || die "could not create status temporary file"
    captured=$(date +%s)
    mapfile -t worktree_excluded < <(list_worktree_branches "$root")
    exclude_set=$(branch_name_set "${worktree_excluded[@]}")
    {
        printf 'version=1\nroot=%s\ncaptured-at=%s\n' "$root" "$captured"
        for write_set in "${write_sets[@]}"; do
            printf 'write-set=%s\n' "$write_set"
        done
        for excluded_branch in "${worktree_excluded[@]}"; do
            printf 'excluded-branch=%s\n' "$excluded_branch"
        done
        printf 'head-ref=%s\n' "$(capture_head_ref "$root")"
        printf 'head-sha=%s\n' "$(capture_head_sha "$root")"
        printf 'head-reflog-count=%s\n' "$(capture_ref_reflog_count "$root" HEAD)"
        printf 'head-reflog-usable=%s\n' "$(capture_ref_reflog_usable "$root" HEAD)"
        while IFS=$'\t' read -r branch_name branch_sha branch_reflog_count branch_reflog_usable; do
            [[ -n $branch_name ]] || continue
            printf 'branch-sha=%s\t%s\t%s\t%s\n' \
                "$branch_name" "$branch_sha" "$branch_reflog_count" "$branch_reflog_usable"
        done < <(capture_branch_shas "$root" "$exclude_set")
        printf 'path\tstatus\tmtime\tsha256\n'
        status_file "$root" "$status_path"
    } >"$temp"
    chmod 600 -- "$temp" || die "could not secure snapshot"
    mv -f -- "$temp" "$output" || die "could not publish snapshot: $output"
    rm -f -- "$status_path"
    printf 'snapshot=%s root=%s captured-at=%s\n' "$output" "$root" "$captured"
}

collect_cmd() {
    local root='' snapshot='' worker='' issue='' worker_start='' worker_end='' dispose=no
    local arg write_set path status mtime hash issue_attr attribute branch_match disposition
    local baseline_value baseline_hash baseline_changed root_file worker_file
    local current_status current_raw captured now
    local baseline_head_ref baseline_head_sha baseline_head_reflog_count baseline_head_reflog_usable
    local current_head_ref current_head_sha current_head_reflog_usable
    local ref_activity ref_summary ref_window branch_name branch_sha branch_reflog_count _
    local branch_reflog_usable baseline_branch_sha current_branch_sha current_branch_reflog_usable
    local exclude_set excluded_branch
    local -a write_sets=() sorted_branch_names=() baseline_excluded=() current_excluded=()
    declare -A baseline=() baseline_branches=() baseline_branch_reflog_counts=()
    declare -A baseline_branch_reflog_usable=() current_branches=() union_excluded=()
    while (($#)); do
        arg=$1
        case $arg in
            --root) (($# >= 2)) || die '--root requires a value'; root=$2; shift 2;;
            --snapshot) (($# >= 2)) || die '--snapshot requires a value'; snapshot=$2; shift 2;;
            --worker-worktree) (($# >= 2)) || die '--worker-worktree requires a value'; worker=$2; shift 2;;
            --issue|--worker-id) (($# >= 2)) || die "$arg requires a value"; issue=${2#\#}; shift 2;;
            --worker-start) (($# >= 2)) || die '--worker-start requires a value'; worker_start=$2; shift 2;;
            --worker-end) (($# >= 2)) || die '--worker-end requires a value'; worker_end=$2; shift 2;;
            --write-set) (($# >= 2)) || die '--write-set requires a value'; write_sets+=("$2"); shift 2;;
            --dispose-duplicates) dispose=yes; shift;;
            -h|--help) usage;;
            *) die "unknown collect option: $arg";;
        esac
    done
    [[ -n $root && -n $snapshot && -n $worker && -n $issue ]] || usage
    [[ -r $snapshot && -f $snapshot && ! -L $snapshot ]] || die "snapshot is unreadable: $snapshot"
    root=$(require_root "$root")
    [[ $(sed -n 's/^root=//p' "$snapshot" | head -n 1) == "$root" ]] ||
        die 'snapshot root does not match the Collect root'
    worker=$(canonical_dir "$worker") || die "cannot resolve worker worktree: $worker"
    require_matching_worktree "$root" "$worker"
    [[ ${#write_sets[@]} -gt 0 ]] || mapfile -t write_sets < <(snapshot_write_sets "$snapshot")
    ((${#write_sets[@]} > 0)) || die 'Collect requires at least one write set'
    captured=$(snapshot_at "$snapshot")
    [[ $captured =~ ^[0-9]+$ ]] || die 'snapshot captured-at is invalid'
    now=$(date +%s)
    [[ -n $worker_start ]] || worker_start=$captured
    [[ -n $worker_end ]] || worker_end=$now
    [[ $worker_start =~ ^[0-9]+$ && $worker_end =~ ^[0-9]+$ ]] ||
        die 'worker mtime window must be integer epochs'

    while IFS=$'\t' read -r path status mtime hash; do
        [[ $path == path || -z $path ]] && continue
        baseline["$path"]=$status$'\t'$mtime$'\t'$hash
    done < <(awk 'index($0, "\t") { print }' "$snapshot")

    current_status=$(mktemp) || die 'could not create current status temporary file'
    current_raw=$(mktemp) || die 'could not create raw current status temporary file'
    status_file "$root" "$current_raw" >"$current_status"
    rm -f -- "$current_raw"
    local incidents=0
    while IFS=$'\t' read -r path status mtime hash; do
        [[ -n $path ]] || continue
        baseline_changed=no
        if [[ -n ${baseline[$path]+present} ]]; then
            baseline_value=${baseline[$path]}
            baseline_hash=${baseline_value##*$'\t'}
        else
            baseline_hash=''
        fi
        if [[ $hash == unreadable || $baseline_hash == unreadable ]]; then
            matches_write_set "$root" "$path" "${write_sets[@]}" || continue
            incidents=$((incidents + 1))
            printf 'cross-write=path=%s issue=unknown attribute=unreadable-hash status=%s mtime=%s branch-match=unknown disposition=surface-unreadable\n' \
                "$path" "$status" "$mtime"
            continue
        fi
        if [[ -n ${baseline[$path]+present} ]]; then
            if [[ $hash == "$baseline_hash" ]]; then
                # The bytes are unchanged from the immutable baseline; this is
                # not a worker overwrite even if Git's status code changed.
                continue
            fi
            baseline_changed=yes
        fi
        matches_write_set "$root" "$path" "${write_sets[@]}" || continue
        incidents=$((incidents + 1))
        if ((mtime >= worker_start && mtime <= worker_end)); then
            issue_attr=$issue
            issue_attr="${issue_attr:-unknown}"
            attribute='mtime-window'
        else
            issue_attr=unknown
            attribute='outside-mtime-window'
        fi
        branch_match=no
        root_file=$(resolve_inside_root "$root" "$path") ||
            die "current status path escapes root: $path"
        worker_file=$(resolve_inside_root "$worker" "$path") ||
            die "worker path escapes worktree: $path"
        if [[ -e "$worker_file" || -L "$worker_file" ]] &&
            [[ -e "$root_file" || -L "$root_file" ]] &&
            cmp -s -- "$root_file" "$worker_file"; then
            branch_match=yes
        fi
        if [[ $branch_match == yes ]]; then
            if [[ $baseline_changed == yes ]]; then
                disposition=surface-overwrote-baseline
            elif [[ $attribute == mtime-window && $dispose == yes ]]; then
                restore_exact_duplicate "$root" "$path" "$hash"
                disposition=restored-exact-duplicate
            elif [[ $attribute == mtime-window ]]; then
                disposition=restore-exact-duplicate
            else
                disposition=surface-exact-outside-window
            fi
        else
            disposition=surface-divergent
        fi
        printf 'cross-write=path=%s issue=%s attribute=%s status=%s mtime=%s branch-match=%s disposition=%s\n' \
            "$path" "$issue_attr" "$attribute" "$status" "$mtime" "$branch_match" "$disposition"
    done <"$current_status"
    rm -f -- "$current_status"

    # --- ref incidents: HEAD's ref/sha and every baseline-tracked branch ----
    # `git reset --soft`, `git checkout <branch>`, and `git branch -f` move
    # refs without writing a single file, so the file-status loop above
    # cannot see them. A plain baseline-vs-current comparison also misses a
    # ref that moved and landed back on its baseline value (a `reset --soft`
    # to the pre-dispatch commit is byte-identical to "untouched"), so every
    # baseline-tracked ref is additionally checked for reflog growth since
    # the snapshot -- see reflog_activity for why entry counts, not
    # timestamps, are what detect that case reliably.
    baseline_head_ref=$(snapshot_head_ref "$snapshot")
    baseline_head_sha=$(snapshot_head_sha "$snapshot")
    baseline_head_reflog_count=$(snapshot_head_reflog_count "$snapshot")
    [[ -n $baseline_head_reflog_count ]] || baseline_head_reflog_count=0
    baseline_head_reflog_usable=$(snapshot_head_reflog_usable "$snapshot")
    current_head_ref=$(capture_head_ref "$root")
    current_head_sha=$(capture_head_sha "$root")
    current_head_reflog_usable=$(capture_ref_reflog_usable "$root" HEAD)
    IFS=$'\t' read -r ref_activity _ ref_summary ref_window < <(
        reflog_activity "$root" HEAD "$baseline_head_reflog_count" "$worker_start" "$worker_end"
    )

    # A ref this fence cannot observe cannot be certified clean: a reflog
    # unusable at snapshot or collect time (core.logAllRefUpdates=false, or a
    # ref Git never logs) is always a named incident, independent of whether
    # HEAD's ref/sha also changed -- "cross-write=none" must never mean "we
    # couldn't tell", only "we checked, and nothing moved".
    if [[ $baseline_head_reflog_usable != yes || $current_head_reflog_usable != yes ]]; then
        incidents=$((incidents + 1))
        printf 'cross-ref=type=head-reflog-unavailable name=HEAD baseline=%s current=%s restored=unknown window=unknown reflog=unavailable\n' \
            "$baseline_head_sha" "$current_head_sha"
    fi

    if [[ -n $baseline_head_ref && $current_head_ref != "$baseline_head_ref" ]]; then
        incidents=$((incidents + 1))
        printf 'cross-ref=type=head-branch-changed name=HEAD baseline=%s current=%s restored=no window=%s reflog=%s\n' \
            "$baseline_head_ref" "$current_head_ref" "$ref_window" "$ref_summary"
    elif [[ -n $baseline_head_sha && $current_head_sha != "$baseline_head_sha" ]]; then
        incidents=$((incidents + 1))
        printf 'cross-ref=type=head-sha-changed name=HEAD baseline=%s current=%s restored=no window=%s reflog=%s\n' \
            "$baseline_head_sha" "$current_head_sha" "$ref_window" "$ref_summary"
    elif [[ -n $baseline_head_sha && $ref_activity == yes ]]; then
        incidents=$((incidents + 1))
        printf 'cross-ref=type=head-sha-changed name=HEAD baseline=%s current=%s restored=yes window=%s reflog=%s\n' \
            "$baseline_head_sha" "$current_head_sha" "$ref_window" "$ref_summary"
    fi

    # A branch checked out by another worktree is out of scope for the ROOT
    # ref fence -- that worktree owns its own commits and pushes (see
    # list_worktree_branches). Ownership can change between snapshot and
    # collect (a worker worktree can be added, or removed, mid-window), so a
    # branch excluded at EITHER end is excluded at BOTH: union, not
    # intersection. Filtering only the side where it happens to be owned
    # would read the other side's absence as a fabricated branch-created or
    # branch-deleted incident -- a worktree lifecycle event, not a root
    # mutation.
    mapfile -t baseline_excluded < <(snapshot_excluded_branches "$snapshot")
    mapfile -t current_excluded < <(list_worktree_branches "$root")
    for excluded_branch in "${baseline_excluded[@]}" "${current_excluded[@]}"; do
        [[ -n $excluded_branch ]] || continue
        union_excluded["$excluded_branch"]=1
    done
    exclude_set=$(branch_name_set "${!union_excluded[@]}")

    while IFS=$'\t' read -r branch_name branch_sha branch_reflog_count branch_reflog_usable; do
        [[ -n $branch_name ]] || continue
        [[ -n ${union_excluded[$branch_name]+present} ]] && continue
        baseline_branches["$branch_name"]=$branch_sha
        baseline_branch_reflog_counts["$branch_name"]=${branch_reflog_count:-0}
        baseline_branch_reflog_usable["$branch_name"]=${branch_reflog_usable:-no}
    done < <(snapshot_branch_shas "$snapshot")
    while IFS=$'\t' read -r branch_name branch_sha branch_reflog_count branch_reflog_usable; do
        [[ -n $branch_name ]] || continue
        current_branches["$branch_name"]=$branch_sha
    done < <(capture_branch_shas "$root" "$exclude_set")

    # Compare the UNION of baseline and current branch names, not just the
    # baseline set: a branch created in the root checkout never appears in
    # baseline, and a branch deleted from it never appears in current -- each
    # is a real ref mutation this fence must not pass through as clean.
    mapfile -t sorted_branch_names < <(
        printf '%s\n' "${!baseline_branches[@]}" "${!current_branches[@]}" | sort -u
    )
    for branch_name in "${sorted_branch_names[@]}"; do
        if [[ -z ${baseline_branches[$branch_name]+present} ]]; then
            # Created: no baseline entry to compare against, so the presence
            # of the name at all is the incident. reflog_activity against a
            # zero baseline still reports a useful window/summary when the
            # branch's own creation reflog entry exists.
            current_branch_sha=${current_branches[$branch_name]}
            incidents=$((incidents + 1))
            IFS=$'\t' read -r _ _ ref_summary ref_window < <(
                reflog_activity "$root" "refs/heads/$branch_name" 0 "$worker_start" "$worker_end"
            )
            printf 'cross-ref=type=branch-created name=%s baseline=none current=%s restored=no window=%s reflog=%s\n' \
                "$branch_name" "$current_branch_sha" "$ref_window" "$ref_summary"
            continue
        fi
        baseline_branch_sha=${baseline_branches[$branch_name]}
        if [[ -z ${current_branches[$branch_name]+present} ]]; then
            # Deleted: the ref (and its reflog) is gone, so there is nothing
            # left to compare bytes or reflog activity against -- the
            # disappearance itself is the incident.
            incidents=$((incidents + 1))
            printf 'cross-ref=type=branch-deleted name=%s baseline=%s current=none restored=no window=unknown reflog=branch-deleted\n' \
                "$branch_name" "$baseline_branch_sha"
            continue
        fi
        current_branch_sha=${current_branches[$branch_name]}
        current_branch_reflog_usable=$(capture_ref_reflog_usable "$root" "refs/heads/$branch_name")
        if [[ ${baseline_branch_reflog_usable[$branch_name]:-no} != yes ||
              $current_branch_reflog_usable != yes ]]; then
            incidents=$((incidents + 1))
            printf 'cross-ref=type=branch-reflog-unavailable name=%s baseline=%s current=%s restored=unknown window=unknown reflog=unavailable\n' \
                "$branch_name" "$baseline_branch_sha" "$current_branch_sha"
        fi
        IFS=$'\t' read -r ref_activity _ ref_summary ref_window < <(
            reflog_activity "$root" "refs/heads/$branch_name" \
                "${baseline_branch_reflog_counts[$branch_name]:-0}" "$worker_start" "$worker_end"
        )
        if [[ $current_branch_sha != "$baseline_branch_sha" ]]; then
            incidents=$((incidents + 1))
            printf 'cross-ref=type=branch-moved name=%s baseline=%s current=%s restored=no window=%s reflog=%s\n' \
                "$branch_name" "$baseline_branch_sha" "$current_branch_sha" "$ref_window" "$ref_summary"
        elif [[ $ref_activity == yes ]]; then
            incidents=$((incidents + 1))
            printf 'cross-ref=type=branch-moved name=%s baseline=%s current=%s restored=yes window=%s reflog=%s\n' \
                "$branch_name" "$baseline_branch_sha" "$current_branch_sha" "$ref_window" "$ref_summary"
        fi
    done

    if ((incidents == 0)); then
        printf 'cross-write=none root=%s\n' "$root"
        return 0
    fi
    return 10
}

dispose_cmd() {
    local root='' worker='' path='' expected_hash='' arg
    while (($#)); do
        arg=$1
        case $arg in
            --root) (($# >= 2)) || die '--root requires a value'; root=$2; shift 2;;
            --worker-worktree) (($# >= 2)) || die '--worker-worktree requires a value'; worker=$2; shift 2;;
            --path) (($# >= 2)) || die '--path requires a value'; path=$2; shift 2;;
            --expected-hash) (($# >= 2)) || die '--expected-hash requires a value'; expected_hash=$2; shift 2;;
            -h|--help) usage;;
            *) die "unknown dispose option: $arg";;
        esac
    done
    [[ -n $root && -n $worker && -n $path ]] || usage
    root=$(require_root "$root")
    dispose_path "$root" "$worker" "$path" "$expected_hash"
}

[[ $# -gt 0 ]] || usage
command=$1
shift
case $command in
    snapshot) snapshot_cmd "$@";;
    collect) collect_cmd "$@";;
    dispose) dispose_cmd "$@";;
    -h|--help) usage 0;;
    *) die "unknown command: $command";;
esac
