#!/usr/bin/env bash
# Missing, unsafe, and mistyped workflow artifacts name the actual remedy.
set -uo pipefail

TEST_NAME='owned path diagnostics'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

pr_green="$root/agentkit/skills/pr-to-green/scripts"
review="$root/agentkit/skills/review-remote-pr/scripts"
parallel="$root/agentkit/skills/parallel-issues/scripts"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

failure_output() {
    local rc=0 output
    output=$("$@" 2>&1) || rc=$?
    [[ $rc -ne 0 ]] || {
        printf 'command unexpectedly succeeded: %q' "$1" >&2
        return 1
    }
    printf '%s' "$output"
}

missing="$tmp/missing.json"
out=$(failure_output "$parallel/write-merge-plan.sh" \
    --dispatch-plan "$missing" --validate-only)
assert_contains "$out" 'input is missing' \
    'write-merge-plan distinguishes an absent input'
assert_contains "$out" 'dispatch planning' \
    'write-merge-plan names the stage that creates a dispatch plan'

ln -s -- "$tmp/missing-target.json" "$tmp/link.json"
out=$(failure_output "$parallel/write-merge-plan.sh" \
    --dispatch-plan "$tmp/link.json" --validate-only)
assert_contains "$out" 'path is a symlink' \
    'write-merge-plan classifies a dangling symlink as unsafe rather than absent'

mkdir -- "$tmp/directory.json"
out=$(failure_output "$parallel/write-merge-plan.sh" \
    --dispatch-plan "$tmp/directory.json" --validate-only)
assert_contains "$out" 'path is not a regular file' \
    'write-merge-plan distinguishes the wrong path type'

# CI normally runs as an unprivileged account, so a root-owned system file is
# a portable ownership boundary there. Root cannot observe an unowned file
# without a privilege-changing dependency, so keep that environment explicit.
if [[ ! -O /etc/hosts ]]; then
    out=$(failure_output "$parallel/write-merge-plan.sh" \
        --dispatch-plan /etc/hosts --validate-only)
    assert_contains "$out" 'path is not owned by the current user' \
        'write-merge-plan distinguishes an unowned input'
else
    _pass 'unowned-input assertion is inapplicable while the test process is root'
fi

out=$(failure_output "$review/compose-review-reply.sh" \
    --pr 1 --repo owner/repo --reply-to 2 --provider coderabbit \
    --disposition fixed --sha aaaaaaa --reasoning-file "$missing")
assert_contains "$out" 'remediation reasoning stage' \
    'compose-review-reply names the stage that creates reasoning'

out=$(failure_output "$review/thread-action.sh" \
    --pr 1 --repo owner/repo --threads-artifact "$missing" --thread-id T)
assert_contains "$out" 'review artifact collection stage' \
    'thread-action names the stage that creates the thread artifact'

out=$(failure_output "$review/consent-record.sh" payload \
    --repo owner/repo --pr 1 --diff "$missing")
assert_contains "$out" 'canonical diff rendering stage' \
    'consent-record names the stage that creates a supplied diff'

out=$(failure_output "$pr_green/merge-gate.sh" \
    --repo owner/repo --pr 1 --head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --base main --pr-state-digest "$missing" --provider-result NONE \
    --human-items-decided yes --adversarial-review-status not-required \
    --code-quality-scan-state not-enabled)
assert_contains "$out" 'gh-pr-state.sh' \
    'merge-gate names the producer of its missing digest'

out=$(failure_output "$pr_green/merge-pr.sh" \
    --repo owner/repo --pr 1 --head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --base main --merge-method squash --authorization-file "$missing" \
    --gate-result "$missing")
assert_contains "$out" 'authorize-queue.sh' \
    'merge-pr names the producer of its missing authorization'

repo="$tmp/repo"
mkdir -- "$repo"
ln -s -- "$repo" "$tmp/repo-link"
out=$(failure_output env PR_QUEUE_GH=true "$pr_green/pr-queue.sh" \
    --repo owner/repo --repo-root "$tmp/repo-link")
assert_not_contains "$out" 'path is a symlink' \
    'pr-queue preserves symlink-compatible --repo-root reads'

out=$(failure_output "$pr_green/authorize-queue.sh" \
    --repo owner/repo --repo-root "$repo" --confirmed-queue-file "$missing")
assert_contains "$out" 'repository onboarding stage' \
    'authorize-queue explains which stage creates .agent'

out=$(failure_output env PR_QUEUE_GH=true "$pr_green/pr-queue.sh" \
    --repo owner/repo --repo-root "$repo" --write-confirmed-queue --no-providers)
assert_contains "$out" 'repository onboarding stage' \
    'pr-queue explains which stage creates .agent'

provider="$tmp/provider"
printf '#!/usr/bin/env bash\nprintf "provider=none mode=disabled source=declared\\n"\n' >"$provider"
chmod +x -- "$provider"
out=$(failure_output env REVIEW_TRANSITION_GH=true \
    REVIEW_TRANSITION_PROVIDER_CONFIG="$provider" REVIEW_TRANSITION_COMMENT=/usr/bin/true \
    "$pr_green/review-transition.sh" --repo owner/repo --repo-root "$repo" \
    --pr 1 --authorization-file "$missing" --rounds 1 --interval 1)
assert_contains "$out" 'authorize-queue.sh' \
    'review-transition names the producer of its missing authorization'

finish
