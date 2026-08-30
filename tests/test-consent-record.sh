#!/usr/bin/env bash
# Boundary coverage for the executable cross-provider consent record.
set -uo pipefail

TEST_NAME='consent-record'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/consent-record.sh"
runner="$root/agentkit/skills/review-remote-pr/scripts/adversarial-run.sh"
claude="$root/agentkit/skills/review-remote-pr/scripts/claude-adversarial-review.sh"
codex="$root/agentkit/skills/review-remote-pr/scripts/codex-adversarial-review.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

state_dir="$tmp/state"
mkdir -- "$state_dir"
chmod 700 -- "$state_dir"
diff_one="$tmp/diff-one"
diff_two="$tmp/diff-two"
printf '%s\n' 'exact diff bytes one' >"$diff_one"
printf '%s\n' 'exact diff bytes two' >"$diff_two"
empty_diff="$tmp/diff-empty"
: >"$empty_diff"
whitespace_diff="$tmp/diff-whitespace"
printf '   \n\t\n  \n' >"$whitespace_diff"

payload_one="acme/widget:24:$(sha256sum -- "$diff_one" | awk '{print $1}')"
payload_two="acme/widget:24:$(sha256sum -- "$diff_two" | awk '{print $1}')"
state="$state_dir/record"

# Consent derivation is explicitly rooted in the PR worktree and run directory;
# it must remain usable when the caller is sitting at the repository root (or
# any other unrelated current directory).
explicit_worktree="$tmp/explicit-worktree"
explicit_run_dir="$tmp/explicit-run"
mkdir -- "$explicit_worktree" "$explicit_run_dir"
chmod 700 -- "$explicit_worktree" "$explicit_run_dir"
explicit_payload=''
explicit_payload=$(cd -- / || exit
    /bin/bash "$script" payload --worktree "$explicit_worktree" --run-dir "$explicit_run_dir" \
        --repo acme/widget --pr 24 --diff "$diff_one")
assert_eq "$payload_one" "$explicit_payload" \
    'payload accepts explicit worktree and run directory outside the current directory'
assert_contains "$(cat -- "$runner")" 'CONSENT_STATE_FILENAME' \
    'adversarial runner consumes the shared consent-state filename constant'
assert_eq 1 "$(awk '{ count += gsub(/cross-provider-consent/, "") } END { print count + 0 }' \
    "$script" "$runner")" \
    'consent-state filename has one spelling across both scripts'

explicit_grant_run="$tmp/explicit-grant-run"
mkdir -- "$explicit_grant_run"
chmod 700 -- "$explicit_grant_run"
/bin/bash "$script" grant --worktree "$explicit_worktree" --run-dir "$explicit_grant_run" \
    --provider anthropic --payload "$payload_one" --source interactive >/dev/null
assert_eq yes "$( [[ -f $explicit_grant_run/state/cross-provider-consent ]] && printf yes || printf no )" \
    'grant writes the filename consumed by adversarial-run check'
assert_rc 0 'the runner-compatible explicit grant passes an explicit check' -- \
    /bin/bash "$script" check --worktree "$explicit_worktree" --run-dir "$explicit_grant_run" \
    --provider anthropic --payload "$payload_one"

# Legacy state paths remain independent of the caller's current directory for
# every state operation, including informational disclosure.
legacy_state="$state_dir/legacy-record"
legacy_grant_rc=0
(cd -- / || exit
    /bin/bash "$script" grant --state "$legacy_state" --provider anthropic \
        --payload "$payload_one" --source interactive) >/dev/null || legacy_grant_rc=$?
assert_eq 0 "$legacy_grant_rc" 'legacy grant with --state works outside the Git worktree'
legacy_check() {
    cd -- / || return
    /bin/bash "$script" check --state "$legacy_state" --provider anthropic --payload "$payload_one"
}
assert_rc 0 'legacy check with --state works outside the Git worktree' -- \
    legacy_check
legacy_disclosure=$(cd -- / || exit
    /bin/bash "$script" disclose --state "$legacy_state" --payload "$payload_one" \
        --destination 'Anthropic via Claude' --purpose 'one adversarial review of that diff')
assert_contains "$legacy_disclosure" "payload=$payload_one" \
    'legacy disclose with --state works outside the Git worktree'

# Payload identity is derived from the repository, PR number and exact diff bytes.
out=$(/bin/bash "$script" payload --repo acme/widget --pr 24 --diff "$diff_one")
assert_eq "$payload_one" "$out" 'payload derives the repo, PR and exact diff hash'
assert_not_contains "$out" "$payload_two" 'changed diff bytes change the payload identity'

# PR numbers are only unique within one repository. Identical bytes under the
# same number in a second repository must NOT derive the same payload, or a
# reused record would satisfy check for a repository never disclosed.
other_repo_payload=$(/bin/bash "$script" payload --repo acme/other --pr 24 --diff "$diff_one")
assert_eq differ \
    "$( [[ $out != "$other_repo_payload" ]] && printf differ || printf same )" \
    'the same PR number and diff bytes in another repository derive a different payload'
# Granted for acme/widget in its own record, so the rejection below can only be
# the repository mismatch -- not a missing state file and not a changed digest.
cross_state="$state_dir/cross-repo-record"
/bin/bash "$script" grant --state "$cross_state" --provider anthropic \
    --payload "$out" --source interactive >/dev/null
assert_rc 10 'consent granted for one repository does not check out for another' -- \
    /bin/bash "$script" check --state "$cross_state" --provider anthropic \
    --payload "$other_repo_payload"
missing_repo_error=''
missing_repo_rc=0
missing_repo_error=$(/bin/bash "$script" payload --pr 24 --diff "$diff_one" 2>&1) || missing_repo_rc=$?
assert_eq 2 "$missing_repo_rc" 'payload refuses a missing repository'
assert_contains "$missing_repo_error" 'Usage:' \
    'missing repository rejection includes a copyable payload recipe'
assert_rc 2 'payload refuses a repository carrying the payload delimiter' -- \
    /bin/bash "$script" payload --repo 'acme/wid:get' --pr 24 --diff "$diff_one"

# The consent helper and adversarial runner must hash one canonical renderer,
# not two independently assembled diff commands. A base-ref payload derives
# the bytes itself and rejects a caller-supplied diff that drifts from them.
canonical_origin="$tmp/canonical-origin.git"
canonical_repo="$tmp/canonical-repo"
git init --bare --quiet "$canonical_origin"
git init --quiet --initial-branch=main "$canonical_repo"
git -C "$canonical_repo" config user.email test@example.invalid
git -C "$canonical_repo" config user.name test
git -C "$canonical_repo" remote add origin "$canonical_origin"
printf '%s\n' canonical-base >"$canonical_repo/example.txt"
git -C "$canonical_repo" add example.txt
git -C "$canonical_repo" commit --quiet -m base
git -C "$canonical_repo" push --quiet -u origin main
git -C "$canonical_repo" switch --quiet -c feature
printf '%s\n' canonical-head >"$canonical_repo/example.txt"
git -C "$canonical_repo" commit --quiet -am change
canonical_diff="$tmp/canonical.diff"
git -C "$canonical_repo" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$canonical_diff"
canonical_payload=$(
    cd -- "$canonical_repo" || exit
    /bin/bash "$script" payload --worktree "$canonical_repo" --repo acme/widget --pr 24 --base-ref main --diff "$canonical_diff"
)
canonical_expected="acme/widget:24:$(sha256sum -- "$canonical_diff" | awk '{print $1}')"
assert_eq "$canonical_expected" "$canonical_payload" \
    'base-ref payload hashes the canonical adversarial renderer'
derived_payload=$(
    cd -- "$canonical_repo" || exit
    /bin/bash "$script" payload --worktree "$canonical_repo" --repo acme/widget --pr 24 --base-ref main
)
assert_eq "$canonical_payload" "$derived_payload" \
    'base-ref payload derives the same identity without a caller-rendered diff'

# A direct consent derivation may run before the launcher. Refresh the remote
# base first, or it can grant a payload for stale origin/main bytes that the
# launcher rejects after its own fetch.
stale_origin_oid=$(git -C "$canonical_repo" rev-parse origin/main)
updater="$tmp/canonical-updater"
git clone --quiet --branch main "$canonical_origin" "$updater"
git -C "$updater" config user.email test@example.invalid
git -C "$updater" config user.name test
printf '%s\n' origin-refresh >"$updater/base-only.txt"
git -C "$updater" add base-only.txt
git -C "$updater" commit --quiet -m 'refresh base'
git -C "$updater" push --quiet origin main
fresh_origin_oid=$(git -C "$updater" rev-parse HEAD)
assert_eq differ "$( [[ $stale_origin_oid != "$fresh_origin_oid" ]] && printf differ || printf same )" \
    'test fixture advances the remote base while local origin/main is stale'
(
    cd -- "$canonical_repo" || exit
    git fetch --quiet origin main:refs/remotes/origin/refresh-base
    git merge --quiet --no-ff --no-edit refs/remotes/origin/refresh-base
    git update-ref refs/remotes/origin/main "$stale_origin_oid"
)
assert_eq "$fresh_origin_oid" "$(git -C "$canonical_repo" rev-parse HEAD^2)" \
    'test fixture merges the refreshed base into the PR head'
stale_files=$(git -C "$canonical_repo" --no-pager diff --name-only origin/main...HEAD)
assert_contains "$stale_files" 'base-only.txt' \
    'stale origin/main rendering includes the merged base-only file'
stale_expected_payload="acme/widget:24:$(git -C "$canonical_repo" --no-pager diff \
    --find-renames --unified=25 origin/main...HEAD | sha256sum | awk '{print $1}')"
stale_direct_payload=$(
    cd -- "$canonical_repo" || exit
    /bin/bash "$script" payload --worktree "$canonical_repo" --repo acme/widget --pr 24 --base-ref main
)
expected_after_refresh=$(
    cd -- "$canonical_repo" || exit
    git fetch --quiet origin main
    /bin/bash "$script" payload --worktree "$canonical_repo" --repo acme/widget --pr 24 --base-ref main
)
assert_eq differ "$( [[ $expected_after_refresh != "$stale_expected_payload" ]] && printf differ || printf same )" \
    'stale and refreshed base refs produce different payload identities'
assert_eq "$expected_after_refresh" "$stale_direct_payload" \
    'base-ref payload refreshes origin before deriving consent'
assert_eq "$fresh_origin_oid" "$(git -C "$canonical_repo" rev-parse origin/main)" \
    'base-ref payload updates the local remote-tracking base ref'
printf '%s\n' drifted >"$canonical_diff"
drift_payload() {
    cd -- "$canonical_repo" || return
    /bin/bash "$script" payload --worktree "$canonical_repo" --repo acme/widget --pr 24 --base-ref main --diff "$canonical_diff"
}
assert_rc 1 'base-ref payload rejects rendering drift' -- \
    drift_payload

# An empty or whitespace-only diff must never mint a valid-looking payload --
# sha256sum of empty/whitespace input is still a well-formed 64-hex digest, so
# the emptiness check has to run before hashing, not rely on digest shape.
empty_supplied_error=''
empty_supplied_rc=0
empty_supplied_error=$(/bin/bash "$script" payload --repo acme/widget --pr 24 \
    --diff "$empty_diff" 2>&1) || empty_supplied_rc=$?
assert_eq 1 "$empty_supplied_rc" 'payload refuses an empty supplied diff'
assert_contains "$empty_supplied_error" 'empty' \
    'empty supplied diff rejection names the empty diff'

whitespace_supplied_rc=0
/bin/bash "$script" payload --repo acme/widget --pr 24 \
    --diff "$whitespace_diff" >/dev/null 2>&1 || whitespace_supplied_rc=$?
assert_eq 1 "$whitespace_supplied_rc" 'payload refuses a whitespace-only supplied diff'

# The same refusal applies when a base-ref is also given: an explicitly
# supplied empty diff must not slip through under a mismatch message, or any
# other message that doesn't name the actual cause.
supplied_empty_with_base_error=''
supplied_empty_with_base_rc=0
supplied_empty_with_base_error=$(
    cd -- "$canonical_repo" || exit
    /bin/bash "$script" payload --worktree "$canonical_repo" --repo acme/widget --pr 24 --base-ref main --diff "$empty_diff" 2>&1
) || supplied_empty_with_base_rc=$?
assert_eq 1 "$supplied_empty_with_base_rc" \
    'payload refuses an empty supplied diff even alongside a non-empty base-ref'
assert_contains "$supplied_empty_with_base_error" 'empty' \
    'empty supplied diff with base-ref names the empty diff'

# A canonical (base-ref-derived) diff can itself be empty -- run outside the PR
# worktree, or HEAD already equals the base -- and must fail closed too.
empty_base_origin="$tmp/empty-base-origin.git"
empty_base_repo="$tmp/empty-base-repo"
git init --bare --quiet "$empty_base_origin"
git init --quiet --initial-branch=main "$empty_base_repo"
git -C "$empty_base_repo" config user.email test@example.invalid
git -C "$empty_base_repo" config user.name test
git -C "$empty_base_repo" remote add origin "$empty_base_origin"
printf '%s\n' base-only >"$empty_base_repo/example.txt"
git -C "$empty_base_repo" add example.txt
git -C "$empty_base_repo" commit --quiet -m base
git -C "$empty_base_repo" push --quiet -u origin main
empty_base_error=''
empty_base_rc=0
empty_base_error=$(
    cd -- "$empty_base_repo" || exit
    /bin/bash "$script" payload --worktree "$empty_base_repo" --repo acme/widget --pr 24 --base-ref main 2>&1
) || empty_base_rc=$?
assert_eq 1 "$empty_base_rc" \
    'payload refuses an empty canonical diff when HEAD already equals origin/main'
assert_contains "$empty_base_error" 'empty' \
    'empty canonical diff rejection names the empty diff'

# Disclosure is informational only and cannot create consent state.
disclosure=$(/bin/bash "$script" disclose --payload "$payload_one" \
    --destination 'Anthropic via Claude' --purpose 'one adversarial review of that diff')
assert_contains "$disclosure" "payload=$payload_one" 'disclose prints the source payload'
assert_contains "$disclosure" 'destination=Anthropic via Claude' 'disclose prints the destination'
assert_contains "$disclosure" 'purpose=one adversarial review of that diff' 'disclose prints the purpose'
assert_eq no "$( [[ ! -e $state ]] && printf no || printf yes )" \
    'disclose has no state side effect'

# Grant accepts only an explicit source and persists a secure exact record.
grant=$(/bin/bash "$script" grant --state "$state" --provider anthropic \
    --payload "$payload_one" --source interactive)
expected="cross_provider_consent=anthropic;scope=PR-diff;payload=$payload_one;status=granted;source=interactive"
assert_eq "$expected" "$(<"$state")" 'grant persists the exact consent record'
assert_eq 600 "$(stat -c %a -- "$state")" 'grant secures the record at mode 0600'
assert_eq "$expected" "$grant" 'grant prints the persisted record'

assert_rc 0 'check accepts an exact provider and payload' -- \
    /bin/bash "$script" check --state "$state" --provider anthropic --payload "$payload_one"
assert_rc 10 'check rejects a changed payload' -- \
    /bin/bash "$script" check --state "$state" --provider anthropic --payload "$payload_two"
assert_rc 10 'check rejects a changed provider' -- \
    /bin/bash "$script" check --state "$state" --provider openai --payload "$payload_one"

# A second explicit grant may use the orchestrator's invocation-line source.
grant=$(/bin/bash "$script" grant --state "$state" --provider openai \
    --payload "$payload_two" --source auto-review-flag)
assert_contains "$grant" 'source=auto-review-flag' 'auto-review source is recorded explicitly'
assert_rc 0 'check accepts the explicitly granted replacement payload' -- \
    /bin/bash "$script" check --state "$state" --provider openai --payload "$payload_two"
assert_rc 10 'the prior payload is not reusable after replacement' -- \
    /bin/bash "$script" check --state "$state" --provider anthropic --payload "$payload_one"

# `peer-cli=` names a CLI (codex, claude); adversarial-run.sh checks the
# consent record against the model-provider token that CLI runs on (openai,
# anthropic). A grant recorded under either spelling must satisfy the same
# check, so the caller never has to read the runner source to find the
# "right" token (#392).
codex_alias_state="$state_dir/codex-alias-record"
grant_alias=$(/bin/bash "$script" grant --state "$codex_alias_state" --provider codex \
    --payload "$payload_one" --source interactive)
codex_alias_expected="cross_provider_consent=openai;scope=PR-diff;payload=$payload_one;status=granted;source=interactive"
assert_eq "$codex_alias_expected" "$(<"$codex_alias_state")" \
    'grant normalizes the codex CLI name to its openai provider token'
assert_eq "$codex_alias_expected" "$grant_alias" 'grant prints the normalized record'
assert_rc 0 "the runner's check for the Codex path accepts a grant recorded under the codex CLI name" -- \
    /bin/bash "$script" check --state "$codex_alias_state" --provider openai --payload "$payload_one"
assert_rc 0 'a direct check under the codex CLI name also normalizes to the same record' -- \
    /bin/bash "$script" check --state "$codex_alias_state" --provider codex --payload "$payload_one"

claude_alias_state="$state_dir/claude-alias-record"
/bin/bash "$script" grant --state "$claude_alias_state" --provider claude \
    --payload "$payload_one" --source interactive >/dev/null
claude_alias_expected="cross_provider_consent=anthropic;scope=PR-diff;payload=$payload_one;status=granted;source=interactive"
assert_eq "$claude_alias_expected" "$(<"$claude_alias_state")" \
    'grant normalizes the claude CLI name to its anthropic provider token'
assert_rc 0 "the runner's check for the Claude path accepts a grant recorded under the claude CLI name" -- \
    /bin/bash "$script" check --state "$claude_alias_state" --provider anthropic --payload "$payload_one"

# A refused check must name the expected provider token and, when a record
# exists, the one actually recorded -- so a mismatch is diagnosable without
# reading the runner source.
mismatch_error=$(/bin/bash "$script" check --state "$codex_alias_state" --provider anthropic \
    --payload "$payload_one" 2>&1) || true
assert_contains "$mismatch_error" 'openai' 'a refused check names the token actually recorded'
assert_contains "$mismatch_error" 'anthropic' 'a refused check names the expected provider token'
no_record_error=$(/bin/bash "$script" check --state "$state_dir/never-granted" --provider openai \
    --payload "$payload_one" 2>&1) || true
assert_contains "$no_record_error" 'openai' 'a missing record still names the expected provider token'

# There is no implicit yes/auto-grant path, and invalid source values do not
# alter an existing record.
before=$(<"$state")
invalid_source_error=''
invalid_source_rc=0
invalid_source_error=$(/bin/bash "$script" grant --state "$state" --provider anthropic \
    --payload "$payload_one" --source yes 2>&1) || invalid_source_rc=$?
assert_eq 2 "$invalid_source_rc" 'grant rejects an unrecognized source'
assert_contains "$invalid_source_error" 'Usage:' \
    'invalid source rejection includes a copyable grant recipe'
assert_eq "$before" "$(<"$state")" 'invalid source leaves the existing record unchanged'
assert_rc 2 'grant rejects a --yes shortcut' -- \
    /bin/bash "$script" grant --state "$state" --provider anthropic \
    --payload "$payload_one" --yes

# State failures fail closed and never become a valid check.
assert_rc 2 'grant requires an explicit --run-dir or --state' -- \
    /bin/bash "$script" grant --provider anthropic --payload "$payload_one" --source interactive
assert_rc 2 'check requires an explicit --run-dir or --state' -- \
    /bin/bash "$script" check --provider anthropic --payload "$payload_one"
missing_state="$state_dir/missing/prN/state/record"
assert_rc 10 'check fails closed when state is unavailable' -- \
    /bin/bash "$script" check --state "$missing_state" --provider openai --payload "$payload_two"
missing_grant=''
missing_grant_rc=0
old_umask=$(umask)
umask 022
missing_grant=$(/bin/bash "$script" grant --state "$missing_state" --provider openai \
    --payload "$payload_two" --source interactive) || missing_grant_rc=$?
umask "$old_umask"
assert_eq 0 "$missing_grant_rc" 'grant creates missing nested private state parents'
assert_contains "$missing_grant" 'source=interactive' \
    'grant reports the newly persisted nested state record'
assert_eq 700 "$(stat -c %a -- "$state_dir/missing")" \
    'grant secures the first missing state parent despite umask'
assert_eq 700 "$(stat -c %a -- "$state_dir/missing/prN")" \
    'grant secures the second missing state parent despite umask'
assert_eq 700 "$(stat -c %a -- "$state_dir/missing/prN/state")" \
    'grant secures the nested state parent despite umask'
assert_eq 600 "$(stat -c %a -- "$missing_state")" \
    'grant secures the consent record after creating its parent'

symlink_state="$state_dir/symlink-record"
ln -s -- "$state" "$symlink_state"
assert_rc 10 'check rejects a state symlink' -- \
    /bin/bash "$script" check --state "$symlink_state" --provider openai --payload "$payload_two"
assert_rc 1 'grant rejects writing through a state symlink' -- \
    /bin/bash "$script" grant --state "$symlink_state" --provider openai \
    --payload "$payload_two" --source interactive

assert_rc 2 'grant rejects field-delimiter injection' -- \
    /bin/bash "$script" grant --state "$state" --provider 'openai;forged' \
    --payload "$payload_two" --source interactive

# The review launchers enforce the check before they can invoke either provider.
launch_dir="$tmp/launch"
mkdir -- "$launch_dir"
chmod 700 -- "$launch_dir"
counter="$launch_dir/provider-invoked"
cat >"$launch_dir/fake-provider" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch -- "$FAKE_PROVIDER_MARKER"
EOF
chmod 755 -- "$launch_dir/fake-provider"
for helper in "$claude" "$codex"; do
    launch_err="$launch_dir/$(basename "$helper").err"
    launch_rc=0
    if [[ $helper == *claude* ]]; then
        CLAUDE_EXECUTABLE="$launch_dir/fake-provider" \
            FAKE_PROVIDER_MARKER="$counter" /bin/bash "$helper" \
            --mode review --model claude-test --repo acme/widget --pr 24 --diff "$diff_one" \
            --consent-state "$launch_dir/missing/record" \
            --transcript "$launch_dir/claude.transcript" > /dev/null 2>"$launch_err" || launch_rc=$?
    else
        CODEX_EXECUTABLE="$launch_dir/fake-provider" \
            FAKE_PROVIDER_MARKER="$counter" /bin/bash "$helper" \
            --mode review --model gpt-test --repo acme/widget --pr 24 --diff "$diff_one" \
            --consent-state "$launch_dir/missing/record" \
            --transcript "$launch_dir/codex.transcript" > /dev/null 2>"$launch_err" || launch_rc=$?
    fi
    assert_eq 1 "$launch_rc" "$(basename "$helper") refuses a missing consent check"
    assert_contains "$(<"$launch_err")" 'consent' \
        "$(basename "$helper") reports the consent boundary"
done
assert_eq no "$( [[ ! -e $counter ]] && printf no || printf yes )" \
    'a refused launch never invokes the provider'

# --- issue #579: --base-ref accepts a full SHA that resolves locally, not --
# just a branch name -- a chain-base commit (parallel-issues' recorded
# `chain_base_sha`) is frequently unreachable from any branch tip by the time
# a later PR's review runs, and the old branch-only validator rejected it
# with "ambiguous argument 'origin/<sha>...HEAD'" once canonical_diff()
# prepended "origin/" to it.
sha_origin="$tmp/sha-origin.git"
sha_repo="$tmp/sha-repo"
git init --bare --quiet "$sha_origin"
git init --quiet --initial-branch=main "$sha_repo"
git -C "$sha_repo" config user.email test@example.invalid
git -C "$sha_repo" config user.name test
git -C "$sha_repo" remote add origin "$sha_origin"
printf '%s\n' sha-base >"$sha_repo/example.txt"
git -C "$sha_repo" add example.txt
git -C "$sha_repo" commit --quiet -m base
git -C "$sha_repo" push --quiet -u origin main
chain_base_sha=$(git -C "$sha_repo" rev-parse HEAD)
git -C "$sha_repo" switch --quiet -c feature
printf '%s\n' sha-head >"$sha_repo/example.txt"
git -C "$sha_repo" commit --quiet -am change

sha_payload=$(
    cd -- "$sha_repo" || exit
    /bin/bash "$script" payload --worktree "$sha_repo" --repo acme/widget --pr 24 --base-ref "$chain_base_sha"
)
sha_expected_digest=$(git -C "$sha_repo" --no-pager diff --find-renames --unified=25 \
    "$chain_base_sha...HEAD" | sha256sum | awk '{print $1}')
assert_eq "acme/widget:24:$sha_expected_digest" "$sha_payload" \
    'a resolvable chain-base SHA renders the same diff a branch-based base-ref would'

# A SHA base-ref must never attempt to fetch -- the whole point is that it is
# already local; proven by breaking origin and confirming the payload is
# unaffected.
git -C "$sha_repo" remote set-url origin "$tmp/nonexistent-origin.git"
sha_payload_no_origin=$(
    cd -- "$sha_repo" || exit
    /bin/bash "$script" payload --worktree "$sha_repo" --repo acme/widget --pr 24 --base-ref "$chain_base_sha"
)
assert_eq "$sha_payload" "$sha_payload_no_origin" \
    'a SHA base-ref never fetches, so an unreachable origin does not affect it'

# A SHA-shaped value that does NOT resolve locally is rejected, and the error
# names both accepted forms (branch name and full SHA).
unresolvable_sha=$(printf '%040d' 1)
unresolvable_error=''
unresolvable_rc=0
unresolvable_error=$(
    cd -- "$sha_repo" || exit
    /bin/bash "$script" payload --worktree "$sha_repo" --repo acme/widget --pr 24 --base-ref "$unresolvable_sha" 2>&1
) || unresolvable_rc=$?
assert_eq 2 "$unresolvable_rc" 'a SHA-shaped --base-ref that does not resolve locally is a usage error'
assert_contains "$unresolvable_error" 'branch name' \
    'the rejection names the branch-name form'
assert_contains "$unresolvable_error" 'SHA' \
    'the rejection also names the SHA form'

finish
