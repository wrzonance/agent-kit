# shellcheck shell=bash
# ak setup: run AGENT_CMD_SETUP once per worktree.

cmd_main() {
    (($# == 0)) || usage_die "setup takes no arguments"
    local command stamp
    command=$(cfg AGENT_CMD_SETUP)
    if [[ -z $command ]]; then
        printf 'setup=none\n'
        return 0
    fi
    stamp="$(ak_dir)/setup.ok"
    if [[ -f $stamp ]]; then
        printf 'setup=ok cached\n'
        return 0
    fi
    run_logged setup "$command" || exit 1
    : >"$stamp"
    printf 'setup=ok\n'
}
