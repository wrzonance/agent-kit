#!/usr/bin/env bash
#
# worktree-commit.sh -- stage and commit from inside a git worktree without the
# guaranteed "index.lock: Read-only file system" tax.
#
# WHY THIS EXISTS
#   A linked worktree keeps its git metadata under the MAIN repository's .git
#   directory (.git/worktrees/NAME/), not under the worktree checkout. When an
#   agent runs in a sandbox whose writable bind covers only the worktree, the
#   very first `git add` dies with
#       fatal: Unable to create '.../.git/worktrees/NAME/index.lock':
#              Read-only file system
#   after the files were already chosen and the change already narrated. The
#   cause is fully detectable before any staging happens, so this wrapper probes
#   BOTH git metadata directories for writability up front and exits 2 naming
#   the exact offending path. The worker hands the identical command to the
#   top-level session, which owns any privileged retry; this helper never
#   elevates itself.
#
# IT ALSO
#   * refuses to commit onto a trunk branch (main/master/trunk),
#   * runs `git diff --cached --check` (whitespace / conflict-marker gate),
#   * prints exactly one machine-readable line on success.
#
# EXIT CODES
#   0  committed
#   2  a git metadata directory is not writable -- needs elevation, then retry
#   3  an active merge carries protected paths that attended work must park
#   1  usage error, not a repository, trunk branch, or any git failure
#
# A merge-inherited protected path may also be authorized by a recorded
# session-ledger grant (--ledger/--run-id/--ledger-scope) instead of a named
# base: see guard_staged_protected_paths and issue #563.
#
set -euo pipefail

readonly PROGNAME="${0##*/}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
# shellcheck disable=SC1091  # sibling library is resolved at runtime
source "$SCRIPT_DIR/lib/protected-paths.sh"
# shellcheck disable=SC1091  # sibling library is resolved at runtime
source "$SCRIPT_DIR/lib/trunk-policy.sh"

SUBJECT=""
BODY=""
ALLOW_EMPTY=0
EXACT=1
SCOPE_MODE=""
ALLOW_BASE_INHERITED=0
BASE_INHERITED_REF=""
YOLO=0
LEDGER_FILE=""
LEDGER_RUN_ID=""
LEDGER_SCOPE=""
TRAILERS=()
FILES=()
ALLOW_OUTSIDE=()
MESSAGE_ARGS=()
META_COMMON_DIR=""
META_WORKTREE_DIR=""
LOCK_FD=""

usage() {
    cat <<EOF
Usage: $PROGNAME [--exact|--include-staged] --message SUBJECT [--body TEXT] [--trailer LINE]... [--allow-empty]
                 [--allow-outside PATH]... [--allow-base-inherited BASE [--yolo]] [--] FILE...

Stage FILE... and commit them from inside a git worktree, after verifying up
front that the repository's git metadata directories are writable.

Options:
  --message SUBJECT   Commit subject line. Required, must be a single line.
  --body TEXT         Commit body, added as its own paragraph. At most once.
  --trailer LINE      Trailer line, e.g. "Co-Authored-By: Name <a@example.com>".
                      Repeatable; all trailers share the final paragraph so git
                      parses them as one trailer block. Every LINE must be a
                      non-empty "Key: value" -- a value-less key, a key-less
                      value, or an empty value is refused rather than committed.
                      Omitted entirely, a "Co-Authored-By:" trailer is derived
                      from this repository's environment contract instead.
  --allow-empty       Permit a commit with no FILE operands / no staged change.
  --exact             Refuse staged paths outside FILE operands and mismatched
                      committed file counts (the default scope).
  --include-staged    Include existing staged paths, preserving legacy behavior.
                      Existing staged paths still require an explicit operand or
                      --allow-outside PATH.
  --allow-outside PATH
                      Explicitly authorize this tracked staged path outside the
                      issue FILE operands. Repeat for multiple paths.
  --allow-base-inherited BASE
                      Name the exact merge base whose protected paths may be
                      carried into this commit after byte-identity checks.
  --yolo              In unattended mode, authorize --allow-base-inherited BASE
                      when the named commit is the active merge head. Attended
                      runs park inherited paths and preserve them in the index.
  --ledger FILE --run-id ID --ledger-scope SCOPE
                      Given together (all three, or none): when every merge-
                      inherited protected path staged is a CI-workflow file
                      (.github/workflows/, .gitlab-ci.yml, .circleci/,
                      azure-pipelines.yml, Jenkinsfile), ask session-ledger.sh
                      whether RUN ID's ledger at FILE records a covering
                      'authorize:workflow-mutations' grant for SCOPE. A
                      covering grant commits with an Authorized-By-Ledger
                      trailer instead of parking. Harness/hook configuration
                      (.githooks/, .git/hooks/, .git/config,
                      .pre-commit-config.yaml, .codex/config.toml,
                      .claude/settings*.json) is never ledger-authorizable and
                      still parks the whole staged set; no covering record
                      also leaves the park behaviour unchanged.
  --                  End of options; every later argument is a FILE.
  -h, --help          Print this help and exit 0.

Behaviour:
  * Probes 'git rev-parse --git-dir' and '--git-common-dir' for writability
    BEFORE staging anything; exits 2 naming the unwritable path if either fails.
  * Refuses to commit while HEAD is on main, master or trunk.
  * Runs 'git diff --cached --check' after staging and aborts on its findings.
  * Exact mode refuses staged paths outside the FILE operands before staging.
  * Include-staged mode includes anything already staged in the index.
  * Every trailer -- supplied or derived -- is validated before staging and
    verified against the commit's own parsed trailers after committing.

Output (stdout, on success -- one line):
  committed 0123456789abcdef0123456789abcdef01234567 feat(example): add widget (3 files)

Examples:
  $PROGNAME --message 'feat(example): add widget' src/example.ts docs/example.md
  $PROGNAME --message 'fix(example): guard empty input' \\
            --body 'Rejects an empty payload at the boundary.' \\
            --trailer 'Co-Authored-By: Agent <noreply@example.com>' \\
            -- src/example.ts
EOF
}

die() {
    local code="$1"
    shift
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit "$code"
}

need_value() {
    (( $# >= 2 )) || die 1 "$1 requires a value (try --help)"
}

# Absolute, symlink-resolved form of a path git reported relative to $PWD.
abs_path() {
    local path="$1"
    case "$path" in
        /*) ;;
        *) path="$PWD/$path" ;;
    esac
    readlink -f -- "$path" 2>/dev/null || printf '%s' "$path"
}

parse_args() {
    local body_seen=0 opt value
    while (( $# > 0 )); do
        opt="$1"
        if [[ "$opt" == --*=* ]]; then
            value="${opt#*=}"
            set -- "${opt%%=*}" "$value" "${@:2}"
            continue
        fi
        case "$opt" in
            -h|--help) usage; exit 0 ;;
            --message) need_value "$@"; SUBJECT="$2"; shift 2 ;;
            --body)
                need_value "$@"
                (( body_seen == 0 )) || die 1 "--body given more than once"
                BODY="$2"
                body_seen=1
                shift 2
                ;;
            --trailer) need_value "$@"; TRAILERS+=("$2"); shift 2 ;;
            --allow-empty) ALLOW_EMPTY=1; shift ;;
            --allow-outside)
                need_value "$@"
                ALLOW_OUTSIDE+=("$2")
                shift 2
                ;;
            --exact)
                [[ $SCOPE_MODE != include ]] || die 1 "--exact and --include-staged are mutually exclusive"
                EXACT=1
                SCOPE_MODE=exact
                shift
                ;;
            --include-staged)
                [[ $SCOPE_MODE != exact ]] || die 1 "--exact and --include-staged are mutually exclusive"
                EXACT=0
                SCOPE_MODE=include
                shift
                ;;
            --allow-base-inherited)
                need_value "$@"
                (( ALLOW_BASE_INHERITED == 0 )) || die 1 "--allow-base-inherited given more than once"
                BASE_INHERITED_REF="$2"
                ALLOW_BASE_INHERITED=1
                shift 2
                ;;
            --yolo) YOLO=1; shift ;;
            --ledger)
                need_value "$@"
                [[ -z $LEDGER_FILE ]] || die 1 "--ledger given more than once"
                LEDGER_FILE="$2"
                shift 2
                ;;
            --run-id)
                need_value "$@"
                [[ -z $LEDGER_RUN_ID ]] || die 1 "--run-id given more than once"
                LEDGER_RUN_ID="$2"
                shift 2
                ;;
            --ledger-scope)
                need_value "$@"
                [[ -z $LEDGER_SCOPE ]] || die 1 "--ledger-scope given more than once"
                LEDGER_SCOPE="$2"
                shift 2
                ;;
            --) shift; FILES+=("$@"); break ;;
            -*) die 1 "unknown option: $opt (try --help)" ;;
            *) FILES+=("$1"); shift ;;
        esac
    done
}

# Keep this list aligned with the hook's protected-path defaults. Repository
# declarations are additive, so an agent cannot edit config.env to make an
# inherited gate disappear.
protected_pattern() {
    local candidate=$1 declared root
    candidate=${candidate#./}
    root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n $root && -x $SCRIPT_DIR/repo-config.sh ]]; then
        declared=$("$SCRIPT_DIR/repo-config.sh" --repo-root "$root" \
            --get AGENT_PROTECTED_PATHS 2>/dev/null || true)
    fi
    shared_protected_pattern "$candidate" "$root" "$declared" 0
}

staged_protected_paths() {
    local path
    while IFS= read -r -d '' path; do
        protected_pattern "$path" >/dev/null || continue
        printf '%s\n' "$path"
    done < <(git diff --cached --name-only -z --diff-filter=ACDMRTUXB)
}

park_inherited_paths() {
    local paths=$1
    printf '%s: merge-inherited protected paths parked/handed off (churn: merge-inherited):\n' \
        "$PROGNAME" >&2
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        printf '  %s\n' "$path" >&2
    done <<< "$paths"
    printf '%s: inherited bytes remain staged; attended mode will not silently drop them.\n' \
        "$PROGNAME" >&2
    printf '%s: re-run with --allow-base-inherited BASE --yolo only after naming the merged base.\n' \
        "$PROGNAME" >&2
    exit 3
}

active_merge() {
    local merge_head_file
    merge_head_file=$(git rev-parse --git-path MERGE_HEAD 2>/dev/null) || return 1
    [[ -s $merge_head_file ]]
}

base_merge_contains() {
    local base_commit=$1 merge_head_file head
    merge_head_file=$(git rev-parse --git-path MERGE_HEAD 2>/dev/null) || return 1
    [[ -r $merge_head_file ]] || return 1
    while IFS= read -r head; do
        [[ $head == "$base_commit" ]] && return 0
    done < "$merge_head_file"
    return 1
}

# base_merge_contains requires BASE_INHERITED_REF to equal an entry in the
# worktree's own MERGE_HEAD -- so the caller never has to be TOLD that value
# in advance (e.g. threaded into a dispatch prompt). Whoever is about to
# commit can always read it straight back with `git rev-parse MERGE_HEAD` at
# commit time, since it names the exact merge the caller is mid-way through.
# See parallel-issues/references/chains.md#merge-down-after-a-predecessor-advances
# for the chained-worker walkthrough this backs (issue #289).
verify_base_inherited() {
    local paths=$1 base_commit path
    base_commit=$(git rev-parse --verify "$BASE_INHERITED_REF^{commit}" 2>/dev/null) ||
        die 1 "--allow-base-inherited names an unresolved base: $BASE_INHERITED_REF"
    base_merge_contains "$base_commit" ||
        die 1 "--allow-base-inherited base is not the active merge head: $BASE_INHERITED_REF"
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        git diff --quiet --cached "$base_commit" -- "$path" ||
            die 1 "merge-inherited protected path differs from base $BASE_INHERITED_REF: $path"
    done <<< "$paths"
}

config_merge_authorized() {
    active_merge || return 1
    (( ALLOW_BASE_INHERITED == 1 && YOLO == 1 )) || return 1
    verify_base_inherited '.agent/config.env'
}

# The one decision token this guard ever checks. Fixed, never caller-chosen:
# only SCOPE (validate_ledger_args) varies per invocation, so a worker cannot
# widen its own authorization by naming a different decision (issue #563).
readonly LEDGER_WORKFLOW_DECISION='authorize:workflow-mutations'

# 0 when a recorded session-ledger grant covers this run's protected-path
# commit. Fails closed on any missing input or non-zero session-ledger.sh
# exit -- an unreadable or absent ledger is exactly as authorized as no
# ledger at all.
ledger_authorizes_workflow_mutations() {
    [[ -n $LEDGER_FILE ]] || return 1
    [[ -x $SCRIPT_DIR/session-ledger.sh ]] || return 1
    "$SCRIPT_DIR/session-ledger.sh" covers --ledger "$LEDGER_FILE" --run-id "$LEDGER_RUN_ID" \
        --decision "$LEDGER_WORKFLOW_DECISION" --scope "$LEDGER_SCOPE" >/dev/null 2>&1
}

# 0 when PATH is one of the fixed CI-workflow patterns a session-ledger
# authorize:workflow-mutations grant may authorize; 1 for every other
# protected path -- harness/hook configuration (.githooks/, .git/hooks/,
# .git/config, .pre-commit-config.yaml, .codex/config.toml,
# .claude/settings*.json) keeps parking even under a covering grant, and this
# is never widened by a repository's own AGENT_PROTECTED_PATHS declaration
# (issue #563 F1 adversarial-review fix).
ledger_authorizable_protected_path() {
    local candidate=$1 root
    candidate=${candidate#./}
    root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    shared_ci_workflow_pattern "$candidate" "$root" 0 >/dev/null
}

# Prints, one per line, every entry of PATHS that ledger_authorizable_protected_path
# refuses: the paths a covering ledger grant must never carry.
non_ledger_authorizable_paths() {
    local paths=$1 path
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        ledger_authorizable_protected_path "$path" || printf '%s\n' "$path"
    done <<< "$paths"
}

guard_staged_protected_paths() {
    local paths
    active_merge || return 0
    paths=$(staged_protected_paths)
    [[ -n $paths ]] || return 0
    if (( ALLOW_BASE_INHERITED == 1 && YOLO == 1 )); then
        verify_base_inherited "$paths"
        printf '%s: merge-inherited paths authorized by named base (churn: merge-inherited): %s\n' \
            "$PROGNAME" "${paths//$'\n'/, }" >&2
        return 0
    fi
    if ledger_authorizes_workflow_mutations; then
        local non_ci_paths
        non_ci_paths=$(non_ledger_authorizable_paths "$paths")
        if [[ -z $non_ci_paths ]]; then
            local ledger_trailer="Authorized-By-Ledger: $LEDGER_RUN_ID $LEDGER_WORKFLOW_DECISION"
            validate_trailer_line "$ledger_trailer"
            TRAILERS+=("$ledger_trailer")
            printf '%s: staged protected paths authorized by session ledger (run %s, decision %s): %s\n' \
                "$PROGNAME" "$LEDGER_RUN_ID" "$LEDGER_WORKFLOW_DECISION" "${paths//$'\n'/, }" >&2
            return 0
        fi
        printf '%s: session ledger grant does not authorize non-CI-workflow protected paths: %s\n' \
            "$PROGNAME" "${non_ci_paths//$'\n'/, }" >&2
    fi
    park_inherited_paths "$paths"
}

validate_args() {
    [[ -n "$SUBJECT" ]] || die 1 "--message is required (try --help)"
    [[ "$SUBJECT" != *$'\n'* ]] || die 1 "--message must be a single line"
    if (( ${#FILES[@]} == 0 && ALLOW_EMPTY == 0 )); then
        die 1 "no FILE operands given; pass at least one file or --allow-empty"
    fi
    validate_ledger_args
}

# --ledger/--run-id/--ledger-scope form one coherent authorization query: a
# caller that supplies one or two of the three has an incomplete query, never
# a partial authorization, so this refuses rather than silently ignoring the
# fragment.
validate_ledger_args() {
    local supplied=0
    [[ -z $LEDGER_FILE ]] || supplied=$((supplied + 1))
    [[ -z $LEDGER_RUN_ID ]] || supplied=$((supplied + 1))
    [[ -z $LEDGER_SCOPE ]] || supplied=$((supplied + 1))
    (( supplied == 0 || supplied == 3 )) || die 1 \
        '--ledger, --run-id, and --ledger-scope must be given together or not at all'
}

# Exact mode is the safe default for root corrections: a pre-existing staged
# path must be one of the explicit operands, otherwise the caller may commit a
# worker's unrelated work. Resolve both sides with Git's own pathspec matcher
# and --no-renames output so directory operands, duplicates, and rename pairs
# use the same de-duplicated path set.
scope_paths_for() {
    local path status old new
    local -a operands=("$@")
    local -A scoped=()
    (( ${#operands[@]} > 0 )) || return 0

    while IFS= read -r -d '' path; do
        scoped["$path"]=1
    done < <(git diff --cached --name-only --no-renames -z \
        --diff-filter=ACDMRTUXB -- "${operands[@]}")

    # A rename is represented as a deletion and an addition by --no-renames.
    # When either side is selected, retain both paths in the expected set so a
    # staged rename can be named by its live destination or its old source.
    while IFS= read -r -d '' status; do
        case "$status" in
            R*)
                IFS= read -r -d '' old || break
                IFS= read -r -d '' new || break
                if [[ ${scoped["$old"]+yes} == yes || ${scoped["$new"]+yes} == yes ]]; then
                    scoped["$old"]=1
                    scoped["$new"]=1
                fi
                ;;
        esac
    done < <(git diff --cached --name-status --find-renames -z --diff-filter=R)

    for path in "${!scoped[@]}"; do
        printf '%s\0' "$path"
    done
}

scope_paths() {
    scope_paths_for "${FILES[@]}"
}

authorized_scope_paths() {
    scope_paths_for "${FILES[@]}" "${ALLOW_OUTSIDE[@]}"
}

exact_scope_paths_match() {
    local path
    local -A staged=() expected=()

    while IFS= read -r -d '' path; do
        staged["$path"]=1
    done < <(git diff --cached --name-only --no-renames -z --diff-filter=ACDMRTUXB)
    while IFS= read -r -d '' path; do
        expected["$path"]=1
    done < <(authorized_scope_paths)

    for path in "${!staged[@]}"; do
        [[ ${expected["$path"]+yes} == yes ]] || return 1
    done
    for path in "${!expected[@]}"; do
        [[ ${staged["$path"]+yes} == yes ]] || return 1
    done
    return 0
}

merge_inherited_path_authorized() {
    local path=$1 merge_head
    active_merge || return 1
    protected_pattern "$path" >/dev/null && return 1
    merge_head=$(git rev-parse --verify 'MERGE_HEAD^{commit}' 2>/dev/null) || return 1
    git diff --quiet --cached "$merge_head" -- "$path"
}

refuse_staged_outside_operands() {
    local path
    local -a offending=()
    local -A expected=()
    while IFS= read -r -d '' path; do
        expected["$path"]=1
    done < <(authorized_scope_paths)
    while IFS= read -r -d '' path; do
        [[ ${expected["$path"]+yes} == yes ]] && continue
        # A merge-down brings protected base files into the index by design;
        # let the dedicated park/authorize guard below handle those bytes.
        if active_merge && { protected_pattern "$path" >/dev/null ||
            [[ $path == .agent/config.env ]]; }; then
            continue
        fi
        if merge_inherited_path_authorized "$path"; then
            continue
        fi
        offending+=("$path")
    done < <(git diff --cached --name-only --no-renames -z --diff-filter=ACDMRTUXB)
    ((${#offending[@]} == 0)) || {
        if (( EXACT == 1 )); then
            printf '%s: --exact refuses staged paths outside FILE operands or --allow-outside paths:\n' \
                "$PROGNAME" >&2
        else
            printf '%s: refuses staged paths outside FILE operands or --allow-outside paths:\n' \
                "$PROGNAME" >&2
        fi
        printf '  %s\n' "${offending[@]}" >&2
        die 1 'remove the foreign paths from the index or name each one with --allow-outside PATH'
    }
}

# .agent/config.env is base-trusted policy input: adversarial-run.sh reads its
# reviewer settings from the PR base, so a worker must not carry a local edit
# along accidentally. An explicit config.env operand is the issue write-set
# declaration that authorizes the change; this guard also covers
# --include-staged, which stages existing operands but must not silently sweep
# unrelated tracked changes into a commit.
config_operand_named() {
    local file candidate root magic suffix
    root=$(git rev-parse --show-toplevel 2>/dev/null || return 1)
    root=$(readlink -f -- "$root" 2>/dev/null || printf '%s' "$root")
    for file in "${FILES[@]}" "${ALLOW_OUTSIDE[@]}"; do
        if [[ ${file:0:2} == ':(' ]]; then
            magic=${file#':('}
            suffix=${magic#*)}
            magic=${magic%%\)*}
            [[ $magic == top || $magic == top,* ]] &&
                [[ $suffix == .agent/config.env ]] && return 0
        elif [[ $file == ':/.agent/config.env' ]]; then
            return 0
        fi
        if [[ $file == /* ]]; then
            candidate=$(readlink -m -- "$file" 2>/dev/null || true)
        else
            candidate=$(readlink -m -- "$PWD/$file" 2>/dev/null || true)
        fi
        [[ $candidate == "$root/.agent/config.env" ]] && return 0
    done
    return 1
}

refuse_unrequested_config() {
    local staged
    staged=$(git diff --cached --name-only --no-renames -- ':(top).agent/config.env')
    [[ -z $staged ]] || config_operand_named || config_merge_authorized || die 1 \
        'refusing unrequested .agent/config.env change; name .agent/config.env explicitly in the issue write set'
}

guard_exact_operand_scope() {
    (( EXACT == 1 )) || return 0
    exact_scope_paths_match || die 1 \
        '--exact staged paths do not match the FILE operand pathspec scope'
}

# Leading/trailing whitespace trim -- the standard parameter-expansion idiom,
# safe under `set -u` for empty and all-whitespace input alike.
trim_ws() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

trailer_key() { printf '%s' "${1%%:*}"; }
trailer_value() { trim_ws "${1#*:}"; }

# A trailer must be a non-empty "Key: value" line. This is the sole guard
# against the three ways attribution has actually been lost in the field
# (issue #305): no ':' at all (a bare identity string with no key), a key
# with nothing after the ':' once trimmed, and -- across two separate tool
# calls -- an empty string that reaches here as an entirely empty LINE.
validate_trailer_line() {
    local line="$1" key value
    case "$line" in
        *:*) ;;
        *) die 1 "--trailer must be a 'Key: value' line (no ':' found): $line" ;;
    esac
    key="$(trailer_key "$line")"
    value="$(trailer_value "$line")"
    [[ "$key" =~ ^[A-Za-z0-9-]+$ ]] || die 1 \
        "--trailer key must be a git-trailer token (letters, digits, hyphens only -- git rejects '_'): $line"
    [[ -n "$value" ]] || die 1 "--trailer has an empty value after '$key:': $line"
}

# contract-read.sh's harness.trailer key composes a complete, git-parseable
# "Co-Authored-By: <identity>" line -- it is the one key that never returns a
# bare identity (see issue #345: a field literally named "trailer" that held
# a keyless identity was the trap that let a caller pass it straight to
# --trailer and silently drop attribution). This helper still validates and
# post-commit-verifies whatever it gets back, rather than trusting the name.
contract_trailer_value() {
    local repo_root value rc=0
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die 1 \
        "no --trailer given and no default can be derived: not inside a git repository"
    [[ -x "$SCRIPT_DIR/contract-read.sh" ]] || die 1 \
        "no --trailer given and no default can be derived: missing $SCRIPT_DIR/contract-read.sh"
    value="$("$SCRIPT_DIR/contract-read.sh" --repo-root "$repo_root" --get harness.trailer 2>&1)" || rc=$?
    (( rc == 0 )) || die 1 \
        "no --trailer given and no default can be derived (pass --trailer explicitly): $value"
    [[ -n "$value" ]] || die 1 \
        "no --trailer given and no default can be derived: contract harness.trailer resolved empty -- pass --trailer explicitly"
    printf '%s' "$value"
}

resolve_trailers() {
    local line
    if (( ${#TRAILERS[@]} == 0 )); then
        # contract_trailer_value already returns a complete "Co-Authored-By: ..."
        # line (contract-read.sh's harness.trailer composes it) -- do not
        # prefix it again here.
        TRAILERS+=("$(contract_trailer_value)")
    fi
    for line in "${TRAILERS[@]}"; do
        validate_trailer_line "$line"
    done
}

# --git-dir is the per-worktree metadata dir (where index.lock is created);
# --git-common-dir is the shared repository metadata dir. Both must be writable.
resolve_git_dirs() {
    local common worktree
    common="$(git rev-parse --git-common-dir 2>/dev/null)" \
        || die 1 "not inside a git repository (git rev-parse failed) cwd=$PWD"
    worktree="$(git rev-parse --git-dir 2>/dev/null)" \
        || die 1 "not inside a git repository (git rev-parse failed) cwd=$PWD"
    META_COMMON_DIR="$(abs_path "$common")"
    META_WORKTREE_DIR="$(abs_path "$worktree")"
}

probe_writable() {
    local dir="$1" probe
    [[ -d "$dir" ]] || return 1
    probe="$dir/.worktree-commit-probe.$$"
    # A read-only *mount* passes `[[ -w ]]`, so actually create a file. The
    # redirection order matters: bash applies redirections left to right, so
    # 2>/dev/null must come FIRST or the failed '>' still prints to stderr.
    if : 2>/dev/null >"$probe"; then
        rm -f -- "$probe"
        return 0
    fi
    return 1
}

report_unwritable() {
    local dir="$1" consequence="$2"
    printf '%s: git metadata directory is not writable: %s\n' "$PROGNAME" "$dir" >&2
    printf '%s: %s\n' "$PROGNAME" "$consequence" >&2
    printf '%s: nothing was staged. This workflow uses a designed handback: hand the identical command back to the top-level session for publication, then retry it there after the path is writable.\n' \
        "$PROGNAME" >&2
    exit 2
}

require_writable_git_dirs() {
    probe_writable "$META_WORKTREE_DIR" \
        || report_unwritable "$META_WORKTREE_DIR" \
            "staging would fail on $META_WORKTREE_DIR/index.lock before touching your files."
    if [[ "$META_COMMON_DIR" != "$META_WORKTREE_DIR" ]]; then
        probe_writable "$META_COMMON_DIR" \
            || report_unwritable "$META_COMMON_DIR" \
                "the commit would fail writing objects and refs under $META_COMMON_DIR."
    fi
}

# The index lock only covers one git command. This descriptor covers the whole
# stage/check/commit transaction and lives in the common directory so linked
# worktrees contend on the same lock.
acquire_transaction_lock() {
    local lock_file="$META_COMMON_DIR/worktree-commit.lock"

    command -v flock > /dev/null 2>&1 || die 1 \
        "transaction lock requires 'flock' on PATH"
    if ! exec {LOCK_FD}>"$lock_file"; then
        die 1 "cannot open transaction lock: $lock_file"
    fi
    if ! flock -x "$LOCK_FD"; then
        die 1 "cannot acquire transaction lock: $lock_file"
    fi
}

refuse_trunk() {
    local branch declared root
    # symbolic-ref works on an unborn branch too, and stays quiet when detached.
    branch="$(git symbolic-ref --quiet --short HEAD || true)"
    [[ -n "$branch" ]] || return 0

    # main|master|trunk is a DEFAULT, not the answer. The repository states its
    # own trunk in AGENT_BASE_BRANCH, and a repository whose trunk is `develop`
    # was protected by neither list -- so the one branch that most needed this
    # guard was the one branch it ignored.
    #
    # `q` after the first match rather than `| head -1`: closing a pipe early
    # makes sed exit on SIGPIPE, and under `set -o pipefail` that becomes this
    # script's exit status.
    root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"
    declared="$(shared_declared_trunk_branch "$root" 2>/dev/null || true)"
    if [[ -n "$declared" && "$branch" == "$declared" ]]; then
        die 1 "refusing to commit to '$branch', this repository's declared base branch -- create a feature branch first"
    fi

    if ! shared_is_trunk_branch "$branch" "$root"; then
        case "$branch" in main|master|trunk) ;; *) return 0;; esac
    fi
    case "$branch" in
        main|master|trunk)
            die 1 "refusing to commit to trunk branch '$branch' -- create a feature branch first"
            ;;
    esac
}

# A path can be ignored by a rule in a file nobody thought to look at. The case
# that cost real time: .gitignore carried the intended allowlist
# (`.agent/*` plus `!.agent/config.env`) while .git/info/exclude carried a
# broader `.agent/`. Git does not descend into an excluded DIRECTORY, so the
# negation is never reached -- the allowlist is textually present and has no
# effect. git's own message names the directory, not the rule or the file, so
# each session re-derived it from scratch.
#
# --no-index is required: without it check-ignore stays silent about a tracked
# file, which is exactly the file being reported on here.
#
# Deciding needs the PLAIN form, which lists only genuinely excluded paths. The
# -v form reports the last matching pattern even when it is a negation, and
# exits 0 regardless -- so a working allowlist would report itself as the
# problem. Decide plainly; use -v only to name the rule.
explain_ignored() {
    local ignored matches
    ignored=$(git check-ignore --no-index -- "${FILES[@]}" 2> /dev/null) || return 0
    [[ -n $ignored ]] || return 0
    # Explain ONLY the paths that are actually excluded. Passing the whole FILES
    # list would also print the negation lines matched by the files that staged
    # fine, which reads as though the allowlist were the fault.
    matches=$(xargs -d '\n' -r git check-ignore --no-index -v -- <<< "$ignored" 2> /dev/null) || return 0
    [[ -n $matches ]] || return 0
    printf '%s: these paths are excluded by an ignore rule:\n' "$PROGNAME" >&2
    printf '%s\n' "$matches" | sed 's/^/  /' >&2
    if grep -qE '^[^:]*:[0-9]+:[^[:space:]]*/[[:space:]]' <<< "$matches"; then
        printf '%s: a rule ending in "/" excludes the DIRECTORY, and git does not descend\n' "$PROGNAME" >&2
        printf '%s: into one -- so a "!" negation for a file inside it is never reached.\n' "$PROGNAME" >&2
        printf '%s: narrow that rule (e.g. .agent/ -> .agent/*) in the file named above.\n' "$PROGNAME" >&2
    fi
}

stage_files() {
    local rc=0 file
    local -a stageable=()
    (( ${#FILES[@]} > 0 )) || return 0
    for file in "${FILES[@]}"; do
        # An already-staged deletion (the old side of a staged rename) has no
        # live path for git add to match. Its index entry is already in scope;
        # stage the remaining operands and leave that deletion untouched.
        if [[ ! -e $file && ! -L $file ]] &&
            ! git diff --cached --quiet -- "$file"; then
            continue
        fi
        stageable+=("$file")
    done
    if ((${#stageable[@]} > 0)); then
        git add -- "${stageable[@]}" || rc=$?
    fi
    if (( rc != 0 )); then
        explain_ignored
        die 1 "git add failed (rc=$rc) for: ${FILES[*]}"
    fi
}

check_staged() {
    local rc=0
    git diff --cached --check || rc=$?
    (( rc == 0 )) || die 1 \
        "git diff --cached --check reported whitespace or conflict-marker problems (rc=$rc); fix them and re-run"
}

build_message_args() {
    MESSAGE_ARGS=(--message "$SUBJECT")
    if [[ -n "$BODY" ]]; then
        MESSAGE_ARGS+=(--message "$BODY")
    fi
    if (( ${#TRAILERS[@]} > 0 )); then
        # git only parses the LAST paragraph as trailers, so every --trailer
        # must land in one shared -m paragraph, not one -m each.
        MESSAGE_ARGS+=(--message "$(printf '%s\n' "${TRAILERS[@]}")")
    fi
}

do_commit() {
    local rc=0
    local args=(commit --quiet "${MESSAGE_ARGS[@]}")
    if (( ALLOW_EMPTY == 1 )); then
        args+=(--allow-empty)
    fi
    git "${args[@]}" || rc=$?
    (( rc == 0 )) || die 1 \
        "git commit failed (rc=$rc); nothing was committed (check 'git status', or pass --allow-empty)"
}

report_commit() {
    local sha count
    sha="$(git rev-parse HEAD)"
    count="$(git show --pretty=format: --name-only --no-renames HEAD |
        awk 'NF { n++ } END { print n + 0 }')"
    printf 'committed %s %s (%s files)\n' "$sha" "$SUBJECT" "$count"
}

# Validation catches a malformed --trailer before it is ever staged, but it
# cannot catch git's own trailer parser disagreeing with ours. Read the
# trailers back off the commit we just made -- the way the receipt publisher
# byte-verifies its own output -- and fail loudly, before the one-line success
# record prints, if an intended trailer did not survive into the real commit.
verify_trailers() {
    local actual line key value aline akey avalue found
    # Pin the separator this read is parsed with: a repository-local
    # trailer.separators config that drops ':' (e.g. "=") would otherwise
    # change how git's own pretty-format parses trailers, misreporting a real
    # commit with a well-formed "Key: value" trailer as a verification
    # failure purely because of repo config, not the commit itself. This
    # helper's documented, validated syntax is always "Key: value".
    actual="$(git -c trailer.separators=: log -1 --format='%(trailers:only=true,unfold=true)' HEAD)"
    for line in "${TRAILERS[@]}"; do
        key="$(trailer_key "$line")"
        value="$(trailer_value "$line")"
        found=0
        while IFS= read -r aline; do
            [[ -n "$aline" ]] || continue
            akey="$(trailer_key "$aline")"
            avalue="$(trailer_value "$aline")"
            if [[ "$akey" == "$key" && "$avalue" == "$value" ]]; then
                found=1
                break
            fi
        done <<< "$actual"
        (( found == 1 )) || die 1 \
            "post-commit verification failed: expected trailer not found on $(git rev-parse HEAD): $line"
    done
}

main() {
    parse_args "$@"
    validate_args
    resolve_trailers
    resolve_git_dirs
    require_writable_git_dirs
    refuse_trunk
    acquire_transaction_lock
    refuse_unrequested_config
    refuse_staged_outside_operands
    stage_files
    refuse_unrequested_config
    guard_staged_protected_paths
    guard_exact_operand_scope
    check_staged
    build_message_args
    do_commit
    verify_trailers
    report_commit
}

main "$@"
