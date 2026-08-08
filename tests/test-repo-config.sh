#!/usr/bin/env bash
# Suite: repo-config.sh parsing, validation, and rejection behavior.
set -uo pipefail

TEST_NAME='repo-config'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

rc_sh="$root/agentkit/skills/.shared/scripts/repo-config.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Build a throwaway repo root holding one fixture as .agent/config.env.
make_repo() {
    local fixture=$1 dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    mkdir -p "$dir/.agent"
    cp "$here/fixtures/$fixture" "$dir/.agent/config.env"
    printf '%s' "$dir"
}

# --- good config -----------------------------------------------------------
repo=$(make_repo config-good.env)
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
assert_contains "$out" "export AGENT_REPO_SLUG='example-org/example-repo'" 'exports slug'
assert_contains "$out" "export AGENT_PROJECT_NUMBER='7'" 'exports project number'
assert_contains "$out" 'In progress' 'keeps spaces in status vocabulary'

got=$("$rc_sh" --repo-root "$repo" --get AGENT_BASE_BRANCH 2> /dev/null)
assert_eq 'main' "$got" '--get returns a single value'
assert_rc 1 '--get on an absent key exits 1' -- "$rc_sh" --repo-root "$repo" --get AGENT_NOPE

# Exported lines must be safe to eval.
eval "$out"
assert_eq 'example-org/example-repo' "${AGENT_REPO_SLUG:-}" 'eval of --export sets the variable'

# --- bad config ------------------------------------------------------------
repo=$(make_repo config-bad.env)
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
err=$("$rc_sh" --repo-root "$repo" --export 2>&1 > /dev/null)
for key in AGENT_REPO_SLUG AGENT_BASE_BRANCH AGENT_PROJECT_NUMBER \
    AGENT_ADR_DIR AGENT_WORKTREE_ROOT AGENT_BRANCH_PREFIXES AGENT_REVIEW_PROVIDERS; do
    assert_not_contains "$out" "export $key=" "rejects invalid $key"
done
assert_contains "$err" 'AGENT_UNKNOWN_KEY' 'warns about an unknown key'
assert_contains "$err" 'no equals sign' 'warns about a malformed line'
assert_rc 0 'a fully invalid config still exits 0' -- "$rc_sh" --repo-root "$repo" --export

# --- secret rejection ------------------------------------------------------
repo=$(make_repo config-secrets.env)
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
err=$("$rc_sh" --repo-root "$repo" --export 2>&1 > /dev/null)
for key in GH_TOKEN AGENT_CA_BUNDLE HTTPS_PROXY AGENT_API_SECRET; do
    assert_not_contains "$out" "$key" "never exports $key"
done
assert_contains "$err" 'refusing' 'loudly refuses credential-shaped keys'
assert_contains "$out" 'export AGENT_REPO_SLUG=' 'valid keys survive alongside rejected ones'

# --- quoting and whitespace ------------------------------------------------
repo=$(make_repo config-quoted.env)
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
assert_contains "$out" "export AGENT_REPO_SLUG='example-org/example-repo'" 'strips double quotes'
assert_contains "$out" 'In progress' 'strips single quotes'
assert_contains "$out" "export AGENT_BASE_BRANCH='develop'" 'trims whitespace around key and value'
assert_contains "$out" "export AGENT_ADR_DIR='docs/adr'" 'tolerates CRLF line endings'

# --- runner containment ----------------------------------------------------
repo=$(mktemp -d "$tmp/repo.XXXXXX")
mkdir -p "$repo/.agent" "$repo/tools"
printf '#!/bin/sh\nexit 0\n' > "$repo/tools/verify"
chmod +x "$repo/tools/verify"
printf 'AGENT_REPO_RUNNER=tools/verify\n' > "$repo/.agent/config.env"
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
assert_contains "$out" 'AGENT_REPO_RUNNER=' 'accepts an in-repo executable runner'

printf 'AGENT_REPO_RUNNER=/bin/sh\n' > "$repo/.agent/config.env"
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
assert_not_contains "$out" 'AGENT_REPO_RUNNER=' 'rejects a runner outside the repo'

printf 'AGENT_REPO_RUNNER=tools/missing\n' > "$repo/.agent/config.env"
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
assert_not_contains "$out" 'AGENT_REPO_RUNNER=' 'rejects a non-executable runner'

# --- command containment ---------------------------------------------------
# argv[0] is an executable this repository points at -- the same capability the
# runner key grants -- so a path-shaped one is contained the same way. A bare
# name stays an ordinary PATH lookup.
printf 'AGENT_CMD_VERIFY=tools/verify --fast\n' > "$repo/.agent/config.env"
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
assert_contains "$out" 'AGENT_CMD_VERIFY=' 'accepts an in-repo path as argv[0]'

printf 'AGENT_CMD_VERIFY=echo ok\n' > "$repo/.agent/config.env"
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
assert_contains "$out" 'AGENT_CMD_VERIFY=' 'accepts a bare name as argv[0]'

printf 'AGENT_CMD_VERIFY=tools/../../etc/passwd\n' > "$repo/.agent/config.env"
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
assert_not_contains "$out" 'AGENT_CMD_VERIFY=' 'rejects argv[0] traversing out of the repo'

printf 'AGENT_CMD_VERIFY=/bin/sh -c true\n' > "$repo/.agent/config.env"
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
assert_not_contains "$out" 'AGENT_CMD_VERIFY=' 'rejects an absolute argv[0]'

# --- absent config ---------------------------------------------------------
repo=$(mktemp -d "$tmp/repo.XXXXXX")
out=$("$rc_sh" --repo-root "$repo" --export 2> /dev/null)
assert_eq '' "$out" 'absent config produces no output'
assert_rc 0 'absent config exits 0' -- "$rc_sh" --repo-root "$repo" --export

# --- usage -----------------------------------------------------------------
assert_rc 2 'no mode argument is a usage error' -- "$rc_sh" --repo-root "$repo"
assert_rc 2 'unknown flag is a usage error' -- "$rc_sh" --repo-root "$repo" --bogus

# --- the file is never sourced --------------------------------------------
repo=$(mktemp -d "$tmp/repo.XXXXXX")
mkdir -p "$repo/.agent"
cat > "$repo/.agent/config.env" << EOF
AGENT_REPO_SLUG=\$(touch $tmp/PWNED)/x
AGENT_BASE_BRANCH=\`touch $tmp/PWNED2\`
EOF
"$rc_sh" --repo-root "$repo" --export > /dev/null 2>&1
assert_eq 'no' "$([[ -e $tmp/PWNED || -e $tmp/PWNED2 ]] && echo yes || echo no)" \
    'command substitution in the config never executes'

# --- agent-preflight reports the config -----------------------------------
# The preflight takes --worktree, not --repo-root, and WORKTREE is the resolved
# root. The gh stub is on PATH so the probe can never make a live API call.
pf_sh="$root/agentkit/skills/.shared/scripts/agent-preflight.sh"
mkdir -p "$tmp/stub"
cp "$here/stub/gh" "$tmp/stub/gh"
chmod +x "$tmp/stub/gh"

repo=$(make_repo config-good.env)
git -C "$repo" init -q 2> /dev/null || true
out=$(PATH="$tmp/stub:$PATH" "$pf_sh" --worktree "$repo" --no-write 2> /dev/null || true)
assert_contains "$out" 'config= present=yes' 'preflight reports a present config'
assert_contains "$out" 'AGENT_REPO_SLUG' 'preflight names the supplied keys'

repo=$(mktemp -d "$tmp/repo.XXXXXX")
git -C "$repo" init -q 2> /dev/null || true
out=$(PATH="$tmp/stub:$PATH" "$pf_sh" --worktree "$repo" --no-write 2> /dev/null || true)
assert_contains "$out" 'config= present=no keys=0 supplied=none' 'preflight reports an absent config'

# --- a monorepo declares more than five commands ---------------------------
# A fixed five (VERIFY/TEST/LINT/TYPECHECK/BUILD) fits one component. A real
# polyglot repo produced fourteen useful per-component commands and had to throw
# eleven away to fit, so the contract recorded less than the repo knew.
repo=$(make_repo config-good.env)
mkdir -p "$repo/server/.venv/bin" "$repo/dashboard/node_modules/.bin"
touch "$repo/server/.venv/bin/pytest" "$repo/dashboard/node_modules/.bin/tsc"
chmod +x "$repo/server/.venv/bin/pytest" "$repo/dashboard/node_modules/.bin/tsc"
cat > "$repo/.agent/config.env" <<'CFG'
AGENT_REPO_SLUG=example-org/example-repo
AGENT_CMD_BACKEND_TEST=server/.venv/bin/pytest -q server/tests
AGENT_CMD_DASHBOARD_TYPECHECK=dashboard/node_modules/.bin/tsc --noEmit
AGENT_CMD_TEST=server/.venv/bin/pytest -q
CFG
out=$("$rc_sh" --repo-root "$repo" --list 2>&1)
assert_contains "$out" 'AGENT_CMD_BACKEND_TEST=' 'a per-component command name is accepted'
assert_contains "$out" 'AGENT_CMD_DASHBOARD_TYPECHECK=' 'and so is another'
assert_contains "$out" 'AGENT_CMD_TEST=' 'alongside the conventional names'
assert_not_contains "$out" 'invalid value' 'with no warnings'

# The NAME still has to survive being lowercased into an argument and a filename.
printf 'AGENT_CMD_bad name=x\nAGENT_CMD_=x\nAGENT_CMD_9LEADING=x\n' > "$repo/.agent/config.env"
out=$("$rc_sh" --repo-root "$repo" --list 2>&1)
assert_not_contains "$out" 'AGENT_CMD_9LEADING=x' 'a name starting with a digit is refused'
assert_contains "$out" 'unknown key' 'and the refusal is reported, not silent'

# An open-ended key must not become a hole for a credential.
printf 'AGENT_CMD_GH_TOKEN=x\nAGENT_CMD_MY_SECRET=x\n' > "$repo/.agent/config.env"
out=$("$rc_sh" --repo-root "$repo" --list 2>&1)
assert_contains "$out" 'refusing credential-shaped key' 'a credential-shaped command key is refused loudly'
assert_not_contains "$out" 'AGENT_CMD_GH_TOKEN=x' 'and never resolved'
assert_not_contains "$out" 'AGENT_CMD_MY_SECRET=x' 'whatever it is named'

# --- real label vocabularies contain colons --------------------------------
# phase:v1, area:api, priority:p0 are ordinary. Rejecting them threw away the
# one thing this key exists to record.
printf 'AGENT_LABEL_AREAS=ai-engine,phase:v1,phase:v1.1\nAGENT_LABEL_TYPES=bug,type:security\n' \
    > "$repo/.agent/config.env"
out=$("$rc_sh" --repo-root "$repo" --list 2>&1)
assert_contains "$out" 'phase:v1.1' 'a colon in a label is accepted'
assert_contains "$out" 'type:security' 'on every label key'
assert_not_contains "$out" 'invalid value' 'without a warning'

# Still no shell metacharacters: these are interpolated into forge queries.
# shellcheck disable=SC2016  # the unexpanded substitution IS the fixture
printf 'AGENT_LABEL_AREAS=ok,$(id)\n' > "$repo/.agent/config.env"
out=$("$rc_sh" --repo-root "$repo" --list 2>&1)
assert_contains "$out" 'invalid value' 'a substitution in a label is still refused'

finish
