#!/usr/bin/env bash
# Enter (or create) the worktree for a pull request and bootstrap it.
set -euo pipefail

readonly PROGNAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/worktree-setup.sh"

WORKTREE_SETUP_PROGNAME=$PROGNAME
PR=''
REPO=''

usage() {
    cat <<'EOF'
Usage: pr-worktree.sh --pr N --repo OWNER/REPO

Reuse the worktree carrying a pull request's head branch, or create one below
the configured AGENT_WORKTREE_ROOT (default .worktrees). Fork pull requests use
gh pr checkout from a detached worktree. The worktree is preflighted and gets
the declared setup command through agent-run.sh when AGENT_CMD_SETUP is present.
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            --pr)
                worktree_setup_require_value "$1" "${2:-}" || exit 1
                [[ -z $PR ]] || { worktree_setup_fail '--pr given more than once'; exit 1; }
                PR=$2
                shift 2
                ;;
            --pr=*)
                [[ -z $PR ]] || { worktree_setup_fail '--pr given more than once'; exit 1; }
                PR=${1#*=}
                shift
                ;;
            --repo)
                worktree_setup_require_value "$1" "${2:-}" || exit 1
                [[ -z $REPO ]] || { worktree_setup_fail '--repo given more than once'; exit 1; }
                REPO=$2
                shift 2
                ;;
            --repo=*)
                [[ -z $REPO ]] || { worktree_setup_fail '--repo given more than once'; exit 1; }
                REPO=${1#*=}
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
    [[ $PR =~ ^[1-9][0-9]*$ ]] || { worktree_setup_fail '--pr must be a positive integer'; exit 1; }
    worktree_setup_validate_repo_slug "$REPO" || exit 1
    command -v jq >/dev/null 2>&1 || {
        worktree_setup_fail 'jq is not installed; evidence unavailable'
        exit 1
    }
    command -v gh >/dev/null 2>&1 || {
        worktree_setup_fail 'gh is not installed'
        exit 1
    }
}

existing_worktree_for_branch() {
    local root=$1 branch=$2 line path=''
    while IFS= read -r line; do
        case $line in
            'worktree '*) path=${line#worktree } ;;
            "branch refs/heads/$branch")
                printf '%s\n' "$path"
                return 0
                ;;
        esac
    done < <(git -C "$root" worktree list --porcelain)
    return 1
}

main() {
    parse_args "$@"
    validate_args

    local root config shared preflight head_branch cross_repo existing worktree_root
    local worktree branch setup_declared created_worktree=0 config_export
    root=$(worktree_setup_resolve_repo_root "$PWD") || exit 1
    config="$SCRIPT_DIR/../../.shared/scripts/repo-config.sh"
    shared="$SCRIPT_DIR/../../.shared/scripts"
    preflight="$shared/agent-preflight.sh"

    head_branch=$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq '.headRefName') || {
        worktree_setup_fail "could not resolve head branch for $REPO#$PR"
        exit 1
    }
    worktree_setup_validate_ref "$head_branch" 'pull request head branch' || exit 1
    cross_repo=$(gh pr view "$PR" --repo "$REPO" --json isCrossRepository --jq '.isCrossRepository') || {
        worktree_setup_fail "could not resolve repository mode for $REPO#$PR"
        exit 1
    }
    [[ $cross_repo == true || $cross_repo == false ]] || {
        worktree_setup_fail "pull request repository mode was not boolean: $cross_repo"
        exit 1
    }
    git -C "$root" fetch origin || {
        worktree_setup_fail 'could not fetch origin'
        exit 1
    }
    branch=$head_branch

    existing=$(existing_worktree_for_branch "$root" "$branch" 2>/dev/null) || existing=''
    if [[ -n $existing ]]; then
        worktree=$existing
    else
        # Load AGENT_WORKTREE_ROOT BEFORE deriving either the exclusion or the
        # target path. Reading it after those writes leaves a configured root
        # unexcluded and the real worktree untracked in the main repository.
        # This ordering is deliberately kept in this entry point as a contract
        # regression guard for the review skill's Step 0a hazard.
        unset AGENT_WORKTREE_ROOT
        # worktree_setup_load_config's own -x check reports a specific error;
        # capturing its output through a plain assignment (rather than
        # embedding the substitution directly inside `eval`'s argument) is
        # required for that failure's exit status to actually reach this
        # `|| exit 1` instead of being discarded by eval's own exit status.
        config_export=$(worktree_setup_load_config "$config" "$root") || exit 1
        eval "$config_export"
        worktree_root=${AGENT_WORKTREE_ROOT:-.worktrees}
        worktree_setup_validate_worktree_root "$worktree_root" || exit 1
        worktree_setup_ensure_exclude "$root" "$worktree_root/" || exit 1
        # The worktree path is always derived from the validated repository
        # root and worktree root — no environment override is honored here,
        # so nothing can steer worktree creation outside the repository.
        worktree="$root/$worktree_root/pr-$PR"
        if [[ -e $worktree || -L $worktree ]]; then
            worktree_setup_fail "worktree path exists: $worktree"
            exit 1
        fi
        if [[ $cross_repo == true ]]; then
            git -C "$root" worktree add --detach "$worktree" || {
                worktree_setup_fail "could not create detached worktree $worktree"
                exit 1
            }
            (
                cd -- "$worktree"
                gh pr checkout "$PR" --repo "$REPO"
            ) || {
                worktree_setup_fail "could not check out fork pull request $REPO#$PR"
                exit 1
            }
        else
            git -C "$root" worktree add -b "$head_branch" "$worktree" "origin/$head_branch" 2>/dev/null ||
                git -C "$root" worktree add "$worktree" "$head_branch" || {
                    worktree_setup_fail "could not create worktree $worktree"
                    exit 1
                }
        fi
        created_worktree=1
    fi

    worktree_setup_ensure_exclude "$root" '.agent/*' || exit 1
    if ((created_worktree)); then
        worktree_setup_propagate_config "$root" "$worktree" || exit 1
    fi
    worktree_setup_preflight "$preflight" "$worktree" "$REPO" || exit 1
    if [[ $cross_repo == false ]]; then
        git -C "$worktree" pull --ff-only origin "$head_branch" || {
            worktree_setup_fail "could not fast-forward pull request branch $head_branch"
            exit 1
        }
    fi
    setup_declared=$("$config" --repo-root "$worktree" --get AGENT_CMD_SETUP 2>/dev/null) || setup_declared=''
    local setup_status setup_marker="$worktree/.agent/setup-succeeded"
    if [[ -e $setup_marker && ! -f $setup_marker ]] || [[ -L $setup_marker ]]; then
        worktree_setup_fail "setup completion marker is not a regular file: $setup_marker"
        exit 1
    fi
    if worktree_setup_declared_setup "$config" "$shared/agent-run.sh" "$worktree"; then
        if [[ -n $setup_declared ]]; then
            setup_status=declared
        else
            setup_status=none
        fi
    elif ((created_worktree)) || [[ ! -f $setup_marker ]]; then
        # A freshly created worktree that never finished its own setup, or a
        # reused worktree that has never recorded a successful setup (e.g. its
        # only prior attempt also failed), genuinely isn't ready; that failure
        # stays fatal. Leaving the marker unwritten on failure is what makes a
        # later re-run of this same never-succeeded worktree fatal too, rather
        # than silently downgrading to a warning.
        worktree_setup_fail "setup failed in $worktree"
        exit 1
    else
        # A reused worktree previously completed its declared setup at least
        # once (the marker proves it); a convenience re-run of that command
        # failing now must not block re-entry. worktree_setup_declared_setup's
        # own agent-run.sh invocation already printed the failure detail and
        # full log path above.
        setup_status=failed
    fi
    printf 'worktree=%s branch=%s setup=%s cross-repository=%s\n' "$worktree" "$branch" \
        "$setup_status" "$cross_repo"
}

main "$@"
