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
#   the exact offending path, telling the caller to retry the identical command
#   with elevated filesystem permission. It never tries to elevate itself.
#
# IT ALSO
#   * refuses to commit onto a trunk branch (main/master/trunk),
#   * runs `git diff --cached --check` (whitespace / conflict-marker gate),
#   * prints exactly one machine-readable line on success.
#
# EXIT CODES
#   0  committed
#   2  a git metadata directory is not writable -- needs elevation, then retry
#   1  usage error, not a repository, trunk branch, or any git failure
#
set -euo pipefail

readonly PROGNAME="${0##*/}"

SUBJECT=""
BODY=""
ALLOW_EMPTY=0
TRAILERS=()
FILES=()
MESSAGE_ARGS=()
META_COMMON_DIR=""
META_WORKTREE_DIR=""
LOCK_FD=""

usage() {
    cat <<EOF
Usage: $PROGNAME --message SUBJECT [--body TEXT] [--trailer LINE]... [--allow-empty] [--] FILE...

Stage FILE... and commit them from inside a git worktree, after verifying up
front that the repository's git metadata directories are writable.

Options:
  --message SUBJECT   Commit subject line. Required, must be a single line.
  --body TEXT         Commit body, added as its own paragraph. At most once.
  --trailer LINE      Trailer line, e.g. "Co-Authored-By: Name <a@example.com>".
                      Repeatable; all trailers share the final paragraph so git
                      parses them as one trailer block.
  --allow-empty       Permit a commit with no FILE operands / no staged change.
  --                  End of options; every later argument is a FILE.
  -h, --help          Print this help and exit 0.

Behaviour:
  * Probes 'git rev-parse --git-dir' and '--git-common-dir' for writability
    BEFORE staging anything; exits 2 naming the unwritable path if either fails.
  * Refuses to commit while HEAD is on main, master or trunk.
  * Runs 'git diff --cached --check' after staging and aborts on its findings.
  * Anything already staged in the index is included in the commit.

Output (stdout, on success -- one line):
  committed abc1234 feat(example): add widget (3 files)

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
            --) shift; FILES+=("$@"); break ;;
            -*) die 1 "unknown option: $opt (try --help)" ;;
            *) FILES+=("$1"); shift ;;
        esac
    done
}

validate_args() {
    [[ -n "$SUBJECT" ]] || die 1 "--message is required (try --help)"
    [[ "$SUBJECT" != *$'\n'* ]] || die 1 "--message must be a single line"
    if (( ${#FILES[@]} == 0 && ALLOW_EMPTY == 0 )); then
        die 1 "no FILE operands given; pass at least one file or --allow-empty"
    fi
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
    printf '%s: nothing was staged. Retry this identical command with elevated filesystem permission for that path.\n' \
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
    declared="$(sed -n 's/^[[:space:]]*AGENT_BASE_BRANCH=[[:space:]]*//p
                        /^[[:space:]]*AGENT_BASE_BRANCH=/q' \
        "$root/.agent/config.env" 2>/dev/null | tr -d '\r')"
    if [[ -n "$declared" && "$branch" == "$declared" ]]; then
        die 1 "refusing to commit to '$branch', this repository's declared base branch -- create a feature branch first"
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
    local rc=0
    (( ${#FILES[@]} > 0 )) || return 0
    git add -- "${FILES[@]}" || rc=$?
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
    sha="$(git rev-parse --short HEAD)"
    count="$(git show --pretty=format: --name-only --no-renames HEAD |
        awk 'NF { n++ } END { print n + 0 }')"
    printf 'committed %s %s (%s files)\n' "$sha" "$SUBJECT" "$count"
}

main() {
    parse_args "$@"
    validate_args
    resolve_git_dirs
    require_writable_git_dirs
    refuse_trunk
    acquire_transaction_lock
    stage_files
    check_staged
    build_message_args
    do_commit
    report_commit
}

main "$@"
