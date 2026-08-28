#!/usr/bin/env bash
# agent-run.sh -- run ONE command with a correct, sandbox-safe environment.
#
# Shell state does not persist between an agent's tool calls, so without this wrapper
# every invocation re-exports cache dirs, CA bundles and PYTHONPATH by hand (and
# silently fails when it forgets), guesses the right cwd for node tooling, then burns
# an extra turn grepping a log after a failure. Here that is all procedural.
#
# A repository-declared command runner always wins (reuse before reinventing):
# $AGENT_REPO_RUNNER, else the same key in <git-toplevel>/.agent/config.env, else
# the first line of <git-toplevel>/.agent/runner resolved relative to the git
# toplevel, else none. All are conventions this skill defines -- a repository opts
# in; no vendor or company tool path is ever probed for. It is exec'd as
# `runner <command> [args]` in the resolved working directory, with the prepared
# environment (plus AGENT_RUN_LABEL) already exported.
#
# --cmd NAME names a command instead of spelling one out, so a caller never has to
# know the repository's ecosystem: the repository declares what "test" means as
# AGENT_CMD_TEST in .agent/config.env, else its runner is invoked as `runner test`.
#
# Usage: agent-run.sh [--dir PATH] [--label NAME] [--resolve NAME]
#          [--baseline-ref REF --baseline-path PATH --baseline-id ID]
#          (--cmd NAME | [--] <command> ...)
# Exit status: 0 when the wrapped command passes or a proven baseline exclusion is
# recorded; otherwise the wrapped command's non-zero status (usage errors exit 1).

set -euo pipefail

if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
    printf '%s: requires Bash >= 4 (invoked interpreter: %s); run this helper with bash, not zsh\n' \
        "${0##*/}" "${SHELL:-unknown}" >&2
    exit 2
fi

usage() {
    cat <<'EOF'
Usage: agent-run.sh [--dir PATH] [--label NAME] [--resolve NAME] [--force] [--only NAME[,NAME...]]
                    [--baseline-ref REF --baseline-path PATH --baseline-id ID]
                    (--cmd NAME | [--] <command> ...)

Runs one command with a sandbox-safe environment and a compact result summary.
  --dir PATH     Working directory for the command (default: current directory).
  --label NAME   Label used in the log file name (default: the command's basename).
  --force        Execute a named command even when green evidence is current.
  --only NAME[,NAME...]  For --cmd test, use the repository's
                 AGENT_CMD_TEST_FOCUS declaration and pass names through its %s placeholder.
  --baseline-ref REF  On a failed verification, compare against this chain-base ref.
  --baseline-path PATH  Failing test file whose blob must be unchanged at the base.
  --baseline-id ID  Stable test/check identifier recorded in baseline-exclusion.md.
  --if-declared  With --cmd, exit 0 quietly when the repository declares no such
                 command. For a command a skill treats as optional.
  --resolve NAME Query a named command without executing it. Prints declared,
                 runner, or unresolved and exits 0, 4, or 3 respectively; exit 2
                 is reserved for a fatal unsupported-interpreter guard.
  --cmd NAME     Run the command this repository declares under that name, instead
                 of spelling one out. Mutually exclusive with a literal command.
  --             End of options; everything after it is the command.
  -h, --help     Show this help and exit 0.

Compose isolation: a deterministic per-worktree COMPOSE_PROJECT_NAME is exported
for declared commands, overriding a repository .env value or a compose-file
top-level name:. A literal -p/--project-name in the declaration outranks that
export, so isolation cannot be established and the run exits 5 without executing.
Serialize full-suite verification and set AGENT_COMPOSE_SERIALIZED=1 to assert no
concurrent full-suite run, or drop the flag from the declaration.

Environment:
  AGENT_CACHE_ROOT    Force cache dirs under this root (otherwise a fallback root
                      is used only when the normal cache home is unusable).
  AGENT_REPO_RUNNER   Path to a repository command runner to delegate to.

Repository declarations (<git-toplevel>/.agent/config.env):
  AGENT_RUNDIR_<NAME> Directory to run that command in, relative to the repo root.
  AGENT_CMD_<NAME>    What `--cmd <name>` runs here. Values are argv: spaces
                      inside single/double quotes stay in one token, then argv
                      is exec'd directly, never through a shell. A path-shaped
                      first token must resolve inside the repository.
  AGENT_REPO_RUNNER   Runner to delegate to, as a repository-relative path.

Output:
  PASS: <cmd> (N lines suppressed -> LOG)
  BASELINE-EXCLUDED: <test/base/log> (exit 0, not green evidence)
  FAIL(rc=N): <cmd>  + context notes + up to 20 error lines + 'full log: LOG'

Examples:
  agent-run.sh --cmd test
  agent-run.sh --dir src/example --cmd lint
  agent-run.sh --label unit -- ./scripts/check --quick
  agent-run.sh --dir src/example --label smoke -- bin/smoke-test
EOF
}

die() {
    printf 'agent-run: error: %s\n' "$1" >&2
    exit 1
}

# ---------------------------------------------------------------- arguments ---
dir_opt=
label=
cmd_name=
resolve_name=
cmd=()
focus_opt=''
focus_requested=0
force_cmd=0
baseline_ref=''
baseline_path=''
baseline_id=''
literal_root_fallback=no
literal_token=''
literal_execution_base=''
literal_repository_base=''
# Set when the command came from an AGENT_CMD_* declaration, which is the whole
# argv and so must not be handed to the runner as a subcommand.
cmd_declared=no
if_declared=0

while (($#)); do
    case $1 in
        --if-declared) if_declared=1; shift ;;
        --force)
            force_cmd=1
            shift
            ;;
        --only)
            (($# >= 2)) || die 'Missing value for --only.'
            focus_requested=1
            focus_opt=$2
            shift 2
            ;;
        --baseline-ref|--baseline-path|--baseline-id|--dir|--label|--cmd|--resolve)
            (($# >= 2)) || die "Missing value for $1."
            case $1 in
                --baseline-ref) baseline_ref=$2 ;;
                --baseline-path) baseline_path=$2 ;;
                --baseline-id) baseline_id=$2 ;;
                --dir) dir_opt=$2 ;;
                --label) label=$2 ;;
                --cmd) cmd_name=$2 ;;
                --resolve) resolve_name=$2 ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            cmd=("$@")
            break
            ;;
        -*)
            die "Unknown option: $1 (use -- before a command that starts with '-')."
            ;;
        *)
            cmd=("$@")
            break
            ;;
    esac
done

if ((focus_requested)); then
    [[ -n $focus_opt ]] || die '--only requires a non-empty value.'
    [[ -n $cmd_name ]] || die '--only requires --cmd test.'
fi

if [[ -n $resolve_name ]]; then
    [[ -z $cmd_name ]] || die '--cmd NAME and --resolve NAME are mutually exclusive.'
    ((${#cmd[@]} == 0)) || die '--resolve NAME and a literal command are mutually exclusive.'
    ((focus_requested == 0)) || die '--resolve NAME cannot be combined with --only.'
    ((force_cmd == 0)) ||
        die '--resolve NAME cannot be combined with execution flags.'
    ((if_declared == 0)) || die '--resolve NAME cannot be combined with --if-declared.'
elif [[ -n $cmd_name ]]; then
    ((${#cmd[@]} == 0)) || die '--cmd NAME and a literal command are mutually exclusive.'
else
    ((${#cmd[@]})) || die 'No command given.'
fi
if ((force_cmd)) && [[ -z $cmd_name ]]; then
    die '--force requires --cmd NAME.'
fi
if [[ -n $baseline_ref || -n $baseline_path || -n $baseline_id ]]; then
    [[ -n $baseline_ref && -n $baseline_path && -n $baseline_id ]] ||
        die '--baseline-ref, --baseline-path, and --baseline-id are required together.'
    [[ $baseline_path != /* && $baseline_path != *$'\n'* && $baseline_path != *$'\r'* ]] ||
        die '--baseline-path must be a relative single-line path.'
    [[ $baseline_id != *$'\n'* && $baseline_id != *$'\r'* && $baseline_id != *'`'* ]] ||
        die '--baseline-id must be a single-line identifier without backticks.'
fi

run_dir=${dir_opt:-$PWD}
[[ -d $run_dir ]] || die "Working directory does not exist: $run_dir"
run_dir=$(cd -- "$run_dir" && pwd -P)
work_dir=$run_dir

notes=()
add_note() { notes+=("$1"); }
refresh_cmd_str() {
    cmd_str=$(printf '%s ' "${cmd[@]}")
    cmd_str=${cmd_str% }
}
git_top=$(git -C "$run_dir" rev-parse --show-toplevel 2>/dev/null || true)

# Both the label and the printable command string are derived from argv, and with
# --cmd there is no argv until the repository has resolved the name -- so they are
# finalised in main, once resolution has happened.
finalise_label() {
    [[ -n $label ]] || label=$(basename -- "${cmd[0]}")
    label=${label//[^A-Za-z0-9._-]/_}
    [[ -n $label ]] || label='cmd'
}

# ------------------------------------------------------------------- caches ---
dir_writable() {
    local d=$1 probe
    [[ -n $d ]] || return 1
    mkdir -p -- "$d" 2>/dev/null || return 1
    probe=$d/.agent-run-probe.$$
    # 2>/dev/null FIRST: redirections apply left to right, so with the order
    # reversed the failing >"$probe" writes to the real stderr before the
    # suppression exists. Under a sandbox with a read-only HOME that printed
    # "Read-only file system" on every single wrapped command.
    : 2>/dev/null >"$probe" || return 1
    rm -f -- "$probe"
}

# Fallback roots under a world-writable /tmp are fully predictable, so another
# uid can pre-create one as a symlink and capture every cache write and command
# log. Refuse anything that is not a real directory this user owns.
assert_private_dir() {
    local d=$1
    [[ -L $d ]] && die "Refusing to use $d: it is a symlink."
    # -m with -p would only apply to the deepest component, so chmod explicitly.
    mkdir -p -- "$d" 2>/dev/null || die "Cannot create directory: $d"
    chmod 700 -- "$d" 2>/dev/null || true
    [[ -d $d && ! -L $d && -O $d ]] ||
        die "Refusing to use $d: not a directory owned by this user."
}

# Respect a caller-provided value that still works; otherwise point at our root.
export_cache_var() {
    local name=$1 path=$2 current=${!1:-}
    [[ -n $current ]] && dir_writable "$current" && return 0
    dir_writable "$path" || die "Cannot create cache directory: $path"
    export "$name=$path"
}

select_caches() {
    local root=${AGENT_CACHE_ROOT:-} home_cache=${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}
    if [[ -z $root ]]; then
        # $HOME matters too: some package managers cache beside it, not under the
        # XDG cache home, so a read-only HOME must force the fallback as well.
        dir_writable "$home_cache" && [[ -w ${HOME:-/nonexistent} ]] && return 0
        root=${TMPDIR:-/tmp}/agent-cache-$(id -u)
        add_note "cache home unusable (${home_cache:-unset}); caches under $root"
        assert_private_dir "$root"
    fi
    dir_writable "$root" || die "Cache root is not writable: $root"
    export_cache_var XDG_CACHE_HOME "$root"
    export_cache_var UV_CACHE_DIR "$root/uv"
    export_cache_var NPM_CONFIG_CACHE "$root/npm"
    # ecosystem-allow: redirecting a package manager's cache is environment
    # code, not a claim about which one this repository uses -- the same
    # exemption the detection helpers carry. This one keeps a SQLite-backed
    # content store OUTSIDE the npm cache, so redirecting NPM_CONFIG_CACHE alone
    # left it writing where a sandbox denied it, surfacing as "[ERR_SQLITE_ERROR]
    # unable to open database file" -- which names neither the store nor the
    # sandbox. An agent lost several calls to it, then passed --store-dir by hand
    # on every command for the rest of the session.
    export_cache_var npm_config_store_dir "$root/pnpm-store"  # ecosystem-allow:
    export_cache_var PIP_CACHE_DIR "$root/pip"
}

# ---------------------------------------------------------------------- TLS ---
ca_bundle=
ca_custom=no
standard_bundles='/etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt
/etc/ssl/ca-bundle.pem /etc/ssl/cert.pem'

# Distro-standard bundle locations and local-anchor directories only. A site or
# corporate CA shows up either as a non-empty local-anchor directory or as a CA
# variable already pointing somewhere other than the distro bundle.
detect_ca() {
    local candidate anchor
    for candidate in "${SSL_CERT_FILE:-}" "${REQUESTS_CA_BUNDLE:-}" "${CURL_CA_BUNDLE:-}" \
        $standard_bundles; do
        if [[ -n $candidate && -r $candidate ]]; then
            ca_bundle=$candidate
            break
        fi
    done
    for anchor in /usr/local/share/ca-certificates /etc/pki/ca-trust/source/anchors \
        /usr/share/pki/trust/anchors /etc/ca-certificates/trust-source/anchors; do
        if [[ -d $anchor ]] && compgen -G "$anchor/*.[cp][re][tm]" >/dev/null 2>&1; then
            ca_custom=yes
            add_note "site CA anchors present in $anchor"
            return 0
        fi
    done
    for candidate in "${SSL_CERT_FILE:-}" "${REQUESTS_CA_BUNDLE:-}" "${NODE_EXTRA_CA_CERTS:-}"; do
        [[ -n $candidate ]] || continue
        case " ${standard_bundles//$'\n'/ } " in *" $candidate "*) continue ;; esac
        ca_custom=yes
        add_note "non-default CA bundle already in the environment: $candidate"
        return 0
    done
}

export_ca_vars() {
    local name
    [[ -n $ca_bundle ]] || return 0
    for name in SSL_CERT_FILE REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS CURL_CA_BUNDLE; do
        [[ -z ${!name:-} ]] && export "$name=$ca_bundle"
    done
    return 0
}

# --------------------------------------------------------------- PYTHONPATH ---
# Source-root names declared by the two standard metadata files, matched by shape:
#   "" = "src" (setuptools package-dir), from = "src" (poetry), = src (setup.cfg).
declared_root_names() {
    grep -oE '(""[[:space:]]*=|from[[:space:]]*=)[[:space:]]*"[^"]+"' "$1" 2>/dev/null |
        grep -oE '"[^"]+"$' | tr -d '"' || true
    # [:blank:] not [:space:]: deleting newlines here would swallow the last value.
    grep -oE '^[[:space:]]+=[[:space:]]*[A-Za-z0-9_./-]+[[:space:]]*$' "$1" 2>/dev/null |
        tr -d '[:blank:]=' || true
}

# A directory is a source root when it directly holds an importable package, or when
# the project's own metadata declares it. Detected by structure, never by layout.
python_source_roots() {
    local base=$1 root file rel=''
    for root in "$base" "$base/src"; do
        if [[ -d $root ]] && compgen -G "$root/*/__init__.py" >/dev/null 2>&1; then
            printf '%s\n' "$root"
        fi
    done
    for file in "$base/pyproject.toml" "$base/setup.cfg"; do
        [[ -f $file ]] || continue
        while IFS= read -r rel || [[ -n $rel ]]; do
            [[ -n $rel && -d $base/$rel ]] && printf '%s\n' "$base/$rel"
        done < <(declared_root_names "$file")
    done
    return 0
}

set_pythonpath() {
    local base roots=() root joined
    for base in "$run_dir" "$git_top"; do
        [[ -n $base && -d $base ]] || continue
        while IFS= read -r root; do
            case ":${roots[*]:-}:" in
                *":$root:"*) ;;
                *) roots+=("$root") ;;
            esac
        done < <(python_source_roots "$base")
    done
    ((${#roots[@]})) || return 0
    joined=$(printf '%s:' "${roots[@]}")
    export PYTHONPATH="${joined%:}${PYTHONPATH:+:$PYTHONPATH}"
}

# ------------------------------------------------------ command adjustments ---
command_is() {
    local want=$1 exe=${cmd[0]} resolved
    [[ $(basename -- "$exe") == "$want" ]] && return 0
    resolved=$(command -v -- "$exe" 2>/dev/null || true)
    [[ -n $resolved && $(basename -- "$resolved") == "$want" ]]
}

# uv reads the platform trust store when UV_SYSTEM_CERTS is set -- the documented
# equivalent of its --system-certs flag. Setting the variable rather than splicing
# a flag into argv keeps this correct for every uv subcommand and invocation form,
# and removes any need to guess where the subcommand starts.
maybe_enable_system_certs() {
    [[ $ca_custom == yes ]] || return 0
    command_is uv || return 0
    [[ -n ${UV_SYSTEM_CERTS:-} ]] && return 0
    export UV_SYSTEM_CERTS=1
    add_note 'set UV_SYSTEM_CERTS=1 (site CA detected)'
}

nearest_package_dir() {
    local d=$1
    while [[ -n $d && $d != / ]]; do
        [[ -f $d/package.json ]] && { printf '%s' "$d"; return 0; }
        d=$(dirname -- "$d")
    done
    [[ -f /package.json ]] || return 1
    printf '%s' /
}

# Moving the cwd would break relative paths in argv, so absolutise the tokens that
# clearly are paths: they contain a slash and exist relative to the original cwd.
absolutise_path_args() {
    local i=1 out=("${cmd[0]}") tok
    while ((i < ${#cmd[@]})); do
        tok=${cmd[i]}
        [[ $tok == */* && $tok != /* && -e $run_dir/$tok ]] && tok=$run_dir/$tok
        out+=("$tok")
        i=$((i + 1))
    done
    cmd=("${out[@]}")
    refresh_cmd_str
}

maybe_use_package_dir() {
    local name pkg_dir
    for name in node npm npx pnpm yarn; do  # ecosystem-allow: detects, never prescribes
        command_is "$name" || continue
        if ! pkg_dir=$(nearest_package_dir "$run_dir"); then
            add_note "no package.json in $run_dir or any ancestor; ran there anyway"
            return 0
        fi
        [[ $pkg_dir == "$run_dir" ]] && return 0
        absolutise_path_args
        work_dir=$pkg_dir
        add_note "package root $pkg_dir used instead of $run_dir"
        return 0
    done
}

canonicalise_work_dir() {
    local resolved
    resolved=$(cd -- "$work_dir" 2>/dev/null && pwd -P) ||
        die "Working directory cannot be resolved: $work_dir"
    work_dir=$resolved
}

# Docker Compose falls back to a directory-derived project name. Worktree
# directories are not necessarily unique by basename, and concurrent worktrees
# must never inherit the same project. Hash the canonical git root so the value
# is stable for this worktree, valid for Compose, and independent of caller env.
compose_project_name_for_worktree() {
    local digest
    digest=$(printf '%s' "$git_top" | sha256sum | awk '{print $1}') || return 1
    [[ $digest =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf 'agentkit-%s' "${digest:0:16}"
}

compose_static_value() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    value=${value#\"}
    value=${value%\"}
    value=${value#\'}
    value=${value%\'}
    [[ -n $value && $value != *'$'* && $value != \#* ]]
}

compose_argv() {
    local token base engine_seen=0
    for token in "${cmd[@]}"; do
        base=${token##*/}
        case $base in
            docker-compose | podman-compose)
                return 0
                ;;
            docker | podman)
                # Remember the engine rather than only the previous token: global
                # options may sit between it and its subcommand, and
                # `docker --context ci compose` still honours --project-name.
                # Matching on the immediate predecessor missed exactly those.
                engine_seen=1
                ;;
            compose)
                ((engine_seen)) && return 0
                ;;
        esac
    done
    return 1
}

# Positive evidence that the repository itself uses Compose, independent of
# anything a command happened to print. Mirrors the filename shapes
# compose_project_hardcodes recognises, but only asks whether one exists.
compose_repo_has_compose_file() {
    local rel
    while IFS= read -r -d '' rel; do
        case ${rel##*/} in
            compose.yml | compose.yaml | compose-*.yml | compose-*.yaml | \
            docker-compose.yml | docker-compose.yaml | docker-compose-*.yml | \
            docker-compose-*.yaml)
                return 0
                ;;
        esac
    done < <(git -C "$git_top" ls-files --cached --others --exclude-standard -z 2>/dev/null)
    return 1
}

# Print repository-controlled Compose project names as path:value findings.
# This is deliberately a narrow filename/shape scan: arbitrary YAML `name:`
# fields and unrelated environment variables are not Compose evidence.
compose_project_hardcodes() {
    local rel base line value token next i
    while IFS= read -r -d '' rel; do
        base=${rel##*/}
        case $base in
            .env | .env.*)
                while IFS= read -r line || [[ -n $line ]]; do
                    [[ $line =~ ^[[:space:]]*COMPOSE_PROJECT_NAME[[:space:]]*= ]] || continue
                    value=${line#*=}
                    if compose_static_value "$value"; then
                        printf '%s:%s\n' "$rel" "$value"
                    fi
                done < "$git_top/$rel"
                ;;
            compose.yml | compose.yaml | compose-*.yml | compose-*.yaml | \
            docker-compose.yml | docker-compose.yaml | docker-compose-*.yml | \
            docker-compose-*.yaml)
                while IFS= read -r line || [[ -n $line ]]; do
                    [[ $line =~ ^name:[[:space:]]* ]] || continue
                    value=${line#name:}
                    if compose_static_value "$value"; then
                        printf '%s:%s\n' "$rel" "$value"
                    fi
                done < <(awk '/^[^[:space:]#][^:]*:[[:space:]]*/ && $0 ~ /^name:[[:space:]]*/ { print }' "$git_top/$rel")
                ;;
        esac
    done < <(git -C "$git_top" ls-files --cached --others --exclude-standard -z 2>/dev/null)

    # A literal CLI project flag has precedence over COMPOSE_PROJECT_NAME and
    # therefore defeats the per-worktree export. The declaration is already a
    # parsed argv array, so inspect tokens without invoking a shell.
    if compose_argv; then
        for ((i = 0; i < ${#cmd[@]}; i++)); do
            token=${cmd[i]}
            value=''
            case $token in
                --project-name=*) value=${token#--project-name=} ;;
                -p?*) value=${token#-p} ;;
                -p | --project-name)
                    ((i + 1 < ${#cmd[@]})) || continue
                    next=${cmd[i + 1]}
                    value=$next
                    ((i += 1))
                    ;;
                COMPOSE_PROJECT_NAME=*) value=${token#COMPOSE_PROJECT_NAME=} ;;
                *) continue ;;
            esac
            if compose_static_value "$value"; then
                printf 'argv[%s]:%s\n' "$i" "$value"
            fi
        done
    fi
}

# Two cases, because Compose's own precedence splits them:
#
#   COMPOSE_PROJECT_NAME (exported here) outranks a repository `.env` value and a
#   compose-file top-level `name:`. Overriding those IS the isolation, and it is
#   safe for an ephemeral verification run, so they are reported and overridden.
#
#   A literal -p/--project-name in the declared command outranks the export. That
#   one cannot be overridden from here, so isolation genuinely cannot be
#   established and every worktree would share one project. Warning and running
#   anyway walks straight into the collision this gate exists to prevent, so that
#   path fails closed and the caller serializes instead. Set
#   AGENT_COMPOSE_SERIALIZED=1 to assert no concurrent full-suite run is in
#   flight; the command then proceeds under that assertion.
configure_compose_project() {
    local finding project argv_findings=()
    [[ -n $cmd_name ]] || return 0
    project=$(compose_project_name_for_worktree) ||
        die "cannot derive a deterministic Compose project name for $git_top"
    export COMPOSE_PROJECT_NAME=$project
    while IFS= read -r finding; do
        [[ -n $finding ]] || continue
        add_note "repository hardcodes a Compose project name: $finding"
        printf 'agent-run: WARNING: repository hardcodes a Compose project name: %s\n' \
            "$finding" >&2
        [[ $finding == argv\[* ]] && argv_findings+=("$finding")
    done < <(compose_project_hardcodes | sort -u)

    ((${#argv_findings[@]})) || return 0
    if [[ ${AGENT_COMPOSE_SERIALIZED:-} == 1 ]]; then
        add_note "isolation-impossible accepted under AGENT_COMPOSE_SERIALIZED=1: ${argv_findings[*]}"
        printf 'agent-run: note: isolation-impossible accepted under AGENT_COMPOSE_SERIALIZED=1\n' >&2
        return 0
    fi
    printf 'agent-run: ISOLATION-IMPOSSIBLE: %s\n' "${argv_findings[*]}" >&2
    printf 'agent-run: a declared -p/--project-name outranks COMPOSE_PROJECT_NAME, so this run cannot be isolated from sibling worktrees.\n' >&2
    printf 'agent-run: serialize full-suite verification -- let one unchanged full-suite command finish before starting another -- then re-run with AGENT_COMPOSE_SERIALIZED=1, or remove the flag from the declaration.\n' >&2
    exit 5
}

# A literal executable path is an ad-hoc command, not a repository declaration.
# Prefer its relative form from the exact execution directory, then fall back to
# the repository toplevel for the common root-relative spelling. Plain names
# deliberately fall through to PATH lookup. When the token cannot be proven to
# name a contained executable, leave it untouched so the wrapped command
# supplies its normal failure status while the diagnostic records both the
# execution cwd and the toplevel-resolution result.
resolve_literal_executable() {
    local token=${cmd[0]} candidate resolved
    [[ $cmd_declared == no && $token == */* ]] || return 0
    [[ $token != /* && -n $git_top ]] || return 0

    candidate=$work_dir/$token
    resolved=$(readlink -f -- "$candidate" 2>/dev/null || true)
    if [[ -n $resolved && $resolved == "$git_top"/* && -x $resolved && ! -d $resolved ]]; then
        cmd[0]=$resolved
        add_note "ad-hoc argv[0] '$token' resolved at execution cwd: yes ($resolved); execution cwd: $work_dir"
        refresh_cmd_str
        return 0
    fi

    candidate=$git_top/$token
    resolved=$(readlink -f -- "$candidate" 2>/dev/null || true)
    if [[ -n $resolved && $resolved == "$git_top"/* && -x $resolved && ! -d $resolved ]]; then
        cmd[0]=$resolved
        literal_root_fallback=yes
        literal_token=$token
        literal_execution_base=$work_dir
        literal_repository_base=$git_top
        add_note "ad-hoc argv[0] '$token' resolved at toplevel fallback: yes ($resolved); execution cwd: $work_dir"
    else
        add_note "ad-hoc argv[0] '$token' resolved at toplevel: no; execution cwd: $work_dir"
    fi
    refresh_cmd_str
}

# ------------------------------------------------- repository declarations ---
self_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")

# Read one repository-declared key. repo-config.sh is the ONLY reader of
# .agent/config.env -- it parses that file against a key whitelist and never
# sources it -- so every value arriving here has already been validated.
#
# The root is always passed explicitly. Letting the resolver detect it would use
# THIS process's cwd, which is not necessarily inside the repository --dir names.
repo_config_get() {
    local key=$1 resolver=$self_dir/repo-config.sh
    relevant_config_add "$key"
    if [[ -n ${resolved_config_present[$key]+yes} ]]; then
        printf '%s' "${resolved_config_values[$key]}"
        return 0
    fi
    [[ -x $resolver ]] || return 1
    "$resolver" --repo-root "${git_top:-$run_dir}" --get "$key" 2>/dev/null
}

# ------------------------------------------------------------------- runner ---
runner_path='' runner_src=''
resolution_kind=unresolved
declare -a relevant_config_keys=()
declare -A resolved_config_values=() resolved_config_present=()
declare -a resolved_command_argv=() resolved_focus_argv=()
resolved_command_key=''
command_kind=generic

relevant_config_add() {
    local key=$1 existing
    for existing in "${relevant_config_keys[@]}"; do
        [[ $existing == "$key" ]] && return 0
    done
    relevant_config_keys+=("$key")
}

relevant_config_remove() {
    local key=$1 existing
    local -a retained=()
    for existing in "${relevant_config_keys[@]}"; do
        [[ $existing == "$key" ]] || retained+=("$existing")
    done
    relevant_config_keys=("${retained[@]}")
}

# Resolve all keys needed for this invocation in one parser process. The
# resolver emits NUL-delimited records containing key, raw validated value,
# argv-count, and parsed argv. Keeping those parsed values in memory means the
# gate and execution cannot disagree after a second config read.
repo_config_resolve_keys() {
    local resolver=$self_dir/repo-config.sh key tmp diagnostics field argc i
    local -a keys=("$@")
    local -a resolve_args=(--repo-root "${git_top:-$run_dir}")
    tmp=$(mktemp "${TMPDIR:-/tmp}/agent-run-config.XXXXXX") || return 1
    diagnostics=$(mktemp "${TMPDIR:-/tmp}/agent-run-config-err.XXXXXX") || {
        rm -f -- "$tmp"
        return 1
    }
    for key in "${keys[@]}"; do
        [[ -n $key ]] || continue
        relevant_config_add "$key"
        resolve_args+=(--resolve "$key")
    done
    if ! "$resolver" "${resolve_args[@]}" >"$tmp" 2>"$diagnostics"; then
        cat -- "$diagnostics" >&2
        rm -f -- "$tmp" "$diagnostics"
        return 1
    fi
    resolved_rundir_mismatch=no
    exec 3<"$tmp" || { rm -f -- "$tmp" "$diagnostics"; return 1; }
    while IFS= read -r -d '' field <&3; do
        key=$field
        if [[ $key == __AGENT_CONFIG_PARSE_STATUS__ ]]; then
            IFS= read -r -d '' field <&3 || {
                exec 3<&-
                rm -f -- "$tmp" "$diagnostics"
                return 1
            }
            [[ $field == 0 || $field == 1 ]] || {
                exec 3<&-
                rm -f -- "$tmp" "$diagnostics"
                return 1
            }
            continue
        fi
        if [[ $key == __AGENT_CONFIG_RUNDIR_MISMATCH__ ]]; then
            IFS= read -r -d '' field <&3 || {
                exec 3<&-
                rm -f -- "$tmp" "$diagnostics"
                return 1
            }
            resolved_rundir_mismatch=yes
            continue
        fi
        IFS= read -r -d '' field <&3 || { exec 3<&-; rm -f -- "$tmp" "$diagnostics"; return 1; }
        resolved_config_values[$key]=$field
        resolved_config_present[$key]=yes
        IFS= read -r -d '' field <&3 || { exec 3<&-; rm -f -- "$tmp" "$diagnostics"; return 1; }
        [[ $field =~ ^[0-9]+$ ]] || { exec 3<&-; rm -f -- "$tmp" "$diagnostics"; return 1; }
        argc=$field
        local -a parsed=()
        for ((i = 0; i < argc; i++)); do
            IFS= read -r -d '' field <&3 || { exec 3<&-; rm -f -- "$tmp" "$diagnostics"; return 1; }
            parsed+=("$field")
        done
        if [[ $key == "$resolved_command_key" ]]; then
            resolved_command_argv=("${parsed[@]}")
        elif [[ $key == AGENT_CMD_TEST_FOCUS ]]; then
            resolved_focus_argv=("${parsed[@]}")
        fi
    done
    exec 3<&-
    if [[ $resolved_rundir_mismatch == yes ]]; then
        cat -- "$diagnostics" >&2
        rm -f -- "$tmp" "$diagnostics"
        die "cannot run $resolved_command_key: fix the rundir-relative declaration before running it"
    fi
    rm -f -- "$tmp" "$diagnostics"
}

# Sets runner_path/runner_src from an explicit declaration: $AGENT_REPO_RUNNER,
# else the same key in .agent/config.env. Returns 1 when neither declares one. A
# config.env value is repository-relative by construction -- repo-config.sh only
# accepts a contained, executable relative path -- so it resolves against the git
# toplevel rather than the current directory.
resolve_declared_runner() {
    local path src
    if [[ -n ${AGENT_REPO_RUNNER:-} ]]; then
        path=$AGENT_REPO_RUNNER
        src=AGENT_REPO_RUNNER
    else
        path=$(repo_config_get AGENT_REPO_RUNNER) || return 1
        [[ -n $path ]] || return 1
        [[ $path == /* ]] || path=${git_top:-$run_dir}/$path
        src=.agent/config.env
    fi
    if [[ ! -x $path ]]; then
        add_note "$src names a non-executable runner: $path"
        return 1
    fi
    runner_path=$path
    runner_src=$src
}

# Sets runner_path/runner_src, returns 0 when a runner is declared. Runs in the
# current shell (never a subshell) so the notes it adds survive for the caller.
# Memoised, because --cmd resolution may already have asked the same question.
# The sed picks the file's first non-blank, non-comment line and trims it.
resolve_runner() {
    local first
    if [[ -n $runner_path ]]; then
        return 0
    fi
    if resolve_declared_runner; then
        return 0
    fi
    [[ -n $git_top && -f $git_top/.agent/runner ]] || return 1
    first=$(sed -n '/^[[:space:]]*[^#[:space:]]/{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q;}' \
        "$git_top/.agent/runner" 2>/dev/null || true)
    [[ -n $first ]] || return 1
    [[ $first == /* ]] || first=$git_top/$first
    if [[ ! -x $first ]]; then
        add_note ".agent/runner names a non-executable command: $first"
        return 1
    fi
    runner_path=$first
    runner_src=.agent/runner
}

# Resolve a command by NAME rather than by ecosystem. The skill says "test"; the
# repository says what that means. Nothing here knows about npm, cargo, make, or
# any bespoke dispatcher.
#
# Order: AGENT_CMD_<NAME> -> the declared runner as `runner <name>` -> usage error.
resolve_named_command() {
    local name=$1 key declared kind_key declared_kind
    # The declaration reads AGENT_CMD_CHECK_NODE_PIN; the invocation is
    # --cmd check-node-pin. Reading the contract and typing its key back is the
    # obvious move, and it used to fail.
    #
    # Naming the correct spelling in the error was not enough: the next session
    # made the same three mistakes and recovered from each, which is three
    # wasted calls per session on every repository with multi-word command
    # names. Both spellings fold to the same key with no ambiguity, so the
    # strictness bought nothing that was worth a round trip. Accept either and
    # canonicalise -- everything downstream, including the log label, sees the
    # dashed form.
    name=$(printf '%s' "$name" | tr '[:upper:]_' '[:lower:]-')
    [[ $name =~ ^[a-z][a-z0-9-]*$ ]] ||
        die "--cmd NAME must be letters, digits, dashes or underscores, got: $1"

    # The name is also the natural log label, and it survives resolution.
    [[ -n $label ]] || label=$name

    local upper rundir
    upper=$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')
    key="AGENT_CMD_$upper"
    kind_key="${key}_KIND"
    resolved_command_key=$key
    relevant_config_add "$key"
    local -a resolve_keys=("$key" "AGENT_RUNDIR_$upper" "$kind_key")
    ((focus_requested)) && resolve_keys+=(AGENT_CMD_TEST_FOCUS)
    [[ -z ${AGENT_REPO_RUNNER:-} ]] && resolve_keys+=(AGENT_REPO_RUNNER)
    repo_config_resolve_keys "${resolve_keys[@]}" || die "cannot resolve repository declarations for $key"
    declared=${resolved_config_values[$key]:-}
    if [[ -n ${resolved_config_present[$key]+yes} && -n $declared ]]; then
        # The runner was parsed in the same resolver pass to close the
        # fallback TOCTOU window, but it is not relevant when the declaration
        # wins command resolution.
        [[ -z ${AGENT_REPO_RUNNER:-} ]] && relevant_config_remove AGENT_REPO_RUNNER
        cmd=("${resolved_command_argv[@]}")
        ((${#cmd[@]})) || die "invalid argv for $key"
        cmd_declared=yes
        resolution_kind=declared

        # Formatter diagnostics commonly contain volatile order, colour, and
        # timing text. Optional kind metadata selects path-set comparison while
        # the command-name fallback preserves existing formatter declarations.
        command_kind=generic
        declared_kind=${resolved_config_values[$kind_key]:-}
        case $declared_kind in
            format) command_kind=format ;;
            generic|'') ;;
        esac
        if [[ -z $declared_kind ]]; then
            case $name in
                format|formatter|*-format|format-*) command_kind=format ;;
            esac
        fi

        # A monorepo command usually has to run IN its component. Without this
        # the only root-runnable form of a dashboard test invocation globbed
        # into node_modules and started running a dependency's test suite.
        rundir=${resolved_config_values[AGENT_RUNDIR_$upper]:-}
        if [[ -n $rundir ]]; then
            [[ -n $git_top ]] || die "AGENT_RUNDIR_$upper is set but this is not a git repository"
            [[ -d $git_top/$rundir ]] ||
                die "AGENT_RUNDIR_$upper points at a missing directory: $rundir"
            work_dir="$git_top/$rundir"
        fi
        return 0
    fi

    # A bespoke dispatcher IS the runner; `runner <name>` is how the runner
    # convention already invokes it, so this needs no special case.
    # AGENT_REPO_RUNNER is consulted only on the fallback path. If the caller
    # supplied AGENT_REPO_RUNNER in the environment, the resolver is not read.
    if resolve_runner; then
        cmd=("$name")
        resolution_kind=runner
        command_kind=generic
        case $name in
            format|formatter|*-format|format-*) command_kind=format ;;
        esac
        return 0
    fi

    # A skill that names an OPTIONAL command must not fail when a repository
    # does not declare it. Observed: a review workflow hardcoded --cmd lint and
    # errored on a repository whose gate is declared as verify -- the contract
    # never promised that name, so the skill was wrong to assume it.
    if ((if_declared)); then
        printf 'agent-run: no command named %s declared here; skipping\n' "$name" >&2
        exit 0
    fi
    if [[ -n $resolve_name ]]; then
        printf 'unresolved\n'
        exit 3
    fi
    die "no command named '$name': declare $key in .agent/config.env, or add .agent/runner"
}

apply_test_focus() {
    local key='AGENT_CMD_TEST_FOCUS' declared token without replaced=0 occurrences i
    local -a focus_cmd=()
    ((focus_requested)) || return 0
    [[ $cmd_name == test ]] || die '--only is supported only with --cmd test.'

    relevant_config_add "$key"
    declared=${resolved_config_values[$key]:-}
    [[ -n ${resolved_config_present[$key]+yes} && -n $declared ]] ||
        die "--only requires $key in .agent/config.env."
    focus_cmd=("${resolved_focus_argv[@]}")
    ((${#focus_cmd[@]})) || die "invalid argv for $key"
    [[ ${focus_cmd[0]} != *%s* ]] ||
        die "$key cannot contain %s in its executable token."
    for i in "${!focus_cmd[@]}"; do
        token=${focus_cmd[i]}
        without=${token//%s/}
        [[ $without == "$token" ]] && { focus_cmd[i]=$token; continue; }
        occurrences=$(((${#token} - ${#without}) / 2))
        replaced=$((replaced + occurrences))
        token=${token//%s/$focus_opt}
        focus_cmd[i]=$token
    done
    ((replaced == 1)) || die "$key must contain exactly one %s placeholder."
    cmd=("${focus_cmd[@]}")
    cmd_declared=yes
}

# --------------------------------------------------------------------- logs ---
choose_log() {
    local log_dir stamp log
    if [[ -n $git_top ]] && dir_writable "$git_top/.agent/logs"; then
        log_dir=$git_top/.agent/logs
    else
        # Failing commands routinely echo tokens and credentialed URLs into these
        # logs, so the predictable /tmp fallback must be a private, self-owned dir.
        log_dir=${TMPDIR:-/tmp}/agent-logs-$(id -u)
        assert_private_dir "$log_dir"
        dir_writable "$log_dir" || die "No writable log directory (tried $log_dir)."
    fi
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    log=$log_dir/$stamp-$label.log
    [[ -e $log ]] && log=$log_dir/$stamp-$label.$$.log
    printf '%s' "$log"
}

# Full-suite runs share a host, so a probe that is healthy in isolation can
# cross its fixed startup bound while sibling suites consume the same cores.
# Keep short-lived, owner-only markers in /tmp to derive a conservative load
# count without relying on process-name matching (which is ambiguous in nested
# shells and across worktrees).
suite_marker=''
concurrent_suites=1
suite_marker_dir=${TMPDIR:-/tmp}/agent-run-suites-$(id -u)

current_process_start() {
    local pid=$1
    if [[ -r /proc/$pid/stat ]]; then
        awk '{print $22}' "/proc/$pid/stat" 2> /dev/null
    else
        # macOS has no /proc; kill -0 is the portable liveness fallback. The
        # marker is still short-lived and is removed by the EXIT trap.
        kill -0 "$pid" 2> /dev/null || return 1
        printf 'alive'
    fi
}

suite_marker_live() {
    local marker=$1 pid start current
    read -r pid start < "$marker" 2> /dev/null || return 1
    [[ $pid =~ ^[0-9]+$ && ($start =~ ^[0-9]+$ || $start == alive) ]] || return 1
    current=$(current_process_start "$pid")
    [[ -n $current && $current == "$start" ]]
}

register_suite_run() {
    local marker existing pid start
    [[ ${cmd_name:-} == test && -z ${focus_opt:-} ]] || return 0
    assert_private_dir "$suite_marker_dir"
    shopt -s nullglob
    for existing in "$suite_marker_dir"/*.run; do
        suite_marker_live "$existing" || rm -f -- "$existing"
    done
    shopt -u nullglob
    marker=$(mktemp "$suite_marker_dir/agent-run.XXXXXX.run") ||
        die "cannot create active-suite marker in $suite_marker_dir"
    pid=$$
    start=$(current_process_start "$pid")
    [[ $start =~ ^[0-9]+$ ]] || {
        rm -f -- "$marker"
        die "cannot identify active-suite process $pid"
    }
    printf '%s %s\n' "$pid" "$start" > "$marker" || {
        rm -f -- "$marker"
        die "cannot write active-suite marker $marker"
    }
    suite_marker=$marker
    concurrent_suites=$(find "$suite_marker_dir" -maxdepth 1 -type f -name '*.run' -print 2> /dev/null |
        wc -l | tr -d '[:space:]')
    [[ $concurrent_suites =~ ^[1-9][0-9]*$ ]] || concurrent_suites=1
    local timeout_scale_key=AGENT_TEST_TIMEOUT_SCALE
    if [[ -z ${!timeout_scale_key:-} ]]; then
        export "$timeout_scale_key=$concurrent_suites"
    fi
}

# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap below.
cleanup_suite_run() {
    [[ -n $suite_marker ]] || return 0
    rm -f -- "$suite_marker" 2> /dev/null || true
    suite_marker=''
}

# A worker may ask for one failed verification to be checked against the chain
# base. The source path must be the same blob at both commits, and the base
# checkout must produce matching failure evidence. This is deliberately opt-in:
# ordinary failures remain failures when a worker cannot identify a test or
# cannot obtain a trustworthy base run.
failure_signature() {
    local file=$1
    sed -E \
        -e '/^=== agent-run /d' \
        -e '/^=== started /d' \
        -e '/^=== finding /d' \
        -e '/^=== agent-run exited /d' \
        "$file" | sha256sum | awk '{print $1}'
}

# Formatter diagnostics are intentionally compared as a normalized set of
# repository-relative paths. Prettier's output can vary in order, colour, and
# timing while still identifying exactly the same drift. Only its stable
# `[warn] path` records are accepted; arbitrary diagnostic text is never a
# candidate path.
format_failure_paths() {
    local file=$1 line path
    while IFS= read -r line || [[ -n $line ]]; do
        line=$(printf '%s\n' "$line" | sed $'s/\033\\[[0-9;]*m//g;s/\r$//')
        [[ $line =~ ^[[:space:]]*\[warn\][[:space:]]+(.+)$ ]] || continue
        path=${BASH_REMATCH[1]}
        path=${path#./}
        case $path in
            ''|/*|../*|*/../*|*/..|*'\n'*) continue ;;
        esac
        printf '%s\n' "$path"
    done <"$file" | sort -u
}

format_paths_csv() {
    local paths=$1
    printf '%s\n' "$paths" | paste -sd, - | sed 's/,/, /g'
}

baseline_exclusion_message=''
baseline_exclusion_base_sha=''

clear_baseline_exclusion() {
    local exclusion_file=$git_top/.agent/baseline-exclusion.md
    [[ ! -L $exclusion_file ]] || return 1
    [[ ! -e $exclusion_file ]] || rm -f -- "$exclusion_file"
}

remove_baseline_exclusion() {
    local id=$1 base_sha=$2 exclusion_file=$git_top/.agent/baseline-exclusion.md
    local prefix line exclusion_tmp
    [[ ! -L $exclusion_file ]] || return 1
    [[ -f $exclusion_file ]] || return 0
    prefix="- [ ] Baseline exclusion: \`$id\` ("
    exclusion_tmp=$(mktemp "$git_top/.agent/.baseline-exclusion.XXXXXX") || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "$prefix"* && -n $base_sha &&
            $line == *"chain base \`$base_sha\`"* ]]; then
            continue
        fi
        printf '%s\n' "$line" >>"$exclusion_tmp" || {
            rm -f -- "$exclusion_tmp"
            return 1
        }
    done <"$exclusion_file"
    if [[ -s $exclusion_tmp ]]; then
        mv -f -- "$exclusion_tmp" "$exclusion_file"
    else
        rm -f -- "$exclusion_tmp" "$exclusion_file"
    fi
}

sanitize_baseline_path() {
    local value=$1 part result='' separator=''
    local -a parts=()
    IFS=: read -r -a parts <<<"$value"
    for part in "${parts[@]}"; do
        [[ -n $part && $part != "$git_top" && $part != "$git_top"/* ]] || continue
        result+=$separator$part
        separator=:
    done
    printf '%s' "${result:-/usr/bin:/bin}"
}

try_baseline_exclusion() {
    local base_sha head_sha base_blob current_blob current_file resolved_file
    local baseline_dir baseline_output baseline_work_dir rel base_rc baseline_path_env baseline_project
    local current_signature baseline_signature exclusion_file exclusion_tmp
    local current_failure_paths baseline_failure_paths exclusion_paths path
    [[ -n $baseline_ref ]] || return 1
    [[ -n $git_top && -d $git_top/.agent/logs ]] || return 1

    base_sha=$(git -C "$git_top" rev-parse --verify "$baseline_ref^{commit}" 2>/dev/null) || return 1
    [[ $base_sha =~ ^[[:xdigit:]]{40}$ ]] || return 1
    head_sha=$(git -C "$git_top" rev-parse --verify HEAD 2>/dev/null) || return 1
    [[ $base_sha != "$head_sha" ]] || return 1
    git -C "$git_top" merge-base --is-ancestor "$base_sha" "$head_sha" >/dev/null 2>&1 || return 1
    case $baseline_path in
        ''|.|..|../*|*/../*|*/.. ) return 1 ;;
    esac
    current_file=$git_top/$baseline_path
    resolved_file=$(readlink -f -- "$current_file" 2>/dev/null || true)
    [[ -n $resolved_file && $resolved_file == "$git_top"/* && -f $resolved_file ]] || return 1
    [[ $(git -C "$git_top" cat-file -t "$base_sha:$baseline_path" 2>/dev/null || true) == blob ]] || return 1
    base_blob=$(git -C "$git_top" rev-parse "$base_sha:$baseline_path" 2>/dev/null) || return 1
    current_blob=$(git -C "$git_top" hash-object -- "$resolved_file" 2>/dev/null) || return 1
    [[ $base_blob == "$current_blob" ]] || return 1

    baseline_dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-run-baseline.XXXXXX") || return 1
    baseline_output=$(mktemp "$git_top/.agent/logs/.baseline-run.XXXXXX") || {
        rmdir -- "$baseline_dir" 2>/dev/null || true
        return 1
    }
    chmod 600 -- "$baseline_output" 2>/dev/null || {
        rm -f -- "$baseline_output"
        rmdir -- "$baseline_dir" 2>/dev/null || true
        return 1
    }
    if ! git -C "$git_top" archive "$base_sha" | tar -x -C "$baseline_dir"; then
        rm -f -- "$baseline_output"
        rm -rf -- "$baseline_dir"
        return 1
    fi
    baseline_work_dir=$baseline_dir
    if [[ $work_dir != "$git_top" ]]; then
        rel=${work_dir#"$git_top"/}
        baseline_work_dir=$baseline_dir/$rel
    fi
    [[ -d $baseline_work_dir ]] || {
        rm -f -- "$baseline_output"
        rm -rf -- "$baseline_dir"
        return 1
    }
    baseline_path_env=$(sanitize_baseline_path "${PATH:-}") || {
        rm -f -- "$baseline_output"
        rm -rf -- "$baseline_dir"
        return 1
    }
    baseline_project=${COMPOSE_PROJECT_NAME:-agentkit}
    baseline_project=$baseline_project-baseline
    base_rc=0
    (cd -- "$baseline_work_dir" &&
        env -u PYTHONPATH -u NODE_PATH -u PYTHONHOME -u VIRTUAL_ENV \
            -u NPM_CONFIG_PREFIX -u npm_config_prefix -u COMPOSE_FILE \
            -u GIT_DIR -u GIT_WORK_TREE PATH="$baseline_path_env" \
            COMPOSE_PROJECT_NAME="$baseline_project" "${cmd[@]}") \
        >"$baseline_output" 2>&1 || base_rc=$?
    current_failure_paths=''
    baseline_failure_paths=''
    if [[ $command_kind == format ]]; then
        current_failure_paths=$(format_failure_paths "$log_file") || current_failure_paths=''
        baseline_failure_paths=$(format_failure_paths "$baseline_output") || baseline_failure_paths=''
    else
        current_signature=$(failure_signature "$log_file") || current_signature=''
        baseline_signature=$(failure_signature "$baseline_output") || baseline_signature=''
    fi
    rm -f -- "$baseline_output"
    rm -rf -- "$baseline_dir"
    ((base_rc != 0)) || return 1
    if [[ $command_kind == format ]]; then
        [[ -n $current_failure_paths && $current_failure_paths == "$baseline_failure_paths" ]] || return 1
        while IFS= read -r path || [[ -n $path ]]; do
            [[ -n $path ]] || continue
            [[ $(git -C "$git_top" cat-file -t "$base_sha:$path" 2>/dev/null || true) == blob ]] || return 1
            current_file=$git_top/$path
            resolved_file=$(readlink -f -- "$current_file" 2>/dev/null || true)
            [[ -n $resolved_file && $resolved_file == "$git_top"/* && -f $resolved_file ]] || return 1
            base_blob=$(git -C "$git_top" rev-parse "$base_sha:$path" 2>/dev/null) || return 1
            current_blob=$(git -C "$git_top" hash-object -- "$resolved_file" 2>/dev/null) || return 1
            [[ $base_blob == "$current_blob" ]] || return 1
            git -C "$git_top" diff --quiet "$base_sha...$head_sha" -- "$path" || return 1
            git -C "$git_top" diff --quiet HEAD -- "$path" || return 1
        done <<<"$current_failure_paths"
        exclusion_paths=$(format_paths_csv "$current_failure_paths") || return 1
    else
        [[ -n $current_signature && $current_signature == "$baseline_signature" ]] || return 1
        exclusion_paths=$baseline_path
    fi

    exclusion_file=$git_top/.agent/baseline-exclusion.md
    [[ ! -L $exclusion_file && (! -e $exclusion_file || -f $exclusion_file) ]] || return 1
    exclusion_tmp=$(mktemp "$git_top/.agent/.baseline-exclusion.XXXXXX") || return 1
    chmod 600 -- "$exclusion_tmp" 2>/dev/null || {
        rm -f -- "$exclusion_tmp"
        return 1
    }
    if [[ -e $exclusion_file ]]; then
        cat -- "$exclusion_file" >"$exclusion_tmp" || {
            rm -f -- "$exclusion_tmp"
            return 1
        }
    fi
    # shellcheck disable=SC2016  # backticks are literal Markdown delimiters.
    printf -- '- [ ] Baseline exclusion: `%s` (`%s`) is unchanged and red on chain base `%s` (failing paths: %s; evidence: `%s`)\n' \
        "$baseline_id" "$baseline_path" "$base_sha" "$exclusion_paths" "$log_file" >>"$exclusion_tmp" || {
        rm -f -- "$exclusion_tmp"
        return 1
    }
    mv -f -- "$exclusion_tmp" "$exclusion_file" || {
        rm -f -- "$exclusion_tmp"
        return 1
    }
    baseline_exclusion_base_sha=$base_sha
    baseline_exclusion_message="baseline-excluded test=$baseline_id base=$base_sha paths=$exclusion_paths log=$log_file"
    return 0
}

print_notes() {
    local prefix=$1 n
    ((${#notes[@]})) || return 0
    for n in "${notes[@]}"; do
        printf '%snote: %s\n' "$prefix" "$n"
    done
}

probe_timeout_load_flake() {
    ((concurrent_suites > 1)) || return 1
    grep -Eiq \
        '=== finding load-flake:|probe[^[:cntrl:]]*(did not finish|timed out|timeout)|probe timeout' \
        "$1" 2> /dev/null
}

# Compose's dependency-start messages are often the only durable signal that
# concurrent worktrees contended for a container, port, or network. Require
# POSITIVE evidence that the runner itself contended for a Compose resource --
# the declared command's resolved argv is a Compose invocation (compose_argv),
# or the repository actually contains a Compose file -- plus a collision/
# startup signature, so ordinary assertion and application failures remain
# ordinary command failures. Matching signature 1 against the log text alone
# was satisfied by any line that merely *mentions* Compose -- including a test
# suite's own passing test names -- which reduced the check to signature 2
# alone; a repository with no Compose file must never classify.
compose_dependency_start_collision() {
    local log=$1
    { compose_argv || compose_repo_has_compose_file; } || return 1
    grep -Eiq \
        'dependency[[:space:][:punct:]]+failed to start|dependency[^[:cntrl:]]*(already in use|already exists|port is already allocated|conflict)|container name[^[:cntrl:]]*already in use|port is already allocated|network[^[:cntrl:]]*already exists|Error response from daemon:[[:space:]]*Conflict|driver failed programming external connectivity' \
        "$log" 2>/dev/null
}

report_failure() {
    local rc=$1 log=$2 excerpt
    printf 'FAIL(rc=%s): %s\n' "$rc" "$cmd_str"
    printf '  cwd=%s runner=none\n' "$work_dir"
    print_notes '  '
    if compose_dependency_start_collision "$log"; then
        printf '  classification: environment-retry-eligible — Compose dependency-start collision; not a code regression.\n'
        printf '  retry guidance: rerun the unchanged declared command after the conflicting dependency has drained or been isolated.\n'
    fi
    if probe_timeout_load_flake "$log"; then
        printf '  classification: load-flake — probe timeout while concurrent-suites=%s; one retry was exhausted.\n' \
            "$concurrent_suites"
        printf '  retry guidance: the runner already retried this timeout once; inspect the probe failure if it persists.\n'
    fi
    if ((rc == 127)) && [[ $literal_root_fallback == yes ]]; then
        printf '  note: rc=127 indicates argv[0] %s was found from repository root %s but not from execution cwd %s; fix the declaration to use the execution base, and do not add a literal twin to route around the resolved execution base.\n' \
            "$literal_token" "$literal_repository_base" "$literal_execution_base"
    fi
    excerpt=$(grep -iE 'error|fail|traceback|assert|refused|denied' "$log" 2>/dev/null | head -n 20 || true)
    [[ -n $excerpt ]] || excerpt=$(tail -n 20 "$log" 2>/dev/null || true)
    if [[ -n $excerpt ]]; then
        printf '%s\n' "$excerpt"
    else
        printf '  (log is empty)\n'
    fi
    printf 'full log: %s\n' "$log"
}

# ---------------------------------------------------------------- verification cache ---
# Only commands whose names describe verification are eligible for reusable
# green evidence. State-producing commands must run again when their ignored
# outputs disappear, even when the checkout bytes are unchanged.
verification_cache_eligible() {
    case ${cmd_name:-} in
        test|lint|typecheck|coverage|verify|check) return 0 ;;
        *) return 1 ;;
    esac
}

hash_untracked_files() {
    local paths path file digest link
    paths=$(mktemp "${TMPDIR:-/tmp}/agent-run-untracked.XXXXXX") || return 1
    if ! git -C "$git_top" ls-files --others --exclude-standard -z >"$paths"; then
        rm -f -- "$paths"
        return 1
    fi

    exec 3<"$paths" || {
        rm -f -- "$paths"
        return 1
    }
    while IFS= read -r -d '' path <&3; do
        file=$git_top/$path
        if [[ ! -e $file && ! -L $file ]]; then
            exec 3<&-
            rm -f -- "$paths"
            return 1
        fi
        printf 'untracked\0path\0%s\0' "$path"
        if [[ -L $file ]]; then
            if ! link=$(readlink -- "$file"); then
                exec 3<&-
                rm -f -- "$paths"
                return 1
            fi
            printf 'symlink\0%s\0' "$link"
        elif digest=$(sha256sum -- "$file" | awk '{print $1}'); then
            if [[ ! $digest =~ ^[[:xdigit:]]{64}$ ]]; then
                exec 3<&-
                rm -f -- "$paths"
                return 1
            fi
            printf 'file\0%s\0' "$digest"
        else
            exec 3<&-
            rm -f -- "$paths"
            return 1
        fi
    done
    exec 3<&-
    rm -f -- "$paths"
}

# Green evidence is keyed to the complete checkout state that a caller can
# observe. The status stream carries untracked paths; diff HEAD carries both
# staged and unstaged tracked content. Untracked file contents are added from a
# NUL-delimited manifest, so same-path edits cannot reuse stale evidence and
# unusual filenames cannot be split by shell text parsing. Cache state is
# ignored by git, so it does not feed back into this hash.
#
# The resolved argv is folded in too, NUL-delimited per token: `cmd` is already
# fully resolved by the time this runs (AGENT_CMD_<NAME> read from
# .agent/config.env, or the runner invocation). That file is conventionally
# gitignored, so its bytes never appear in HEAD, the tracked diff, or the
# untracked-file manifest above -- only the resolved argv observes a changed
# declared value. Without this, editing AGENT_CMD_TEST from `true` to `false`
# left the tree hash unchanged and served the old green evidence back (#287).
compute_tree_hash() {
    local hash_input digest
    [[ -n ${git_top:-} ]] || return 1
    hash_input=$(mktemp "${TMPDIR:-/tmp}/agent-run-tree.XXXXXX") || return 1
    if ! : >"$hash_input" ||
        ! git -C "$git_top" rev-parse HEAD >>"$hash_input" ||
        ! printf '\0' >>"$hash_input" ||
        ! printf 'command\0%s\0kind\0%s\0focus\0%s\0' "$cmd_name" "$command_kind" "$focus_opt" >>"$hash_input" ||
        ! printf 'resolved\0' >>"$hash_input" ||
        ! printf '%s\0' "${cmd[@]}" >>"$hash_input" ||
        ! git -C "$git_top" diff HEAD >>"$hash_input" ||
        ! printf '\0' >>"$hash_input" ||
        ! git -C "$git_top" status --porcelain=v2 -z --untracked-files=all >>"$hash_input" ||
        ! printf '\0work-dir\0%s\0' "$work_dir" >>"$hash_input" ||
        ! hash_untracked_files >>"$hash_input"; then
        rm -f -- "$hash_input"
        return 1
    fi
    if ! digest=$(sha256sum -- "$hash_input" | awk '{print $1}') ||
        [[ ! $digest =~ ^[[:xdigit:]]{64}$ ]]; then
        rm -f -- "$hash_input"
        return 1
    fi
    rm -f -- "$hash_input"
    printf '%s' "$digest"
}

verification_cache_path() {
    [[ -n ${git_top:-} ]] || return 1
    printf '%s/.agent/verification-cache' "$git_top"
}

# A cache line is evidence only while its referenced log still has the exact
# completion marker. This prevents an interrupted or hand-written line from
# becoming a green result.
verification_cache_hit() {
    local tree_hash=$1 cache line log
    ((force_cmd)) && return 1
    verification_cache_eligible || return 1
    cache=$(verification_cache_path 2>/dev/null || true)
    [[ -n $cache && -r $cache ]] || return 1
    while IFS= read -r line; do
        [[ $line == "$tree_hash cmd=$cmd_name log="* ]] || continue
        [[ $line == *" focus="* ]] || continue
        log=${line#* log=}
        log=${log% at=*}
        [[ -f $log ]] || continue
        grep -qE '^=== agent-run exited rc=0([[:space:]]|$)' "$log" || continue
        printf 'agent-run: verification current: %s\n' "$log"
        return 0
    done < "$cache"
    return 1
}

record_verification() {
    local tree_hash=$1 log=$2 cache temp
    [[ -n ${git_top:-} ]] || return 0
    verification_cache_eligible || return 0
    grep -qE '^=== agent-run exited rc=0([[:space:]]|$)' "$log" || return 0
    cache=$(verification_cache_path 2>/dev/null || true)
    [[ -n $cache && ! -L $cache ]] || return 0
    mkdir -p -- "${cache%/*}" 2>/dev/null || return 0
    temp=$cache.$$
    {
        [[ ! -e $cache ]] || cat -- "$cache"
        printf '%s cmd=%s log=%s at=%s focus=%s\n' \
            "$tree_hash" "$cmd_name" "$log" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$focus_opt"
    } > "$temp" 2>/dev/null || {
        rm -f -- "$temp" 2>/dev/null || true
        return 0
    }
    chmod 600 -- "$temp" 2>/dev/null || true
    mv -f -- "$temp" "$cache" 2>/dev/null || rm -f -- "$temp" 2>/dev/null || true
}

# --------------------------------------------------------------------- main ---
if [[ -n $cmd_name ]]; then
    resolve_named_command "$cmd_name"
    apply_test_focus
elif [[ -n $resolve_name ]]; then
    resolve_named_command "$resolve_name"
    printf '%s\n' "$resolution_kind"
    case $resolution_kind in
        declared) exit 0 ;;
        runner) exit 4 ;;
        *) die "unknown resolution kind: $resolution_kind" ;;
    esac
fi
finalise_label
refresh_cmd_str

# Resolve the directory before verification identity is computed. This keeps
# --dir, repository-declared rundirs, and package-root adjustments scoped to
# the exact directory where the command will execute.
maybe_use_package_dir
canonicalise_work_dir
resolve_literal_executable

# Configure the per-worktree Compose namespace only for a named command, before
# either delegation or execution so every declared command sees it.
configure_compose_project

tree_hash=''
if verification_cache_eligible; then
    tree_hash=$(compute_tree_hash 2>/dev/null || true)
    if [[ -n $tree_hash ]] && verification_cache_hit "$tree_hash"; then
        exit 0
    fi
fi

select_caches
detect_ca
export_ca_vars
# A read-only repository ROOT is the failure that arrives disguised. Most build
# and test tools write there -- a coverage file, a cache, build output -- so the
# first symptom is an OSError from a tool that had nothing to do with the cause.
# Observed: a session started in a SUBDIRECTORY, which a workspace-scoped sandbox
# makes the only writable subtree, and pytest died on .coverage at the root.
warn_if_root_readonly() {
    local probe
    [[ -n $git_top && -d $git_top ]] || return 0
    probe=$(mktemp "$git_top/.agent-run-probe-XXXXXX" 2> /dev/null) || {
        printf 'agent-run: WARNING: the repository root (%s) is not writable from this process.\n' "$git_top" >&2
        printf '  Anything writing there -- coverage files, caches, build output -- will fail with an\n' >&2
        printf '  error naming the file rather than the cause. A session started in a subdirectory is\n' >&2
        printf '  the usual reason: start it at the repository root instead.\n' >&2
        return 0
    }
    rm -f -- "$probe" 2> /dev/null || true
}
warn_if_root_readonly

set_pythonpath
maybe_enable_system_certs
export AGENT_RUN_LABEL="$label"

# A declared AGENT_CMD_* value is the entire command: the repository has already
# said exactly what to run, so it is not handed to the runner as a subcommand.
if [[ $cmd_declared == no ]] && resolve_runner; then
    printf 'delegating: runner=%s source=%s cwd=%s\n' "$runner_path" "$runner_src" "$work_dir" >&2
    print_notes '' >&2
    cd -- "$work_dir"
    exec "$runner_path" "${cmd[@]}"
fi

log_file=$(choose_log)
register_suite_run
trap cleanup_suite_run EXIT

# Announced BEFORE the run, not only after it. Output is captured, so a long
# command looks identical to a hung one until it exits -- and an agent watching
# a five-minute suite went hunting with ps and `ls -t .agent/logs` to find
# something to tail. Naming the file up front costs one line and saves that.
printf 'running: %s\n  log: %s (grows while this runs; tail it instead of waiting blind)\n' \
    "$cmd_str" "$log_file" >&2
printf '  a log with no "=== agent-run exited" line has NOT finished\n' >&2

# The log is bracketed, and the closing marker is the point.
#
# It used to hold the command's output and nothing else, so a log that stopped
# mid-stream was indistinguishable from one still being written -- and from one
# whose process had died. A session that launched several commands at once read
# two logs ending after their package manager's preamble, could not tell a hang
# from a failure, and went to `ps` to find out. The absence of a terminator is
# now the answer: no "exited" line means it did not finish.
#
# LOG_HEADER_LINES keeps the "N lines suppressed" count honest -- it reports the
# command's own output, not this bookkeeping.
readonly LOG_HEADER_LINES=2
{
    printf '=== agent-run %s\n' "$cmd_str"
    printf '=== started %s  pid=%s  cwd=%s  concurrent-suites=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || printf 'unknown')" "$$" "$work_dir" \
        "$concurrent_suites"
} > "$log_file"

# A killed run cannot write its own terminator on SIGKILL, which is correct:
# that log SHOULD stay unterminated. TERM and INT are catchable, and a run the
# operator interrupted is worth distinguishing from one that vanished.
# shellcheck disable=SC2329,SC2317  # invoked from the trap strings below;
# version 0.11 calls this SC2329, older releases call it SC2317, and a line
# starting with the tool name would itself be read as a directive
log_interrupted() {
    printf '=== agent-run interrupted by %s -- the command did not finish\n' "$1" >> "$log_file"
    exit 130
}
trap 'log_interrupted SIGINT' INT
trap 'log_interrupted SIGTERM' TERM

started_at=$SECONDS
rc=0
(cd -- "$work_dir" && exec "${cmd[@]}") >> "$log_file" 2>&1 || rc=$?
load_flake_retry=0
if ((rc != 0)) && probe_timeout_load_flake "$log_file"; then
    load_flake_retry=1
    printf '=== finding load-flake: probe timeout under concurrent-suites=%s; retried 1/1\n' \
        "$concurrent_suites" >> "$log_file"
    rc=0
    (cd -- "$work_dir" && exec "${cmd[@]}") >> "$log_file" 2>&1 || rc=$?
fi
trap - INT TERM
elapsed=$((SECONDS - started_at))
lines=$(($(wc -l < "$log_file" | tr -d '[:space:]') - LOG_HEADER_LINES))
((lines >= 0)) || lines=0
baseline_excluded=no
original_rc=$rc
if [[ -n $baseline_ref ]]; then
    baseline_key_sha=$(git -C "$git_top" rev-parse --verify "$baseline_ref^{commit}" 2>/dev/null || true)
    remove_baseline_exclusion "$baseline_id" "$baseline_key_sha" || true
elif ((rc == 0)); then
    clear_baseline_exclusion || true
fi
if ((rc != 0)) && try_baseline_exclusion; then
    baseline_excluded=yes
    rc=0
    printf '=== agent-run baseline-excluded original-rc=%s test=%s base=%s\n' \
        "$original_rc" "$baseline_id" "$baseline_exclusion_base_sha" >> "$log_file"
fi
if ((rc != 0)) && compose_dependency_start_collision "$log_file"; then
    printf '=== finding environment-retry-eligible: compose dependency-start collision (not a code regression)\n' >> "$log_file"
fi
printf '=== agent-run exited rc=%s after %ss\n' "$rc" "$elapsed" >> "$log_file"

if ((rc == 0)); then
    if [[ $baseline_excluded == yes ]]; then
        printf 'BASELINE-EXCLUDED: %s\n' "$baseline_exclusion_message"
    else
        if ((load_flake_retry)); then
            printf 'load-flake: probe timeout under concurrent-suites=%s; retried 1/1\n' \
                "$concurrent_suites"
        fi
        [[ -n $tree_hash ]] && record_verification "$tree_hash" "$log_file"
        printf 'PASS: %s (%s lines suppressed -> %s)\n' "$cmd_str" "$lines" "$log_file"
    fi
else
    report_failure "$rc" "$log_file"
fi
exit "$rc"
