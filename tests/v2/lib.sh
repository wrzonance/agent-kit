# shellcheck shell=bash
# Shared setup for the v2 suites: assertions, the fake gh on PATH, and a fixture repository.
V2_TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$V2_TESTS/../.." && pwd)
export AK="$REPO/v2/bin/ak"
# shellcheck source=../lib/assert.sh
source "$REPO/tests/lib/assert.sh"

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export PATH="$V2_TESTS/stub:$PATH"
export FAKE_GH_LOG="$WORK/gh.log" FAKE_GH_ROUTES="$WORK/routes"
: >"$FAKE_GH_LOG"
: >"$FAKE_GH_ROUTES"
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_HOME CODEX_SANDBOX_NETWORK_DISABLED CODEX_PERMISSION_PROFILE CODEX_THREAD_ID
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# route PATTERN [BODY] [EXIT]: answer gh calls whose joined args match PATTERN.
route() {
    local file="$WORK/response.$RANDOM$RANDOM"
    printf '%s' "${2:-}" >"$file"
    printf '%s\t%s\t%s\n' "$1" "$file" "${3:-0}" >>"$FAKE_GH_ROUTES"
}

# fixture_repo: a clone at $WORK/repo with a bare origin, one commit on main, origin/HEAD set. Echoes the path.
fixture_repo() {
    git init -q --bare -b main "$WORK/origin.git"
    git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
    (
        cd "$WORK/repo" || exit 1
        mkdir -p src .agent
        printf 'one\n' >src/a.txt
        printf 'AGENT_REPO_SLUG=acme/widget\n' >.agent/config.env
        printf '.agent/\n' >.gitignore
        git add src .gitignore && git commit -q -m init && git push -q origin main
        git remote set-head origin main
    )
    printf '%s\n' "$WORK/repo"
}
