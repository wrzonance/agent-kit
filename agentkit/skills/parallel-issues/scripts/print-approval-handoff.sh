#!/usr/bin/env bash
# Render attended agent-run approval recipes for isolated worktrees.  The
# helper refuses the main checkout so an operator cannot approve work against
# the wrong tree by copying a generated line.
set -uo pipefail

readonly PROGRAM=${0##*/}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
runner=$script_dir/../../.shared/scripts/agent-run.sh
worktrees=()
commands=()
only=''

usage() {
    cat <<'EOF'
Usage: print-approval-handoff.sh --worktree DIR [--worktree DIR ...]
       --cmd NAME [--cmd NAME ...] [--only NAME[,NAME...]] [--runner FILE]

Prints one copy-pasteable approval line per worktree and command. The main
checkout is never an eligible target.
EOF
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

while (($#)); do
    case $1 in
        --worktree)
            (($# >= 2)) || die '--worktree requires a directory'
            worktrees+=("$2")
            shift 2
            ;;
        --cmd)
            (($# >= 2)) || die '--cmd requires a command name'
            commands+=("$2")
            shift 2
            ;;
        --only)
            (($# >= 2)) || die '--only requires a suite selector'
            only=$2
            shift 2
            ;;
        --runner)
            (($# >= 2)) || die '--runner requires an executable path'
            runner=$2
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

((${#worktrees[@]} > 0)) || die 'at least one --worktree is required'
((${#commands[@]} > 0)) || die 'at least one --cmd is required'
[[ -x $runner ]] || die "agent-run helper is missing or not executable: $runner"
[[ -z $only || $only =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]] ||
    die '--only must be a comma-separated suite selector'

for command_name in "${commands[@]}"; do
    [[ $command_name =~ ^[A-Za-z0-9_.-]+$ ]] ||
        die "unsafe command name: $command_name"
done

# Resolve to an absolute path without relying on readlink -f, which is a
# GNU coreutils extension absent on BSD/macOS. Only the containing directory
# is canonicalized (cd + pwd -P, the idiom already used below for the
# worktree and Git root); the basename is kept as-is so a runner that is
# itself a symlink still resolves and executes correctly.
runner_dir=$(dirname -- "$runner")
runner_dir=$(cd -- "$runner_dir" 2>/dev/null && pwd -P) || die "cannot resolve runner directory: $runner"
runner=$runner_dir/$(basename -- "$runner")
printf '%s\n' 'Workers will block at command approval until these are run from an operator terminal:'
for worktree in "${worktrees[@]}"; do
    [[ -d $worktree ]] || die "worktree is not a directory: $worktree"
    worktree=$(cd -- "$worktree" && pwd -P) || die "cannot resolve worktree: $worktree"
    top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) ||
        die "worktree is not a Git checkout: $worktree"
    top=$(cd -- "$top" && pwd -P) || die "cannot resolve Git root: $worktree"
    first_worktree=''
    while IFS= read -r line; do
        if [[ $line == worktree\ * ]]; then
            first_worktree=${line#worktree }
            break
        fi
    done < <(git -C "$top" worktree list --porcelain 2>/dev/null)
    first_worktree=$(cd -- "$first_worktree" 2>/dev/null && pwd -P || true)
    [[ -n $first_worktree && $top != "$first_worktree" ]] ||
        die "refusing main checkout: never hand off the main checkout ($top)"
    for command_name in "${commands[@]}"; do
        printf 'cd %q && %q --approve --cmd %q' "$top" "$runner" "$command_name"
        [[ -z $only ]] || printf ' --only %q' "$only"
        printf '\n'
    done
done
