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
readonly RUN_ID_RE='^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'

usage() {
    cat <<EOF
Usage: $PROGNAME (--pr N | --run-id ID | --scratch-label LABEL | --procedure-set NAME --scope CSV [--flags CSV] --repo SLUG --base BRANCH) [--repo-root DIR]

Prints a private run directory selected by PR, explicit/canonical run ID, or
creates a unique mode-0600 scratch file under DIR/.agent/cache.

Primary location: DIR/.agent/evidence/pr-N or DIR/.agent/evidence/run-ID.
DIR defaults to the Git root. Unwritable state falls back under \${TMPDIR:-/tmp}.
Existing targets must be owned, real mode-0700 directories.
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
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
            --pr) require_value "$1" "${2:-}"; PR=$2; shift 2 ;;
            --pr=*) PR=${1#*=}; shift ;;
            --run-id) require_value "$1" "${2:-}"; RUN_ID=$2; shift 2 ;;
            --run-id=*) RUN_ID=${1#*=}; shift ;;
            --scratch-label) require_value "$1" "${2:-}"; SCRATCH_LABEL=$2; shift 2 ;;
            --scratch-label=*) SCRATCH_LABEL=${1#*=}; shift ;;
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
    local agent_dir=$REPO_ROOT/.agent cache file
    [[ ! -L $agent_dir ]] || die "environment state directory must not be a symlink: $agent_dir"
    if [[ -e $agent_dir ]]; then [[ -d $agent_dir ]] || die "environment state directory must be a directory: $agent_dir"
    else mkdir -m 700 -- "$agent_dir" 2>/dev/null ||
        [[ -d $agent_dir && ! -L $agent_dir ]] || die "could not create environment state directory: $agent_dir"; fi
    cache=$agent_dir/cache
    ensure_private_root "$cache" || die "could not create scratch cache: $cache"
    file=$(mktemp "$cache/$SCRATCH_LABEL.XXXXXXXXXX") || die "could not create scratch file in: $cache"
    chmod 600 -- "$file" || die "could not secure scratch file: $file"
    [[ -f $file && ! -L $file && -O $file ]] || die "scratch file is not an owned regular file: $file"
    printf '%s\n' "$file"
}

validate_selector() {
    local canonical_count=0 ledger="$SCRIPT_DIR/../../.shared/scripts/session-ledger.sh"
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

fallback_target() {
    local repo_slug fallback_root
    repo_slug=$(printf '%s' "$REPO_ROOT" | sha256sum | cut -c1-16) ||
        die 'could not derive the repository fallback identity'
    fallback_root="${TMPDIR:-/tmp}/agent-kit-review-remote-pr.$(id -u)"
    ensure_private_root "$fallback_root" ||
        die "could not create the fallback run-directory root: $fallback_root; evidence unavailable"
    TARGET=$fallback_root/$repo_slug/$SELECTOR
}

parse_args "$@"
if [[ -n $SCRATCH_LABEL ]]; then
    [[ $SCRATCH_LABEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die_usage 'scratch label must use letters, numbers, ., _, or -'
    [[ -z $PR$RUN_ID$PROCEDURE_SET$SCOPE$FLAGS$REPO$BASE ]] || die_usage '--scratch-label is mutually exclusive with run selectors'
    resolve_repo_root
    create_scratch
    exit 0
fi
validate_selector
resolve_repo_root

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
