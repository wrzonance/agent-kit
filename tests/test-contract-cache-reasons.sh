#!/usr/bin/env bash
# Suite: contract-cache.sh's --read-session-context CLI names WHY a read
# failed on stderr (issue #587) instead of returning silently. Covers the
# four failure classes -- absent, invalid, skills-path-mismatch, stale --
# plus the two invariants the issue requires: success output and exit codes
# are byte-identical to before this fix, and sourced (library) use stays
# silent.
set -uo pipefail

TEST_NAME='contract-cache-reasons'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

cache_reader="$root/agentkit/skills/.shared/scripts/lib/contract-cache.sh"
reader="$root/agentkit/skills/.shared/scripts/contract-read.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Populates a real, schema-valid session-context record the same way
# production code does: contract-read.sh's own --get path writes it as a
# side effect (test-contract-provenance.sh exercises the same flow). Calling
# contract-cache.sh's --read-session-context CLI directly never WRITES a
# record, so a hand-rolled repo without this step has nothing to read.
make_valid_repo() {
    local dir=$1
    mkdir -p "$dir/.agent"
    git -C "$dir" init -q
    printf '%s\n' \
        'skills= path=/tmp/installed/agentkit/skills' \
        'repo=example-org/example-repo' \
        'base=main source=refs/remotes/origin/HEAD' \
        'harness= name=codex trailer="Codex <noreply@openai.com>" other=claude' \
        > "$dir/.agent/env-contract.txt"
    "$reader" --repo-root "$dir" --get skills.path > /dev/null
}

# --- absent: no readable record file at all -------------------------------
absent_repo="$tmp/absent"
make_valid_repo "$absent_repo"
rm -f -- "$absent_repo/.agent/cache/contract-session.env"
out=''
err=''
rc=0
out=$("$cache_reader" --read-session-context --repo-root "$absent_repo" 2> "$tmp/absent.err") || rc=$?
err=$(cat -- "$tmp/absent.err")
assert_eq 1 "$rc" 'an absent session-context record fails with rc 1 (unchanged)'
assert_eq '' "$out" 'an absent session-context record has no stdout (unchanged)'
assert_eq 'contract-cache: session-context absent' "$err" \
    'an absent session-context record names its class on stderr'

# --- invalid (not absent): a record file exists but fails provenance ------
# (follow-up finding on #587): a tracked file or a symlink swap is
# corruption/tampering, not "nothing there" -- absent must mean no
# filesystem entry at all. A tracked record fails
# contract_cache_file_is_ours's git-ownership check while still physically
# present on disk, so it exercises the same existing-but-unsafe branch a
# mode or ownership change would.
tracked_repo="$tmp/tracked-record"
make_valid_repo "$tracked_repo"
git -C "$tracked_repo" add -f -- .agent/cache/contract-session.env
rc=0
out=$("$cache_reader" --read-session-context --repo-root "$tracked_repo" 2> "$tmp/tracked.err") || rc=$?
err=$(cat -- "$tmp/tracked.err")
assert_eq 1 "$rc" 'a tracked session-context record fails with rc 1 (unchanged)'
assert_eq '' "$out" 'a tracked session-context record has no stdout (unchanged)'
assert_eq 'contract-cache: session-context invalid' "$err" \
    'a session-context record that exists but fails provenance (tracked) is invalid, not absent'
git -C "$tracked_repo" rm --cached -q -- .agent/cache/contract-session.env

symlink_repo="$tmp/symlink-swap"
make_valid_repo "$symlink_repo"
real_target="$tmp/symlink-swap-target.env"
cp -- "$symlink_repo/.agent/cache/contract-session.env" "$real_target"
rm -f -- "$symlink_repo/.agent/cache/contract-session.env"
ln -s -- "$real_target" "$symlink_repo/.agent/cache/contract-session.env"
rc=0
out=$("$cache_reader" --read-session-context --repo-root "$symlink_repo" 2> "$tmp/symlink.err") || rc=$?
err=$(cat -- "$tmp/symlink.err")
assert_eq 1 "$rc" 'a symlinked session-context record fails with rc 1 (unchanged)'
assert_eq '' "$out" 'a symlinked session-context record has no stdout (unchanged)'
assert_eq 'contract-cache: session-context invalid' "$err" \
    'a session-context record replaced by a symlink is invalid, not absent'

cache_dir_repo="$tmp/cache-dir-symlink"
make_valid_repo "$cache_dir_repo"
cache_dir_target="$tmp/cache-dir-symlink-target"
mv -- "$cache_dir_repo/.agent/cache" "$cache_dir_target"
ln -s -- "$cache_dir_target" "$cache_dir_repo/.agent/cache"
rc=0
out=$("$cache_reader" --read-session-context --repo-root "$cache_dir_repo" 2> "$tmp/cache-dir.err") || rc=$?
err=$(cat -- "$tmp/cache-dir.err")
assert_eq 1 "$rc" 'a symlinked cache directory fails with rc 1 (unchanged)'
assert_eq '' "$out" 'a symlinked cache directory has no stdout (unchanged)'
assert_eq 'contract-cache: session-context invalid' "$err" \
    'a cache directory replaced by a symlink is invalid, not absent'

# --- invalid: malformed record content ------------------------------------
invalid_repo="$tmp/invalid"
make_valid_repo "$invalid_repo"
printf 'not-a-valid-record\n' > "$invalid_repo/.agent/cache/contract-session.env"
chmod 600 -- "$invalid_repo/.agent/cache/contract-session.env"
rc=0
out=$("$cache_reader" --read-session-context --repo-root "$invalid_repo" 2> "$tmp/invalid.err") || rc=$?
err=$(cat -- "$tmp/invalid.err")
assert_eq 1 "$rc" 'a malformed session-context record fails with rc 1 (unchanged)'
assert_eq '' "$out" 'a malformed session-context record has no stdout (unchanged)'
assert_eq 'contract-cache: session-context invalid' "$err" \
    'a malformed session-context record names its class on stderr'

# --- skills-path-mismatch: record disagrees with the live contract's ------
# skills= path (the plugin-upgrade field case from the issue) --------------
mismatch_repo="$tmp/mismatch"
make_valid_repo "$mismatch_repo"
sed -i 's|^skills= path=.*$|skills= path=/tmp/installed-v2/agentkit/skills|' \
    "$mismatch_repo/.agent/env-contract.txt"
# Refresh the digest-side inputs so this trips the skills-path check, not the
# staleness check: recompute the session record with the OLD skills path but
# the CURRENT digest so contract_inputs_sha256 still matches.
digest=$(sed -n 's/^contract_inputs_sha256=//p' "$mismatch_repo/.agent/cache/contract-session.env")
printf '%s\n' \
    'format=1' \
    'agentkit=/tmp/installed/agentkit/skills' \
    'shared=/tmp/installed/agentkit/skills/.shared/scripts' \
    'agentkit_provenance=ok' \
    "contract_root=$mismatch_repo" \
    "contract_inputs_sha256=$digest" \
    > "$mismatch_repo/.agent/cache/contract-session.env"
chmod 600 -- "$mismatch_repo/.agent/cache/contract-session.env"
rc=0
out=$("$cache_reader" --read-session-context --repo-root "$mismatch_repo" 2> "$tmp/mismatch.err") || rc=$?
err=$(cat -- "$tmp/mismatch.err")
assert_eq 1 "$rc" 'a skills-path mismatch fails with rc 1 (unchanged)'
assert_eq '' "$out" 'a skills-path mismatch has no stdout (unchanged)'
assert_contains "$err" 'contract-cache: session-context skills-path-mismatch (cache=' \
    'a skills-path mismatch names its class and carries the cache= path'
assert_contains "$err" 'contract=' \
    'a skills-path mismatch also carries the contract= path'
assert_contains "$err" "$mismatch_repo/.agent/cache/contract-session.env" \
    'the reported cache= path is the actual session record'
assert_contains "$err" "$mismatch_repo/.agent/env-contract.txt" \
    'the reported contract= path is the actual live contract'

# --- stale: contract_inputs_sha256 no longer matches ----------------------
stale_repo="$tmp/stale"
make_valid_repo "$stale_repo"
printf 'AGENT_REPO_SLUG=changed/example\n' > "$stale_repo/.agent/config.env"
rc=0
out=$("$cache_reader" --read-session-context --repo-root "$stale_repo" 2> "$tmp/stale.err") || rc=$?
err=$(cat -- "$tmp/stale.err")
assert_eq 75 "$rc" 'a stale digest keeps rc 75 (unchanged)'
assert_eq '' "$out" 'a stale digest has no stdout (unchanged)'
assert_eq 'contract-cache: session-context stale' "$err" \
    'a stale digest names its class on stderr'

# --- success path: stdout and exit code untouched by this fix -------------
ok_repo="$tmp/ok"
make_valid_repo "$ok_repo"
rc=0
out=$("$cache_reader" --read-session-context --repo-root "$ok_repo" --get agentkit \
    2> "$tmp/ok.err") || rc=$?
err=$(cat -- "$tmp/ok.err")
assert_eq 0 "$rc" 'a successful read still exits 0'
assert_eq '/tmp/installed/agentkit/skills' "$out" 'a successful read still prints the requested value'
assert_eq '' "$err" 'a successful read emits nothing on stderr'

# --- sourced (library) use never emits the CLI diagnostic -----------------
# shellcheck source=../agentkit/skills/.shared/scripts/lib/contract-cache.sh
source "$cache_reader"
# The reason global is set inside contract_cache_session_context_read; reading
# it back in the SAME command substitution keeps it in the one subshell that
# actually saw the assignment (a separate `$(...)` call would read the
# parent's unset copy under `set -u`).
sourced_reason=$(contract_cache_session_context_read "$absent_repo" \
    > /dev/null 2> "$tmp/sourced.err"; printf '%s' "$CONTRACT_CACHE_SESSION_CONTEXT_REASON")
sourced_err=$(cat -- "$tmp/sourced.err")
assert_eq '' "$sourced_err" \
    'sourced (non-CLI) use of the read function emits nothing on stderr'
assert_eq absent "$sourced_reason" \
    'sourced use still records the reason for a caller that wants it, without printing'

finish
