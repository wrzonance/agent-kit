#!/usr/bin/env bash
# Create and bootstrap one issue worktree from the repository's declared base.
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/worktree-setup.sh"

WORKTREE_SETUP_PROGNAME=$PROGNAME
REPO_ROOT=''
ISSUE=''
BASE=''
CHAIN_BASE=''

usage() {
    cat <<'EOF'
Usage: create-issue-worktree.sh --repo-root PATH --issue N --base BRANCH [--chain-base SHA]

Create feat/issue-N below the configured AGENT_WORKTREE_ROOT (default
.worktrees), starting at origin/BRANCH or the supplied full chain-base SHA.
The branch is pushed upstream, preflighted, and receives the declared setup
command through agent-run.sh when AGENT_CMD_SETUP is present.
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            --repo-root)
                worktree_setup_require_value "$1" "${2:-}" || exit 1
                [[ -z $REPO_ROOT ]] || { worktree_setup_fail '--repo-root given more than once'; exit 1; }
                REPO_ROOT=$2
                shift 2
                ;;
            --repo-root=*)
                [[ -z $REPO_ROOT ]] || { worktree_setup_fail '--repo-root given more than once'; exit 1; }
                REPO_ROOT=${1#*=}
                shift
                ;;
            --issue)
                worktree_setup_require_value "$1" "${2:-}" || exit 1
                [[ -z $ISSUE ]] || { worktree_setup_fail '--issue given more than once'; exit 1; }
                ISSUE=$2
                shift 2
                ;;
            --issue=*)
                [[ -z $ISSUE ]] || { worktree_setup_fail '--issue given more than once'; exit 1; }
                ISSUE=${1#*=}
                shift
                ;;
            --base)
                worktree_setup_require_value "$1" "${2:-}" || exit 1
                [[ -z $BASE ]] || { worktree_setup_fail '--base given more than once'; exit 1; }
                BASE=$2
                shift 2
                ;;
            --base=*)
                [[ -z $BASE ]] || { worktree_setup_fail '--base given more than once'; exit 1; }
                BASE=${1#*=}
                shift
                ;;
            --chain-base)
                worktree_setup_require_value "$1" "${2:-}" || exit 1
                [[ -z $CHAIN_BASE ]] || { worktree_setup_fail '--chain-base given more than once'; exit 1; }
                CHAIN_BASE=$2
                shift 2
                ;;
            --chain-base=*)
                [[ -z $CHAIN_BASE ]] || { worktree_setup_fail '--chain-base given more than once'; exit 1; }
                CHAIN_BASE=${1#*=}
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                (($# == 0)) || { worktree_setup_fail "unexpected argument: $1"; exit 1; }
                ;;
            *)
                worktree_setup_fail "unexpected argument: $1"
                exit 1
                ;;
        esac
    done
}

validate_args() {
    [[ -n $REPO_ROOT ]] || { worktree_setup_fail '--repo-root is required'; exit 1; }
    [[ $ISSUE =~ ^[1-9][0-9]*$ ]] || { worktree_setup_fail '--issue must be a positive integer'; exit 1; }
    worktree_setup_validate_ref "$BASE" '--base' || exit 1
    if [[ -n $CHAIN_BASE ]]; then
        worktree_setup_validate_full_sha "$CHAIN_BASE" '--chain-base' || exit 1
    fi
}

main() {
    parse_args "$@"
    validate_args

    local root config shared preflight worktree_root branch worktree start setup_declared
    root=$(worktree_setup_resolve_repo_root "$REPO_ROOT") || exit 1
    config="$SCRIPT_DIR/../../.shared/scripts/repo-config.sh"
    shared="$SCRIPT_DIR/../../.shared/scripts"
    preflight="$shared/agent-preflight.sh"
    worktree_root=$(worktree_setup_worktree_root "$config" "$root") || exit 1
    worktree_setup_validate_worktree_root "$worktree_root" || exit 1
    branch="feat/issue-$ISSUE"
    worktree="$root/$worktree_root/$branch"
    start=${CHAIN_BASE:-origin/$BASE}

    worktree_setup_ensure_exclude "$root" "$worktree_root/" || exit 1
    git -C "$root" fetch origin || {
        worktree_setup_fail 'could not fetch origin'
        exit 1
    }
    if git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        worktree_setup_fail "remote branch origin/$branch already exists; choose a different issue branch"
        exit 1
    fi
    if [[ -e $worktree || -L $worktree ]]; then
        worktree_setup_fail "worktree path exists: $worktree"
        exit 1
    fi
    git -C "$root" worktree add "$worktree" -b "$branch" "$start" || {
        worktree_setup_fail "could not create worktree $worktree"
        exit 1
    }
    for private_dir in prompts evidence logs pr-body; do
        # The process-wide umask 077 makes every newly-created component mode
        # 0700, including the intermediate .agent directory.
        mkdir -p -- "$worktree/.agent/$private_dir" || {
            worktree_setup_fail "could not create private worktree state directory: $worktree/.agent/$private_dir"
            exit 1
        }
    done
    git -C "$worktree" push --set-upstream origin "$branch" || {
        worktree_setup_fail "could not create remote branch origin/$branch"
        exit 1
    }
    worktree_setup_ensure_exclude "$root" '.agent/*' || exit 1
    worktree_setup_propagate_config "$root" "$worktree" || exit 1
    # sandbox=, caches=, and tls= are session-scoped facts (which process is
    # running the commands, what it can reach) -- not per-worktree ones. A
    # per-worktree preflight that RE-MEASURES them can run in a differently-
    # privileged process than the root's own preflight did and produce a
    # truthful-for-itself but contradictory answer for the same session
    # (issue #332). Carry the root contract's copies forward verbatim instead
    # of calling worktree_setup_preflight's plain probe; agent-preflight.sh
    # itself falls back to a fresh probe for any line --inherit-session can't
    # find, so a root that hasn't preflighted yet degrades to the prior
    # behavior rather than failing.
    [[ -x $preflight ]] || {
        worktree_setup_fail "agent-preflight.sh is missing or not executable: $preflight"
        exit 1
    }
    "$preflight" --worktree "$worktree" --inherit-session "$root/.agent/env-contract.txt" || {
        worktree_setup_fail "preflight failed in $worktree"
        exit 1
    }
    setup_declared=$("$config" --repo-root "$worktree" --get AGENT_CMD_SETUP 2>/dev/null) || setup_declared=''
    worktree_setup_declared_setup "$config" "$shared/agent-run.sh" "$worktree" || {
        worktree_setup_fail "setup failed in $worktree"
        exit 1
    }
    printf 'worktree=%s branch=%s setup=%s\n' "$worktree" "$branch" \
        "$(if [[ -n $setup_declared ]]; then printf declared; else printf none; fi)"
}

main "$@"
