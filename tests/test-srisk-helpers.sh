#!/usr/bin/env bash
# Suite: deterministic helpers extracted from high-attention prose recipes.
set -uo pipefail

TEST_NAME='srisk-helpers'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

parallel="$root/agentkit/skills/parallel-issues/scripts"
shared="$root/agentkit/skills/.shared/scripts"
review="$root/agentkit/skills/review-remote-pr/scripts"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

cap="$parallel/concurrency-cap.sh"
boundary="$parallel/select-boundary-mode.sh"
groom="$review/groom-backlog.sh"
quality="$review/code-quality-state.sh"

# --- concurrency-cap -------------------------------------------------------
config="$tmp/config.toml"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 10' >"$config"
out=$(CODEX_HOME="$tmp" "$cap" --config "$config" 2>/dev/null)
assert_contains "$out" 'runtime concurrency cap: 10 total threads, including the root' \
    'concurrency helper reads the accepted agents section'
mkdir -p "$tmp/codex-home"
cp -- "$config" "$tmp/codex-home/config.toml"
out=$(CODEX_HOME="$tmp/codex-home" "$cap" 2>/dev/null)
assert_contains "$out" 'runtime concurrency cap: 10 total threads, including the root' \
    'concurrency helper resolves CODEX_HOME like the runtime'
assert_rc 0 'no-spawn degradation does not require a runtime cap' -- \
    "$cap" --config "$tmp/missing.toml" --no-spawn
out=$("$cap" --config "$tmp/missing.toml" --no-spawn 2>&1)
assert_contains "$out" 'worker=self (spawn unavailable)' \
    'no-spawn degradation names the serial worker path'
printf '%s\n' '[other]' 'max_concurrent_threads_per_session = 4' >"$config"
err=$("$cap" --config "$config" 2>&1 >/dev/null)
assert_contains "$err" 'outside the accepted sections' \
    'concurrency helper identifies a key in an unsupported section'
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = many' >"$config"
err=$("$cap" --config "$config" 2>&1 >/dev/null)
assert_contains "$err" 'non-numeric' 'concurrency helper identifies a nonnumeric value'

# --- boundary mode ---------------------------------------------------------
assert_eq 'boundary mode: public-fenced' \
    "$("$boundary" --visibility unknown 2>/dev/null)" \
    'unknown visibility fails closed to public-fenced'
assert_eq 'boundary mode: private-trusted' \
    "$("$boundary" --visibility true 2>/dev/null)" \
    'private visibility selects private-trusted'
assert_eq 'boundary mode: yolo-trusted' \
    "$("$boundary" --visibility false --yolo 2>/dev/null)" \
    'explicit yolo selects yolo-trusted regardless of visibility'
assert_rc 2 'boundary helper rejects an unknown option despite YOLO mode' -- \
    env YOLO_INVOCATION=true "$boundary" --no-yol0

# --- read-only board and Code Quality helpers ------------------------------
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"findings":[{"number":7,"state":"open","location":{"path":"a.sh","start_line":3}}]}'
EOF
chmod +x "$tmp/bin/gh"
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r 2>/dev/null)
assert_contains "$out" '"number":7' 'Code Quality helper emits fetched finding state'
assert_not_contains "$out" 'dismiss' 'Code Quality helper exposes no dismissal operation'
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --state dismissed 2>/dev/null)
assert_contains "$out" '"number":7' 'Code Quality helper accepts the dismissed API state'
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --summary 2>/dev/null)
assert_contains "$out" 'finding=7 path=a.sh line=3 state=open' \
    'Code Quality summary follows the documented finding schema'
assert_not_contains "$out" 'commit=' \
    'Code Quality summary does not invent a commit field'
assert_rc 1 'Code Quality helper rejects unsupported closed state' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo o/r --state closed
assert_rc 1 'Code Quality helper rejects unsupported all state' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo o/r --state all
state_error=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --state 2>&1 >/dev/null || true)
assert_contains "$state_error" 'open or dismissed' \
    'Code Quality missing-state error names the supported API states'

cat >"$tmp/bin/board-list.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[{"type":"Issue","number":42,"title":"Ready candidate"},{"type":"PullRequest","number":7}]'
EOF
chmod +x "$tmp/bin/board-list.sh"
# Use an explicit board helper to keep this test independent of forge state.
out=$(PATH="$tmp/bin:$PATH" "$groom" --board-helper "$tmp/bin/board-list.sh" 2>/dev/null)
assert_contains "$out" '#42' 'groom helper reports issue numbers from Backlog JSON'
assert_not_contains "$out" 'move-github-project-item' 'groom helper does not auto-promote'

# --- onboarding next steps -------------------------------------------------
repo="$tmp/repo"
mkdir -p "$repo/.agent"
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit --allow-empty -qm initial
out=$("$shared/onboard-state.sh" --repo-root "$repo" --next-steps 2>/dev/null)
assert_contains "$out" "$shared/agent-run.sh" \
    'onboarding checklist resolves the absolute agent-run helper path'
assert_contains "$out" 'Open a PR' 'onboarding checklist renders the go-live steps'

contract_repo="$tmp/contract-repo"
mkdir -p "$contract_repo/.agent"
git -C "$contract_repo" init -q
"$shared/agent-preflight.sh" --worktree "$contract_repo" >/dev/null 2>&1
contract_before=$(<"$contract_repo/.agent/env-contract.txt")
contract_inode=$(stat -c %i "$contract_repo/.agent/env-contract.txt")
contract_mtime=$(stat -c %.9Y "$contract_repo/.agent/env-contract.txt")
contract_out=$("$shared/agent-preflight.sh" --ensure --worktree "$contract_repo" 2>/dev/null)
assert_eq "$contract_before" "$contract_out" \
    'preflight ensure reuses a trusted contract byte-for-byte'
# A whole-second stat -c %Y comparison cannot catch a rewrite that reproduces
# identical bytes within the same second (e.g. a write-temp-then-rename that
# lands on the same content). Compare the inode -- this repo's own atomic-write
# idiom (write-temp, mv -f over target) always changes it -- alongside a
# sub-second mtime, which catches an in-place rewrite the inode check would
# miss.
assert_eq "$contract_inode" "$(stat -c %i "$contract_repo/.agent/env-contract.txt")" \
    'preflight ensure does not replace the trusted contract file (inode unchanged)'
assert_eq "$contract_mtime" "$(stat -c %.9Y "$contract_repo/.agent/env-contract.txt")" \
    'preflight ensure does not rewrite a trusted contract (sub-second mtime unchanged)'
rm -f -- "$contract_repo/.agent/env-contract.txt"
"$shared/agent-preflight.sh" --ensure --worktree "$contract_repo" >/dev/null 2>&1
assert_eq yes "$( [[ -f $contract_repo/.agent/env-contract.txt ]] && printf yes || printf no )" \
    'preflight ensure writes a missing contract'

finish
