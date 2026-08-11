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
    -type d -path "*/agentkit/*/skills" 2>/dev/null | sort -V | tail -1)
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

# Is this cached contract OURS, or did the repository supply it?
#
# The contract is read straight into model context and announced as established
# fact that the agent must not re-probe. So whatever can write this file can put
# text in an agent's head. A hostile repository does not need an exploit for
# that -- it only has to TRACK .agent/env-contract.txt, and cloning and opening
# the repository is enough. An external review found this reachable and rated it
# the single critical defect in the tree.
#
# Three ways it is not ours, each of which alone is disqualifying:
#   tracked  -- it arrived with the checkout; our preflight never commits it
#   symlink  -- it can name .git/config, a key file, anything readable
#   foreign  -- another user owns it, so another user chooses its contents
#
# Rejecting costs one preflight run. Accepting costs the session.
guard_contract_is_ours() {
    local file=$1 root=${2:-}
    [[ -n $file && ! -L $file && -f $file && -O $file ]] || return 1
    [[ -n $root ]] || return 0
    ! git -C "$root" ls-files --error-unmatch -- "$file" > /dev/null 2>&1
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
        ".shared/scripts/board-list.sh|what is on the Project board by column; --issue N to confirm one item"
        ".shared/scripts/ci-gap.sh|which CI gates no declared command covers"
        ".shared/scripts/triage-issues.sh|open issues with board status and linked PRs, one call"
        "parallel-issues/scripts/move-github-project-item.sh|set an issue's board Status, one call"
        ".shared/scripts/agent-run.sh|run a command this repo declared, by name: --cmd <name>"
        ".shared/scripts/worktree-commit.sh|stage and commit without sweeping working state"
        "review-remote-pr/scripts/gh-pr-state.sh|CI and review state for a pull request"
        ".shared/scripts/bootstrap-repo.sh|re-declare this repo facts; see the onboard-repo skill"
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

# Commands that destroy work. This is the ONE place a hard, repeatable denial is
# right, and it is the opposite of every other guard here.
#
# The rest of the guard set never blocks, because a command with a cheaper
# alternative should run and be corrected afterwards. There is no
# teach-after-the-fact for a force-push that already landed, and a
# once-per-session override would refuse the first attempt and permit the
# second -- precisely backwards. So these deny every time, and say what to do
# instead.
#
# Kept deliberately short. A long list of "risky" commands trains an agent to
# treat denials as noise, which is how the one that mattered gets worked around.
# `git clean --force -d` and `git clean -fd` do identical damage, and only the
# second was refused. So did `git push origin +main`, `git branch --delete
# --force main`, and `rm --recursive --force /`. None of that is obfuscation --
# it is git's own documented spelling, and an external review found all four by
# reading the man pages.
#
# That matters more than an ordinary miss, because the README told operators to
# hand over a writable .git on the strength of these patterns refusing this
# class "every time, with no override". Normalising the long forms first is what
# lets each rule state its intent once instead of enumerating spellings.
guard_normalize_flags() {
    # Longest first: --force-with-lease contains --force.
    sed -E 's/--force-with-lease(=[^[:space:]]*)?/-f/g
            s/--force/-f/g
            s/--recursive/-r/g
            s/--delete/-d/g' <<< "$1" 2> /dev/null || printf '%s' "$1"
}

# Are all of these short flags present, however they are arranged -- clustered
# (-rf), separate (-r -f), or long (--recursive --force, once normalised)?
# Enumerating arrangements in a regex is where the original rules went wrong.
guard_has_short_flags() {
    local cmd=$1 want letters
    shift
    letters=$(tr -s '[:space:]' '\n' <<< "$cmd" 2> /dev/null |
        grep -E '^-[a-zA-Z]+$' | tr -d '\n-' || true)
    for want in "$@"; do
        [[ $letters == *"$want"* ]] || return 1
    done
    return 0
}

guard_destructive_reason() {
    local cmd=$1 stripped flattened normalized

    # A flag hidden inside a substitution reads as ordinary text to every pattern
    # below: `git push $(echo --force)` matched nothing. Flattening the
    # substitution markers and re-testing catches the literal case.
    #
    # Deliberately NOT a ban on substitution in these commands. `git push origin
    # $(git branch --show-current)` is an ordinary thing to write, and flattening
    # leaves it as `git push origin git branch --show-current`, which matches
    # nothing -- so the legitimate use survives and the hidden flag does not.
    #
    # A determined evasion still gets through (a variable, a split string). This
    # guards against an agent taking a shortcut, not against an adversary.
    flattened=${cmd//\$(/ }
    flattened=${flattened//[\`)]/ }
    if [[ $flattened != "$cmd" ]]; then
        local hidden
        if hidden=$(guard_destructive_reason "$flattened"); then
            printf '%s (the command hides that flag inside a substitution; write it literally if you mean it)' "$hidden"
            return 0
        fi
    fi

    stripped=$(guard_strip_git_globals "$cmd")
    normalized=$(guard_normalize_flags "$stripped")

    if grep -qE '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]][^;&|]*)?[[:space:]]+(--force|--force-with-lease|-f)([[:space:]]|$)' <<< "$normalized"; then
        printf 'force-pushing rewrites history other people may already have. Push a normal commit, or ask the user to force-push themselves.'
        return 0
    fi
    # A leading + on a refspec IS --force, for that ref only, and carries no flag
    # for a flag-shaped pattern to find.
    if grep -qE '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]][^;&|]*)?[[:space:]]\+[^[:space:];&|]' <<< "$stripped"; then
        printf 'a + on the refspec force-pushes that ref, rewriting history other people may already have. Push a normal commit, or ask the user to force-push themselves.'
        return 0
    fi
    # Intervening tokens are tolerated, as in the push rule: after a substitution
    # is flattened the flag is no longer adjacent to the verb. Bounded by shell
    # separators, so a later unrelated command cannot be dragged into the match.
    if grep -qE '(^|[;&|[:space:]])git[[:space:]]+reset([[:space:]][^;&|]*)?[[:space:]]--hard' <<< "$stripped"; then
        printf 'reset --hard discards uncommitted work irrecoverably. Use git stash, or commit first.'
        return 0
    fi
    if grep -qE '(^|[;&|[:space:]])git[[:space:]]+clean([[:space:]]|$)' <<< "$normalized" &&
        guard_has_short_flags "$normalized" f; then
        printf 'git clean -f deletes untracked files, including .agent/ working state. Remove named paths instead.'
        return 0
    fi
    # -D, or -d with -f, or the long spellings of either -- all the same deletion.
    if grep -qE '(^|[;&|[:space:]])git[[:space:]]+branch([[:space:]][^;&|]*)?[[:space:]](main|master|trunk)([[:space:]]|$)' <<< "$normalized" &&
        { grep -qE '(^|[[:space:]])-[a-zA-Z]*D' <<< "$normalized" ||
            guard_has_short_flags "$normalized" d f; }; then
        printf 'deleting the trunk branch is not recoverable from this clone. If this is really intended, the user should do it.'
        return 0
    fi
    # Plumbing. These were covered only by the sandbox holding .git read-only,
    # and that protection is exactly what a writable-root recommendation removes
    # -- so the guard has to cover them before the recommendation is made.
    # Porcelain patterns never saw any of these: they rewrite refs and destroy
    # the recovery path without the word "force" or "hard" appearing anywhere.
    if grep -qE '(^|[;&|[:space:]])git([[:space:]][^;&|]*)?[[:space:]]update-ref([[:space:]]|$)' <<< "$stripped"; then
        printf 'update-ref moves a branch or tag without any of the checks a commit or push goes through. Use the porcelain command for what you actually mean.'
        return 0
    fi
    if grep -qE '(^|[;&|[:space:]])git([[:space:]][^;&|]*)?[[:space:]]symbolic-ref[[:space:]]+HEAD[[:space:]]+[^-]' <<< "$stripped"; then
        printf 'rewriting HEAD detaches the branch from the work in it. Use git switch.'
        return 0
    fi
    if grep -qE '(^|[;&|[:space:]])git([[:space:]][^;&|]*)?[[:space:]]reflog[[:space:]]+expire' <<< "$stripped"; then
        printf 'expiring the reflog destroys the only recovery path for everything else on this list. There is no undo behind it.'
        return 0
    fi
    if grep -qE '(^|[;&|[:space:]])git([[:space:]][^;&|]*)?[[:space:]]gc([[:space:]][^;&|]*)?[[:space:]]--prune' <<< "$stripped"; then
        printf 'gc --prune makes unreachable objects unrecoverable. Leave collection to git own schedule.'
        return 0
    fi
    if grep -qE '(^|[;&|[:space:]])git([[:space:]][^;&|]*)?[[:space:]]filter-(branch|repo)' <<< "$stripped"; then
        printf 'filter-branch and filter-repo rewrite every commit they touch. That is a decision for the user, on a repository they have backed up.'
        return 0
    fi
    # An execution key in git config runs a command during ORDINARY git
    # operations, persists after the session, and runs as the user rather than
    # the agent. It is the quietest code-execution vector in a repository.
    if grep -qE '(^|[;&|[:space:]])git([[:space:]][^;&|]*)?[[:space:]]config([[:space:]][^;&|]*)?[[:space:]](core\.hooksPath|core\.fsmonitor|filter\.[^[:space:]]+\.(clean|smudge|process)|core\.sshCommand|diff\.[^[:space:]]+\.textconv)' <<< "$cmd"; then
        printf 'that git config key executes a command during ordinary git operations, and it outlives this session. Setting it is a decision for the user.'
        return 0
    fi
    if grep -qE '(^|[;&|[:space:]])gh[[:space:]]+pr[[:space:]]+merge' <<< "$cmd"; then
        printf 'merging a pull request is the user decision, not the agent one. Report that the PR is ready instead.'
        return 0
    fi
    if grep -qE '(^|[[:space:]])--no-verify([[:space:]]|$)' <<< "$cmd"; then
        printf '--no-verify skips the checks the repository installed on purpose. Fix what they are reporting.'
        return 0
    fi
    # Flags in any arrangement, then the target. -R is the same as -r here, so
    # the membership test is done against a lowercased flag set.
    if grep -qE '(^|[;&|[:space:]])rm([[:space:]]|$)' <<< "$normalized" &&
        guard_has_short_flags "${normalized//R/r}" r f &&
        grep -qE '[[:space:]](/|~|\$HOME)([[:space:]]|/?$)' <<< "$normalized"; then
        printf 'a recursive force-remove of the home directory or filesystem root is never what was meant.'
        return 0
    fi
    return 1
}

# Committing straight onto the trunk branch.
#
# Found by a virgin-repo onboarding run: the skill said "git add" then "commit",
# the agent did exactly that, and the onboarding commit landed on `main` of a
# repository whose every other change arrives by pull request. Nothing objected,
# because the trunk refusal lives in worktree-commit.sh and the skill had told
# the agent to use plain git.
#
# Deny-ONCE, not always. Plenty of people commit to main on purpose -- a solo
# repository, a docs typo, the first commit of an empty tree -- and a hard
# refusal would be wrong in all of those. One refusal is enough to turn an
# unnoticed default into a decision.
#
# Evidence rule: a repository that has not declared a trunk gets no opinion.
# AGENT_BASE_BRANCH is what onboarding writes; origin/HEAD is the fallback, and
# when neither answers, this stays silent rather than guessing at "main".
guard_trunk_commit_reason() {
    local cmd=$1 root=$2 current trunk
    [[ -n $root ]] || return 1

    # Command position, so `git commit` in a message body or a grep pattern is
    # not a commit. `git -C dir commit` and `git commit -m x` both qualify;
    # --dry-run does not, since it writes nothing.
    grep -qE '(^|[;&|])[[:space:]]*git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+commit([[:space:]]|$)' \
        <<< "$cmd" || return 1
    grep -qE '[[:space:]]--dry-run([[:space:]]|=|$)' <<< "$cmd" && return 1

    current=$(git -C "$root" symbolic-ref --quiet --short HEAD 2> /dev/null) || return 1
    [[ -n $current ]] || return 1

    trunk=$(sed -n 's/^[[:space:]]*AGENT_BASE_BRANCH[[:space:]]*=[[:space:]]*//p' \
        "$root/.agent/config.env" 2> /dev/null | tail -1)
    trunk=${trunk%%[[:space:]]*}
    if [[ -z $trunk ]]; then
        trunk=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null) || true
        trunk=${trunk#origin/}
    fi
    [[ -n $trunk && $current == "$trunk" ]] || return 1

    printf '%s' "$current"
}

# A hook that fails open is invisible. Every silent failure this tree has had --
# a SIGPIPE exit of 141, a pipefail death before the error could print -- looked
# from outside exactly like a hook that had nothing to say. One line per
# incident, next to the logs the runner already writes.
guard_log_error() {
    local status=${1:-?} dir="${GUARD_LOG_ROOT:-$PWD}/.agent/logs"
    mkdir -p "$dir" 2> /dev/null || return 0
    printf '{"hook":"%s","status":"%s","line":"%s"}\n' \
        "${GUARD_HOOK_NAME:-unknown}" "$status" "${BASH_LINENO[0]:-unknown}" \
        >> "$dir/hook-errors.jsonl" 2> /dev/null || true
}

# Files that decide whether other checks run: CI definitions, git hooks, harness
# configuration. Editing one is legitimate work sometimes and quietly disabling
# a gate to go green other times, and the two are indistinguishable from the
# diff alone.
#
# So this is deny-ONCE, like the helper-path rule and unlike the destructive one:
# refusing outright would block real work, and allowing silently is how a
# loosened gate ships. One refusal makes the second attempt a deliberate choice.
#
# The defaults name only the gate-and-guard class, which is the same in every
# repository. Anything repo-specific -- migrations, generated files, a vendored
# tree -- belongs in AGENT_PROTECTED_PATHS, because guessing at it here would be
# wrong somewhere else.
readonly -a GUARD_PROTECTED_DEFAULTS=(
    '.github/workflows/'
    '.gitlab-ci.yml'
    '.circleci/'
    'azure-pipelines.yml'
    'Jenkinsfile'
    '.githooks/'
    '.git/hooks/'
    '.git/config'
    '.pre-commit-config.yaml'
    # The harness CONFIG decides what runs; the installed plugin tree does not.
    # A blanket '.codex/' refused an agent READING the very skill it had been
    # asked to follow -- the guard fired on the plugin's own instructions.
    '.codex/config.toml'
    '.claude/settings.json'
    '.claude/settings.local.json'
)

# Prints the matched pattern when a path is protected. Repository-declared
# entries are additive: a repo can extend the list, never shrink it, so a
# committed file cannot switch its own guard off.
guard_protected_match() {
    local candidate=$1 root=$2 pattern
    local -a patterns=("${GUARD_PROTECTED_DEFAULTS[@]}")

    candidate=${candidate//\\//}
    candidate=${candidate#./}
    # An absolute path inside the repository is compared repo-relative, so the
    # same rule covers both forms an agent might use.
    [[ -z $root || $candidate != "$root"/* ]] || candidate=${candidate#"$root"/}

    if [[ -n $root && -r $root/.agent/config.env ]]; then
        local declared
        declared=$(sed -n 's/^[[:space:]]*AGENT_PROTECTED_PATHS[[:space:]]*=[[:space:]]*//p' \
            "$root/.agent/config.env" 2> /dev/null | tail -1)
        if [[ -n $declared ]]; then
            local IFS=,
            read -r -a extra <<< "$declared"
            patterns+=("${extra[@]}")
        fi
    fi

    for pattern in "${patterns[@]}"; do
        [[ -n $pattern ]] || continue
        pattern=${pattern#./}
        if [[ $pattern == */ ]]; then
            [[ $candidate == "$pattern"* || $candidate == *"/$pattern"* ]] || continue
        else
            [[ $candidate == "$pattern" || $candidate == *"/$pattern" ]] || continue
        fi
        printf '%s' "$pattern"
        return 0
    done
    return 1
}

# Paths a SHELL command is about to write. The edit-tool guard never sees these:
# a redirect or `sed -i` is a Bash call, not a file edit, which is the gap that
# let a workflow be rewritten past it.
#
# Narrow on purpose -- only write-shaped operators, and only matched against the
# protected list afterwards. A general "commands that touch files" rule would
# fire on every grep and be switched off within a week.
guard_shell_write_targets() {
    local cmd=$1 write_probe=$1

    # Redirects to device sinks discard output but do not write a protected
    # path. Remove them before deciding whether the command is write-shaped.
    write_probe=$(sed -E \
        's/[0-9]*>>?[[:space:]]*\/dev\/(null|stdout|stderr)//g' \
        <<< "$write_probe")

    # Two stages, because the alternative is parsing operands per command and
    # that rots: `sed -i` takes its file LAST, `tee` takes it first, a redirect
    # has no command word at all. Getting one of those wrong is how a rule ends
    # up silently matching nothing.
    #
    # Stage one: does this command write at all? A path mentioned by grep or cat
    # is not a target, and matching those would fire this rule constantly.
    grep -qE '(^|[;&|[:space:]])(tee|sed[[:space:]]+-i|cp|mv|install|truncate|dd)([[:space:]]|$)|>>?[[:space:]]*[^[:space:]&|]' \
        <<< "$write_probe" 2> /dev/null || return 0

    # Stage two: offer every token and let the protected list decide. A token
    # that is not protected costs nothing; a target missed by clever parsing
    # costs the whole guard.
    tr -s '[:space:]' '\n' <<< "$cmd" 2> /dev/null |
        sed -E 's/^[<>]+//; s/^["'"'"']+//; s/["'"'"']+$//' |
        grep -vE '^-|^$' || true
}

# Every path a tool call is about to write. Covers the file-edit tools of both
# harnesses plus the patch format one of them uses, where the paths are inside
# the payload text rather than in a field of their own.
guard_target_paths() {
    local payload=$1
    jq -r '
        [ .tool_input.file_path?, .tool_input.path?, .tool_input.notebook_path?,
          (.tool_input.edits? // [] | .[]? | .file_path?) ]
        | map(select(type == "string")) | .[]
    ' <<< "$payload" 2> /dev/null || true

    # `*** Add File: path` / `Update File:` / `Delete File:` / `Move to:`
    jq -r '[.tool_input | .. | strings] | .[]' <<< "$payload" 2> /dev/null |
        grep -oE '^\*\*\*[[:space:]]+(Add|Update|Delete)[[:space:]]+File:[[:space:]]+.+$|^\*\*\*[[:space:]]+Move to:[[:space:]]+.+$' 2> /dev/null |
        sed -E 's/^\*\*\*[[:space:]]+(Add|Update|Delete)[[:space:]]+File:[[:space:]]+//; s/^\*\*\*[[:space:]]+Move to:[[:space:]]+//' || true
}
