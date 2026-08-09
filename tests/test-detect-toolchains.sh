#!/usr/bin/env bash
# Suite: detect-toolchains.sh component discovery, suggestion generation, and
# drift detection.
set -uo pipefail

TEST_NAME='detect-toolchains'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

dt_sh="$root/agentkit/skills/.shared/scripts/detect-toolchains.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

new_repo() { mktemp -d "$tmp/repo.XXXXXX"; }

# A PATH holding only the binaries detect-toolchains.sh itself needs, and
# deliberately never `uv` -- this is what makes the "no .venv, no uv" fallback
# assertion hold on any machine, including ones with uv installed globally.
make_restricted_path() {
    local dir="$tmp/restricted-bin" bin p
    [[ -d $dir ]] && printf '%s' "$dir" && return 0
    mkdir -p "$dir"
    for bin in env bash find dirname basename sort cut cat grep; do
        p=$(command -v "$bin") || continue
        ln -sf "$p" "$dir/$bin"
    done
    printf '%s' "$dir"
}

# --- node: runner comes from the lockfile in the same directory ------------
repo=$(new_repo)
printf '{}' > "$repo/package.json"
printf '' > "$repo/pnpm-lock.yaml"
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'lang=node marker=package.json runner=pnpm' \
    'a pnpm-lock.yaml repo would get told to run npm without this'

repo=$(new_repo)
printf '{}' > "$repo/package.json"
printf '' > "$repo/yarn.lock"
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'lang=node marker=package.json runner=yarn' \
    'a yarn.lock repo resolves to the yarn runner'

repo=$(new_repo)
printf '{}' > "$repo/package.json"
printf '' > "$repo/bun.lockb"
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'lang=node marker=package.json runner=bun' \
    'a bun.lockb repo resolves to the bun runner'

repo=$(new_repo)
printf '{}' > "$repo/package.json"
printf '' > "$repo/package-lock.json"
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'lang=node marker=package.json runner=npm' \
    'a package-lock.json repo resolves to the npm runner'

repo=$(new_repo)
printf '{}' > "$repo/package.json"
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'component= path=. lang=node marker=package.json runner=npm' \
    'a node package with no lockfile and no ancestor falls back to npm, not silence'

# --- python: .venv present vs. absent ---------------------------------------
repo=$(new_repo)
printf '' > "$repo/pyproject.toml"
mkdir -p "$repo/.venv/bin"
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'lang=python marker=pyproject.toml runner=.venv/bin' \
    'a component with an installed .venv must be told to run its own venv binaries, not a bare tool name'

repo=$(new_repo)
printf '' > "$repo/pyproject.toml"
restricted=$(make_restricted_path)
out=$(PATH="$restricted" "$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'lang=python marker=pyproject.toml runner=python3 -m' \
    'with no .venv and no uv on PATH, the runner falls back to python3 -m rather than guessing a name that will not resolve'

# --- dotnet / go / rust ------------------------------------------------------
repo=$(new_repo)
printf '' > "$repo/App.csproj"
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'lang=dotnet marker=App.csproj runner=dotnet' \
    'a .csproj marks a dotnet component with the dotnet runner'

repo=$(new_repo)
printf '' > "$repo/go.mod"
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'lang=go marker=go.mod runner=go' \
    'a go.mod marks a go component with the go runner'

repo=$(new_repo)
printf '' > "$repo/Cargo.toml"
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'lang=rust marker=Cargo.toml runner=cargo' \
    'a Cargo.toml marks a rust component with the cargo runner'

# --- markdown: config-only repository ----------------------------------------
repo=$(new_repo)
printf '{}' > "$repo/.markdownlintrc"
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'lang=markdown marker=.markdownlintrc runner=none' \
    'a .markdownlint config alone is definitive evidence, no linter or README count needed'

# --- monorepo: independent components each get their own prefix + rundir ----
repo=$(new_repo)
mkdir -p "$repo/server/.venv/bin" "$repo/dashboard"
printf '' > "$repo/server/pyproject.toml"
printf '#!/bin/sh\n' > "$repo/server/.venv/bin/pytest"
chmod +x "$repo/server/.venv/bin/pytest"
cat > "$repo/dashboard/package.json" << 'EOF'
{"scripts": {"test": "jest", "lint": "eslint ."}}
EOF
printf '' > "$repo/dashboard/package-lock.json"

comp_out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$comp_out" 'path=server lang=python' \
    'the python component under server/ is found by its own marker, independent of the repo root'
assert_contains "$comp_out" 'path=dashboard lang=node marker=package.json runner=npm' \
    'the node component under dashboard/ resolves its own lockfile independent of server/'

sugg_out=$("$dt_sh" --repo-root "$repo" --format suggestions)
assert_contains "$sugg_out" 'AGENT_CMD_SERVER_TEST=server/.venv/bin/pytest' \
    'the server test command is prefixed by its own component name, not confused with the root'
assert_contains "$sugg_out" 'AGENT_RUNDIR_SERVER_TEST=server' \
    'a python command under server/ must declare its own rundir or it runs from the repo root by accident'
assert_contains "$sugg_out" 'AGENT_CMD_DASHBOARD_TEST=npm test' \
    'the dashboard test command names its own npm script'
assert_contains "$sugg_out" 'AGENT_RUNDIR_DASHBOARD_TEST=dashboard' \
    'a node command under dashboard/ must declare its own rundir or it globs into the wrong package.json'

# --- excluded directories: node_modules, .venv, dashboard/.next -------------
repo=$(new_repo)
printf '' > "$repo/go.mod"
mkdir -p "$repo/node_modules" "$repo/.venv" "$repo/dashboard/.next"
printf '{}' > "$repo/node_modules/package.json"
printf '' > "$repo/.venv/pyproject.toml"
printf '{}' > "$repo/dashboard/.next/package.json"
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_contains "$out" 'lang=go' \
    'a real component elsewhere in the tree must still be reported despite the excluded dirs nearby'
assert_not_contains "$out" 'node_modules' \
    'a package.json inside node_modules is a dependency, not a component -- reporting it would get it declared and committed'
assert_not_contains "$out" '.venv/pyproject' \
    'a pyproject.toml inside .venv is the installed venv, not a component'
assert_not_contains "$out" '.next' \
    'dashboard/.next/package.json is a build artifact; reporting it is the phantom this exclusion list exists to prevent'

# --- suggestions never emit a live, uncommented key --------------------------
bad_lines=$(printf '%s\n' "$sugg_out" | grep -E '^AGENT_' || true)
assert_eq '' "$bad_lines" \
    'every suggested AGENT_CMD_/AGENT_RUNDIR_ line must stay commented -- an uncommented one is a command nobody has run, live in the repo'

# --- drift: a moved component is reported with its new candidate ------------
repo=$(new_repo)
mkdir -p "$repo/.agent" "$repo/services/backend"
printf '' > "$repo/services/backend/pyproject.toml"
printf 'AGENT_RUNDIR_BACKEND_TEST=backend\n' > "$repo/.agent/config.env"
out=$("$dt_sh" --repo-root "$repo" --format drift)
assert_contains "$out" 'drift= key=AGENT_RUNDIR_BACKEND_TEST declared=backend status=missing candidate=services/backend' \
    'a moved component must be found again by its marker file, or a command silently starts failing with "no such file" instead of "the directory moved"'

# --- drift: silence when every declared path still resolves -----------------
repo=$(new_repo)
mkdir -p "$repo/.agent" "$repo/backend"
printf '' > "$repo/backend/pyproject.toml"
printf 'AGENT_RUNDIR_BACKEND_TEST=backend\n' > "$repo/.agent/config.env"
out=$("$dt_sh" --repo-root "$repo" --format drift)
assert_eq '' "$out" \
    'nothing moved, so drift must print nothing -- noise here trains a human to stop reading it'
assert_rc 0 'a clean drift check still exits 0' -- "$dt_sh" --repo-root "$repo" --format drift

# --- a non-directory --repo-root is a hard failure, not a silent no-op ------
assert_rc 3 '--repo-root pointing at a file, not a directory, must exit 3 rather than silently scan the wrong thing' \
    -- "$dt_sh" --repo-root "$tmp/no-such-directory" --format components

# --- regressions the live repositories exposed -----------------------------

# `npm lint` is not a command: npm needs `run` for anything that is not one of
# its own subcommands. Emitted bare, the suggestion declares something that
# cannot execute -- and the rule is that nothing is declared until it has passed.
repo=$(mktemp -d "$tmp/npmrun.XXXXXX")
printf '{"scripts":{"test":"x","lint":"y"}}' > "$repo/package.json"
out=$("$dt_sh" --repo-root "$repo" --format suggestions)
assert_contains "$out" 'AGENT_CMD_LINT=npm run lint' 'npm gets run for a package script'
assert_contains "$out" 'AGENT_CMD_TEST=npm test' 'but not for its own subcommand'

printf '' > "$repo/pnpm-lock.yaml"
out=$("$dt_sh" --repo-root "$repo" --format suggestions)
assert_contains "$out" 'AGENT_CMD_LINT=pnpm lint' 'another runner takes the bare form'

# An existing entry point answers the question before any per-language guess.
# The rewrite that added language detection dropped this, so a repository with
# tools/verify -- the shape this project recommends -- stopped being offered it.
repo=$(mktemp -d "$tmp/dispatch.XXXXXX")
mkdir -p "$repo/tools"
printf '#!/bin/sh\n' > "$repo/tools/verify"
chmod +x "$repo/tools/verify"
printf '{"scripts":{"test":"x"}}' > "$repo/package.json"
out=$("$dt_sh" --repo-root "$repo" --format suggestions)
assert_contains "$out" 'AGENT_CMD_VERIFY=tools/verify' 'a bespoke dispatcher is offered'
assert_contains "$out" 'entry point' 'and marked as outranking the guesses'

repo=$(mktemp -d "$tmp/mk.XXXXXX")
printf 'test:\n\techo hi\nlint:\n\techo hi\n' > "$repo/Makefile"
out=$("$dt_sh" --repo-root "$repo" --format suggestions)
assert_contains "$out" 'AGENT_CMD_TEST=make test' 'Makefile targets are offered'

# Two components at one path each proposing the same key is a duplicate entry in
# a committed file. Auxiliary languages are repo-wide and suffix their task.
repo=$(mktemp -d "$tmp/collide.XXXXXX")
printf '{"scripts":{"lint":"eslint ."}}' > "$repo/package.json"
printf '#!/usr/bin/env bash\necho hi\n' > "$repo/build.sh"
git -C "$repo" init -q
git -C "$repo" add -A > /dev/null 2>&1
out=$("$dt_sh" --repo-root "$repo" --format suggestions)
dupes=$(grep -oE '^# AGENT_CMD_[A-Z0-9_]+' <<< "$out" | sort | uniq -d)
assert_eq '' "$dupes" 'no suggested key is proposed twice'

# And an auxiliary language is reported once for the repository, not beside
# every component that happens to contain a script.
repo=$(mktemp -d "$tmp/auxonce.XXXXXX")
mkdir -p "$repo/a" "$repo/b"
printf '#!/usr/bin/env bash\n' > "$repo/a/x.sh"
printf '#!/usr/bin/env bash\n' > "$repo/b/y.sh"
# Shell components are found among TRACKED files, so the fixture has to be a
# repository with them staged -- an untracked script is not part of the project.
git -C "$repo" init -q
git -C "$repo" add -A > /dev/null 2>&1
out=$("$dt_sh" --repo-root "$repo" --format components)
assert_eq '1' "$(grep -c 'lang=shell' <<< "$out" || true)" 'shell is reported once for the repository'

finish
