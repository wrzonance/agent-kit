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
  pinned=
  if [[ -n "$contract_root" && -r "$contract" && -f "$contract" &&
        ! -L "$contract" && -O "$contract" ]] &&
      ! git -C "$contract_root" ls-files --error-unmatch -- .agent/env-contract.txt \
          >/dev/null 2>&1; then
      pinned=$(sed -n "s/^skills= path=//p" "$contract" 2>/dev/null | head -n 1)
  fi
  if [[ -n "$pinned" && -d "$pinned" ]]; then
      agentkit="$pinned"
  fi
  if [[ -z "$agentkit" ]]; then
      agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" \
          "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" -maxdepth 4 \
          -type d -path "*/agentkit/*/skills" 2>/dev/null | sort -V | tail -1)
      [ -n "$agentkit" ] || agentkit="${CODEX_HOME:-$HOME/.codex}/skills"
  fi
  if [[ -n "$contract_root" && -n "$agentkit" &&
        ( -z "$pinned" || -d "$pinned" ) &&
        -x "$agentkit/.shared/scripts/contract-read.sh" ]]; then
      contract_skills=$("$agentkit/.shared/scripts/contract-read.sh" \
          --repo-root "$contract_root" --get skills.path 2>/dev/null)
      [[ -z "$contract_skills" || "$contract_skills" == "$agentkit" ]] || agentkit=
  fi'

# shellcheck disable=SC2034  # read by pre-tool-use.sh, which sources this file
readonly HELPERS='agent-run|worktree-commit|gh-pr-state|agent-preflight|repo-config|contract-read|triage-issues|move-github-project-item|gh-comment|gh-body'

# The per-call lessons point at the resolver instead of pasting RESOLVE_HINT:
# every lesson is paid in the agent's context for the rest of the session, and
# the full block is already there (SessionStart/SubagentStart curriculum).
# shellcheck disable=SC2016,SC2034  # literal text the agent reads; used by the sourcing hooks
readonly RESOLVE_POINTER='  agentkit=<the skills= path= value from your environment contract (session context, or the contract pasted in your worker prompt)>
  # the full guarded resolver (contract file, else the plugins/cache bootstrap) is the resolver block in your session or worker context'

# One sentence, six refusals: the sanctioned merge path.
readonly MERGE_RULE='The only sanctioned agent-driven merge path is merge-pr.sh (pr-to-green), bound to a confirmed --auto-merge authorization record and a gate=PASS review-completion result.'

GUARD_LIB_DIR=${BASH_SOURCE[0]%/*}
[[ $GUARD_LIB_DIR != "${BASH_SOURCE[0]}" ]] || GUARD_LIB_DIR=.
SHARED_SCRIPT_LIB=$(cd -- "$GUARD_LIB_DIR/../../skills/.shared/scripts/lib" 2>/dev/null && pwd -P) || {
    printf 'guard-lib.sh: shared script library is unavailable relative to %s\n' \
        "${BASH_SOURCE[0]}" >&2
    return 2
}
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SHARED_SCRIPT_LIB/protected-paths.sh"
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SHARED_SCRIPT_LIB/contract-cache.sh"

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

# Plugin-cache roots the RUNNING harness itself loaded into this session --
# Claude's and Codex's, since either variable may be unset while the other
# harness is the one actually running, and getting this wrong in either
# direction is cheap: a sibling harness's own plugin cache is still this
# machine's harness content, never arbitrary user data (issue #335 Case 2).
guard_harness_plugin_cache_roots() {
    local claude_root=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}
    local codex_root=${CODEX_HOME:-${HOME:-}/.codex}
    [[ -n $claude_root ]] && printf '%s\n' "$claude_root/plugins/cache"
    [[ -n $codex_root ]] && printf '%s\n' "$codex_root/plugins/cache"
}

# Is this path under a harness's own plugin-cache tree? A SKILL.md the running
# harness injected at SessionStart (e.g. superpowers) lives here -- reading it
# is expected, ordinary traffic, not an environment probe of foreign content.
guard_harness_path() {
    local candidate=$1 root
    [[ -n $candidate ]] || return 1
    candidate=$(guard_scope_canonical "$candidate") || return 1
    while IFS= read -r root; do
        [[ -n $root ]] || continue
        root=$(guard_scope_canonical "$root") || continue
        [[ $candidate == "$root" || $candidate == "$root"/* ]] && return 0
    done < <(guard_harness_plugin_cache_roots)
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
    elif guard_harness_path "$root"; then
        GUARD_TARGET_CLASSIFICATION=harness
    elif guard_fixture_path "$root"; then
        GUARD_TARGET_CLASSIFICATION=fixture
    else
        GUARD_TARGET_CLASSIFICATION=foreign
    fi
    printf '%s' "$GUARD_TARGET_CLASSIFICATION"
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

    # Walk segments in order via guard_gh_command_segments +
    # guard_tokenize_words (quote/heredoc aware); a target resolves against the
    # directory in force at its own segment. git -C counts only before the
    # subcommand (grep -C, commit -C are not directories) -- issue #335.
    local segments
    segments=$(guard_gh_command_segments "$command_line")
    while IFS= read -r segment; do
        trimmed=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<< "$segment")
        [[ -n $trimmed ]] || continue
        mapfile -t words < <(guard_tokenize_words "$trimmed")
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
        # A plugin-cache tree need not be a git checkout at all -- when the
        # repository-root lookup fails outright, the target may still be
        # harness content rather than genuinely unresolved.
        if guard_harness_path "$candidate"; then
            GUARD_TARGET_CLASSIFICATION=harness
        else
            GUARD_TARGET_CLASSIFICATION=unresolved
        fi
        printf '%s' "$GUARD_TARGET_CLASSIFICATION"
        return 0
    }
    GUARD_TARGET_ROOT=${resolved%%$'\n'*}
    candidate=${resolved#*$'\n'}
    if guard_harness_path "$candidate"; then
        GUARD_TARGET_CLASSIFICATION=harness
        printf '%s' "$GUARD_TARGET_CLASSIFICATION"
        return 0
    fi
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
    # A missing candidate is a normal outcome, not a failure: both hooks call
    # this under trap ERR, and a bare [[ -d ]] && cmd once returned 1, fired the
    # trap and skipped every guard (issue #369). The if keeps the status 0.
    if [[ -d $candidate ]]; then
        guard_add_root "$candidate"
    fi
    return 0
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
        contract=$(contract_cache_contract_file "$r")
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

# GNU grep bundles a value-taking short option with the rest of its token
# (-reTODO == -r -e TODO) or, when the bundle ends at the flag, with the next
# argv token (-re TODO). The first e/f in $1 (dash stripped) claims the value;
# returns 1 with no e/f, else 0 with GUARD_BUNDLE_NEXT_IS_VALUE=1/0 (next/attached).
guard_grep_bundle_pattern_flag() {
    local bundle=$1 before
    before=${bundle%%[ef]*}
    [[ $before == "$bundle" ]] && return 1
    GUARD_BUNDLE_NEXT_IS_VALUE=0
    [[ -z ${bundle:$((${#before} + 1))} ]] && GUARD_BUNDLE_NEXT_IS_VALUE=1
    return 0
}

# Return the first absolute/home-expanded path outside the allowed roots when
# a command segment is a walker/reader. Relative paths are intentionally left
# alone: the resolved repository/cwd contract answers those without guessing.
guard_out_of_scope_target() {
    local command_line=$1 segment verb token cleaned has_walker=0 expr_operand=0
    local pattern_pending=0 past_options=0
    local cwd=${2:-$PWD} command_root='' command_class='' command_dir=''
    local -a words
    # Segmented and tokenized as the shell parses (guard_gh_command_segments /
    # guard_tokenize_words): heredoc bodies are data and a quoted ;, |, or space
    # is not structure (issue #335 Case 3).
    local segments
    segments=$(guard_gh_command_segments "$command_line")
    # shellcheck disable=SC2034  # consumed by the sourcing PreToolUse hook
    GUARD_SCOPE_CLASSIFICATION=''
    command_root=$(guard_command_repository_root "$cwd" "$command_line" 2> /dev/null || true)
    if [[ -z $command_root ]]; then
        command_dir=$(guard_command_target_dir "$cwd" "$command_line" 2> /dev/null || true)
        if [[ -n $command_dir && $command_dir != "$(guard_scope_canonical "$cwd")" ]]; then
            command_root=$command_dir
            # A temporary non-git fixture, or a harness plugin-cache tree, is
            # still in-scope. Only an unambiguously foreign directory
            # receives the advisory.
            if guard_fixture_path "$command_dir"; then
                command_class=fixture
            elif guard_harness_path "$command_dir"; then
                command_class=harness
            else
                command_class=foreign
            fi
        fi
    fi

    while IFS= read -r segment; do
        [[ -n ${segment//[[:space:]]/} ]] || continue
        mapfile -t words < <(guard_tokenize_words "$segment")
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

        # Only the operand of sed -e/--expression and grep -e/--regexp is
        # excluded from path checking -- never every token with whitespace: a
        # quoted path with a space is exactly how a foreign path is passed
        # (issue #335 review F1).
        expr_operand=0 pattern_pending=0 past_options=0
        if [[ $verb == grep ]]; then
            # grep's FIRST positional operand is its PATTERN unless -e/--regexp
            # or -f/--file supplied one (2026-09-08: `grep -rl "$HOME" docs/` was
            # denied as a $HOME sweep). grep only: rg/fd have pattern-less modes
            # (rg --files DIR) whose first operand IS the walk root. A two-word
            # value flag (-A 3, --include GLOB) hands its value to this rule and
            # the real pattern is path-checked as before -- never less strictly.
            # A bundle carrying e/f counts too: -reTODO is grep's own -r -e TODO
            # (round 2: `grep -reTODO "$HOME"` bypassed the sweep denial).
            pattern_pending=1
            for token in "${words[@]:1}"; do
                # `--` ends option parsing: a later -e/--regexp is the positional
                # pattern, so stop here (round 3: `grep -r -- -e "$HOME"` walked $HOME).
                [[ $token == -- ]] && break
                case $token in
                    --regexp | --regexp=* | --file | --file=*) pattern_pending=0 ;;
                    -[A-Za-z]*)
                        guard_grep_bundle_pattern_flag "${token#-}" && pattern_pending=0
                        ;;
                esac
            done
        fi
        for token in "${words[@]:1}"; do
            if ((expr_operand)); then
                expr_operand=0
                continue
            fi
            case $verb in
                sed) case $token in -e | --expression) expr_operand=1; continue;; esac ;;
                grep)
                    if ((past_options == 0)) && [[ $token == -- ]]; then
                        past_options=1
                        continue
                    fi
                    # Flag/bundle parsing applies only before `--`; after it a token
                    # shaped like -e/-f/--regexp/--file is a positional operand (round 3).
                    if ((past_options == 0)); then
                        case $token in
                            --regexp | --file) expr_operand=1; continue;;
                            -[A-Za-z]*)
                                if guard_grep_bundle_pattern_flag "${token#-}"; then
                                    ((GUARD_BUNDLE_NEXT_IS_VALUE)) && expr_operand=1
                                    continue
                                fi
                                ;;
                        esac
                    fi
                    if ((pattern_pending)) && { ((past_options)) || [[ $token != -* ]]; }; then
                        pattern_pending=0
                        continue
                    fi
                    ;;
            esac
            # Trailing comma/paren trimming stays for the common prose-list
            # case ("see /a/b, /c)") -- unrelated to the expression-operand
            # exclusion above.
            cleaned=${token%,}; cleaned=${cleaned%)}
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
                        [[ $command_class == workspace || $command_class == harness ]] && continue
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

# Is an out-of-scope walker target $HOME itself or an ancestor (/home, /)? A
# $HOME sweep treats every AGENTS.md on the machine (~/Downloads included) as
# candidate instructions, so it earns a denial, not the lesson; sweeping an
# ancestor reaches $HOME on the way past.
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

# Is this cached contract OURS? It is read straight into model context, so a
# repository that merely TRACKS .agent/env-contract.txt could put text in an
# agent's head (rated critical by external review). Disqualified if tracked, a
# symlink, or owned by another user; rejecting costs one preflight.
guard_contract_is_ours() {
    local file=$1 root=${2:-}
    local reader="$GUARD_LIB_DIR/../../skills/.shared/scripts/contract-read.sh"
    if [[ -n $root ]]; then
        local write_target
        write_target=$(contract_cache_contract_write_target "$root" 2> /dev/null)
        if [[ -n $write_target && $file == "$write_target" ]]; then
            if [[ ! -e $file && ! -L $file ]]; then
                # Nothing exists at this harness's own canonical path yet
                # (issue #551): there is nothing another writer could have
                # planted there to have an opinion about, so a WRITER asking
                # "is it safe to create this" gets a plain yes. An EXISTING
                # file at this path still goes through the full provenance
                # check below.
                return 0
            fi
            [[ -x $reader ]] || return 1
            "$reader" --repo-root "$root" --check > /dev/null 2>&1
            return
        fi
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

# Print the trusted contract's instructions= line when it names any unresolved
# router references. Kept separate so one tool call validates and reads the
# contract once, regardless of how many shell tokens it carries.
guard_unresolved_instruction_line() {
    local root=$1 contract line unresolved
    [[ -n $root ]] || return 1
    contract=$(contract_cache_contract_file "$root")
    guard_contract_is_ours "$contract" "$root" || return 1
    line=$(grep -m1 '^instructions=.* unresolved=' -- "$contract" 2> /dev/null) || return 1
    unresolved=${line##* unresolved=}
    [[ -n $unresolved && $unresolved != none ]] || return 1
    printf '%s' "$line"
}

# True when TARGET is one of LINE's explicitly named unresolved references.
# The list is capped; a trailing +N-more marker is disclosure, not a path, and
# is stripped before exact matching.
guard_unresolved_instruction_target() {
    local root=$1 target=$2 base=${3:-$PWD} line=$4 unresolved ref
    local target_canonical ref_canonical
    [[ -n $root && -n $target && -n $line ]] || return 1
    unresolved=${line##* unresolved=}
    case $target in
        /*) target_canonical=$(guard_scope_canonical "$target") || return 1 ;;
        *) target_canonical=$(guard_scope_canonical "$base/$target") || return 1 ;;
    esac
    local IFS=,
    local -a refs
    read -r -a refs <<< "$unresolved"
    for ref in "${refs[@]}"; do
        ref=${ref%+[0-9]*-more}
        [[ -n $ref ]] || continue
        ref_canonical=$(guard_scope_canonical "$root/$ref") || continue
        if [[ $target_canonical == "$ref_canonical" ]]; then
            return 0
        fi
    done
    return 1
}

# Print the matching contract line when this tool call attempts to read an
# unresolved instruction path. File-path tools and ordinary shell readers are
# both covered; write/edit tools never enter this advisory path.
guard_unresolved_instruction_read() {
    local root=$1 input=$2 cwd=$3 command_line=$4 tool_name=$5
    local target segment verb token line positional current candidate
    local redirect_pending redirect_dest operand rg_files
    local -a words

    case $tool_name in
        Edit|Write|MultiEdit|NotebookEdit|apply_patch) return 1;;
    esac

    line=$(guard_unresolved_instruction_line "$root") || return 1

    target=$(jq -r '.tool_input.file_path // empty' <<< "$input" 2> /dev/null || true)
    if [[ -n $target ]] &&
        guard_unresolved_instruction_target "$root" "$target" "$cwd" "$line"; then
        printf '%s' "$line"
        return 0
    fi

    [[ -n $command_line ]] || return 1
    current=$(guard_scope_canonical "$cwd") || current=$cwd
    while IFS= read -r segment; do
        mapfile -t words < <(guard_tokenize_words "$segment")
        ((${#words[@]})) || continue
        verb=${words[0]#\(}
        if [[ $verb == cd && ${#words[@]} -ge 2 ]]; then
            candidate=$(guard_command_dir_candidate "$current" "${words[1]}") || candidate=''
            [[ -z $candidate ]] || current=$candidate
            continue
        fi
        case $verb in
            cat|sed|head|tail|less|more|rg|grep|wc) ;;
            *) continue;;
        esac
        positional=0
        redirect_pending=0
        rg_files=no
        if [[ $verb == rg ]]; then
            for token in "${words[@]:1}"; do
                [[ $token == --files ]] && rg_files=yes
            done
        fi
        for token in "${words[@]:1}"; do
            if ((redirect_pending)); then
                redirect_pending=0
                continue
            fi
            # Output redirects are write destinations. Preserve any operand
            # attached before the redirect (`cat file>sink`), but never offer
            # the destination itself to the unresolved-read matcher.
            operand=$token
            redirect_dest=''
            case $token in
                *'>>'*) operand=${token%%>>*}; redirect_dest=${token#*>>} ;;
                *'>'*) operand=${token%%>*}; redirect_dest=${token#*>} ;;
            esac
            if [[ $operand != "$token" ]]; then
                [[ -n $redirect_dest ]] || redirect_pending=1
                [[ $operand =~ ^[0-9]*$ ]] && operand=''
                token=$operand
            fi
            [[ -n $token && $token != -* ]] || continue
            # In conventional grep/rg form the first positional is a search
            # pattern, not a file operand. Matching its path-shaped text would
            # turn an unrelated search into a false unresolved-read advisory.
            if [[ $verb == grep || $verb == rg && $rg_files == no ]] &&
                ((positional++ == 0)); then
                continue
            fi
            if guard_unresolved_instruction_target "$root" "$token" "$current" "$line"; then
                printf '%s' "$line"
                return 0
            fi
        done
    done < <(guard_gh_command_segments "$command_line")
    return 1
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
    contract=$(contract_cache_contract_file "$root")
    [[ -r $contract && -f $contract && ! -L $contract && -O $contract ]] || return 1
    rc=0
    git -C "$root" ls-files --error-unmatch -- "${contract#"$root"/}" >/dev/null 2>&1 || rc=$?
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
        printf 'Refused once -- could not securely resolve write target %s while enforcing the contracted worktree %s. Use corrected path: %s. Retry the same call once to override.' \
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
        printf 'Refused once -- write target %s resolves outside the contracted worktree %s. Use corrected path: %s. Retry the same call once to override.' \
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
    printf 'Refused once -- write target %s resolves inside the repository root %s but outside the contracted worktree %s. Use corrected path: %s. Retry the same call once to override.' \
        "$source" "$GUARD_WORKTREE_CONTRACT_REPO" \
        "$GUARD_WORKTREE_CONTRACT_WORKTREE" "$GUARD_WORKTREE_BOUNDARY_CORRECTED"
}

# This harness's own mode= claim (issue #551): "observer" when SessionStart
# found another harness's contract fresh in this checkout and declined to
# compete with it, "owner" (the default, including when the line or the
# contract itself is absent -- every pre-#551 contract) otherwise. Reads only
# the CURRENT harness's own contract, never a foreign one -- an observer
# cannot be talked into believing it owns a checkout by a stale or hostile
# neighboring file.
guard_contract_mode() {
    local root=$1 contract mode
    [[ -n $root ]] || return 1
    contract=$(contract_cache_contract_file "$root")
    guard_contract_is_ours "$contract" "$root" || return 1
    mode=$(sed -n 's/^mode=\([^[:space:]]*\).*/\1/p' -- "$contract" 2> /dev/null | head -n 1)
    printf '%s' "${mode:-owner}"
}

# An observer session exists to watch a run already active under another
# harness, not to compete with it for the same files (issue #551 north star:
# "two harnesses on one machine must not fight"). A write that resolves into
# the checkout root this session started in is exactly that collision; a
# write into a linked worktree, /tmp, or any other repository remains
# ordinary and is never touched by this guard.
guard_observer_write_reason() {
    local target=$1 cwd=$2 command_line=${3:-} classification
    [[ -n ${workspace_root:-} ]] || return 1
    [[ $(guard_contract_mode "$workspace_root") == observer ]] || return 1
    classification=$(guard_classify_target "$target" "$cwd" "$command_line")
    [[ $classification == workspace ]] || return 1
    printf 'Refused once -- this session is an OBSERVER: another harness holds an active run in %s (this contract records mode=observer), so a write here would race it. If that run has ended, remove %s/.agent/env-contract.*.txt and start a fresh session -- or run the same call again now; it is allowed once.' \
        "$workspace_root" "$workspace_root"
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

# Claim "this lesson, this session" exactly once: 0 claimed now, 1 already
# claimed, 2 cannot record. mkdir is atomic (two calls in one turn cannot both
# claim). Three-way because advisories and denials treat the unwritable case in
# OPPOSITE directions -- see the two wrappers below.
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

# The tooling contract: what exists here and the one question each answers. Only
# helpers that resolve ON DISK are named (a curriculum naming a missing script
# teaches a broken path); one line each, since it competes with the contract for
# attention.
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
        # Not a script: the manifest of every companion reference that ships,
        # with its openable path and purpose. Named here because the
        # references themselves live under .shared/ and <skill>/references/,
        # which default enumeration hides -- an agent told only that they
        # exist searches for them.
        "references.md|every reference file that ships, with its path and purpose -- read it instead of searching"
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

# Work-destroying commands: the ONE place a hard, repeatable denial is right (no
# teach-after-the-fact for a reset --hard; a once-per-session override would be
# backwards). Kept short so denials stay signal. Long spellings (--force,
# --recursive, --delete) are normalised first so each rule states its intent
# once -- an external review found the misses by reading the man pages.
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

# Walks a tokenized word array (named by $1, from index $2) past leading
# NAME=value assignments and execution wrappers (env, sudo/doas,
# command/nohup/setsid/exec/time, timeout, nice/ionice, stdbuf, xargs) to the
# real command word. Shared by guard_heredoc_consumer_is_shell and
# guard_gh_api_merge_mutation_reason (issue #404 follow-up). Prints the resolved
# index; an index past the array means the walk ran out mid-wrapper -- the
# caller decides (consumer: treat as shell; gh api: no match).
guard_skip_command_prefix() {
    local -n __gscp_words=$1
    local i=${2:-0} word wrapper n=${#__gscp_words[@]}
    while ((i < n)) && [[ ${__gscp_words[i]} =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; do
        ((i++))
    done
    word=${__gscp_words[i]-}

    while [[ -n $word ]]; do
        wrapper=${word##*/}
        case $wrapper in
            env)
                ((i++))
                while ((i < n)); do
                    case ${__gscp_words[i]} in
                        -*|*=*) ((i++));;
                        *) break;;
                    esac
                done
                ;;
            sudo|doas)
                ((i++))
                while ((i < n)) && [[ ${__gscp_words[i]} == -* ]]; do
                    case ${__gscp_words[i]} in
                        -u|-g|-p|-r|-t|-C|-h|--user|--group|--prompt|--role|--type|--close-from|--host)
                            ((i += 2));;
                        *) ((i++));;
                    esac
                done
                ;;
            command|nohup|setsid|exec|time)
                ((i++))
                while ((i < n)) && [[ ${__gscp_words[i]} == -* ]]; do
                    ((i++))
                done
                ;;
            timeout)
                ((i++))
                while ((i < n)) && [[ ${__gscp_words[i]} == -* ]]; do
                    case ${__gscp_words[i]} in
                        -s|-k|--signal|--kill-after)
                            ((i += 2));;
                        *) ((i++));;
                    esac
                done
                # The DURATION is a required positional argument.
                ((i++))
                ;;
            nice|ionice)
                ((i++))
                while ((i < n)) && [[ ${__gscp_words[i]} == -* ]]; do
                    case ${__gscp_words[i]} in
                        -n|-c|-p|--adjustment)
                            ((i += 2));;
                        *) ((i++));;
                    esac
                done
                ;;
            stdbuf)
                ((i++))
                while ((i < n)) && [[ ${__gscp_words[i]} == -* ]]; do
                    case ${__gscp_words[i]} in
                        -i|-o|-e)
                            # Bare flag (no attached value, e.g. `-o` not
                            # `-oL`) takes the next token as its value.
                            ((i += 2));;
                        *) ((i++));;
                    esac
                done
                ;;
            xargs)
                ((i++))
                while ((i < n)) && [[ ${__gscp_words[i]} == -* ]]; do
                    case ${__gscp_words[i]} in
                        -I|-L|-n|-P|-s|-d|-E|--replace|--max-lines|--max-args|--max-procs|--max-chars|--delimiter|--eof)
                            ((i += 2));;
                        *) ((i++));;
                    esac
                done
                ;;
            *)
                break
                ;;
        esac
        word=${__gscp_words[i]-}
    done
    printf '%s' "$i"
}

# Is the heredoc consumer a shell interpreter? Then its BODY runs as a script
# regardless of delimiter quoting. Running out of tokens mid-wrapper returns 0
# (treat as shell): a false positive costs a refusal, a false negative lets a
# destructive body through.
guard_heredoc_consumer_is_shell() {
    local owner=$1 i word
    local -a words
    mapfile -t words < <(guard_tokenize_words "$owner")
    i=$(guard_skip_command_prefix words 0)
    word=${words[i]-}

    # Ran out of tokens mid-wrapper (e.g. `sudo -u` with nothing after): the
    # real interpreter could not be confidently resolved. Treat as a shell.
    ((i >= ${#words[@]} && ${#words[@]} > 0)) && [[ -z $word ]] && return 0

    case ${word##*/} in
        bash|sh|zsh|dash|ksh|ash|mksh) return 0;;
    esac
    return 1
}

# Every $(...) / `...` command substitution inside a heredoc BODY, inner text
# only. An UNQUOTED delimiter (`<<EOF`, no quotes and no leading backslash)
# means the shell expands these while it BUILDS the heredoc, before the
# consumer ever reads it -- `cat <<EOF` with a `$(rm -rf ~)` inside deletes
# regardless of `cat` being perfectly inert. Depth-counted so a nested
# `$(echo $(pwd))` extracts the whole outer call, not the first `)`.
guard_heredoc_substitutions() {
    local body=$1
    local i=0 length=${#body} depth start inner
    while ((i < length)); do
        if [[ ${body:i:1} == '$' && ${body:i+1:1} == '(' ]]; then
            depth=1
            start=$((i + 2))
            i=$start
            while ((i < length && depth > 0)); do
                case ${body:i:1} in
                    '(') ((depth++));;
                    ')') ((depth--));;
                esac
                ((i++))
            done
            inner=${body:start:i-start-1}
            [[ -n $inner ]] && printf '%s\n' "$inner"
            continue
        fi
        if [[ ${body:i:1} == '`' ]]; then
            start=$((i + 1))
            i=$start
            # Backticks do not nest the way $( ) does: the first UNESCAPED
            # backtick closes the span. A literal backtick inside one is
            # written `\`` -- the backslash is consumed and does not end the
            # scan, matching how the shell itself reads a backtick span.
            while ((i < length)); do
                if [[ ${body:i:1} == \\ ]]; then
                    i=$((i + 2))
                    continue
                fi
                [[ ${body:i:1} == '`' ]] && break
                ((i++))
            done
            inner=${body:start:i-start}
            ((i++))
            [[ -n $inner ]] && printf '%s\n' "$inner"
            continue
        fi
        ((i++))
    done
}

# Replace the CONTENT of every unescaped single-quoted span in $1 with # filler,
# length-preserving, everything else verbatim -- so a $(/backtick inside single
# quotes (never expanded) cannot be mistaken for a live substitution. Same quote
# state machine as guard_tokenize_words.
guard_mask_single_quotes() {
    local input=$1 out='' quote='' escaped=0 char i length
    length=${#input}
    for ((i = 0; i < length; i++)); do
        char=${input:i:1}
        if [[ $quote == "'" ]]; then
            if [[ $char == "'" ]]; then
                quote=''
                out+=$char
            else
                out+='#'
            fi
            continue
        fi
        if ((escaped)); then
            out+=$char
            escaped=0
            continue
        fi
        if [[ $char == \\ ]]; then
            out+=$char
            escaped=1
            continue
        fi
        if [[ $quote == '"' ]]; then
            out+=$char
            [[ $char == '"' ]] && quote=''
            continue
        fi
        case $char in
            "'" | '"') quote=$char; out+=$char ;;
            *) out+=$char ;;
        esac
    done
    printf '%s' "$out"
}

# Every $(...)/backtick substitution a SEGMENT will actually evaluate, including
# inside an outer double-quoted argument; single-quoted text is inert and
# skipped by walking a masked copy while slicing payloads from the unmasked
# original (issue #397 follow-up).
guard_segment_substitutions() {
    local original=$1 masked
    masked=$(guard_mask_single_quotes "$original")
    local i=0 length=${#masked} depth start inner
    while ((i < length)); do
        if [[ ${masked:i:1} == '$' && ${masked:i+1:1} == '(' ]]; then
            depth=1
            start=$((i + 2))
            i=$start
            while ((i < length && depth > 0)); do
                case ${masked:i:1} in
                    '(') ((depth++));;
                    ')') ((depth--));;
                esac
                ((i++))
            done
            inner=${original:start:i-start-1}
            [[ -n $inner ]] && printf '%s\n' "$inner"
            continue
        fi
        if [[ ${masked:i:1} == '`' ]]; then
            start=$((i + 1))
            i=$start
            while ((i < length)); do
                if [[ ${masked:i:1} == \\ ]]; then
                    i=$((i + 2))
                    continue
                fi
                [[ ${masked:i:1} == '`' ]] && break
                ((i++))
            done
            inner=${original:start:i-start}
            ((i++))
            [[ -n $inner ]] && printf '%s\n' "$inner"
            continue
        fi
        ((i++))
    done
}

# Like guard_gh_command_segments, but a heredoc BODY is dropped only when inert:
# a quoted-delimiter body to a data sink stays dropped (issue #351); an UNQUOTED
# body's substitutions and any body handed to a shell are recovered and
# recursively re-segmented (issue #364).
guard_destructive_command_segments() {
    local input=$1 line segment='' quote='' escaped=0 heredoc='' heredoc_tabstrip=0
    local i length char next third rest k delimiter delimiter_quote terminator_line
    local owner='' heredoc_no_expand=0 body='' bodyline sub recovered

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -n $heredoc ]]; then
            terminator_line=$line
            if ((heredoc_tabstrip)); then
                terminator_line=${terminator_line#"${terminator_line%%[!$'\t']*}"}
            fi
            if [[ $terminator_line == "$heredoc" ]]; then
                heredoc=''
                heredoc_tabstrip=0
                if ((heredoc_no_expand)) && ! guard_heredoc_consumer_is_shell "$owner"; then
                    body=''
                elif guard_heredoc_consumer_is_shell "$owner"; then
                    while IFS= read -r recovered; do
                        [[ -n $recovered ]] && printf '%s\n' "$recovered"
                    done < <(guard_destructive_command_segments "$body")
                    body=''
                else
                    while IFS= read -r sub; do
                        while IFS= read -r recovered; do
                            [[ -n $recovered ]] && printf '%s\n' "$recovered"
                        done < <(guard_destructive_command_segments "$sub")
                    done < <(guard_heredoc_substitutions "$body")
                    body=''
                fi
                owner=''
                # Flush the owner line (through the heredoc opener) as its own
                # segment now, or the next command merges into it and the
                # one-segment-per-command contract breaks.
                if [[ -n $segment ]]; then
                    printf '%s\n' "${segment%$'\n'}"
                    segment=''
                fi
                continue
            fi
            bodyline=$line
            if ((heredoc_tabstrip)); then
                bodyline=${bodyline#"${bodyline%%[!$'\t']*}"}
            fi
            body+="$bodyline"$'\n'
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
                        owner=$segment
                        segment+='<<'
                        i=$((i + 2))
                        rest=${line:i}
                        heredoc_tabstrip=0
                        [[ ${rest:0:1} == '-' ]] && { rest=${rest:1}; heredoc_tabstrip=1; }
                        rest="${rest#"${rest%%[![:space:]]*}"}"
                        delimiter_quote=${rest:0:1}
                        if [[ $delimiter_quote == "'" || $delimiter_quote == '"' ]]; then
                            rest=${rest:1}
                            k=0
                            while ((k < ${#rest})) && [[ ${rest:k:1} != "$delimiter_quote" ]]; do
                                ((k++))
                            done
                            delimiter=${rest:0:k}
                            heredoc_no_expand=1
                        else
                            delimiter=${rest%%[[:space:];|&]*}
                            # An unquoted delimiter such as `<<\EOF` disables
                            # heredoc-body expansion the same way a quoted one
                            # does; bash strips the backslash for the purpose
                            # of matching the terminator, so the stored
                            # delimiter must too, or the real terminator line
                            # (bare "EOF") never matches "\EOF".
                            heredoc_no_expand=0
                            [[ $delimiter_quote == \\ ]] && heredoc_no_expand=1
                            delimiter=${delimiter//\\/}
                        fi
                        [[ -n $delimiter ]] && heredoc=$delimiter
                        body=''
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

# Judges each executed segment on its own tokens
# (guard_destructive_command_segments): matching the whole raw text let a quoted
# example in an inert heredoc, or a -f from an unrelated segment, manufacture a
# match (issue #351); non-inert bodies are still recovered and judged (issue
# #364).
guard_destructive_reason() {
    local command_line=$1 cwd=${2:-} segments segment trimmed reason
    local -a lines=()

    segments=$(guard_destructive_command_segments "$command_line")
    while IFS= read -r segment; do
        trimmed=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<< "$segment")
        [[ -n $trimmed ]] || continue
        lines+=("$trimmed")
    done <<< "$segments"

    for segment in "${lines[@]}"; do
        if reason=$(guard_destructive_segment_reason "$segment" "$cwd"); then
            # Name the offending line once more than one command shares this
            # payload, so a multi-line script is not refused wholesale over a
            # single dangerous line -- the agent can see which one to redo.
            # The hook-skipping flag has one deliberately terse diagnostic.
            # In particular, a sanctioned bash recipe is often multi-line;
            # appending the offending heredoc line or substitution framing
            # blames the recipe shape instead of naming the policy.
            if [[ $reason == 'Refused the hook-skipping flag; drop it.' ]]; then
                printf '%s' "$reason"
            elif ((${#lines[@]} > 1)); then
                printf '%s (the offending line is: %s)' "$reason" "$segment"
            else
                printf '%s' "$reason"
            fi
            return 0
        fi
    done
    return 1
}

# Is $2.. present as a contiguous, EXACT-token sequence anywhere in the word
# array named by $1 (produced by guard_tokenize_words, so a quoted argument is
# already one word)? Word-array equality, never substring -- so `gh pr merge`
# spelled out inside a single quoted data argument (a sed replacement script,
# a printf payload destined for a file) can never match: quoting collapses it
# into ONE word here, not three separate command tokens (issue #397).
guard_words_contain_sequence() {
    local -n __gwcs_words=$1
    shift
    local -a want=("$@")
    local n=${#want[@]} i j matched
    ((n)) || return 1
    for ((i = 0; i + n <= ${#__gwcs_words[@]}; i++)); do
        matched=1
        for ((j = 0; j < n; j++)); do
            [[ ${__gwcs_words[i + j]} == "${want[j]}" ]] || { matched=0; break; }
        done
        ((matched)) && return 0
    done
    return 1
}

# Is a git config word array SETTING an execution key (core.hooksPath,
# core.fsmonitor, core.sshCommand, filter.*.clean/smudge/process,
# diff.*.textconv -- formerly matched with a grep -E pattern spelling the key as
# core\.hooksPath, etc.)? Prints the key; a --get* READ never counts (issue #397
# false positive #3); token equality, never substring.
guard_git_config_write_key() {
    local -n __ggcw_words=$1
    local i n=${#__ggcw_words[@]} word key='' is_read=0 saw_git=0 saw_config=0
    for ((i = 0; i < n; i++)); do
        word=${__ggcw_words[i]}
        if ((!saw_git)); then
            [[ $word == git ]] && saw_git=1
            continue
        fi
        if ((!saw_config)); then
            [[ $word == config ]] && saw_config=1
            continue
        fi
        case $word in
            --get | --get-all | --get-regexp | --get-urlmatch) is_read=1 ;;
            core.hooksPath | core.fsmonitor | core.sshCommand | \
            filter.*.clean | filter.*.smudge | filter.*.process | diff.*.textconv)
                key=$word ;;
        esac
    done
    ((saw_git && saw_config)) || return 1
    [[ -n $key && $is_read -eq 0 ]] || return 1
    printf '%s' "$key"
}

# The same execution keys passed as -c KEY=VALUE, -cKEY=VALUE, or
# --config-env=KEY=... on the UNSTRIPPED word array (guard_strip_git_globals
# removes the pair before the stripped array exists -- PR #414 review, issue
# #397 F1). Keep the key set in lockstep with guard_git_config_write_key.
guard_git_dash_c_write_key() {
    local -n __ggdc_words=$1
    local i n=${#__ggdc_words[@]} word next key='' saw_git=0
    for ((i = 0; i < n; i++)); do
        word=${__ggdc_words[i]}
        if ((!saw_git)); then
            [[ $word == git ]] && saw_git=1
            continue
        fi
        case $word in
            -c)
                ((i + 1 < n)) || continue
                next=${__ggdc_words[i + 1]}
                ;;
            -c?*) next=${word#-c} ;;
            --config-env=*) next=${word#--config-env=} ;;
            *) continue ;;
        esac
        [[ $next == *=* ]] || continue
        case ${next%%=*} in
            core.hooksPath | core.fsmonitor | core.sshCommand | \
            filter.*.clean | filter.*.smudge | filter.*.process | diff.*.textconv)
                key=${next%%=*} ;;
        esac
    done
    ((saw_git)) || return 1
    [[ -n $key ]] || return 1
    printf '%s' "$key"
}

# Does a `gh api` flag (exact token, no attached `=value` or short form) take
# a SEPARATE next argument as its value? Used only to walk past that value
# when hunting for the endpoint positional below -- an attached `--flag=value`
# or short `-Fvalue` token already carries its value in the same word, so it
# is never in this list. `--cache` was the CodeRabbit-reported gap on PR #415:
# without it, `gh api --cache 1h -X PUT .../merge` misread `1h` as the
# endpoint positional and the merge went unrecognised.
guard_gh_api_value_flag() {
    case $1 in
        -X | --method | -F | --field | -H | --header | --hostname | \
        --input | -q | --jq | -p | --preview | -f | --raw-field | -t | --template | \
        --cache)
            return 0 ;;
    esac
    return 1
}

# Judges a gh api graphql --input PATH body (PR #415 review): fails CLOSED
# unless PATH is a readable regular file inside cwd's own repository, lexically
# and after symlink resolution; then a literal mergePullRequest denies.
guard_gh_api_graphql_input_reason() {
    local input_path=$1 cwd=$2 reason_tail
    reason_tail=" Pass the mutation inline via -f query=... instead so this guard can read it. $MERGE_RULE"

    if [[ -z $input_path || $input_path == '-' || -z $cwd ]]; then
        printf 'a GraphQL mutation body supplied via --input (stdin, unnamed, or with no working directory to resolve it against) cannot be inspected for a mergePullRequest mutation, so it is refused rather than assumed safe.%s' \
            "$reason_tail"
        return 0
    fi

    local path_result rc=0 lexical_root lexical_candidate cwd_root real_candidate
    path_result=$(guard_target_path "$input_path" "$cwd" 2> /dev/null) || rc=$?
    if ((rc != 0)); then
        printf 'a GraphQL mutation body supplied via --input %s could not be resolved to a path inside a repository, so it is refused rather than assumed safe.%s' \
            "$input_path" "$reason_tail"
        return 0
    fi
    lexical_root=${path_result%%$'\n'*}
    lexical_candidate=${path_result#*$'\n'}
    cwd_root=$(git -C "$cwd" rev-parse --show-toplevel 2> /dev/null)
    if [[ -z $cwd_root || $lexical_root != "$cwd_root" ]]; then
        printf 'a GraphQL mutation body supplied via --input %s resolves outside this repository, so it is refused rather than assumed safe.%s' \
            "$input_path" "$reason_tail"
        return 0
    fi

    if ! real_candidate=$(guard_target_realpath "$lexical_candidate" 2> /dev/null); then
        printf 'a GraphQL mutation body supplied via --input %s could not be read, so it is refused rather than assumed safe.%s' \
            "$input_path" "$reason_tail"
        return 0
    fi
    if ! guard_path_inside "$cwd_root" "$real_candidate"; then
        printf 'a GraphQL mutation body supplied via --input %s resolves outside this repository, so it is refused rather than assumed safe.%s' \
            "$input_path" "$reason_tail"
        return 0
    fi
    if [[ ! -f $real_candidate || ! -r $real_candidate ]]; then
        printf 'a GraphQL mutation body supplied via --input %s is not a readable regular file, so it is refused rather than assumed safe.%s' \
            "$input_path" "$reason_tail"
        return 0
    fi

    if grep -qF -- 'mergePullRequest' "$real_candidate" 2> /dev/null; then
        printf 'merging a pull request through a GraphQL mergePullRequest mutation supplied via --input %s is the same decision as gh pr merge, reached a different way. %s' \
            "$input_path" "$MERGE_RULE"
        return 0
    fi
    return 1
}

# Is a gh api word array the REST/GraphQL pull-request MERGE that gh pr merge
# reaches (issue #404 follow-up)? Exact tokens (a quoted data argument is one
# word); the command word is found via guard_skip_command_prefix so GH_TOKEN=x
# gh api / env gh api cannot slip past (PR #415). merge-pr.sh's own call runs in
# its subprocess and is never seen here; $2 (cwd) serves only the graphql
# --input case.
guard_gh_api_merge_mutation_reason() {
    local -n __ggamr_words=$1
    local cwd=${2:-}
    local n=${#__ggamr_words[@]}
    local start
    start=$(guard_skip_command_prefix "$1" 0)
    ((start + 1 < n)) || return 1
    [[ ${__ggamr_words[start]} == gh && ${__ggamr_words[start + 1]} == api ]] || return 1

    local i word next method='GET' endpoint=''
    local -a positionals=()
    for ((i = start + 2; i < n; i++)); do
        word=${__ggamr_words[i]}
        case $word in
            -X | --method)
                if ((i + 1 < n)); then
                    method=${__ggamr_words[i + 1]}
                    ((i++))
                fi
                continue ;;
            -X?*) method=${word#-X}; continue ;;
            --method=*) method=${word#--method=}; continue ;;
        esac
        if [[ $word == -* ]]; then
            guard_gh_api_value_flag "$word" && ((i++))
            continue
        fi
        positionals+=("$word")
    done
    endpoint=${positionals[0]-}

    # REST: PUT .../pulls/N/merge -- with or without a leading slash or the
    # full api.github.com host, OWNER/REPO restricted to the character set a
    # repo slug actually allows.
    if [[ ${method^^} == PUT ]] &&
        [[ $endpoint =~ ^(https://api\.github\.com/)?/?repos/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pulls/[0-9]+/merge$ ]]; then
        printf 'merging a pull request through the REST API directly is the same decision as gh pr merge, reached a different way. %s' "$MERGE_RULE"
        return 0
    fi

    # GraphQL: the endpoint literal is "graphql"; the mutation NAME is data
    # carried in a -f/-F/--raw-field/--field VALUE token -- the payload gh
    # actually sends -- never the raw command text, so this cannot match a
    # mention of the same word inside an argument that is not one of those
    # value tokens. `--input`/`--input=` instead names a FILE carrying the
    # body -- guard_gh_api_graphql_input_reason judges that shape.
    if [[ $endpoint == graphql ]]; then
        local input_path='' had_input=0 graphql_input_reason
        for ((i = start + 2; i < n; i++)); do
            word=${__ggamr_words[i]}
            case $word in
                -f | -F | --raw-field | --field)
                    next=${__ggamr_words[i + 1]-}
                    if [[ $next == *mergePullRequest* ]]; then
                        printf 'merging a pull request through a GraphQL mergePullRequest mutation is the same decision as gh pr merge, reached a different way. %s' "$MERGE_RULE"
                        return 0
                    fi
                    ;;
                -f*=*mergePullRequest* | -F*=*mergePullRequest* | \
                --raw-field=*mergePullRequest* | --field=*mergePullRequest*)
                    printf 'merging a pull request through a GraphQL mergePullRequest mutation is the same decision as gh pr merge, reached a different way. %s' "$MERGE_RULE"
                    return 0
                    ;;
                --input)
                    had_input=1
                    input_path=${__ggamr_words[i + 1]-}
                    ;;
                --input=*)
                    had_input=1
                    input_path=${word#--input=}
                    ;;
            esac
        done
        if ((had_input)) &&
            graphql_input_reason=$(guard_gh_api_graphql_input_reason "$input_path" "$cwd"); then
            printf '%s' "$graphql_input_reason"
            return 0
        fi
    fi

    return 1
}

guard_destructive_segment_reason() {
    local cmd=$1 cwd=${2:-} stripped flattened normalized

    # Flatten substitution markers and re-test so git push $(echo --force)
    # cannot hide a flag; git push origin $(git branch --show-current) flattens
    # to harmless words and survives. Guards a shortcut, not an adversary.
    flattened=${cmd//\$(/ }
    flattened=${flattened//[\`)]/ }
    if [[ $flattened != "$cmd" ]]; then
        local hidden
        if hidden=$(guard_destructive_segment_reason "$flattened" "$cwd"); then
            if [[ $hidden == 'Refused the hook-skipping flag; drop it.' ]]; then
                printf '%s' "$hidden"
            else
                printf '%s (the command hides that flag inside a substitution; write it literally if you mean it)' "$hidden"
            fi
            return 0
        fi
    fi

    # A $(...)/backtick inside an outer DOUBLE-quoted argument still executes;
    # guard_segment_substitutions (single-quote aware) extracts every payload
    # for the FULL check (issue #397 follow-up).
    local payload payload_reason
    while IFS= read -r payload; do
        [[ -n $payload ]] || continue
        if payload_reason=$(guard_destructive_segment_reason "$payload" "$cwd"); then
            if [[ $payload_reason == 'Refused the hook-skipping flag; drop it.' ]]; then
                printf '%s' "$payload_reason"
            else
                printf '%s (the command hides that inside a "$(...)"/`...` substitution; write it literally if you mean it)' "$payload_reason"
            fi
            return 0
        fi
    done < <(guard_segment_substitutions "$cmd")

    stripped=$(guard_strip_git_globals "$cmd")
    normalized=$(guard_normalize_flags "$stripped")
    # Quote-aware tokenization of this ONE segment -- a quoted argument (a sed
    # script, a printf payload) collapses to a single word here, so the
    # verb-position checks below can never fire on bytes inside quoted data
    # (issue #397).
    local -a words
    mapfile -t words < <(guard_tokenize_words "$stripped")
    # The UNSTRIPPED word array -- guard_strip_git_globals removes every
    # `-c KEY=VALUE` pair before `words` above ever sees it, so
    # guard_git_dash_c_write_key (which needs that pair intact) works from
    # this array instead (issue #397 follow-up F1).
    local -a raw_words
    # shellcheck disable=SC2034  # consumed by name via the
    # guard_git_dash_c_write_key nameref below, never as ${raw_words[@]} here.
    mapfile -t raw_words < <(guard_tokenize_words "$cmd")

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
    # An execution key in git config runs a command during ordinary git
    # operations, persistently (git config KEY) or for one call (-c KEY=VALUE,
    # --config-env=); token-matched, never substring (issue #397 + follow-up
    # F1).
    local config_key
    if config_key=$(guard_git_config_write_key words) ||
        config_key=$(guard_git_dash_c_write_key raw_words); then
        printf 'that git config key (%s) executes a command during git operations. Setting it is a decision for the user.' \
            "$config_key"
        return 0
    fi
    # Exact token sequence, not substring (issue #397). The one rule (issue
    # #404): an agent merge is sanctioned only through merge-pr.sh; the
    # porcelain is refused unconditionally, and
    # guard_gh_api_merge_mutation_reason below refuses the REST/GraphQL
    # spellings for the same reason. merge-pr.sh's own gh api call is a command
    # line this hook never sees.
    if guard_words_contain_sequence words gh pr merge; then
        printf 'merging a pull request is the user decision, not the agent one. Report that the PR is ready instead. %s This gh pr merge porcelain form stays refused even under that authorization.' "$MERGE_RULE"
        return 0
    fi
    local api_merge_reason
    if api_merge_reason=$(guard_gh_api_merge_mutation_reason words "$cwd"); then
        printf '%s' "$api_merge_reason"
        return 0
    fi
    # Match the flag as a shell token, not as a substring of a quoted prose
    # argument. Quoted data remains one word in `words`, while an executed
    # recipe's command body is tokenized on its recursive check above.
    if guard_words_contain_sequence words --no-verify; then
        printf '%s' 'Refused the hook-skipping flag; drop it.'
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
    local input=$1 line segment='' quote='' escaped=0 heredoc='' heredoc_tabstrip=0
    local i length char next third rest k delimiter delimiter_quote terminator_line

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -n $heredoc ]]; then
            terminator_line=$line
            # `<<-` permits the TERMINATOR to be tab-indented too, not only the
            # heredoc body -- bash strips leading tabs from every line of a
            # `<<-` heredoc, including the closing delimiter line. Comparing
            # the raw line left a tab-indented terminator never matching, so
            # the heredoc (and every command segment after it) was silently
            # swallowed -- the guard failing open rather than closed.
            if ((heredoc_tabstrip)); then
                terminator_line=${terminator_line#"${terminator_line%%[!$'\t']*}"}
            fi
            [[ $terminator_line == "$heredoc" ]] && { heredoc=''; heredoc_tabstrip=0; }
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
                        heredoc_tabstrip=0
                        [[ ${rest:0:1} == '-' ]] && { rest=${rest:1}; heredoc_tabstrip=1; }
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
                            # An unquoted delimiter such as `<<\EOF` disables
                            # heredoc-body expansion the same way a quoted one
                            # does; bash strips the backslash for the purpose
                            # of matching the terminator, so the stored
                            # delimiter must too, or the real terminator line
                            # (bare "EOF") never matches "\EOF".
                            delimiter=${delimiter//\\/}
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

# Tokenize ONE segment as the shell would (single/double quotes, backslash
# escapes): read -r -a split a quoted sed address into several path-shaped
# "words" (issue #335 Case 3). One word per line; quote characters are consumed.
guard_tokenize_words() {
    local segment=$1 word='' quote='' escaped=0 char i length
    length=${#segment}
    for ((i = 0; i < length; i++)); do
        char=${segment:i:1}
        if ((escaped)); then
            word+=$char
            escaped=0
            continue
        fi
        if [[ $char == \\ && $quote != "'" ]]; then
            escaped=1
            continue
        fi
        if [[ -n $quote ]]; then
            if [[ $char == "$quote" ]]; then
                quote=''
            else
                word+=$char
            fi
            continue
        fi
        case $char in
            "'" | '"') quote=$char ;;
            [[:space:]])
                if [[ -n $word ]]; then
                    printf '%s\n' "$word"
                    word=''
                fi
                ;;
            *) word+=$char ;;
        esac
    done
    [[ -n $word ]] && printf '%s\n' "$word"
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
        # shellcheck disable=SC2016  # $agentkit is literal text the agent retypes
        advice='Policy: gh mutation bodies are file-backed (--body-file, --input, or -F body=@file); create/edit PRs and issues via "$agentkit/.shared/scripts/gh-body.sh", which byte-verifies the stored body.'
        if ((comment)); then
            # shellcheck disable=SC2016  # same: literal text
            advice+=' Comments: "$agentkit/review-remote-pr/scripts/gh-comment.sh" --body-file FILE.'
        fi
        if ((literal_backslash_n)); then
            advice+=' A literal \n renders as backslash-n in the posted body; write the newline to the file.'
        fi
        printf '%s' "$advice"
        return 0
    done <<< "$segments"
    return 1
}

# A hook that fails open is invisible: one JSONL line per incident under the
# resolved state root's .agent/logs (guard_state_root -- never $PWD, which once
# left a stray log inside agentkit/skills/, issue #370). No resolved root means
# write nothing; GUARD_LOG_ROOT is a test override.
guard_log_error() {
    local status=${1:-?} root dir
    root=${GUARD_LOG_ROOT:-$(guard_state_root)}
    [[ -n $root ]] || return 0
    dir="$root/.agent/logs"
    mkdir -p "$dir" 2> /dev/null || return 0
    printf '{"hook":"%s","status":"%s","line":"%s"}\n' \
        "${GUARD_HOOK_NAME:-unknown}" "$status" "${BASH_LINENO[0]:-unknown}" \
        >> "$dir/hook-errors.jsonl" 2> /dev/null || true
}

# Files that decide whether other checks run (CI definitions, git hooks, harness
# config): deny-ONCE, since editing one is legitimate sometimes and
# gate-loosening other times. Defaults are the gate-and-guard class;
# AGENT_PROTECTED_PATHS is additive (a committed file cannot switch its own
# guard off). Prints the matched pattern.
guard_protected_match() {
    local candidate=$1 root=$2
    candidate=${candidate//\\//}
    candidate=${candidate#./}
    # An absolute path inside the repository is compared repo-relative, so the
    # same rule covers both forms an agent might use.
    [[ -z $root || $candidate != "$root"/* ]] || candidate=${candidate#"$root"/}

    # Declared unconditionally: a repository with no .agent/config.env (the
    # default, un-onboarded case) must fall through to the built-in list below
    # rather than trip `set -u` and skip the guard entirely (issue #368).
    local declared=''
    if [[ -n $root && -r $root/.agent/config.env ]]; then
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
    local cmd=$1 segments segment write_probe token
    local -a results=()

    # Heredoc BODIES are data, never a write target's spelling -- a JSON/text
    # payload that happens to mention a protected path inside a heredoc body
    # is not editing it. Segmenting first, via the same heredoc-aware lexer
    # guard_out_of_scope_target relies on, drops those bodies entirely; each
    # remaining segment is then judged on its own tokens only (issue #397).
    segments=$(guard_gh_command_segments "$cmd")
    while IFS= read -r segment; do
        [[ -n ${segment//[[:space:]]/} ]] || continue

        # Redirects to device sinks discard output but do not write a
        # protected path. Remove them before deciding whether this segment is
        # write-shaped.
        write_probe=$(sed -E \
            -e 's#([0-9]*>>?[[:space:]]*)"/dev/(null|stdout|stderr)"([[:space:];|&()<>]|$)#\1/dev/\2\3#g' \
            -e "s#([0-9]*>>?[[:space:]]*)'/dev/(null|stdout|stderr)'([[:space:];|&()<>]|$)#\\1/dev/\\2\\3#g" \
            -e 's#[0-9]*>>?[[:space:]]*/dev/(null|stdout|stderr)([[:space:];|&()<>]|$)#\2#g' \
            <<< "$segment")

        # Stage one: is this segment write-shaped at all (tee, sed -i, cp, mv,
        # install, truncate, dd, a redirect)? Parsing operands per command rots;
        # a path mentioned by grep or cat is not a target.
        grep -qE '(^|[;&|[:space:]])(tee|sed[[:space:]]+-i|cp|mv|install|truncate|dd)([[:space:]]|$)|>>?[[:space:]]*[^[:space:]&|]' \
            <<< "$write_probe" 2> /dev/null || continue

        # Stage two: offer tokens broadly and let the protected list decide,
        # except shell syntax and unambiguous data operands: Git <rev>:<path> /
        # <rev>^{type} (issue #423) and a LEADING NAME=value assignment (issue
        # #397). The skip ends at the command word -- applied everywhere it
        # dropped dd's of= target (follow-up F2); a later key=value offers its
        # VALUE.
        local seen_command=0 command_is_git=no redirect_pending=0 redirect_target=0 value
        local redirect_re='^[0-9]*>>?(.*)$'
        while IFS= read -r token; do
            [[ -n $token ]] || continue

            # Preserve enough shell redirect syntax to exempt only Git's read
            # operands below, never the redirect destination itself. The
            # lexer may emit `> file`, `>file`, or their fd/append forms.
            redirect_target=0
            if ((redirect_pending)); then
                redirect_target=1
                redirect_pending=0
            elif [[ $token =~ $redirect_re ]]; then
                token=${BASH_REMATCH[1]}
                if [[ -z $token ]]; then
                    redirect_pending=1
                    continue
                fi
                redirect_target=1
            fi
            if ((redirect_target)); then
                token=${token#\"}; token=${token%\"}
                token=${token#\'}; token=${token%\'}
            fi
            [[ -n $token ]] || continue
            if [[ $token =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
                if ((seen_command)); then
                    value=${token#*=}
                    [[ -n $value ]] && results+=("$value")
                fi
                continue
            fi
            if ((!seen_command)); then
                [[ $token == git ]] && command_is_git=yes
            fi
            seen_command=1

            # Shell permits a redirect to be attached to the preceding word.
            # Split that destination out before classifying a Git object name;
            # otherwise `HEAD:path>target` looks like one large revspec and the
            # data-operand exemption drops the real target with it.
            if ((redirect_target == 0)) && [[ $command_is_git == yes && $token == *'>'* ]]; then
                value=${token#*>}
                value=${value#>}
                value=${value#\"}; value=${value%\"}
                value=${value#\'}; value=${value%\'}
                [[ -n $value ]] && results+=("$value")
                token=${token%%>*}
                [[ -n $token ]] || continue
            fi
            [[ $token == -* ]] && continue
            if ((redirect_target == 0)) && [[ $command_is_git == yes && $token != *'>'* ]] &&
                { [[ $token =~ ^[^/:][^:]*:.+$ ]] ||
                    [[ $token =~ \^\{(tree|commit|tag|object)\}$ ]]; }; then
                continue
            fi
            results+=("$token")
        done < <(guard_tokenize_words "$segment" |
            sed -E 's/^[<]+//; s/^["'"'"']+//; s/["'"'"']+$//' |
            sed -E 's/[;|&()]+$//')
    done <<< "$segments"

    ((${#results[@]})) && printf '%s\n' "${results[@]}"
    return 0
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
