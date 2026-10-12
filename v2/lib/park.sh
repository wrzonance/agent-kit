# shellcheck shell=bash
# ak park --reason TEXT: nothing in this issue fits this worktree; leave a result that says why. No GitHub calls.

cmd_main() {
    local reason="" dir
    [[ ${1:-} == --reason && -n ${2:-} && $# == 2 ]] || usage_die "usage: ak park --reason TEXT"
    reason=${2//$'\n'/ }
    cd -- "$(worktree_root)" || exit 1
    dir=$(ak_dir)
    # A worker parked on its own red test without running ak verify; only setup.log and push.log existed.
    compgen -G "$dir/logs/*.log" | grep -qvE '/(setup|push)\.log$' \
        || die "nothing verified yet: a red test of your own is a fix, not a park reason" "ak verify, fix what it prints, then ak park --reason \"…\" only for what this worktree cannot do"
    printf 'pr=none\nci=none\nreview=skipped\nhead=%s\nnote=parked: %s\n' "$(git rev-parse HEAD)" "$reason" >"$dir/result"
    # The marker keeps the park time after a worker resumed in place removes the result (ak plan reads it).
    : >"$dir/parked"
    paste -sd' ' "$dir/result"
}
