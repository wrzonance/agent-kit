#!/usr/bin/env bash
# Shared mechanics for creating issue and pull-request worktrees.
#
# The entry points own their forge-specific arguments; this library owns the
# filesystem and repository boundaries that must remain identical between the
# parallel-issues and review-remote-pr skills.

worktree_setup_fail() {
    printf '%s: %s\n' "${WORKTREE_SETUP_PROGNAME:-worktree-setup}" "$*" >&2
    return 1
}

worktree_setup_require_value() {
    [[ -n ${2:-} ]] || worktree_setup_fail "$1 requires a value"
}

worktree_setup_resolve_repo_root() {
    local supplied=${1:-} root
    [[ -n $supplied && -d $supplied ]] || {
        worktree_setup_fail "repository root is not a directory: ${supplied:-missing}"
        return 1
    }
    root=$(git -C "$supplied" rev-parse --show-toplevel 2>/dev/null) || {
        worktree_setup_fail "not a Git repository: $supplied"
        return 1
    }
    root=$(cd -- "$root" && pwd -P) || {
        worktree_setup_fail "could not resolve repository root: $supplied"
        return 1
    }
    printf '%s\n' "$root"
}

worktree_setup_common_dir() {
    local root=$1 common
    common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || {
        worktree_setup_fail "could not resolve Git common directory: $root"
        return 1
    }
    if [[ $common != /* ]]; then
        common=$root/$common
    fi
    readlink -f -- "$common" 2>/dev/null || {
        worktree_setup_fail "could not resolve Git common directory: $common"
        return 1
    }
}

worktree_setup_exclude_path() {
    local root=$1 common
    common=$(worktree_setup_common_dir "$root") || return 1
    printf '%s/info/exclude\n' "$common"
}

worktree_setup_ensure_exclude() {
    local root=$1 pattern=$2 exclude
    [[ -n $pattern && $pattern != *$'\n'* && $pattern != *$'\r'* ]] || {
        worktree_setup_fail "invalid Git exclude pattern"
        return 1
    }
    exclude=$(worktree_setup_exclude_path "$root") || return 1
    mkdir -p -- "$(dirname -- "$exclude")" || {
        worktree_setup_fail "could not create Git metadata directory for $exclude"
        return 1
    }
    if ! grep -Fqx -- "$pattern" "$exclude" 2>/dev/null; then
        printf '%s\n' "$pattern" >>"$exclude" || {
            worktree_setup_fail "could not update Git exclude: $exclude"
            return 1
        }
    fi
}

worktree_setup_load_config() {
    local config=$1 root=$2
    [[ -x $config ]] || {
        worktree_setup_fail "repository config helper is missing or not executable: $config"
        return 1
    }
    "$config" --repo-root "$root" --export
}

worktree_setup_worktree_root() {
    local config=$1 root=$2 value
    value=$("$config" --repo-root "$root" --get AGENT_WORKTREE_ROOT 2>/dev/null) || value=''
    [[ -n $value ]] || value='.worktrees'
    [[ $value != /* && $value != *..* && $value != *$'\n'* && $value != *$'\r'* ]] || {
        worktree_setup_fail "AGENT_WORKTREE_ROOT must be a safe repository-relative path"
        return 1
    }
    printf '%s\n' "${value%/}"
}

worktree_setup_validate_ref() {
    local value=$1 label=$2
    [[ $value =~ ^[A-Za-z0-9._/-]+$ && $value != -* && $value != /* &&
        $value != */ && $value != *..* && $value != *//* &&
        $value != *'@{'* ]] || {
        worktree_setup_fail "$label must be a safe branch ref"
        return 1
    }
}

worktree_setup_validate_full_sha() {
    local value=$1 label=$2
    [[ $value =~ ^[0-9a-f]{40}$ ]] || {
        worktree_setup_fail "$label must be a full 40-character lowercase commit SHA"
        return 1
    }
}

worktree_setup_validate_repo_slug() {
    local value=$1
    [[ $value =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
        worktree_setup_fail 'repository must look like OWNER/REPO'
        return 1
    }
}

worktree_setup_validate_worktree_root() {
    local value=$1
    [[ -n $value && $value != /* && $value != *..* && $value != *$'\n'* &&
        $value != *$'\r'* ]] || {
        worktree_setup_fail 'worktree root must be a safe repository-relative path'
        return 1
    }
}

worktree_setup_preflight() {
    local preflight=$1 worktree=$2 repo=${3:-}
    [[ -x $preflight ]] || {
        worktree_setup_fail "agent-preflight.sh is missing or not executable: $preflight"
        return 1
    }
    if [[ -n $repo ]]; then
        "$preflight" --repo "$repo" --worktree "$worktree"
    else
        "$preflight" --worktree "$worktree"
    fi
}

worktree_setup_prepare_agent_dir() {
    local worktree=$1 agent_dir="$1/.agent"
    if [[ -L $agent_dir ]]; then
        worktree_setup_fail "worktree .agent directory is a symlink: $agent_dir"
        return 1
    fi
    if [[ -e $agent_dir && ! -d $agent_dir ]]; then
        worktree_setup_fail "worktree .agent path is not a directory: $agent_dir"
        return 1
    fi
    [[ -d $agent_dir ]] || mkdir -- "$agent_dir" || {
        worktree_setup_fail "could not create worktree .agent directory: $agent_dir"
        return 1
    }
}

worktree_setup_propagate_config() {
    local root=$1 worktree=$2 source_dir source target temp
    source_dir="$root/.agent"
    source="$source_dir/config.env"
    target="$worktree/.agent/config.env"

    if [[ -L $source_dir ]]; then
        worktree_setup_fail "root .agent directory is a symlink: $source_dir"
        return 1
    fi
    [[ -e $source_dir ]] || return 0
    [[ -d $source_dir ]] || {
        worktree_setup_fail "root .agent path is not a directory: $source_dir"
        return 1
    }
    if [[ -L $source ]]; then
        worktree_setup_fail "root config.env is a symlink: $source"
        return 1
    fi
    [[ -e $source ]] || return 0
    [[ -f $source && -O $source ]] || {
        worktree_setup_fail "root config.env must be a self-owned regular file: $source"
        return 1
    }

    worktree_setup_prepare_agent_dir "$worktree" || return 1
    if [[ -L $target ]]; then
        worktree_setup_fail "worktree config.env is a symlink: $target"
        return 1
    fi
    if [[ -e $target ]]; then
        [[ -f $target && -O $target ]] || {
            worktree_setup_fail "worktree config.env must be a self-owned regular file: $target"
            return 1
        }
        # A checked-in or previously trusted target is authoritative. Never
        # overwrite it with local state, even when its bytes differ.
        return 0
    fi

    temp=$(mktemp "$worktree/.agent/.config.env.XXXXXX") || {
        worktree_setup_fail "could not create a private config staging file: $worktree/.agent"
        return 1
    }
    if ! cat -- "$source" >"$temp" || ! chmod 600 -- "$temp"; then
        rm -f -- "$temp"
        worktree_setup_fail "could not stage root-local config.env"
        return 1
    fi
    # Linux's no-target-directory mode prevents a raced directory from being
    # interpreted as the destination directory. No-clobber keeps an existing
    # regular target authoritative, and neither mode follows a symlink target.
    if ! mv --no-clobber --no-target-directory -- "$temp" "$target" 2>/dev/null; then
        rm -f -- "$temp"
        worktree_setup_fail "could not place root-local config.env"
        return 1
    fi
    # Revalidate after the move: a target can appear or change between the
    # initial checks and placement. Never report success for a non-regular,
    # symlinked, or foreign-owned result.
    if [[ -L $target || ! -f $target || ! -O $target ]]; then
        rm -f -- "$temp"
        worktree_setup_fail "worktree config.env placement was not a self-owned regular file: $target"
        return 1
    fi
    if [[ -e $temp ]]; then
        rm -f -- "$temp"
    fi
}

worktree_setup_declared_setup() {
    local config=$1 agent_run=$2 worktree=$3 declaration
    [[ -x $config ]] || {
        worktree_setup_fail "repository config helper is missing or not executable: $config"
        return 1
    }
    [[ -x $agent_run ]] || {
        worktree_setup_fail "agent-run.sh is missing or not executable: $agent_run"
        return 1
    }
    declaration=$("$config" --repo-root "$worktree" --get AGENT_CMD_SETUP 2>/dev/null) || declaration=''
    [[ -z $declaration ]] || "$agent_run" --dir "$worktree" --cmd setup
}
