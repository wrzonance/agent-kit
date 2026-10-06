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
    local dir=$1 command=$2 path=$3 top
    while [[ $dir == ./* ]]; do dir=${dir#./}; done
    dir=${dir%/}
    if [[ -n $dir && $dir != . ]]; then
        [[ $path == "$dir"/* ]]
        return
    fi
    [[ $path == */* ]] || return 1
    top=${path%%/*}
    [[ " $command " =~ [[:space:]/=\"\']"$top"(/|[[:space:]]|\"|\') ]]
}

# verify_areas PATHS: the top-level directories (or root files) the changed paths sit in, one per line.
verify_areas() {
    [[ -n $1 ]] || return 0
    awk -F/ '{ print $1 }' <<<"$1" | LC_ALL=C sort -u
}

# verify_whole_cached COMMAND AREAS: did COMMAND already pass in this worktree for a superset of AREAS?
# .ak/verify-whole holds the command on its first line and the areas it passed for after it.
verify_whole_cached() {
    local file
    file="$(ak_dir)/verify-whole"
    [[ -f $file && -n $2 && $(head -n 1 -- "$file") == "$1" ]] || return 1
    [[ -z $(LC_ALL=C comm -23 <(printf '%s\n' "$2") <(tail -n +2 -- "$file" | LC_ALL=C sort -u)) ]]
}

verify_skips() {
    local logs=$1
    shift
    (($# == 0)) && return 0
    (cd -- "$logs" && cat -- "$@") | sed -nE 's/^SKIP ([^ ]+).*/\1/p' | LC_ALL=C sort -u | paste -sd, -
}

# verify_whole FULL: the repository's whole check, or nothing. Prints "NAME<TAB>COMMAND". With FULL, AGENT_CMD_TEST
# comes first: a field repository set VERIFY to its fast check and TEST to the full gate, and --full never ran it.
verify_whole() {
    local full=${1:-0} verify_cmd test_cmd
    verify_cmd=$(cfg AGENT_CMD_VERIFY)
    test_cmd=$(cfg AGENT_CMD_TEST)
    if ((full)) && [[ -n $test_cmd ]]; then
        printf 'test\t%s\n' "$test_cmd"
    elif [[ -n $verify_cmd ]]; then
        printf 'verify\t%s\n' "$verify_cmd"
    elif [[ -n $test_cmd ]]; then
        printf 'test\t%s\n' "$test_cmd"
    fi
}

cmd_main() {
    local full=0 name command dir changed path out="" rc=0 skipped whole uncovered=() owned areas cached=0
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
    whole=$(verify_whole "$full")
    areas=$(verify_areas "$changed")
    if [[ -n $whole ]] && ((full || ${#suites[@]} == 0)); then
        if ((!full)) && verify_whole_cached "${whole#*$'\t'}" "$areas"; then
            # A re-verify after review fixes re-ran a 12-minute whole check for the same areas in a field run;
            # CI repeats it on every push anyway.
            out+="cached ${whole%%$'\t'*}: passed earlier for these areas ($(paste -sd, - <<<"$areas"))"$'\n'
            cached=1
        elif out+=$(run_logged "${whole%%$'\t'*}" "${whole#*$'\t'}")$'\n'; then
            printf '%s\n%s\n' "${whole#*$'\t'}" "$areas" >"$(ak_dir)/verify-whole"
            ran+=("${whole%%$'\t'*}.log")
        else
            rc=1
            rm -f -- "$(ak_dir)/verify-whole"
            ran+=("${whole%%$'\t'*}.log")
        fi
    fi
    for name in "${suites[@]}"; do
        dir=$(cfg "AGENT_RUNDIR_$name")
        out+=$(run_logged "${name,,}" "$(cfg "AGENT_CMD_$name")" "${dir:-.}")$'\n' || rc=1
        ran+=("${name,,}.log")
    done
    if ((${#ran[@]} == 0 && !cached)); then
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
    if [[ -n $skipped ]] || ((cached || (${#suites[@]} > 0 && !full))); then printf 'oracle=ci\n'; fi
    return "$rc"
}
