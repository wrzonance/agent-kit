#!/usr/bin/env bash
# Create and bootstrap one issue worktree from the repository's declared base.
set -euo pipefail

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
RESUME=no

usage() {
    cat <<'EOF'
Usage: create-issue-worktree.sh --repo-root PATH --issue N --base BRANCH [--chain-base SHA]
       create-issue-worktree.sh --repo-root PATH --issue N --base BRANCH --resume

Create feat/issue-N below the configured AGENT_WORKTREE_ROOT (default
.worktrees), starting at origin/BRANCH or the supplied full chain-base SHA.
The branch is pushed upstream, preflighted, and receives the declared setup
command through agent-run.sh when AGENT_CMD_SETUP is present.

--resume reuses the worktree already registered for feat/issue-N, or recreates
it from the existing local branch or origin/feat/issue-N when no worktree
currently owns that branch, ensures the branch has an origin upstream, and
re-runs exclude/config-propagation/preflight/declared-setup against it,
refreshing its .agent/env-contract.txt in place. It fails only when the path
is occupied by something other than that worktree, or when neither a
worktree nor a branch exists to resume.
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
            --resume)
                RESUME=yes
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

worktree_setup_state_counts() {
    local worktree=$1 status_line status_code untracked=0 modified=0
    if [[ -d $worktree && ! -L $worktree ]] &&
        git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        while IFS= read -r status_line; do
            [[ -n $status_line ]] || continue
            status_code=${status_line:0:2}
            if [[ $status_code == '??' ]]; then
                untracked=$((untracked + 1))
            elif [[ $status_code != '!!' ]]; then
                modified=$((modified + 1))
            fi
        done < <(git -C "$worktree" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)
    fi
    printf '%d %d\n' "$untracked" "$modified"
}

# worktree_branch_at_path ROOT WORKTREE -- prints the ref registered for
# WORKTREE in ROOT's own `git worktree list`, or "detached" for a registered
# worktree with no branch, and fails when WORKTREE is not a path any
# worktree of ROOT actually owns. A worktree is identified by ROOT's
# metadata, never by probing WORKTREE with `git rev-parse
# --is-inside-work-tree`: that probe walks up into the *parent* repository
# and reports success for a plain, unregistered directory nested under it
# (issue #588 finding 1).
worktree_branch_at_path() {
    local root=$1 worktree=$2
    local want_path entry_path='' entry_branch='' resolved line
    want_path=$(readlink -f -- "$worktree" 2>/dev/null) || return 1
    [[ -n $want_path ]] || return 1
    while IFS= read -r line; do
        if [[ $line == worktree\ * ]]; then
            entry_path=${line#worktree }
            entry_branch=''
        elif [[ $line == branch\ * ]]; then
            entry_branch=${line#branch }
        elif [[ -z $line ]]; then
            if [[ -n $entry_path ]]; then
                resolved=$(readlink -f -- "$entry_path" 2>/dev/null) || resolved=''
                if [[ -n $resolved && $resolved == "$want_path" ]]; then
                    printf '%s\n' "${entry_branch:-detached}"
                    return 0
                fi
            fi
            entry_path=''
            entry_branch=''
        fi
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null; printf '\n')
    return 1
}

# worktree_registered_for_branch ROOT WORKTREE BRANCH -- true only when ROOT's
# worktree metadata has an entry at WORKTREE checked out on refs/heads/BRANCH.
worktree_registered_for_branch() {
    local root=$1 worktree=$2 branch=$3 found_branch
    found_branch=$(worktree_branch_at_path "$root" "$worktree") || return 1
    [[ $found_branch == "refs/heads/$branch" ]]
}

main() {
    parse_args "$@"
    validate_args

    local root config shared preflight worktree_root branch worktree start setup_declared
    local root_harness root_contract
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
    local resumable=no untracked=0 modified=0 state_counts worktree_registered=no
    if worktree_registered_for_branch "$root" "$worktree" "$branch"; then
        worktree_registered=yes
    fi
    if [[ -e $worktree || -L $worktree ]] ||
        git -C "$root" show-ref --verify --quiet "refs/heads/$branch" ||
        git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        resumable=yes
        if [[ $worktree_registered == yes ]]; then
            state_counts=$(worktree_setup_state_counts "$worktree") || state_counts='0 0'
            read -r untracked modified <<<"$state_counts"
        fi
    fi
    printf 'resumable: %s untracked=%d modified=%d\n' "$resumable" "$untracked" "$modified"

    if [[ $RESUME == yes ]]; then
        if [[ $worktree_registered != yes ]]; then
            if [[ -e $worktree || -L $worktree ]]; then
                local existing_branch=''
                existing_branch=$(worktree_branch_at_path "$root" "$worktree" 2>/dev/null) || existing_branch=''
                if [[ -n $existing_branch ]]; then
                    worktree_setup_fail "cannot resume feat/issue-$ISSUE: $worktree is a registered worktree on $existing_branch, not refs/heads/$branch"
                else
                    worktree_setup_fail "cannot resume feat/issue-$ISSUE: $worktree exists but is not a registered git worktree"
                fi
                exit 1
            fi
            local recreate_from=''
            if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
                recreate_from=local
            elif git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
                recreate_from=remote
            else
                worktree_setup_fail "no worktree is registered for feat/issue-$ISSUE to resume, and no local or remote branch exists to recreate it from: $worktree"
                exit 1
            fi
            if [[ $recreate_from == local ]]; then
                git -C "$root" worktree add "$worktree" "$branch" || {
                    worktree_setup_fail "could not recreate worktree $worktree from local branch $branch"
                    exit 1
                }
            else
                git -C "$root" worktree add "$worktree" -b "$branch" "origin/$branch" || {
                    worktree_setup_fail "could not recreate worktree $worktree from origin/$branch"
                    exit 1
                }
            fi
            for private_dir in prompts evidence logs pr-body; do
                (umask 077; mkdir -p -- "$worktree/.agent/$private_dir") || {
                    worktree_setup_fail "could not create private worktree state directory: $worktree/.agent/$private_dir"
                    exit 1
                }
            done
        fi
        # A prior create that got as far as `git worktree add` but died before
        # (or during) `git push --set-upstream` -- or a worktree just
        # recreated above from a local-only branch -- must not report success
        # without a pushed, tracked origin branch (issue #588 finding 2).
        if git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            local upstream=''
            upstream=$(git -C "$worktree" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || upstream=''
            if [[ $upstream != "origin/$branch" ]]; then
                git -C "$worktree" branch --set-upstream-to="origin/$branch" "$branch" || {
                    worktree_setup_fail "could not set upstream origin/$branch during resume"
                    exit 1
                }
            fi
        else
            git -C "$worktree" push --set-upstream origin "$branch" || {
                worktree_setup_fail "could not push origin/$branch during resume"
                exit 1
            }
        fi
    else
        if git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            worktree_setup_fail "resumable prior work exists for this issue (origin/$branch); resume it with --resume, never create a duplicate branch"
            exit 1
        fi
        if [[ -e $worktree || -L $worktree ]]; then
            worktree_setup_fail "resumable prior work exists for this issue (worktree at $worktree); resume it with --resume, never create a duplicate branch"
            exit 1
        fi
        git -C "$root" worktree add "$worktree" -b "$branch" "$start" || {
            worktree_setup_fail "could not create worktree $worktree"
            exit 1
        }
        for private_dir in prompts evidence logs pr-body; do
            # Scope the restrictive umask to private state creation; checkout and
            # setup commands must retain the caller's ambient permissions.
            (umask 077; mkdir -p -- "$worktree/.agent/$private_dir") || {
                worktree_setup_fail "could not create private worktree state directory: $worktree/.agent/$private_dir"
                exit 1
            }
        done
        git -C "$worktree" push --set-upstream origin "$branch" || {
            worktree_setup_fail "could not create remote branch origin/$branch"
            exit 1
        }
    fi
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
    # The root's contract is keyed by harness (issue #551): SessionStart
    # writes .agent/env-contract.<harness>.txt there, never the bare name, so
    # inheriting from the bare name would silently degrade to a fresh probe
    # on every dispatch. Prefer THIS process's own harness's file when it
    # exists; fall back to the legacy bare name -- still a valid inherit
    # source for a root whose contract predates this key, or came from a
    # caller that still writes the bare name.
    root_harness=$("$shared/harness-id.sh" --name 2> /dev/null) || root_harness=''
    root_contract="$root/.agent/env-contract.txt"
    if [[ -n $root_harness && -f "$root/.agent/env-contract.$root_harness.txt" &&
        ! -L "$root/.agent/env-contract.$root_harness.txt" ]]; then
        root_contract="$root/.agent/env-contract.$root_harness.txt"
    fi
    "$preflight" --worktree "$worktree" --inherit-session "$root_contract" || {
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
