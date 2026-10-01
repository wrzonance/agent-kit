# shellcheck shell=bash
# ak verify [--full]: run the declared suites the diff touches, each in its own directory; CI stays the full gate.
#
# A suite AGENT_CMD_<NAME> runs when a changed path sits under its AGENT_RUNDIR_<NAME> (and runs there), or, with no
# rundir, when its command names a changed path's top-level directory (`pytest server/tests` for server/ changes).
# The repository's whole check (AGENT_CMD_VERIFY, else AGENT_CMD_TEST) runs only when no suite matched or with
# --full: a field run spent most of 58M tokens on five workers re-running a whole-repo check for one-area diffs.

# Paths changed against the work base, committed or not.
verify_changed_paths() {
    local base
    base=$(work_base)
    {
        git diff --name-only "origin/$base...HEAD" 2>/dev/null || true
        git diff --name-only HEAD
        git ls-files --others --exclude-standard
    } | LC_ALL=C sort -u
}

# Every NAME with an AGENT_CMD_NAME in the environment or config, minus the whole-repo and fix commands.
verify_suite_names() {
    local file name
    file="$(main_root)/.agent/config.env"
    {
        compgen -v AGENT_CMD_ || true
        [[ ! -f $file ]] || grep -oE '^AGENT_CMD_[A-Za-z0-9_]+' "$file" || true
    } | sed 's/^AGENT_CMD_//' | LC_ALL=C sort -u | while IFS= read -r name; do
        case $name in SETUP | VERIFY | TEST | *_FIX) continue ;; esac
        printf '%s\n' "$name"
    done
}

# verify_covers DIR COMMAND PATH: does this suite own PATH?
verify_covers() {
    local dir=${1%/} command=$2 path=$3 top
    if [[ -n $dir && $dir != . ]]; then
        [[ $path == "$dir"/* ]]
        return
    fi
    [[ $path == */* ]] || return 1
    top=${path%%/*}
    [[ " $command " =~ [[:space:]/=\"\']${top}(/|[[:space:]]) ]]
}

verify_skips() {
    local logs=$1
    shift
    (($# == 0)) && return 0
    (cd -- "$logs" && cat -- "$@") | sed -nE 's/^SKIP ([^ ]+).*/\1/p' | LC_ALL=C sort -u | paste -sd, -
}

# verify_whole: the repository's whole check, or nothing. Prints "NAME<TAB>COMMAND".
verify_whole() {
    local command
    if command=$(cfg AGENT_CMD_VERIFY) && [[ -n $command ]]; then
        printf 'verify\t%s\n' "$command"
    elif command=$(cfg AGENT_CMD_TEST) && [[ -n $command ]]; then
        printf 'test\t%s\n' "$command"
    fi
}

cmd_main() {
    local full=0 name command dir changed path out="" rc=0 skipped whole uncovered=() owned
    local -a ran=() suites=()
    case ${1:-} in --full) full=1 ;; '') ;; *) usage_die "usage: ak verify [--full]" ;; esac
    cd -- "$(worktree_root)" || exit 1
    changed=$(verify_changed_paths)
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        command=$(cfg "AGENT_CMD_$name")
        dir=$(cfg "AGENT_RUNDIR_$name")
        [[ -n $command ]] || continue
        while IFS= read -r path; do
            [[ -n $path ]] && verify_covers "$dir" "$command" "$path" && { suites+=("$name"); break; }
        done <<<"$changed"
    done < <(verify_suite_names)
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        owned=0
        for name in "${suites[@]}"; do
            verify_covers "$(cfg "AGENT_RUNDIR_$name")" "$(cfg "AGENT_CMD_$name")" "$path" && { owned=1; break; }
        done
        ((owned)) || uncovered+=("$path")
    done <<<"$changed"
    whole=$(verify_whole)
    if [[ -n $whole ]] && ((full || ${#suites[@]} == 0)); then
        out+=$(run_logged "${whole%%$'\t'*}" "${whole#*$'\t'}")$'\n' || rc=1
        ran+=("${whole%%$'\t'*}.log")
    fi
    for name in "${suites[@]}"; do
        dir=$(cfg "AGENT_RUNDIR_$name")
        out+=$(run_logged "${name,,}" "$(cfg "AGENT_CMD_$name")" "${dir:-.}")$'\n' || rc=1
        ran+=("${name,,}.log")
    done
    if ((${#ran[@]} == 0)); then
        printf 'verify=none oracle=ci\n'
        return 0
    fi
    skipped=$(verify_skips "$(ak_dir)/logs" "${ran[@]}")
    ((rc)) && printf 'verify=fail\n' || printf 'verify=pass\n'
    printf '%s' "$out"
    [[ -z $skipped ]] || printf 'skipped=%s\n' "$skipped"
    if ((${#suites[@]} > 0 && ! full && ${#uncovered[@]} > 0)); then
        printf 'uncovered=%s%s\n' "$(printf '%s\n' "${uncovered[@]:0:3}" | paste -sd, -)" \
            "$( ((${#uncovered[@]} > 3)) && printf ' (+%d)' $((${#uncovered[@]} - 3)))"
    fi
    if [[ -n $skipped ]] || ((${#suites[@]} > 0 && ! full)); then printf 'oracle=ci\n'; fi
    return "$rc"
}
