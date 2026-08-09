#!/usr/bin/env bash
#
# detect-toolchains.sh -- what components does this repository actually have?
#
# Onboarding used to hardcode one package manager and one ecosystem: on a
# repository locked with a different node package manager it still suggested
# npm, and it never looked for a lint script at all. A repository states its
# own facts in its marker files (package.json,
# pyproject.toml, a .csproj, ...); this finds them so a human does not have
# to enumerate components by hand, and so a component that later moves can be
# found again by the same marker rather than by a path nobody re-checks.
#
# Reports, never fails: exit 0 always, 3 only when --repo-root DIR is not a
# directory. "Found nothing" is exit 0 with no output -- a format that always
# prints something trains the reader to stop looking at it.
#
# Usage:
#   detect-toolchains.sh [--repo-root DIR] [--format components|suggestions|drift]
set -uo pipefail

PROGRAM=${0##*/}

usage() {
    cat << 'EOF'
detect-toolchains.sh -- find the components a repository actually has: which
directories run which language, with which package manager or build tool, so
a moved component can be found again and onboarding never hardcodes one
ecosystem.

Usage:
  detect-toolchains.sh [--repo-root DIR] [--format components|suggestions|drift]

--format components   one line per detected component (default: suggestions)
--format suggestions  commented AGENT_CMD_*/AGENT_RUNDIR_* declarations
--format drift        compares .agent/config.env declarations against disk

Exit 0 always; exit 3 only when --repo-root DIR is not a directory.
EOF
}

# Directories excluded at ANY depth. A directory inside one of these is not a
# component -- the case that motivates this: a real repository carries
# dashboard/.next/package.json (a build artifact, not a source component),
# and reporting it would be a phantom that then gets declared and committed.
readonly -a EXCLUDE_NAMES=(
    node_modules .venv venv vendor .git .worktrees site-packages
    dist build target out coverage .next
)

# The same exclusion, expressed as a find(1) prune clause. Built once and
# reused by every walk in this file, including the drift candidate search.
readonly -a PRUNE_EXPR=(
    -type d '('
    -name node_modules -o -name .venv -o -name venv -o -name vendor
    -o -name .git -o -name .worktrees -o -name site-packages
    -o -name dist -o -name build -o -name target -o -name out
    -o -name coverage -o -name .next
    ')' -prune
)

# ---- small path helpers -----------------------------------------------------

# Absolute path -> repo-relative path, with "." for the repo root itself.
relpath() {
    local abs=$1 rel
    rel=${abs#"$repo_root"/}
    [[ $rel != "$abs" ]] || rel=.
    printf '%s' "$rel"
}

componentdir_of_marker() {
    local d
    d=$(dirname -- "$1")
    relpath "$d"
}

# Join a repo-relative component dir ("." for root) with a filename.
joinpath() {
    if [[ $1 == . ]]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi
}

# Depth of a repo-relative path, root = 0, used to process node components
# shallowest-first so lockfile inheritance sees the ancestor before the child.
depth_of() {
    local p=$1 slashes
    if [[ $p == . ]]; then
        printf '0'
        return
    fi
    slashes=${p//[^\/]/}
    printf '%d' $((${#slashes} + 1))
}

# True if any path segment of a repo-relative path is an excluded dir name.
# Needed on top of the find(1) prune because `git ls-files` output (used for
# the markdown count and the shell file list) never goes through find's prune
# at all.
is_excluded_path() {
    local p=$1 part ex
    local IFS=/
    for part in $p; do
        for ex in "${EXCLUDE_NAMES[@]}"; do
            [[ $part == "$ex" ]] && return 0
        done
    done
    return 1
}

# All files under repo_root matching any of the given -name patterns,
# skipping excluded dirs at any depth. One shared prune clause, reused so
# every marker search behaves identically.
find_files_by_names() {
    local -a names=("$@") expr=()
    local first=1 n
    for n in "${names[@]}"; do
        if ((first)); then
            expr+=(-name "$n")
            first=0
        else
            expr+=(-o -name "$n")
        fi
    done
    find "$repo_root" "${PRUNE_EXPR[@]}" -o -type f '(' "${expr[@]}" ')' -print
}

get_sh_files() {
    if git -C "$repo_root" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        git -C "$repo_root" ls-files -- '*.sh'
    else
        find "$repo_root" "${PRUNE_EXPR[@]}" -o -type f -name '*.sh' -print |
            while IFS= read -r f; do relpath "$f"; done
    fi
}

# Nearest ancestor directory that is ITSELF a node component with an already
# resolved runner. Requires NODE_RUNNER to be populated shallowest-first.
nearest_node_ancestor_runner() {
    local d=$1
    while :; do
        if [[ $d == */* ]]; then
            d=${d%/*}
        elif [[ $d != . ]]; then
            d=.
        else
            return 1
        fi
        if [[ -n ${NODE_RUNNER[$d]:-} ]]; then
            printf '%s' "${NODE_RUNNER[$d]}"
            return 0
        fi
    done
}

# ---- component collection ---------------------------------------------------

declare -A NODE_MARKER=() NODE_RUNNER=() PY_MARKER=() PY_RUNNER=()
declare -A DOTNET_MARKER=() GO_MARKER=() RUST_MARKER=() MD_MARKER=() SHELL_MARKER=()
COMPONENT_LINES=()

collect_all() {
    local f d name lockfile toolname runner mdcount venvbin

    # node -- runner comes from the lockfile IN THE SAME DIRECTORY; a
    # directory with no lockfile of its own inherits the nearest ancestor
    # node component's runner, so a workspace package under a root that
    # locked with a different tool does not get told to run npm.
    while IFS= read -r f; do
        d=$(componentdir_of_marker "$f")
        NODE_MARKER[$d]=package.json
    done < <(find_files_by_names package.json)

    local -a sorted_dirs
    mapfile -t sorted_dirs < <(
        for d in "${!NODE_MARKER[@]}"; do printf '%s\t%s\n' "$(depth_of "$d")" "$d"; done |
            sort -n -k1,1 -k2,2 | cut -f2-
    )
    for d in "${sorted_dirs[@]}"; do
        runner=''
        for name in 'pnpm-lock.yaml:pnpm' 'yarn.lock:yarn' 'bun.lockb:bun' 'package-lock.json:npm'; do # ecosystem-allow: detection
            lockfile=${name%%:*}
            toolname=${name##*:}
            if [[ -f "$repo_root/$(joinpath "$d" "$lockfile")" ]]; then
                runner=$toolname
                break
            fi
        done
        if [[ -z $runner ]]; then
            runner=$(nearest_node_ancestor_runner "$d") || runner=npm
        fi
        NODE_RUNNER[$d]=$runner
    done

    # python -- first marker found wins, in the stated precedence order.
    for name in pyproject.toml setup.cfg requirements.txt; do
        while IFS= read -r f; do
            d=$(componentdir_of_marker "$f")
            [[ -n ${PY_MARKER[$d]:-} ]] || PY_MARKER[$d]=$name
        done < <(find_files_by_names "$name")
    done
    for d in "${!PY_MARKER[@]}"; do
        venvbin=$(joinpath "$d" .venv/bin)
        if [[ -d "$repo_root/$venvbin" ]]; then
            PY_RUNNER[$d]=$venvbin
        elif command -v uv > /dev/null 2>&1; then
            PY_RUNNER[$d]=uv
        else
            PY_RUNNER[$d]='python3 -m'
        fi
    done

    # dotnet -- one component per directory even when both a .csproj and a
    # .sln live there; whichever sorts first is the recorded marker.
    while IFS= read -r f; do
        d=$(componentdir_of_marker "$f")
        [[ -n ${DOTNET_MARKER[$d]:-} ]] || DOTNET_MARKER[$d]=$(basename -- "$f")
    done < <(find_files_by_names '*.csproj' '*.sln' | sort)

    while IFS= read -r f; do
        d=$(componentdir_of_marker "$f")
        GO_MARKER[$d]=go.mod
    done < <(find_files_by_names go.mod)

    while IFS= read -r f; do
        d=$(componentdir_of_marker "$f")
        RUST_MARKER[$d]=Cargo.toml
    done < <(find_files_by_names Cargo.toml)

    # markdown -- conservative on purpose. A config file is definitive; absent
    # that, only a linter that is actually on PATH plus a real body of tracked
    # docs (five is arbitrary but nonzero) earns the suggestion. Nobody wants
    # a markdown linter suggested for every repository that happens to have a
    # README.
    local -a mdcfg
    mapfile -t mdcfg < <(find "$repo_root" -maxdepth 1 -type f -name '.markdownlint*' 2> /dev/null | sort)
    if ((${#mdcfg[@]})); then
        MD_MARKER[.]=$(basename -- "${mdcfg[0]}")
    elif command -v markdownlint-cli2 > /dev/null 2>&1 &&
        git -C "$repo_root" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        mdcount=0
        while IFS= read -r f; do
            is_excluded_path "$f" || mdcount=$((mdcount + 1))
        done < <(git -C "$repo_root" ls-files -- '*.md')
        ((mdcount > 5)) && MD_MARKER[.]=markdownlint-cli2
    fi

    # shell -- no single marker file; a component is a directory (any other
    # component's root, or the repo root) that owns tracked *.sh files not
    # already claimed by a deeper component directory. Deepest-first so a
    # nested component claims its own scripts before the root claims the rest.
    local have_shellcheck=0
    command -v shellcheck > /dev/null 2>&1 && have_shellcheck=1
    if ((have_shellcheck)); then
        local -a sh_files=()
        while IFS= read -r f; do
            is_excluded_path "$f" || sh_files+=("$f")
        done < <(get_sh_files)
        if ((${#sh_files[@]})); then
            local -A cand=([.]=1)
            for d in "${!NODE_MARKER[@]}" "${!PY_MARKER[@]}" "${!DOTNET_MARKER[@]}" \
                "${!GO_MARKER[@]}" "${!RUST_MARKER[@]}" "${!MD_MARKER[@]}"; do
                cand[$d]=1
            done
            local -a shell_candidates
            mapfile -t shell_candidates < <(
                for d in "${!cand[@]}"; do printf '%s\t%s\n' "$(depth_of "$d")" "$d"; done |
                    sort -rn -k1,1 -k2,2 | cut -f2-
            )
            local -a remaining owned new_remaining
            local fdir fpath
            remaining=("${sh_files[@]}")
            for d in "${shell_candidates[@]}"; do
                owned=()
                new_remaining=()
                for fpath in "${remaining[@]}"; do
                    fdir=$(dirname -- "$fpath")
                    if [[ $d == . || $fdir == "$d" || $fdir == "$d"/* ]]; then
                        owned+=("$fpath")
                    else
                        new_remaining+=("$fpath")
                    fi
                done
                ((${#owned[@]})) && SHELL_MARKER[$d]='*.sh'
                remaining=("${new_remaining[@]}")
            done
        fi
    fi

    for d in "${!NODE_MARKER[@]}"; do
        COMPONENT_LINES+=("$d"$'\t'node$'\t'"${NODE_MARKER[$d]}"$'\t'"${NODE_RUNNER[$d]}")
    done
    for d in "${!PY_MARKER[@]}"; do
        COMPONENT_LINES+=("$d"$'\t'python$'\t'"${PY_MARKER[$d]}"$'\t'"${PY_RUNNER[$d]}")
    done
    for d in "${!DOTNET_MARKER[@]}"; do
        COMPONENT_LINES+=("$d"$'\t'dotnet$'\t'"${DOTNET_MARKER[$d]}"$'\tdotnet')
    done
    for d in "${!GO_MARKER[@]}"; do
        COMPONENT_LINES+=("$d"$'\t'go$'\t'"${GO_MARKER[$d]}"$'\tgo')
    done
    for d in "${!RUST_MARKER[@]}"; do
        COMPONENT_LINES+=("$d"$'\t'rust$'\t'"${RUST_MARKER[$d]}"$'\tcargo')
    done
    for d in "${!MD_MARKER[@]}"; do
        COMPONENT_LINES+=(.$'\t'markdown$'\t'"${MD_MARKER[$d]}"$'\tnone')
        break
    done
    # Shell and markdown describe the WHOLE repository, not one component of it.
    # Reported per directory they produced a "shell component" beside every real
    # one -- and then two components at the same path each proposed
    # AGENT_CMD_<DIR>_LINT, which is a duplicate key in a committed file.
    if ((${#SHELL_MARKER[@]})); then
        COMPONENT_LINES+=(.$'\t'shell$'\t''*.sh'$'\tnone')
    fi
}

print_components() {
    ((${#COMPONENT_LINES[@]})) || return 0
    printf '%s\n' "${COMPONENT_LINES[@]}" | sort -t $'\t' -k1,1 -k2,2 |
        while IFS=$'\t' read -r path lang marker runner; do
            printf 'component= path=%s lang=%s marker=%s runner=%s\n' "$path" "$lang" "$marker" "$runner"
        done
}

# ---- suggestions -------------------------------------------------------------

# Directory basename, uppercased, non-alnum runs collapsed to underscores.
# Empty for the repo root, which gets a bare TASK name instead of a prefix.
component_name() {
    local path=$1 base upper
    if [[ $path == . ]]; then
        printf ''
        return
    fi
    base=${path##*/}
    upper=${base^^}
    upper=${upper//[^A-Z0-9]/_}
    printf '%s' "$upper"
}

suggestion_name() {
    local cname=$1 task=$2
    if [[ -z $cname ]]; then
        printf '%s' "$task"
    else
        printf '%s_%s' "$cname" "$task"
    fi
}

# Whether TOOL is actually available to a python component with runner
# RUNNER. A resolved .venv is checked by binary presence, which is the
# strongest evidence (a listed dependency is not necessarily installed); an
# unresolved runner (uv / python3 -m) falls back to a text match against the
# component's own marker files.
py_tool_present() {
    local dir=$1 tool=$2 runner=$3 f
    if [[ $runner == */* ]]; then
        [[ -x "$repo_root/$runner/$tool" ]]
        return
    fi
    for f in pyproject.toml setup.cfg requirements.txt; do
        f="$repo_root/$(joinpath "$dir" "$f")"
        [[ -f $f ]] || continue
        grep -qiE "(^|[^a-z0-9_])${tool}([^a-z0-9_]|\$)" "$f" && return 0
    done
    return 1
}

py_bin_prefix() {
    local runner=$1 tool=$2
    if [[ $runner == */* ]]; then
        printf '%s/%s' "$runner" "$tool"
    elif [[ $runner == uv ]]; then
        printf 'uv run %s' "$tool" # ecosystem-allow: detection
    else
        printf 'python3 -m %s' "$tool"
    fi
}

# Each gen_*_tasks function prints TASK\tvalue lines for the tasks it has
# actual evidence for. Nothing here is executed; agent-run.sh is where a
# value gets tried for real.
# npm distinguishes its own subcommands from package scripts; the others do not.
# `npm test` is valid because test is built in, `npm lint` is not a command at  # ecosystem-allow: detection
# all, and `pnpm lint` is fine. Getting this wrong produces a declaration that  # ecosystem-allow: detection
# fails the first time anyone runs it.
node_invocation() {
    local runner=$1 script=$2
    case "$runner:$script" in
        npm:test | npm:start | npm:stop | npm:restart)
            printf '%s %s' "$runner" "$script" # ecosystem-allow: detection
            ;;
        npm:*)
            printf '%s run %s' "$runner" "$script" # ecosystem-allow: detection
            ;;
        *)
            printf '%s %s' "$runner" "$script" # ecosystem-allow: detection
            ;;
    esac
}

gen_node_tasks() {
    local pkg=$1 runner=$2
    local -a keys=(lint test build typecheck type-check format:check format test:coverage coverage verify)
    local -a tasks=(LINT TEST BUILD TYPECHECK TYPECHECK FORMAT FORMAT COVERAGE COVERAGE VERIFY)
    local i key task seen=''
    [[ -f $pkg ]] || return 0
    for i in "${!keys[@]}"; do
        key=${keys[$i]}
        task=${tasks[$i]}
        case $seen in *"|$task|"*) continue ;; esac
        grep -qF "\"$key\":" "$pkg" || continue
        # `npm lint` is not a command. npm requires `run` for anything that is  # ecosystem-allow: detection
        # not one of its own subcommands, so emitting the bare form would have
        # declared something that cannot execute -- and the rule here is that
        # nothing gets declared until it has been seen to pass.
        printf '%s\t%s\n' "$task" "$(node_invocation "$runner" "$key")"
        seen="$seen|$task|"
    done
}

gen_python_tasks() {
    local dir=$1 runner=$2 bin
    if py_tool_present "$dir" pytest "$runner"; then
        bin=$(py_bin_prefix "$runner" pytest)
        printf 'TEST\t%s\n' "$bin"
    fi
    if py_tool_present "$dir" ruff "$runner"; then
        bin=$(py_bin_prefix "$runner" ruff)
        printf 'LINT\t%s\n' "$bin"
        printf 'FORMAT\t%s format --check\n' "$bin"
    fi
    if py_tool_present "$dir" mypy "$runner"; then
        bin=$(py_bin_prefix "$runner" mypy)
        printf 'TYPECHECK\t%s\n' "$bin"
    fi
}

gen_dotnet_tasks() {
    printf 'BUILD\tdotnet build\n'
    printf 'TEST\tdotnet test\n'
    printf 'FORMAT\tdotnet format --verify-no-changes\n'
}

gen_go_tasks() {
    printf 'TEST\tgo test ./...\n' # ecosystem-allow: detection
    printf 'LINT\tgo vet ./...\n'
}

gen_rust_tasks() {
    printf 'TEST\tcargo test\n' # ecosystem-allow: detection
    printf 'LINT\tcargo clippy\n'
    printf 'FORMAT\tcargo fmt --check\n' # ecosystem-allow: detection
}

gen_markdown_tasks() {
    printf 'LINT\tmarkdownlint-cli2 "**/*.md"\n'
}

gen_shell_tasks() {
    printf 'LINT\tshellcheck\n'
}

# A repository that already has ONE entry point has answered the question, and
# it outranks anything inferred per component. The rewrite that introduced
# language detection dropped both of these, so a repo with tools/verify -- the
# exact shape this project recommends -- stopped being offered it.
gen_dispatcher_tasks() {
    local script
    for script in tools/verify tools/dev/verify bin/verify scripts/verify; do
        if [[ -x "$repo_root/$script" ]]; then
            printf 'VERIFY\t%s\n' "$script"
            return 0
        fi
    done
    for script in Makefile makefile; do
        [[ -f "$repo_root/$script" ]] || continue
        local target
        for target in verify test lint check build; do
            grep -qE "^$target:" "$repo_root/$script" 2> /dev/null || continue
            # ecosystem-allow: detection -- naming the tool IS the detection
            printf '%s\tmake %s\n' "$(printf '%s' "$target" | tr '[:lower:]' '[:upper:]')" "$target"
        done
        return 0
    done
    for script in justfile Justfile Taskfile.yml; do
        [[ -f "$repo_root/$script" ]] || continue
        case $script in
            Taskfile.yml) printf 'TEST\ttask test\n' ;; # ecosystem-allow: detection
            *) printf 'TEST\tjust test\n' ;;            # ecosystem-allow: detection
        esac
        return 0
    done
    return 0
}

suggestion_footer() {
    cat << 'SUGGEST_EOF'
# Every value above is argv -- no shell, no &&, no pipes -- and none of it has
# been run. Put each command through agent-run.sh before uncommenting it.
SUGGEST_EOF
}

print_suggestions() {
    local sorted path lang marker runner cname task value name entry any=0
    local -a dispatch=()

    # An existing single entry point answers the question before any per-language
    # guess does, so it is offered first and unprefixed.
    mapfile -t dispatch < <(gen_dispatcher_tasks)
    if ((${#dispatch[@]})); then
        any=1
        printf '# repository entry point (prefer this over the per-component guesses below)\n'
        for entry in "${dispatch[@]}"; do
            [[ -n $entry ]] || continue
            printf '# AGENT_CMD_%s=%s\n' "${entry%%$'\t'*}" "${entry#*$'\t'}"
        done
        printf '\n'
    fi

    if ((${#COMPONENT_LINES[@]} == 0)); then
        ((any)) && suggestion_footer
        return 0
    fi
    sorted=$(printf '%s\n' "${COMPONENT_LINES[@]}" | sort -t $'\t' -k1,1 -k2,2)
    while IFS=$'\t' read -r path lang marker runner; do
        [[ -n $path ]] || continue
        local -a tasks=()
        case $lang in
            node) mapfile -t tasks < <(gen_node_tasks "$repo_root/$(joinpath "$path" package.json)" "$runner") ;;
            python) mapfile -t tasks < <(gen_python_tasks "$path" "$runner") ;;
            dotnet) mapfile -t tasks < <(gen_dotnet_tasks) ;;
            go) mapfile -t tasks < <(gen_go_tasks) ;;
            rust) mapfile -t tasks < <(gen_rust_tasks) ;;
            markdown) mapfile -t tasks < <(gen_markdown_tasks) ;;
            shell) mapfile -t tasks < <(gen_shell_tasks) ;;
            *) continue ;;
        esac
        ((${#tasks[@]})) || continue
        any=1
        printf '# component: %s (%s, %s)\n' "$path" "$lang" "$marker"
        cname=$(component_name "$path")
        for entry in "${tasks[@]}"; do
            task=${entry%%$'\t'*}
            value=${entry#*$'\t'}
            # An auxiliary language at the repository root would otherwise
            # claim the same key as a real component there: one repository
            # proposed AGENT_CMD_LINT twice, once for its node scripts and once
            # for the shell linter.
            case $lang in
                shell | markdown) name=$(suggestion_name "$cname" "${task}_$(printf '%s' "$lang" | tr '[:lower:]' '[:upper:]')") ;;
                *) name=$(suggestion_name "$cname" "$task") ;;
            esac
            if [[ $lang == shell && $task == LINT ]]; then
                printf '# shellcheck needs explicit file operands -- argv cannot glob, so choose\n'
                printf '# the paths this repository wants checked:\n'
            fi
            printf '# AGENT_CMD_%s=%s\n' "$name" "$value"
            [[ $path == . ]] || printf '# AGENT_RUNDIR_%s=%s\n' "$name" "$path"
        done
        printf '\n'
    done <<< "$sorted"

    ((any)) || return 0
    suggestion_footer
}

# ---- drift -------------------------------------------------------------------

# Locate a plausible replacement for a missing declared path, by basename:
# search the tree for a same-named directory that is itself a real component
# (holds one of the known marker files). Only called for a path already
# confirmed missing, and the search is scoped to one basename -- this is what
# keeps drift cheap enough to run every session.
find_drift_candidate() {
    local missing=$1 base d rel
    local -a matches=()
    base=${missing##*/}
    if [[ -z $base ]]; then
        printf 'none'
        return
    fi
    while IFS= read -r d; do
        [[ -n $d ]] || continue
        if [[ -f "$d/package.json" || -f "$d/pyproject.toml" || -f "$d/setup.cfg" ||
            -f "$d/requirements.txt" || -f "$d/go.mod" || -f "$d/Cargo.toml" ]] ||
            compgen -G "$d/*.csproj" > /dev/null 2>&1 ||
            compgen -G "$d/*.sln" > /dev/null 2>&1; then
            rel=${d#"$repo_root"/}
            [[ $rel != "$d" ]] || rel=.
            matches+=("$rel")
        fi
    done < <(find "$repo_root" "${PRUNE_EXPR[@]}" -o -type d -name "$base" -print 2> /dev/null)
    if ((${#matches[@]} == 0)); then
        printf 'none'
    elif ((${#matches[@]} == 1)); then
        printf '%s' "${matches[0]}"
    else
        local joined
        joined=$(
            IFS=,
            printf '%s' "${matches[*]}"
        )
        printf '%s' "$joined"
    fi
}

print_drift() {
    local declared key value argv0 dir candidate
    declared=$("$self_dir/repo-config.sh" --repo-root "$repo_root" --list 2> /dev/null) || true
    [[ -n $declared ]] || return 0

    while IFS='=' read -r key value; do
        [[ $key == AGENT_RUNDIR_* ]] || continue
        [[ -n $value ]] || continue
        [[ -d "$repo_root/$value" ]] && continue
        candidate=$(find_drift_candidate "$value")
        printf 'drift= key=%s declared=%s status=missing candidate=%s\n' "$key" "$value" "$candidate"
    done <<< "$declared"

    while IFS='=' read -r key value; do
        [[ $key == AGENT_CMD_* ]] || continue
        argv0=${value%% *}
        [[ $argv0 == */* ]] || continue
        dir=${argv0%/*}
        [[ -d "$repo_root/$dir" ]] && continue
        candidate=$(find_drift_candidate "$dir")
        printf 'drift= key=%s declared=%s status=missing candidate=%s\n' "$key" "$dir" "$candidate"
    done <<< "$declared"
}

# ---- main ----------------------------------------------------------------

ARG_REPO_ROOT=''
ARG_FORMAT=suggestions

while (($#)); do
    case $1 in
        --repo-root)
            shift
            (($#)) || {
                printf '%s: --repo-root requires a directory\n' "$PROGRAM" >&2
                exit 2
            }
            ARG_REPO_ROOT=$1
            ;;
        --format)
            shift
            (($#)) || {
                printf '%s: --format requires a value\n' "$PROGRAM" >&2
                exit 2
            }
            ARG_FORMAT=$1
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf '%s: unknown argument: %s\n' "$PROGRAM" "$1" >&2
            exit 2
            ;;
    esac
    shift
done

case $ARG_FORMAT in
    components | suggestions | drift) ;;
    *)
        printf '%s: unknown --format %s (want components|suggestions|drift)\n' "$PROGRAM" "$ARG_FORMAT" >&2
        exit 2
        ;;
esac

if [[ -n $ARG_REPO_ROOT ]]; then
    [[ -d $ARG_REPO_ROOT ]] || {
        printf '%s: not a directory: %s\n' "$PROGRAM" "$ARG_REPO_ROOT" >&2
        exit 3
    }
    repo_root=$ARG_REPO_ROOT
else
    repo_root=$(git rev-parse --show-toplevel 2> /dev/null || printf '%s' "$PWD")
fi
repo_root=$(cd -- "$repo_root" && pwd)

self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.

case $ARG_FORMAT in
    components)
        collect_all
        print_components
        ;;
    suggestions)
        collect_all
        print_suggestions
        ;;
    drift)
        print_drift
        ;;
esac

exit 0
