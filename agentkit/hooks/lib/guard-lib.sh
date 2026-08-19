#!/usr/bin/env bash
# Shared guard logic. SOURCED by the hook dispatchers, never executed.
#
# PreToolUse and PostToolUse must agree on which repositories a command touches
# and which of them declared what. Two copies of that logic drifting apart would
# make one hook act where the other stayed silent, for reasons invisible from
# either file.

# The exact snippet the skills use. Defined once so no message can teach a path
# that does not resolve -- which is what these messages did after packaging moved
# the tree, and only a live session caught it. The contract is the guarded,
# worktree-rooted source of truth; the cache search is an explicit bootstrap for
# a contract-absent checkout.
# shellcheck disable=SC2016  # every $ here is literal text the AGENT reads and
# retypes. Expanding it would bake this machine's paths into the advice.
readonly RESOLVE_HINT='  agentkit=
  contract_root=$(git rev-parse --show-toplevel 2>/dev/null) || contract_root=
  contract=
  if [[ -n "$contract_root" ]]; then
      contract="$contract_root/.agent/env-contract.txt"
  fi
  if [[ -n "$contract_root" && -r "$contract" && -f "$contract" &&
        ! -L "$contract" && -O "$contract" ]] &&
      ! git -C "$contract_root" ls-files --error-unmatch -- .agent/env-contract.txt \
          >/dev/null 2>&1; then
      agentkit=$(sed -n "s/^skills= path=//p" "$contract" 2>/dev/null | head -n 1)
  fi
  if [[ -z "$agentkit" ]]; then
      # Contract-absent bootstrap: discover the installed plugin tree.
      agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" \
          "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" -maxdepth 4 \
          -type d -path "*/agentkit/*/skills" 2>/dev/null | sort -V | tail -1)
      [ -n "$agentkit" ] || agentkit="${CODEX_HOME:-$HOME/.codex}/skills"
  fi
  if [[ -n "$contract_root" && -n "$agentkit" &&
        -x "$agentkit/.shared/scripts/contract-read.sh" ]]; then
      contract_skills=$("$agentkit/.shared/scripts/contract-read.sh" \
          --repo-root "$contract_root" --get skills.path 2>/dev/null)
      [[ -z "$contract_skills" || "$contract_skills" == "$agentkit" ]] || agentkit=
  fi'

# shellcheck disable=SC2034  # read by pre-tool-use.sh, which sources this file
readonly HELPERS='agent-run|worktree-commit|gh-pr-state|agent-preflight|repo-config|contract-read|triage-issues|move-github-project-item|gh-comment|gh-body'

GUARD_LIB_DIR=${BASH_SOURCE[0]%/*}
[[ $GUARD_LIB_DIR != "${BASH_SOURCE[0]}" ]] || GUARD_LIB_DIR=.
SHARED_SCRIPT_LIB=$(cd -- "$GUARD_LIB_DIR/../../skills/.shared/scripts/lib" 2>/dev/null && pwd -P) || {
    printf 'guard-lib.sh: shared script library is unavailable relative to %s\n' \
        "${BASH_SOURCE[0]}" >&2
    return 2
}
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SHARED_SCRIPT_LIB/protected-paths.sh"

# Populated by guard_resolve_roots.
roots=()

# The session repository is the workspace anchor. Target guards classify every
# command target against it instead of inferring intent from path spelling.
workspace_root=''
workspace_common=''
GUARD_TARGET_CLASSIFICATION=''
GUARD_TARGET_ROOT=''
GUARD_SCOPE_CLASSIFICATION=''

# Filesystem scope is narrower than repository targeting. `roots` may include
# repositories named by a command so repository-scoped advice follows `cd` and
# `git -C`; those names are untrusted input and must never authorize a walker.
scope_roots=()

guard_add_root() {
    local resolved existing
    resolved=$(git -C "$1" rev-parse --show-toplevel 2> /dev/null) || return 0
    for existing in ${roots[@]+"${roots[@]}"}; do
        [[ $existing != "$resolved" ]] || return 0
    done
    roots+=("$resolved")
}

guard_repository_common() {
    local root=$1 common
    common=$(git -C "$root" rev-parse --git-common-dir 2> /dev/null) || return 1
    case $common in
        /*) ;;
        *) common="$root/$common";;
    esac
    guard_scope_canonical "$common"
}

guard_fixture_path() {
    local candidate=$1 fixture configured=${AGENT_FIXTURE_ROOTS:-}
    local -a fixtures=(/tmp "${TMPDIR:-/tmp}") extra=()
    candidate=$(guard_scope_canonical "$candidate") || return 1
    [[ -n ${AGENT_FIXTURE_ROOT:-} ]] && fixtures+=("$AGENT_FIXTURE_ROOT")
    if [[ -n $configured ]]; then
        local IFS=:
        read -r -a extra <<< "$configured"
        fixtures+=("${extra[@]}")
    fi
    for fixture in "${fixtures[@]}"; do
        [[ -n $fixture ]] || continue
        fixture=$(guard_scope_canonical "$fixture") || continue
        [[ $candidate == "$fixture" || $candidate == "$fixture"/* ]] && return 0
    done
    return 1
}

guard_workspace_root() {
    local root=$1 common
    [[ -n $workspace_root ]] || return 1
    [[ $root == "$workspace_root" ]] && return 0
    common=$(guard_repository_common "$root") || return 1
    [[ -n $workspace_common && $common == "$workspace_common" ]]
}

# Classify a resolved repository root. A root with no git toplevel is handled
# by guard_classify_target as unresolved for policy guards; scope maps it to a
# foreign escape because that is the safe answer for a walker.
guard_classify_root() {
    local root=$1
    GUARD_TARGET_ROOT=$root
    if [[ -z $root ]]; then
        GUARD_TARGET_CLASSIFICATION=unresolved
    elif guard_workspace_root "$root"; then
        if [[ $root == "$workspace_root" && -n ${AGENT_FIXTURE_ROOT:-} ]] &&
            guard_fixture_path "$root" 2> /dev/null; then
            GUARD_TARGET_CLASSIFICATION=fixture
        else
            GUARD_TARGET_CLASSIFICATION=workspace
        fi
    elif guard_fixture_path "$root"; then
        GUARD_TARGET_CLASSIFICATION=fixture
    else
        GUARD_TARGET_CLASSIFICATION=foreign
    fi
    printf '%s' "$GUARD_TARGET_CLASSIFICATION"
}

# Command substitutions run in a child shell, so the globals populated by the
# classifier do not survive `classification=$(...)`. Return both values as a
# small, explicit record for callers that need diagnostics or policy roots.
guard_classify_root_result() {
    guard_classify_root "$1" > /dev/null
    printf '%s\n%s' "$GUARD_TARGET_CLASSIFICATION" "$GUARD_TARGET_ROOT"
}

guard_target_path() {
    local target=$1 base=${2:-$PWD} candidate probe root
    case $target in
        /*) candidate=$target;;
        *) candidate="$base/$target";;
    esac
    candidate=$(guard_scope_canonical "$candidate") || return 2
    probe=$candidate
    [[ -d $probe ]] || probe=${probe%/*}
    [[ -n $probe ]] || probe=/
    root=$(git -C "$probe" rev-parse --show-toplevel 2> /dev/null) || return 1
    printf '%s\n%s' "$root" "$candidate"
}

guard_command_dir_candidate() {
    local cwd=$1 candidate=$2
    candidate=${candidate#\"}; candidate=${candidate%\"}
    candidate=${candidate#\'}; candidate=${candidate%\'}
    case $candidate in
        /*|~|~/*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*) ;;
        *) candidate="$cwd/$candidate";;
    esac
    guard_scope_canonical "$candidate"
}

guard_command_target_dir() {
    local cwd=$1 command_line=$2 target=${3:-}
    local current segment trimmed candidate git_candidate segment_dir last_effective
    local -a words
    current=$(guard_scope_canonical "$cwd") || current=$cwd
    last_effective=$current

    # Walk shell segments in order. A target is resolved against the directory
    # in force at the segment that names it; a later `cd` cannot rewrite that
    # earlier target. Git's -C is parsed only before the git subcommand, so
    # grep's -C context flag and `git commit -C <message>` are not directories.
    local segments=${command_line//[;&|]/$'\n'}
    while IFS= read -r segment; do
        trimmed=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<< "$segment")
        [[ -n $trimmed ]] || continue
        read -r -a words <<< "$trimmed"
        ((${#words[@]})) || continue
        segment_dir=$current
        git_candidate=''

        if [[ ${words[0]} == cd && ${#words[@]} -ge 2 ]]; then
            candidate=$(guard_command_dir_candidate "$current" "${words[1]}") || candidate=''
            [[ -n $candidate ]] && current=$candidate
            segment_dir=$current
        elif [[ ${words[0]} == git ]]; then
            local i word next
            for ((i = 1; i < ${#words[@]}; i++)); do
                word=${words[i]}
                case $word in
                    --) break;;
                    -C)
                        ((i + 1 < ${#words[@]})) || break
                        next=${words[i + 1]}
                        candidate=$(guard_command_dir_candidate "$current" "$next") || candidate=''
                        [[ -d $candidate ]] && git_candidate=$candidate
                        ((i++))
                        ;;
                    -C*)
                        candidate=$(guard_command_dir_candidate "$current" "${word#-C}") || candidate=''
                        [[ -d $candidate ]] && git_candidate=$candidate
                        ;;
                    -*) ;;
                    *) break;;
                esac
            done
            [[ -n $git_candidate ]] && segment_dir=$git_candidate
        fi

        last_effective=$segment_dir
        if [[ -n $target && $trimmed == *"$target"* ]]; then
            printf '%s' "$segment_dir"
            return 0
        fi
    done <<< "$segments"
    printf '%s' "$last_effective"
}

guard_command_repository_root() {
    local cwd=$1 command_line=$2 dir
    dir=$(guard_command_target_dir "$cwd" "$command_line") || return 1
    git -C "$dir" rev-parse --show-toplevel 2> /dev/null
}

# Shared boundary for all repository-policy and scope guards. It resolves the
# target path relative to the command's effective directory, then classifies
# the resulting git root. A failed root lookup remains unresolved so policy
# callers can fail closed exactly as they did before classification existed.
guard_classify_target() {
    local target=$1 cwd=$2 command_line=${3:-} base resolved candidate
    base=$(guard_command_target_dir "$cwd" "$command_line" "$target") || base=$cwd
    resolved=$(guard_target_path "$target" "$base" 2> /dev/null) || {
        case $target in
            /*) candidate=$target;;
            *) candidate="$base/$target";;
        esac
        GUARD_TARGET_ROOT=''
        GUARD_TARGET_CLASSIFICATION=unresolved
        printf '%s' "$GUARD_TARGET_CLASSIFICATION"
        return 0
    }
    GUARD_TARGET_ROOT=${resolved%%$'\n'*}
    guard_classify_root "$GUARD_TARGET_ROOT"
}

guard_classify_target_result() {
    guard_classify_target "$1" "$2" "${3:-}" > /dev/null
    printf '%s\n%s' "$GUARD_TARGET_CLASSIFICATION" "$GUARD_TARGET_ROOT"
}

# Every repository a command might act on -- not just the one the session started
# in. An agent launched in $HOME and told "commit my work in <repo>" reaches it
# with `cd <repo> && ...` or `git -C <repo> ...`. Anchoring to the session cwd
# alone left the repository-scoped guards inert for exactly that session, with no
# sign they had switched off.
guard_resolve_roots() {
    local cwd=$1 command_line=$2 candidate

    if [[ -n $cwd && -d $cwd ]]; then
        workspace_root=$(git -C "$cwd" rev-parse --show-toplevel 2> /dev/null || true)
        if [[ -n $workspace_root ]]; then
            workspace_common=$(guard_repository_common "$workspace_root" 2> /dev/null || true)
        fi
        guard_add_root "$cwd"
    fi

    # Add only the effective directory selected by the segment-aware parser.
    # Broad grep over the whole command mistakes grep context and commit
    # message reuse flags for directory-bearing -C options.
    candidate=$(guard_command_target_dir "$cwd" "$command_line" 2> /dev/null || true)
    [[ -d $candidate ]] && guard_add_root "$candidate"
}

# Resolve only the hook's trusted working directory and its current repository.
# Command-derived `cd`/`-C` paths intentionally never enter this list.
guard_add_scope_root() {
    local resolved existing
    resolved=$(guard_scope_canonical "$1") || return 0
    for existing in ${scope_roots[@]+"${scope_roots[@]}"}; do
        [[ $existing != "$resolved" ]] || return 0
    done
    scope_roots+=("$resolved")
}

guard_resolve_scope_roots() {
    local cwd=$1 repo
    [[ -n $cwd && -d $cwd ]] || return 0
    guard_add_scope_root "$cwd"
    repo=$(git -C "$cwd" rev-parse --show-toplevel 2> /dev/null) || return 0
    guard_add_scope_root "$repo"
}

# Roots in which a dispatched worker is expected to read. The contract is the
# source for skills and cache paths; no path from the command line is executed
# while resolving this list.
guard_scope_allowed_roots() {
    local r contract skills cache

    for r in ${scope_roots[@]+"${scope_roots[@]}"}; do
        printf '%s\n' "$r"
        contract="$r/.agent/env-contract.txt"
        guard_contract_is_ours "$contract" "$r" || continue
        skills=$(sed -n 's/^skills= path=//p' "$contract" 2>/dev/null | head -n 1)
        [[ -n $skills ]] && printf '%s\n' "$skills"
        cache=$(sed -n 's/^caches= root=\([^[:space:]]*\).*/\1/p' "$contract" 2>/dev/null | head -n 1)
        [[ -n $cache ]] && printf '%s\n' "$cache"
    done
    printf '%s\n' /tmp
}

# Canonicalize a path without requiring that it exists. This makes the
# component boundary explicit: /repo is not a parent of /repo-evil.
guard_scope_canonical() {
    local path=$1 component canonical=''
    local -a components kept=()
    case $path in
        '~') path=${HOME:-}/;;
        \~/*) path=${HOME:-}${path#\~};;
        '$HOME') path=${HOME:-}/;;
        '$HOME/'*) path=${HOME:-}${path#'$HOME'};;
        '${HOME}') path=${HOME:-}/;;
        '${HOME}/'*) path=${HOME:-}${path#'${HOME}'};;
    esac
    case $path in
        /*) ;;
        *) path=$PWD/$path;;
    esac
    IFS=/ read -r -a components <<< "$path"
    for component in "${components[@]}"; do
        case $component in
            ''|.) ;;
            ..)
                if ((${#kept[@]})); then
                    kept=("${kept[@]:0:${#kept[@]}-1}")
                fi
                ;;
            *) kept+=("$component");;
        esac
    done
    for component in "${kept[@]}"; do
        canonical+="/$component"
    done
    printf '%s\n' "${canonical:-/}"
}

# Resolve existing symlink components without trusting lexical containment.
# For a missing leaf, resolve its parent and append only that leaf. A caller
# that cannot resolve the parent must fail closed rather than treating the
# spelling as proof that the target stays in the worker.
guard_target_realpath() {
    local candidate=$1 parent base resolved
    if [[ -e $candidate || -L $candidate ]]; then
        realpath -e -- "$candidate" 2> /dev/null || return 2
    else
        parent=${candidate%/*}
        base=${candidate##*/}
        [[ -n $parent ]] || parent=/
        resolved=$(realpath -e -- "$parent" 2> /dev/null) || return 2
        printf '%s/%s\n' "$resolved" "$base"
    fi
}

guard_path_inside() {
    local root=$1 candidate=$2
    [[ $candidate == "$root" || $candidate == "$root"/* ]]
}

guard_scope_path_allowed() {
    local candidate root root_canonical
    candidate=$(guard_scope_canonical "$1") || return 1
    [[ -n $candidate ]] || return 1
    while IFS= read -r root; do
        [[ -n $root ]] || continue
        root_canonical=$(guard_scope_canonical "$root") || continue
        [[ -n $root_canonical ]] || continue
        if [[ $candidate == "$root_canonical" || $candidate == "$root_canonical"/* ]]; then
            return 0
        fi
    done < <(guard_scope_allowed_roots)
    return 1
}

# Return the first absolute/home-expanded path outside the allowed roots when
# a command segment is a walker/reader. Relative paths are intentionally left
# alone: the resolved repository/cwd contract answers those without guessing.
guard_out_of_scope_target() {
    local command_line=$1 segment verb token cleaned has_walker=0
    local cwd=${2:-$PWD} command_root='' command_class='' command_dir=''
    local -a words
    local segments=${command_line//[;&|]/$'\n'}
    # shellcheck disable=SC2034  # consumed by the sourcing PreToolUse hook
    GUARD_SCOPE_CLASSIFICATION=''
    command_root=$(guard_command_repository_root "$cwd" "$command_line" 2> /dev/null || true)
    if [[ -z $command_root ]]; then
        command_dir=$(guard_command_target_dir "$cwd" "$command_line" 2> /dev/null || true)
        if [[ -n $command_dir && $command_dir != "$(guard_scope_canonical "$cwd")" ]]; then
            command_root=$command_dir
            # A temporary non-git fixture is still in-scope. Only an
            # unambiguously foreign directory receives the advisory.
            if guard_fixture_path "$command_dir"; then
                command_class=fixture
            else
                command_class=foreign
            fi
        fi
    fi

    while IFS= read -r segment; do
        [[ -n ${segment//[[:space:]]/} ]] || continue
        read -r -a words <<< "$segment"
        ((${#words[@]})) || continue
        verb=${words[0]#\(}
        case $verb in
            find|rg|fd|du|cat|sed|head|tail) has_walker=1 ;;
            grep)
                for token in "${words[@]:1}"; do
                    [[ $token == -* && $token != -- ]] || continue
                    [[ $token == *r* || $token == *R* ]] && has_walker=1
                done
                ;;
            ls)
                for token in "${words[@]:1}"; do
                    [[ $token == -* && $token != -- ]] || continue
                    [[ $token == *R* ]] && has_walker=1
                done
                ;;
        esac
        ((has_walker)) || continue

        # A relative walk inherits the command's effective directory. If that
        # directory resolves to a foreign repository, advise even though the
        # command never spelled an absolute path.
        if [[ -n $command_root ]]; then
            if [[ -z $command_class ]]; then
                guard_classify_root "$command_root" > /dev/null
                command_class=$GUARD_TARGET_CLASSIFICATION
            fi
            if [[ $command_class == foreign ]]; then
                # shellcheck disable=SC2034  # consumed by the sourcing hook
                GUARD_SCOPE_CLASSIFICATION=foreign
                printf '%s' "$command_root"
                return 0
            fi
        elif [[ $segment =~ (^|[[:space:];&|])cd[[:space:]]+ ]]; then
            # shellcheck disable=SC2034  # consumed by the sourcing hook
            GUARD_SCOPE_CLASSIFICATION=foreign
            printf '%s' "$(guard_command_target_dir "$cwd" "$segment")"
            return 0
        fi

        for token in "${words[@]:1}"; do
            cleaned=${token#\"}; cleaned=${cleaned%\"}
            cleaned=${cleaned#\'}; cleaned=${cleaned%\'}
            cleaned=${cleaned%,}; cleaned=${cleaned%)}
            case $cleaned in
                /*|~|~/*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*)
                    if ! guard_scope_path_allowed "$cleaned"; then
                        case $cleaned in
                            /*)
                                classification_result=$(guard_classify_target_result "$cleaned" "$cwd" "$command_line")
                                command_class=${classification_result%%$'\n'*}
                                ;;
                            *) command_class=foreign;;
                        esac
                        [[ $command_class == workspace ]] && continue
                        # shellcheck disable=SC2034  # consumed by the sourcing hook
                        GUARD_SCOPE_CLASSIFICATION=foreign
                        printf '%s' "$cleaned"
                        return 0
                    fi
                    ;;
            esac
        done
        has_walker=0
    done <<< "$segments"
    return 1
}

# Is an out-of-scope walker target $HOME itself, or something even broader?
#
# A read of one foreign path is a mis-scoped read; a walk rooted at $HOME is an
# environment probe, and it is the worse of the two by a wide margin. It treats
# every AGENTS.md and CLAUDE.md on the machine as a candidate instruction
# source -- including whatever last landed in ~/Downloads, which is precisely
# where untrusted files arrive. The contract's instructions= line already
# answers that question for the worktree, so this class earns a denial rather
# than the lesson guard_out_of_scope_target's caller emits for the rest.
#
# Ancestors of $HOME (/home, /) count too: sweeping them reaches $HOME on the
# way past.
guard_home_sweep_target() {
    local target home
    home=$(guard_scope_canonical "${HOME:-}") || return 1
    [[ -n $home && $home != / ]] || return 1
    target=$(guard_scope_canonical "$1") || return 1
    [[ -n $target ]] || return 1
    # Root is an ancestor of every absolute path, $HOME included, but the
    # ancestor test below is a component-boundary match against
    # "$target"/* -- and for target=/ that becomes //* (a doubled leading
    # slash), which $home (e.g. /home/adam) never matches. Root needs its
    # own disjunct rather than falling through the general ancestor check.
    [[ $target == "$home" || $target == / || $home == "$target"/* ]]
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
    local reader="$GUARD_LIB_DIR/../../skills/.shared/scripts/contract-read.sh"
    if [[ -n $root && $file == "$root/.agent/env-contract.txt" ]]; then
        [[ -x $reader ]] || return 1
        "$reader" --repo-root "$root" --check > /dev/null 2>&1
        return
    fi
    [[ -n $file && -r $file && -f $file && ! -L $file && -O $file ]] || return 1
    [[ -n $root ]] || return 0
    local rc=0
    git -C "$root" ls-files --error-unmatch -- "$file" > /dev/null 2>&1 || rc=$?
    # Lockstep with contract_is_ours in contract-read.sh: only status 1 proves
    # the path is untracked. Any other failure means git never established
    # provenance, so refuse rather than fail open.
    ((rc == 1))
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

# A dispatched worker's contract names the linked worktree it is allowed to
# edit.  The contract is accepted only when it is an untracked regular file
# owned by this user, and only when its worktree is the current Git root under
# the repository's conventional .worktrees/ directory.  This keeps a stale or
# repository-supplied declaration from becoming an escape hatch.
guard_worktree_contract() {
    local root=$1 contract worktree main_worktree rc
    GUARD_WORKTREE_CONTRACT_WORKTREE=''
    GUARD_WORKTREE_CONTRACT_REPO=''
    [[ -n $root && -d "$root/.agent" && ! -L "$root/.agent" ]] || return 1
    contract="$root/.agent/env-contract.txt"
    [[ -r $contract && -f $contract && ! -L $contract && -O $contract ]] || return 1
    rc=0
    git -C "$root" ls-files --error-unmatch -- .agent/env-contract.txt >/dev/null 2>&1 || rc=$?
    ((rc == 1)) || return 1
    worktree=$(sed -n 's/^worktree=//p' "$contract" 2> /dev/null | head -n 1)
    [[ -n $worktree && $worktree == /*/.worktrees/* ]] || return 1
    worktree=$(guard_scope_canonical "$worktree") || return 1
    [[ $worktree == "$root" ]] || return 1
    main_worktree=$(git -C "$root" worktree list --porcelain 2> /dev/null |
        sed -n 's/^worktree //p' | head -n 1) || return 1
    [[ -n $main_worktree ]] || return 1
    main_worktree=$(guard_scope_canonical "$main_worktree") || return 1
    [[ $worktree == "$main_worktree/.worktrees/"* ]] || return 1
    GUARD_WORKTREE_CONTRACT_WORKTREE=$worktree
    GUARD_WORKTREE_CONTRACT_REPO=$main_worktree
    return 0
}

# If a write target resolves into the main checkout while the session is
# contracted to a linked worktree, print a corrective denial reason.  Paths in a
# sibling worktree remain ordinary targets; only the root checkout itself is
# the silent-cross-write boundary this guard prevents.
guard_worktree_boundary_reason() {
    local target=$1 cwd=$2 command_line=${3:-} base candidate actual relative source
    local lexical_worker=no lexical_repo=no
    guard_worktree_contract "${workspace_root:-}" || return 1
    base=$(guard_command_target_dir "$cwd" "$command_line" "$target") || base=$cwd
    case $target in
        /*) candidate=$target;;
        *) candidate="$base/$target";;
    esac
    candidate=$(guard_scope_canonical "$candidate") || return 1

    # Resolve every candidate before classifying it. An alias outside both
    # checkout prefixes can still land in the main checkout, so lexical prefix
    # checks must never decide whether realpath resolution happens.
    case $candidate in
        "$GUARD_WORKTREE_CONTRACT_WORKTREE"|"$GUARD_WORKTREE_CONTRACT_WORKTREE"/*)
            lexical_worker=yes
            ;;
    esac
    if ! actual=$(guard_target_realpath "$candidate"); then
        [[ $lexical_worker == yes ]] || return 1
        GUARD_WORKTREE_BOUNDARY_CORRECTED=$GUARD_WORKTREE_CONTRACT_WORKTREE
        printf 'Refused once -- could not securely resolve write target %s while enforcing the contracted worktree %s. Use corrected path: %s. If this target is intentionally part of the task, make the same call again -- it will be allowed.' \
            "$candidate" "$GUARD_WORKTREE_CONTRACT_WORKTREE" \
            "$GUARD_WORKTREE_BOUNDARY_CORRECTED"
        return 0
    fi

    case $candidate in
        "$GUARD_WORKTREE_CONTRACT_REPO"|"$GUARD_WORKTREE_CONTRACT_REPO"/*)
            lexical_repo=yes
            ;;
    esac

    if guard_path_inside "$GUARD_WORKTREE_CONTRACT_WORKTREE" "$actual"; then
        return 1
    fi
    if [[ $lexical_worker == yes ]]; then
        GUARD_WORKTREE_BOUNDARY_CORRECTED=$GUARD_WORKTREE_CONTRACT_WORKTREE
        relative=${candidate#"$GUARD_WORKTREE_CONTRACT_WORKTREE"/}
        [[ $candidate == "$GUARD_WORKTREE_CONTRACT_WORKTREE" ]] && relative=''
        [[ -z $relative ]] || GUARD_WORKTREE_BOUNDARY_CORRECTED+="/$relative"
        printf 'Refused once -- write target %s resolves outside the contracted worktree %s. Use corrected path: %s. If this target is intentionally part of the task, make the same call again -- it will be allowed.' \
            "$candidate" "$GUARD_WORKTREE_CONTRACT_WORKTREE" \
            "$GUARD_WORKTREE_BOUNDARY_CORRECTED"
        return 0
    fi

    # A sibling linked worktree remains an ordinary target. A lexical root
    # target is retained as a denial even if a symlink happens to point at a
    # sibling; the worker contract cannot authorize that spelling.
    case $actual in
        "$GUARD_WORKTREE_CONTRACT_REPO/.worktrees"|\
        "$GUARD_WORKTREE_CONTRACT_REPO/.worktrees"/*)
            [[ $lexical_repo == yes ]] || return 1
            source=$candidate
            ;;
        "$GUARD_WORKTREE_CONTRACT_REPO"|"$GUARD_WORKTREE_CONTRACT_REPO"/*)
            source=$actual
            ;;
        *)
            [[ $lexical_repo == yes ]] || return 1
            source=$candidate
            ;;
    esac
    relative=${source#"$GUARD_WORKTREE_CONTRACT_REPO"/}
    [[ $source != "$GUARD_WORKTREE_CONTRACT_REPO" ]] || relative=''
    GUARD_WORKTREE_BOUNDARY_CORRECTED=$GUARD_WORKTREE_CONTRACT_WORKTREE
    [[ -z $relative ]] || GUARD_WORKTREE_BOUNDARY_CORRECTED+="/$relative"
    printf 'Refused once -- write target %s resolves inside the repository root %s but outside the contracted worktree %s. Use corrected path: %s. If this target is intentionally part of the task, make the same call again -- it will be allowed.' \
        "$source" "$GUARD_WORKTREE_CONTRACT_REPO" \
        "$GUARD_WORKTREE_CONTRACT_WORKTREE" "$GUARD_WORKTREE_BOUNDARY_CORRECTED"
}

# Persist one JSONL record for each content-bearing tool call that exposes a
# write target.  The raw command is retained for Bash calls because a target
# alone cannot distinguish a redirect, sed -i, tee, or an edit payload during
# post-hoc incident reconstruction.  Evidence is local .agent state, secured
# as a private file, and every failure is deliberately non-blocking: the hook
# must not turn an evidence filesystem hiccup into an invisible allow/deny loop.
guard_record_write_targets() {
    local root=$1 payload=$2 cwd=$3 command_line=$4 tool_name=$5 session=$6 tool_call_id=${7:-}
    local agent_dir evidence_dir evidence_file targets_json record timestamp
    local -a targets=()
    agent_dir="$root/.agent"
    [[ -n $root && -d $agent_dir && ! -L $agent_dir && -O $agent_dir ]] || return 0
    mapfile -t targets < <(
        guard_target_paths "$payload"
        [[ -z $command_line ]] || guard_shell_write_targets "$command_line"
    )
    ((${#targets[@]})) || return 0
    evidence_dir="$agent_dir/evidence"
    if [[ -e $evidence_dir || -L $evidence_dir ]]; then
        [[ -d $evidence_dir && ! -L $evidence_dir && -O $evidence_dir ]] || return 0
    else
        mkdir -- "$evidence_dir" 2> /dev/null || return 0
        [[ -d $evidence_dir && ! -L $evidence_dir && -O $evidence_dir ]] || return 0
    fi
    chmod 700 -- "$evidence_dir" 2> /dev/null || return 0
    evidence_file="$evidence_dir/paths-touched.ndjson"
    if [[ -e $evidence_file || -L $evidence_file ]]; then
        [[ -f $evidence_file && ! -L $evidence_file && -O $evidence_file ]] || return 0
    else
        touch -- "$evidence_file" 2> /dev/null || return 0
        [[ -f $evidence_file && ! -L $evidence_file && -O $evidence_file ]] || return 0
    fi
    chmod 600 -- "$evidence_file" 2> /dev/null || return 0
    targets_json=$(jq -nc '$ARGS.positional' --args "${targets[@]}" 2> /dev/null) || return 0
    timestamp=$(date +%s)
    record=$(jq -nc \
        --arg timestamp "$timestamp" --arg session "$session" \
        --arg tool "$tool_name" --arg call_id "$tool_call_id" --arg cwd "$cwd" \
        --arg command "$command_line" --argjson paths "$targets_json" \
        '{timestamp:($timestamp|tonumber),session:$session,tool:$tool,tool_call_id:$call_id,cwd:$cwd,command:$command,paths_touched:$paths}' \
        2> /dev/null) || return 0
    printf '%s\n' "$record" >>"$evidence_file" 2> /dev/null || true
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

# Record issue numbers independently from the once-per-rule lesson claim. A
# single body read is useful and should stay quiet; the first distinct second
# number is where the digest becomes the cheaper route. mkdir is the atomic
# state transition, so concurrent hook invocations cannot lose a number.
guard_issue_view_is_distinct() {
    local root=$1 session=$2 issue=$3 dir
    [[ -n $root && $issue =~ ^[0-9]+$ ]] || return 1

    session=${session//[^A-Za-z0-9._-]/_}
    dir="$root/.agent/cache/brief/${session:-nosession}/issue-views"
    # This feeds an advisory, so unrecordable state must SPEAK. Returning true
    # lets guard_should_advise emit the lesson while still persisting nothing.
    mkdir -p "$dir" 2> /dev/null || return 0
    # Record the issue marker BEFORE electing the quiet first view: the marker
    # mkdir is the atomic transition, so of two concurrent reads of one issue
    # exactly one records it and neither can masquerade as a distinct second
    # number. A marker that already exists is a re-read: quiet. Any other
    # marker failure is unrecordable state: fail open and speak.
    if ! mkdir "$dir/$issue" 2> /dev/null; then
        [[ -d "$dir/$issue" ]] && return 1
        return 0
    fi
    mkdir "$dir/first" 2> /dev/null && return 1
    return 0
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
        ".shared/scripts/onboard-refresh.sh|report onboarding drift without mutating config.env"
        ".shared/scripts/onboard-state.sh|report the next resumable onboarding stage and environment preflight"
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
# teach-after-the-fact for a reset --hard that already discarded the work, and
# a once-per-session override would refuse the first attempt and permit the
# second -- precisely backwards. So these deny every time, and say what to do
# instead.
#
# Kept deliberately short. A long list of "risky" commands trains an agent to
# treat denials as noise, which is how the one that mattered gets worked around.
# `git clean --force -d` and `git clean -fd` do identical damage, and only the
# second was refused. So did `git branch --delete --force main` and
# `rm --recursive --force /`. None of that is obfuscation -- it is git's own
# documented spelling, and an external review found all three by reading the
# man pages.
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

    # Intervening tokens are tolerated: after a substitution is flattened the
    # flag is no longer adjacent to the verb. Bounded by shell separators, so a
    # later unrelated command cannot be dragged into the match.
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

# Split shell command text at unquoted separators while dropping heredoc bodies.
# This is intentionally a small lexer, not a shell evaluator: the hook only
# needs command-position boundaries. Keeping quote and heredoc state prevents
# prose such as `echo "step 1; gh ..."` and body lines such as `gh ...` from
# becoming executable-looking segments.
guard_gh_command_segments() {
    local input=$1 line segment='' quote='' escaped=0 heredoc=''
    local i length char next third rest k delimiter delimiter_quote

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -n $heredoc ]]; then
            [[ $line == "$heredoc" ]] && heredoc=''
            continue
        fi

        i=0
        length=${#line}
        while ((i < length)); do
            char=${line:i:1}
            next=${line:i+1:1}
            third=${line:i+2:1}

            if [[ $quote == "'" ]]; then
                segment+=$char
                [[ $char == "'" ]] && quote=''
                ((i++))
                continue
            fi
            if ((escaped)); then
                segment+=$char
                escaped=0
                ((i++))
                continue
            fi
            if [[ $char == \\ ]]; then
                segment+=$char
                escaped=1
                ((i++))
                continue
            fi
            if [[ $quote == '"' ]]; then
                segment+=$char
                [[ $char == '"' ]] && quote=''
                ((i++))
                continue
            fi

            case $char in
                "'"|'"')
                    quote=$char
                    segment+=$char
                    ((i++))
                    ;;
                ';'|'|'|'&')
                    printf '%s\n' "$segment"
                    segment=''
                    ((i++))
                    ;;
                '<')
                    if [[ $next == '<' && $third != '<' ]]; then
                        segment+='<<'
                        i=$((i + 2))
                        rest=${line:i}
                        [[ ${rest:0:1} == '-' ]] && { rest=${rest:1}; }
                        rest="${rest#"${rest%%[![:space:]]*}"}"
                        delimiter_quote=${rest:0:1}
                        if [[ $delimiter_quote == "'" || $delimiter_quote == '"' ]]; then
                            rest=${rest:1}
                            k=0
                            while ((k < ${#rest})) && [[ ${rest:k:1} != "$delimiter_quote" ]]; do
                                ((k++))
                            done
                            delimiter=${rest:0:k}
                        else
                            delimiter=${rest%%[[:space:];|&]*}
                        fi
                        [[ -n $delimiter ]] && heredoc=$delimiter
                    else
                        segment+=$char
                        ((i++))
                    fi
                    ;;
                *)
                    segment+=$char
                    ((i++))
                    ;;
            esac
        done

        if [[ -z $heredoc && -z $quote ]]; then
            printf '%s\n' "$segment"
            segment=''
        else
            segment+=$'\n'
        fi
    done <<< "$input"
}

# Classify one gh body option. Output is `inline|VALUE`; file-backed and
# unrelated options return status 1. The caller owns advancing over a separate
# option value because it is also tokenising the command segment.
guard_gh_body_option() {
    local token=$1 value=${2-}
    case $token in
        --body|-b) printf 'inline|%s' "$value"; return 0;;
        -b?*) printf 'inline|%s' "${token#-b}"; return 0;;
        --body=*) printf 'inline|%s' "${token#--body=}"; return 0;;
        -f|--raw-field|--field)
            [[ $value == body=* ]] || return 1
            printf 'inline|%s' "${value#body=}"; return 0;;
        -fbody=*|--raw-field=body=*|--field=body=*)
            printf 'inline|%s' "${token#*=}"; return 0;;
        -F)
            [[ $value == body=* ]] || return 1
            value=${value#body=}
            [[ $value != @* ]] || return 1
            printf 'inline|%s' "$value"; return 0;;
        -Fbody=*)
            value=${token#*=}
            [[ $value != @* ]] || return 1
            printf 'inline|%s' "$value"; return 0;;
    esac
    return 1
}

# Inline bodies are easy to corrupt before gh receives them: shell quoting,
# command substitution, and a literal backslash-n all change the bytes the
# forge stores. Advise only the body-taking mutations, and only when gh is the
# command at the start of a shell segment. Text mentioning gh in grep, printf,
# or another quoted argument is data, not a command to inspect.
guard_gh_inline_body_reason() {
    local command_line=$1 segment trimmed token value operation comment=0
    local inline=0 literal_backslash_n=0 i j start option advice
    local -a words
    local segments
    segments=$(guard_gh_command_segments "$command_line")

    while IFS= read -r segment; do
        comment=0
        inline=0
        literal_backslash_n=0
        trimmed=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<< "$segment")
        [[ -n $trimmed ]] || continue
        read -r -a words <<< "$trimmed"
        ((${#words[@]})) || continue

        start=0
        while ((start < ${#words[@]})) &&
            [[ ${words[start]} =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; do
            ((start++))
        done
        if [[ ${words[start]-} == env ]]; then
            ((start++))
            while ((start < ${#words[@]})); do
                if [[ ${words[start]} == -i || ${words[start]} == --ignore-environment ]] ||
                    [[ ${words[start]} =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
                    ((start++))
                else
                    break
                fi
            done
        fi
        [[ ${words[start]-} == gh ]] || continue

        operation=''
        for ((i = start + 1; i < ${#words[@]}; i++)); do
            case ${words[i]} in
                pr|issue)
                    case ${words[i + 1]-} in
                        create|edit) operation=${words[i]};;
                        comment) operation=${words[i]}-comment; comment=1;;
                    esac
                    ;;
                api) operation=api;;
            esac
            [[ -n $operation ]] && break
        done
        [[ -n $operation ]] || continue

        for ((j = i + 1; j < ${#words[@]}; j++)); do
            token=${words[j]}
            value=${words[j + 1]-}
            case $token in
                --body|-b|-f|--raw-field|--field|-F) ((j++));;
            esac
            if option=$(guard_gh_body_option "$token" "$value"); then
                inline=1
                value=${option#*|}
                [[ $value == *'\n'* ]] && literal_backslash_n=1
            fi
        done

        ((inline)) || continue
        advice='Policy: keep gh mutation bodies file-backed. Use --body-file or --input; for gh api, use -F body=@file.'
        advice+=' For PR/issue create and edit, use the resolved gh-body.sh transport so the stored body is re-fetched and byte-verified.'
        if ((comment)); then
            advice+=' For comments, use gh-comment.sh --body-file so the helper preserves and verifies the exact bytes.'
        fi
        if ((literal_backslash_n)); then
            advice+=' A literal \n renders as backslash-n in the posted body; write the intended newline to a file instead.'
        fi
        printf '%s' "$advice"
        return 0
    done <<< "$segments"
    return 1
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
# Prints the matched pattern when a path is protected. Repository-declared
# entries are additive: a repo can extend the list, never shrink it, so a
# committed file cannot switch its own guard off.
guard_protected_match() {
    local candidate=$1 root=$2
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
            declared=$(IFS=,; printf '%s' "${extra[*]}")
        fi
    fi
    shared_protected_pattern "$candidate" "$root" "$declared"
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
        -e 's#([0-9]*>>?[[:space:]]*)"/dev/(null|stdout|stderr)"([[:space:];|&()<>]|$)#\1/dev/\2\3#g' \
        -e "s#([0-9]*>>?[[:space:]]*)'/dev/(null|stdout|stderr)'([[:space:];|&()<>]|$)#\\1/dev/\\2\\3#g" \
        -e 's#[0-9]*>>?[[:space:]]*/dev/(null|stdout|stderr)([[:space:];|&()<>]|$)#\2#g' \
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
        sed -E 's/[;|&()]+$//' |
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
