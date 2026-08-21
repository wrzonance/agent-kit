#!/usr/bin/env bash
# Suite: compose-worker-prompt.sh scopes the declared-command list to the
# dispatch write set and emits dispatcher-only prose conditionally (issue #336).
# shellcheck disable=SC2016  # literal $worktree / $shared text is assertion data
set -uo pipefail

TEST_NAME='compose-worker-prompt-scope'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

compose="$root/agentkit/skills/parallel-issues/scripts/compose-worker-prompt.sh"
template="$root/agentkit/skills/parallel-issues/references/worker-prompts.md"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

contract=$'skills= path='"$root"$'/agentkit/skills\nharness= name=codex trailer="Codex <noreply@openai.com>"'

# make_repo DIR CONFIG_LINE... -- a fixture worktree with every artifact pair.
make_repo() {
    local dir=$1
    shift
    mkdir -p "$dir/.agent"
    git -C "$dir" init -q
    printf '%s\n' 'AGENT_REPO_SLUG=example-org/mono' 'AGENT_BASE_BRANCH=main' "$@" > "$dir/.agent/config.env"
    printf '%s\n' "$contract" > "$dir/.agent/env-contract.txt"
    printf 'SPEC-BYTES\n' > "$dir/.agent/fenced-spec.txt"
    printf 'PRIOR-BYTES\n' > "$dir/.agent/fenced-prior-art.txt"
    printf 'TRUSTED-SPEC-BYTES\n' > "$dir/.agent/spec.txt"
    printf 'TRUSTED-PRIOR-BYTES\n' > "$dir/.agent/prior-art.txt"
}

compose_lead() { # DIR WRITE_SET_GLOB...
    local dir=$1 args=()
    shift
    local glob
    for glob in "$@"; do args+=(--write-set "$glob"); done
    bash "$compose" --template issue-lead --boundary yolo-trusted --worktree "$dir" \
        --issue 42 --branch feat/issue-42 --worker-model gpt-5.6-luna --worker-effort high "${args[@]}"
}

compose_fix_batch() { # DIR
    bash "$compose" --template fix-batch --worktree "$1" --issue 42 --branch feat/issue-42 \
        --worker-model gpt-5.6-luna --worker-effort high
}

command_lines() { printf '%s\n' "$1" | grep -E 'agent-run\.sh.*--cmd'; }

# --- the write-set scope filter -------------------------------------------
# Fixture B: a monorepo with per-component rundirs, dispatched for a
# frontend-only write set. Repo-wide gates (no AGENT_RUNDIR_*) always stay;
# commands whose declared rundir cannot intersect the write set are dropped
# from the runnable list and DISCLOSED instead -- named, explained, and
# explicitly still runnable at the worker's judgement.
mono_declarations=(
    'AGENT_CMD_VERIFY=tools/verify' 'AGENT_CMD_TEST=tools/test'
    'AGENT_CMD_FRONTEND_TEST=npm test' 'AGENT_RUNDIR_FRONTEND_TEST=frontend'
    'AGENT_CMD_FRONTEND_LINT=npm run lint' 'AGENT_RUNDIR_FRONTEND_LINT=frontend'
    'AGENT_CMD_BACKEND_TEST=dotnet test' 'AGENT_RUNDIR_BACKEND_TEST=backend'
    'AGENT_CMD_BACKEND_BUILD=dotnet build' 'AGENT_RUNDIR_BACKEND_BUILD=backend'
    'AGENT_CMD_SERVER_TEST=go test ./...' 'AGENT_RUNDIR_SERVER_TEST=server'
    'AGENT_CMD_SERVER_BUILD=go build ./...' 'AGENT_RUNDIR_SERVER_BUILD=server'
    'AGENT_CMD_TEST_FOCUS=tools/test --only %s'
)
mono="$tmp/mono"
make_repo "$mono" "${mono_declarations[@]}"
mkdir -p "$mono/frontend" "$mono/backend" "$mono/server"

frontend_prompt=$(compose_lead "$mono" 'frontend/src/**')
frontend_commands=$(command_lines "$frontend_prompt")
assert_contains "$frontend_commands" '--cmd verify' 'a repo-wide verify gate survives a frontend-only write set'
assert_contains "$frontend_commands" '--cmd test ' 'a repo-wide test gate survives a frontend-only write set'
assert_contains "$frontend_commands" '--cmd frontend-test' 'a command whose rundir intersects the write set is emitted'
assert_contains "$frontend_commands" '--cmd frontend-lint' 'every in-scope component command is emitted'
assert_not_contains "$frontend_commands" '--cmd backend-test' 'a backend test command is absent from a frontend-only dispatch'
assert_not_contains "$frontend_commands" '--cmd backend-build' 'a backend build command is absent from a frontend-only dispatch'
assert_not_contains "$frontend_commands" '--cmd server-test' 'a server test command is absent from a frontend-only dispatch'
assert_not_contains "$frontend_commands" '--cmd server-build' 'a server build command is absent from a frontend-only dispatch'
assert_contains "$frontend_prompt" 'Also declared, but withheld from the list above' 'the prompt states that a filter was applied'
assert_contains "$frontend_prompt" 'backend-test (rundir backend)' 'a dropped command is named with its rundir so the worker knows it exists'
assert_contains "$frontend_prompt" 'server-build (rundir server)' 'every dropped command is named'

# --- regression pin: a rundir is a LOCATION fact, never a coverage boundary --
# A `shared/**` dispatch drops a suite declared in `frontend/` even when the
# frontend imports the changed shared code. Withholding the recipe is fine;
# telling the worker not to run it hides exactly the regression the heuristic
# cannot see. The disclosure must name the command AND leave the call open.
assert_not_contains "$frontend_prompt" 'do not run them' \
    'a withheld command is disclosed, never forbidden'
assert_contains "$frontend_prompt" 'LOCATION heuristic, not a coverage guarantee' \
    'the disclosure says a rundir does not bound coverage'
assert_contains "$frontend_prompt" 'Run one anyway when your change can reach it' \
    'the worker is told to run a withheld command when the change reaches it'
assert_contains "$frontend_prompt" 'shared or library code can break a dependent component' \
    'the disclosure names the shared-code case the heuristic is blindest to'

# The hazard shape needs a rundir-less repo-wide gate present: without one,
# every command drops and the fail-open fallback already lists them all. WITH
# one, `verify` survives, the component suites are withheld, and the withheld
# text is the only thing standing between the worker and an untested dependent.
shared_dep="$tmp/shared-dep"
make_repo "$shared_dep" 'AGENT_CMD_VERIFY=tools/verify' \
    'AGENT_CMD_FRONTEND_TEST=npm test' 'AGENT_RUNDIR_FRONTEND_TEST=frontend' \
    'AGENT_CMD_BACKEND_TEST=dotnet test' 'AGENT_RUNDIR_BACKEND_TEST=backend'
mkdir -p "$shared_dep/frontend" "$shared_dep/backend" "$shared_dep/shared"
shared_prompt=$(compose_lead "$shared_dep" 'shared/**')
assert_contains "$(command_lines "$shared_prompt")" '--cmd verify' \
    'the repo-wide gate survives a shared/** dispatch'
assert_not_contains "$(command_lines "$shared_prompt")" '--cmd frontend-test' \
    'the component suite is withheld from the runnable list, as the filter intends'
assert_contains "$shared_prompt" 'frontend-test (rundir frontend)' \
    'a dependent component suite dropped by a shared/** dispatch is still named'
assert_not_contains "$shared_prompt" 'do not run them' \
    'a shared/** dispatch is never told to skip a dependent component suite'
assert_contains "$shared_prompt" 'Run one anyway when your change can reach it' \
    'a shared/** dispatch is told the withheld dependent suite remains its call'
assert_not_contains "$frontend_prompt" '__DECLARED_COMMANDS__' 'the command token never survives composition'

# A write set that reaches every component keeps every command and states no filter.
wide_prompt=$(compose_lead "$mono" '**')
wide_commands=$(command_lines "$wide_prompt")
for name in verify test frontend-test frontend-lint backend-test backend-build server-test server-build; do
    assert_contains "$wide_commands" "--cmd $name" "a repo-wide write set keeps --cmd $name"
done
assert_not_contains "$wide_prompt" 'withheld from the list above' 'no filter statement renders when nothing was dropped'

# A glob whose literal prefix is a parent of the rundir, or a child of it, intersects.
parent_prompt=$(compose_lead "$mono" 'backend/api/*.cs' 'docs/*.md')
parent_commands=$(command_lines "$parent_prompt")
assert_contains "$parent_commands" '--cmd backend-test' 'a glob below the rundir keeps that component'
assert_not_contains "$parent_commands" '--cmd frontend-test' 'an unrelated component is still dropped'
assert_contains "$parent_commands" '--cmd verify' 'repo-wide gates are unaffected by component globs'

# A metacharacter that cuts a path component is not a component prefix: keep
# conservatively rather than guess.
partial_prompt=$(compose_lead "$mono" 'front*/**')
assert_contains "$(command_lines "$partial_prompt")" '--cmd backend-test' \
    'an ambiguous literal prefix keeps every command rather than guessing'

# Fail OPEN, never closed: a write set that intersects no declared component
# still composes with the full list. Refusing would turn a legitimate
# docs-only dispatch in a componentised monorepo into a blocker.
componentised="$tmp/componentised"
make_repo "$componentised" 'AGENT_CMD_FRONTEND_TEST=npm test' 'AGENT_RUNDIR_FRONTEND_TEST=frontend' \
    'AGENT_CMD_BACKEND_TEST=dotnet test' 'AGENT_RUNDIR_BACKEND_TEST=backend'
mkdir -p "$componentised/frontend" "$componentised/backend"
docs_prompt=$(compose_lead "$componentised" 'docs/*.md')
docs_commands=$(command_lines "$docs_prompt")
assert_contains "$docs_commands" '--cmd frontend-test' \
    'a write set intersecting no component keeps every command rather than refusing'
assert_contains "$docs_commands" '--cmd backend-test' \
    'the unfiltered fallback keeps every declared command'
assert_contains "$docs_prompt" 'No declared command rundir intersects this write set' \
    'the fallback states why the list is unfiltered'
assert_not_contains "$docs_prompt" 'withheld from the list above' \
    'the fallback does not also claim commands were dropped'

# fix-batch carries no write set, so it is never filtered.
fix_prompt=$(compose_fix_batch "$mono")
fix_commands=$(command_lines "$fix_prompt")
for name in verify test frontend-test backend-test server-build; do
    assert_contains "$fix_commands" "--cmd $name" "fix-batch keeps --cmd $name unfiltered"
done
assert_not_contains "$fix_prompt" 'withheld from the list above' 'fix-batch states no filter'

# --- the focused selector follows the SCOPED test command (CodeRabbit F1) ---
# focus_declared is read from the FULL declaration list, but `--cmd test --only`
# selects ONE command, and the write-set filter may have scoped that command
# out. Emitting the selector anyway points the worker at a suite this dispatch
# has no business running -- and when that suite drives Compose, it does so
# without the isolation prose, because compose_reachable only inspects scoped
# commands. That pair is the sibling-worktree collision the isolation reference
# exists to prevent, so the selector and the Compose decision must agree.
focus_out="$tmp/focus-scoped-out"
make_repo "$focus_out" 'AGENT_CMD_VERIFY=tools/verify' \
    'AGENT_CMD_TEST=docker compose run --rm tests' 'AGENT_RUNDIR_TEST=backend' \
    'AGENT_CMD_TEST_FOCUS=tools/focused --only %s'
mkdir -p "$focus_out/backend" "$focus_out/frontend"
focus_out_prompt=$(compose_lead "$focus_out" 'frontend/src/**')
# Match the emitted COMMAND LINES, not the whole prompt: the explanatory
# sentence legitimately names the `--cmd test --only` flag it is declining to
# offer, and a whole-prompt match would read that mention as the offer itself.
assert_not_contains "$(command_lines "$focus_out_prompt")" '--only' \
    'no runnable focused selector is emitted when the test command it selects is scoped out'
assert_not_contains "$focus_out_prompt" "--cmd test --only 'NAME[,NAME...]'" \
    'the focused selector recipe is absent when its test command is scoped out'
assert_not_contains "$(command_lines "$focus_out_prompt")" '--cmd test ' \
    'the scoped-out test command is not in the runnable list either'
assert_contains "$focus_out_prompt" 'A focused selector is declared, but the test command it selects' \
    'the prose distinguishes scoped-out from never-declared'
assert_not_contains "$focus_out_prompt" 'No focused selector is declared' \
    'a scoped-out test command never masquerades as a repository with no selector'
assert_contains "$focus_out_prompt" 'test (rundir backend)' \
    'the scoped-out test command is still disclosed by name'
# The coherent pair: no selector for it, and no Compose prose for it either.
assert_not_contains "$focus_out_prompt" 'AGENT_COMPOSE_SERIALIZED=1' \
    'a scoped-out Compose test command brings no isolation prose, matching the withheld selector'

# The same repository with a write set that DOES reach the test command keeps
# both halves: the focused selector and the Compose-isolation prose.
focus_in_prompt=$(compose_lead "$focus_out" 'backend/**')
assert_contains "$focus_in_prompt" "--cmd test --only 'NAME[,NAME...]'" \
    'an in-scope test command still offers the focused selector'
assert_contains "$focus_in_prompt" 'AGENT_COMPOSE_SERIALIZED=1' \
    'an in-scope Compose test command still brings the isolation prose'
assert_not_contains "$focus_in_prompt" 'A focused selector is declared, but' \
    'the scoped-out explanation does not render when the command is in scope'

# A repository with no AGENT_CMD_TEST resolves `test` through its runner, so
# there is no per-command rundir to scope by and the selector must survive.
runner_focus="$tmp/runner-focus"
make_repo "$runner_focus" 'AGENT_CMD_VERIFY=tools/verify' 'AGENT_CMD_TEST_FOCUS=tools/focused --only %s'
mkdir -p "$runner_focus/tools"
printf '#!/usr/bin/env bash\n' > "$runner_focus/tools/run"
chmod +x "$runner_focus/tools/run"
printf 'tools/run\n' > "$runner_focus/.agent/runner"
runner_focus_prompt=$(compose_lead "$runner_focus" 'src/**')
assert_contains "$runner_focus_prompt" "--cmd test --only 'NAME[,NAME...]'" \
    'a runner-resolved test command is never treated as scoped out'

# --- Compose-isolation prose is conditional ---------------------------------
compose_phrase='AGENT_COMPOSE_SERIALIZED=1'
assert_not_contains "$frontend_prompt" "$compose_phrase" \
    'a repository with no Compose-using command gets no Compose-isolation prose (issue lead)'
assert_not_contains "$frontend_prompt" 'COMPOSE_PROJECT_NAME' \
    'a repository with no Compose-using command never hears about the Compose project variable'
assert_not_contains "$fix_prompt" "$compose_phrase" \
    'a repository with no Compose-using command gets no Compose-isolation prose (fix-batch)'
assert_not_contains "$frontend_prompt" '__COMPOSE_ISOLATION__' 'the Compose token never survives composition'

composed="$tmp/composed"
make_repo "$composed" 'AGENT_CMD_TEST=docker compose run --rm tests' 'AGENT_CMD_LINT=tools/lint'
composed_prompt=$(compose_lead "$composed" 'src/**')
assert_contains "$composed_prompt" "$compose_phrase" \
    'a declared `docker compose` test command brings the Compose-isolation prose (issue lead)'
assert_contains "$composed_prompt" 'COMPOSE_PROJECT_NAME' \
    'the Compose prose names the per-worktree project variable'
assert_contains "$composed_prompt" 'environment-retry-eligible' \
    'the Compose prose classifies dependency-start collisions'
composed_fix=$(compose_fix_batch "$composed")
assert_contains "$composed_fix" "$compose_phrase" \
    'a declared `docker compose` test command brings the Compose-isolation prose (fix-batch)'

hyphen="$tmp/hyphen"
make_repo "$hyphen" 'AGENT_CMD_TEST=docker-compose run tests'
assert_contains "$(compose_lead "$hyphen" 'src/**')" "$compose_phrase" \
    'a declared docker-compose command is recognised as Compose-using'

# Compose reachability follows the in-scope list: a Compose command filtered out
# by the write set cannot collide, so its prose is not emitted either.
scoped_compose="$tmp/scoped-compose"
make_repo "$scoped_compose" 'AGENT_CMD_TEST=tools/test' \
    'AGENT_CMD_BACKEND_TEST=docker compose run tests' 'AGENT_RUNDIR_BACKEND_TEST=backend'
mkdir -p "$scoped_compose/backend"
assert_not_contains "$(compose_lead "$scoped_compose" 'frontend/**')" "$compose_phrase" \
    'an out-of-scope Compose command brings no Compose prose'
assert_contains "$(compose_lead "$scoped_compose" 'backend/**')" "$compose_phrase" \
    'an in-scope Compose command brings the Compose prose'

# --- image-invalidating writer list is conditional -------------------------
assert_contains "$frontend_prompt" 'verification stamps under .agent/cache/' \
    'the agent-run.sh writer bullet is always present (every emitted command runs through it)'
assert_not_contains "$frontend_prompt" 'session-start.sh' \
    'a root-side writer the dispatch never reaches is not listed'
assert_not_contains "$frontend_prompt" 'move-github-project-item.sh' \
    'a board-cache writer the dispatch never reaches is not listed'
assert_not_contains "$frontend_prompt" 'compose-pr-body.sh' \
    'a root-side composer the dispatch never reaches is not listed'
assert_not_contains "$frontend_prompt" '__IMAGE_INVALIDATING_WRITERS__' \
    'the writers token never survives composition'
assert_contains "$fix_prompt" 'verification stamps under .agent/cache/' \
    'fix-batch also keeps the agent-run.sh writer bullet'
assert_not_contains "$fix_prompt" 'session-start.sh' \
    'fix-batch also drops unreachable root-side writers'

reachable="$tmp/reachable"
make_repo "$reachable" 'AGENT_CMD_TEST=tools/test' 'AGENT_CMD_CHECK=tools/session-ledger.sh --verify'
reachable_prompt=$(compose_lead "$reachable" 'src/**')
assert_contains "$reachable_prompt" 'session-ledger.sh' \
    'a writer named by an in-scope declared command is listed as image-invalidating'
assert_not_contains "$reachable_prompt" 'session-start.sh' \
    'writers the declared commands do not name stay absent'

# --- dispatcher-only prose never reaches a worker --------------------------
for haystack_name in frontend_prompt composed_prompt fix_prompt; do
    haystack=${!haystack_name}
    assert_not_contains "$haystack" '--trust-trunk' "$haystack_name carries no --trust-trunk history"
    assert_not_contains "$haystack" 'fence-untrusted-data.sh' "$haystack_name carries no fence helper mechanics"
    assert_not_contains "$haystack" '128-bit' "$haystack_name carries no fence-token generation mechanics"
    assert_not_contains "$haystack" 'SPEC_BOUNDARY_TOKEN' "$haystack_name carries no token placeholder"
    assert_not_contains "$haystack" '| Mode | Selection | Rendering rule |' "$haystack_name carries no boundary selection table"
done
assert_not_contains "$(<"$template")" '--trust-trunk' \
    'the raw worker-prompt template mentions --trust-trunk zero times'

# --- regression: every rule a worker must follow still reaches it -----------
must_survive=(
    'Every path you stage must fall inside those globs'
    '## Branch Rules (MANDATORY'
    'git branch --show-current must print feat/issue-42'
    '## Required six-step loop (must be reported explicitly)'
    'SPIKE + REVERT'
    '## Progress, commit, and push'
    'worktree-commit.sh" --message'
    'git push -u origin feat/issue-42'
    '## True blockers'
    'worker_attribution=$('
    '**Filesystem scope:**'
    '**Ownership boundary:**'
    'NAMED LOG'
    'Before generating any patch, re-read the target file'
)
for rule in "${must_survive[@]}"; do
    assert_contains "$frontend_prompt" "$rule" "issue lead still receives: $rule"
done
for rule in '## Branch Rules (MANDATORY)' 'Spike + Revert, Invariants, then Implementation (TDD)' \
    'worktree-commit.sh"' 'Before generating any patch, re-read the target file' '## Exit Report'; do
    assert_contains "$fix_prompt" "$rule" "fix-batch still receives: $rule"
done

finish
