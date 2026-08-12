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
Usage: agent-run.sh [--dir PATH] [--label NAME] [--approve|--yolo] [--force] [--only NAME[,NAME...]] (--cmd NAME | [--] <command> ...)

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
  --force        Execute a named command even when green evidence is current.
  --only NAME[,NAME...]  For --cmd test, use the repository's
                 AGENT_CMD_TEST_FOCUS declaration and pass names through its %s placeholder.
  --if-declared  With --cmd, exit 0 quietly when the repository declares no such
                 command. For a command a skill treats as optional.
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
cmd=()
focus_opt=''
focus_requested=0
approve_cmd=0
yolo_cmd=0
force_cmd=0
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

if ((focus_requested)); then
    [[ -n $focus_opt ]] || die '--only requires a non-empty value.'
    [[ -n $cmd_name ]] || die '--only requires --cmd test.'
fi

if [[ -n $cmd_name ]]; then
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

# A literal executable path is an ad-hoc command, not a repository declaration.
# Resolve its relative form from the repository toplevel so `--dir nested --
# ./tools/check` has the same meaning as the same command from the root. Plain
# names deliberately fall through to PATH lookup. When the token cannot be
# proven to name a contained executable, leave it untouched so the wrapped
# command supplies its normal failure status while the diagnostic records both
# the execution cwd and the toplevel-resolution result.
resolve_literal_executable() {
    local token=${cmd[0]} candidate resolved
    [[ $cmd_declared == no && $token == */* ]] || return 0
    [[ $token != /* && -n $git_top ]] || return 0

    candidate=$git_top/$token
    resolved=$(readlink -f -- "$candidate" 2>/dev/null || true)
    if [[ -n $resolved && $resolved == "$git_top"/* && -x $resolved && ! -d $resolved ]]; then
        cmd[0]=$resolved
        add_note "ad-hoc argv[0] '$token' resolved at toplevel: yes ($resolved); execution cwd: $work_dir"
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
    local resolver=$self_dir/repo-config.sh key tmp field argc i
    local -a keys=("$@")
    local -a resolve_args=(--repo-root "${git_top:-$run_dir}")
    tmp=$(mktemp "${TMPDIR:-/tmp}/agent-run-config.XXXXXX") || return 1
    for key in "${keys[@]}"; do
        [[ -n $key ]] || continue
        relevant_config_add "$key"
        resolve_args+=(--resolve "$key")
    done
    if ! "$resolver" "${resolve_args[@]}" >"$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    exec 3<"$tmp" || { rm -f -- "$tmp"; return 1; }
    while IFS= read -r -d '' field <&3; do
        key=$field
        if [[ $key == __AGENT_CONFIG_PARSE_STATUS__ ]]; then
            IFS= read -r -d '' field <&3 || {
                exec 3<&-
                rm -f -- "$tmp"
                return 1
            }
            [[ $field == 0 || $field == 1 ]] || {
                exec 3<&-
                rm -f -- "$tmp"
                return 1
            }
            [[ $field == 1 ]] && resolved_parse_failed=yes
            continue
        fi
        IFS= read -r -d '' field <&3 || { exec 3<&-; rm -f -- "$tmp"; return 1; }
        resolved_config_values[$key]=$field
        resolved_config_present[$key]=yes
        IFS= read -r -d '' field <&3 || { exec 3<&-; rm -f -- "$tmp"; return 1; }
        [[ $field =~ ^[0-9]+$ ]] || { exec 3<&-; rm -f -- "$tmp"; return 1; }
        argc=$field
        local -a parsed=()
        for ((i = 0; i < argc; i++)); do
            IFS= read -r -d '' field <&3 || { exec 3<&-; rm -f -- "$tmp"; return 1; }
            parsed+=("$field")
        done
        if [[ $key == "$resolved_command_key" ]]; then
            resolved_command_argv=("${parsed[@]}")
        elif [[ $key == AGENT_CMD_TEST_FOCUS ]]; then
            resolved_focus_argv=("${parsed[@]}")
        fi
    done
    exec 3<&-
    rm -f -- "$tmp"
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
    command_input_paths
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
yolo_changed_input() {
    local base=$1 rel abs untracked
    while IFS= read -r rel; do
        [[ -n $rel ]] || continue
        if is_command_input_sentinel "$rel"; then
            printf '%s' "$rel"
            return 0
        fi
        abs=$git_top/$rel
        if [[ -e $abs || -L $abs ]]; then
            if ! git -C "$git_top" cat-file -e "$base:$rel" 2> /dev/null; then
                printf '%s' "$rel"
                return 0
            fi
            if ! git -C "$git_top" diff --quiet "$base" -- "$rel" 2> /dev/null; then
                printf '%s' "$rel"
                return 0
            fi
            if [[ -d $abs ]]; then
                untracked=$(git -C "$git_top" status --porcelain=v1 \
                    --untracked-files=all --ignored=matching -- "$rel" 2> /dev/null || true)
                if [[ -n $untracked ]]; then
                    printf '%s' "$rel"
                    return 0
                fi
            fi
        elif git -C "$git_top" cat-file -e "$base:$rel" 2> /dev/null; then
            printf '%s' "$rel"
            return 0
        fi
    done < <(yolo_repo_inputs | sort -u)
    return 1
}

yolo_gate() {
    local base changed canonical_out rc key current_value base_value
    declare -A base_present=() base_values=() current_present=() current_values=()
    base=$(yolo_base_ref) \
        || die '--yolo: no remote trunk ref to validate command inputs against; review the declaration and approve it from your own terminal instead.'
    if [[ $resolved_parse_failed == yes ]]; then
        printf 'agent-run: refusing --yolo for %s: AGENT_CMD_%s cannot be proven equal after config parse errors\n' \
            "$cmd_name" "$(printf '%s' "$cmd_name" | tr '[:lower:]-' '[:upper:]_')" >&2
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
                "$cmd_name" "$key" "$base" >&2
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
                "$cmd_name" "$key" "$base" >&2
            exit 1
        fi
        if [[ -n ${current_present[$key]+yes} && ${current_values[$key]} != "${base_values[$key]}" ]]; then
            printf 'agent-run: refusing --yolo for %s: %s differs from %s\n' \
                "$cmd_name" "$key" "$base" >&2
            exit 1
        fi
    done < <(printf '%s\n' "${relevant_config_keys[@]}" | LC_ALL=C sort -u)
    if changed=$(yolo_changed_input "$base"); then
        printf 'agent-run: refusing --yolo for %s: %s differs from %s\n' \
            "$cmd_name" "$changed" "$base" >&2
        printf '  --yolo trusts only command inputs the trunk already carries. This checkout\n' >&2
        printf '  changes one, so it is new code asking to run unattended -- review the\n' >&2
        printf '  change and approve it from your own terminal.\n' >&2
        exit 1
    fi
    printf 'agent-run: trust gate skipped (--yolo): %s inputs match %s; no approval record\n' \
        "$cmd_name" "$base" >&2
    add_note "trust gate skipped (--yolo): inputs match $base; no approval record"
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
    LOG_HEADER_LINES=3
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
printf '=== agent-run exited rc=%s after %ss\n' "$rc" "$elapsed" >> "$log_file"

if ((rc == 0)); then
    write_command_stamp
    [[ -n $tree_hash ]] && record_verification "$tree_hash" "$log_file"
    printf 'PASS: %s (%s lines suppressed -> %s)\n' "$cmd_str" "$lines" "$log_file"
else
    report_failure "$rc" "$log_file"
fi
exit "$rc"
