#!/usr/bin/env bash
# verification-baseline.sh -- classify a declared-verification failure as
# baseline-red (every failing path is provably unchanged from HEAD and
# outside this PR's diff against its base) or change-caused-red (at least one
# failing path was touched by this change).
#
# North star: a clean change must never be blocked from publication by a
# repository gate that is red for reasons entirely outside the diff. Making
# the gate pass would mean touching unrelated files (refused); parking stalls
# a run an operator then has to unblock by hand. baseline-red is the third,
# correct outcome -- publish, with the pre-existing red recorded as evidence.
# It never claims "fully green", and it never unblocks ready-flip or merge:
# those stay gated on the declared verification passing, unchanged.
#
# Usage: verification-baseline.sh --base REF --log FILE --paths P [P...]
#            [--check NAME] [--issue N] [--repo-root DIR]
#            [--evidence-dir DIR] [--force]
#
# Exit 0 (stdout: "baseline-red ..." + a markdown evidence block) only when
# EVERY path is both unchanged in the worktree (`git diff --exit-code HEAD`)
# and outside the diff against --base (`git diff --exit-code BASE...HEAD`).
# Exit 1 (stdout: "change-caused-red ...") when any path fails either check --
# that path was touched by this change, and the failure is fixed as today.
# Exit 2 is a usage error.
#
# With --check NAME, a baseline-red decision is persisted to
# <evidence-dir>/NAME.json (default <repo-root>/.agent/evidence/baseline/) so
# the next session for the same paths and base reuses it without re-running
# the diffs -- pass --force to recompute anyway.
set -euo pipefail

readonly PROGNAME=${0##*/}
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/private-dir.sh"

BASE=''
LOG=''
CHECK=''
ISSUE='none'
REPO_ROOT=''
EVIDENCE_DIR=''
FORCE=0
declare -a RAW_PATHS=()

usage() {
    cat <<EOF
Usage: $PROGNAME --base REF --log FILE --paths P [P...] [--check NAME]
           [--issue N] [--repo-root DIR] [--evidence-dir DIR] [--force]

--base REF          Base ref/SHA this PR targets (e.g. main, origin/main).
--log FILE          Path to the declared-verification failure log (recorded
                     as evidence provenance; must be an existing, readable
                     regular file).
--paths P [P...]    One or more failing paths from that verification run.
                     Repeat the flag or pass several values; consumes
                     arguments up to the next --flag.
--check NAME        Name of the failing check (e.g. frontend-format). Only
                     lowercase letters, digits, dashes, or underscores are
                     accepted (mirrors agent-run.sh's --cmd NAME charset).
                     Required to persist or reuse a decision.
--issue N           Tracking issue number for the pre-existing red. Default:
                     none.
--repo-root DIR     Default: \`git rev-parse --show-toplevel\`.
--evidence-dir DIR  Default: <repo-root>/.agent/evidence/baseline.
--force             Ignore any persisted decision and recompute.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit 1
}

die_usage() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    usage >&2
    exit 2
}

require_value() {
    [[ -n ${2:-} ]] || die_usage "option $1 requires a value"
}

parse_args() {
    while (($#)); do
        case $1 in
            --base) require_value "$1" "${2:-}"; BASE=$2; shift 2 ;;
            --base=*) BASE=${1#*=}; shift ;;
            --log) require_value "$1" "${2:-}"; LOG=$2; shift 2 ;;
            --log=*) LOG=${1#*=}; shift ;;
            --check) require_value "$1" "${2:-}"; CHECK=$2; shift 2 ;;
            --check=*) CHECK=${1#*=}; shift ;;
            --issue) require_value "$1" "${2:-}"; ISSUE=$2; shift 2 ;;
            --issue=*) ISSUE=${1#*=}; shift ;;
            --repo-root) require_value "$1" "${2:-}"; REPO_ROOT=$2; shift 2 ;;
            --repo-root=*) REPO_ROOT=${1#*=}; shift ;;
            --evidence-dir) require_value "$1" "${2:-}"; EVIDENCE_DIR=$2; shift 2 ;;
            --evidence-dir=*) EVIDENCE_DIR=${1#*=}; shift ;;
            --force) FORCE=1; shift ;;
            --paths)
                shift
                [[ $# -gt 0 && $1 != --* ]] || die_usage '--paths requires at least one value'
                while [[ $# -gt 0 && $1 != --* ]]; do
                    RAW_PATHS+=("$1")
                    shift
                done
                ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
}

validate_args() {
    [[ -n $BASE ]] || die_usage '--base is required'
    [[ -n $LOG ]] || die_usage '--log is required'
    [[ -f $LOG && ! -L $LOG && -r $LOG ]] || die "--log must be an existing readable regular file: $LOG"
    ((${#RAW_PATHS[@]} > 0)) || die_usage '--paths requires at least one value'
    [[ $ISSUE == none || $ISSUE =~ ^[1-9][0-9]*$ ]] || die_usage '--issue must be a positive integer or "none"'
    if [[ -n $CHECK ]]; then
        [[ $CHECK =~ ^[a-z][a-z0-9_-]*$ ]] || die_usage '--check must be lowercase letters, digits, dashes, or underscores, starting with a letter'
    fi
    command -v jq >/dev/null 2>&1 || die 'jq is not installed; evidence unavailable'
}

resolve_repo_root() {
    if [[ -n $REPO_ROOT ]]; then
        [[ -d $REPO_ROOT ]] || die_usage "--repo-root is not a directory: $REPO_ROOT"
        REPO_ROOT=$(cd -- "$REPO_ROOT" && pwd -P) || die "could not resolve --repo-root: $REPO_ROOT"
    else
        REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) ||
            die 'could not resolve the repository root (pass --repo-root outside a Git worktree)'
    fi
    [[ -n $EVIDENCE_DIR ]] || EVIDENCE_DIR="$REPO_ROOT/.agent/evidence/baseline"
}

# normalize_paths -- resolves every --paths value against REPO_ROOT and
# rejects one that escapes it, then fills NORM_PATHS (dedup'd, argv order
# preserved) and SORTED_PATHS (unique, sorted -- the comparison/storage key).
declare -a NORM_PATHS=()
declare -a SORTED_PATHS=()
normalize_paths() {
    local raw abs rel p seen
    for raw in "${RAW_PATHS[@]}"; do
        [[ -n $raw ]] || die "a --paths value is empty"
        if [[ $raw == /* ]]; then
            abs=$raw
        else
            abs=$REPO_ROOT/$raw
        fi
        abs=$(realpath -m -- "$abs") || die "could not resolve path: $raw"
        case $abs in
            "$REPO_ROOT"/*) rel=${abs#"$REPO_ROOT"/} ;;
            "$REPO_ROOT") die "--paths value resolves to the repository root: $raw" ;;
            *) die "--paths value escapes the repository: $raw" ;;
        esac
        seen=0
        for p in "${NORM_PATHS[@]}"; do
            [[ $p == "$rel" ]] && { seen=1; break; }
        done
        ((seen)) || NORM_PATHS+=("$rel")
    done
    while IFS= read -r p; do
        SORTED_PATHS+=("$p")
    done < <(printf '%s\n' "${NORM_PATHS[@]}" | LC_ALL=C sort -u)
}

resolve_base_sha() {
    BASE_SHA=$(git -C "$REPO_ROOT" rev-parse --verify "${BASE}^{commit}" 2>/dev/null) ||
        die "--base is not a resolvable commit: $BASE"
}

# path_diff_check RANGE PATH -- runs `git diff --exit-code RANGE -- PATH`,
# prints "yes" (no differences) or "no" (differences), and dies loudly on any
# other exit status (a bad range/path is evidence-unavailable, never a quiet
# "no").
path_diff_check() {
    local range=$1 path=$2 rc=0
    git -C "$REPO_ROOT" diff --exit-code "$range" -- "$path" >/dev/null 2>&1 || rc=$?
    case $rc in
        0) printf 'yes\n' ;;
        1) printf 'no\n' ;;
        *) die "git diff --exit-code $range -- $path failed unexpectedly (rc=$rc); evidence unavailable" ;;
    esac
}

evidence_block() {
    local heading='## Baseline verification evidence' path_list issue_line
    [[ -z $CHECK ]] || heading+=" — $CHECK"
    path_list=$(printf '%s ' "${NORM_PATHS[@]}")
    path_list=${path_list% }
    if [[ $ISSUE == none ]]; then
        issue_line='The baseline is not yet tracked by an issue.'
    else
        issue_line="The baseline is tracked in #$ISSUE."
    fi
    printf '%s\n\n' "$heading"
    # shellcheck disable=SC2016  # literal backticked markdown, not command substitution
    printf -- '- `git diff --exit-code HEAD -- %s` returned exit `0`, proving the files are unchanged in the worktree.\n' "$path_list"
    # shellcheck disable=SC2016  # literal backticked markdown, not command substitution
    printf -- '- `git diff --exit-code %s...HEAD -- %s` returned exit `0`, proving the files are outside this PR diff.\n' "$BASE" "$path_list"
    printf -- '- %s No unrelated file was reformatted.\n' "$issue_line"
}

decision_path() {
    [[ -n $CHECK ]] || return 1
    printf '%s/%s.json\n' "$EVIDENCE_DIR" "$CHECK"
}

# try_reuse_decision -- exits 0 (printing the reconstructed marker + evidence
# block) when a persisted decision exists for --check and its stored paths
# and base SHA exactly match this invocation; otherwise returns without
# exiting so the caller falls through to a fresh classification.
try_reuse_decision() {
    local file stored_paths_json stored_base stored_issue stored_log current_paths_json
    ((FORCE == 0)) || return 0
    file=$(decision_path) || return 0
    [[ -f $file && ! -L $file && -r $file ]] || return 0
    stored_base=$(jq -r '.baseSha // empty' -- "$file" 2>/dev/null) || return 0
    [[ -n $stored_base && $stored_base == "$BASE_SHA" ]] || return 0
    current_paths_json=$(printf '%s\n' "${SORTED_PATHS[@]}" | jq -R . | jq -s -c 'sort')
    stored_paths_json=$(jq -c '(.paths // []) | sort' -- "$file" 2>/dev/null) || return 0
    [[ -n $stored_paths_json && $stored_paths_json == "$current_paths_json" ]] || return 0
    stored_issue=$(jq -r '.issue // "none"' -- "$file" 2>/dev/null) || stored_issue=$ISSUE
    stored_log=$(jq -r '.log // empty' -- "$file" 2>/dev/null) || stored_log=$LOG
    ISSUE=$stored_issue
    printf 'baseline-red check=%s paths=%s unchanged=yes outside-diff=yes issue=%s base=%s log=%s reused=%s\n' \
        "$CHECK" "${#SORTED_PATHS[@]}" "$ISSUE" "$BASE" "$stored_log" "$file"
    printf '\n'
    evidence_block
    exit 0
}

persist_decision() {
    local file dir tmp paths_json
    [[ -n $CHECK ]] || return 0
    file=$(decision_path) || return 0
    dir=$EVIDENCE_DIR
    mkdir -p -- "$REPO_ROOT/.agent" 2>/dev/null || die "could not create .agent under $REPO_ROOT"
    private_dir_ensure_root_evidence
    private_dir_ensure "$dir" 'baseline evidence directory'
    paths_json=$(printf '%s\n' "${SORTED_PATHS[@]}" | jq -R . | jq -s -c 'sort')
    tmp="$dir/.$CHECK.$$.json"
    jq -n \
        --arg check "$CHECK" \
        --argjson paths "$paths_json" \
        --arg base "$BASE" \
        --arg baseSha "$BASE_SHA" \
        --arg issue "$ISSUE" \
        --arg log "$LOG" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{check: $check, paths: $paths, base: $base, baseSha: $baseSha, issue: $issue, log: $log, timestamp: $timestamp}' \
        >"$tmp" || { rm -f -- "$tmp"; die "could not write baseline decision: $file"; }
    chmod 600 -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; die "could not finalize baseline decision: $file"; }
}

# private_dir_ensure_root_evidence -- establishes REPO_ROOT/.agent/evidence
# as a private 0700 root the first time a baseline decision needs one,
# mirroring run-dir.sh's ensure_private_root without requiring an
# already-private ancestor (private_dir_ensure alone refuses to bootstrap
# the very first private boundary under a shared, non-private .agent/).
private_dir_ensure_root_evidence() {
    local dir=$REPO_ROOT/.agent/evidence mode
    [[ ! -L $dir ]] || die "environment evidence directory must not be a symlink: $dir"
    if [[ -e $dir ]]; then
        [[ -d $dir ]] || die "environment evidence directory must be a directory: $dir"
        [[ -O $dir ]] || die "environment evidence directory is not owned by this user: $dir"
        mode=$(stat -c %a -- "$dir") || die "could not inspect: $dir"
        [[ $mode == 700 ]] || die "environment evidence directory must have mode 0700: $dir"
        return 0
    fi
    mkdir -m 700 -- "$dir" || die "could not create private evidence directory: $dir"
}

main() {
    parse_args "$@"
    validate_args
    resolve_repo_root
    normalize_paths
    resolve_base_sha
    try_reuse_decision

    local any_changed=0 p unchanged outside
    declare -a report_lines=()
    for p in "${NORM_PATHS[@]}"; do
        unchanged=$(path_diff_check "HEAD" "$p")
        outside=$(path_diff_check "${BASE}...HEAD" "$p")
        [[ $unchanged == yes && $outside == yes ]] || any_changed=1
        report_lines+=("path=$p unchanged=$unchanged outside-diff=$outside")
    done

    if ((any_changed == 0)); then
        persist_decision
        printf 'baseline-red check=%s paths=%s unchanged=yes outside-diff=yes issue=%s base=%s log=%s\n' \
            "${CHECK:-unset}" "${#NORM_PATHS[@]}" "$ISSUE" "$BASE" "$LOG"
        printf '\n'
        evidence_block
        exit 0
    fi

    printf 'change-caused-red check=%s paths=%s\n' "${CHECK:-unset}" "${#NORM_PATHS[@]}"
    printf '%s\n' "${report_lines[@]}"
    exit 1
}

main "$@"
