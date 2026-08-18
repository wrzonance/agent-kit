---
name: pr-to-green
description: >-
  Use when asked to take a confirmed queue of draft pull requests to green,
  accepting optional PR numbers to resume named ready pull requests.
  Triggers: /pr-to-green, /pr-to-green 42 43, "take these PRs to green",
  "finish the draft PR queue".
---

# PR to green

Coordinate existing Agent Kit review machinery in a strict serial queue. This
skill owns queue authorization and the ready/provider transition boundary; it
is not another review engine.

## Environment warm-up

Run the repository preflight once before queue discovery. The warm-up writes
data-only `.agent/cache/contract-session.env`; it is never sourced.

```bash
agentkit=''
contract_root="$(git rev-parse --show-toplevel 2>/dev/null)" || contract_root=''
contract="$contract_root/.agent/env-contract.txt"
if [[ -n $contract_root && -r $contract && -f $contract && ! -L $contract && -O $contract ]] &&
    ! git -C "$contract_root" ls-files --error-unmatch -- .agent/env-contract.txt > /dev/null 2>&1; then
    agentkit=$(sed -n "s/^skills= path=//p" "$contract" 2>/dev/null | head -n 1)
fi
[[ -n $agentkit ]] || { printf '%s\n' 'agentkit: run agent-preflight.sh first' >&2; exit 1; }
[ -d "$agentkit/.shared/scripts" ] || { printf '%s\n' 'agentkit: invalid skills path' >&2; exit 1; }
agentkit_provenance=ok; : "$agentkit_provenance"
```

#### THE CACHE REHYDRATION

Fresh standalone command blocks rehydrate the validated data record with the
trusted reader, never by sourcing it:

```bash
agentkit='STEP_0_AGENTKIT'; [[ $agentkit == /* && $agentkit != STEP_0_AGENTKIT ]] || exit 1
expected_agentkit=$agentkit; shared="$agentkit/.shared/scripts"; cache_reader="$shared/lib/contract-cache.sh"
[[ -d $shared && ! -L $shared && -O $shared && -f $cache_reader && ! -L $cache_reader && -O $cache_reader && -x $cache_reader ]] || exit 1
contract_root=$(git rev-parse --show-toplevel) && contract_root=$(cd -P -- "$contract_root" && pwd -P) || exit 1
IFS=$'\t' read -r agentkit shared agentkit_provenance loaded_root _ < <("$cache_reader" --read-session-context --repo-root "$contract_root")
[[ $agentkit == "$expected_agentkit" && $shared == "$expected_agentkit/.shared/scripts" && $agentkit_provenance == ok && $loaded_root == "$contract_root" ]] || exit 1
```

Perform the sole refresh and contract-read warm-up here:

```bash
set -euo pipefail
# >>> prepend THE RESOLVER (initial warm-up only) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend the Step 0 resolver block" >&2; exit 1; }
repository_root=$(git rev-parse --show-toplevel) || exit 1
shared="$agentkit/.shared/scripts"
preflight="$shared/agent-preflight.sh"
[[ -x $preflight ]] || exit 1
environment_contract=$("$preflight" --worktree "$repository_root") || exit 1
printf '%s\n' "$environment_contract"
[[ -x "$shared/contract-read.sh" ]] || exit 1
contract_path=$("$shared/contract-read.sh" --repo-root "$repository_root" --get skills.path) || exit 1
[[ $contract_path == "$agentkit" ]] || exit 1
"$shared/lib/contract-cache.sh" --read-session-context --repo-root "$repository_root" --get agentkit >/dev/null || exit 1
```

## Hard rules

- Process strictly one PR at a time. Never run two remediation or transition
  loops concurrently.
- Resolve provider configuration before any PR mutation. Missing or invalid
  configuration is effective `none`: warn and continue through CI, mandatory
  adversarial review, and human-feedback gates without a provider wait.
- Present the provider plan, verified dependency graph, and exact serial queue
  before mutation. One explicit confirmation covers remediation pushes, ready
  transitions, and trigger-capable requests for that displayed queue only.
- Never merge, force-push, or clean worktrees. Never choose a history rewrite,
  unexpected diff expansion, conflict repair, or human-feedback disposition
  silently.
- Provider rules, author classification, fix batches, reply settlement,
  bounded waits, exact readback, worktree mechanics, and the six-step worker
  gate remain in their existing authoritative files.

## Resident call-site map

| Boundary | Authority |
|---|---|
| Environment, isolated worktree, Phase A/C review loop, adversarial receipt, human gate | `../review-remote-pr/SKILL.md` and its lazy references |
| Provider plan before mutation | `../.shared/scripts/review-provider-config.sh` |
| Draft discovery, explicit resumption, stack graph, stable queue | `scripts/pr-queue.sh` |
| Confirmed ready transition and provider capability action | `scripts/review-transition.sh` |
| CI/provider/finding evidence | `../review-remote-pr/scripts/gh-pr-state.sh` |
| Canonical replies and bot-response settlement | `../review-remote-pr/scripts/thread-action.sh` |
| Post-merge retarget proof | `../parallel-issues/scripts/chain-advance.sh` |

Read `../review-remote-pr/SKILL.md` once when entering Phase A. Read its provider
rules once only if findings exist, and reuse that content through Phase C.

## Serial state machine

### 1. Resolve and display

Establish the environment through review-remote-pr Step 0, then run
`review-provider-config.sh` before any mutation. Retain its exact capability
records; do not infer installed bots from checks or issue prose.

Run `pr-queue.sh` with the persisted schema-v2 dispatch/merge plan when one was
handed off by `parallel-issues`. Without one, use forge derivation. Automatic
discovery selects drafts. An explicitly named ready PR may resume an interrupted
run. The queue helper reports `RUNNABLE`, `WAITING_FOR_MERGE`,
`RETARGET_REQUIRED`, or `BLOCKED` and fails closed on ambiguous topology.

Show the human table and the exact provider records. State every chain base to
tip, then independent roots in queue order. Do not mutate until the user confirms
the displayed provider plan, verified dependency graph, and exact serial queue.

After confirmation, write an owner-only authorization JSON file containing:

- `repository` and `readyTransition: true`;
- `providers`, containing exactly the displayed triggerable providers;
- `queue`, with each confirmed PR's number, current state, and full head SHA.

That file is narrow evidence for `review-transition.sh`, not reusable consent
after a head, provider plan, or queue change. Re-display and reconfirm changed
inputs.

### 2. Normalize one runnable PR

Take the first `RUNNABLE` record only. Establish or reuse its isolated worktree
through review-remote-pr. Complete Phase A against the current base: no
conflicts, declared verification passing, CI settled green, mandatory
adversarial receipt settled (including its same-harness blind fallback), and
every observed human item explicitly decided. Consolidate accepted changes into
the existing one-push fix batch. A blocked check is named evidence, never green.

If Phase A changes the head, regenerate the queue and authorization evidence.
Do not let earlier confirmation authorize a new SHA.

### 3. Transition and consume provider state

Invoke `review-transition.sh` only for the current confirmed `RUNNABLE` record.
It may safely resume an already-ready PR. Treat its provider result as follows:

- `AUTO_REVIEW`, `TRIGGERED`, or `ALREADY_SPENT`: enter Phase C and consume
  observed findings through review-remote-pr.
- `OBSERVE_ONLY`: consume findings and wait for provider-owned rescans; never
  manufacture a request.
- `DISABLED`: add no provider wait or approval requirement.
- `BLOCKED`: stop this PR on the named evidence; do not advance its descendants.

Phase C uses one consolidated fix/push batch per bounded round. Canonical replies
enter `AWAITING_BOT_RESPONSE`; refresh evidence before calling
`thread-action.sh --settle`. Acknowledgement settles, pushback joins the next
bounded fix round, and unanswered replies remain awaiting. Code Quality keeps
its auto-clear/reasoned-dismiss lifecycle. Unexpected authoritative bots use
the generic automated lane and are never triggered. Human items retain
per-item confirmation and human threads remain unresolved.

### 4. Prove evidence-green

A PR is evidence-green only when all of these are current for its head and base:

- CI and every declared repository check pass with no stale-base residue;
- mandatory adversarial review is satisfied;
- declared or observed automated findings are fixed, reasoned-dismissed,
  deferred by an explicit decision, or settled after provider response;
- Code Quality findings are auto-cleared or dismissed through its supported
  workflow;
- every human item has an explicit per-item decision; and
- no reply is awaiting an unread provider response.

Report formal provider approval separately. It is not required for effective
`none`, and a stale approval after retarget is not evidence-green.

### 5. Advance stacks without merging

After a predecessor becomes evidence-green, mark its open descendants
`WAITING_FOR_MERGE`. Never merge it. Continue the oldest independent runnable
root while the chain waits; otherwise report the exact human merge dependency.

Only after the forge confirms the human merged the predecessor may the direct
successor become `RETARGET_REQUIRED`. Invoke `chain-advance.sh` to retarget it to
the default branch and verify the live base. Refresh its diff, ancestry,
conflicts, checks, head/base evidence, provider state, and closing linkage.
Unexpected expansion, conflict, stale evidence, failed retarget, or required
history rewrite blocks that successor instead of selecting a repair.

Regenerate and re-confirm the queue before the successor becomes `RUNNABLE` or
spends any provider authority. Prefer that newly unblocked successor, then
continue serially.

## Exit

Continue until every queue item is evidence-green or blocked on a named
human/dependency decision. Report per PR: head/base, CI, adversarial receipt,
provider result, finding settlement, human decisions, stack state, and formal
provider approval separately. Preserve all worktrees and authorization/evidence
artifacts for resumption.
