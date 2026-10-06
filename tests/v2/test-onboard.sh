#!/usr/bin/env bash
# ak onboard: writes the config keys ak reads from what the repository already says, and keeps what is there.
TEST_NAME=v2-onboard
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# linked_route BOARDS: answer the "boards linked to this repository" query with the JSON array BOARDS.
linked_route() {
    route 'api graphql*projectsV2(first*' "$(jq -c '{data: {repository: {projectsV2: {nodes: .}}}}' <<<"$1")"
}
FULL='[{"name":"Backlog"},{"name":"Ready"},{"name":"In progress"},{"name":"In review"},{"name":"Done"}]'
board() { jq -nc --argjson n "$1" --arg t "$2" --argjson o "${3:-$FULL}" '{number: $n, title: $t, closed: false, owner: {login: "acme"}, field: {options: $o}}'; }

repo=$(fixture_repo)
cd "$repo" || exit 1

# --- a Node repository linked to one board ---
printf '{"name":"widget","scripts":{"test":"jest"}}\n' >package.json
printf '{}\n' >package-lock.json
git add package.json package-lock.json && git commit -q -m node
linked_route "[$(board 4 'Widget board')]"
out=$("$AK" onboard 2>&1); rc=$?
assert_eq 0 "$rc" 'onboard exits 0'
assert_contains "$out" 'wrote=.agent/config.env keys=5 kept=1' 'onboard counts the keys it added and the ones it kept'
assert_contains "$out" $'\nAGENT_BASE_BRANCH=main\n' 'the base branch comes from origin/HEAD'
assert_contains "$out" $'\nAGENT_PROJECT_OWNER=acme\nAGENT_PROJECT_NUMBER=4\n' 'the one linked board is adopted'
assert_contains "$out" $'\nAGENT_CMD_SETUP=npm ci\nAGENT_CMD_TEST=npm test\n' 'the lockfile picks the package manager'
assert_contains "$out" 'board=4 "Widget board" status=Backlog,Ready,In progress,In review,Done' 'the board line names the Status options'
assert_contains "$out" $'\nnext=ak setup && ak verify --full' 'the next line proves the declared commands'
assert_not_contains "$out" 'AGENT_REPO_SLUG' 'a key already in the file is kept, not reprinted'
assert_eq 1 "$(grep -c '^AGENT_REPO_SLUG=' .agent/config.env)" 'the existing slug line survives once'
assert_eq 'npm test' "$(sed -n 's/^AGENT_CMD_TEST=//p' .agent/config.env)" 'the file carries the test command'
assert_eq 0 "$(grep -c '^fake gh' <<<"$out")" 'gh calls all had routes'
assert_eq 1 "$(grep -c 'api graphql' "$FAKE_GH_LOG")" 'the board costs one GraphQL read'
assert_rc 0 'onboard prints at most 20 lines' -- test "$(wc -l <<<"$out")" -le 20

before=$(cat .agent/config.env)
out=$("$AK" onboard 2>&1); rc=$?
assert_eq 0 "$rc" 'a second onboard exits 0'
assert_contains "$out" 'wrote=.agent/config.env keys=0 kept=6' 'a second onboard adds nothing'
assert_eq "$before" "$(cat .agent/config.env)" 'a second onboard leaves the file byte-identical'

# --- a bad flag ---
out=$("$AK" onboard --bogus 2>&1); rc=$?
assert_eq 2 "$rc" 'an unknown flag exits 2'

# --- a repository linked to two boards, then a chosen one ---
rm .agent/config.env
: >"$FAKE_GH_ROUTES"
linked_route "[$(board 4 'Widget board'),$(board 9 'Platform')]"
out=$("$AK" onboard 2>&1); rc=$?
assert_eq 0 "$rc" 'two linked boards still write the rest of the config'
assert_contains "$out" $'board=choose\n  4 Widget board\n  9 Platform\nfix: ak onboard --project N --owner acme' 'two boards are listed with the command that picks one'
assert_not_contains "$out" 'AGENT_PROJECT_NUMBER' 'no board is guessed'
route 'api graphql*projectV2(number*' "$(jq -c '{data: {repositoryOwner: {projectV2: .}}}' <<<"$(board 9 Platform '[{"name":"Todo"},{"name":"Ready"},{"name":"In progress"},{"name":"Done"}]')")"
out=$("$AK" onboard --project 9 --owner acme 2>&1); rc=$?
assert_eq 0 "$rc" 'a named board is adopted'
assert_contains "$out" $'\nAGENT_PROJECT_OWNER=acme\nAGENT_PROJECT_NUMBER=9\n' 'the named board is written'
assert_contains "$out" 'board=9 "Platform" status=Todo,Ready,In progress,Done' 'the chosen board line names its options'
assert_contains "$out" $'\nmissing-status=In review (ak board no-ops a move there)' 'a missing canonical column is named, not fatal'

# --- no linked board, no toolchain ---
rm .agent/config.env package.json package-lock.json
git rm -q package.json package-lock.json && git commit -q -m bare
: >"$FAKE_GH_ROUTES"
linked_route '[]'
out=$("$AK" onboard 2>&1); rc=$?
assert_eq 0 "$rc" 'nothing discovered still exits 0'
assert_contains "$out" 'board=none; ak plan reads AGENT_READY_LABEL=<label> instead, or name one: ak onboard --project N --owner O' 'no board names both ways forward'
assert_contains "$out" 'commands=none; append AGENT_CMD_TEST=<the command CI runs> to .agent/config.env' 'no toolchain asks for the CI command'
assert_contains "$out" $'\nnext=ak verify --full' 'with no setup, next is verify alone'
assert_not_contains "$out" $'\nAGENT_CMD_' 'no command is invented'

# --- a board read that fails is reported, not fatal ---
: >"$FAKE_GH_ROUTES"
route 'api graphql*projectsV2(first*' 'gh: Bad credentials (HTTP 401)' 1
out=$("$AK" onboard 2>&1); rc=$?
assert_eq 0 "$rc" 'a failed board read still writes the config'
assert_contains "$out" 'board=unavailable (gh: Bad credentials (HTTP 401)); fix: gh auth status' 'the board failure carries the gh error'

# --- Makefile wins; per-directory toolchains become suites ---
rm -f .agent/config.env
printf 'test:\n\ttrue\n' >Makefile
mkdir -p api web services/jobs
printf '[project]\nname="api"\n' >api/pyproject.toml && : >api/uv.lock
printf '{"scripts":{"test":"vitest"}}\n' >web/package.json && : >web/pnpm-lock.yaml
printf 'module jobs\n' >services/jobs/go.mod
mkdir -p tools/site && printf '{"name":"site"}\n' >tools/site/package.json && : >tools/site/package-lock.json
git add Makefile api web services tools && git commit -q -m mono
linked_route '[]'
out=$("$AK" onboard 2>&1); rc=$?
assert_eq 0 "$rc" 'a monorepo onboards'
assert_contains "$out" $'\nAGENT_CMD_TEST=make test\n' 'a Makefile test target is the whole check'
assert_contains "$out" $'\nAGENT_CMD_API=uv run pytest\nAGENT_RUNDIR_API=api\n' 'a uv project is a suite in its directory'
assert_contains "$out" $'\nAGENT_CMD_WEB=pnpm test\nAGENT_RUNDIR_WEB=web\n' 'a pnpm project is a suite in its directory'
assert_contains "$out" $'\nAGENT_CMD_SERVICES_JOBS=go test ./...\nAGENT_RUNDIR_SERVICES_JOBS=services/jobs\n' 'a nested go module is a suite named by its path'
assert_contains "$out" $'\nAGENT_CMD_SETUP=(cd api && uv sync) && (cd web && pnpm install --frozen-lockfile)\n' 'suite installs compose the setup when the root has none'
assert_not_contains "$out" 'tools/site' 'a package.json with no test script is neither a suite nor an install'
assert_eq "$(printf '%s\n' AGENT_BASE_BRANCH AGENT_CMD_API AGENT_CMD_SERVICES_JOBS AGENT_CMD_SETUP AGENT_CMD_TEST AGENT_CMD_WEB AGENT_REPO_SLUG AGENT_RUNDIR_API AGENT_RUNDIR_SERVICES_JOBS AGENT_RUNDIR_WEB)" \
    "$(grep -oE '^AGENT_[A-Z_]+' .agent/config.env | LC_ALL=C sort)" 'the file holds exactly the discovered keys'

# --- an untracked config is excluded from git; a tracked one is left alone ---
assert_rc 0 'an untracked .agent/ is ignored' -- git check-ignore -q .agent/config.env
rm .gitignore && git rm -q --cached .gitignore && git commit -q -m noignore
assert_rc 0 '.agent/ stays ignored through info/exclude' -- git check-ignore -q .agent/config.env

finish
