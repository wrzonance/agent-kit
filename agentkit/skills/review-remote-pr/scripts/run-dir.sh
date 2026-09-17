#!/usr/bin/env bash
# run-dir.sh -- durable PR/run -> private RUN_DIR mapping.
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../.shared/scripts/lib/private-dir.sh"

PR=''
RUN_ID=''
REPO_ROOT=''
SELECTOR=''
PROCEDURE_SET=''
SCOPE=''
FLAGS=''
REPO=''
BASE=''
SCRATCH_LABEL=''
SCRATCH_NEAR=''
LIST_RUN_ROOTS=0
readonly RUN_ID_RE='^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'

usage() {
    cat <<EOF
Usage: $PROGNAME (--pr N | --run-id ID | --scratch-label LABEL [--scratch-near PATH] | --procedure-set NAME --scope CSV [--flags CSV] --repo SLUG --base BRANCH) [--repo-root DIR]
       $PROGNAME --list-run-roots [--repo-root DIR]

Prints a private run directory or creates unique mode-0600 scratch. Run state
uses DIR/.agent/evidence; DIR defaults to the Git root with a private fallback.
--list-run-roots prints existing trusted primary/fallback roots; exit 11 means none.
EOF
}

die() { printf '%s: %s\n' "$PROGNAME" "$1" >&2; exit 1; }

die_usage() { printf '%s: %s\n' "$PROGNAME" "$1" >&2; usage >&2; exit 2; }

require_value() {
    [[ -n ${2:-} ]] || die_usage "option $1 requires a value"
}

parse_args() {
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
            --pr) require_value "$1" "${2:-}"; PR=$2; shift 2 ;;
            --pr=*) PR=${1#*=}; shift ;;
            --run-id) require_value "$1" "${2:-}"; RUN_ID=$2; shift 2 ;;
            --run-id=*) RUN_ID=${1#*=}; shift ;;
            --list-run-roots) LIST_RUN_ROOTS=1; shift ;;
            --scratch-label) require_value "$1" "${2:-}"; SCRATCH_LABEL=$2; shift 2 ;;
            --scratch-label=*) SCRATCH_LABEL=${1#*=}; shift ;;
            --scratch-near) require_value "$1" "${2:-}"; SCRATCH_NEAR=$2; shift 2 ;;
            --scratch-near=*) SCRATCH_NEAR=${1#*=}; shift ;;
            --procedure-set|--scope|--flags|--repo|--base)
                require_value "$1" "${2:-}"
                case $1 in
                    --procedure-set) PROCEDURE_SET=$2 ;; --scope) SCOPE=$2 ;;
                    --flags) FLAGS=$2 ;; --repo) REPO=$2 ;; --base) BASE=$2 ;;
                esac
                shift 2
                ;;
            --repo-root) require_value "$1" "${2:-}"; REPO_ROOT=$2; shift 2 ;;
            --repo-root=*) REPO_ROOT=${1#*=}; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
}

create_scratch() {
    local agent_dir cache file mode base
    if [[ -n $SCRATCH_NEAR ]]; then
        [[ $SCRATCH_NEAR == /* ]] || die_usage '--scratch-near must be absolute'
        base=${SCRATCH_NEAR##*/}; cache=${SCRATCH_NEAR%/*}; [[ -n $base && -d $cache ]] || die_usage '--scratch-near parent must exist'
        cache=$(cd -- "$cache" && pwd -P) || die 'could not resolve --scratch-near parent'
        file=$(mktemp "$cache/.$base.$SCRATCH_LABEL.XXXXXXXXXX") || die "could not create scratch file in: $cache"
    else
        agent_dir=$REPO_ROOT/.agent
        if [[ ! -e $agent_dir ]]; then
            mkdir -m 700 -- "$agent_dir" 2>/dev/null || [[ -d $agent_dir && ! -L $agent_dir ]] || die "could not create environment state directory: $agent_dir"
        fi
        [[ -d $agent_dir && ! -L $agent_dir && -O $agent_dir ]] || die "environment state directory must be an owned directory: $agent_dir"
        mode=$(stat -c %a -- "$agent_dir") || die "could not inspect: $agent_dir"
        (( (8#$mode & 0022) == 0 )) || die "environment state directory must not be group- or world-writable: $agent_dir"
        cache=$agent_dir/cache; ensure_private_root "$cache" || die "could not create scratch cache: $cache"
        file=$(mktemp "$cache/$SCRATCH_LABEL.XXXXXXXXXX") || die "could not create scratch file in: $cache"
    fi
    chmod 600 -- "$file" || die "could not secure scratch file: $file"
    [[ -f $file && ! -L $file && -O $file ]] || die "scratch file is not an owned regular file: $file"
    printf '%s\n' "$file"
}

validate_selector() {
    local canonical_count=0 ledger="$SCRIPT_DIR/../../.shared/scripts/session-ledger.sh"
    if ((LIST_RUN_ROOTS)); then
        [[ -z $PR$RUN_ID$PROCEDURE_SET$SCOPE$FLAGS$REPO$BASE ]] ||
            die_usage '--list-run-roots is mutually exclusive with run selectors'
        return
    fi
    [[ -z $PROCEDURE_SET ]] || canonical_count=$((canonical_count + 1))
    [[ -z $SCOPE ]] || canonical_count=$((canonical_count + 1))
    [[ -z $REPO ]] || canonical_count=$((canonical_count + 1))
    [[ -z $BASE ]] || canonical_count=$((canonical_count + 1))
    [[ -z $FLAGS ]] || canonical_count=$((canonical_count + 1))
    if ((canonical_count > 0)); then
        [[ -z $PR && -z $RUN_ID ]] || die_usage 'canonical identity options cannot be combined with --pr or --run-id'
        ((canonical_count >= 4)) && [[ -n $PROCEDURE_SET && -n $SCOPE && -n $REPO && -n $BASE ]] ||
            die_usage 'canonical identity requires --procedure-set, --scope, --repo, and --base'
        local -a args=(run-id --procedure-set "$PROCEDURE_SET" --scope "$SCOPE" --repo "$REPO" --base "$BASE")
        [[ -z $FLAGS ]] || args+=(--flags "$FLAGS")
        RUN_ID=$("$ledger" "${args[@]}") || exit $?
    fi
    if [[ -n $PR && -n $RUN_ID ]]; then
        die_usage '--pr and --run-id are mutually exclusive'
    fi
    if [[ -n $PR ]]; then
        [[ $PR =~ ^[1-9][0-9]*$ ]] || die_usage "--pr must be a positive integer without leading zeros: $PR"
        SELECTOR="pr-$PR"
        return
    fi
    if [[ -n $RUN_ID ]]; then
        [[ $RUN_ID =~ $RUN_ID_RE ]] || die_usage \
            "--run-id must use letters, numbers, ., _, :, or - (max 128 characters, starting with a letter or number): $RUN_ID"
        SELECTOR="run-$RUN_ID"
        return
    fi
    die_usage 'either --pr or --run-id is required'
}

resolve_repo_root() {
    if [[ -n $REPO_ROOT ]]; then
        [[ -d $REPO_ROOT ]] || die_usage "--repo-root is not a directory: $REPO_ROOT"
        REPO_ROOT=$(cd -- "$REPO_ROOT" && pwd -P) || die "could not resolve --repo-root: $REPO_ROOT"
        return
    fi
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) ||
        die 'could not resolve the repository root (pass --repo-root outside a Git worktree)'
}

ensure_private_root() {
    local dir=$1 mode
    [[ ! -L $dir ]] || die "must be an existing directory, not a symlink: $dir"
    if [[ -e $dir ]]; then
        [[ -d $dir ]] || die "must be an existing directory, not a symlink: $dir"
        [[ -O $dir ]] || die "is not owned by this user: $dir"
        mode=$(stat -c %a -- "$dir") || die "could not inspect: $dir"
        [[ $mode == 700 ]] || die "must have mode 0700: $dir"
        return 0
    fi
    mkdir -m 700 -- "$dir" 2>/dev/null || [[ -d $dir && ! -L $dir ]] || return 1
    [[ ! -L $dir ]] || die "must be an existing directory, not a symlink: $dir"
    [[ -d $dir ]] || die "must be an existing directory, not a symlink: $dir"
    [[ -O $dir ]] || die "is not owned by this user: $dir"
    mode=$(stat -c %a -- "$dir") || die "could not inspect: $dir"
    [[ $mode == 700 ]] || die "must have mode 0700: $dir"
}

TARGET=''
try_primary() {
    local agent_dir=$REPO_ROOT/.agent evidence_dir
    [[ ! -L $agent_dir ]] || die "environment state directory must not be a symlink: $agent_dir"
    if [[ -e $agent_dir ]]; then
        [[ -d $agent_dir ]] || die "environment state directory must be a directory: $agent_dir"
    else
        mkdir -p -- "$agent_dir" 2>/dev/null || return 1
    fi
    evidence_dir=$agent_dir/evidence
    ensure_private_root "$evidence_dir" || return 1
    TARGET=$evidence_dir/$SELECTOR
}

FALLBACK_ROOT=''
FALLBACK_REPO_ROOT=''
fallback_paths() {
    local repo_slug
    repo_slug=$(printf '%s' "$REPO_ROOT" | sha256sum | cut -c1-16) ||
        die 'could not derive the repository fallback identity'
    FALLBACK_ROOT="${TMPDIR:-/tmp}/agent-kit-review-remote-pr.$(id -u)"
    FALLBACK_REPO_ROOT=$FALLBACK_ROOT/$repo_slug
}

fallback_target() {
    fallback_paths
    ensure_private_root "$FALLBACK_ROOT" ||
        die "could not create the fallback run-directory root: $FALLBACK_ROOT; evidence unavailable"
    TARGET=$FALLBACK_REPO_ROOT/$SELECTOR
}

existing_fallback_target() {
    local fallback_selector primary_agent primary_evidence primary_selector
    fallback_paths
    print_existing_private_root "$FALLBACK_ROOT" 'fallback root' 0
    [[ -e $FALLBACK_ROOT ]] || return 1
    print_existing_private_root "$FALLBACK_REPO_ROOT" 'fallback repository root' 0
    [[ -e $FALLBACK_REPO_ROOT ]] || return 1
    fallback_selector=$FALLBACK_REPO_ROOT/$SELECTOR
    print_existing_private_root "$fallback_selector" 'fallback run directory' 0
    [[ -e $fallback_selector ]] || return 1

    primary_agent=$REPO_ROOT/.agent
    [[ ! -L $primary_agent ]] || die "environment state directory must not be a symlink: $primary_agent"
    if [[ -e $primary_agent ]]; then
        [[ -d $primary_agent ]] || die "environment state directory must be a directory: $primary_agent"
        primary_evidence=$primary_agent/evidence
        print_existing_private_root "$primary_evidence" 'evidence directory' 0
        if [[ -e $primary_evidence ]]; then
            primary_selector=$primary_evidence/$SELECTOR
            print_existing_private_root "$primary_selector" 'primary run directory' 0
            [[ ! -e $primary_selector ]] ||
                die "run selector exists in both primary and fallback backends: $SELECTOR"
        fi
    fi
    TARGET=$fallback_selector
}

LISTED_ROOTS=0
print_existing_private_root() {
    local dir=$1 label=$2 emit=${3:-1} mode
    [[ ! -L $dir ]] || die "$label must not be a symlink: $dir"
    [[ -e $dir ]] || return 0
    [[ -d $dir && -O $dir ]] || die "$label must be an owned directory: $dir"
    mode=$(stat -c %a -- "$dir") || die "could not inspect $label: $dir"
    [[ $mode == 700 ]] || die "$label must have mode 0700: $dir"
    if ((emit)); then printf '%s\n' "$dir"; LISTED_ROOTS=$((LISTED_ROOTS + 1)); fi
}

list_run_roots() {
    local agent_dir=$REPO_ROOT/.agent evidence_dir
    [[ ! -L $agent_dir ]] || die "environment state directory must not be a symlink: $agent_dir"
    if [[ -e $agent_dir ]]; then
        [[ -d $agent_dir ]] || die "environment state directory must be a directory: $agent_dir"
        evidence_dir=$agent_dir/evidence
        print_existing_private_root "$evidence_dir" 'evidence directory'
    fi
    fallback_paths
    print_existing_private_root "$FALLBACK_ROOT" 'fallback root' 0
    [[ ! -e $FALLBACK_ROOT ]] || print_existing_private_root "$FALLBACK_REPO_ROOT" 'fallback repository root'
    ((LISTED_ROOTS)) || exit 11
}

parse_args "$@"
if [[ -n $SCRATCH_LABEL ]]; then
    [[ $SCRATCH_LABEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die_usage 'scratch label must use letters, numbers, ., _, or -'
    [[ -z $PR$RUN_ID$PROCEDURE_SET$SCOPE$FLAGS$REPO$BASE && $LIST_RUN_ROOTS == 0 ]] || die_usage '--scratch-label is mutually exclusive with run selectors'
    if [[ -n $SCRATCH_NEAR ]]; then [[ -z $REPO_ROOT ]] || die_usage '--scratch-near cannot be combined with --repo-root'; else resolve_repo_root; fi
    create_scratch
    exit 0
fi
[[ -z $SCRATCH_NEAR ]] || die_usage '--scratch-near requires --scratch-label'
validate_selector
resolve_repo_root

if ((LIST_RUN_ROOTS)); then
    list_run_roots
    exit 0
fi

if existing_fallback_target; then
    private_dir_ensure "$TARGET" 'run directory'; printf '%s\n' "$TARGET"
    exit 0
fi

if try_primary; then
    private_dir_ensure "$TARGET" 'run directory'
    printf '%s\n' "$TARGET"
    exit 0
fi

printf '%s: .agent/ is not writable under %s; using a private %s fallback\n' \
    "$PROGNAME" "$REPO_ROOT" "${TMPDIR:-/tmp}" >&2
fallback_target
private_dir_ensure "$TARGET" 'run directory'
printf '%s\n' "$TARGET"
