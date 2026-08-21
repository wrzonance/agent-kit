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
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

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

finish
