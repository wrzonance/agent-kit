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
    # Mark this checkout as carrying a pull request's head. agent-run.sh reads
    # the marker and keeps command approvals scoped to THIS checkout rather than
    # reusing the clone's record: a contributor's branch can change what a
    # declared command transitively runs -- a declaration naming a task runner
    # and a task carries no path in argv, so the script it resolves is not
    # something the trust fingerprint hashes -- so a PR checkout must earn its
    # own approval.
    # Written on every run, not only on creation, because a reused worktree is
    # still carrying a pull request's head.
    # The pull request's own content is already checked out at this point, so
    # both of these paths are contributor-controlled: `.agent/*` sits in the
    # local exclude, but that governs UNTRACKED files only, and a pull request
    # can track whatever it likes. A plain redirect follows a symlink, so a
    # tracked symlink here would make this write land wherever it points --
    # arbitrary file write as the reviewing maintainer, from the one command
    # whose whole job is handling untrusted branches. Refuse a symlinked
    # directory, and replace the marker path rather than writing through it.
    if [[ -L $worktree/.agent ]]; then
        worktree_setup_fail "$worktree/.agent is a symlink; refusing to mark this checkout"
        exit 1
    fi
    mkdir -p -- "$worktree/.agent" 2> /dev/null || true
    # rm -f removes a symlink itself rather than its target, and fails on a
    # directory -- which the write below then reports.
    rm -f -- "$worktree/.agent/pr-checkout" 2> /dev/null || true
    if [[ -e $worktree/.agent/pr-checkout || -L $worktree/.agent/pr-checkout ]] ||
        ! printf 'pr=%s\nrepo=%s\n' "$PR" "$REPO" > "$worktree/.agent/pr-checkout" 2> /dev/null; then
        # Continuing unmarked would hand this checkout the wider repository
        # scope, which is the exact failure the marker exists to prevent.
        worktree_setup_fail "could not mark $worktree as a pull-request checkout"
        exit 1
    fi
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
    worktree_setup_declared_setup "$config" "$shared/agent-run.sh" "$worktree" || {
        worktree_setup_fail "setup failed in $worktree"
        exit 1
    }
    printf 'worktree=%s branch=%s setup=%s cross-repository=%s\n' "$worktree" "$branch" \
        "$(if [[ -n $setup_declared ]]; then printf declared; else printf none; fi)" "$cross_repo"
}

main "$@"
