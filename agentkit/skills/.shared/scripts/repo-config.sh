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
#   repo-config.sh --list            # K=V lines for accepted keys actually declared
#   repo-config.sh --list-keys       # the accepted key set itself, one per line
#   repo-config.sh --canonical-keys K1,K2
#                                    # strict, sorted canonical K=V lines
#   repo-config.sh --resolve KEY ... # one-pass key/value/argv records
# Options:
#   --repo-root DIR                  # skip git-toplevel detection
#   --diagnose                       # report path roots/candidates without rejecting declarations
#
# Exit: 0 success (including no config found), 2 bad usage.
set -euo pipefail

if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
    printf '%s: requires Bash >= 4 (invoked interpreter: %s); run this helper with bash, not zsh\n' \
        "${0##*/}" "${SHELL:-unknown}" >&2
    exit 2
fi

readonly PROGRAM=${0##*/}

warn() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }

die_usage() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    printf 'usage: %s [--repo-root DIR] [--config-file FILE] (--export | --get KEY | --get-argv KEY | --list | --list-keys | --diagnose | --canonical-keys K1,K2 | --resolve KEY ...)\n' "$PROGRAM" >&2
    exit 2
}

readonly ACCEPTED_KEYS=(
    AGENT_REPO_SLUG AGENT_BASE_BRANCH AGENT_PROJECT_OWNER AGENT_PROJECT_NUMBER
    AGENT_STATUS_VOCAB AGENT_ADR_DIR AGENT_BRANCH_PREFIXES AGENT_WORKTREE_ROOT
    AGENT_LABEL_TYPES AGENT_LABEL_AREAS AGENT_LABEL_PRIORITIES
    AGENT_REVIEW_PROVIDERS AGENT_REPO_RUNNER AGENT_PROTECTED_PATHS
    AGENT_GENERATED_PATHS AGENT_ONBOARDED_BY
    AGENT_WORKER_MODEL AGENT_WORKER_MODEL_FALLBACK AGENT_WORKER_EFFORT
    AGENT_ADVERSARIAL_REVIEWER AGENT_ADVERSARIAL_REVIEW_MODEL
    AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK AGENT_ADVERSARIAL_REVIEW_EFFORT
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
config_file_opt=''
canonical_keys_csv=''
declare -a resolve_keys=()
declare -A resolve_requested_keys=()

while (($#)); do
    case $1 in
        --export) mode='export' ;;
        --list) mode='list' ;;
        --list-keys) mode='keys' ;;
        --diagnose) mode='diagnose' ;;
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
        --canonical-keys)
            mode='canonical'
            shift
            (($#)) || die_usage '--canonical-keys requires a comma-separated KEY list'
            canonical_keys_csv=$1
            ;;
        --resolve)
            mode='resolve'
            shift
            (($#)) || die_usage '--resolve requires at least one KEY'
            resolve_keys+=("$1")
            ;;
        --config-file)
            shift
            (($#)) || die_usage '--config-file requires a file'
            config_file_opt=$1
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

[[ -n $mode ]] || die_usage 'one of --export, --get, --list, --list-keys, --diagnose, --canonical-keys, or --resolve is required'

# The accepted key set is schema, not a fact about any one repository -- print
# it and exit before any repo-root/config-file resolution, so it works the
# same with no arguments as it does pointed at a repo with no config yet.
if [[ $mode == keys ]]; then
    printf '%s\n' "${ACCEPTED_KEYS[@]}"
    printf 'AGENT_CMD_<NAME>\n'
    printf 'AGENT_RUNDIR_<NAME>\n'
    exit 0
fi

if [[ $mode == resolve ]]; then
    for key in "${resolve_keys[@]}"; do
        resolve_requested_keys[$key]=yes
    done
fi

if [[ -z $repo_root ]]; then
    repo_root=$(git rev-parse --show-toplevel 2> /dev/null || true)
fi
[[ -n $repo_root ]] || exit 0
repo_root=$(cd -- "$repo_root" 2> /dev/null && pwd -P) || exit 0

config_file=${config_file_opt:-$repo_root/.agent/config.env}
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

# Repository-relative path prefixes used to identify generated artifacts. The
# values are data, never shell patterns: a trailing slash is documentation for
# a directory prefix, and each item must remain inside the repository.
generated_paths_valid() {
    local item
    [[ -n $1 && $1 != ,* && $1 != *, && $1 != *,,* ]] || return 1
    local -a items=()
    IFS=, read -ra items <<< "$1"
    ((${#items[@]})) || return 1
    for item in "${items[@]}"; do
        safe_relpath "$item" || return 1
    done
}

# Mirrors lib/review-provider-catalog.sh's REVIEW_PROVIDER_NAMES, for warning
# text only. Kept as a local literal rather than sourcing that file: this
# parser is deliberately self-contained (see the file header) so a missing or
# broken lib file can never turn one bad declaration into a hard failure for
# every accepted key. test-repo-config.sh pins this against the catalog.
readonly REVIEW_PROVIDER_ACCEPTED_NAMES=(coderabbit github-code-quality none)

providers_display() {
    local out='' name
    for name in "${REVIEW_PROVIDER_ACCEPTED_NAMES[@]}"; do
        out+="${out:+, }$name"
    done
    printf '%s' "$out"
}

providers_valid() {
    local item saw_none=0 seen_coderabbit=0 seen_code_quality=0
    [[ -n $1 && $1 != ,* && $1 != *, && $1 != *,,* ]] || return 1
    local -a items=()
    IFS=, read -ra items <<< "$1"
    ((${#items[@]})) || return 1
    for item in "${items[@]}"; do
        case $item in
            coderabbit)
                ((saw_none == 0 && seen_coderabbit == 0)) || return 1
                seen_coderabbit=1
                ;;
            github-code-quality)
                ((saw_none == 0 && seen_code_quality == 0)) || return 1
                seen_code_quality=1
                ;;
            none)
                ((saw_none == 0 && ${#items[@]} == 1)) || return 1
                saw_none=1
                ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# Worker model IDs are policy input for the spawn contract. Keep the resolver
# responsible for a safe, single-token value without hardcoding today's
# supported model names here: an unsupported value must remain visible to the
# explicit-authorization gate instead of silently becoming the default.
worker_model_valid() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]]
}

# The adversarial reviewer is one of exactly two CLIs adversarial-run.sh knows
# how to launch -- unlike a worker model id, this is a closed set, not open
# policy input, so an unsupported spelling is refused outright rather than
# kept visible for a later authorization gate.
readonly ADVERSARIAL_REVIEWER_ACCEPTED_NAMES=(codex claude)

# Mirrors codex-adversarial-review.sh / claude-adversarial-review.sh's own
# `--effort` enum (no `ultra`): a value AGENT_WORKER_EFFORT would accept but
# the adversarial helpers reject would pass here and only fail at launch,
# after consent and diff construction already ran.
readonly ADVERSARIAL_REVIEW_EFFORT_ACCEPTED_NAMES=(low medium high xhigh max)

names_display() {
    local out='' name
    for name in "$@"; do
        out+="${out:+, }$name"
    done
    printf '%s' "$out"
}

adversarial_reviewer_valid() {
    local item
    for item in "${ADVERSARIAL_REVIEWER_ACCEPTED_NAMES[@]}"; do
        [[ $item == "$1" ]] && return 0
    done
    return 1
}

adversarial_review_effort_valid() {
    local item
    for item in "${ADVERSARIAL_REVIEW_EFFORT_ACCEPTED_NAMES[@]}"; do
        [[ $item == "$1" ]] && return 0
    done
    return 1
}

# Resolve a relative path from BASE and prove the physical result stays inside
# the repository. Resolution is physical, not lexical: readlink -f follows
# symlinks, so a committed symlink pointing outside is caught as surely as a
# `..` traversal. Prints the resolved path.
resolve_contained_from() {
    local base=$1 value=$2 resolved
    [[ $value != /* ]] || return 1
    [[ $value != *..* ]] || return 1
    # readlink -f needs the final executable to exist. readlink -m preserves
    # the physical containment check for a not-yet-installed dependency while
    # still resolving any existing symlinks in its parent directories.
    resolved=$(cd -- "$base" 2> /dev/null &&
        (readlink -f -- "$value" 2> /dev/null || readlink -m -- "$value" 2> /dev/null)) || return 1
    [[ -n $resolved && $resolved == "$repo_root"/* ]] || return 1
    printf '%s' "$resolved"
}

resolve_contained() {
    resolve_contained_from "$repo_root" "$1"
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

# Return the physical base used to resolve a command's path-shaped argv[0].
# value_by_key is populated for the complete config before the deferred command
# validation pass, so command/rundir lines are valid in either order.
command_resolution_root() {
    local key=$1 rundir_key rundir
    rundir_key="AGENT_RUNDIR_${key#AGENT_CMD_}"
    if [[ -n ${value_by_key[$rundir_key]+yes} ]]; then
        rundir=${value_by_key[$rundir_key]}
        # A fresh checkout may carry the declaration before the component
        # itself or its dependencies exist. In that case retain the historical
        # root-based containment check; agent-run.sh will reject a missing
        # execution directory when the command is actually selected.
        if [[ -d $repo_root/$rundir ]]; then
            resolve_contained "$rundir" || return 1
        else
            printf '%s' "$repo_root"
        fi
    else
        printf '%s' "$repo_root"
    fi
}

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
    # A component-rundir command commonly starts with `.venv/` or `./`; the
    # later containment check still rejects absolute and escaping paths.
    [[ ${PARSED_ARGV[0]} == [[:alnum:]_]* ||
        ${PARSED_ARGV[0]} == .*/* ]] || return 1
}

safe_argv() {
    local value=$1 key=${2:-} argv0 resolution_root
    parse_argv "$value" || return 1
    argv0=${PARSED_ARGV[0]}
    # A declaration says where the command will live, not that dependencies
    # have already been installed. Keep the boundary to containment only so a
    # fresh clone can carry node_modules/.bin/* declarations through bootstrap.
    [[ $argv0 != */* ]] && return 0
    resolution_root=$repo_root
    if [[ $key =~ ^AGENT_CMD_ ]]; then
        resolution_root=$(command_resolution_root "$key") || return 1
    fi
    resolve_contained_from "$resolution_root" "$argv0" > /dev/null || return 1
    return 0
}

# All repository-declared command variants, including focused test commands,
# share one argv boundary validator. A path-shaped executable must resolve
# inside this repository; bare names remain PATH lookups.
command_value_valid() {
    safe_argv "$1" "${2:-}"
}

# Explain path-shaped declaration failures at the boundary where they are
# rejected. The root and candidate make staging mistakes distinguishable from
# genuinely bad declarations, while the reason tells an operator the smallest
# repair. Bare PATH commands deliberately have no candidate to report.
path_validation_diagnostic() {
    local key=$1 value=$2 argv0='' candidate='' reason='' resolution_root=$repo_root
    case $key in
        AGENT_REPO_RUNNER) argv0=$value ;;
        AGENT_CMD_*)
            if parse_argv "$value" 2> /dev/null; then
                argv0=${PARSED_ARGV[0]:-}
            else
                # Preserve a path-shaped first token even when the ordinary
                # argv grammar rejects it (notably an absolute path), so the
                # diagnostic can still explain the containment failure.
                argv0=${value%%[[:space:]]*}
                argv0=${argv0#\"}; argv0=${argv0%\"}
                argv0=${argv0#\'}; argv0=${argv0%\'}
            fi
            ;;
        *) return 0 ;;
    esac
    [[ $argv0 == */* || $argv0 == /* ]] || return 0

    if [[ $argv0 == /* ]]; then
        candidate=$(readlink -f -- "$argv0" 2> /dev/null ||
            readlink -m -- "$argv0" 2> /dev/null || printf '%s' "$argv0")
    else
        if [[ $key =~ ^AGENT_CMD_ ]]; then
            resolution_root=$(command_resolution_root "$key" 2> /dev/null ||
                printf '%s' "$repo_root")
        fi
        candidate=$(cd -- "$resolution_root" 2> /dev/null &&
            (readlink -f -- "$argv0" 2> /dev/null || readlink -m -- "$argv0" 2> /dev/null) || true)
    fi
    [[ -n $candidate ]] || candidate="$repo_root/$argv0"

    if [[ $candidate != "$repo_root"/* ]]; then
        reason='containment escape'
    elif [[ ! -e $candidate && ! -L $candidate ]]; then
        reason='missing'
    elif [[ ! -f $candidate || ! -x $candidate ]]; then
        reason='non-executable'
    else
        return 0
    fi
    warn "path validation for $key: resolution root: $resolution_root; resolved candidate: $candidate; failure: $reason"
}

# A path-shaped command token is interpreted by exec from the command's
# working directory. Checking only from the repository root lets
# `tools/check` pass while `AGENT_RUNDIR_COMPONENT=component` later executes
# `component/tools/check` and fails with rc=127 after approval. A missing
# dependency is still allowed on a fresh clone; warn only when the root-based
# candidate exists and the rundir-based candidate does not.
rundir_path_diagnostic() {
    local key=$1 value=$2 rundir_key rundir argv0 root_candidate rundir_candidate
    [[ $key =~ ^AGENT_CMD_ ]] || return 0
    rundir_key="AGENT_RUNDIR_${key#AGENT_CMD_}"
    [[ -n ${value_by_key[$rundir_key]+yes} ]] || return 0
    rundir=${value_by_key[$rundir_key]}
    [[ -d $repo_root/$rundir ]] || return 0
    parse_argv "$value" 2> /dev/null || return 0
    argv0=${PARSED_ARGV[0]:-}
    [[ $argv0 == */* ]] || return 0
    root_candidate=$(cd -- "$repo_root" 2> /dev/null &&
        (readlink -f -- "$argv0" 2> /dev/null || readlink -m -- "$argv0" 2> /dev/null) || true)
    rundir_candidate=$(cd -- "$repo_root/$rundir" 2> /dev/null &&
        (readlink -f -- "$argv0" 2> /dev/null || readlink -m -- "$argv0" 2> /dev/null) || true)
    [[ -n $root_candidate && -n $rundir_candidate ]] || return 0
    [[ -e $root_candidate || -L $root_candidate ]] || return 0
    [[ ! -e $rundir_candidate && ! -L $rundir_candidate ]] || return 0
    if [[ $mode != resolve || -n ${resolve_requested_keys[$key]+yes} ]]; then
        rundir_mismatch_requested=1
    fi
    warn "rundir-relative argv[0] mismatch for $key: '$argv0' resolves from repository root '$repo_root' to '$root_candidate', but from declared rundir '$repo_root/$rundir' to missing '$rundir_candidate'; fix $key to use a path relative to '$repo_root/$rundir' (or move the executable); do not add a literal twin to route around approval"
}

validate() {
    local key=$1 value=$2
    case $key in
        AGENT_REPO_SLUG) [[ $value =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ;;
        AGENT_ONBOARDED_BY) [[ $value =~ ^agentkit/[A-Za-z0-9._:-]+$ ]] ;;
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
        AGENT_GENERATED_PATHS) generated_paths_valid "$value" ;;
        AGENT_REVIEW_PROVIDERS) providers_valid "$value" ;;
        AGENT_WORKER_MODEL | AGENT_WORKER_MODEL_FALLBACK) worker_model_valid "$value" ;;
        AGENT_WORKER_EFFORT)
            [[ $value == low || $value == medium || $value == high ||
                $value == xhigh || $value == max || $value == ultra ]]
            ;;
        AGENT_ADVERSARIAL_REVIEWER) adversarial_reviewer_valid "$value" ;;
        AGENT_ADVERSARIAL_REVIEW_MODEL | AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK)
            worker_model_valid "$value"
            ;;
        AGENT_ADVERSARIAL_REVIEW_EFFORT) adversarial_review_effort_valid "$value" ;;
        AGENT_REPO_RUNNER) runner_contained "$value" ;;
        AGENT_CMD_TEST_FOCUS)
            command_value_valid "$value" "$key" || return 1
            # The focused selector is interpolated into every occurrence of
            # %s. argv[0] is executable data, so accepting the placeholder
            # there would turn a suite name into the command path.
            [[ ${PARSED_ARGV[0]} != *%s* ]]
            ;;
        *)
            if [[ $key =~ $RUNDIR_KEY_PATTERN ]]; then
                safe_relpath "$value"
                return
            fi
            [[ $key =~ $CMD_KEY_PATTERN ]] || return 1
            command_value_valid "$value" "$key"
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
declare -A value_by_key=() seen_by_key=()
declare -A invalid_command_keys=() checked_command_keys=()
# Canonical comparison is strict for every parse error. Resolve mode keeps the
# established warn/drop behavior for the file as a whole, but tracks whether a
# parse error occurred so a caller reading __AGENT_CONFIG_PARSE_STATUS__ below
# (e.g. review-provider-config.sh) can tell "this failed to parse" apart from
# "this was never declared" without a second read of the config file.
parse_failed=0
rundir_mismatch_requested=0
lineno=0

while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue

    if [[ $line != *=* ]]; then
        warn "line $lineno has no equals sign, ignoring"
        malformed_key=$(trim "$line")
        [[ $mode == resolve && -n ${resolve_requested_keys[$malformed_key]+yes} ]] && parse_failed=1
        [[ $mode == canonical ]] && parse_failed=1
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
            warn "unknown key on line $lineno, ignoring: $key (run '$PROGRAM --list-keys' to see the accepted keys)"
        fi
        # Unknown keys are deliberately dropped. In resolve mode they are not
        # relevant to the requested declaration set.
        [[ $mode == canonical ]] && parse_failed=1
        continue
    fi

    if [[ ! $key =~ ^AGENT_CMD_ ]] && ! validate "$key" "$value"; then
        path_validation_diagnostic "$key" "$value"
        # An empty value is the one rejection that looks like a deliberate
        # statement rather than a mistake -- "this repository has no priority
        # labels" is a real thing to want to record. Saying only "invalid"
        # leaves the writer guessing at what a valid empty list looks like;
        # there isn't one, and a comment is how you say it.
        if [[ -z $value ]]; then
            warn "empty value for $key on line $lineno, ignoring -- to record that this repository has none, comment the line out instead"
        elif [[ $key == AGENT_REVIEW_PROVIDERS ]]; then
            warn "invalid value for $key on line $lineno, ignoring -- accepted: $(providers_display)"
        elif [[ $key == AGENT_ADVERSARIAL_REVIEWER ]]; then
            warn "invalid value for $key on line $lineno, ignoring -- accepted: $(names_display "${ADVERSARIAL_REVIEWER_ACCEPTED_NAMES[@]}")"
        elif [[ $key == AGENT_ADVERSARIAL_REVIEW_EFFORT ]]; then
            warn "invalid value for $key on line $lineno, ignoring -- accepted: $(names_display "${ADVERSARIAL_REVIEW_EFFORT_ACCEPTED_NAMES[@]}")"
        else
            warn "invalid value for $key on line $lineno, ignoring"
        fi
        [[ $mode == canonical ||
            ( $mode == resolve && -n ${resolve_requested_keys[$key]+yes} ) ]] && parse_failed=1
        continue
    fi

    # Validity and diagnostics are intentionally separate. A missing or
    # non-executable dependency is a truthful fresh-clone declaration, while
    # --diagnose lets an operator audit the candidate against this root.
    if [[ $mode == diagnose && ! $key =~ ^AGENT_CMD_ ]]; then
        path_validation_diagnostic "$key" "$value"
    fi

    # Existing readers resolve the first accepted occurrence. Preserve that
    # behavior while retaining a key-indexed view for canonical output.
    if [[ -z ${seen_by_key[$key]+yes} ]]; then
        seen_by_key[$key]=yes
        value_by_key[$key]=$value
    fi
    out_keys+=("$key")
    out_values+=("$value")
done < "$config_file"

# Command lines are emitted before their companion rundir lines. Revalidate
# after the complete file is parsed so the command's path boundary uses the
# same rundir that agent-run.sh will use, regardless of declaration order.
for key in "${out_keys[@]}"; do
    [[ $key =~ ^AGENT_CMD_ ]] || continue
    [[ -n ${checked_command_keys[$key]+yes} ]] && continue
    checked_command_keys[$key]=yes
    value=${value_by_key[$key]}
    if ! validate "$key" "$value"; then
        path_validation_diagnostic "$key" "$value"
        if [[ -z $value ]]; then
            warn "empty value for $key, ignoring -- to record that this repository has none, comment the line out instead"
        else
            warn "invalid value for $key, ignoring"
        fi
        invalid_command_keys[$key]=yes
        [[ $mode == canonical ||
            ( $mode == resolve && -n ${resolve_requested_keys[$key]+yes} ) ]] && parse_failed=1
    elif [[ $mode == diagnose ]]; then
        path_validation_diagnostic "$key" "$value"
    fi
done

if ((${#invalid_command_keys[@]})); then
    declare -a filtered_keys=() filtered_values=()
    for i in "${!out_keys[@]}"; do
        key=${out_keys[$i]}
        [[ -n ${invalid_command_keys[$key]+yes} ]] && continue
        filtered_keys+=("$key")
        filtered_values+=("${out_values[$i]}")
    done
    out_keys=("${filtered_keys[@]}")
    out_values=("${filtered_values[@]}")
    for key in "${!invalid_command_keys[@]}"; do
        unset "value_by_key[$key]" "seen_by_key[$key]"
    done
fi

# Run after the whole file is parsed so command/rundir declarations may appear
# in either order. Bootstrap treats this warning as a write-time validation
# failure; ordinary listing still shows the declarations and the precise fix.
if ((${#out_keys[@]})); then
    for key in "${out_keys[@]}"; do
        if [[ $key =~ ^AGENT_CMD_ ]]; then
            rundir_path_diagnostic "$key" "${value_by_key[$key]}"
        fi
    done
fi

if [[ $mode == canonical ]] && ((parse_failed)); then
    exit 1
fi

case $mode in
    export)
        for i in "${!out_keys[@]}"; do
            printf 'export %s=%s\n' "${out_keys[$i]}" "$(shell_quote "${out_values[$i]}")"
        done
        ;;
    list | diagnose)
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
    canonical)
        declare -a requested_keys=() canonical_lines=()
        IFS=, read -ra requested_keys <<< "$canonical_keys_csv"
        for key in "${requested_keys[@]}"; do
            [[ -n $key ]] || continue
            is_accepted "$key" || {
                warn "invalid canonical key: $key"
                exit 1
            }
            if [[ -n ${seen_by_key[$key]+yes} ]]; then
                canonical_lines+=("$key=${value_by_key[$key]}")
            fi
        done
        if ((${#canonical_lines[@]})); then
            printf '%s\n' "${canonical_lines[@]}" | LC_ALL=C sort -t= -k1,1
        fi
        ;;
    resolve)
        local_key=''
        for local_key in "${resolve_keys[@]}"; do
            is_accepted "$local_key" || {
                warn "invalid resolve key: $local_key"
                exit 1
            }
            [[ -n ${seen_by_key[$local_key]+yes} ]] || continue
            value=${value_by_key[$local_key]}
            if [[ $local_key =~ $CMD_KEY_PATTERN ]]; then
                parse_argv "$value" || exit 1
                printf '%s\0%s\0%s\0' "$local_key" "$value" "${#PARSED_ARGV[@]}"
                printf '%s\0' "${PARSED_ARGV[@]}"
            else
                printf '%s\0%s\0%s\0' "$local_key" "$value" 0
            fi
        done
        # Resolution remains warn/drop/fall-through for ordinary callers. This
        # marker lets a caller such as review-provider-config.sh distinguish a
        # parse failure from an undeclared key and fail closed accordingly.
        # agent-run.sh has no invocation gate over this marker any more (that
        # gate governed command approval and was removed with the fence): it
        # validates the marker's format and discards it. Its own fail-closed
        # behavior for the REQUESTED command instead falls out of
        # resolved_config_present staying unset when that command's config
        # line failed to parse, since resolve mode never emits a key it
        # could not parse.
        printf '__AGENT_CONFIG_PARSE_STATUS__\0%s\0' "$parse_failed"
        ((rundir_mismatch_requested)) && printf '__AGENT_CONFIG_RUNDIR_MISMATCH__\0yes\0'
        ;;
esac

exit 0
