#!/usr/bin/env bash
# Suite: parallel dispatch runtime cap and completion-only polling guidance.
# shellcheck disable=SC2016  # Markdown backticks are literal assertion text
set -uo pipefail

TEST_NAME='parallel-dispatch-contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skill="$root/agentkit/skills/parallel-issues/SKILL.md"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

text=$(<"$skill")
assert_not_contains "$text" 'Between waits, read durable state instead of waiting again' \
    'polling does not inspect durable state between empty waits'
assert_contains "$text" 'Between waits, wait again; read durable state only when a wait reports an actual completion.' \
    'polling reads durable state only after completion'
assert_contains "$text" 'do not load `review-remote-pr/SKILL.md`' \
    'dispatch is self-contained without loading the worker skill'
assert_not_contains "$text" 'Four total slots including the root' \
    'dispatch does not hardcode the old slot count'
assert_not_contains "$text" 'Max 5 issues' \
    'limits do not hardcode the old issue count'
assert_contains "$text" 'max_concurrent_threads_per_session' \
    'dispatch reads the runtime concurrency setting'

snippet=$(awk '
    index($0, "config_file=\"${CODEX_HOME:-$HOME/.codex}/config.toml\"") == 1 { capture=1 }
    capture && /^```$/ { exit }
    capture { print }
' "$skill")

configured_home="$tmp/configured"
mkdir -p "$configured_home/.codex"
printf '%s\n' '[multi_agent_v2]' 'max_concurrent_threads_per_session = 10' \
    > "$configured_home/.codex/config.toml"
out=$(env -u CODEX_HOME HOME="$configured_home" bash -c "$snippet" 2>/dev/null)
status=$?
assert_contains "$out" 'runtime concurrency cap: 10 total threads, including the root' \
    'dispatch advertises the configured runtime cap'
assert_eq '0' "$status" 'an advertised cap exits zero'

codex_home="$tmp/codex-home"
mkdir -p "$codex_home"
printf '%s\n' '[multi_agent_v2]' 'max_concurrent_threads_per_session = 7' \
    > "$codex_home/config.toml"
out=$(CODEX_HOME="$codex_home" HOME="$tmp/no-such-home" bash -c "$snippet" 2>/dev/null)
assert_contains "$out" 'runtime concurrency cap: 7 total threads, including the root' \
    'a CODEX_HOME override is honored over $HOME/.codex'

missing_home="$tmp/missing"
mkdir -p "$missing_home"
err=$(env -u CODEX_HOME HOME="$missing_home" bash -c "$snippet" 2>&1 >/dev/null)
status=$?
assert_contains "$err" 'Unable to advertise concurrency' \
    'missing runtime config explains why the cap is unavailable'
assert_eq 'nonzero' "$( (( status != 0 )) && printf nonzero || printf zero )" \
    'missing runtime config exits nonzero so dispatch stops'

finish
