# shellcheck shell=bash
# Shared helpers for every ak command. Sourced by bin/ak; never executed.

# A refusal is two lines: the cause, then the exact command that fixes it.
die() {
    printf 'ak: %s\n' "$1" >&2
    [[ -z ${2:-} ]] || printf 'fix: %s\n' "$2" >&2
    exit 1
}

usage_die() {
    printf 'ak: %s\n' "$1" >&2
    exit 2
}

# The worktree the command runs in.
worktree_root() {
    git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository" "cd into the repository"
}

# The main checkout, which owns .agent/config.env and .ak/runs, even from a linked worktree.
main_root() {
    local common
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
        die "not inside a git repository" "cd into the repository"
    dirname -- "$common"
}

# cfg KEY [DEFAULT]: environment first, then .agent/config.env, then DEFAULT. The file is parsed, never sourced.
cfg() {
    local key=$1 default=${2:-} file line value
    if [[ -n ${!key:-} ]]; then
        printf '%s\n' "${!key}"
        return 0
    fi
    file="$(main_root)/.agent/config.env"
    if [[ -f $file ]]; then
        line=$(grep -E "^${key}=" "$file" | tail -n 1 || true)
        if [[ -n $line ]]; then
            value=${line#*=}
            value=${value%$'\r'}
            if [[ $value == \"*\" || $value == \'*\' ]]; then
                value=${value:1:${#value}-2}
            fi
            [[ -z $value ]] || { printf '%s\n' "$value"; return 0; }
        fi
    fi
    printf '%s\n' "$default"
}

slug() {
    local value url
    value=$(cfg AGENT_REPO_SLUG)
    if [[ -z $value ]]; then
        url=$(git remote get-url origin 2>/dev/null) || die "no origin remote" "git remote add origin <url>"
        value=${url%.git}
        value=${value#*github.com[:/]}
    fi
    printf '%s\n' "$value"
}

base_branch() {
    local value
    value=$(cfg AGENT_BASE_BRANCH)
    if [[ -z $value ]]; then
        value=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
        value=${value#origin/}
    fi
    printf '%s\n' "${value:-main}"
}

# The innermost harness wins: a Codex shell sets CODEX_THREAD_ID, and may inherit CLAUDE* from a Claude session
# that launched it; the reverse inheritance is rare. Weaker hints only break the tie when neither marker is set.
harness() {
    if [[ -n ${CODEX_THREAD_ID:-} ]]; then
        printf 'codex\n'
    elif [[ -n ${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-} ]]; then
        printf 'claude\n'
    elif [[ -n ${CODEX_HOME:-}${CODEX_SANDBOX_NETWORK_DISABLED:-}${CODEX_PERMISSION_PROFILE:-} ]]; then
        printf 'codex\n'
    else
        printf 'unknown\n'
    fi
}

trailer() {
    case $(harness) in
        claude) printf 'Claude <noreply@anthropic.com>\n' ;;
        codex) printf 'Codex <noreply@openai.com>\n' ;;
        *) printf 'Agent <noreply@example.invalid>\n' ;;
    esac
}

# The per-worktree state directory, kept out of git through the shared info/exclude.
ak_dir() {
    local root dir exclude
    root=$(worktree_root)
    dir="$root/.ak"
    mkdir -p -- "$dir"
    exclude="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
    mkdir -p -- "$(dirname -- "$exclude")"
    grep -qxF '.ak/' "$exclude" 2>/dev/null || printf '.ak/\n' >>"$exclude"
    printf '%s\n' "$dir"
}

# run_logged NAME COMMAND [DIR]: run COMMAND in DIR (relative to the worktree), log it, print PASS or FAIL + tail.
# A command that runs for minutes shows a heartbeat (AK_HEARTBEAT seconds, default 20: below the ~30 s at which
# an agent's shell yields), so the agent sees it is alive instead of inspecting processes.
# run_progress PID LOG: ", now: <newest leaf process>, last: <last log line>", whichever exist.
run_progress() {
    local leaf=$1 kids now line
    while kids=$(pgrep -P "$leaf" 2>/dev/null) && [[ -n $kids ]]; do leaf=$(tail -n 1 <<<"$kids"); done
    # bash execs a final command in place, so the job's own pid may already be the running process.
    now=$(ps -o args= -p "$leaf" 2>/dev/null | cut -c1-80)
    [[ -z $now ]] || printf ', now: %s' "$now"
    line=$(tr -d '\r' <"$2" | awk 'NF { last = $0 } END { print last }' | cut -c1-100)
    [[ -z $line ]] || printf ', last: %s' "$line"
}

run_logged() {
    local name=$1 command=$2 dir=${3:-.} log rc=0 pid waited=0 beat=${AK_HEARTBEAT:-20}
    log="$(ak_dir)/logs/$name.log"
    mkdir -p -- "$(dirname -- "$log")"
    printf 'run %s: %s%s\n' "$name" "${command:0:100}" "$([[ $dir == . ]] || printf ' (in %s)' "$dir")"
    (cd -- "$(worktree_root)/$dir" && bash -c "$command") >"$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        ((waited % beat)) || printf '%s still running %ds%s (log %s)\n' "$name" "$waited" "$(run_progress "$pid" "$log")" "$log"
    done
    wait "$pid" || rc=$?
    if ((rc == 0)); then
        printf 'PASS %s\n' "$name"
    else
        printf 'FAIL %s rc=%d log=%s\n' "$name" "$rc" "$log"
        tail -n 12 -- "$log"
    fi
    return "$rc"
}

# The issue number this worktree works on, from its branch name (feat/issue-N) or .ak/issue.
issue_number() {
    local root branch
    root=$(worktree_root)
    if [[ -f $root/.ak/issue ]]; then
        cat -- "$root/.ak/issue"
        return 0
    fi
    branch=$(git -C "$root" branch --show-current)
    [[ $branch =~ issue-([0-9]+) ]] || die "cannot tell the issue from branch $branch" "echo N > .ak/issue"
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# The branch this worktree's work is diffed against: .ak/base (a PR worktree's own base, maybe another PR's branch), else base_branch.
work_base() {
    local file
    file="$(worktree_root)/.ak/base"
    if [[ -s $file ]]; then
        head -n 1 -- "$file"
    else
        base_branch
    fi
}

# The worker model: the first roster entry of the running harness's family, else its default.
worker_model() {
    local roster entry family
    family=$(harness)
    IFS=', ' read -ra roster <<<"$(cfg AGENT_WORKER_MODELS)"
    for entry in "${roster[@]}"; do
        [[ -n $entry ]] || continue
        case $family in
            codex) [[ ! $entry =~ ^(gpt-|o[0-9]) ]] || { printf '%s\n' "$entry"; return 0; } ;;
            claude) [[ $entry =~ ^(gpt-|o[0-9]) ]] || { printf '%s\n' "$entry"; return 0; } ;;
            *) printf '%s\n' "$entry"; return 0 ;;
        esac
    done
    if [[ $family == claude ]]; then printf 'sonnet\n'; else printf 'gpt-5.6-luna\n'; fi
}
