#!/usr/bin/env bash
# Resolve repository-declared agent facts from <git-toplevel>/.agent/config.env.
#
# This is the ONLY reader of that file. It is parsed line-wise against a key
# whitelist and is NEVER sourced: a committed file in a shared repository is
# reachable by anyone who can open a pull request, so treating it as shell would
# make it an injection vector into every agent's environment.
#
# Anything missing, malformed, or unrecognized is dropped with a warning and the
# caller falls through to live discovery. This script never blocks a run.
#
# Usage:
#   repo-config.sh --export          # `export K='V'` lines, safe to eval
#   repo-config.sh --get KEY         # one value; exit 1 if absent
#   repo-config.sh --get-argv KEY    # parsed argv, NUL-delimited; exit 1 if absent
#   repo-config.sh --list            # K=V lines for accepted keys
# Options:
#   --repo-root DIR                  # skip git-toplevel detection
#
# Exit: 0 success (including no config found), 2 bad usage.
set -euo pipefail

readonly PROGRAM=${0##*/}

warn() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }

die_usage() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    printf 'usage: %s [--repo-root DIR] (--export | --get KEY | --get-argv KEY | --list)\n' "$PROGRAM" >&2
    exit 2
}

readonly ACCEPTED_KEYS=(
    AGENT_REPO_SLUG AGENT_BASE_BRANCH AGENT_PROJECT_OWNER AGENT_PROJECT_NUMBER
    AGENT_STATUS_VOCAB AGENT_ADR_DIR AGENT_BRANCH_PREFIXES AGENT_WORKTREE_ROOT
    AGENT_LABEL_TYPES AGENT_LABEL_AREAS AGENT_LABEL_PRIORITIES
    AGENT_REVIEW_PROVIDERS AGENT_REPO_RUNNER AGENT_PROTECTED_PATHS
)

# AGENT_CMD_<NAME> is open-ended by design. A fixed five (VERIFY, TEST, LINT,
# TYPECHECK, BUILD) fits a single-component repository and fails a monorepo: a
# real one produced fourteen useful per-component commands -- backend lint,
# dashboard typecheck, bridge tests -- and had to discard eleven of them to fit
# the schema, so the contract recorded less than the repository actually knew.
#
# The NAME is what `agent-run.sh --cmd <name>` takes, so it is constrained to a
# shape that survives being lowercased into a filename and an argument.
readonly CMD_KEY_PATTERN='^AGENT_CMD_[A-Z][A-Z0-9_]*$'

# The directory a named command runs in. Paths may contain spaces and are
# quoted in generated config. Values are argv executed from the
# repository root, which suits a single-component repo and breaks a monorepo:
# asked to declare a dashboard test command, an agent produced a root-run
# invocation that globbed into node_modules and started running a DEPENDENCY's
# test suite. The command was correct; the working directory was not
# expressible.
#
# A separate key rather than a prefix inside the value, so the command's argv
# grammar stays independent from the working-directory path.
readonly RUNDIR_KEY_PATTERN='^AGENT_RUNDIR_[A-Z][A-Z0-9_]*$'

# Credential-shaped keys are refused loudly rather than ignored quietly, so a
# misguided commit is visible instead of silently honored.
readonly SECRET_PATTERN='(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|PROXY|CA_BUNDLE|CERT|APIKEY|API_KEY|PRIVATE_KEY)$|^(GH|GITHUB)_'

mode=''
want_key=''
repo_root=''

while (($#)); do
    case $1 in
        --export) mode='export' ;;
        --list) mode='list' ;;
        --get)
            mode='get'
            shift
            (($#)) || die_usage '--get requires a KEY'
            want_key=$1
            ;;
        --get-argv)
            mode='argv'
            shift
            (($#)) || die_usage '--get-argv requires a KEY'
            want_key=$1
            ;;
        --repo-root)
            shift
            (($#)) || die_usage '--repo-root requires a directory'
            repo_root=$1
            ;;
        -h | --help) die_usage 'help requested' ;;
        *) die_usage "unknown argument: $1" ;;
    esac
    shift
done

[[ -n $mode ]] || die_usage 'one of --export, --get, --list is required'

if [[ -z $repo_root ]]; then
    repo_root=$(git rev-parse --show-toplevel 2> /dev/null || true)
fi
[[ -n $repo_root ]] || exit 0

config_file="$repo_root/.agent/config.env"
[[ -f $config_file ]] || exit 0

is_accepted() {
    local candidate=$1 key
    # Credential-shaped names are refused BEFORE the open-ended command pattern
    # can accept them. Opening AGENT_CMD_<NAME> to arbitrary names made
    # AGENT_CMD_GH_TOKEN a legal key -- exactly the hole the secret check exists
    # to close, reopened by the change that made monorepos work. Order matters
    # here, and only a test that asked for the hole by name caught it.
    [[ ! $candidate =~ $SECRET_PATTERN ]] || return 1
    [[ ! $candidate =~ $CMD_KEY_PATTERN ]] || return 0
    [[ ! $candidate =~ $RUNDIR_KEY_PATTERN ]] || return 0
    for key in "${ACCEPTED_KEYS[@]}"; do
        [[ $key == "$candidate" ]] && return 0
    done
    return 1
}

# A relative path that cannot escape the repository.
safe_relpath() {
    local value=$1
    [[ $value != /* ]] || return 1
    [[ $value != *..* ]] || return 1
    [[ $value =~ ^[A-Za-z0-9._/\ -]+$ ]] || return 1
    return 0
}

# Git ref characters only; rejects option-injection and reserved forms.
safe_ref() {
    local value=$1
    [[ $value =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    [[ $value != -* ]] || return 1
    [[ $value != *..* ]] || return 1
    [[ $value != */ ]] || return 1
    [[ $value != *.lock ]] || return 1
    return 0
}

# Comma-separated human labels; spaces allowed ("In progress"), controls not.
# Colons are ordinary in real label vocabularies -- `phase:v1`, `area:api`,
# `priority:p0` -- and excluding them rejected a repository's actual labels,
# which is the one thing this key exists to record. Still no shell
# metacharacters: these values are interpolated into forge queries.
safe_list() {
    [[ $1 =~ ^[A-Za-z0-9\ ._:/-]+(,[A-Za-z0-9\ ._:/-]+)*$ ]]
}

providers_valid() {
    local item
    local -a items=()
    IFS=, read -ra items <<< "$1"
    ((${#items[@]})) || return 1
    for item in "${items[@]}"; do
        case $item in
            coderabbit | github-code-quality | none) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# Resolve a repository-relative path against the repository root and prove the
# result stays inside it. Resolution is physical, not lexical: readlink -f
# follows symlinks, so a committed symlink pointing outside is caught as surely
# as a `..` traversal. Prints the resolved path.
resolve_contained() {
    local value=$1 resolved
    [[ $value != /* ]] || return 1
    [[ $value != *..* ]] || return 1
    resolved=$(cd -- "$repo_root" 2> /dev/null && readlink -f -- "$value" 2> /dev/null) || return 1
    [[ -n $resolved && $resolved == "$repo_root"/* ]] || return 1
    printf '%s' "$resolved"
}

# The key naming a runner. agent-run.sh already executes
# <git-toplevel>/.agent/runner, so this is not new exposure -- but the bare
# convention had no containment check, and this adds one.
runner_contained() {
    local resolved
    safe_relpath "$1" || return 1
    resolved=$(resolve_contained "$1") || return 1
    [[ -f $resolved && -x $resolved ]] || return 1
    return 0
}

# A command line expressed as safe, shell-like argv. Quotes only group spaces;
# they are not evaluated, and no shell syntax or escaping is accepted. The
# parsed array is also the source for --get-argv, so validation and execution
# cannot disagree about where an argument begins.
#
# argv[0] is an executable this repository points at -- the same capability
# AGENT_REPO_RUNNER grants -- so it gets the same containment. A bare name is a
# PATH lookup and stays one; a name carrying a slash is a path, and a path must
# resolve inside the repository. Without this, `tools/../../outside/payload`
# reaches exec through a key with no check at all.
declare -a PARSED_ARGV=()

legacy_argv_value() {
    local value=$1 quote i
    [[ ${value:0:1} == '"' || ${value:0:1} == "'" ]] || {
        printf '%s' "$value"
        return
    }
    quote=${value:0:1}
    for ((i = 1; i < ${#value}; i++)); do
        [[ ${value:i:1} == "$quote" ]] || continue
        if [[ $i -eq $((${#value} - 1)) ]]; then
            printf '%s' "${value:1:${#value}-2}"
        else
            printf '%s' "$value"
        fi
        return
    done
    printf '%s' "$value"
}

safe_token() {
    local token=$1 char i
    for ((i = 0; i < ${#token}; i++)); do
        char=${token:i:1}
        case $char in
            [[:alnum:]]|_|.|/|=|@|:|,|'?'|'*'|'%'|' '|-) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

parse_argv() {
    local value=$1 char quote='' token='' started=0 i
    PARSED_ARGV=()
    [[ -n $value ]] || return 1
    value=$(legacy_argv_value "$value")
    [[ -n $value ]] || return 1

    for ((i = 0; i < ${#value}; i++)); do
        char=${value:i:1}
        if [[ -n $quote ]]; then
            if [[ $char == "$quote" ]]; then
                quote=''
                started=1
                continue
            fi
            [[ $char != $'\n' && $char != $'\t' ]] || return 1
            if [[ $char == ' ' ]]; then
                token+=$char
                continue
            fi
        else
            case $char in
                \" | \')
                    quote=$char
                    started=1
                    continue
                    ;;
                ' ')
                    if ((started)); then
                        safe_token "$token" || return 1
                        PARSED_ARGV+=("$token")
                        token=''
                        started=0
                    fi
                    continue
                    ;;
            esac
        fi

        case $char in
            [[:alnum:]_./=@:,?*%-]) token+=$char ;;
            *) return 1 ;;
        esac
        started=1
    done

    [[ -z $quote ]] || return 1
    if ((started)); then
        safe_token "$token" || return 1
        PARSED_ARGV+=("$token")
    fi
    ((${#PARSED_ARGV[@]})) || return 1
    [[ ${PARSED_ARGV[0]} == [[:alnum:]_]* ]] || return 1
}

safe_argv() {
    local argv0
    parse_argv "$1" || return 1
    argv0=${PARSED_ARGV[0]}
    [[ $argv0 != */* ]] || resolve_contained "$argv0" > /dev/null || return 1
    return 0
}

# All repository-declared command variants, including focused test commands,
# share one argv boundary validator. A path-shaped executable must resolve
# inside this repository; bare names remain PATH lookups.
command_value_valid() {
    safe_argv "$1"
}

validate() {
    local key=$1 value=$2
    case $key in
        AGENT_REPO_SLUG) [[ $value =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ;;
        AGENT_PROJECT_OWNER) [[ $value =~ ^[A-Za-z0-9._-]+$ ]] ;;
        AGENT_PROJECT_NUMBER) [[ $value =~ ^[0-9]{1,6}$ ]] ;;
        AGENT_BASE_BRANCH) safe_ref "$value" ;;
        AGENT_ADR_DIR | AGENT_WORKTREE_ROOT) safe_relpath "$value" ;;
        AGENT_BRANCH_PREFIXES) [[ $value =~ ^[a-z]+(,[a-z]+)*$ ]] ;;
        AGENT_STATUS_VOCAB | AGENT_LABEL_TYPES | AGENT_LABEL_AREAS | AGENT_LABEL_PRIORITIES)
            safe_list "$value"
            ;;
        # Additive only: a repository may extend the protected set, never shrink
        # it, so a committed file cannot switch off its own guard.
        AGENT_PROTECTED_PATHS)
            safe_list "$value" && [[ $value != *..* && $value != /* && $value != *,/* ]]
            ;;
        AGENT_REVIEW_PROVIDERS) providers_valid "$value" ;;
        AGENT_REPO_RUNNER) runner_contained "$value" ;;
        AGENT_CMD_TEST_FOCUS)
            command_value_valid "$value"
            ;;
        *)
            if [[ $key =~ $RUNDIR_KEY_PATTERN ]]; then
                safe_relpath "$value"
                return
            fi
            [[ $key =~ $CMD_KEY_PATTERN ]] || return 1
            command_value_valid "$value"
            ;;
    esac
}

trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

unquote() {
    local value=$1
    if ((${#value} >= 2)); then
        if [[ ${value:0:1} == '"' && ${value: -1} == '"' ]]; then
            value=${value:1:${#value}-2}
        elif [[ ${value:0:1} == "'" && ${value: -1} == "'" ]]; then
            value=${value:1:${#value}-2}
        fi
    fi
    printf '%s' "$value"
}

# Single-quote for eval. Chosen over printf %q because %q renders a space as
# "\ ", which is correct but unreadable in a block an agent has to scan.
shell_quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

declare -a out_keys=() out_values=()
lineno=0

while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue

    if [[ $line != *=* ]]; then
        warn "line $lineno has no equals sign, ignoring"
        continue
    fi

    key=$(trim "${line%%=*}")
    value=$(trim "${line#*=}")
    if [[ ! $key =~ $CMD_KEY_PATTERN ]]; then
        value=$(unquote "$value")
    fi

    if ! is_accepted "$key"; then
        if [[ $key =~ $SECRET_PATTERN ]]; then
            warn "refusing credential-shaped key on line $lineno: $key"
        else
            warn "unknown key on line $lineno, ignoring: $key"
        fi
        continue
    fi

    if ! validate "$key" "$value"; then
        # An empty value is the one rejection that looks like a deliberate
        # statement rather than a mistake -- "this repository has no priority
        # labels" is a real thing to want to record. Saying only "invalid"
        # leaves the writer guessing at what a valid empty list looks like;
        # there isn't one, and a comment is how you say it.
        if [[ -z $value ]]; then
            warn "empty value for $key on line $lineno, ignoring -- to record that this repository has none, comment the line out instead"
        else
            warn "invalid value for $key on line $lineno, ignoring"
        fi
        continue
    fi

    out_keys+=("$key")
    out_values+=("$value")
done < "$config_file"

case $mode in
    export)
        for i in "${!out_keys[@]}"; do
            printf 'export %s=%s\n' "${out_keys[$i]}" "$(shell_quote "${out_values[$i]}")"
        done
        ;;
    list)
        for i in "${!out_keys[@]}"; do
            printf '%s=%s\n' "${out_keys[$i]}" "${out_values[$i]}"
        done
        ;;
    get)
        for i in "${!out_keys[@]}"; do
            if [[ ${out_keys[$i]} == "$want_key" ]]; then
                printf '%s\n' "${out_values[$i]}"
                exit 0
            fi
        done
        exit 1
        ;;
    argv)
        for i in "${!out_keys[@]}"; do
            if [[ ${out_keys[$i]} == "$want_key" ]]; then
                parse_argv "${out_values[$i]}" || exit 1
                printf '%s\0' "${PARSED_ARGV[@]}"
                exit 0
            fi
        done
        exit 1
        ;;
esac

exit 0
