#!/usr/bin/env bash
# run-dir.sh — the durable PR/run -> RUN_DIR mapping.
#
# review-remote-pr's Step 0c used to mint a randomly named directory under
# ${TMPDIR:-/tmp} every run. That path lived only in the current shell and the
# harness scratchpad; a `/exit` (or any resumed session) lost the pointer even
# though the directory itself was still on disk, orphaning digests, consent
# records, and receipts (issue #405).
#
# This helper owns the mapping instead: the same PR always resolves to the
# same private directory, so a resumed session finds its prior evidence
# without re-deriving it. Primary location is the excluded, per-repo
# `.agent/evidence/pr-<N>` (see .gitignore's `**/.agent/*`); ${TMPDIR:-/tmp}
# is used only as a genuine fallback, on hosts where `.agent/` cannot be
# written -- never as a silent default.
#
# A run that never produces a pull request (e.g. parallel-issues' bulk triage,
# before any PR exists) has no PR number to address by, so it has no way to
# reach this guarantee -- and previously improvised a repository-relative
# path instead, which `git status` then showed as untracked additions mixed
# into the operator's own working tree (issue #447). `--run-id ID` is the
# second addressing mode this adds: ID is the invocation-level RUN_ID a skill
# already establishes once per run (see .shared/scripts/session-ledger.sh),
# reusing that existing stable identifier rather than inventing a second
# scheme. It resolves to `.agent/evidence/run-<ID>`, sharing every mechanic
# --pr uses (mode 0700, hostile-input refusal, the ${TMPDIR:-/tmp} fallback);
# the `pr-`/`run-` prefixes keep the two namespaces disjoint even when the
# literal PR number and run id happen to match.
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/private-dir.sh"

PR=''
RUN_ID=''
REPO_ROOT=''
SELECTOR=''
readonly RUN_ID_RE='^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'

usage() {
    cat <<EOF
Usage: $PROGNAME (--pr N | --run-id ID) [--repo-root DIR]

Prints the private, mode-0700 run directory for pull request N, or for a
PR-less run addressed by the stable ID (the invocation-level RUN_ID a skill
already establishes) it was invoked with, creating it if needed. The same
selector always resolves to the same directory, so a resumed session finds
its prior evidence instead of orphaning it. Exactly one of --pr / --run-id is
required; they are mutually exclusive.

Primary location: DIR/.agent/evidence/pr-N or DIR/.agent/evidence/run-ID (DIR
defaults to \`git rev-parse --show-toplevel\`; pass --repo-root to override,
mainly for tests). Falls back to a private directory under \${TMPDIR:-/tmp},
keyed by both the repository and the selector, only when .agent/ genuinely
cannot be created or secured there.

A pre-existing target that is a symlink, not a directory, not owned by this
user, or not mode 0700 is refused rather than reused or silently widened.
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
            --repo-root) require_value "$1" "${2:-}"; REPO_ROOT=$2; shift 2 ;;
            --repo-root=*) REPO_ROOT=${1#*=}; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
}

# validate_selector -- exactly one of --pr / --run-id must be set; whichever
# it is gets validated and turned into SELECTOR, the path component shared by
# try_primary and fallback_target. Both selectors are validated (and refused)
# before they ever become part of a path -- a malformed value must never
# reach mkdir/stat as a traversal or option-injection vector.
validate_selector() {
    if [[ -n $PR && -n $RUN_ID ]]; then
        die_usage '--pr and --run-id are mutually exclusive'
    fi
    if [[ -n $PR ]]; then
        # Leading zeros rejected rather than normalized (a path component
        # should read as the number it is).
        [[ $PR =~ ^[1-9][0-9]*$ ]] || die_usage "--pr must be a positive integer without leading zeros: $PR"
        SELECTOR="pr-$PR"
        return
    fi
    if [[ -n $RUN_ID ]]; then
        # Same charset session-ledger.sh's --run-id already accepts, so the
        # invocation-level RUN_ID a skill establishes once (parallel-issues,
        # review-remote-pr) is always a valid path component here too -- no
        # second identifier scheme to invent or keep in sync.
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

# ensure_private_root DIR -- DIR must already be (or safely become) an owned,
# non-symlink, mode-0700 directory. Unlike private_dir_ensure (private-dir.sh),
# this never requires an ALREADY-private ancestor: it is the function that
# establishes the very first private boundary under a shared, non-private
# parent (.agent/ itself stays mode 0755; only .agent/evidence/ and below are
# private). An existing DIR is validated and never widened or reused past a
# mismatch; a missing DIR is created at exactly 0700 (mkdir -m bypasses
# umask, so there is no window where it is briefly more permissive). Returns
# 1 only for a plain creation failure (the fallback-eligible case); every
# other problem is a hostile/corrupted pre-existing path and dies outright.
#
# The `-L` check runs UNCONDITIONALLY, before any `-e`-gated branch -- never
# `if [[ -e $dir ]]; then ... -L check ...`. `-e` follows a symlink to its
# target, so for a DANGLING symlink (target does not exist) `-e` is false and
# an `-e`-gated `-L` check is skipped entirely; `mkdir` then fails with EEXIST
# against the link itself, `return 1` reads as "not writable", and the run
# silently falls back to /tmp instead of refusing -- the exact fail-open this
# function exists to prevent (issue #405 review finding). `-L` alone is true
# for a symlink whether or not its target exists, so checking it first and
# unconditionally closes that gap; this mirrors private_dir_ensure's own
# loop in private-dir.sh, which checks `-L` before ever branching on `-e`.
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
    mkdir -m 700 -- "$dir" 2>/dev/null || return 1
    # Re-verify against a creation race (something replaced the path between
    # the -e check above and mkdir).
    [[ ! -L $dir ]] || die "must be an existing directory, not a symlink: $dir"
    [[ -d $dir ]] || die "must be an existing directory, not a symlink: $dir"
    [[ -O $dir ]] || die "is not owned by this user: $dir"
}

# try_primary -- sets TARGET and returns 0 on success; returns 1 only when
# .agent/ or .agent/evidence genuinely cannot be created there (permission
# denied), which is the one condition allowed to fall back. Any hostile
# pre-existing state (symlink, wrong type, wrong owner, wrong mode) dies
# outright via ensure_private_root/die -- it never falls through to the
# fallback path. Deliberately called directly, never as `$(try_primary)`: a
# command substitution runs in a subshell, and `die`'s `exit` inside one would
# only end the subshell, silently falling through to the fallback path
# instead of stopping the script.
TARGET=''
try_primary() {
    local agent_dir=$REPO_ROOT/.agent evidence_dir
    # -L checked unconditionally, before the -e branch -- see ensure_private_root's
    # comment for why an -e-gated -L check misses a dangling symlink.
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

# fallback_target -- sets TARGET to a deterministic (never randomly named)
# path under ${TMPDIR:-/tmp}, namespaced by both the effective user and the
# repository, so two checkouts (or two users on a shared host) never collide
# on the same selector. A genuine environment failure here has no further
# fallback and dies outright (also called directly, for the same subshell
# reason as try_primary).
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
