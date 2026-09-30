# shellcheck shell=bash
# ak verify: the repo's own check, then every declared suite whose rundir holds a changed path.

# Paths changed against origin/<base>, committed or not.
verify_changed_paths() {
    local base
    base=$(base_branch)
    {
        git diff --name-only "origin/$base...HEAD" 2>/dev/null || true
        git diff --name-only HEAD
        git ls-files --others --exclude-standard
    } | LC_ALL=C sort -u
}

# Every NAME with an AGENT_CMD_NAME in the environment or config, minus the primary and fix commands.
verify_extra_names() {
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

# verify_touches RUNDIR: does any changed path live under RUNDIR?
verify_touches() {
    local dir=${1%/} changed=$2 path
    [[ $dir != . && -n $dir ]] || return 0
    while IFS= read -r path; do
        [[ $path == "$dir"/* ]] && return 0
    done <<<"$changed"
    return 1
}

verify_skips() {
    local logs=$1
    shift
    (($# == 0)) && return 0
    (cd -- "$logs" && cat -- "$@") | sed -nE 's/^SKIP ([^ ]+).*/\1/p' | LC_ALL=C sort -u | paste -sd, -
}

cmd_main() {
    (($# == 0)) || usage_die "verify takes no arguments"
    local primary name command dir changed out="" rc=0 skipped
    local -a ran=()
    cd -- "$(worktree_root)" || exit 1
    if primary=$(cfg AGENT_CMD_VERIFY) && [[ -n $primary ]]; then
        name=verify
    elif primary=$(cfg AGENT_CMD_TEST) && [[ -n $primary ]]; then
        name='test'
    fi
    if [[ -n $primary ]]; then
        out+=$(run_logged "$name" "$primary")$'\n' || rc=1
        ran+=("$name.log")
    fi
    changed=$(verify_changed_paths)
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        dir=$(cfg "AGENT_RUNDIR_$name")
        command=$(cfg "AGENT_CMD_$name")
        if [[ -z $dir || -z $command ]] || ! verify_touches "$dir" "$changed"; then continue; fi
        name=${name,,}
        out+=$(run_logged "$name" "$command")$'\n' || rc=1
        ran+=("$name.log")
    done < <(verify_extra_names)
    if ((${#ran[@]} == 0)); then
        printf 'verify=none oracle=ci\n'
        return 0
    fi
    skipped=$(verify_skips "$(ak_dir)/logs" "${ran[@]}")
    ((rc)) && printf 'verify=fail\n' || printf 'verify=pass\n'
    printf '%s' "$out"
    [[ -z $skipped ]] || printf 'skipped=%s\n' "$skipped"
    [[ -z $skipped && -n $primary ]] || printf 'oracle=ci\n'
    return "$rc"
}
