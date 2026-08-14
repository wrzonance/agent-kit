#!/usr/bin/env bash
# Read established facts from the session environment contract.
#
# The contract is agent context, not repository configuration. It must be an
# untracked, readable regular file owned by this user and it must not be a
# symlink before any value is served.
set -euo pipefail

if [[ -z $BASH_VERSION ]] || (( BASH_VERSINFO[0] < 4 )); then
    printf '%s: requires Bash >= 4\n' "$(basename -- "$0")" >&2
    exit 2
fi

PROGRAM=$(basename -- "$0")
readonly PROGRAM
repo_root=''
mode=''
key=''
worker_model=''

usage() {
    printf 'usage: %s --repo-root DIR (--get KEY [--worker-model ID] | --check)\n' "$PROGRAM" >&2
    printf 'keys: skills.path harness.trailer harness.name repo.slug base.branch\n' >&2
    exit 2
}

die() {
    local rc=$1
    shift
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit "$rc"
}

while (($#)); do
    case $1 in
        --repo-root)
            (($# >= 2)) || usage
            [[ -z $repo_root ]] || usage
            repo_root=$2
            shift 2
            ;;
        --get)
            (($# >= 2)) || usage
            [[ -z $mode ]] || usage
            mode='get'
            key=$2
            shift 2
            ;;
        --check)
            [[ -z $mode ]] || usage
            mode='check'
            shift
            ;;
        --worker-model)
            (($# >= 2)) || usage
            [[ -z $worker_model ]] || usage
            worker_model=$2
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n $repo_root && -d $repo_root ]] || usage
[[ -n $mode ]] || usage

repo_root=$(cd -- "$repo_root" && pwd -P) ||
    die 2 'could not resolve --repo-root'
contract="$repo_root/.agent/env-contract.txt"

case $mode in
    get)
        case $key in
            skills.path|harness.trailer|harness.name|repo.slug|base.branch) ;;
            *) die 2 "unknown contract key: $key" ;;
        esac
        [[ -z $worker_model || $key == harness.trailer ]] ||
            die 2 '--worker-model requires --get harness.trailer'
        if [[ -n $worker_model ]]; then
            [[ $worker_model =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] ||
                die 2 '--worker-model must be a safe single-token identifier'
        fi
        ;;
    check)
        [[ -z $worker_model ]] || die 2 '--worker-model requires --get harness.trailer'
        ;;
esac

if [[ ! -e $contract && ! -L $contract ]]; then
    die 3 "no environment contract: $contract"
fi

# Keep this expression in lockstep with guard_contract_is_ours. The helper is
# the executable source of truth; the hook delegates here instead of copying
# the predicate.
contract_is_ours() {
    [[ -n $contract && -r $contract && -f $contract && ! -L $contract && -O $contract ]] || return 1
    ! git -C "$repo_root" ls-files --error-unmatch -- "$contract" > /dev/null 2>&1
}

if ! contract_is_ours; then
    if [[ -L $contract ]]; then
        die 4 "environment contract is a symlink: $contract"
    elif [[ ! -f $contract ]]; then
        die 4 "environment contract is not a regular file: $contract"
    elif [[ ! -O $contract ]]; then
        die 4 "environment contract owner mismatch: $contract"
    elif [[ ! -r $contract ]]; then
        die 4 "environment contract is not readable: $contract"
    elif git -C "$repo_root" ls-files --error-unmatch -- "$contract" > /dev/null 2>&1; then
        die 4 "environment contract is tracked: $contract"
    else
        die 4 "environment contract failed provenance checks: $contract"
    fi
fi

[[ $mode == check ]] && exit 0

raw=''
case $key in
    skills.path)
        raw=$(sed -n 's/^skills= path=//p' "$contract")
        ;;
    harness.trailer)
        raw=$(sed -n 's/^harness=.*trailer="\([^"]*\)".*/\1/p' "$contract")
        ;;
    harness.name)
        raw=$(sed -n 's/^harness= name=\([^[:space:]]*\).*/\1/p' "$contract")
        ;;
    repo.slug)
        raw=$(sed -n 's/^repo=//p' "$contract")
        ;;
    base.branch)
        raw=$(sed -n 's/^base=\([^[:space:]]*\).*/\1/p' "$contract")
        ;;
esac
value=$(printf '%s\n' "$raw" | sed -n '1p')
[[ -n $value ]] || die 1 "contract key is absent or empty: $key"

if [[ -n $worker_model ]]; then
    original=$value
    [[ $value == *' <'* ]] ||
        die 1 'harness.trailer has no email boundary for worker-model substitution'
    value=$(printf '%s\n' "$value" | sed "s| <| $worker_model <|")
    [[ $value != "$original" ]] ||
        die 1 'harness.trailer substitution did not change the value'
fi

printf '%s\n' "$value"
