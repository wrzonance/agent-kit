#!/usr/bin/env bash
# Shared guard logic. SOURCED by the hook dispatchers, never executed.
#
# PreToolUse and PostToolUse must agree on which repositories a command touches
# and which of them declared what. Two copies of that logic drifting apart would
# make one hook act where the other stayed silent, for reasons invisible from
# either file.

# The exact snippet the skills use. Defined once so no message can teach a path
# that does not resolve -- which is what these messages did after packaging moved
# the tree, and only a live session caught it.
# shellcheck disable=SC2016  # every $ here is literal text the AGENT reads and
# retypes. Expanding it would bake this machine's paths into the advice.
readonly RESOLVE_HINT='  agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" -maxdepth 4 \
    -type d -path "*/agentkit/*/skills" 2>/dev/null | sort | tail -1)
  [ -n "$agentkit" ] || agentkit="${CODEX_HOME:-$HOME/.codex}/skills"'

# shellcheck disable=SC2034  # read by pre-tool-use.sh, which sources this file
readonly HELPERS='agent-run|worktree-commit|gh-pr-state|agent-preflight|repo-config|triage-issues|move-github-project-item|gh-comment'

# Populated by guard_resolve_roots.
roots=()

guard_add_root() {
    local resolved existing
    resolved=$(git -C "$1" rev-parse --show-toplevel 2> /dev/null) || return 0
    for existing in ${roots[@]+"${roots[@]}"}; do
        [[ $existing != "$resolved" ]] || return 0
    done
    roots+=("$resolved")
}

# Every repository a command might act on -- not just the one the session started
# in. An agent launched in $HOME and told "commit my work in <repo>" reaches it
# with `cd <repo> && ...` or `git -C <repo> ...`. Anchoring to the session cwd
# alone left the repository-scoped guards inert for exactly that session, with no
# sign they had switched off.
guard_resolve_roots() {
    local cwd=$1 command_line=$2 candidate

    if [[ -n $cwd && -d $cwd ]]; then
        guard_add_root "$cwd"
    fi

    # Paths the command names. Read as text and never evaluated: this parses an
    # untrusted command line, where a substitution would execute it.
    while IFS= read -r candidate; do
        [[ -n $candidate ]] || continue
        candidate=${candidate/#\~/$HOME}
        if [[ -d $candidate ]]; then
            guard_add_root "$candidate"
        fi
    done < <(grep -oE '(^|[;&|])[[:space:]]*cd[[:space:]]+[^[:space:];&|]+|-C[[:space:]]+[^[:space:];&|]+' \
        <<< "$command_line" 2> /dev/null | sed -E 's/.*(cd|-C)[[:space:]]+//' || true)
}

# True when ANY candidate repository carries the file. A guard keyed to a
# repository's own declaration should act on the repository being touched.
guard_has_evidence() {
    local r
    for r in ${roots[@]+"${roots[@]}"}; do
        [[ ! -r "$r/$1" ]] || return 0
    done
    return 1
}

# Where per-session state lives: the first candidate that has an .agent/ at all,
# since that is the repository whose declarations are in play.
guard_state_root() {
    local r
    for r in ${roots[@]+"${roots[@]}"}; do
        if [[ -d "$r/.agent" ]]; then
            printf '%s' "$r"
            return 0
        fi
    done
    printf '%s' "${roots[0]-}"
}

# Claim "this lesson, this session" exactly once.
#
#   0  claimed now      -- first time, and it is recorded
#   1  already claimed  -- said earlier in this session
#   2  cannot record    -- no root, or the state is not writable
#
# Created with mkdir because it is atomic: two tool calls in one turn would
# otherwise both see "not yet claimed" and both act.
#
# The three-way answer exists because advisories and denials must treat the
# unwritable case in OPPOSITE directions -- see the two wrappers below. Collapsing
# it to a boolean is what would reintroduce the deny loop.
guard_claim() {
    local root=$1 session=$2 rule=$3 dir
    [[ -n $root ]] || return 2

    session=${session//[^A-Za-z0-9._-]/_}
    rule=${rule//[^A-Za-z0-9._-]/_}
    dir="$root/.agent/cache/brief/${session:-nosession}"

    mkdir -p "$dir" 2> /dev/null || return 2
    mkdir "$dir/$rule" 2> /dev/null || return 1
    return 0
}

# Advisory: speak unless it was already said. An unrecorded claim SPEAKS -- a
# repeated sentence is noise, silence loses the lesson, and nothing that calls
# this can block a command.
guard_should_advise() {
    local rc=0
    guard_claim "$@" || rc=$?
    ((rc != 1))
}

# Denial: deny ONLY on a claim that was actually recorded.
#
# This is the inverse of the advisory rule and it is the single most important
# line in the guard set. A denial issued on state that could not be persisted
# denies the retry identically, and the one after that -- an unrecoverable loop
# with no human in the loop for a worker. Cannot record, do not deny.
guard_should_deny() {
    local rc=0
    guard_claim "$@" || rc=$?
    ((rc == 0))
}

# The tooling contract: what exists here, and the one question each answers.
#
# Only helpers that resolve ON DISK are named. A curriculum that names a missing
# script teaches a broken path -- the same failure the deny messages had after
# packaging moved the tree, and the reason a gate exists for it.
#
# Kept to one line each. It competes with the environment contract for the
# agent's attention; past that, it is a skill rather than a contract.
guard_curriculum() {
    local skills=$1 entry rel desc out=''
    local -a entries=(
        ".shared/scripts/triage-issues.sh|board status and cross-referenced PRs for many issues, one call"
        "parallel-issues/scripts/move-github-project-item.sh|set an issue's board Status, one call"
        ".shared/scripts/agent-run.sh|run a command this repo declared, by name: --cmd <name>"
        ".shared/scripts/worktree-commit.sh|stage and commit without sweeping working state"
        "review-remote-pr/scripts/gh-pr-state.sh|CI and review state for a pull request"
    )

    [[ -d $skills ]] || return 1
    for entry in "${entries[@]}"; do
        rel=${entry%%|*}
        desc=${entry#*|}
        [[ -e "$skills/$rel" ]] || continue
        # shellcheck disable=SC2016  # $agentkit is literal text the agent retypes
        out+='  $agentkit/'"$rel  -- $desc"$'\n'
    done
    [[ -n $out ]] || return 1

    printf 'Deterministic helpers available here -- prefer them over ad-hoc calls.\nResolve the tree once, then use the paths below:\n%s\n%s' \
        "$RESOLVE_HINT" "$out"
}

# Normalise global git options out of a command line before matching a
# subcommand. They sit BETWEEN `git` and the subcommand, so a `git[[:space:]]+add`
# pattern misses every one of them -- `git -C . add -A` walked straight through.
#
# A bounded list is deliberate: a pattern loose enough to skip arbitrary text
# would also match `git log --grep "add -A"`.
guard_strip_git_globals() {
    sed -E '
        s/[[:space:]]+-(C|c)[[:space:]]+[^[:space:]]+//g
        s/[[:space:]]+--(git-dir|work-tree|namespace|exec-path)=[^[:space:]]+//g
        s/[[:space:]]+--(no-pager|paginate|bare|no-replace-objects|literal-pathspecs)([[:space:]]|$)/ /g
        s/[[:space:]]+-P([[:space:]]|$)/ /g
    ' <<< "$1" 2> /dev/null || printf '%s' "$1"
}
