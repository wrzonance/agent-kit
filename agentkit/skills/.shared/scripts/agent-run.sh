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
# Usage: agent-run.sh [--dir PATH] [--label NAME] (--cmd NAME | [--] <command> ...)
# Exit status: the wrapped command's status (this script's own usage errors exit 1).

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: agent-run.sh [--dir PATH] [--label NAME] (--cmd NAME | [--] <command> ...)

Runs one command with a sandbox-safe environment and a compact result summary.
  --dir PATH     Working directory for the command (default: current directory).
  --label NAME   Label used in the log file name (default: the command's basename).
  --cmd NAME     Run the command this repository declares under that name, instead
                 of spelling one out. Mutually exclusive with a literal command.
  --             End of options; everything after it is the command.
  -h, --help     Show this help and exit 0.

Environment:
  AGENT_CACHE_ROOT    Force cache dirs under this root (otherwise a fallback root
                      is used only when the normal cache home is unusable).
  AGENT_REPO_RUNNER   Path to a repository command runner to delegate to.

Repository declarations (<git-toplevel>/.agent/config.env):
  AGENT_RUNDIR_<NAME> Directory to run that command in, relative to the repo root.
  AGENT_CMD_<NAME>    What `--cmd <name>` runs here. Values are argv: split on
                      whitespace and exec'd directly, never through a shell. A
                      path-shaped first word must resolve inside the repository.
  AGENT_REPO_RUNNER   Runner to delegate to, as a repository-relative path.

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
cmd=()
# Set when the command came from an AGENT_CMD_* declaration, which is the whole
# argv and so must not be handed to the runner as a subcommand.
cmd_declared=no

while (($#)); do
    case $1 in
        --dir|--label|--cmd)
            (($# >= 2)) || die "Missing value for $1."
            case $1 in
                --dir) dir_opt=$2 ;;
                --label) label=$2 ;;
                *) cmd_name=$2 ;;
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

if [[ -n $cmd_name ]]; then
    ((${#cmd[@]} == 0)) || die '--cmd NAME and a literal command are mutually exclusive.'
else
    ((${#cmd[@]})) || die 'No command given.'
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
    [[ -x $resolver ]] || return 1
    "$resolver" --repo-root "${git_top:-$run_dir}" --get "$key" 2>/dev/null
}

# ------------------------------------------------------------------- runner ---
runner_path='' runner_src=''

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
    [[ $name =~ ^[a-z][a-z0-9-]*$ ]] ||
        die "--cmd NAME must be lowercase letters, digits and dashes, got: $name"

    # The name is also the natural log label, and it survives resolution.
    [[ -n $label ]] || label=$name

    local upper rundir
    upper=$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')
    key="AGENT_CMD_$upper"
    declared=$(repo_config_get "$key" || true)
    if [[ -n $declared ]]; then
        # Word-split deliberately: the value is argv, and repo-config.sh has
        # already refused every character a shell would interpret.
        read -r -a cmd <<< "$declared"
        cmd_declared=yes

        # A monorepo command usually has to run IN its component. Without this
        # the only root-runnable form of a dashboard test invocation globbed
        # into node_modules and started running a dependency's test suite.
        rundir=$(repo_config_get "AGENT_RUNDIR_$upper" || true)
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
    if resolve_runner; then
        cmd=("$name")
        return 0
    fi

    die "no command named '$name': declare $key in .agent/config.env, or add .agent/runner"
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

report_failure() {
    local rc=$1 log=$2 excerpt
    printf 'FAIL(rc=%s): %s\n' "$rc" "$cmd_str"
    printf '  cwd=%s runner=none\n' "$work_dir"
    print_notes '  '
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

# --------------------------------------------------------------------- main ---
if [[ -n $cmd_name ]]; then
    resolve_named_command "$cmd_name"
fi
finalise_label
refresh_cmd_str

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
maybe_use_package_dir
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

rc=0
(cd -- "$work_dir" && exec "${cmd[@]}") >"$log_file" 2>&1 || rc=$?
if ((rc == 0)); then
    write_command_stamp
    lines=$(wc -l <"$log_file" | tr -d '[:space:]')
    printf 'PASS: %s (%s lines suppressed -> %s)\n' "$cmd_str" "$lines" "$log_file"
else
    report_failure "$rc" "$log_file"
fi
exit "$rc"
