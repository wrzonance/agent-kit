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
    worker_root=$(git -C "$worker" rev-parse --show-toplevel 2>/dev/null) ||
        die "worker worktree is not a Git checkout: $worker"
    worker_root=$(canonical_dir "$worker_root") || die "cannot resolve worker root"
    [[ $worker == "$worker_root" ]] || die "worker path is not a worktree root: $worker"
    root_common=$(git_common_dir "$root") || die "cannot resolve root Git common directory"
    worker_common=$(git_common_dir "$worker") || die "cannot resolve worker Git common directory"
    [[ $root_common == "$worker_common" ]] ||
        die "worker worktree belongs to a different repository: $worker"
}

require_inside_root() {
    local root=$1 path=$2 candidate
    case $path in
        /*) candidate=$path;;
        *) candidate=$root/$path;;
    esac
    case $candidate in
        "$root"|"$root"/*) printf '%s\n' "$candidate";;
        *) die "path escapes root: $path";;
    esac
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

status_file() {
    local root=$1 output=$2 line status path
    git -C "$root" status --porcelain=v1 --untracked-files=all >"$output" ||
        die "could not snapshot Git status for $root"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        ((${#line} >= 4)) || continue
        status=${line:0:2}
        path=${line:3}
        # Porcelain v1 quotes unusual paths.  The cross-write ledger is
        # intentionally conservative: do not reinterpret escapes into a path
        # that could identify a different file.
        if [[ ${path:0:1} == '"' || ${path: -1} == '"' ]]; then
            continue
        fi
        printf '%s\t%s\t%s\t%s\n' "$path" "$status" \
            "$(path_mtime "$root/$path")" "$(path_hash "$root/$path")"
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

normalise_pattern() {
    local pattern=$1 root=$2
    case $pattern in
        "$root"/*) pattern=${pattern#"$root"/};;
        ./*) pattern=${pattern#./};;
    esac
    printf '%s\n' "$pattern"
}

matches_write_set() {
    local root=$1 path=$2 pattern
    shift 2
    for pattern in "$@"; do
        pattern=$(normalise_pattern "$pattern" "$root")
        [[ -n $pattern ]] || continue
        # shellcheck disable=SC2053  # write-set globs intentionally use [[ ]] patterns
        [[ $path == $pattern ]] && return 0
    done
    return 1
}

tracked_path() {
    local root=$1 path=$2
    git -C "$root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1
}

restore_exact_duplicate() {
    local root=$1 path=$2 expected_hash=${3:-} actual_hash
    actual_hash=$(path_hash "$root/$path")
    [[ -z $expected_hash || $expected_hash == "$actual_hash" ]] ||
        die "root path changed during disposal: $path"
    if tracked_path "$root" "$path"; then
        git -C "$root" restore --source=HEAD --worktree -- "$path" ||
            die "could not restore tracked duplicate: $path"
    else
        rm -- "$root/$path" || die "could not remove untracked duplicate: $path"
    fi
}

dispose_path() {
    local root=$1 worker=$2 path=$3 expected_hash=${4:-}
    local worker_file root_file worker_hash
    [[ -n $path && $path != /* && $path != .* && $path != */../* ]] ||
        die "dispose path must be repository-relative: $path"
    root_file=$(require_inside_root "$root" "$path")
    [[ -e $root_file || -L $root_file ]] || die "root path does not exist: $path"
    worker=$(canonical_dir "$worker") || die "cannot resolve worker worktree"
    require_matching_worktree "$root" "$worker"
    worker_file=$worker/$path
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
    local root='' output='' arg write_set
    local -a write_sets=()
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
    {
        printf 'version=1\nroot=%s\ncaptured-at=%s\n' "$root" "$captured"
        for write_set in "${write_sets[@]}"; do
            printf 'write-set=%s\n' "$write_set"
        done
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
    local arg write_set line path status mtime hash issue_attr attribute branch_match disposition
    local current_status current_raw captured now
    local -a write_sets=()
    declare -A baseline=()
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
        [[ -n ${baseline[$path]+present} ]] && continue
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
        if [[ -e "$worker/$path" || -L "$worker/$path" ]] &&
            cmp -s -- "$root/$path" "$worker/$path"; then
            branch_match=yes
        fi
        if [[ $branch_match == yes ]]; then
            if [[ $attribute == mtime-window && $dispose == yes ]]; then
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
