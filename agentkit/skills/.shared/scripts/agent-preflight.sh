#!/usr/bin/env bash
#
# agent-preflight.sh -- declare the agent's sandbox environment ONCE, before the first command.
#
# WHY THIS EXISTS
#   Agents routinely burn a failed command, a retry, and a paragraph of narration
#   rediscovering facts that were knowable before any work started: the uv/npm/pip cache
#   under $HOME is read-only; a package script was invoked from a directory with no package.json;
#   an import failed because the python source root was not on PYTHONPATH; `git add` died
#   on "<git-dir>/index.lock: Read-only file system"; a reviewer CLI probe failed because
#   the peer review CLI is not installed here. This probes all of it once and prints a declarative
#   block that becomes the agent's working memory. The verbosity is deliberate: one
#   upfront declaration replaces N rediscoveries-by-failure.
#
# BEHAVIOUR
#   Reports, never blocks -- missing facts are printed as missing and the exit status is
#   still 0, so no caller can be wedged by its own preflight. Only account-scoped forge
#   state is probed (never repository-scoped), the repository slug is parsed locally from
#   the origin URL, and the only writes are under <worktree>/.agent/.
#
# OUTPUT (stdout, exactly one key per line, in this order; diagnostics go to stderr)
#   repo= branch= worktree= base= git= gh= sandbox= tls= caches= runners= harness= peer-cli=
#   The same block is written to <worktree>/.agent/env-contract.txt unless suppressed.
#
set -euo pipefail

ARG_WORKTREE=""
ARG_REPO=""
ARG_WRITE=""
ARG_NO_WRITE=0
WORKTREE=""
IN_REPO=0
OUT_LINES=()

# Known system CA bundle / cert dir locations (Debian, RHEL, SUSE, Alpine/BSD).
SYSTEM_BUNDLES=(
    /etc/ssl/certs/ca-certificates.crt
    /etc/pki/tls/certs/ca-bundle.crt
    /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
    /etc/ssl/ca-bundle.pem
    /etc/ssl/cert.pem
)
SYSTEM_CERT_DIRS=(/etc/ssl/certs /etc/pki/tls/certs /etc/pki/ca-trust/extracted/pem)
CA_ENV_VARS=(SSL_CERT_FILE REQUESTS_CA_BUNDLE CURL_CA_BUNDLE NODE_EXTRA_CA_CERTS)

usage() {
    cat <<'EOF'
agent-preflight.sh -- declare the agent's sandbox environment once, up front.

Usage:
  agent-preflight.sh [--worktree PATH] [--repo OWNER/REPO] [--write FILE | --no-write] [-h|--help]

Options:
  --worktree PATH    Worktree to describe (default: git toplevel of the cwd, else the cwd).
  --repo OWNER/REPO  Use this slug instead of parsing one from the origin remote.
  --write FILE       Write the block here (default: <worktree>/.agent/env-contract.txt).
  --no-write         Print the block only; write no file.
  -h, --help         Print this help and exit 0.

Prints one key per line: repo= branch= worktree= base= config= git= gh= sandbox= tls= caches= runners= harness= peer-cli=

Exit: 0 always, including when tools or facts are missing (they are reported as missing);
      2 only for invalid usage.
EOF
}

note() { printf 'agent-preflight: %s\n' "$*" >&2; }
emit() { OUT_LINES+=("$1"); }

die() {
    printf 'agent-preflight: error: %s\n' "$*" >&2
    printf 'agent-preflight: run "agent-preflight.sh --help" for usage\n' >&2
    exit 2
}

join_by() {
    local sep="$1" out="" item
    shift
    for item in "$@"; do out+="${out:+$sep}$item"; done
    printf '%s' "$out"
}

# Join, but cap the list so one sprawling monorepo cannot flood the block; say how many
# were dropped rather than truncating silently.
join_capped() {
    local cap="$1"
    shift
    if (( $# <= cap )); then join_by , "$@"; return 0; fi
    join_by , "${@:1:cap}"
    printf '+%d-more' "$(( $# - cap ))"
}

contains() {
    local needle="$1" item
    shift
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then return 0; fi
    done
    return 1
}

need_value() {
    if (( $# < 2 )) || [[ "$2" == --* ]]; then die "$1 requires a value"; fi
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)  usage; exit 0 ;;
            --worktree) need_value "$@"; ARG_WORKTREE="$2"; shift 2 ;;
            --repo)     need_value "$@"; ARG_REPO="$2"; shift 2 ;;
            --write)    need_value "$@"; ARG_WRITE="$2"; ARG_NO_WRITE=0; shift 2 ;;
            --no-write) ARG_NO_WRITE=1; ARG_WRITE=""; shift ;;
            --)         shift; break ;;
            -*)         die "unknown option: $1" ;;
            *)          die "unexpected argument: $1 (this command takes options only)" ;;
        esac
    done
    if (( $# > 0 )); then die "unexpected argument: $1 (this command takes options only)"; fi
    if [[ -n "$ARG_REPO" && ! "$ARG_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        die "--repo must look like OWNER/REPO, got: $ARG_REPO"
    fi
    if [[ -n "$ARG_WORKTREE" && ! -d "$ARG_WORKTREE" ]]; then
        die "--worktree is not a directory: $ARG_WORKTREE"
    fi
}

# Nearest existing ancestor, so writability can be tested without creating anything.
nearest_existing() {
    local d="$1" parent
    while [[ -n "$d" && ! -e "$d" ]]; do
        parent="${d%/*}"
        if [[ -z "$parent" || "$parent" == "$d" ]]; then parent="/"; fi
        d="$parent"
    done
    printf '%s' "${d:-/}"
}

# True only when a file can actually be created in the directory. Permission bits lie
# about read-only mounts, and a read-only mount is exactly the case that breaks agents.
dir_writable() {
    local target probe
    target="$(nearest_existing "$1")"
    [[ -d "$target" ]] || return 1
    probe="$(mktemp "$target/.agent-preflight-XXXXXX" 2>/dev/null)" || return 1
    rm -f -- "$probe" 2>/dev/null || true
}

bounded() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

# git -C DIR rev-parse prints git dirs RELATIVE TO DIR, so they must be resolved against
# the worktree and never against the caller's cwd.
abs_in_worktree() {
    local p="$1"
    case "$p" in /*) ;; *) p="$WORKTREE/$p" ;; esac
    readlink -f -- "$p" 2>/dev/null || printf '%s' "$p"
}

relative_to_top() {
    local rel="${1#"$WORKTREE"}"
    rel="${rel#/}"
    printf '%s' "${rel:-.}"
}

# Filters match the worktree-relative path, never the absolute one: a worktree living
# under a dotted parent must not filter itself away.
skip_relative_path() {
    case "/$1" in
        */node_modules/*|*/.*|*/venv/*|*/site-packages/*) return 0 ;;
        *) return 1 ;;
    esac
}

# OWNER/REPO from an origin URL, parsed locally: a forge round trip just to learn the slug
# costs latency and fails offline. Takes the last two path segments, which is the
# owner/name pair for every forge URL form (ssh, scp-style, https, with or without .git).
parse_repo_slug() {
    local url="$1" path owner name
    url="${url%.git}"
    url="${url%/}"
    if [[ "$url" == *://* ]]; then
        path="${url#*://}"
        path="${path#*@}"
        path="${path#*/}"
    elif [[ "$url" == *:* ]]; then
        path="${url#*:}"
    else
        return 1 # a bare filesystem path: a local clone, not a forge repository
    fi
    [[ "$path" == */* ]] || return 1
    name="${path##*/}"
    owner="${path%/*}"
    owner="${owner##*/}"
    [[ "$owner/$name" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
    printf '%s/%s' "$owner" "$name"
}

# Base branch from local refs only -- never a fetch.
detect_base() {
    local ref candidate namespace
    if ref="$(git -C "$WORKTREE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
        printf 'base=%s source=refs/remotes/origin/HEAD' "${ref#*/}"
        return 0
    fi
    for namespace in refs/remotes/origin refs/heads; do
        for candidate in main master trunk develop; do
            if git -C "$WORKTREE" show-ref --verify --quiet "$namespace/$candidate"; then
                printf 'base=%s source=%s/%s' "$candidate" "$namespace" "$candidate"
                return 0
            fi
        done
    done
    printf 'base=none source=none note="no origin/HEAD and no conventional base ref locally"'
}

# WORKTREE is always normalised to the git toplevel when inside a repo, so .agent/ always
# lands at the worktree root and relative git paths resolve correctly.
resolve_worktree() {
    local start top
    start="$(readlink -f -- "${ARG_WORKTREE:-$PWD}")"
    if top="$(git -C "$start" rev-parse --show-toplevel 2>/dev/null)"; then
        IN_REPO=1
        WORKTREE="$(readlink -f -- "$top")"
        if [[ "$WORKTREE" != "$start" ]]; then note "normalised worktree to its git toplevel: $WORKTREE"; fi
    else
        IN_REPO=0
        WORKTREE="$start"
    fi
}

probe_identity() {
    local slug origin branch
    if (( ! IN_REPO )); then
        emit "repo=${ARG_REPO:-none note=\"not inside a git repository\"}"
        emit "branch=none"
        emit "worktree=$WORKTREE"
        emit "base=none source=none"
        return 0
    fi
    if [[ -n "$ARG_REPO" ]]; then
        slug="$ARG_REPO"
    elif origin="$(git -C "$WORKTREE" remote get-url origin 2>/dev/null)"; then
        slug="$(parse_repo_slug "$origin")" || slug='none origin=not-a-forge-url'
    else
        slug='none origin=absent'
    fi
    branch="$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')"
    if [[ "$branch" == "HEAD" ]]; then branch="detached"; fi
    emit "repo=$slug"
    emit "branch=$branch"
    emit "worktree=$WORKTREE"
    emit "$(detect_base)"
}

# What the repository declared about itself. This tells the agent which facts below
# came from a committed file rather than from probing -- and, when a config exists but
# supplies nothing, that its keys were rejected rather than absent.
probe_config() {
    local self_dir resolver listing count keys shown extra
    self_dir="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
    resolver="$self_dir/repo-config.sh"
    listing=""

    if [[ -x "$resolver" && -n "$WORKTREE" ]]; then
        listing="$("$resolver" --repo-root "$WORKTREE" --list 2>/dev/null || true)"
    fi
    if [[ -z "$listing" ]]; then
        emit 'config= present=no keys=0 supplied=none'
        return 0
    fi

    count="$(printf '%s\n' "$listing" | grep -c '=' || true)"
    # Name only the first few: this block is read on every run, and a dozen key
    # names would cost more than the fact they convey.
    shown="$(printf '%s\n' "$listing" | cut -d= -f1 | head -n 4 | paste -sd, -)"
    extra=$(( count > 4 ? count - 4 : 0 ))
    keys="$shown"
    if (( extra > 0 )); then keys="$shown,+$extra more"; fi
    emit "config= present=yes keys=$count supplied=\"$keys\""
}

# A read-only real git dir is the most expensive surprise in a sandbox: it turns every
# later `git add` into "index.lock: Read-only file system". Test it by creating a file.
probe_git() {
    local common gitdir line
    if (( ! IN_REPO )); then
        emit 'git= common-dir=none writable=unknown note="not inside a git repository"'
        return 0
    fi
    common="$(git -C "$WORKTREE" rev-parse --git-common-dir 2>/dev/null || printf '')"
    if [[ -z "$common" ]]; then
        emit 'git= common-dir=none writable=unknown note="git rev-parse --git-common-dir failed"'
        return 0
    fi
    gitdir="$(git -C "$WORKTREE" rev-parse --git-dir 2>/dev/null || printf '%s' "$common")"
    common="$(abs_in_worktree "$common")"
    gitdir="$(abs_in_worktree "$gitdir")"
    if dir_writable "$common"; then
        line="git= common-dir=$common writable=yes"
    else
        line="git= common-dir=$common writable=no note=\"first write needs elevation\""
    fi
    if [[ "$gitdir" != "$common" ]]; then
        if dir_writable "$gitdir"; then
            line+=" gitdir=$gitdir gitdir-writable=yes"
        else
            line+=" gitdir=$gitdir gitdir-writable=no note2=\"index.lock lives here; git add fails read-only\""
        fi
    fi
    emit "$line"
}

# Account-scoped only: never touch a repository-scoped endpoint, and never let a forge
# failure abort the preflight.
probe_gh() {
    local status_out="" scopes authed="no" api="unreachable" account="" project="unknown"
    if ! command -v gh >/dev/null 2>&1; then
        emit 'gh= authed=no scopes=none api=unreachable note="gh CLI not installed"'
        return 0
    fi
    # Captured for scopes and diagnostics, NOT as the verdict: gh auth status
    # exits non-zero when any configured entry fails, even while a working
    # account appears in the same output. Whether a call succeeds is the only
    # question that predicts whether the next command works.
    status_out="$(bounded 20 gh auth status 2>&1 || true)"
    scopes="$(printf '%s\n' "$status_out" | grep -i -m1 'token scopes' || true)"
    scopes="${scopes#*:}"
    scopes="${scopes//\'/}"
    scopes="${scopes// /}"
    if [[ -z "$scopes" ]]; then
        scopes="unknown"
    else
        project="no"
        if [[ ",$scopes," == *",project,"* || ",$scopes," == *",read:project,"* ]]; then project="yes"; fi
    fi
    if account="$(bounded 20 gh api user --jq .login 2>/dev/null)"; then
        authed="yes"
        api="reachable"
    fi
    account="${account%%$'\n'*}" # one key per line is the block's invariant

    # When gh says no, say WHY. "gh is not authenticated" on a machine where the
    # user just ran `gh auth status` successfully reads as the tooling being
    # broken, and the next move is a guess. The distinction that matters is
    # whether a token exists at all or whether THIS process cannot use the one
    # that does -- a token in the system keyring is reachable from a login shell
    # and may not be from wherever an agent's commands actually run.
    local why=""
    if [[ $authed == no ]]; then
        local src="none" envtok="no"
        [[ -z ${GH_TOKEN:-}${GITHUB_TOKEN:-} ]] || envtok="yes"
        if grep -q 'oauth_token' "${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml" 2>/dev/null; then
            src="config-file"
        elif [[ -s ${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml ]]; then
            # An account is configured but its token is not in the file, so it
            # lives in the OS keyring -- the case that fails per-process.
            src="keyring"
        fi
        why=" token-source=$src env-token=$envtok config-dir=${GH_CONFIG_DIR:-$HOME/.config/gh}"
        why+=" detail=\"$(printf '%s' "$status_out" | tr '\n' ';' | tr -d '"' | cut -c1-160)\""
    fi

    emit "gh= authed=$authed scopes=$scopes api=$api${account:+ account=$account} project-scope=$project$why"
}

# The agent sandbox is the single biggest source of "mystery" command failures:
# a read-only /, a read-only $HOME (package-manager caches), a read-only .git
# (every git write), and disabled networking (every forge call) all surface as
# unrelated-looking errors. Report them as facts so nothing is learned by failing.
probe_sandbox() {
    local sandboxed=no network=ok profile=none root_opts
    root_opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
    [[ ",$root_opts," == *",ro,"* || $root_opts == ro* ]] && sandboxed=yes
    [[ -n ${CODEX_SANDBOX_NETWORK_DISABLED:-} ]] && { network=disabled; sandboxed=yes; }
    [[ -n ${CODEX_PERMISSION_PROFILE:-} ]] && { profile=$CODEX_PERMISSION_PROFILE; sandboxed=yes; }
    if [[ $network == ok ]] && ! bounded 5 getent hosts github.com >/dev/null 2>&1; then
        network=unresolved
    fi
    local note=""
    if [[ $sandboxed == yes ]]; then
        note=' note="escalate git writes and forge calls; only the workspace is writable"'
    fi
    emit "sandbox= active=$sandboxed profile=$profile network=$network home-writable=$(dir_writable_word "${HOME:-}")$note"
}

dir_writable_word() {
    local d=${1:-} p
    [[ -d $d ]] || { printf 'unknown'; return 0; }
    p=$d/.preflight-probe.$$
    if : >"$p" 2>/dev/null; then rm -f -- "$p"; printf 'yes'; else printf 'no'; fi
}

# Conservative: a corporate/MITM CA is only reported as *likely* when a bundle exists AND
# the environment or the cert dir already points somewhere that is not a system default.
probe_tls() {
    local bundle="" source="none" corporate="no" var path uv_flag preset_str
    local -a preset=()
    for var in "${CA_ENV_VARS[@]}"; do
        [[ -n "${!var:-}" ]] || continue
        preset+=("$var")
        if [[ -z "$bundle" ]]; then bundle="${!var}"; source="env:$var"; fi
    done
    if [[ -z "$bundle" ]]; then
        for path in "${SYSTEM_BUNDLES[@]}"; do
            if [[ -f "$path" ]]; then bundle="$path"; source="system"; break; fi
        done
    fi
    preset_str="$(join_by , "${preset[@]+"${preset[@]}"}")"
    if [[ -z "$bundle" ]]; then
        emit "tls= bundle=\"none detected\" source=none corporate-ca=unknown preset=${preset_str:-none} uv-system-certs=unknown"
        return 0
    fi
    if ! contains "$bundle" "${SYSTEM_BUNDLES[@]}"; then corporate="likely"; fi
    if [[ -n "${SSL_CERT_DIR:-}" ]] && ! contains "${SSL_CERT_DIR}" "${SYSTEM_CERT_DIRS[@]}"; then
        corporate="likely"
    fi
    uv_flag="not-needed"
    if [[ "$corporate" == "likely" ]]; then
        uv_flag='required note="agent-run.sh exports UV_SYSTEM_CERTS=1 for uv"'
    fi
    emit "tls= bundle=$bundle source=$source corporate-ca=$corporate preset=${preset_str:-none} uv-system-certs=$uv_flag"
}

# Mirrors agent-run.sh's selection exactly, so the agent knows the cache layout before its
# first uv/npm/pip invocation instead of after that invocation's read-only failure.
probe_caches() {
    local home_cache root reason
    home_cache="${XDG_CACHE_HOME:-$HOME/.cache}"
    if [[ -n "${AGENT_CACHE_ROOT:-}" ]]; then
        root="$AGENT_CACHE_ROOT"
        reason="AGENT_CACHE_ROOT-set"
    elif dir_writable "$home_cache"; then
        root="$home_cache"
        reason="home-cache-writable"
    else
        root="${TMPDIR:-/tmp}/agent-cache-$(id -u)"
        reason="home-cache-unwritable"
    fi
    emit "caches= root=$root reason=$reason home-cache=$home_cache UV_CACHE_DIR=$root/uv NPM_CONFIG_CACHE=$root/npm PIP_CACHE_DIR=$root/pip XDG_CACHE_HOME=$root"
}

# The repo command runner is a convention this skill defines and documents: a repo opts in
# by exporting AGENT_REPO_RUNNER or committing <git-toplevel>/.agent/runner. Nothing else
# is probed for -- never a vendor- or company-specific tool path.
resolve_repo_runner() {
    local declared="" candidate source file="$WORKTREE/.agent/runner"
    if [[ -n "${AGENT_REPO_RUNNER:-}" ]]; then
        candidate="$AGENT_REPO_RUNNER"
        source="env:AGENT_REPO_RUNNER"
    elif [[ ! -f "$file" ]]; then
        printf 'repo-runner=none source=none reason=no-AGENT_REPO_RUNNER-and-no-.agent/runner'
        return 0
    else
        read -r declared <"$file" || true
        source="file:$file"
        if [[ -z "$declared" ]]; then
            printf 'repo-runner=none source=%s reason=empty' "$source"
            return 0
        fi
        case "$declared" in
            /*) candidate="$declared" ;;
            *)  candidate="$WORKTREE/$declared" ;;
        esac
    fi
    if [[ -x "$candidate" ]]; then
        printf 'repo-runner=%s source=%s' "$candidate" "$source"
    else
        printf 'repo-runner=none source=%s reason=not-executable:%s' "$source" "$candidate"
    fi
}

node_roots() {
    local -a roots=()
    local found pm="none"
    while IFS= read -r found; do
        roots+=("$(relative_to_top "${found%/package.json}")")
    done < <(find "$WORKTREE" -maxdepth 4 \
        \( -name node_modules -o -path "$WORKTREE/.*" \) -prune \
        -o -type f -name package.json -print 2>/dev/null | sort)
    if (( ${#roots[@]} == 0 )); then
        printf 'node-roots=none'
        return 0
    fi
    # Which package manager this repo uses is discovered from its lockfile, not assumed.
    if   [[ -f "$WORKTREE/pnpm-lock.yaml" ]];    then pm="pnpm"  # ecosystem-allow: detection
    elif [[ -f "$WORKTREE/yarn.lock" ]];         then pm="yarn"  # ecosystem-allow: detection
    elif [[ -f "$WORKTREE/bun.lockb" ]];         then pm="bun"
    elif [[ -f "$WORKTREE/package-lock.json" ]]; then pm="npm"
    fi
    printf 'node-roots=%s node-pm=%s' "$(join_capped 6 "${roots[@]}")" "$pm"
}

declares_src_layout() {
    local file
    for file in "$WORKTREE/pyproject.toml" "$WORKTREE/setup.cfg"; do
        if [[ -f "$file" ]] && grep -qE '(package[-_]dir|from)[[:space:]]*=[[:space:]]*.*src' "$file" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# A source root is the parent of a directory holding __init__.py, plus a src/ layout
# declared by pyproject.toml/setup.cfg. Generic: no repo layout is assumed.
py_roots() {
    local -a roots=()
    local init rel pkg
    while IFS= read -r init; do
        rel="$(relative_to_top "$init")"
        if skip_relative_path "$rel"; then continue; fi
        pkg="${init%/*}"
        rel="$(relative_to_top "${pkg%/*}")"
        if ! contains "$rel" "${roots[@]+"${roots[@]}"}"; then roots+=("$rel"); fi
    done < <(find "$WORKTREE" -mindepth 2 -maxdepth 3 -type f -name __init__.py -print 2>/dev/null | sort)
    if [[ -d "$WORKTREE/src" ]] && ! contains "src" "${roots[@]+"${roots[@]}"}" && declares_src_layout; then
        roots+=("src")
    fi
    if (( ${#roots[@]} == 0 )); then
        printf 'py-roots=none'
    else
        printf 'py-roots=%s' "$(join_capped 6 "${roots[@]}")"
    fi
}

probe_runners() {
    local python="none" pyver="" pyrunner="none" tool
    if command -v python3 >/dev/null 2>&1; then python="$(command -v python3)"
    elif command -v python >/dev/null 2>&1; then python="$(command -v python)"
    fi
    if [[ "$python" != "none" ]]; then
        # Match the version line specifically and stop: a deprecation warning on stderr
        # must not leak a newline into the block and split the runners= line in two.
        pyver="$("$python" --version 2>&1 | awk '/^Python /{print $2; exit}')" || pyver=""
    fi
    for tool in uv poetry pipenv hatch; do
        if command -v "$tool" >/dev/null 2>&1; then pyrunner="$tool"; break; fi
    done
    emit "runners= $(resolve_repo_runner) python=$python${pyver:+($pyver)} py-runner=$pyrunner $(py_roots) $(node_roots)"
}

# Which CLI is running this. The tree is harness-agnostic, but two things are
# not: who a commit should credit, and which CLI is the OTHER one for a
# cross-harness adversarial review. Both are facts about the session, so they are
# reported rather than guessed -- a hardcoded trailer credits the wrong agent the
# moment the same repository is worked from the other CLI.
HARNESS_OTHER=claude
probe_harness() {
    local line
    line=$("$(dirname -- "${BASH_SOURCE[0]}")/harness-id.sh" 2>/dev/null || true)
    [[ -n $line ]] || line='name=unknown trailer="Agent <noreply@example.invalid>" other=none'
    HARNESS_OTHER=${line##*other=}
    emit "harness= $line"
}

# The peer CLI, for a cross-harness adversarial review. Named from the harness
# probe rather than assumed: on a Claude session the peer is Codex, and a message
# that says otherwise sends the reviewer to the CLI it is already running in.
probe_peer_cli() {
    local path other=${1:-claude}
    if path="$(command -v "$other" 2>/dev/null)"; then
        emit "peer-cli= $other present path=$path probe=not-run"
    elif [[ -x "$HOME/.local/bin/$other" ]]; then
        emit "peer-cli= $other present path=$HOME/.local/bin/$other probe=not-run"
    else
        emit "peer-cli= $other absent note=\"no cross-harness reviewer; use the same-harness blind fallback\""
    fi
}

# Never fail the run over the artifact: the block already went to stdout.
write_block() {
    local target="$1" dir
    dir="$(dirname -- "$target")"
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        note "could not create $dir -- environment block printed to stdout only"
        return 0
    fi
    if ! printf '%s\n' "${OUT_LINES[@]}" 2>/dev/null >"$target"; then
        note "could not write $target -- environment block printed to stdout only"
        return 0
    fi
    note "wrote $target"
}

main() {
    parse_args "$@"
    resolve_worktree
    probe_identity
    probe_config
    probe_git
    probe_gh
    probe_sandbox
    probe_tls
    probe_caches
    probe_runners
    probe_harness
    probe_peer_cli "$HARNESS_OTHER"
    printf '%s\n' "${OUT_LINES[@]}"
    if (( ARG_NO_WRITE )); then
        note "--no-write: no environment block file written"
        return 0
    fi
    mkdir -p -- "$WORKTREE/.agent/logs" 2>/dev/null ||
        note "could not create $WORKTREE/.agent/logs -- agent-run.sh will fall back"
    write_block "${ARG_WRITE:-$WORKTREE/.agent/env-contract.txt}"
}

main "$@"
