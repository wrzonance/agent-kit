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
self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.
self_dir=$(cd -P -- "$self_dir" && pwd -P) || {
    printf '%s: could not resolve helper directory\n' "$PROGRAM" >&2
    exit 1
}
# shellcheck source=lib/contract-cache.sh
source "$self_dir/lib/contract-cache.sh"
repo_root=''
mode=''
key=''
worker_model=''

usage() {
    printf 'usage: %s --repo-root DIR (--get KEY [--worker-model ID] | --check)\n' "$PROGRAM" >&2
    printf 'keys: skills.path skills.content harness.identity harness.trailer harness.name repo.slug base.branch\n' >&2
    printf '  harness.identity resolves to the bare harness identity (e.g. "Claude <noreply@anthropic.com>").\n' >&2
    printf '  harness.trailer resolves to the full, git-parseable trailer line built from that identity\n' >&2
    printf '  (e.g. "Co-Authored-By: Claude <noreply@anthropic.com>") -- it never returns a keyless value.\n' >&2
    printf '  skills.content resolves to the sha256 content stamp over the shipped skill/script tree\n' >&2
    printf '  (issue #453) -- independent of skills.path, which always stays the bare directory path.\n' >&2
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
        --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
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
# Harness-keyed first, legacy bare name as a read-only fallback (issue #551):
# see contract_cache_contract_file's own comment for why.
contract=$(contract_cache_contract_file "$repo_root")

case $mode in
    get)
        case $key in
            skills.path|skills.content|harness.identity|harness.trailer|harness.name|repo.slug|base.branch) ;;
            *) die 2 "unknown contract key: $key" ;;
        esac
        [[ -z $worker_model || $key == harness.identity || $key == harness.trailer ]] ||
            die 2 '--worker-model requires --get harness.identity or harness.trailer'
        if [[ -n $worker_model ]]; then
            [[ $worker_model =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] ||
                die 2 '--worker-model must be a safe single-token identifier'
        fi
        ;;
    check)
        [[ -z $worker_model ]] || die 2 '--worker-model requires --get harness.identity or harness.trailer'
        ;;
esac

if [[ ! -e $contract && ! -L $contract ]]; then
    die 3 "no environment contract: $contract"
fi

# Keep this expression in lockstep with guard_contract_is_ours. The helper is
# the executable source of truth; the hook delegates here instead of copying
# the predicate.
contract_is_ours() {
    local rc=0
    [[ -n $contract && -r $contract && -f $contract && ! -L $contract && -O $contract ]] || return 1
    git -C "$repo_root" ls-files --error-unmatch -- "$contract" > /dev/null 2>&1 || rc=$?
    # Only status 1 means "git looked and the path is untracked". Status 0 means
    # tracked, and anything else (128 for a missing or refused work tree, 127
    # for no git at all) means git never established provenance. Accepting a
    # bare non-zero status would fail OPEN there and serve a tracked contract.
    ((rc == 1))
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
    elif ! git -C "$repo_root" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        die 4 "cannot prove the environment contract is untracked; not a usable Git work tree: $repo_root"
    else
        die 4 "environment contract failed provenance checks: $contract"
    fi
fi

[[ $mode == check ]] && exit 0

emit_value() {
    local value=$1 original
    if [[ -n $worker_model ]]; then
        original=$value
        [[ $value == *' <'* ]] ||
            die 1 'harness identity has no email boundary for worker-model substitution'
        value=$(printf '%s\n' "$value" | sed "s| <| $worker_model <|")
        [[ $value != "$original" ]] ||
            die 1 'harness identity substitution did not change the value'
    fi
    # harness.trailer is the ONLY key that composes a full "Key: value" trailer
    # line -- harness.identity (and every other key) always returns bare data.
    # This is the fix for the keyless-trailer defect (issue #345): a field
    # literally named "trailer" now always returns something git can parse as
    # one, so a caller can no longer be misled by the name into passing an
    # identity straight to worktree-commit.sh's --trailer.
    if [[ $key == harness.trailer ]]; then
        value="Co-Authored-By: $value"
    fi
    printf '%s\n' "$value"
}

config="$repo_root/.agent/config.env"
read_contract_value() {
    local requested=$1 raw=''
    case $requested in
        skills.path)
            raw=$(sed -n 's/^skills= path=//p' "$contract")
            ;;
        skills.content)
            raw=$(sed -n 's/^skills-content= sha256=//p' "$contract")
            ;;
        harness.identity|harness.trailer)
            # Both keys read the same raw contract field; emit_value is what
            # composes harness.trailer into a full "Co-Authored-By: ..." line.
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
    printf '%s\n' "$raw" | sed -n '1p'
}

cache_digest=$(contract_cache_input_digest "$contract" "$config" 2> /dev/null || true)
if [[ -n $cache_digest ]] &&
    value=$(contract_cache_read "$repo_root" "$cache_digest" "$key" 2> /dev/null); then
    live_value=$(read_contract_value "$key")
    session_skills_path=$(contract_cache_read "$repo_root" "$cache_digest" skills.path 2> /dev/null || true)
    live_skills_path=$(read_contract_value skills.path)
    # The digest says only that the sources are unchanged; an owned/untracked
    # cache remains mutable. Accept a hit only when its requested projection
    # and the skills path used for the session record still match live data.
    if [[ -n $live_value && $value == "$live_value" &&
        -n $session_skills_path && $session_skills_path == "$live_skills_path" ]]; then
        contract_cache_write_session_context "$repo_root" "$cache_digest" "skills.path=$live_skills_path"
        emit_value "$value"
        exit 0
    fi
fi

raw=$(read_contract_value "$key")
value=$raw
[[ -n $value ]] || die 1 "contract key is absent or empty: $key"

if [[ -n $cache_digest ]]; then
    cache_entries=()
    for cache_key in skills.path skills.content harness.identity harness.trailer harness.name repo.slug base.branch; do
        cache_value=$(read_contract_value "$cache_key")
        [[ -n $cache_value ]] && cache_entries+=("$cache_key=$cache_value")
    done
    contract_cache_write "$repo_root" "$cache_digest" "${cache_entries[@]}"
    contract_cache_write_session_context "$repo_root" "$cache_digest" "${cache_entries[@]}"
fi

emit_value "$value"
