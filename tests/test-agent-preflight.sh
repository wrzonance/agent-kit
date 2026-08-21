#!/usr/bin/env bash
# Suite: agent-preflight.sh writes its contract safely.
#
# This script had no behavioural suite at all, which an external review noted
# before finding a defect in it: the contract was written with plain redirection,
# so a repository tracking .agent/env-contract.txt as a symlink to ../.git/config
# turned every preflight run into a truncate of the git config. Redirection
# follows the link and does not care where it lands.
#
# The file also matters more than its size suggests. It carries local paths, the
# CA bundle location and the authenticated account name, and it is read straight
# back into the agent's context as established fact.
set -uo pipefail

TEST_NAME='agent-preflight'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/agent-preflight.sh"
harness_id_script="$root/agentkit/skills/.shared/scripts/harness-id.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# The current CLI's harness= line, exactly as agent-preflight.sh's own
# probe_harness would emit it. --inherit-session fixtures below must carry
# this (issue #332 F3: inheritance is only trusted from a same-harness,
# recent source), computed live rather than hardcoded so the suite passes
# under whichever CLI actually runs it.
current_harness_line="harness= $("$harness_id_script" 2> /dev/null)"

new_repo() {
    local d
    d=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$d" init -q
    mkdir -p "$d/.agent"
    printf '%s' "$d"
}

# --- the ordinary case ------------------------------------------------------
repo=$(new_repo)
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_contains "$out" 'harness=' 'the block names the harness it ran under'
assert_rc 0 'a preflight in a bare repository still exits 0' -- \
    "$script" --worktree "$repo"
if [[ -f "$repo/.agent/env-contract.txt" ]]; then
    _pass 'and leaves the contract on disk'
else
    _fail 'and leaves the contract on disk' "no file at $repo/.agent/env-contract.txt"
fi

# --ensure must not silently discard operands whose documented semantics belong
# to a full probe. Fail closed before checking the fast-path contract instead.
assert_rc 2 '--ensure rejects an explicit --write target' -- \
    "$script" --ensure --worktree "$repo" --write "$tmp/other-contract"
assert_rc 2 '--ensure rejects an explicit repository override' -- \
    "$script" --ensure --worktree "$repo" --repo owner/repo
assert_rc 2 '--ensure rejects an explicit measured-from override' -- \
    "$script" --ensure --worktree "$repo" --measured-from hook

# The contract can disappear or become unreadable after contract-read validates
# it. A failed fast-path read must fall back to the normal probe and preserve
# the documented success status rather than returning cat's status 1.
mkdir -p "$tmp/cat-race-bin"
cat > "$tmp/cat-race-bin/cat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == '--' && "${2:-}" == "${PRETEND_CONTRACT:-}" ]]; then
    exit 1
fi
exec /usr/bin/cat "$@"
EOF
chmod +x "$tmp/cat-race-bin/cat"
assert_rc 0 'an unreadable trusted contract falls back to a fresh preflight' -- \
    env PATH="$tmp/cat-race-bin:$PATH" PRETEND_CONTRACT="$repo/.agent/env-contract.txt" \
    "$script" --ensure --worktree "$repo"
race_out=$(PATH="$tmp/cat-race-bin:$PATH" PRETEND_CONTRACT="$repo/.agent/env-contract.txt" \
    "$script" --ensure --worktree "$repo" 2> /dev/null)
assert_contains "$race_out" 'harness=' \
    'the fallback still emits a complete preflight contract'

# The contract is not secret, but it is not public either: local paths, a CA
# bundle location, an account name. A lax umask should not decide that.
mode=$(stat -c '%a' "$repo/.agent/env-contract.txt" 2> /dev/null || printf '?')
assert_eq '600' "$mode" 'the contract is written private to the user'

# --- bounded root instruction report ---------------------------------------
repo=$(new_repo)
mkdir -p "$repo/nested"
printf 'nested guidance\n' > "$repo/nested/AGENTS.md"
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_contains "$out" 'instructions= root=none' \
    'a bare fixture reports no root instruction files'
assert_not_contains "$out" 'nested/AGENTS.md' \
    'nested instruction files are not enumerated by preflight'

printf 'root guidance\n' > "$repo/AGENTS.md"
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_eq 'instructions= root=AGENTS.md' "$(grep '^instructions=' <<< "$out")" \
    'preflight reports exactly the root AGENTS.md'
assert_not_contains "$(grep '^instructions=' <<< "$out")" 'CLAUDE.md' \
    'the root report omits an absent CLAUDE.md'

printf 'root guidance\n' > "$repo/CLAUDE.md"
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_eq 'instructions= root=AGENTS.md,CLAUDE.md' "$(grep '^instructions=' <<< "$out")" \
    'preflight reports exactly both root instruction files in stable order'

# Root instruction files are a trust boundary. Reject both external and in-tree
# symlinks rather than importing text through a path whose canonical target was
# not explicitly selected by the contract.
repo=$(new_repo)
printf 'external guidance\n' > "$tmp/external-AGENTS.md"
ln -s "$tmp/external-AGENTS.md" "$repo/AGENTS.md"
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_eq 'instructions= root=none' "$(grep '^instructions=' <<< "$out")" \
    'preflight rejects a symlinked root AGENTS.md'

repo=$(new_repo)
printf 'in-tree guidance\n' > "$repo/in-tree-AGENTS.md"
ln -s in-tree-AGENTS.md "$repo/AGENTS.md"
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_eq 'instructions= root=none' "$(grep '^instructions=' <<< "$out")" \
    'preflight rejects an in-tree root AGENTS.md symlink'

# --- the symlink ------------------------------------------------------------
repo=$(new_repo)
printf 'ORIGINAL-MUST-SURVIVE\n' > "$repo/victim.txt"
ln -sf "$repo/victim.txt" "$repo/.agent/env-contract.txt"
err=$("$script" --worktree "$repo" 2>&1 > /dev/null)
assert_eq 'ORIGINAL-MUST-SURVIVE' "$(cat "$repo/victim.txt")" \
    'a symlinked contract does not become a write to its target'
assert_contains "$err" 'symlink' 'and the refusal says why'

# Reporting, never failing: the block already went to stdout, so refusing the
# artifact must not fail the run that produced it.
assert_rc 0 'refusing the artifact still exits 0' -- "$script" --worktree "$repo"
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_contains "$out" 'harness=' 'and the block is still printed'

# --- a non-regular file at the target ---------------------------------------
repo=$(new_repo)
mkdir -p "$repo/.agent/env-contract.txt"
err=$("$script" --worktree "$repo" 2>&1 > /dev/null)
assert_contains "$err" 'not a regular file' 'a directory at the target is refused, not written through'
if [[ -d "$repo/.agent/env-contract.txt" ]]; then
    _pass 'and the directory is left alone'
else
    _fail 'and the directory is left alone' 'it was replaced'
fi

# --- replacement is atomic --------------------------------------------------
# A reader that opens this file mid-write gets a truncated contract and treats
# it as fact. Renaming a complete temporary over the target means a reader sees
# either the old contract or the new one.
repo=$(new_repo)
"$script" --worktree "$repo" > /dev/null 2>&1
first=$(wc -l < "$repo/.agent/env-contract.txt")
"$script" --worktree "$repo" > /dev/null 2>&1
second=$(wc -l < "$repo/.agent/env-contract.txt")
assert_eq "$first" "$second" 'a second run replaces the contract rather than appending to it'
leftovers=$(find "$repo/.agent" -maxdepth 1 -name '.env-contract.*' | wc -l | tr -d ' ')
assert_eq '0' "$leftovers" 'and leaves no temporary files behind'

# --- who the measurement is about -------------------------------------------
# A hook runs OUTSIDE the agent's sandbox. Its write probes succeed where the
# agent's would be denied, and the CODEX_* variables the sandbox block reads are
# set only in the agent's own shell -- so from a hook every session looks
# unsandboxed with a writable .git.
#
# A live session was handed exactly that and then had its write to
# .git/info/exclude refused. It noticed and worked around it. The contract says
# "established; do not re-probe", so noticing was not something it was invited
# to do, and relying on it twice is not a plan.
repo=$(new_repo)
agent_view=$("$script" --worktree "$repo" 2> /dev/null)
if grep -q 'measured-by=hook' <<< "$agent_view"; then
    _fail 'the default block claims nothing about a hook' 'it labelled itself hook-measured'
else
    _pass 'the default block claims nothing about a hook'
fi

hook_view=$("$script" --worktree "$repo" --measured-from hook 2> /dev/null)
assert_contains "$hook_view" 'sandbox=' 'a hook-measured block still reports the sandbox line'
assert_contains "$(grep '^sandbox=' <<< "$hook_view")" 'measured-by=hook' \
    'and marks the sandbox line as measured elsewhere'
assert_contains "$hook_view" 'believe a denial over this line' \
    'and says which side wins when they disagree'

# Never a confident "active=no" from a process that cannot see the answer.
if grep -qE '^sandbox=.*active=no' <<< "$hook_view"; then
    _fail 'a hook does not assert the session is unsandboxed' 'it emitted active=no'
else
    _pass 'a hook does not assert the session is unsandboxed'
fi

# The git line carries the same caveat, but only where it made a positive claim:
# writable=no is a denial the hook actually hit, and the agent's sandbox cannot
# make it more permissive.
git_line=$(grep '^git=' <<< "$hook_view")
if grep -q 'writable=yes' <<< "$git_line"; then
    assert_contains "$git_line" 'measured-by=hook' 'a hook-measured writable=yes is labelled'
    assert_contains "$git_line" 'worth re-probing' 'and invites the one re-probe that matters'
else
    _pass 'a hook-measured writable=yes is labelled (no positive claim to label here)'
    _pass 'and invites the one re-probe that matters (not applicable)'
fi

assert_rc 2 'an unknown provenance is a usage error, not a silent default' -- \
    "$script" --worktree "$repo" --measured-from somewhere

# --- branch= on a repository with no commits yet ----------------------------
# `git rev-parse --abbrev-ref HEAD` fails (exit 128) on an unborn repository
# but still echoes "HEAD" to stdout as part of its diagnostic; a naive
# `2>/dev/null || printf 'unknown'` inline fallback captured that stray text
# too, corrupting the one-line-per-key contract with an extra "unknown" line
# (test-session-contract-freshness.sh's unborn-checkout case relies on the
# clean single-line "branch=HEAD" this now produces).
repo=$(new_repo)
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_eq 'branch=HEAD' "$(grep '^branch=' <<< "$out")" \
    'an unborn repository reports a single-line branch=HEAD'
assert_not_contains "$out" $'\nunknown\n' \
    'no stray "unknown" fragment line leaks into the block'

# --- protected= (issue #296) -------------------------------------------------
# The effective protected-path set is computable before any work starts --
# lib/protected-paths.sh's shared defaults plus a repository's additive
# AGENT_PROTECTED_PATHS declaration -- so a colliding write set is knowable at
# planning time instead of rediscovered at commit time by worktree-commit.sh's
# guard_staged_protected_paths.
repo=$(new_repo)
out=$("$script" --worktree "$repo" 2> /dev/null)
protected_line=$(grep '^protected=' <<< "$out")
assert_contains "$out" 'protected=' 'the block reports the effective protected-path set'
assert_contains "$protected_line" '.github/workflows/' \
    'protected= carries the shared built-in defaults'
assert_contains "$protected_line" 'repo-declared="none"' \
    'a repository with no declaration reports repo-declared=none'

repo=$(new_repo)
printf 'AGENT_PROTECTED_PATHS=docs/adrs/,infra/terraform.tf\n' > "$repo/.agent/config.env"
out=$("$script" --worktree "$repo" 2> /dev/null)
protected_line=$(grep '^protected=' <<< "$out")
assert_contains "$protected_line" 'docs/adrs/' \
    'a repository-declared protected path extension is included'
assert_contains "$protected_line" 'infra/terraform.tf' \
    'and every declared entry is included, not just the first'
assert_contains "$protected_line" '.github/workflows/' \
    'the declared extension is additive to the shared defaults, not a replacement'
assert_contains "$protected_line" 'repo-declared="docs/adrs/,infra/terraform.tf"' \
    'repo-declared= names exactly the repository extension'

# --- documented OUTPUT key order matches what the script emits --------------
# The header's OUTPUT comment is the contract every consumer parses exact
# prefixes against. Adding protected= without updating both the header and the
# emission order would silently desynchronize documentation from behaviour.
header_line=$(grep -m1 '^#   skills= path= repo=' "$script")
assert_contains "$header_line" ' protected= instructions=' \
    'the header documents protected= immediately after config= and before instructions='
mapfile -t expected_tokens < <(tr -s ' ' '\n' <<< "${header_line#\#}")
declare -a expected_line_keys=()
skip_next=0
for tok in "${expected_tokens[@]}"; do
    [[ -n $tok ]] || continue
    if (( skip_next )); then skip_next=0; continue; fi
    if [[ $tok == 'skills=' ]]; then skip_next=1; fi
    expected_line_keys+=("$tok")
done

repo=$(new_repo)
out=$("$script" --worktree "$repo" 2> /dev/null)
declare -a actual_line_keys=()
while IFS= read -r line; do
    key=$(grep -oE '^[a-zA-Z0-9_-]+=' <<< "$line")
    # runtime-pin= and gh-auth= are conditional lines the header does not name.
    case "$key" in
        runtime-pin=|gh-auth=) continue ;;
    esac
    actual_line_keys+=("$key")
done <<< "$out"
assert_eq "${expected_line_keys[*]}" "${actual_line_keys[*]}" \
    'the documented OUTPUT key order matches every line the script actually emits'

# --- --ensure must not serve a contract that predates protected= (issue #296) -
# --check only validates ownership/tracked-state provenance, not which keys the
# cached file happens to carry. A contract written before protected= existed is
# still provenance-trusted, so without this check --ensure would keep serving
# it forever on an otherwise-untouched worktree -- exactly the checkouts most
# likely to have one already.
repo=$(new_repo)
"$script" --worktree "$repo" > /dev/null 2>&1
grep -v '^protected=' "$repo/.agent/env-contract.txt" > "$tmp/stale-contract"
mv "$tmp/stale-contract" "$repo/.agent/env-contract.txt"
chmod 600 "$repo/.agent/env-contract.txt"
assert_eq '0' "$(grep -c '^protected=' "$repo/.agent/env-contract.txt")" \
    'fixture setup: the stale contract really has no protected= line'
out=$("$script" --ensure --worktree "$repo" 2> "$tmp/ensure-stderr")
assert_eq '1' "$(grep -c '^protected=' <<< "$out")" \
    '--ensure regenerates a contract that predates protected= rather than serving it'
assert_contains "$(cat "$tmp/ensure-stderr")" 'predates protected=' \
    'and says why it fell through to a fresh preflight'
assert_eq '1' "$(grep -c '^protected=' "$repo/.agent/env-contract.txt")" \
    'the regenerated contract on disk carries protected= too'

# The caching behaviour --ensure exists for must not regress: a contract that
# already carries protected= is served as-is, not silently rewritten.
"$script" --worktree "$repo" > /dev/null 2>&1
before_mtime=$(stat -c %Y "$repo/.agent/env-contract.txt")
sleep 1
out=$("$script" --ensure --worktree "$repo" 2> /dev/null)
after_mtime=$(stat -c %Y "$repo/.agent/env-contract.txt")
assert_eq '1' "$(grep -c '^protected=' <<< "$out")" \
    '--ensure still reports protected= for an up-to-date contract'
assert_eq "$before_mtime" "$after_mtime" \
    '--ensure reuses an up-to-date contract instead of rewriting it'

# Shared scripts use associative arrays, so a pre-Bash-4 interpreter must fail
# with a named requirement before doing any work instead of exposing a cryptic
# `declare: -A: invalid option` error. Running the file through zsh reproduces
# the harness boundary that caused a Bash-oriented sed recipe to fail.
if command -v zsh > /dev/null 2>&1; then
    for shared_script in "$script" "$root/agentkit/skills/.shared/scripts/repo-config.sh"; do
        rc=0
        err=$(zsh "$shared_script" --help 2>&1 > /dev/null) || rc=$?
        assert_eq '2' "$rc" "$(basename "$shared_script") rejects a non-Bash interpreter"
        assert_contains "$err" 'requires Bash >= 4' \
            "$(basename "$shared_script") names the Bash requirement"
        assert_contains "$err" 'run this helper with bash, not zsh' \
            "$(basename "$shared_script") names the correct interpreter"
    done
else
    printf '  skip zsh interpreter-boundary checks: zsh not installed\n'
fi

# --- harness= opencode + peer-cli= multi-candidate search (issue #318) ------
# OpenCode has no fixed 1:1 peer CLI the way Claude/Codex do, so harness-id.sh
# hands agent-preflight.sh's probe_peer_cli an ordered "codex,claude"
# candidate list instead of a single name. Exactly one winning name must
# still be emitted, so every existing single-name peer-cli= consumer keeps
# working unmodified.
#
# The candidate list is NOT hardcoded here -- it is read straight from
# harness-id.sh's own OpenCode `other=` output, the single source of truth
# probe_peer_cli is actually handed. Hardcoding "codex claude" would silently
# rot the moment a third candidate is added there: this fixture would keep
# stripping only the two it knows about, a leftover real binary for the new
# candidate would still be on PATH, and the "absent" case below would no
# longer be testing what its name claims.
#
# On THIS machine, codex/claude happen to live in the same directory
# (/home/adam/.local/bin, also probe_peer_cli's own $HOME/.local/bin
# fallback), but a fixture that assumed that would break on any machine
# where the peer CLIs are installed separately (e.g. one via npm global in
# /usr/local/bin, the other in ~/.local/bin) -- so every PATH directory that
# resolves ANY candidate name is stripped, not just one. HOME still points
# somewhere with no .local/bin, and PATH is filtered rather than cleared,
# since agent-preflight.sh itself needs git/jq/stat/date.
opencode_other=$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    -u CODEX_HOME -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_PERMISSION_PROFILE \
    OPENCODE=1 "$root/agentkit/skills/.shared/scripts/harness-id.sh" --other)
declare -a candidate_names=()
IFS=',' read -ra candidate_names <<< "$opencode_other"
assert_eq 'codex,claude' "$opencode_other" \
    'harness-id.sh OpenCode candidate list is codex,claude -- if this fails, a new candidate was added and this fixture (and the assertions below) must account for it'
declare -a path_dirs=() kept_path_dirs=()
IFS=: read -ra path_dirs <<< "$PATH"
for path_dir in "${path_dirs[@]}"; do
    exposes_candidate=0
    for candidate_name in "${candidate_names[@]}"; do
        if [[ -x "$path_dir/$candidate_name" ]]; then
            exposes_candidate=1
            break
        fi
    done
    (( exposes_candidate )) || kept_path_dirs+=("$path_dir")
done
filtered_path=$(IFS=:; printf '%s' "${kept_path_dirs[*]}")
fake_home="$tmp/fake-home-no-local-bin"
mkdir -p "$fake_home"

repo=$(new_repo)
out=$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    -u CODEX_HOME -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_PERMISSION_PROFILE \
    OPENCODE=1 HOME="$fake_home" PATH="$filtered_path" \
    "$script" --worktree "$repo" 2> /dev/null)
assert_eq 'harness= name=opencode trailer="OpenCode <noreply@opencode.ai>" other=codex,claude' \
    "$(grep '^harness=' <<< "$out")" \
    'a preflight run under OPENCODE=1 reports harness= name=opencode'
assert_contains "$(grep '^peer-cli=' <<< "$out")" 'peer-cli= codex absent' \
    'with neither peer CLI on PATH, peer-cli= names the FIRST candidate (codex) as absent'
assert_contains "$(grep '^peer-cli=' <<< "$out")" 'codex,claude' \
    'the absent note lists every candidate that was actually checked'

# Only "claude" present, ahead of the filtered PATH: probe_peer_cli must fall
# through past the absent first candidate (codex) to find it.
claude_only_dir="$tmp/claude-only-path"
mkdir -p "$claude_only_dir"
printf '#!/bin/sh\n' > "$claude_only_dir/claude"
chmod +x "$claude_only_dir/claude"
out=$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    -u CODEX_HOME -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_PERMISSION_PROFILE \
    OPENCODE=1 HOME="$fake_home" PATH="$claude_only_dir:$filtered_path" \
    "$script" --worktree "$repo" 2> /dev/null)
assert_eq 'peer-cli= claude present path='"$claude_only_dir"'/claude probe=not-run' \
    "$(grep '^peer-cli=' <<< "$out")" \
    'with only claude on PATH, peer-cli= falls through codex to report claude present'

# Both present: codex, the first-listed candidate, wins.
both_dir="$tmp/both-path"
mkdir -p "$both_dir"
printf '#!/bin/sh\n' > "$both_dir/codex"
printf '#!/bin/sh\n' > "$both_dir/claude"
chmod +x "$both_dir/codex" "$both_dir/claude"
out=$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    -u CODEX_HOME -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_PERMISSION_PROFILE \
    OPENCODE=1 HOME="$fake_home" PATH="$both_dir:$filtered_path" \
    "$script" --worktree "$repo" 2> /dev/null)
assert_eq 'peer-cli= codex present path='"$both_dir"'/codex probe=not-run' \
    "$(grep '^peer-cli=' <<< "$out")" \
    'with both peers on PATH, codex (the first candidate) wins'

# Claude and Codex are unaffected: still a single-candidate search.
out=$(env -u CODEX_HOME -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_PERMISSION_PROFILE \
    -u OPENCODE -u OPENCODE_PID \
    CLAUDECODE=1 HOME="$fake_home" PATH="$filtered_path" \
    "$script" --worktree "$repo" 2> /dev/null)
assert_eq 'peer-cli= codex absent note="no cross-harness reviewer among: codex; use the same-harness blind fallback"' \
    "$(grep '^peer-cli=' <<< "$out")" \
    'claude sessions still search only codex, unchanged by the multi-candidate support'

# --- sandbox provenance tri-state (issue #332) -------------------------------
# Three process classes can run this probe -- a hook, the agent's own shell,
# and a harness-escalated/approval-granted shell -- and only the hook class
# used to carry a marker. All three must now be provenance-tagged, and the
# "escalated" class must be an explicit assertion, never something this probe
# guesses at (there is no verified in-tree signal for it).
repo=$(new_repo)
default_view=$("$script" --worktree "$repo" 2> /dev/null)
assert_contains "$(grep '^sandbox=' <<< "$default_view")" 'measured-by=agent-shell' \
    'the default (agent-shell) run is now provenance-tagged too'

hook_view=$("$script" --worktree "$repo" --measured-from hook 2> /dev/null)
assert_contains "$(grep '^sandbox=' <<< "$hook_view")" 'measured-by=hook' \
    'a hook-measured run is tagged measured-by=hook'

escalated_repo=$(new_repo)
escalated_view=$("$script" --worktree "$escalated_repo" --measured-from escalated 2> /dev/null)
escalated_sandbox=$(grep '^sandbox=' <<< "$escalated_view")
assert_contains "$escalated_sandbox" 'measured-by=escalated' \
    'an explicitly-asserted escalated run is tagged measured-by=escalated'
assert_contains "$escalated_sandbox" 'this probe does not detect that state itself' \
    'the escalated tag discloses it was asserted, not detected'

# An escalated run inside a sandboxed workspace must keep BOTH sentences
# (issue #332 F1): the escalated branch used to replace note= wholesale,
# silently dropping the actionable "escalate git writes and forge calls"
# guidance a worker needs before it hits a refusal. CODEX_PERMISSION_PROFILE
# forces sandboxed=yes deterministically, independent of this machine's real
# sandbox state.
escalated_sandboxed_repo=$(new_repo)
escalated_sandboxed_view=$(CODEX_PERMISSION_PROFILE=test-profile \
    "$script" --worktree "$escalated_sandboxed_repo" --measured-from escalated 2> /dev/null)
escalated_sandboxed_sandbox=$(grep '^sandbox=' <<< "$escalated_sandboxed_view")
assert_contains "$escalated_sandboxed_sandbox" 'escalate git writes and forge calls' \
    'an escalated run inside a sandbox keeps the sandboxed-workspace guidance'
assert_contains "$escalated_sandboxed_sandbox" 'this probe does not detect that state itself' \
    'an escalated run inside a sandbox also keeps the escalated-disclosure sentence'

assert_rc 2 '--measured-from still rejects an unrecognised class' -- \
    "$script" --worktree "$repo" --measured-from somewhere-else

# "agent" was the pre-#332 public value on main (--measured-from agent|hook,
# documented as the default). A caller outside this tree may still pass it;
# it must be accepted as an alias for agent-shell, not a hard failure that
# leaves a contract-producing script with no contract to produce.
alias_repo=$(new_repo)
alias_view=$("$script" --worktree "$alias_repo" --measured-from agent 2> /dev/null)
assert_contains "$(grep '^sandbox=' <<< "$alias_view")" 'measured-by=agent-shell' \
    '--measured-from agent is accepted as a backward-compatible alias for agent-shell'

# --- never-widen: a more restrictive recorded sandbox=/caches= survives ------
# a less-restrictive re-measurement (issue #332). The scenario reproduces the
# reported bug directly: a prior run recorded a sandboxed, cache-isolated
# contract; a second, unsandboxed-looking run must not silently overwrite it.
repo=$(new_repo)
restrictive_contract="$repo/.agent/env-contract.txt"
printf '%s\n' \
    'sandbox= active=yes profile=none network=disabled home-writable=no measured-by=agent-shell note="escalate git writes and forge calls; only the workspace is writable"' \
    'tls= bundle=none source=none corporate-ca=unknown preset=none uv-system-certs=unknown' \
    'caches= root=/tmp/agent-cache-9999 reason=home-cache-unwritable home-cache=/nonexistent/.cache UV_CACHE_DIR=/tmp/agent-cache-9999/uv NPM_CONFIG_CACHE=/tmp/agent-cache-9999/npm PIP_CACHE_DIR=/tmp/agent-cache-9999/pip XDG_CACHE_HOME=/tmp/agent-cache-9999' \
    > "$restrictive_contract"
chmod 600 "$restrictive_contract"
widen_err=$("$script" --worktree "$repo" 2>&1 > /dev/null)
assert_contains "$widen_err" 'keeping the more-restrictive recorded sandbox=' \
    'a less-restrictive re-measurement of sandbox= reports the disagreement on stderr'
assert_contains "$widen_err" 'keeping the more-restrictive recorded caches=' \
    'a less-restrictive re-measurement of caches= reports the disagreement on stderr'
assert_rc 0 'the never-widen guard still exits 0' -- "$script" --worktree "$repo"
after_widen=$(cat -- "$restrictive_contract")
assert_eq 'sandbox= active=yes profile=none network=disabled home-writable=no measured-by=agent-shell note="escalate git writes and forge calls; only the workspace is writable"' \
    "$(grep '^sandbox=' <<< "$after_widen")" \
    'the more-restrictive recorded sandbox= line is kept byte-for-byte'
assert_contains "$(grep '^caches=' <<< "$after_widen")" 'reason=home-cache-unwritable' \
    'the more-restrictive recorded caches= line is kept'

# --- a spoofed reason= sequence embedded in home-cache= must not out-match --
# the real, earlier reason= (issue #332 F2, round 2). home-cache= is fed by
# XDG_CACHE_HOME/HOME and sits AFTER the genuine reason= in the fixed field
# order; a value containing a complete "reason=... home-cache=..." sequence
# of its own defeats a trailing-context anchor just as easily as the naive
# greedy regex it replaced, since the fake occurrence is ALSO followed by a
# home-cache= token. Only anchoring at the record's start -- past exactly one
# whitespace-free root= token -- closes this: nothing attacker-controlled can
# precede the genuine reason= at that fixed position.
caches_repo=$(new_repo)
caches_contract="$caches_repo/.agent/env-contract.txt"
printf '%s\n' \
    'caches= root=/tmp/agent-cache-restrictive reason=home-cache-unwritable home-cache=/nonexistent/.cache UV_CACHE_DIR=/tmp/agent-cache-restrictive/uv NPM_CONFIG_CACHE=/tmp/agent-cache-restrictive/npm PIP_CACHE_DIR=/tmp/agent-cache-restrictive/pip XDG_CACHE_HOME=/tmp/agent-cache-restrictive' \
    > "$caches_contract"
chmod 600 "$caches_contract"
caches_session="$tmp/caches-spoof-session-contract.txt"
printf '%s\ncaches= root=/tmp/agent-cache-7 reason=home-cache-writable home-cache=/home/u/.cache reason=home-cache-unwritable home-cache=/tmp/spoof UV_CACHE_DIR=/tmp/agent-cache-7/uv NPM_CONFIG_CACHE=/tmp/agent-cache-7/npm PIP_CACHE_DIR=/tmp/agent-cache-7/pip XDG_CACHE_HOME=/tmp/agent-cache-7\n' \
    "$current_harness_line" > "$caches_session"
caches_spoof_err=$("$script" --worktree "$caches_repo" --inherit-session "$caches_session" 2>&1 > /dev/null)
assert_contains "$caches_spoof_err" 'keeping the more-restrictive recorded caches=' \
    'an embedded reason=...home-cache=... sequence inside home-cache= does not mask a real caches= widening'
assert_contains "$(grep '^caches=' "$caches_contract")" 'reason=home-cache-unwritable' \
    'the spoofed caches= scenario keeps the recorded (restrictive) caches= line, not the fresh one'

# --- a whitespace-bearing TMPDIR must not make the RESTRICTIVE record itself
# unparseable (issue #332 F2, round 3). Round 2's whitespace refusal covered
# only AGENT_CACHE_ROOT; TMPDIR feeds root= too, in exactly the branch that
# produces the restrictive home-cache-unwritable record. An unwritable
# $HOME/.cache plus a space-bearing TMPDIR used to emit a caches= line whose
# root= swallowed a literal space, so caches_restriction_score() could not
# find " reason=" at the expected position and scored it as unparseable
# (0, before this fix) -- indistinguishable from a genuinely widened
# home-cache-writable record (also 0), so the guard missed the widening.
tmpdir_repo=$(new_repo)
tmpdir_home="$tmp/tmpdir-unwritable-home"
mkdir -p "$tmpdir_home"
chmod 000 "$tmpdir_home"
weird_tmpdir="$tmp/weird tmpdir"
mkdir -p "$weird_tmpdir"
HOME="$tmpdir_home" TMPDIR="$weird_tmpdir" \
    "$script" --worktree "$tmpdir_repo" > /dev/null 2>&1
chmod 700 "$tmpdir_home"
tmpdir_recorded=$(grep '^caches=' "$tmpdir_repo/.agent/env-contract.txt")
assert_contains "$tmpdir_recorded" 'reason=home-cache-unwritable' \
    'a whitespace-bearing TMPDIR still records a well-formed, restrictive caches= line'
assert_not_contains "$tmpdir_recorded" 'weird tmpdir' \
    'the whitespace-bearing TMPDIR value itself is not used as root='
tmpdir_widen_home="$tmp/tmpdir-writable-home"
mkdir -p "$tmpdir_widen_home"
tmpdir_widen_err=$(HOME="$tmpdir_widen_home" \
    "$script" --worktree "$tmpdir_repo" 2>&1 > /dev/null)
assert_contains "$tmpdir_widen_err" 'keeping the more-restrictive recorded caches=' \
    'a later home-cache-writable measurement is still caught as a widening after a whitespace-bearing TMPDIR run'
assert_contains "$(grep '^caches=' "$tmpdir_repo/.agent/env-contract.txt")" 'reason=home-cache-unwritable' \
    'the whitespace-bearing-TMPDIR scenario keeps the recorded restrictive caches= line, not the fresh one'

# --- an unparseable/unrecognised reason= must rank in the MIDDLE, never as --
# the known least-restrictive value (issue #332 F2 round 3). Independent of
# the TMPDIR whitespace source above: ANY future cause of an unparseable
# caches= record (a malformed line, a reason= token this script doesn't know
# about yet) must fail closed rather than silently comparing equal to a
# genuinely widened home-cache-writable record. This fixture builds the
# malformed "recorded" line directly (missing root=) so it exercises the
# scoring rule itself, not the whitespace guard.
unknown_repo=$(new_repo)
unknown_contract="$unknown_repo/.agent/env-contract.txt"
printf '%s\n' \
    'caches= reason=home-cache-unwritable home-cache=/nonexistent/.cache UV_CACHE_DIR=/tmp/x/uv NPM_CONFIG_CACHE=/tmp/x/npm PIP_CACHE_DIR=/tmp/x/pip XDG_CACHE_HOME=/tmp/x' \
    > "$unknown_contract"
chmod 600 "$unknown_contract"
unknown_session="$tmp/unknown-session-contract.txt"
printf '%s\ncaches= root=/tmp/agent-cache-8 reason=home-cache-writable home-cache=/home/u/.cache UV_CACHE_DIR=/tmp/agent-cache-8/uv NPM_CONFIG_CACHE=/tmp/agent-cache-8/npm PIP_CACHE_DIR=/tmp/agent-cache-8/pip XDG_CACHE_HOME=/tmp/agent-cache-8\n' \
    "$current_harness_line" > "$unknown_session"
unknown_err=$("$script" --worktree "$unknown_repo" --inherit-session "$unknown_session" 2>&1 > /dev/null)
assert_contains "$unknown_err" 'keeping the more-restrictive recorded caches=' \
    'an unparseable recorded caches= line ranks as uncertain, not as freely widenable'
assert_contains "$(grep '^caches=' "$unknown_contract")" 'reason=home-cache-unwritable' \
    'the unparseable-record scenario keeps the recorded line, not a widened fresh one'

# --- field-by-field widen detection: no single axis may mask another --------
# (issue #332 F2). A scalar SUM lets one axis's tightening cancel out
# another axis's widening: active tightening no->yes (+2 under the old
# scorer) while network widens disabled->ok (-2) nets to "no change" in a
# sum, even though the worker just silently lost its network restriction.
# --inherit-session gives full, deterministic control over the "fresh" line.
masking_repo=$(new_repo)
masking_contract="$masking_repo/.agent/env-contract.txt"
printf 'sandbox= active=no profile=none network=disabled home-writable=yes measured-by=agent-shell\n' \
    > "$masking_contract"
chmod 600 "$masking_contract"
masking_session="$tmp/masking-session-contract.txt"
printf '%s\nsandbox= active=yes profile=none network=ok home-writable=yes measured-by=agent-shell\n' \
    "$current_harness_line" > "$masking_session"
masking_err=$("$script" --worktree "$masking_repo" --inherit-session "$masking_session" 2>&1 > /dev/null)
assert_contains "$masking_err" "keeping the more-restrictive recorded sandbox= (a fresh measurement would widen field 'network')" \
    "a network widening masked by an active tightening is still caught, and names the regressed field"
assert_eq 'sandbox= active=no profile=none network=disabled home-writable=yes measured-by=agent-shell' \
    "$(grep '^sandbox=' "$masking_contract")" \
    'the masked-widening scenario keeps the recorded sandbox= line, not the fresh one'

# --- a spoofed field= token inside note= must not out-match the real field --
# (issue #332 F2). note= is free-form and sits at the end of the line; a
# naive greedy `.*field=` search prefers the RIGHTMOST match, so an embedded
# "active=yes" inside note= would previously have been read as the real
# active= value instead of the genuine, earlier one -- letting a fresh
# measurement that actually widened (active regressed yes->no) compare as
# unchanged and slip past the guard.
spoof_repo=$(new_repo)
spoof_contract="$spoof_repo/.agent/env-contract.txt"
printf 'sandbox= active=yes profile=none network=disabled home-writable=no measured-by=agent-shell note="escalate git writes and forge calls; only the workspace is writable"\n' \
    > "$spoof_contract"
chmod 600 "$spoof_contract"
spoof_session="$tmp/spoof-session-contract.txt"
printf '%s\nsandbox= active=no profile=none network=disabled home-writable=no measured-by=agent-shell note="spoofed trailing text containing active=yes to mislead a naive parser"\n' \
    "$current_harness_line" > "$spoof_session"
spoof_err=$("$script" --worktree "$spoof_repo" --inherit-session "$spoof_session" 2>&1 > /dev/null)
assert_contains "$spoof_err" "keeping the more-restrictive recorded sandbox= (a fresh measurement would widen field 'active')" \
    "an embedded active= token inside note= does not mask a real active= widening"
assert_eq 'sandbox= active=yes profile=none network=disabled home-writable=no measured-by=agent-shell note="escalate git writes and forge calls; only the workspace is writable"' \
    "$(grep '^sandbox=' "$spoof_contract")" \
    'the spoofed-note scenario keeps the recorded sandbox= line, not the fresh one'

# A worktree with no prior contract records its first measurement normally --
# there is nothing recorded yet for the guard to protect.
repo=$(new_repo)
"$script" --worktree "$repo" > /dev/null 2>&1
first_sandbox=$(grep '^sandbox=' "$repo/.agent/env-contract.txt")
assert_contains "$first_sandbox" 'measured-by=agent-shell' \
    'a worktree with no prior contract records its first measurement normally'

# A fresh measurement that TIGHTENS the recorded restriction must still win --
# the guard only refuses to widen. --inherit-session gives full control over
# the "fresh" line without depending on this machine's real sandbox state.
repo=$(new_repo)
loose_contract="$repo/.agent/env-contract.txt"
printf 'sandbox= active=no profile=none network=ok home-writable=yes measured-by=agent-shell\n' \
    > "$loose_contract"
chmod 600 "$loose_contract"
tighter_session="$tmp/tighter-session-contract.txt"
printf '%s\nsandbox= active=yes profile=strict network=disabled home-writable=no measured-by=agent-shell note="escalate git writes and forge calls; only the workspace is writable"\n' \
    "$current_harness_line" > "$tighter_session"
tighten_err=$("$script" --worktree "$repo" --inherit-session "$tighter_session" 2>&1 > /dev/null)
assert_not_contains "$tighten_err" 'keeping the more-restrictive recorded sandbox=' \
    'a tightening re-measurement is not treated as a widening'
assert_eq 'sandbox= active=yes profile=strict network=disabled home-writable=no measured-by=agent-shell note="escalate git writes and forge calls; only the workspace is writable"' \
    "$(grep '^sandbox=' "$loose_contract")" \
    'a tightening re-measurement replaces the previously recorded looser line'

# --- --inherit-session carries session-scoped lines forward verbatim --------
# sandbox=, tls=, and caches= describe the session, not any one worktree
# (issue #332); create-issue-worktree.sh relies on this to avoid re-measuring
# them in a differently-privileged process.
session_repo=$(new_repo)
session_contract="$session_repo/.agent/env-contract.txt"
printf '%s\n' \
    "$current_harness_line" \
    'sandbox= active=yes profile=strict network=disabled home-writable=no measured-by=agent-shell note="escalate git writes and forge calls; only the workspace is writable"' \
    'tls= bundle=/etc/ssl/certs/ca-certificates.crt source=system corporate-ca=no preset=none uv-system-certs=not-needed' \
    'caches= root=/tmp/agent-cache-inherit reason=home-cache-unwritable home-cache=/nonexistent/.cache UV_CACHE_DIR=/tmp/agent-cache-inherit/uv NPM_CONFIG_CACHE=/tmp/agent-cache-inherit/npm PIP_CACHE_DIR=/tmp/agent-cache-inherit/pip XDG_CACHE_HOME=/tmp/agent-cache-inherit' \
    > "$session_contract"
chmod 600 "$session_contract"

target_repo=$(new_repo)
inherit_out=$("$script" --worktree "$target_repo" --inherit-session "$session_contract" 2> "$tmp/inherit-stderr")
assert_eq "$(grep '^sandbox=' <<< "$inherit_out")" "$(grep '^sandbox=' "$session_contract")" \
    'the worktree contract carries the session sandbox= line verbatim (byte equality)'
assert_eq "$(grep '^tls=' <<< "$inherit_out")" "$(grep '^tls=' "$session_contract")" \
    'the worktree contract carries the session tls= line verbatim (byte equality)'
assert_eq "$(grep '^caches=' <<< "$inherit_out")" "$(grep '^caches=' "$session_contract")" \
    'the worktree contract carries the session caches= line verbatim (byte equality)'
assert_contains "$(cat "$tmp/inherit-stderr")" 'inherited sandbox=' \
    '--inherit-session discloses on stderr that it copied rather than measured'
assert_contains "$(grep '^sandbox=' <<< "$inherit_out")" 'note="escalate git writes' \
    'a note= present on the authoritative sandbox= line survives inheritance'

# --- --inherit-session only trusts a source verified as belonging to THIS ---
# session (issue #332 F3): agreement between a root and a worktree contract
# proves nothing if both are the same stale bytes left over from an earlier,
# differently-privileged session. There is no cryptographic session identity
# available, so this is a heuristic (recency + same-harness) -- the same
# established heuristic session-start.sh already uses for "is this recorded
# context still current" -- and its absence must fall back to a fresh probe,
# not silently accept the stale bytes.
stale_repo=$(new_repo)
stale_session="$tmp/stale-session-contract.txt"
printf '%s\nsandbox= active=yes profile=strict network=disabled home-writable=no measured-by=agent-shell note="escalate git writes and forge calls; only the workspace is writable"\n' \
    "$current_harness_line" > "$stale_session"
# Backdate well past INHERIT_SESSION_MAX_AGE_MINUTES (30m).
touch -d '2 hours ago' "$stale_session" 2> /dev/null || touch -t "$(date -d '2 hours ago' +%Y%m%d%H%M 2> /dev/null || date -v-2H +%Y%m%d%H%M)" "$stale_session"
stale_err=$("$script" --worktree "$stale_repo" --inherit-session "$stale_session" 2>&1 > /dev/null)
assert_contains "$stale_err" 'older than 30m' \
    'a stale --inherit-session source is refused with its age named'
assert_contains "$stale_err" 'falling back to a fresh probe' \
    'and the run falls back to a fresh probe rather than failing'
stale_out=$("$script" --worktree "$stale_repo" --inherit-session "$stale_session" 2> /dev/null)
assert_not_contains "$(grep '^sandbox=' <<< "$stale_out")" 'active=yes profile=strict network=disabled' \
    'the stale contract'"'"'s sandbox= bytes are not the ones that get served'

mismatch_repo=$(new_repo)
mismatch_session="$tmp/mismatch-session-contract.txt"
printf 'harness= name=some-other-cli trailer="Other <noreply@example.invalid>" other=none\nsandbox= active=yes profile=strict network=disabled home-writable=no measured-by=agent-shell note="escalate git writes and forge calls; only the workspace is writable"\n' \
    > "$mismatch_session"
mismatch_err=$("$script" --worktree "$mismatch_repo" --inherit-session "$mismatch_session" 2>&1 > /dev/null)
assert_contains "$mismatch_err" 'does not match this session' \
    'a source contract from a different harness is refused, naming the mismatch'
mismatch_out=$("$script" --worktree "$mismatch_repo" --inherit-session "$mismatch_session" 2> /dev/null)
assert_not_contains "$(grep '^sandbox=' <<< "$mismatch_out")" 'active=yes profile=strict network=disabled' \
    'the cross-harness contract'"'"'s sandbox= bytes are not the ones that get served'

# A missing or unreadable --inherit-session file falls back to a fresh probe
# for every line, rather than failing the run: reporting, never blocking.
fallback_out=$("$script" --worktree "$(new_repo)" --inherit-session "$tmp/does-not-exist.txt" 2> /dev/null)
assert_contains "$fallback_out" 'sandbox=' \
    'a missing --inherit-session file still produces a full sandbox= line'
assert_contains "$(grep '^sandbox=' <<< "$fallback_out")" 'measured-by=agent-shell' \
    'the fallback measurement is freshly probed, not fabricated'

assert_rc 2 '--ensure rejects an explicit --inherit-session override' -- \
    "$script" --ensure --worktree "$repo" --inherit-session "$session_contract"

finish
