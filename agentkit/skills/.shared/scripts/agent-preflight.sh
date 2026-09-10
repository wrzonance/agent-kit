#!/usr/bin/env bash
#
# agent-preflight.sh -- declare the agent's sandbox environment ONCE, before the
# first command: caches, CA bundles, PYTHONPATH, git-dir writability, peer CLI --
# the facts agents otherwise rediscover by failure. Reports, never blocks (exit 0
# with missing facts named; 2 only for bad usage); only account-scoped forge state
# is probed; writes only under <worktree>/.agent/. Output: one key per line, the
# first `skills= path=/abs` (literal "skills=" then "path="; consumers parse that
# exact prefix), then `skills-content= sha256=` (#453) -- see --help.
#   skills= path= skills-content= repo= branch= worktree= base= config= protected= instructions= git= gh= sandbox= tls= caches= runners= harness= peer-cli=
set -euo pipefail

if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
    printf '%s: requires Bash >= 4 (invoked interpreter: %s); run this helper with bash, not zsh\n' \
        "${0##*/}" "${SHELL:-unknown}" >&2
    exit 2
fi

ARG_WORKTREE=""
ARG_REPO=""
ARG_REPO_SET=0
ARG_WRITE=""
ARG_WRITE_SET=0
ARG_NO_WRITE=0
ARG_ENSURE=0
ARG_MEASURED_FROM_SET=0
ARG_INHERIT_SESSION=""
ARG_INHERIT_SESSION_SET=0
# Which process this run speaks for. A hook runs OUTSIDE the agent's sandbox,
# so everything measured here about writability and sandboxing describes the
# hook, not the shell that will run the commands -- see probe_sandbox().
# "escalated" names a harness-escalated / approval-granted execution (issue
# #332): a real class, but nothing in this script infers it -- there is no
# verified signal for it (see probe_sandbox()). It exists in the vocabulary
# for a caller that already knows its own escalation state from its own
# harness; --measured-from is how that caller would assert it.
ARG_MEASURED_FROM=agent-shell
WORKTREE=""
IN_REPO=0
OUT_LINES=()
GH_AUTH_STATE=""

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

# Canonical directory this script actually lives in, resolved ONCE through any
# symlink entry point (this skill is invoked via a PATH symlink -- see
# tests/test-agent-preflight.sh's symlink-bin case): BASH_SOURCE[0] names the
# symlink, not this file, so a fresh, unresolved `dirname -- "${BASH_SOURCE[0]}"`
# at any other call site would look for siblings beside the symlink, where
# only the symlink itself lives. Every sibling-helper reference in this file
# (the lib/ sources below, repo-config.sh, contract-read.sh, harness-id.sh,
# gh-auth-state.sh, and skills_tree_root's walk-up) must resolve against this
# variable, never recompute its own dirname.
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"
readonly SCRIPT_DIR

# Sibling libraries, each guarded: this script reports missing facts rather than
# blocking (see BEHAVIOUR), so a copy without its lib/ sibling still runs and the
# consumer (probe_protected, apply_never_widen, probe_skills_content, the .agent
# mkdir sites) discloses the gap via `declare -F`. Issues #332 F3, #453, #474.
for preflight_lib in protected-paths sandbox-comparator skills-content-hash secure-mkdir contract-cache; do
    preflight_lib_path="$SCRIPT_DIR/lib/$preflight_lib.sh"
    if [[ -r $preflight_lib_path ]]; then
        # shellcheck disable=SC1090,SC1091  # sibling library is resolved at runtime
        source "$preflight_lib_path"
    fi
done
unset preflight_lib preflight_lib_path

usage() {
    cat <<'EOF'
agent-preflight.sh -- declare the agent's sandbox environment once, up front.

Usage:
  agent-preflight.sh [--worktree PATH] [--repo OWNER/REPO] [--write FILE | --no-write]
                     [--ensure] [--inherit-session FILE]
                     [--measured-from agent-shell|hook|escalated] [-h|--help]

Options:
  --worktree PATH    Worktree to describe (default: git toplevel of the cwd, else the cwd).
  --repo OWNER/REPO  Use this slug instead of parsing one from the origin remote.
  --write FILE       Write the block here (default: <worktree>/.agent/env-contract.txt).
  --no-write         Print the block only; write no file.
  --ensure           Reuse and print a trusted existing contract; run the
                     preflight probes only when that contract is missing or
                     fails contract-read provenance checks.
  --inherit-session FILE
                     Copy this file's sandbox=, tls=, and caches= lines
                     verbatim instead of re-measuring them: those are
                     session-scoped facts, not per-worktree ones, and a
                     second measurement in a differently-privileged process
                     is exactly how a session ends up with contradictory
                     contracts. A key missing from FILE falls back to a
                     fresh probe for that key only. Trusted only from a
                     same-harness source; once it is also older than
                     INHERIT_SESSION_MAX_AGE_MINUTES, sandbox=/caches= are
                     revalidated against a fresh probe (the more restrictive
                     reading wins) rather than trusted or discarded outright.
  --measured-from W  Whose environment this describes: "agent-shell"
                     (default, the shell that will run commands; "agent" is
                     accepted as a backward-compatible alias for callers
                     written against the pre-#332 vocabulary), "hook",
                     which runs outside the agent sandbox and can only
                     report its own, or "escalated", for a caller that
                     already knows -- from its own harness -- that it is
                     running with escalated/approval-granted privileges.
                     This script never infers "escalated" itself.
  -h, --help         Print this help and exit 0.

Prints `skills= path=ABSOLUTE_PATH`, then one key per line: skills-content= repo= branch= worktree= base= config= protected= instructions= git= gh= sandbox= tls= caches= runners= harness= peer-cli=

Exit: 0 always, including when tools or facts are missing (they are reported as missing);
      2 only for invalid usage.
EOF
}

note() { printf 'agent-preflight: %s\n' "$*" >&2; }
emit() { OUT_LINES+=("$1"); }

# Shared by probe_skills_path and probe_skills_content: this file's
# grandparent directory IS the running skills tree, whether that is the
# repository's own agentkit/skills checkout or an installed plugin copy.
skills_tree_root() {
    (cd -- "$SCRIPT_DIR/../.." && pwd -P)
}

# Emits the record `skills= path=/abs/skills-tree`: "skills=" and "path=" are two
# space-separated fields, never the run-together "skills=/abs/path" form.
probe_skills_path() {
    emit "skills= path=$(skills_tree_root)"
}

# Emits `skills-content= sha256=HASH`: a content stamp over the shipped
# skill/script tree, independent of the skills= path= record above and never
# appended to it -- see the OUTPUT comment. Two trees answering to the same
# published version string hash differently the instant their shipped
# content differs, so a session can tell which build it is actually running
# instead of trusting a version string that can name two different trees
# (issue #453). Reports 'unavailable' rather than failing preflight when no
# sha256 tool is present or the tree cannot be read -- see BEHAVIOUR above.
probe_skills_content() {
    local skills hash
    skills="$(skills_tree_root)"
    if command -v skills_content_hash > /dev/null 2>&1 &&
        hash=$(skills_content_hash "$skills" 2> /dev/null) && [[ -n $hash ]]; then
        emit "skills-content= sha256=$hash"
    else
        emit "skills-content= sha256=unavailable"
    fi
}

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
            --measured-from)
                need_value "$@"
                ARG_MEASURED_FROM_SET=1
                case "$2" in
                    # "agent" was the pre-#332 public value (main's --measured-from
                    # agent|hook); a caller outside this tree may still pass it.
                    # Accept it as an alias rather than a hard failure that leaves
                    # a contract-producing script with no contract to produce.
                    agent) ARG_MEASURED_FROM=agent-shell ;;
                    agent-shell|hook|escalated) ARG_MEASURED_FROM="$2" ;;
                    *) die "--measured-from takes agent-shell (or its alias 'agent'), hook, or escalated, got: $2" ;;
                esac
                shift 2 ;;
            --repo)     need_value "$@"; ARG_REPO="$2"; ARG_REPO_SET=1; shift 2 ;;
            --write)    need_value "$@"; ARG_WRITE="$2"; ARG_WRITE_SET=1; ARG_NO_WRITE=0; shift 2 ;;
            --no-write) ARG_NO_WRITE=1; ARG_WRITE=""; shift ;;
            --ensure) ARG_ENSURE=1; shift ;;
            --inherit-session)
                need_value "$@"
                ARG_INHERIT_SESSION="$2"
                ARG_INHERIT_SESSION_SET=1
                shift 2 ;;
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
    # A repository with no commits yet makes rev-parse --abbrev-ref HEAD FAIL
    # (128) while still echoing "HEAD", unlike a detached HEAD (same word, exit
    # 0); capturing rc separately keeps success / failure-with-stdout (unborn,
    # reported as HEAD -- session-start.sh keys off it) / failure-with-nothing
    # (unknown) apart and the one-line-per-key contract intact.
    local git_branch_out git_rc=0
    git_branch_out="$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null)" || git_rc=$?
    if (( git_rc == 0 )); then
        branch="$git_branch_out"
        if [[ "$branch" == "HEAD" ]]; then branch="detached"; fi
    elif [[ -n "$git_branch_out" ]]; then
        branch="$git_branch_out"
    else
        branch="unknown"
    fi
    emit "repo=$slug"
    emit "branch=$branch"
    emit "worktree=$WORKTREE"
    emit "$(detect_base)"
}

# What the repository declared about itself. This tells the agent which facts below
# came from a committed file rather than from probing -- and, when a config exists but
# supplies nothing, that its keys were rejected rather than absent.
probe_config() {
    local resolver listing count keys shown extra
    resolver="$SCRIPT_DIR/repo-config.sh"
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

# The effective protected-path set, computable up front so a colliding write set is
# knowable before work starts rather than discovered at commit time by
# guard_staged_protected_paths in worktree-commit.sh (issue #296). Computed exactly the
# way that guard computes it: lib/protected-paths.sh's SHARED_PROTECTED_DEFAULTS plus
# this repository's additive AGENT_PROTECTED_PATHS declaration (repo-config.sh) --
# never a re-derivation that could drift from the enforcement it describes.
probe_protected() {
    if [[ -z "${SHARED_PROTECTED_DEFAULTS+x}" ]]; then
        emit 'protected= patterns=unavailable repo-declared=unknown note="lib/protected-paths.sh missing alongside this script"'
        return 0
    fi
    local resolver declared="" repo_declared="none"
    resolver="$SCRIPT_DIR/repo-config.sh"
    if [[ -x "$resolver" && -n "$WORKTREE" ]]; then
        declared="$("$resolver" --repo-root "$WORKTREE" --get AGENT_PROTECTED_PATHS 2>/dev/null || true)"
    fi
    local -a effective=("${SHARED_PROTECTED_DEFAULTS[@]}")
    if [[ -n "$declared" ]]; then
        local IFS=,
        local -a extra
        read -r -a extra <<< "$declared"
        effective+=("${extra[@]}")
        repo_declared="$(join_by , "${extra[@]}")"
    fi
    # Capped like py-roots/node-roots: a misconfigured repo cannot flood the block, and
    # the count is never silently understated -- join_capped names how many were dropped.
    emit "protected= patterns=\"$(join_capped 24 "${effective[@]}")\" repo-declared=\"$repo_declared\""
}

# Resolves a repo-relative reference to a canonical, in-worktree, regular,
# non-symlink file. Prints the repo-relative path and returns 0 on success;
# returns 1 (silently) for anything outside those bounds, including a path
# that escapes the worktree via ../.
resolve_instruction_ref() {
    local ref="$1" candidate canon top
    candidate="$WORKTREE/$ref"
    [[ -f "$candidate" && ! -L "$candidate" ]] || return 1
    canon="$(readlink -f -- "$candidate" 2>/dev/null)" || return 1
    top="$(readlink -f -- "$WORKTREE" 2>/dev/null)" || return 1
    case "$canon" in
        "$top"/*) ;;
        *) return 1 ;;
    esac
    relative_to_top "$canon"
}

# A root instruction file can act as a ROUTER: it names on-demand docs by path
# instead of holding the guidance itself (issue #338 -- an observed root
# AGENTS.md referenced instructions/workflow.md, instructions/github.md, etc.
# and none of them existed in the checkout). Any relative, slash-qualified
# *.md-looking token is a candidate reference; this makes no assumption about
# the router's chosen directory name. Surrounding Markdown, backticks, and @
# sigils are deliberately not part of the match. Extraction reads at most
# 256 KiB and returns at most 64 unique references per root file; the sentinel
# makes either exhausted budget visible to probe_instructions.
router_references() {
    local file=$1 byte_cap=262144 ref_cap=64 file_size truncated=no
    local LC_ALL=C
    local -a refs=()

    # stat is constant-work disclosure of whether head's bounded stream omits
    # bytes; keeping file content out of a shell variable also preserves NULs.
    file_size=$(stat -c %s -- "$file" 2> /dev/null || printf '')
    [[ $file_size =~ ^[0-9]+$ ]] || truncated=yes
    [[ $file_size =~ ^[0-9]+$ ]] && ((file_size <= byte_cap)) || truncated=yes
    mapfile -t refs < <(
        head -c "$byte_cap" -- "$file" 2> /dev/null |
            grep -oE '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+\.md' 2> /dev/null |
            sort -u | head -n "$((ref_cap + 1))"
    )
    if ((${#refs[@]} > ref_cap)); then
        refs=("${refs[@]:0:ref_cap}")
        truncated=yes
    fi
    ((${#refs[@]} == 0)) || printf '%s\n' "${refs[@]}"
    [[ $truncated == no ]] || printf '%s\n' '__AGENTKIT_ROUTER_TRUNCATED__'
}

# instructions= reports a RESOLVED SET, not a pointer: the root AGENTS.md/
# CLAUDE.md, any on-demand path a root router references that actually
# resolves inside the worktree, and per-directory instruction files -- all
# regular, non-symlink, canonically inside the worktree. Anything a router
# references that does NOT resolve is named explicitly under unresolved=, so
# an agent reads "these were referenced and are absent" as a fact instead of
# rediscovering it through failed reads. The per-directory sweep is bounded
# and capped exactly like node-roots/py-roots below -- never an unbounded
# worktree enumeration.
probe_instructions() {
    local -a roots=() files=() unresolved=() subdir_files=()
    local root_list files_list unresolved_list resolved ref f router_truncated=no line

    [[ -f "$WORKTREE/AGENTS.md" && ! -L "$WORKTREE/AGENTS.md" ]] && roots+=(AGENTS.md)
    [[ -f "$WORKTREE/CLAUDE.md" && ! -L "$WORKTREE/CLAUDE.md" ]] && roots+=(CLAUDE.md)

    for f in "${roots[@]}"; do
        files+=("$f")
        while IFS= read -r ref; do
            [[ -n "$ref" ]] || continue
            if [[ $ref == __AGENTKIT_ROUTER_TRUNCATED__ ]]; then
                router_truncated=yes
                continue
            fi
            if resolved="$(resolve_instruction_ref "$ref")"; then
                contains "$resolved" "${files[@]+"${files[@]}"}" || files+=("$resolved")
            else
                contains "$ref" "${unresolved[@]+"${unresolved[@]}"}" || unresolved+=("$ref")
            fi
        done < <(router_references "$WORKTREE/$f")
    done

    # Per-directory instruction files (regular, non-symlink
    # AGENTS.md/CLAUDE.md), skipping vendored trees with the bound
    # node_roots/py_roots use. No -mindepth beside -prune (GNU find applies
    # -mindepth globally and would walk into node_modules); root duplicates are
    # dropped by the contains() dedup above.
    while IFS= read -r f; do
        resolved="$(relative_to_top "$f")"
        contains "$resolved" "${files[@]+"${files[@]}"}" || subdir_files+=("$resolved")
    done < <(find "$WORKTREE" -maxdepth 4 \
        \( -name node_modules -o -name vendor -o -path "$WORKTREE/.*" \) -prune \
        -o -type f \( -name AGENTS.md -o -name CLAUDE.md \) -print 2>/dev/null | sort)
    files+=("${subdir_files[@]+"${subdir_files[@]}"}")

    if (( ${#roots[@]} == 0 )); then root_list="none"; else root_list="$(join_by , "${roots[@]}")"; fi
    if (( ${#files[@]} == 0 )); then files_list="none"; else files_list="$(join_capped 24 "${files[@]}")"; fi
    if (( ${#unresolved[@]} == 0 )); then unresolved_list="none"; else unresolved_list="$(join_capped 24 "${unresolved[@]}")"; fi

    if [[ $router_truncated == yes ]]; then
        line="instructions= root=$root_list files=$files_list router-truncated=yes unresolved=$unresolved_list"
    else
        line="instructions= root=$root_list files=$files_list unresolved=$unresolved_list"
    fi
    emit "$line"
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
    # The git directory being writable says nothing about the WORKTREE ROOT, and
    # that is what most commands need: a test runner writes .coverage there, a
    # build writes artefacts there. Starting a session in a SUBDIRECTORY makes
    # only that subtree writable under a workspace-scoped sandbox, so the root
    # is read-only and the failure arrives as an unrelated OSError from whatever
    # tool touched it first.
    local root_state
    root_state=$(dir_writable_word "$WORKTREE")

    if dir_writable "$common"; then
        line="git= common-dir=$common writable=yes"
        # A hook runs outside the agent's sandbox, so this probe just measured
        # the hook's own privileges. A live session was handed writable=yes and
        # then had its write to .git/info/exclude denied -- it noticed and
        # worked around it, which is not something to rely on twice.
        [[ $ARG_MEASURED_FROM != hook ]] ||
            line+=" measured-by=hook note=\"probed outside your sandbox, so this is the hook's access and not yours; a denial when you write is authoritative and worth re-probing\""
    else
        # Measured, not guessed: a workspace-scoped sandbox mounts <repo>/.git
        # READ-ONLY on purpose, so every commit, every worktree add, and even
        # .git/info/exclude costs an approval round-trip. Naming the setting
        # turns a recurring interruption into a one-line decision -- and the
        # blunt protection it removes is covered at finer grain by the guard
        # that refuses force-push, reset --hard and their neighbours.
        line="git= common-dir=$common writable=no note=\"every git write needs approval; a workspace sandbox holds .git read-only. To lift it: sandbox_workspace_write.writable_roots must include this .git path\""
    fi
    line+=" worktree-writable=$root_state"
    if [[ $root_state != yes ]]; then
        line+=" note3=\"the repository ROOT is not writable from here; anything that writes at the root (coverage files, build output, lockfiles) fails. Start the session at the repository root rather than in a subdirectory\""
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

    # When gh says no, say WHY: a token may exist and be unreachable from THIS
    # process (keyring vs login shell). Where the token lives is reported
    # whether or not auth worked, since it predicts whether a
    # differently-sandboxed worker can use it.
    local src="none" envtok="no"
    [[ -z ${GH_TOKEN:-}${GITHUB_TOKEN:-} ]] || envtok="yes"
    if [[ $envtok == yes ]]; then
        src="environment"
    elif grep -q 'oauth_token' "${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml" 2> /dev/null; then
        src="config-file"
    elif [[ -s ${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml ]]; then
        # An account is configured but its token is not in the file, so it lives
        # in the OS keyring -- readable from a login shell, and not always from
        # wherever an agent's commands run.
        src="keyring"
    fi

    local why=" token-source=$src"
    if [[ $authed == no ]]; then
        why+=" env-token=$envtok config-dir=${GH_CONFIG_DIR:-$HOME/.config/gh}"
        why+=" detail=\"$(printf '%s' "$status_out" | tr '\n' ';' | tr -d '"' | cut -c1-160)\""
        # The named cause and its fix, on their own line, so neither the agent
        # nor the operator has to infer which failure this is.
        GH_AUTH_STATE=$("$SCRIPT_DIR/gh-auth-state.sh" 2>/dev/null || true)
    fi

    emit "gh= authed=$authed scopes=$scopes api=$api${account:+ account=$account} project-scope=$project$why"
    [[ -z ${GH_AUTH_STATE:-} ]] || emit "gh-auth= $GH_AUTH_STATE"
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
    if [[ $ARG_MEASURED_FROM == hook ]]; then
        # active/profile/network are read from CODEX_* variables that are set in
        # the AGENT's shell. A hook does not have them, so from here every
        # session looks unsandboxed regardless of what it actually is. Say so
        # rather than emitting a confident "active=no".
        [[ $sandboxed == yes ]] || sandboxed=unknown
        note=' note="probed outside your sandbox; treat this as the floor, not the ceiling, and believe a denial over this line"'
    elif [[ $ARG_MEASURED_FROM == escalated ]]; then
        # No verified signal exists for an escalated shell (issue #332): the
        # CODEX_* variables describe a SANDBOXED shell. This branch runs only
        # for an explicit --measured-from escalated -- labelled, never detected
        # -- and appends to (never replaces) the sandboxed-workspace note (#332
        # F1).
        local escalated_note='explicitly asserted by the caller as an escalated/approval-granted execution; this probe does not detect that state itself'
        if [[ -n $note ]]; then
            note=${note%\"}
            note="$note. $escalated_note\""
        else
            note=" note=\"$escalated_note\""
        fi
    fi
    # measured-by= is unconditional (not just for hook) so every one of the
    # three process classes this probe can run as -- hook, the agent's own
    # shell, or an explicitly-asserted escalated execution -- is provenance-
    # tagged. Before this, only the hook case carried a marker, so a
    # measurement from an escalated shell and one from the agent's ordinary
    # shell were indistinguishable in the persisted contract even though they
    # can truthfully disagree about the same session (issue #332).
    emit "sandbox= active=$sandboxed profile=$profile network=$network home-writable=$(dir_writable_word "${HOME:-}") measured-by=$ARG_MEASURED_FROM$note"
}

# sandbox_field_rank/sandbox_widened live in lib/sandbox-comparator.sh
# (issue #332 F3), sourced near the top of this file -- shared verbatim with
# compose-worker-prompt.sh so the two sides of the create-issue-worktree.sh
# boundary can never rank a sandbox= line's restrictiveness differently.

# Same idea for caches=: a root confirmed unwritable ($HOME/.cache truly
# refused a write, so the cache root fell back to an isolated /tmp path) is
# the restrictive/safe reading; a later measurement claiming $HOME/.cache IS
# writable after all is the exact widening this guards against. An explicit
# AGENT_CACHE_ROOT override is an operator decision, not a measurement, so it
# scores in between rather than being judged for restrictiveness.
caches_restriction_score() {
    local line="$1" reason
    # Anchored at the START of the record (issue #332 F2 round 2): root= is
    # always the first token after "caches= " and probe_caches refuses a root
    # containing whitespace, so nothing attacker-controlled can precede the
    # genuine reason=.
    reason=$(sed -n 's/^caches= root=[^[:space:]]* reason=\([A-Za-z-]*\).*/\1/p' <<< "$line")
    # An unparseable or unknown reason= ranks in the MIDDLE, never as the known
    # least-restrictive value (#332 F2 round 3), mirroring sandbox_field_rank:
    # uncertainty must never read as freedom, or the never-widen guard misses a
    # widening.
    case "$reason" in
        home-cache-unwritable) printf '2' ;;
        AGENT_CACHE_ROOT-set) printf '1' ;;
        home-cache-writable) printf '0' ;;
        *) printf '1' ;;
    esac
}

# caches='s counterpart to lib/sandbox-comparator.sh's sandbox_widened (issue
# #372): whether $2 (a fresh caches= measurement) is LESS restrictive than $1
# (a recorded one). Extracted out of apply_never_widen so inherit_or_probe()
# can reuse the exact same comparison when revalidating a stale
# --inherit-session source, rather than a second, drifting copy of the score
# comparison living in each call site. Prints a token on stdout and returns
# success when widened, mirroring sandbox_widened's contract, so both
# comparators can be invoked identically by name.
caches_widened() {
    local recorded="$1" fresh="$2" old_score new_score
    old_score=$(caches_restriction_score "$recorded")
    new_score=$(caches_restriction_score "$fresh")
    if (( new_score < old_score )); then
        printf 'caches'
        return 0
    fi
    return 1
}

# Never let a later, less-privileged-context-blind measurement overwrite a
# more restrictive one already recorded for this worktree (issue #332): the
# bug this guards against is real -- three preflight runs on one machine, one
# session, produced three mutually contradictory sandbox=/caches= verdicts,
# and the least restrictive one is the one that reached a dispatched worker.
# Only sandbox= and caches= are compared; tls= carries no restrictiveness
# ordering worth guessing at.
apply_never_widen() {
    local target="$1" existing prefix prev_line
    [[ -n "$target" && -f "$target" && ! -L "$target" && -r "$target" ]] || return 0
    existing="$(cat -- "$target" 2>/dev/null)" || return 0
    for prefix in 'sandbox=' 'caches='; do
        prev_line="$(grep -m1 "^$prefix" <<< "$existing" || true)"
        [[ -n "$prev_line" ]] || continue
        local i
        for i in "${!OUT_LINES[@]}"; do
            case "${OUT_LINES[$i]}" in
                "$prefix"*)
                    local new_line
                    new_line="${OUT_LINES[$i]}"
                    if [[ "$prefix" == 'sandbox=' ]]; then
                        if ! declare -F sandbox_widened >/dev/null; then
                            note "cannot verify the sandbox= never-widen guard: lib/sandbox-comparator.sh is missing alongside this script"
                        else
                            local regressed_field
                            if regressed_field=$(sandbox_widened "$prev_line" "$new_line"); then
                                note "keeping the more-restrictive recorded sandbox= (a fresh measurement would widen field '$regressed_field'): recorded=[$prev_line] fresh=[$new_line]"
                                OUT_LINES[i]="$prev_line"
                            fi
                        fi
                    else
                        if caches_widened "$prev_line" "$new_line" >/dev/null; then
                            note "keeping the more-restrictive recorded caches= (a fresh measurement would widen it): recorded=[$prev_line] fresh=[$new_line]"
                            OUT_LINES[i]="$prev_line"
                        fi
                    fi
                    break
                    ;;
            esac
        done
    done
}

# --inherit-session (issue #332 F3, #372): a source is trusted outright only
# when recent (INHERIT_SESSION_MAX_AGE_MINUTES) AND same-harness -- the
# heuristic session-start.sh uses for a cached contract; no cryptographic
# session identity exists and none is invented. Past the window a same-harness
# source is revalidated, not discarded: sandbox=/caches= are probed fresh and
# the more restrictive reading wins per field (inherit_or_probe, the never-widen
# comparators), so a worktree contract can never be less restrictive than the
# recorded root line; tls= has no restrictiveness order and falls back to a
# fresh probe. A different harness's source is never inherited.
readonly INHERIT_SESSION_MAX_AGE_MINUTES=30
INHERIT_SESSION_STATE=-1 # memoised: -1 not yet computed, 0 unusable (missing/unreadable/
                          # harness-mismatch), 1 verified fresh and same-harness (inherit
                          # verbatim), 2 same-harness but past the freshness window
                          # (revalidate sandbox=/caches= against a fresh probe instead of
                          # trusting or discarding the recorded line outright)

compute_inherit_session_state() {
    (( INHERIT_SESSION_STATE < 0 )) || return 0
    INHERIT_SESSION_STATE=0
    if [[ -z "$ARG_INHERIT_SESSION" || ! -f "$ARG_INHERIT_SESSION" ||
        -L "$ARG_INHERIT_SESSION" || ! -r "$ARG_INHERIT_SESSION" ]]; then
        return 0
    fi
    local stale=0
    if [[ -z "$(find "$ARG_INHERIT_SESSION" -mmin "-$INHERIT_SESSION_MAX_AGE_MINUTES" 2>/dev/null)" ]]; then
        stale=1
    fi
    local src_harness current_harness harness_id_script
    harness_id_script="$SCRIPT_DIR/harness-id.sh"
    src_harness="$(sed -n 's/^harness=[[:space:]]*name=\([^ ]*\).*/\1/p;/^harness=/q' "$ARG_INHERIT_SESSION" 2>/dev/null)"
    if [[ -x "$harness_id_script" ]]; then
        current_harness="$("$harness_id_script" --name 2>/dev/null || true)"
    fi
    if [[ -z "$src_harness" || -z "${current_harness:-}" || "$src_harness" != "$current_harness" ]]; then
        note "not inheriting from $ARG_INHERIT_SESSION: its harness= (${src_harness:-none}) does not match this session's (${current_harness:-unknown}) -- falling back to a fresh probe for sandbox=/tls=/caches="
        return 0
    fi
    if (( stale )); then
        note "$ARG_INHERIT_SESSION is older than ${INHERIT_SESSION_MAX_AGE_MINUTES}m -- same harness though, so sandbox=/caches= are revalidated against a fresh probe (whichever reading is more restrictive wins) instead of being trusted verbatim or discarded outright; tls= has no restrictiveness ordering, so it falls back to a fresh probe"
        INHERIT_SESSION_STATE=2
    else
        INHERIT_SESSION_STATE=1
    fi
}

# sandbox=, tls=, caches= are SESSION facts (which process runs the commands,
# what it can reach), not per-worktree ones; re-measuring them per worktree is
# how issue #332's contradictory contracts happened. --inherit-session carries
# them forward verbatim in state 1; $comparator (sandbox_widened /
# caches_widened; none for tls=) is consulted only in state 2 (same-harness but
# stale) to keep the more restrictive of recorded/fresh.
inherit_or_probe() {
    local prefix="$1" probe_fn="$2" comparator="${3:-}" line
    compute_inherit_session_state
    if (( INHERIT_SESSION_STATE == 1 )); then
        line="$(grep -m1 "^$prefix" -- "$ARG_INHERIT_SESSION" 2>/dev/null || true)"
        if [[ -n "$line" ]]; then
            emit "$line"
            note "inherited $prefix from $ARG_INHERIT_SESSION verbatim (session-scoped fact, verified recent and same-harness, not re-measured)"
            return
        fi
    elif (( INHERIT_SESSION_STATE == 2 )) && [[ -n "$comparator" ]]; then
        line="$(grep -m1 "^$prefix" -- "$ARG_INHERIT_SESSION" 2>/dev/null || true)"
        if [[ -n "$line" ]]; then
            local idx fresh regressed_field
            idx=${#OUT_LINES[@]}
            "$probe_fn"
            fresh="${OUT_LINES[$idx]}"
            # Fail CLOSED (issue #372 review): a comparator that cannot run
            # (missing lib, typo'd name) must never read as "not widened";
            # declare -F first tells "unavailable" from "ran and found no
            # regression", and unavailable keeps the recorded, more-restrictive
            # line.
            if ! declare -F "$comparator" >/dev/null; then
                OUT_LINES[idx]="$line"
                note "cannot verify the $prefix revalidation guard: $comparator is not defined -- keeping the recorded (older than ${INHERIT_SESSION_MAX_AGE_MINUTES}m) line rather than treat an unmeasurable comparison as not widened (recorded=[$line] fresh=[$fresh])"
            elif regressed_field=$("$comparator" "$line" "$fresh"); then
                OUT_LINES[idx]="$line"
                note "revalidated $prefix from $ARG_INHERIT_SESSION: kept the recorded line -- older than ${INHERIT_SESSION_MAX_AGE_MINUTES}m but still the more restrictive reading; a fresh probe would widen field '$regressed_field' (recorded=[$line] fresh=[$fresh])"
            else
                note "revalidated $prefix from $ARG_INHERIT_SESSION: the fresh probe is at least as restrictive, so it replaces the recorded (older than ${INHERIT_SESSION_MAX_AGE_MINUTES}m) copy (recorded=[$line] fresh=[$fresh])"
            fi
            return
        fi
    fi
    "$probe_fn"
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
    local home_cache root reason cargo_home cargo_home_default
    home_cache="${XDG_CACHE_HOME:-$HOME/.cache}"
    # A whitespace byte in root= could spoof extra caches= tokens (issue #332
    # F2), so EVERY source that can become root= (AGENT_CACHE_ROOT, TMPDIR, the
    # XDG/$HOME-derived home_cache) is refused rather than out-patterned -- the
    # TMPDIR fallback produces the RESTRICTIVE record, which must never fail to
    # parse (round 3).
    if [[ -n "${AGENT_CACHE_ROOT:-}" ]]; then
        if [[ "${AGENT_CACHE_ROOT}" != *[[:space:]]* ]]; then
            root="$AGENT_CACHE_ROOT"
            reason="AGENT_CACHE_ROOT-set"
        else
            note "ignoring AGENT_CACHE_ROOT: contains whitespace, which the caches= contract record cannot carry safely -- falling back to the home-cache probe"
        fi
    fi
    if [[ -z "${root:-}" ]]; then
        if [[ "$home_cache" == *[[:space:]]* ]]; then
            note "treating \$HOME/.cache as unusable: XDG_CACHE_HOME/HOME contains whitespace, which the caches= contract record cannot carry safely"
        fi
        if [[ "$home_cache" != *[[:space:]]* ]] && dir_writable "$home_cache"; then
            root="$home_cache"
            reason="home-cache-writable"
        else
            root="${TMPDIR:-/tmp}/agent-cache-$(id -u)"
            if [[ "$root" == *[[:space:]]* ]]; then
                note "ignoring TMPDIR: contains whitespace, which the caches= contract record cannot carry safely -- using /tmp instead"
                root="/tmp/agent-cache-$(id -u)"
            fi
            reason="home-cache-unwritable"
        fi
    fi
    # CARGO_HOME is not a pure cache (config.toml/credentials.toml live there),
    # so the contract's token mirrors agent-run.sh's select_cargo_home: report
    # the effective default cargo home as-is when writable, root/cargo only
    # when it is not (PR #690 review).
    cargo_home_default="${CARGO_HOME:-${HOME:+$HOME/.cargo}}"
    if [[ -n "$cargo_home_default" ]] && dir_writable "$cargo_home_default"; then
        cargo_home="$cargo_home_default"
    else
        cargo_home="$root/cargo"
    fi
    emit "caches= root=$root reason=$reason home-cache=$home_cache UV_CACHE_DIR=$root/uv NPM_CONFIG_CACHE=$root/npm PIP_CACHE_DIR=$root/pip XDG_CACHE_HOME=$root CARGO_HOME=$cargo_home GOMODCACHE=$root/go-mod"
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

# The package manager beside ONE root: its own directory first, then
# ancestors up to the worktree root, so a workspace package inherits its
# monorepo's lock. Prints the tool name and returns 0 on the first lockfile
# found; returns 1 with nothing printed when none resolves anywhere in the
# root's ancestry.
resolve_node_pm_for_root() {
    local dir="$WORKTREE/$1" name lockfile toolname
    while :; do
        for name in 'pnpm-lock.yaml:pnpm' 'yarn.lock:yarn' 'bun.lockb:bun' 'package-lock.json:npm'; do # ecosystem-allow: detection
            lockfile="${name%%:*}"
            toolname="${name##*:}"
            if [[ -f "$dir/$lockfile" ]]; then
                printf '%s' "$toolname"
                return 0
            fi
        done
        [[ "$dir" == "$WORKTREE" ]] && break
        dir="$(dirname -- "$dir")"
    done
    return 1
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
    # The package manager is discovered from the lockfile beside EACH detected
    # root (issue #338: roots under bench/fixtures/* had their own lockfiles and
    # reported node-pm=none). Roots that resolve to nothing, or to more than one
    # manager, collapse to node-pm=unresolved -- never a value dispatch could
    # act on for the wrong component.
    local root root_pm first=1
    for root in "${roots[@]}"; do
        if root_pm="$(resolve_node_pm_for_root "$root")"; then
            if (( first )); then
                pm="$root_pm"
                first=0
            elif [[ "$pm" != "$root_pm" ]]; then
                pm="unresolved"
            fi
        else
            pm="unresolved"
            break
        fi
    done
    if [[ "$pm" == "none" ]]; then pm="unresolved"; fi
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
# A repository that pins a runtime version fails EVERY command when the active
# one does not match, and says so in the vocabulary of whichever tool noticed
# first: "[ERR_PNPM_UNSUPPORTED_ENGINE]" names the package manager, not the
# version manager, and not the shell that never activated it. Observed: a
# rehearsal where install and lint both died until the pinned version was put on
# PATH, on a machine that had it installed all along.
probe_runtime_pin() {
    local pin="" src="" active=""
    if [[ -r $WORKTREE/.nvmrc ]]; then
        pin=$(tr -d ' \t\nv' < "$WORKTREE/.nvmrc" 2> /dev/null | head -c 32)
        src=.nvmrc
    elif [[ -r $WORKTREE/.node-version ]]; then
        pin=$(tr -d ' \t\nv' < "$WORKTREE/.node-version" 2> /dev/null | head -c 32)
        src=.node-version
    elif [[ -r $WORKTREE/package.json ]]; then
        pin=$(jq -r '.engines.node // empty' "$WORKTREE/package.json" 2> /dev/null || true)
        [[ -z $pin ]] || src=package.json
    fi
    [[ -n $pin ]] || return 0

    active=$(bounded 5 node --version 2>/dev/null | tr -d 'v' || true)
    if [[ -z $active ]]; then
        emit "runtime-pin= node required=$pin source=$src active=none match=no note=\"node is not on PATH\""
        return 0
    fi

    # Only the major is compared. A range like ">=24 <25" is not worth an
    # expression evaluator here: reporting the two numbers lets the reader judge,
    # and guessing wrong would be worse than saying nothing.
    local want_major="${pin//[^0-9.]/}"
    want_major=${want_major%%.*}
    local have_major=${active%%.*}
    local match=unknown
    [[ -z $want_major ]] || { match=no; [[ $want_major != "$have_major" ]] || match=yes; }

    local note=""
    [[ $match != no ]] ||
        note=" note=\"every command in this repository will fail an engine check until the pinned version is on PATH; activate it in the shell that launches the agent, since a version manager does not follow into a child process\""
    emit "runtime-pin= node required=$pin source=$src active=$active match=$match$note"
}

probe_harness() {
    local line
    line=$("$SCRIPT_DIR/harness-id.sh" 2>/dev/null || true)
    [[ -n $line ]] || line='name=unknown trailer="Agent <noreply@example.invalid>" other=none'
    HARNESS_OTHER=${line##*other=}
    emit "harness= $line"
}

# The peer CLI, for a cross-harness adversarial review. Named from the harness
# probe rather than assumed: on a Claude session the peer is Codex, and a message
# that says otherwise sends the reviewer to the CLI it is already running in.
#
# $1 is one or more comma-separated candidate names, tried in order (Claude
# and Codex each pass a single name, unchanged; OpenCode has no fixed 1:1
# peer, so harness-id.sh hands this "codex,claude" -- try Codex first, then
# Claude). Exactly one winning name is ever emitted, so every existing
# peer-cli= consumer's single-name parse keeps working unmodified. When none
# of the candidates are present, the FIRST candidate names the line -- same
# as the pre-existing single-candidate behavior -- with a note listing every
# name that was actually checked.
probe_peer_cli() {
    local candidates_csv=${1:-claude} path other
    local -a candidates
    IFS=',' read -r -a candidates <<< "$candidates_csv"
    for other in "${candidates[@]}"; do
        if path="$(command -v "$other" 2>/dev/null)"; then
            emit "peer-cli= $other present path=$path probe=not-run"
            return
        elif [[ -x "$HOME/.local/bin/$other" ]]; then
            emit "peer-cli= $other present path=$HOME/.local/bin/$other probe=not-run"
            return
        fi
    done
    emit "peer-cli= ${candidates[0]} absent note=\"no cross-harness reviewer among: $candidates_csv; use the same-harness blind fallback\""
}

# Never fail the run over the artifact: the block already went to stdout.
#
# The write is symlink-safe and atomic, neither of which plain redirection is.
# A repository that tracks .agent/env-contract.txt as a symlink to ../.git/config
# turns this into a truncate of the git config -- the redirection follows the
# link and does not care where it lands. Found by external review.
#
# Refusing an existing symlink or non-regular file, then renaming a fresh
# temporary over it, closes both that and the half-written file a reader can
# otherwise observe.
write_block() {
    local target="$1" dir tmp
    dir="$(dirname -- "$target")"
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        note "could not create $dir -- environment block printed to stdout only"
        return 0
    fi
    if [[ -L "$target" ]]; then
        note "refusing to write $target: it is a symlink, and this file is read back into agent context -- environment block printed to stdout only"
        return 0
    fi
    if [[ -e "$target" && ! -f "$target" ]]; then
        note "refusing to write $target: not a regular file -- environment block printed to stdout only"
        return 0
    fi
    if ! tmp="$(mktemp -- "$dir/.env-contract.XXXXXX" 2>/dev/null)"; then
        note "could not create a temporary file in $dir -- environment block printed to stdout only"
        return 0
    fi
    if ! printf '%s\n' "${OUT_LINES[@]}" 2>/dev/null >"$tmp"; then
        rm -f -- "$tmp" 2>/dev/null || true
        note "could not write $target -- environment block printed to stdout only"
        return 0
    fi
    # 0600: it carries local paths, the CA bundle location and the account name,
    # and mktemp's default is already private -- this survives a lax umask on the
    # rename target.
    chmod 600 -- "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$target" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        note "could not replace $target -- environment block printed to stdout only"
        return 0
    fi
    note "wrote $target"
}

# check_agent_dir_mode DIR -- surface a group/world-writable .agent (or
# .agent/logs) at session start rather than mid-review, where a downstream
# tool such as session-ledger.sh's validate_parent would otherwise be the
# first thing to notice and stop the run. Reports only, via note() -- it is
# not this script's job to refuse or fix an existing directory it may not
# have created (issue #474: a pre-existing group-writable .agent stays
# refused by its actual validator, with the same chmod fix named there).
check_agent_dir_mode() {
    local dir="$1" mode
    [[ -e $dir && ! -L $dir ]] || return 0
    mode=$(stat -c %a -- "$dir" 2>/dev/null) || return 0
    (( (8#$mode & 0022) == 0 )) ||
        note "$dir is group- or world-writable (mode $mode) -- later ledger/private-dir writes under it will be refused (fix: chmod 700 $dir)"
}

main() {
    parse_args "$@"
    if (( ARG_ENSURE )); then
        if (( ARG_WRITE_SET || ARG_REPO_SET || ARG_MEASURED_FROM_SET || ARG_INHERIT_SESSION_SET )); then
            die '--ensure cannot be combined with --write, --repo, --measured-from, or --inherit-session'
        fi
        resolve_worktree
        contract_reader="$SCRIPT_DIR/contract-read.sh"
        if [[ -x $contract_reader ]] && declare -F contract_cache_contract_file > /dev/null &&
            "$contract_reader" --repo-root "$WORKTREE" --check > /dev/null 2>&1; then
            # A provenance-trusted contract can still predate protected= (issue #296
            # follow-up): --check only validates ownership/tracked-state, not which
            # keys the file happens to carry, so a contract written before this key
            # existed would otherwise be served forever without it. Fall through to
            # the same fresh-preflight path a failed provenance re-read already uses,
            # rather than adding a second return path.
            if existing="$(cat -- "$(contract_cache_contract_file "$WORKTREE")")"; then
                if grep -q '^protected=' <<< "$existing" && grep -q '^skills-content=' <<< "$existing"; then
                    # Presence proves the KEYS exist, not that their VALUES
                    # describe this tree (issue #453 review): recompute both
                    # live values (the cost a fresh preflight already pays) and
                    # take the fast path only when BOTH match.
                    recorded_skills_path=$(sed -n 's/^skills= path=//p' <<< "$existing" | sed -n '1p')
                    recorded_skills_content=$(sed -n 's/^skills-content= sha256=//p' <<< "$existing" | sed -n '1p')
                    live_skills_path="$(skills_tree_root)"
                    live_skills_content=''
                    if command -v skills_content_hash > /dev/null 2>&1; then
                        live_skills_content=$(skills_content_hash "$live_skills_path" 2> /dev/null || true)
                    fi
                    [[ -n $live_skills_content ]] || live_skills_content=unavailable
                    if [[ $recorded_skills_path == "$live_skills_path" &&
                        $recorded_skills_content == "$live_skills_content" ]]; then
                        printf '%s\n' "$existing"
                        return 0
                    fi
                    if [[ $recorded_skills_path != "$live_skills_path" ]]; then
                        note "trusted contract's skills= path= no longer matches the running tree ($recorded_skills_path != $live_skills_path) -- continuing with a fresh preflight"
                    else
                        note "trusted contract's skills-content= no longer matches the running tree's content -- continuing with a fresh preflight"
                    fi
                else
                    note 'trusted contract predates protected= or skills-content= -- continuing with a fresh preflight'
                fi
            else
                note 'trusted contract changed while it was being read -- continuing with a fresh preflight'
            fi
        fi
    fi
    probe_skills_path
    probe_skills_content
    resolve_worktree
    probe_identity
    probe_config
    probe_protected
    probe_instructions
    probe_git
    probe_gh
    inherit_or_probe 'sandbox=' probe_sandbox sandbox_widened
    inherit_or_probe 'tls=' probe_tls
    inherit_or_probe 'caches=' probe_caches caches_widened
    probe_runners
    probe_runtime_pin
    probe_harness
    probe_peer_cli "$HARNESS_OTHER"
    local write_target="${ARG_WRITE:-$WORKTREE/.agent/env-contract.txt}"
    apply_never_widen "$write_target"
    printf '%s\n' "${OUT_LINES[@]}"
    if (( ARG_NO_WRITE )); then
        note "--no-write: no environment block file written"
        return 0
    fi
    if command -v secure_mkdir_p > /dev/null 2>&1; then
        secure_mkdir_p "$WORKTREE/.agent/logs" 2>/dev/null ||
            note "could not create $WORKTREE/.agent/logs -- agent-run.sh will fall back"
    else
        mkdir -p -- "$WORKTREE/.agent/logs" 2>/dev/null ||
            note "could not create $WORKTREE/.agent/logs -- agent-run.sh will fall back"
    fi
    check_agent_dir_mode "$WORKTREE/.agent"
    check_agent_dir_mode "$WORKTREE/.agent/logs"
    write_block "$write_target"
}

main "$@"
