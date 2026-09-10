#!/usr/bin/env bash
#
# detect-toolchains.sh -- which components a repository actually has, from its own
# marker files (package.json, pyproject.toml, .csproj, ...), so onboarding never
# hardcodes one ecosystem and a moved component is found again. See --help.
set -uo pipefail

PROGRAM=${0##*/}

usage() {
    cat << 'EOF'
detect-toolchains.sh -- find the components a repository actually has: which
directories run which language, with which package manager or build tool, so
a moved component can be found again and onboarding never hardcodes one
ecosystem.

Usage:
  detect-toolchains.sh [--repo-root DIR] [--format LIST]
  LIST is one or more of components,suggestions,gaps,drift (comma-joined),
  each section run once and printed in the order given.

--format components   one line per detected component
--format suggestions  commented AGENT_CMD_*/AGENT_RUNDIR_* declarations
--format gaps         detected commands this repo has NOT declared (re-onboarding);
                       also lists other commented-out AGENT_* declarations
                       (labels, ADR dir, protected paths, review providers)
--format drift        compares .agent/config.env declarations against disk

Exit 0 always; exit 3 only when --repo-root DIR is not a directory.
EOF
}

# Directories excluded at ANY depth (e.g. dashboard/.next/package.json is a
# build artifact, not a component -- reporting it would get it declared).
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

# True if any path segment is an excluded dir name -- needed because
# `git ls-files` output (markdown count, shell file list) skips find's prune.
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

    # node -- runner comes from the lockfile in the same directory; with none,
    # inherit the nearest ancestor node component's runner (not npm).
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

    # markdown -- conservative on purpose: a config file is definitive; absent
    # that, only an on-PATH linter plus >5 tracked docs earns the suggestion.
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

    # shell -- no marker file; a component is a directory owning tracked *.sh
    # files not already claimed by a deeper one (deepest-first).
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
    # Shell and markdown describe the WHOLE repository, not one component of
    # it -- reported per directory, they'd duplicate AGENT_CMD_<DIR>_LINT.
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

# Config values are parsed line-wise, not sourced. Quote only tokens that need
# grouping so a generated path such as "My Project" survives that parser as one
# argv token while ordinary suggestions remain readable.
config_quote_token() {
    case $1 in
        *' '*) printf '"%s"' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Whether TOOL is available to a python component with runner RUNNER: a
# resolved .venv checks binary presence (strongest evidence); otherwise fall
# back to a text match against the component's own marker files.
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
    local dir=$1 runner=$2 tool=$3 relative_runner
    if [[ $runner == */* ]]; then
        # PY_RUNNER is kept repository-relative for probing, but a command
        # paired with AGENT_RUNDIR must name argv[0] from that directory.
        # Root components already use the repository as their rundir.
        if [[ $dir != . && $runner == "$dir"/* ]]; then
            relative_runner=${runner#"$dir"/}
        else
            relative_runner=$runner
        fi
        config_quote_token "$relative_runner/$tool"
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
        bin=$(py_bin_prefix "$dir" "$runner" pytest)
        printf 'TEST\t%s\n' "$bin"
    fi
    if py_tool_present "$dir" ruff "$runner"; then
        bin=$(py_bin_prefix "$dir" "$runner" ruff)
        printf 'LINT\t%s\n' "$bin"
        printf 'FORMAT\t%s format --check\n' "$bin"
    fi
    if py_tool_present "$dir" mypy "$runner"; then
        bin=$(py_bin_prefix "$dir" "$runner" mypy)
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

# A repository with ONE entry point (e.g. tools/verify) has answered the
# question already, and that outranks anything inferred per component.
gen_dispatcher_tasks() {
    local script
    for script in tools/verify tools/dev/verify bin/verify scripts/verify; do
        if [[ -x "$repo_root/$script" ]]; then
            printf 'VERIFY\t%s\n' "$(config_quote_token "$script")"
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
            # An auxiliary language at the repo root would otherwise claim the
            # same key as a real component there (e.g. AGENT_CMD_LINT twice).
            case $lang in
                shell | markdown) name=$(suggestion_name "$cname" "${task}_$(printf '%s' "$lang" | tr '[:lower:]' '[:upper:]')") ;;
                *) name=$(suggestion_name "$cname" "$task") ;;
            esac
            if [[ $lang == shell && $task == LINT ]]; then
                printf '# shellcheck needs explicit file operands -- argv cannot glob, so choose\n'
                printf '# the paths this repository wants checked:\n'
            fi
            printf '# AGENT_CMD_%s=%s\n' "$name" "$value"
            [[ $path == . ]] || printf '# AGENT_RUNDIR_%s=%s\n' "$name" "$(config_quote_token "$path")"
        done
        printf '\n'
    done <<< "$sorted"

    ((any)) || return 0
    suggestion_footer
}

# ---- gaps --------------------------------------------------------------------

# What has this repository NOT declared? Re-onboarding a repo with an existing
# config.env must still run the detector -- trusting that file as "what
# exists" misses components added since it was last written. Built by
# filtering the SAME generator print_suggestions uses, so this can't drift.
print_gaps() {
    local line header key pending_header='' shown=0 total=0 declared=0
    local -a undeclared=()

    while IFS= read -r line; do
        case $line in
            '# component: '*) header=$line ;;
            '# repository entry point'*) header='# repository entry point' ;;
            '# AGENT_CMD_'*)
                key=${line#\# }
                key=${key%%=*}
                total=$((total + 1))
                if grep -qE "^[[:space:]]*$key=" "$repo_root/.agent/config.env" 2> /dev/null; then
                    declared=$((declared + 1))
                    pending_header=''
                    continue
                fi
                if [[ $header != "$pending_header" ]]; then
                    undeclared+=("$header")
                    pending_header=$header
                fi
                undeclared+=("$line")
                shown=$((shown + 1))
                ;;
            '# AGENT_RUNDIR_'*)
                # Only meaningful beside the command it pairs with.
                [[ -n $pending_header ]] && undeclared+=("$line")
                ;;
        esac
    done < <(print_suggestions)

    printf 'gaps= detected=%d declared=%d undeclared=%d\n\n' "$total" "$declared" "$shown"
    if ((shown == 0)); then
        printf 'Every command this detector can see is already declared.\n'
        printf 'That is not the same as complete -- it only means nothing NEW was found.\n'
    else
        printf 'DETECTED but not declared -- nothing in .agent/config.env runs these:\n\n'
        printf '%s\n' "${undeclared[@]}"
        printf '\n'
        suggestion_footer
    fi
    print_blank_declarations
}

# What onboarding's own `grep '^# AGENT_'` glue used to do beside this call:
# surface EVERY commented-out declaration, including ones with no marker file
# to infer from (e.g. AGENT_CMD_SETUP) -- one call now covers this plus grep.
print_blank_declarations() {
    local config=$repo_root/.agent/config.env blanks
    [[ -r $config ]] || return 0
    blanks=$(grep -nE '^# AGENT_' "$config" 2> /dev/null || true)
    [[ -n $blanks ]] || return 0
    printf '\nOther commented declarations still blank:\n\n%s\n' "$blanks"
}

# ---- drift -------------------------------------------------------------------

# Locate a plausible replacement for a missing declared path, by basename:
# search for a same-named directory that is itself a real component (holds a
# known marker file). Scoped to one basename, keeping drift cheap to run.
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
    local -a argv=()
    declared=$("$self_dir/repo-config.sh" --repo-root "$repo_root" --list 2> /dev/null) || true
    [[ -n $declared ]] || return 0

    while IFS='=' read -r key value; do
        [[ $key == AGENT_RUNDIR_* ]] || continue
        [[ -n $value ]] || continue
        [[ -d "$repo_root/$value" ]] && continue
        candidate=$(find_drift_candidate "$value")
        printf 'drift= key=%s declared=%s status=missing candidate=%s\n' \
            "$key" "$(config_quote_token "$value")" "$(config_quote_token "$candidate")"
    done <<< "$declared"

    while IFS='=' read -r key value; do
        [[ $key == AGENT_CMD_* ]] || continue
        argv=()
        mapfile -d '' -t argv < <("$self_dir/repo-config.sh" --repo-root "$repo_root" --get-argv "$key" 2> /dev/null)
        argv0=${argv[0]:-}
        [[ $argv0 == */* ]] || continue
        dir=${argv0%/*}
        [[ -d "$repo_root/$dir" ]] && continue
        candidate=$(find_drift_candidate "$dir")
        printf 'drift= key=%s declared=%s status=missing candidate=%s\n' \
            "$key" "$(config_quote_token "$dir")" "$(config_quote_token "$candidate")"
    done <<< "$declared"
}

# ---- main ----------------------------------------------------------------

ARG_REPO_ROOT=''
ARG_FORMAT=suggestions

while (($#)); do
    case $1 in
        --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
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

# A comma-joined list runs each named section in one call -- e.g.
# `--format gaps,suggestions` -- so onboarding no longer needs two separate
# invocations to get both reports (issue #696); duplicates dedupe to first.
declare -a ARG_FORMATS=() ARG_FORMATS_UNIQUE=()
declare -A seen_fmt=()
IFS=, read -ra ARG_FORMATS <<< "$ARG_FORMAT"
for fmt in "${ARG_FORMATS[@]}"; do
    case $fmt in
        components | suggestions | gaps | drift) ;;
        *)
            printf '%s: unknown --format %s (want components|suggestions|gaps|drift)\n' "$PROGRAM" "$fmt" >&2
            exit 2
            ;;
    esac
    [[ -n ${seen_fmt[$fmt]:-} ]] || { seen_fmt[$fmt]=1; ARG_FORMATS_UNIQUE+=("$fmt"); }
done

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

[[ $ARG_FORMAT == drift ]] || collect_all
first=1
for fmt in "${ARG_FORMATS_UNIQUE[@]}"; do
    ((first)) || printf '\n'
    first=0
    case $fmt in
        components) print_components ;;
        suggestions) print_suggestions ;;
        gaps) print_gaps ;;
        drift) print_drift ;;
    esac
done

exit 0
