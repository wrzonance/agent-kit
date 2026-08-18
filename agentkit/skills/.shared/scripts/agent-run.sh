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
# Usage: agent-run.sh [--dir PATH] [--label NAME] [--resolve NAME] (--cmd NAME | [--] <command> ...)
# Exit status: the wrapped command's status (this script's own usage errors exit 1).

set -euo pipefail

if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
    printf '%s: requires Bash >= 4 (invoked interpreter: %s); run this helper with bash, not zsh\n' \
        "${0##*/}" "${SHELL:-unknown}" >&2
    exit 2
fi

usage() {
    cat <<'EOF'
Usage: agent-run.sh [--dir PATH] [--label NAME] [--resolve NAME] [--approve|--yolo] [--yolo-write-set GLOB]... [--force] [--only NAME[,NAME...]] (--cmd NAME | [--] <command> ...)

Runs one command with a sandbox-safe environment and a compact result summary.
  --dir PATH     Working directory for the command (default: current directory).
  --label NAME   Label used in the log file name (default: the command's basename).
  --approve      Record explicit approval for the current repository declaration and
                 executable inputs, but do not run the command. The confirmation
                 is read from the terminal (defense-in-depth: a non-interactive
                 agent shell cannot answer it, though it is not an unforgeable
                 human-only gate). Review, then approve from your own terminal.
  --yolo         Run a --cmd command without an approval record, and record
                 none -- PROVIDED the command's repository-controlled inputs
                 (.agent/config.env, .agent/runner, repo-backed argv/module
                 paths, and nearby build manifests)
                 are identical to the remote trunk's. An input that is new or
                 changed on this checkout is refused: that is new code asking
                 to run unattended, and it still takes a terminal approval.
                 For runs a human explicitly launched as unattended (a skill
                 invoked with --yolo/--fast-mode), where stalling on the
                 terminal-only gate dead-ends workers nobody is watching. The
                 skip is announced on stderr and stamped into the run log.
                 Mutually exclusive with --approve; inert for a literal
                 command, which the gate never covered.
  --yolo-base SHA  With --yolo: validate command inputs against this pinned,
                 origin-reachable ancestor commit instead of the remote trunk.
                 For chained worktrees whose base is a root-published commit
                 from an earlier issue in the same run.
  --yolo-write-set GLOB  With --yolo: admit changed command inputs matching this
                 repository-relative dispatch-owned glob. Repeat for multiple
                 globs; commas are literal path characters. Inputs outside the
                 set remain subject to the trust gate.
  --force        Execute a named command even when green evidence is current.
  --only NAME[,NAME...]  For --cmd test, use the repository's
                 AGENT_CMD_TEST_FOCUS declaration and pass names through its %s placeholder.
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

Trust boundary:
  Commands selected with --cmd are repository-controlled. The first run, and any
  run after the declaration or repository-backed command input changes, prompt
  for `agent-run.sh --approve --cmd NAME`. Review it, then approve from a
  terminal. That terminal confirmation is defense-in-depth, not a human-only
  guarantee: a same-user process can drive a pseudo-terminal or write the record
  directly. Approval is stored outside the checkout in an owner-only state
  directory and is never committed to the repository. A run the human explicitly
  launched as unattended may pass --yolo instead: when the command's
  repository-controlled inputs match the remote trunk, the gate is skipped for
  that one invocation, loudly, and no trust is recorded; when they differ from
  the trunk, --yolo refuses.

Output:
  PASS: <cmd> (N lines suppressed -> LOG)
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
approve_cmd=0
yolo_cmd=0
yolo_base_opt=''
declare -a yolo_write_set_args=()
declare -a yolo_write_set_globs=()
force_cmd=0
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
        --approve)
            approve_cmd=1
            shift
            ;;
        --yolo)
            yolo_cmd=1
            shift
            ;;
        --yolo-base)
            (($# >= 2)) || die '--yolo-base requires a commit SHA.'
            yolo_base_opt=$2
            shift 2
            ;;
        --yolo-write-set)
            (($# >= 2)) || die '--yolo-write-set requires one or more globs.'
            yolo_write_set_args+=("$2")
            shift 2
            ;;
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
        --dir|--label|--cmd|--resolve)
            (($# >= 2)) || die "Missing value for $1."
            case $1 in
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
    ((approve_cmd == 0 && yolo_cmd == 0 && force_cmd == 0)) ||
        die '--resolve NAME cannot be combined with execution flags.'
    ((if_declared == 0)) || die '--resolve NAME cannot be combined with --if-declared.'
elif [[ -n $cmd_name ]]; then
    ((${#cmd[@]} == 0)) || die '--cmd NAME and a literal command are mutually exclusive.'
else
    ((${#cmd[@]})) || die 'No command given.'
fi
if ((approve_cmd)) && [[ -z $cmd_name ]]; then
    die '--approve requires --cmd NAME.'
fi
if ((force_cmd)) && [[ -z $cmd_name ]]; then
    die '--force requires --cmd NAME.'
fi
if ((approve_cmd && yolo_cmd)); then
    die '--approve and --yolo are mutually exclusive: one records trust, the other skips it.'
fi
if [[ -n $yolo_base_opt ]]; then
    ((yolo_cmd)) || die '--yolo-base requires --yolo.'
    [[ $yolo_base_opt =~ ^[0-9a-f]{40}$ ]] ||
        die '--yolo-base requires a full 40-character lowercase commit SHA, not a ref or abbreviation.'
fi
if ((${#yolo_write_set_args[@]})); then
    yolo_write_set_globs=("${yolo_write_set_args[@]}")
    for write_set_glob in "${yolo_write_set_globs[@]}"; do
        [[ -n $write_set_glob && $write_set_glob != /* &&
            $write_set_glob != *[[:cntrl:]]* && $write_set_glob != *"\\"* ]] ||
            die "--yolo-write-set glob is not a repository-relative pattern: $write_set_glob"
        case "/$write_set_glob/" in
            *'/../'* | *'//'* | *'/./'*)
                die "--yolo-write-set glob contains an unsafe path: $write_set_glob"
                ;;
        esac
    done
fi
if ((${#yolo_write_set_args[@]})); then
    ((yolo_cmd)) || die '--yolo-write-set requires --yolo.'
    [[ -n $cmd_name ]] || die '--yolo-write-set requires --cmd NAME.'
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
resolved_parse_failed=no

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
            [[ $field == 1 ]] && resolved_parse_failed=yes
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
        die "cannot run $resolved_command_key: fix the rundir-relative declaration before approval"
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
    local name=$1 key declared
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
    resolved_command_key=$key
    relevant_config_add "$key"
    local -a resolve_keys=("$key" "AGENT_RUNDIR_$upper")
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

# ----------------------------------------------------------- command trust ---
# A declaration is data, not consent.  A contributor can change config.env or a
# repository-backed script without changing the command name, so the command
# must be approved outside the checkout before it is executed.  The fingerprint
# deliberately covers the declaration file and every existing repository path
# in argv.  For ecosystem dispatchers whose behavior comes from a manifest, the
# nearby manifest/build files are covered too.  Ordinary source edits remain
# usable; changing the command's declaration or direct execution inputs does not
# silently grant new code execution.
trust_root=''
trust_file=''
trust_fingerprint=''

sha256_text() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

trust_state_root() {
    local candidate
    if [[ -n ${AGENT_TRUST_ROOT:-} ]]; then
        candidate=$AGENT_TRUST_ROOT
    elif [[ -n ${XDG_STATE_HOME:-} ]]; then
        candidate=$XDG_STATE_HOME/agent-kit/command-trust
    elif [[ -n ${HOME:-} ]]; then
        candidate=$HOME/.local/state/agent-kit/command-trust
    else
        candidate=${TMPDIR:-/tmp}/agent-state-$(id -u)/command-trust
    fi
    assert_private_dir "$candidate"
    printf '%s' "$candidate"
}

hash_repo_input() {
    local path=$1 resolved rel
    resolved=$(readlink -f -- "$path" 2>/dev/null || true)
    [[ -n $resolved ]] || {
        printf 'unresolved=%s\n' "$path"
        return 0
    }
    [[ -e $resolved || -L $resolved ]] || {
        printf 'missing=%s\n' "$path"
        return 0
    }
    [[ $resolved == "$git_top"/* ]] || {
        printf 'outside=%s\n' "$path"
        return 0
    }
    rel=${resolved#"$git_top/"}
    if [[ -d $resolved ]]; then
        find "$resolved" -type f -o -type l | sort | while IFS= read -r path; do
            [[ -e $path || -L $path ]] || continue
            printf 'path=%s\n' "${path#"$git_top/"}"
            if [[ -L $path ]]; then
                readlink -- "$path"
            else
                sha256sum -- "$path" | awk '{print $1}'
            fi
        done
    elif [[ -L $resolved ]]; then
        printf 'path=%s\nlink=%s\n' "$rel" "$(readlink -- "$resolved")"
    else
        printf 'path=%s\n' "$rel"
        sha256sum -- "$resolved" | awk '{print $1}'
    fi
}

repo_relative_path() {
    local path=$1
    if [[ $path == "$git_top"/* ]]; then
        printf '%s' "${path#"$git_top/"}"
    else
        printf '%s' "$path"
    fi
}

emit_declared_path_input() {
    local input=$1
    if [[ -z $input ]]; then
        printf '__invalid-command-input__\n'
    elif [[ $input == /* ]]; then
        if [[ $input == "$git_top"/* ]]; then
            printf '%s\n' "${input#"$git_top/"}"
        else
            printf '__external-command-input__\n'
        fi
    elif [[ $input == .. || $input == ../* || $input == */../* || $input == */.. ]]; then
        printf '__external-command-input__\n'
    else
        printf '%s\n' "$input"
        [[ $work_dir == "$git_top" ]] ||
            printf '%s/%s\n' "${work_dir#"$git_top/"}" "$input"
    fi
}

is_command_input_sentinel() {
    case $1 in
        __invalid-command-input__|__external-command-input__) return 0 ;;
        *) return 1 ;;
    esac
}

hash_command_inputs() {
    local input
    while IFS= read -r input; do
        [[ -n $input ]] || continue
        if is_command_input_sentinel "$input"; then
            printf '%s\n' "$input"
        else
            printf 'declared=%s\n' "$input"
            hash_repo_input "$git_top/$input"
        fi
    done < <(command_input_paths | sort -u)
}

command_input_paths() {
    local index input module module_path
    for ((index = 0; index < ${#cmd[@]}; index++)); do
        input=${cmd[index]}
        case $input in
            --require=*) emit_declared_path_input "${input#--require=}" ;;
            --require|-r)
                if ((index + 1 < ${#cmd[@]})); then
                    ((index += 1))
                    emit_declared_path_input "${cmd[index]}"
                else
                    printf '__invalid-command-input__\n'
                fi
                ;;
            -m)
                if ((index + 1 < ${#cmd[@]})); then
                    ((index += 1))
                    module=${cmd[index]}
                    if [[ $module =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ ]]; then
                        module_path=${module//./\/}
                        emit_declared_path_input "$module_path.py"
                        emit_declared_path_input "$module_path"
                    else
                        printf '__invalid-command-input__\n'
                    fi
                else
                    printf '__invalid-command-input__\n'
                fi
                ;;
            *) [[ $input == */* ]] && emit_declared_path_input "$input" ;;
        esac
    done
}

manifest_paths() {
    local base=$1 file name
    local -a manifest_names=(package.json package-lock.json)
    manifest_names+=(pnpm-lock.yaml yarn.lock) # ecosystem-allow: manifest filenames, never commands
    manifest_names+=(Makefile justfile Taskfile.yml pyproject.toml setup.cfg tox.ini)
    manifest_names+=(Cargo.toml go.mod pom.xml build.gradle composer.json Gemfile)
    while [[ $base == "$git_top" || $base == "$git_top"/* ]]; do
        for name in "${manifest_names[@]}"; do
            file=$base/$name
            printf '%s\n' "$(repo_relative_path "$file")"
        done
        base=$(dirname -- "$base")
    done
}

hash_nearby_manifests() {
    local rel file
    while IFS= read -r rel; do
        file=$git_top/$rel
        printf 'manifest=%s\n' "$rel"
        if [[ -f $file ]]; then
            sha256sum -- "$file" | awk '{print $1}'
        else
            printf 'missing\n'
        fi
    done < <(manifest_paths "$1")
}

compute_trust_fingerprint() {
    local input key
    {
        printf 'schema=1\ncommand=%s\n' "$cmd_name"
        printf 'argv=%s\n' "$cmd_str"
        printf 'declarations=\n'
        while IFS= read -r key; do
            [[ -n $key ]] || continue
            if [[ -n ${resolved_config_present[$key]+yes} ]]; then
                printf '%s=%s\n' "$key" "${resolved_config_values[$key]}"
            else
                printf '%s=<absent>\n' "$key"
            fi
        done < <(printf '%s\n' "${relevant_config_keys[@]}" | LC_ALL=C sort -u)
        hash_command_inputs
        [[ -n ${runner_path:-} ]] && hash_repo_input "$runner_path"
        hash_nearby_manifests "$work_dir"
    } | sha256sum | awk '{print $1}'
}

# ---------------------------------------------------------------- yolo gate ---
# --yolo replaces the approval RECORD, not the approval DECISION. The decision
# it leans on is the trunk's: a human launched this run unattended, and the
# remote trunk already carries every input the command resolves from -- so
# executing exactly what the trunk reviewed needs no second confirmation. What
# it never covers is an input that is new or changed on THIS checkout: a branch
# or fork that edits the declaration, runner, payload, or build manifest is new
# code asking to run unattended, and that still takes an explicit approval from
# a terminal. Like any test run, the wrapped command's other transitive inputs
# are the branch's code; the line is drawn at inputs this command contract can
# identify deterministically.
yolo_base_ref() {
    local ref
    ref=$(git -C "$git_top" rev-parse --abbrev-ref -q origin/HEAD 2> /dev/null) || ref=''
    if [[ -z $ref || $ref == origin/HEAD ]]; then
        for ref in origin/main origin/master origin/trunk; do
            git -C "$git_top" rev-parse -q --verify "$ref^{commit}" > /dev/null 2>&1 && break
            ref=''
        done
    fi
    [[ -n $ref ]] || return 1
    printf '%s' "$ref"
}

yolo_repo_inputs() {
    local rel
    printf '%s\n' .agent/runner
    if [[ -n ${runner_path:-} && $runner_path == "$git_top"/* ]]; then
        printf '%s\n' "${runner_path#"$git_top/"}"
    fi
    # Some argv tokens are intentionally not path-shaped; command_input_paths
    # returns their final predicate status, which must not short-circuit the
    # manifest inputs below under set -e.
    command_input_paths || true
    while IFS= read -r rel; do
        printf '%s\n' "$rel"
    done < <(manifest_paths "$work_dir")
}

canonical_relevant_lines() {
    local key
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        if [[ -n ${resolved_config_present[$key]+yes} ]]; then
            printf '%s=%s\n' "$key" "${resolved_config_values[$key]}"
        fi
    done < <(printf '%s\n' "${relevant_config_keys[@]}" | LC_ALL=C sort -u)
}

# Materialize and parse the base config through repo-config.sh itself. The
# temporary is owner-only and removed before returning. Status 3 means the base
# has no config blob; other nonzero statuses are parse/extraction failures.
yolo_base_declarations() {
    local base=$1 resolver=$self_dir/repo-config.sh tmp keys_csv rc
    local -a keys=("${relevant_config_keys[@]}")
    tmp=$(mktemp "${TMPDIR:-/tmp}/agent-run-base-config.XXXXXX") || return 2
    if ! git -C "$git_top" cat-file -e "$base:.agent/config.env" 2>/dev/null; then
        rm -f -- "$tmp"
        return 3
    fi
    if ! git -C "$git_top" show "$base:.agent/config.env" >"$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        return 2
    fi
    keys_csv=$(IFS=,; printf '%s' "${keys[*]}")
    rc=0
    "$resolver" --repo-root "$git_top" --config-file "$tmp" \
        --canonical-keys "$keys_csv" 2>/dev/null || rc=$?
    rm -f -- "$tmp"
    return "$rc"
}

# A path counts as changed when the checkout has content the base does not, or
# when a base input was deleted here. Sentinel inputs are deliberately refused:
# they describe a command input that cannot be proven repository-contained.
# Emit every changed input so the refusal can be handed off as an adjudication
# request instead of forcing the operator to rediscover the comparison set.
yolo_changed_inputs=()
yolo_admitted_inputs=()
yolo_write_set_glob_regex() {
    local glob=$1 regex='^' char class class_closed class_start
    local i=0 length=${#1}
    while ((i < length)); do
        char=${glob:i:1}
        case $char in
            '*') regex+='[^/]*' ;;
            '?') regex+='[^/]' ;;
            '[')
                class='['
                class_closed=0
                class_start=$i
                i=$((i + 1))
                if ((i < length)) && [[ ${glob:i:1} == '!' ]]; then
                    class+='^'
                    i=$((i + 1))
                fi
                while ((i < length)); do
                    char=${glob:i:1}
                    class+=$char
                    i=$((i + 1))
                    if [[ $char == ']' ]]; then
                        class_closed=1
                        break
                    fi
                done
                if ((class_closed)); then
                    regex+=$class
                    continue
                fi
                regex+='\\['
                i=$((class_start + 1))
                continue
                ;;
            '.'|'^'|'$'|'+'|'('|')'|'{'|'}'|'|') regex+="\\$char" ;;
            *) regex+=$char ;;
        esac
        i=$((i + 1))
    done
    regex+='$'
    printf '%s' "$regex"
}
yolo_write_set_matches() {
    local rel=$1 glob prefix regex
    ((${#yolo_write_set_globs[@]})) || return 1
    for glob in "${yolo_write_set_globs[@]}"; do
        if [[ $glob == *'/**' ]]; then
            prefix=${glob%/**}
            regex=$(yolo_write_set_glob_regex "$prefix")
            regex=${regex%'$'}'(/.*)?$'
        else
            regex=$(yolo_write_set_glob_regex "$glob")
        fi
        [[ $rel =~ $regex ]] && return 0
    done
    return 1
}
yolo_changed_input() {
    local base=$1 rel abs untracked found=1
    yolo_changed_inputs=()
    yolo_admitted_inputs=()
    while IFS= read -r rel; do
        [[ -n $rel ]] || continue
        if is_command_input_sentinel "$rel"; then
            yolo_changed_inputs+=("$rel")
            found=0
            continue
        fi
        abs=$git_top/$rel
        if [[ -e $abs || -L $abs ]]; then
            if ! git -C "$git_top" cat-file -e "$base:$rel" 2> /dev/null; then
                if yolo_write_set_matches "$rel"; then
                    yolo_admitted_inputs+=("$rel")
                else
                    yolo_changed_inputs+=("$rel")
                    found=0
                fi
                continue
            fi
            if ! git -C "$git_top" diff --quiet "$base" -- "$rel" 2> /dev/null; then
                if yolo_write_set_matches "$rel"; then
                    yolo_admitted_inputs+=("$rel")
                else
                    yolo_changed_inputs+=("$rel")
                    found=0
                fi
                continue
            fi
            if [[ -d $abs ]]; then
                untracked=$(git -C "$git_top" status --porcelain=v1 \
                    --untracked-files=all --ignored=matching -- "$rel" 2> /dev/null || true)
                if [[ -n $untracked ]]; then
                    if yolo_write_set_matches "$rel"; then
                        yolo_admitted_inputs+=("$rel")
                    else
                        yolo_changed_inputs+=("$rel")
                        found=0
                    fi
                    continue
                fi
            fi
        elif git -C "$git_top" cat-file -e "$base:$rel" 2> /dev/null; then
            if yolo_write_set_matches "$rel"; then
                yolo_admitted_inputs+=("$rel")
            else
                yolo_changed_inputs+=("$rel")
                found=0
            fi
        fi
    done < <(yolo_repo_inputs | sort -u)
    return "$found"
}

yolo_refusal_remediation() {
    local base=$1 changed=$2 input runner
    printf '  remediation: this refusal is an adjudication request, not a dead end.\n' >&2
    printf '  input-diff digest against %s: hand off every changed command input, its diffstat, and its full diff before retrying.\n' \
        "$base" >&2
    printf '  changed command inputs:\n' >&2
    while IFS= read -r input; do
        [[ -n $input ]] || continue
        printf '    %s\n' "$input" >&2
    done <<< "$changed"
    printf -v runner '%q' "$self_dir/agent-run.sh"
    # Parallel workers run with --dir <worktree>. Without it the root re-runs this
    # from its own checkout, where the directory defaults to $PWD and the approval
    # is recorded against a different repository state than the one refused. This
    # is run_dir, the value --dir actually sets -- not work_dir, which AGENT_RUNDIR_*
    # moves to a component subdirectory.
    printf '  approve-with-record: %s --dir %q --approve --cmd %q (review the digest from an interactive terminal).\n' \
        "$runner" "$run_dir" "$cmd_name" >&2
    printf '  park-and-hand-off: preserve this workstream and hand off the digest plus that exact command; continue other workstreams.\n' >&2
    printf '  no approval record is created; approval is not implied by --yolo. Do not strip the input or retry with a literal command.\n' >&2
}

# A pinned base substitutes for the trunk anchor. Root-published only: the SHA
# must sit behind some origin ref (workers cannot push, so only the root can
# put a commit there) and be an ancestor of this worktree's HEAD. Same
# defense-in-depth level as the rest of the gate, no stronger claim.
yolo_pinned_base() {
    local sha=$1
    git -C "$git_top" cat-file -e "$sha^{commit}" 2> /dev/null ||
        die "--yolo-base: no such commit in this repository: $sha"
    # Remote-tracking refs are writable local files -- reachability from them
    # proves nothing about what the server carries. Ask origin itself: a pin is
    # trusted only when it IS a server-advertised head, or is an ancestor of one
    # (ancestry against a server-advertised SHA is content-addressed, so a local
    # forgery cannot satisfy it).
    local advertised='' candidate='' pin_ok=''
    advertised=$(git -C "$git_top" ls-remote --heads origin 2> /dev/null | awk '{print $1}') ||
        die "--yolo-base: cannot query origin to validate pin $sha; refusing."
    [[ -n $advertised ]] ||
        die "--yolo-base: origin advertises no heads to validate pin $sha against; refusing."
    while IFS= read -r candidate; do
        [[ -n $candidate ]] || continue
        if [[ $candidate == "$sha" ]]; then
            pin_ok=yes
            break
        fi
        if git -C "$git_top" cat-file -e "$candidate^{commit}" 2> /dev/null &&
            git -C "$git_top" merge-base --is-ancestor "$sha" "$candidate" 2> /dev/null; then
            pin_ok=yes
            break
        fi
    done <<< "$advertised"
    [[ -n $pin_ok ]] ||
        die "--yolo-base: $sha is not reachable from any origin ref advertised by the server; only root-published commits can anchor trust."
    git -C "$git_top" merge-base --is-ancestor "$sha" HEAD 2> /dev/null ||
        die "--yolo-base: $sha is not an ancestor of this worktree's HEAD."
    printf '%s' "$sha"
}

yolo_gate() {
    local base base_desc changed canonical_out rc key current_value base_value
    declare -A base_present=() base_values=() current_present=() current_values=()
    if [[ -n $yolo_base_opt ]]; then
        base=$(yolo_pinned_base "$yolo_base_opt")
    else
        base=$(yolo_base_ref) \
            || die '--yolo: no remote trunk ref to validate command inputs against; review the declaration and approve it from your own terminal instead.'
    fi
    # Every skip/refusal message below names this description rather than the
    # raw comparison target, so a chained worktree's operator sees which pin
    # authorized (or refused) the run instead of an unlabeled commit/ref.
    base_desc=$base
    [[ -n $yolo_base_opt ]] && base_desc="pinned base $base"
    if [[ $resolved_parse_failed == yes ]]; then
        printf 'agent-run: refusing --yolo for %s: AGENT_CMD_%s cannot be proven equal after config parse errors\n' \
            "$cmd_name" "$(printf '%s' "$cmd_name" | tr '[:lower:]-' '[:upper:]_')" >&2
        yolo_refusal_remediation "$base" '.agent/config.env'
        exit 1
    fi
    canonical_out=''
    rc=0
    canonical_out=$(yolo_base_declarations "$base") || rc=$?
    if ((rc == 2)); then
        die "--yolo: cannot read base .agent/config.env from $base"
    elif ((rc == 3)); then
        while IFS= read -r key; do
            [[ -n $key && -n ${resolved_config_present[$key]+yes} ]] || continue
            printf 'agent-run: refusing --yolo for %s: %s is declared on this checkout but missing from %s\n' \
                "$cmd_name" "$key" "$base_desc" >&2
            yolo_refusal_remediation "$base" ".agent/config.env (declaration $key)"
            exit 1
        done < <(printf '%s\n' "${relevant_config_keys[@]}" | LC_ALL=C sort -u)
        canonical_out=''
    elif ((rc != 0)); then
        die "--yolo: cannot parse base .agent/config.env from $base"
    fi
    while IFS='=' read -r key base_value; do
        [[ -n $key ]] || continue
        base_present[$key]=yes
        base_values[$key]=$base_value
    done <<< "$canonical_out"
    while IFS='=' read -r key current_value; do
        [[ -n $key ]] || continue
        current_present[$key]=yes
        current_values[$key]=$current_value
    done < <(canonical_relevant_lines)
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        if [[ -z ${current_present[$key]+yes} && -n ${base_present[$key]+yes} ||
            -n ${current_present[$key]+yes} && -z ${base_present[$key]+yes} ]]; then
            printf 'agent-run: refusing --yolo for %s: %s differs from %s\n' \
                "$cmd_name" "$key" "$base_desc" >&2
            yolo_refusal_remediation "$base" ".agent/config.env (declaration $key)"
            exit 1
        fi
        if [[ -n ${current_present[$key]+yes} && ${current_values[$key]} != "${base_values[$key]}" ]]; then
            printf 'agent-run: refusing --yolo for %s: %s differs from %s\n' \
                "$cmd_name" "$key" "$base_desc" >&2
            yolo_refusal_remediation "$base" ".agent/config.env (declaration $key)"
            exit 1
        fi
    done < <(printf '%s\n' "${relevant_config_keys[@]}" | LC_ALL=C sort -u)
    rc=0
    yolo_changed_input "$base" || rc=$?
    if ((${#yolo_admitted_inputs[@]})); then
        for admitted_input in "${yolo_admitted_inputs[@]}"; do
            printf 'agent-run: trust gate write-set admission: %s (inside declared write set)\n' \
                "$admitted_input" >&2
            add_note "trust gate write-set admission: $admitted_input (inside declared write set)"
        done
    fi
    if ((rc == 0 && ${#yolo_changed_inputs[@]})); then
        first=${yolo_changed_inputs[0]}
        changed=$(printf '%s\n' "${yolo_changed_inputs[@]}")
        printf 'agent-run: refusing --yolo for %s: %s differs from %s\n' \
            "$cmd_name" "$first" "$base_desc" >&2
        yolo_refusal_remediation "$base" "$changed"
        printf '  --yolo trusts only command inputs the trunk already carries. This checkout\n' >&2
        printf '  changes one or more, so it is new code asking to run unattended -- review the\n' >&2
        printf '  change and approve it from your own terminal.\n' >&2
        exit 1
    fi
    if ((${#yolo_admitted_inputs[@]})); then
        printf 'agent-run: trust gate skipped (--yolo): %s inputs match %s except declared-write-set admissions; no approval record\n' \
            "$cmd_name" "$base_desc" >&2
        add_note "trust gate skipped (--yolo): inputs match $base_desc except declared-write-set admissions; no approval record"
    else
        printf 'agent-run: trust gate skipped (--yolo): %s inputs match %s; no approval record\n' \
            "$cmd_name" "$base_desc" >&2
        add_note "trust gate skipped (--yolo): inputs match $base_desc; no approval record"
    fi
}

# Reuse the exact trunk comparison for the interactive refusal teaching line,
# without duplicating its config, runner, argv, and manifest rules. Run it in a
# subshell because yolo_gate deliberately exits on an unprovable or mismatched
# input and its audit note must not leak into the normal run.
trunk_inputs_match() {
    [[ $cmd_declared == yes ]] || return 1
    (yolo_gate >/dev/null 2>&1)
}

# Approval reads a confirmation from the controlling terminal. This is
# defense-in-depth, not a cryptographic human-only gate: an agent with arbitrary
# command execution can allocate a pseudo-terminal or write the trust record
# directly (same user), which no in-band check prevents. What it does buy is
# closing the failure this was filed for -- an agent reading the refusal below
# and re-running the exact `--approve` it printed -- since a non-interactive
# shell cannot answer the prompt. Enforced here in the tool rather than in a
# hook, whose command-line matcher fails open on ordinary shell spellings.
# A declined or absent confirmation records no trust.
require_human_approval() {
    local cmd_name=$1 reply
    # Scope the error suppression to the open attempt: a bare `exec ... 2>/dev/null`
    # would redirect this script's stderr for good, swallowing every later message.
    { exec 3< /dev/tty; } 2> /dev/null || die \
        "approval reads a confirmation from an interactive terminal, which this
  shell does not have. Review the declaration and approve it from your own
  terminal (a defense-in-depth check, not a human-only guarantee)."
    printf 'Approve repository command %s for this repository state? [y/N] ' \
        "$cmd_name" > /dev/tty
    IFS= read -r reply <&3 || reply=
    # Scope this the same way: a bare `exec ... 2>/dev/null` would redirect the
    # script's stderr permanently, not just for the fd-closing line.
    { exec 3<&-; } 2> /dev/null || true
    case $reply in
        y | Y | yes | YES | Yes) return 0 ;;
        *) die 'approval declined.' ;;
    esac
}

trust_command() {
    local trust_id current recorded temp
    [[ -n ${cmd_name:-} && -n ${git_top:-} ]] || return 0
    trust_root=$(trust_state_root)
    trust_id=$(sha256_text "$git_top\n$cmd_name\nfocus=$focus_opt")
    trust_file=$trust_root/$trust_id.trust
    trust_fingerprint=$(compute_trust_fingerprint)
    current=$trust_fingerprint

    if ((approve_cmd)); then
        require_human_approval "$cmd_name"
        temp=$trust_file.$$
        if ! printf '%s\n' "$current" > "$temp" 2>/dev/null; then
            die "cannot write temporary trust file: $temp"
        fi
        if ! chmod 600 -- "$temp" 2>/dev/null; then
            rm -f -- "$temp" 2>/dev/null || true
            die "cannot set private permissions on temporary trust file: $temp"
        fi
        if ! mv -f -- "$temp" "$trust_file" 2>/dev/null; then
            rm -f -- "$temp" 2>/dev/null || true
            die "cannot atomically replace trust file: $trust_file"
        fi
        printf 'agent-run: approved %s for this repository state\n' "$cmd_name" >&2
        exit 0
    fi

    recorded=$(cat -- "$trust_file" 2>/dev/null || true)
    [[ $recorded == "$current" ]] && return 0
    printf 'agent-run: refusing unapproved repository command: %s\n' "$cmd_name" >&2
    printf '  The declaration or a repository-backed command input is new or changed.\n' >&2
    printf '  A human reviews the change and approves it from a terminal with --approve;\n' >&2
    printf '  that terminal confirmation is defense-in-depth, not a human-only guarantee.\n' >&2
    if [[ -t 2 ]] && trunk_inputs_match; then
        printf '  An operator-granted --yolo/--trust-trunk run would thread this command without approval.\n' >&2
    fi
    return 1
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

print_notes() {
    local prefix=$1 n
    ((${#notes[@]})) || return 0
    for n in "${notes[@]}"; do
        printf '%snote: %s\n' "$prefix" "$n"
    done
}

# Compose's dependency-start messages are often the only durable signal that
# concurrent worktrees contended for a container, port, or network. Require a
# Compose/dependency context plus a collision/startup signature so ordinary
# assertion and application failures remain ordinary command failures.
compose_dependency_start_collision() {
    local log=$1
    grep -Eiq '(^|[^[:alnum:]_-])docker([[:space:]]+|-)compose([^[:alnum:]_-]|$)' \
        "$log" 2>/dev/null || return 1
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
    if ((rc == 127)) && [[ $literal_root_fallback == yes ]]; then
        printf '  note: rc=127 indicates argv[0] %s was found from repository root %s but not from execution cwd %s; fix the declaration to use the execution base, and do not add a literal twin to route around approval.\n' \
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

# ------------------------------------------------------------ command stamp ---
# Record that THIS named command covered the tree as of now. The Stop hook
# compares the stamp for the command it asks for against the files git reports as
# changed, so the stamp is named after the command that wrote it: one file per
# name, never a shared "something passed" flag. A single flag would let a passing
# lint satisfy a check that asked for verify -- and a repository could disarm the
# whole gate by declaring a trivial command under some other name.
#
# What may write one is otherwise the whole contract: a SUCCESSFUL run of a
# command the repository NAMED. A literal command is the caller's own business and
# says nothing about whether the repository's own gate passed.
#
# The delegating path below never reaches here, and does not need to: a declared
# AGENT_CMD_* is exactly what makes cmd_declared=yes and skips delegation, and it
# is also the only thing the Stop hook treats as an opt-in.
#
# The name is safe as a filename: resolve_named_command refuses anything but
# lowercase letters, digits and dashes before this can run.
#
# Best-effort throughout -- a read-only or absent .agent/ must never turn a
# passing run into a failing one.
write_command_stamp() {
    local stamp_dir
    [[ -n ${git_top:-} ]] || return 0
    [[ -n ${cmd_name:-} ]] || return 0
    stamp_dir=$git_top/.agent/cache
    mkdir -p -- "$stamp_dir" 2>/dev/null || return 0
    : >"$stamp_dir/stamp-$cmd_name" 2>/dev/null || true
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
compute_tree_hash() {
    local hash_input digest
    [[ -n ${git_top:-} ]] || return 1
    hash_input=$(mktemp "${TMPDIR:-/tmp}/agent-run-tree.XXXXXX") || return 1
    if ! : >"$hash_input" ||
        ! git -C "$git_top" rev-parse HEAD >>"$hash_input" ||
        ! printf '\0' >>"$hash_input" ||
        ! printf 'command\0%s\0focus\0%s\0' "$cmd_name" "$focus_opt" >>"$hash_input" ||
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

# Resolve the directory before trust and verification identity are computed.
# This keeps --dir, repository-declared rundirs, and package-root adjustments
# scoped to the exact directory where the command will execute.
maybe_use_package_dir
canonicalise_work_dir
resolve_literal_executable

# --yolo skips the approval record for this one invocation -- when the trunk
# already carries the command's inputs (see yolo_gate). Measured in a live
# unattended fleet: three workers dead-ended reporting BLOCKED at this refusal,
# and a fourth piped `y` through `script -qec` to forge the terminal
# confirmation, then reported the result as approved. A gate that cannot bind
# an agent but can stall or corrupt one is worse than an explicit, logged
# opt-out: the flag puts the bypass in the transcript instead of disguising it
# as an approval. The human authorization is the unattended invocation the
# flag was threaded down from -- and it covers trunk-reviewed inputs only.
if [[ -n $cmd_name ]]; then
    if ((yolo_cmd)); then
        yolo_gate
    else
        trust_command || die "command '$cmd_name' is not approved"
    fi
fi

# Configure the per-worktree Compose namespace only for a named command. This
# happens after trust adjudication so the derived runtime value is not mistaken
# for repository-controlled command input, and before either delegation or
# execution so every declared command sees it.
configure_compose_project

tree_hash=''
if verification_cache_eligible; then
    tree_hash=$(compute_tree_hash 2>/dev/null || true)
    if [[ -n $tree_hash ]] && verification_cache_hit "$tree_hash"; then
        write_command_stamp
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
LOG_HEADER_LINES=2
if ((yolo_cmd)) && [[ -n $cmd_name ]]; then
    admission_count=0
    if ((${#yolo_admitted_inputs[@]})); then
        admission_count=${#yolo_admitted_inputs[@]}
    fi
    LOG_HEADER_LINES=$((3 + admission_count))
fi
readonly LOG_HEADER_LINES
{
    printf '=== agent-run %s\n' "$cmd_str"
    printf '=== started %s  pid=%s  cwd=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || printf 'unknown')" "$$" "$work_dir"
    # The skip must survive in the durable artifact, not only on the process's
    # stderr -- an after-the-fact audit reads logs, and a bypassed run must not
    # read as an approved one.
    if ((yolo_cmd)) && [[ -n $cmd_name ]]; then
        printf '=== trust gate skipped (--yolo): no approval record\n'
        if ((${#yolo_admitted_inputs[@]})); then
            for admitted_input in "${yolo_admitted_inputs[@]}"; do
                printf '=== trust gate write-set admission: %s (inside declared write set)\n' \
                    "$admitted_input"
            done
        fi
    fi
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
trap - INT TERM
elapsed=$((SECONDS - started_at))
lines=$(($(wc -l < "$log_file" | tr -d '[:space:]') - LOG_HEADER_LINES))
((lines >= 0)) || lines=0
if ((rc != 0)) && compose_dependency_start_collision "$log_file"; then
    printf '=== finding environment-retry-eligible: compose dependency-start collision (not a code regression)\n' >> "$log_file"
fi
printf '=== agent-run exited rc=%s after %ss\n' "$rc" "$elapsed" >> "$log_file"

if ((rc == 0)); then
    write_command_stamp
    [[ -n $tree_hash ]] && record_verification "$tree_hash" "$log_file"
    printf 'PASS: %s (%s lines suppressed -> %s)\n' "$cmd_str" "$lines" "$log_file"
else
    report_failure "$rc" "$log_file"
fi
exit "$rc"
