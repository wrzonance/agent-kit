#!/usr/bin/env bash
# Suite: helper-invocation and single-source-resolver conventions.
# shellcheck disable=SC2016  # fixtures intentionally contain literal shell syntax
set -uo pipefail

TEST_NAME='skill invocations'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

lint="$here/lint-skill-invocations.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

LINT_RC=0
LINT_OUT=''

# The lint asserts tree-wide that exactly one contract-absent `find` fallback
# exists and that it lives in onboard-repo, so every fixture tree needs that
# one skill present or the assertion under test is masked by an unrelated
# failure.
new_tree() {
    local root=$1
    mkdir -p "$root/onboard-repo"
    cat > "$root/onboard-repo/SKILL.md" <<'EOF'
---
name: onboard-repo
description: Use when bootstrapping a repository that has no contract yet.
---

```bash
agentkit=$(find "$HOME" -maxdepth 4 -type d -name '.shared' 2>/dev/null | head -n 1)
```
EOF
}

# make_skill ROOT NAME -- SKILL.md body on stdin
make_skill() {
    local root=$1 name=$2
    mkdir -p "$root/$name"
    cat > "$root/$name/SKILL.md"
}

run_lint() {
    LINT_RC=0
    LINT_OUT=$("$lint" "$1" 2>&1) || LINT_RC=$?
}

RESOLVER_FENCE='```bash
agentkit=""
contract_root="$(git rev-parse --show-toplevel 2>/dev/null)" || contract_root=""
contract="$contract_root/.agent/env-contract.txt"
if [[ -n $contract_root && -r $contract && -f $contract && ! -L $contract && -O $contract ]] &&
    ! git -C "$contract_root" ls-files --error-unmatch -- .agent/env-contract.txt > /dev/null 2>&1; then
    agentkit=$(sed -n "s/^skills= path=//p" "$contract" 2>/dev/null | head -n 1)
fi
[ -d "$agentkit/.shared/scripts" ] || { printf "%s\n" "agentkit: invalid skills path" >&2; exit 1; }
agentkit_provenance=ok
```'

# The guard is two conditions, not one: the directory check proves some tree is
# there, the sentinel proves THIS resolver put it there.
GUARDED_FENCE='```bash
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend the Step 0 resolver block" >&2; exit 1; }
"$agentkit/.shared/scripts/agent-run.sh" --help
```'

# --- the convention, satisfied ------------------------------------------
root=$tmp/compliant
new_tree "$root"
make_skill "$root" parallel-issues <<EOF
---
name: parallel-issues
description: Use when the conventions are satisfied.
---

## The resolver (prepend to EVERY shell call)

$RESOLVER_FENCE

## Later step

$GUARDED_FENCE
EOF
run_lint "$root"
assert_eq '0' "$LINT_RC" 'one resolver definition plus guarded helper fences passes'

# --- a helper reached without a resolved path ---------------------------
root=$tmp/bare
new_tree "$root"
make_skill "$root" parallel-issues <<EOF
---
name: parallel-issues
description: Use when a helper is invoked bare.
---

## The resolver (prepend to EVERY shell call)

$RESOLVER_FENCE

## Later step

\`\`\`bash
[ -d "\${agentkit:-}/.shared/scripts" ] || { printf "%s\n" "agentkit unresolved" >&2; exit 1; }
agent-run.sh --help
\`\`\`
EOF
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a bare helper invocation fails'
assert_contains "$LINT_OUT" 'BARE INVOCATION' 'the bare invocation is named'

# --- a helper fence with neither the resolver nor the guard -------------
root=$tmp/guardless
new_tree "$root"
make_skill "$root" parallel-issues <<EOF
---
name: parallel-issues
description: Use when a helper fence carries no guard.
---

## The resolver (prepend to EVERY shell call)

$RESOLVER_FENCE

## Later step

\`\`\`bash
"\$agentkit/.shared/scripts/agent-run.sh" --help
\`\`\`
EOF
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a helper fence with no guard fails'
assert_contains "$LINT_OUT" 'MISSING RESOLVER' 'the unguarded fence is named'

# --- a directory-only guard is not a guard ------------------------------
# `[ -d "${agentkit:-}/.shared/scripts" ]` alone is satisfied by any stale or
# profile-inherited value that happens to point at a real tree -- precisely the
# case the sentinel was added to reject. Without this rule the sentinel is
# decorative: the skills carry it, but nothing keeps them carrying it.
root=$tmp/sentinel-less
new_tree "$root"
make_skill "$root" parallel-issues <<EOF
---
name: parallel-issues
description: Use when the guard omits the provenance sentinel.
---

## The resolver (prepend to EVERY shell call)

$RESOLVER_FENCE

## Later step

\`\`\`bash
[ -d "\${agentkit:-}/.shared/scripts" ] || { printf "%s\n" "agentkit unresolved: prepend the Step 0 resolver block" >&2; exit 1; }
"\$agentkit/.shared/scripts/agent-run.sh" --help
\`\`\`
EOF
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a guard that omits the provenance sentinel fails'
assert_contains "$LINT_OUT" 'GUARD WITHOUT SENTINEL' 'the sentinel-less guard is named'

# --- the resolver must be defined exactly once --------------------------
root=$tmp/duplicate
new_tree "$root"
make_skill "$root" parallel-issues <<EOF
---
name: parallel-issues
description: Use when the resolver is copied a second time.
---

## The resolver (prepend to EVERY shell call)

$RESOLVER_FENCE

## Later step

$RESOLVER_FENCE
EOF
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a second resolver copy fails'
assert_contains "$LINT_OUT" 'EXPECTED exactly one full resolver definition' 'the duplicate definition is named'

root=$tmp/absent
new_tree "$root"
make_skill "$root" parallel-issues <<EOF
---
name: parallel-issues
description: Use when the resolver definition is missing entirely.
---

## Later step

$GUARDED_FENCE
EOF
run_lint "$root"
assert_eq '1' "$LINT_RC" 'no resolver definition at all fails'
assert_contains "$LINT_OUT" 'found 0' 'the missing definition is named'

# --- run-once work must not live inside the per-call resolver -----------
# The resolver is prepended to EVERY later shell call, so agent-preflight.sh
# left inside it re-probes the environment once per command: a transient
# gh/network failure then overwrites a good contract, and every command's
# stdout carries the contract block.
root=$tmp/preflight-in-resolver
new_tree "$root"
make_skill "$root" parallel-issues <<EOF
---
name: parallel-issues
description: Use when the preflight is folded back into the resolver.
---

## The resolver (prepend to EVERY shell call)

\`\`\`bash
agentkit=""
contract_root="\$(git rev-parse --show-toplevel 2>/dev/null)" || contract_root=""
contract="\$contract_root/.agent/env-contract.txt"
if [[ -n \$contract_root && -r \$contract && -f \$contract && ! -L \$contract && -O \$contract ]] &&
    ! git -C "\$contract_root" ls-files --error-unmatch -- .agent/env-contract.txt > /dev/null 2>&1; then
    agentkit=\$(sed -n "s/^skills= path=//p" "\$contract" 2>/dev/null | head -n 1)
fi
[ -d "\$agentkit/.shared/scripts" ] || { printf "%s\n" "agentkit: invalid skills path" >&2; exit 1; }
agentkit_provenance=ok
preflight="\$agentkit/.shared/scripts/agent-preflight.sh"
environment_contract="\$("\$preflight" --worktree "\$PWD" 2>/dev/null)"
\`\`\`
EOF
run_lint "$root"
assert_eq '1' "$LINT_RC" 'run-once preflight inside the per-call resolver fails'
assert_contains "$LINT_OUT" 'RUN-ONCE WORK IN RESOLVER' 'the run-once work in the resolver is named'

# The resolver legitimately *names* the helper in its failure message; that
# must not be mistaken for running it, or the rule above would forbid the
# message that tells the agent what to do next.
assert_contains "$(cat "$tmp/compliant/parallel-issues/SKILL.md")" 'agentkit: invalid skills path' \
    'the compliant fixture keeps a printf failure message in the resolver'

finish
