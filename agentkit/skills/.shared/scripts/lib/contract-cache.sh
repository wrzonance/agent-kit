#!/usr/bin/env bash
# Content-addressed cache for the small, read-only contract projection.
#
# The caller must validate the environment contract before using this cache.
# This library never sources a snapshot: cache records are parsed as data and
# only accepted when the caller's current input digest matches exactly.

# Harness-aware contract resolution (issue #551).
#
# The environment contract used to be one untracked file per checkout,
# .agent/env-contract.txt, shared by every CLI that opens it -- but it carries
# harness-specific facts (skills= path=, harness= name=). A second harness
# opening the same checkout rewrote it at SessionStart, silently changing the
# skills tree, helper paths, and hook verdicts of a run already in flight
# (observed live: a root running parallel-issues under one CLI had its
# contract clobbered mid-wave by a second CLI's session, opened "to
# observe"). Every writer now targets its own .agent/env-contract.<harness>.txt,
# so one harness never even has an occasion to touch another's file. The
# bare, un-suffixed name is kept as a READ-ONLY legacy fallback for one
# release -- nothing added by this fix writes it -- so a checkout whose
# contract predates this change, or a worktree whose contract came from a
# caller that still targets the bare name, keeps resolving exactly as before.
contract_cache_harness_name() {
    if [[ -n ${CONTRACT_CACHE_HARNESS_NAME_MEMO:-} ]]; then
        printf '%s' "$CONTRACT_CACHE_HARNESS_NAME_MEMO"
        return 0
    fi
    local self_dir=${BASH_SOURCE[0]%/*} helper name
    [[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.
    helper="$self_dir/../harness-id.sh"
    [[ -x $helper ]] || return 1
    name=$("$helper" --name 2> /dev/null) || return 1
    # A safe single-token filename component: harness-id.sh's own vocabulary
    # (claude, codex, opencode, unknown) always matches this, but a broken or
    # tampered helper must never hand back something that could escape the
    # .agent/ directory or collide with an unrelated file.
    [[ $name =~ ^[a-z][a-z0-9]*$ ]] || return 1
    CONTRACT_CACHE_HARNESS_NAME_MEMO=$name
    printf '%s' "$name"
}

# The contract path a READER should consult for repo_root: the running
# harness's own file when one has ever been written there, otherwise the
# legacy bare name. $2 lets a caller that already resolved a harness (e.g.
# one checking a DIFFERENT harness's liveness) skip the redundant lookup.
contract_cache_contract_file() {
    local repo_root=$1 harness=${2:-} keyed legacy
    legacy="$repo_root/.agent/env-contract.txt"
    [[ -n $harness ]] || harness=$(contract_cache_harness_name 2> /dev/null) || harness=''
    [[ -n $harness ]] || { printf '%s' "$legacy"; return 0; }
    keyed="$repo_root/.agent/env-contract.$harness.txt"
    if [[ -e $keyed || -L $keyed ]]; then
        printf '%s' "$keyed"
    else
        printf '%s' "$legacy"
    fi
}

# The path a WRITER should target for repo_root: always the harness-keyed
# name, whether or not it exists yet -- a writer creates it, a reader merely
# prefers it. Falls back to the legacy bare name only when the harness itself
# cannot be determined (a broken install, never normal operation), which is
# the same fail-open reasoning contract_cache_contract_file above already
# uses for "no harness signal at all".
contract_cache_contract_write_target() {
    local repo_root=$1 harness=${2:-}
    [[ -n $harness ]] || harness=$(contract_cache_harness_name 2> /dev/null) || harness=''
    [[ -n $harness ]] || { printf '%s' "$repo_root/.agent/env-contract.txt"; return 0; }
    printf '%s' "$repo_root/.agent/env-contract.$harness.txt"
}

contract_cache_hash_stream() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum > /dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        return 1
    fi
}

contract_cache_hash_file() {
    local file=$1
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum -- "$file" | awk '{print $1}'
    elif command -v shasum > /dev/null 2>&1; then
        shasum -a 256 -- "$file" | awk '{print $1}'
    else
        return 1
    fi
}

contract_cache_component_hash() {
    local file=$1
    if [[ ! -e $file && ! -L $file ]]; then
        printf '%s' absent
    elif [[ -f $file ]]; then
        contract_cache_hash_file "$file"
    else
        # A directory or other non-regular input is deliberately not read. Its
        # state still participates in the digest so replacing it with a valid
        # config.env forces a miss.
        printf '%s' invalid
    fi
}

contract_cache_input_digest() {
    local contract=$1 config=$2 contract_hash config_hash
    contract_hash=$(contract_cache_component_hash "$contract") || return 1
    config_hash=$(contract_cache_component_hash "$config") || return 1
    printf 'env-contract=%s\nconfig.env=%s\n' "$contract_hash" "$config_hash" |
        contract_cache_hash_stream
}

contract_cache_path() {
    local repo_root=$1
    printf '%s/.agent/cache/contract-read.snapshot' "$repo_root"
}

contract_cache_session_path() {
    local repo_root=$1
    printf '%s/.agent/cache/contract-session.env' "$repo_root"
}

contract_cache_file_is_ours() {
    local file=$1 repo_root=$2 rc=0
    [[ -n $file && -r $file && -f $file && ! -L $file && -O $file ]] || return 1
    git -C "$repo_root" ls-files --error-unmatch -- "$file" > /dev/null 2>&1 || rc=$?
    ((rc == 1))
}

contract_cache_contract_is_ours() {
    local contract=$1 repo_root=$2 rc=0
    contract_cache_file_is_ours "$contract" "$repo_root" || return 1
    git -C "$repo_root" ls-files --error-unmatch -- "$contract" > /dev/null 2>&1 || rc=$?
    ((rc == 1))
}

contract_cache_repo_root_is_canonical() {
    local repo_root=$1 discovered_root
    [[ $repo_root == /* && -d $repo_root && ! -L $repo_root ]] || return 1
    discovered_root=$(git -C "$repo_root" rev-parse --show-toplevel 2> /dev/null) || return 1
    discovered_root=$(cd -P -- "$discovered_root" && pwd -P) || return 1
    [[ $repo_root == "$discovered_root" ]]
}

contract_cache_dir_is_ours() {
    local repo_root=$1 create_cache=${2:-no} root_agent cache_dir
    root_agent="$repo_root/.agent"
    cache_dir="$root_agent/cache"
    [[ -d $root_agent && ! -L $root_agent && -O $root_agent ]] || return 1
    if [[ ! -e $cache_dir && ! -L $cache_dir ]]; then
        [[ $create_cache == yes ]] || return 1
        mkdir -- "$cache_dir" 2> /dev/null || return 1
    fi
    [[ -d $cache_dir && ! -L $cache_dir && -O $cache_dir ]] || return 1
}

contract_cache_read() {
    local repo_root=$1 digest=$2 key=$3 cache format cached_digest value
    cache=$(contract_cache_path "$repo_root")
    contract_cache_file_is_ours "$cache" "$repo_root" || return 1
    format=$(sed -n 's/^format=\([0-9][0-9]*\)$/\1/p' "$cache" | sed -n '1p')
    [[ $format == 1 ]] || return 1
    cached_digest=$(sed -n 's/^inputs_sha256=\([[:xdigit:]]*\)$/\1/p' "$cache" | sed -n '1p')
    [[ -n $digest && $cached_digest == "$digest" ]] || return 1
    value=$(awk -v wanted="$key" '
        index($0, wanted "=") == 1 {
            print substr($0, length(wanted) + 2)
            exit
        }
    ' "$cache")
    [[ -n $value ]] || return 1
    printf '%s\n' "$value"
}

contract_cache_write() {
    local repo_root=$1 digest=$2 cache cache_dir staged entry
    shift 2
    (($#)) || return 0
    [[ -n $digest ]] || return 0
    cache=$(contract_cache_path "$repo_root")
    cache_dir=${cache%/*}
    contract_cache_dir_is_ours "$repo_root" yes || return 0

    # Never replace a cache we cannot prove is ours. In particular, a symlink
    # must remain untouched even when the destination exists in a writable dir.
    if [[ -e $cache || -L $cache ]]; then
        contract_cache_file_is_ours "$cache" "$repo_root" || return 0
    fi
    staged=$(mktemp -- "$cache_dir/.contract-read.XXXXXX" 2> /dev/null) || return 0
    {
        printf 'format=1\ninputs_sha256=%s\n' "$digest"
        for entry in "$@"; do
            [[ $entry == *=* ]] || continue
            printf '%s\n' "$entry"
        done
    } > "$staged" || {
        rm -f -- "$staged" 2> /dev/null || true
        return 0
    }
    chmod 600 -- "$staged" 2> /dev/null || {
        rm -f -- "$staged" 2> /dev/null || true
        return 0
    }
    if ! mv -- "$staged" "$cache" 2> /dev/null; then
        rm -f -- "$staged" 2> /dev/null || true
    fi
}

contract_cache_write_session_context() {
    local repo_root=$1 digest=$2 context context_dir staged entry skills_path=''
    shift 2
    for entry in "$@"; do
        if [[ $entry == skills.path=* ]]; then
            skills_path=${entry#skills.path=}
            break
        fi
    done
    [[ -n $skills_path && -n $digest ]] || return 0
    context=$(contract_cache_session_path "$repo_root")
    context_dir=${context%/*}
    contract_cache_dir_is_ours "$repo_root" yes || return 0
    if [[ -e $context || -L $context ]]; then
        contract_cache_file_is_ours "$context" "$repo_root" || return 0
    fi
    staged=$(mktemp -- "$context_dir/.contract-session.XXXXXX" 2> /dev/null) || return 0
    {
        # This is deliberately a data record, never shell source.  The reader
        # below has a fixed schema and treats every value as an opaque string.
        printf 'format=1\n'
        printf 'agentkit=%s\n' "$skills_path"
        printf 'shared=%s\n' "$skills_path/.shared/scripts"
        printf 'agentkit_provenance=ok\n'
        printf 'contract_root=%s\n' "$repo_root"
        printf 'contract_inputs_sha256=%s\n' "$digest"
    } > "$staged" || {
        rm -f -- "$staged" 2> /dev/null || true
        return 0
    }
    chmod 600 -- "$staged" 2> /dev/null || {
        rm -f -- "$staged" 2> /dev/null || true
        return 0
    }
    if ! mv -- "$staged" "$context" 2> /dev/null; then
        rm -f -- "$staged" 2> /dev/null || true
    fi
}

contract_cache_session_context_read() {
    local repo_root=$1 requested=${2:-} context contract current_digest skills_path
    local root_agent cache_dir
    local line key value count=0
    local -A values=() seen=()
    local expected_keys='format agentkit shared agentkit_provenance contract_root contract_inputs_sha256'

    # CLI reason classification (issue #587): every failing return below sets
    # this global to one of absent|invalid|skills-path-mismatch|stale before
    # returning, so the CLI entry point at the bottom of this file can name
    # the failure on stderr without changing this function's own return
    # value or a sourced caller's silent contract.
    CONTRACT_CACHE_SESSION_CONTEXT_REASON=''

    # Callers derive this from `git rev-parse --show-toplevel`; reject a
    # relative, symlinked, or nested root so the cache path is never
    # cwd-relative or rooted at a repository-controlled subdirectory.
    if [[ $repo_root != /* || ! -d $repo_root || -L $repo_root ]]; then
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        return 1
    fi
    repo_root=$(cd -P -- "$repo_root" && pwd -P) || {
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        return 1
    }
    if [[ $repo_root != "$1" ]]; then
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        return 1
    fi
    contract_cache_repo_root_is_canonical "$repo_root" || {
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        return 1
    }
    # A cache directory that exists but fails provenance (foreign-owned,
    # symlinked, or a dangling symlink) is corruption/tampering, not absence
    # -- only "nothing at all is there" earns the absent class (issue #587
    # follow-up finding). contract_cache_dir_is_ours checks .agent and
    # .agent/cache internally; re-derive the same two paths here purely to
    # classify, without duplicating its provenance logic.
    root_agent="$repo_root/.agent"
    cache_dir="$root_agent/cache"
    contract_cache_dir_is_ours "$repo_root" || {
        if [[ -e $root_agent || -L $root_agent || -e $cache_dir || -L $cache_dir ]]; then
            CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        else
            CONTRACT_CACHE_SESSION_CONTEXT_REASON=absent
        fi
        return 1
    }
    context=$(contract_cache_session_path "$repo_root")
    contract_cache_file_is_ours "$context" "$repo_root" || {
        if [[ -e $context || -L $context ]]; then
            CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        else
            CONTRACT_CACHE_SESSION_CONTEXT_REASON=absent
        fi
        return 1
    }

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line != *=* ]]; then
            CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
            return 1
        fi
        key=${line%%=*}
        value=${line#*=}
        case " $expected_keys " in
            *" $key "*) ;;
            *)
                CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
                return 1
                ;;
        esac
        if [[ -n ${seen[$key]+present} ]]; then
            CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
            return 1
        fi
        # The record is transported as tab-delimited fields; no C0/DEL
        # separator may survive parsing into a later command block.
        if [[ $value == *[$'\001'-$'\037'$'\177']* ]]; then
            CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
            return 1
        fi
        seen[$key]=1
        values[$key]=$value
        ((count += 1))
    done < "$context"
    if ((count != 6)); then
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        return 1
    fi
    for key in $expected_keys; do
        if [[ -z ${seen[$key]+present} ]]; then
            CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
            return 1
        fi
    done
    if [[ ${values[format]} != 1 || ${values[agentkit_provenance]} != ok ]]; then
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        return 1
    fi
    if [[ ! ${values[contract_inputs_sha256]} =~ ^[[:xdigit:]]{64}$ ]]; then
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        return 1
    fi
    if [[ ${values[contract_root]} != "$repo_root" ]]; then
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        return 1
    fi
    if [[ ${values[agentkit]} != /* || ${values[shared]} != /* ]]; then
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        return 1
    fi

    contract=$(contract_cache_contract_file "$repo_root")
    contract_cache_contract_is_ours "$contract" "$repo_root" || {
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        return 1
    }
    skills_path=$(sed -n 's/^skills= path=//p' "$contract" | sed -n '1p')
    if [[ -z $skills_path || ${values[agentkit]} != "$skills_path" ]]; then
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=skills-path-mismatch
        return 1
    fi
    if [[ ${values[shared]} != "$skills_path/.shared/scripts" ]]; then
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=skills-path-mismatch
        return 1
    fi

    current_digest=$(contract_cache_input_digest "$contract" "$repo_root/.agent/config.env") || {
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=invalid
        return 1
    }
    if [[ $current_digest != "${values[contract_inputs_sha256]}" ]]; then
        CONTRACT_CACHE_SESSION_CONTEXT_REASON=stale
        return 75
    fi

    if [[ -n $requested ]]; then
        case $requested in
            agentkit|shared|agentkit_provenance|contract_root|contract_inputs_sha256) ;;
            *) return 2 ;;
        esac
        printf '%s\n' "${values[$requested]}"
        return 0
    fi

    # Print one tab-separated data record only after all checks pass. Consumers
    # assign fields with `read`; no output from this file is shell syntax.
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${values[agentkit]}" "${values[shared]}" \
        "${values[agentkit_provenance]}" "${values[contract_root]}" \
        "${values[contract_inputs_sha256]}"
}

contract_cache_refresh_session_context() {
    local repo_root=$1 contract=$2 skills_path=$3 digest
    digest=$(contract_cache_input_digest "$contract" "$repo_root/.agent/config.env") || return 0
    [[ -n $digest ]] || return 0
    contract_cache_write_session_context "$repo_root" "$digest" "skills.path=$skills_path"
}

# CLI entry (issue #587): a failed read prints exactly one machine-readable
# stderr line naming the failure class, mapped from the reason the read
# function recorded. Stdout and exit codes are unchanged from before this
# fix; sourced (non-CLI) use of the library never reaches this block, so it
# stays byte-silent.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    if [[ ${1:-} != --read-session-context || ${2:-} != --repo-root || -z ${3:-} ||
        ($# != 3 && ($# != 5 || ${4:-} != --get || -z ${5:-})) ]]; then
        printf 'usage: %s --read-session-context --repo-root DIR [--get KEY]\n' "$(basename -- "$0")" >&2
        exit 2
    fi
    contract_cache_cli_repo_root=$3
    contract_cache_session_context_read "$contract_cache_cli_repo_root" "${5:-}"
    contract_cache_cli_rc=$?
    if ((contract_cache_cli_rc == 1 || contract_cache_cli_rc == 75)); then
        contract_cache_cli_reason=${CONTRACT_CACHE_SESSION_CONTEXT_REASON:-invalid}
        if [[ $contract_cache_cli_reason == skills-path-mismatch ]]; then
            printf 'contract-cache: session-context %s (cache=%s contract=%s)\n' \
                "$contract_cache_cli_reason" \
                "$(contract_cache_session_path "$contract_cache_cli_repo_root")" \
                "$(contract_cache_contract_file "$contract_cache_cli_repo_root")" >&2
        else
            printf 'contract-cache: session-context %s\n' "$contract_cache_cli_reason" >&2
        fi
    fi
    exit "$contract_cache_cli_rc"
fi
