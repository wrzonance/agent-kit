---
name: pr-to-green
description: >-
  Use when asked to take a confirmed queue of draft pull requests to green,
  accepting optional PR numbers to resume named ready pull requests and an
  optional --auto-merge flag to also perform the confirmed queue's merges.
  Triggers: /pr-to-green, /pr-to-green 42 43, /pr-to-green --auto-merge,
  "take these PRs to green", "finish the draft PR queue".
---

# PR to green

Coordinate parallel reviews and serial merges.

Paths and purposes: `"$agentkit/references.md"`. Open `"$agentkit/<path>"`; do not search.

Before recipes, read ["$agentkit/.shared/shell-portability.md"](../.shared/shell-portability.md) fully; run all `bash` fences via its `bash -c` boundary.

## Flags

| Flag | Effect |
|---|---|
| `--auto-merge` | Gated serial merges of confirmed PRs; otherwise humans merge at evidence-green. See [details](references/auto-merge.md) for consent and gates. |
| `--yolo` | Explicit intent for unattended queue authorization; never implies merges or cross-provider consent. |
| `--fast-mode` | Display a receipt and authorize the bounded queue without a question. --fast-mode requires --yolo. |
| `--auto-review` | Authorize the disclosed adversarial payload through the existing paths-coverage consent guard. |

## Environment warm-up

Preflight once before queue discovery; it writes data-only `.agent/cache/contract-session.env`, never sourced.

```bash
agentkit=''
contract_root="$(git rev-parse --show-toplevel 2>/dev/null)" || contract_root=''
contract="$contract_root/.agent/env-contract.txt"
# Match runtime harness signal priority before the skills tree is available.
contract_harness=unknown
if [[ -n ${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-} ]]; then contract_harness=claude
elif [[ -n ${CODEX_HOME:-}${CODEX_SANDBOX_NETWORK_DISABLED:-}${CODEX_PERMISSION_PROFILE:-} ]]; then contract_harness=codex
elif [[ -n ${OPENCODE:-}${OPENCODE_PID:-} ]]; then contract_harness=opencode
elif [[ -d ${CODEX_HOME:-$HOME/.codex} ]]; then contract_harness=codex
fi
keyed_contract="$contract_root/.agent/env-contract.$contract_harness.txt"
[[ ! -e $keyed_contract && ! -L $keyed_contract ]] || contract=$keyed_contract
if [[ -n $contract_root && ( -e $contract || -L $contract ) ]]; then
    [[ ! -L $contract_root/.agent && -r $contract && -f $contract && ! -L $contract && -O $contract ]] ||
        { printf 'agentkit: untrusted environment contract: %s\n' "$contract" >&2; exit 1; }
    tracked_rc=0
    git -C "$contract_root" ls-files --error-unmatch -- "$contract" > /dev/null 2>&1 || tracked_rc=$?
    [[ $tracked_rc == 1 ]] || { printf 'agentkit: cannot prove contract is untracked: %s\n' "$contract" >&2; exit 1; }
    agentkit=$(sed -n "s/^skills= path=//p" "$contract" 2>/dev/null | head -n 1)
fi
[[ -n $agentkit ]] || { printf '%s\n' 'agentkit: run onboarding first' >&2; exit 1; }
[ -d "$agentkit/.shared/scripts" ] || { printf '%s\n' 'agentkit: invalid skills path' >&2; exit 1; }
agentkit_provenance=ok; : "$agentkit_provenance"
```

#### THE CACHE REHYDRATION

Fresh standalone command blocks rehydrate the validated data record with the
trusted reader, never by sourcing it:

```bash
agentkit='STEP_0_AGENTKIT'; [[ $agentkit == /* && $agentkit != STEP_0_AGENTKIT ]] || exit 1
expected_agentkit=$agentkit; shared="$agentkit/.shared/scripts"; cache_reader="$agentkit/.shared/scripts/lib/contract-cache.sh"
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
preflight="$agentkit/.shared/scripts/agent-preflight.sh"
[[ -x $preflight ]] || exit 1
environment_contract=$("$preflight" --worktree "$repository_root") || exit 1
printf '%s\n' "$environment_contract"
[[ -x "$agentkit/.shared/scripts/contract-read.sh" ]] || exit 1
contract_path=$("$shared/contract-read.sh" --repo-root "$repository_root" --get skills.path) || exit 1
[[ $contract_path == "$agentkit" ]] || exit 1
"$shared/lib/contract-cache.sh" --read-session-context --repo-root "$repository_root" --get agentkit >/dev/null || exit 1
```

## Hard rules

- Ready-transition, provider trigger, and Phase C settlement (Steps 2–4) may
  run in parallel across independent `RUNNABLE` roots, bounded by
  `$agentkit/parallel-issues/scripts/concurrency-cap.sh`'s cap (root counted) and the API budget below —
  admission/revalidation: ["$agentkit/pr-to-green/references/auto-merge.md"](references/auto-merge.md).
  Step 5's
  merges are serial; `--auto-merge` implies strict serial merge ordering.
- Resolve provider configuration before any PR mutation. Missing or invalid
  config is effective `none`: warn and continue through CI, mandatory
  adversarial review, and human-feedback gates without a provider wait.
- Present the provider plan, verified dependency graph, and exact serial queue
  before mutation. One explicit confirmation covers remediation pushes, ready
  transitions, and trigger-capable requests for that displayed queue only.
  `--fast-mode --yolo` supplies that intent at invocation; always emit the plan receipt.
- Never merge, force-push, or clean worktrees. Never choose a history rewrite,
  unexpected diff expansion, conflict repair, or human-feedback disposition
  silently.
- **GitHub API budget.** Read `$agentkit/pr-to-green/scripts/pr-queue.sh --write-confirmed-queue`'s
  `budget:` preflight line first; `$agentkit/review-remote-pr/scripts/gh-pr-state.sh`/`pr-queue.sh` exit `3` is a rate-limit stop —
  ["$agentkit/.shared/wait-discipline.md"](../.shared/wait-discipline.md#github-api-budget--a-rate-limit-exit-is-not-a-wait-to-retry) owns the rule.

## Resident call-site map

| Boundary | Authority |
|---|---|
| Environment, isolated worktree, Phase A/C review loop, adversarial receipt, human gate | `../review-remote-pr/SKILL.md` and its lazy references |
| Provider plan before mutation | `$agentkit/.shared/scripts/review-provider-config.sh --repo-root DIR` |
| Draft discovery, explicit resumption, stack graph, stable queue | `scripts/pr-queue.sh` |
| Owner-only authorization derived from the confirmed live queue | `$agentkit/pr-to-green/scripts/authorize-queue.sh` |
| Confirmed ready transition and provider capability action, and its `--observe` landed-review check | `$agentkit/pr-to-green/scripts/review-transition.sh` |
| CI/provider/finding evidence | `../review-remote-pr/scripts/gh-pr-state.sh` |
| Canonical replies and bot-response settlement | `$agentkit/review-remote-pr/scripts/thread-action.sh` |
| Post-merge retarget proof | `$agentkit/parallel-issues/scripts/chain-advance.sh` |
| `--auto-merge` pre-merge review-completion gate | `$agentkit/pr-to-green/scripts/merge-gate.sh` |
| `--auto-merge` verified serial merge | `$agentkit/pr-to-green/scripts/merge-pr.sh` |
| Board `Done` move after a merge | `$agentkit/parallel-issues/scripts/move-github-project-item.sh` |

Read `../review-remote-pr/SKILL.md` once when entering Phase A. Read its provider
rules once only if findings exist, and reuse that content through Phase C.

## State machine

### 1. Resolve and display

Establish the environment through review-remote-pr Step 0, then run
`review-provider-config.sh` before any mutation. Retain its exact capability
records; do not infer installed bots from checks or issue prose.

Run `pr-queue.sh --write-confirmed-queue --format table` with any handed-off
schema-2 plan and each `--provider NAME:ACTION:SOURCE` (or `--no-providers`).
One derivation supplies the display and owner-only
`.agent/pr-to-green-confirmed-queue.json`; missing `providers` makes it stale.
`--dispatch-plan` and `--merge-plan` alias the same file across ready-flip;
this consumer requires schema-2. Without a plan, derive from the forge.
Automatic discovery selects drafts; an explicitly named ready PR may resume.
States are `RUNNABLE`,
`WAITING_FOR_MERGE`, `RETARGET_REQUIRED`, or `BLOCKED`; ambiguous topology fails closed.

`ISSUE` is the plan's issue number for `source=plan`. Forge rows do not derive
issues, even with valid closing references: JSON `null`, records `issue=null`,
table `-` mean unknown, never a broken link or merge blocker. Reserve numeric
`0` for proven absence (not currently derived). PR/head/base/state checks still
apply; resolve closing linkage separately for board moves.

Show the human table and the exact provider records, and for every declared
trigger-capable provider state the per-run action it will be authorized for:
`trigger` by default, or `observe`/`disabled` when the operator has instructed
no ping for that provider on this queue. State every chain base to tip, then
independent roots in queue order. When `--auto-merge` is on the invocation
line, the displayed plan must say plainly that confirmed merges are included,
naming the merge method and delete-branch setting. Without `--fast-mode --yolo`,
wait for confirmation of this exact plan. With it, emit the plan as a receipt
and pass both flags to `authorize-queue.sh`; never ask the same question again.

After confirmation, derive the owner-only authorization JSON with
`scripts/authorize-queue.sh`, passing the same repository, merge plan or PR selectors, and provider
decisions the displayed queue used; it re-reads the live queue, requires it to equal the displayed
snapshot (any drift fails closed → redisplay/reconfirm), and copies the queue fields from that live result.
Pass `--confirmed-queue-file`, `--ready-transition`, every displayed
`--provider NAME:ACTION:SOURCE` (or `--no-providers`), and `--no-auto-merge` unless
the invocation included `--auto-merge`. Merging also requires `--merge-method METHOD`
and exactly one of `--delete-branch`/`--keep-branch`. Provider sources remain
`capability-default` for default triggers and `operator-instruction` for overrides.
The head/base-pinned authorization schema and transition guards stay unchanged.

For fast mode or proof-backed fix pushes, start with `--run-id ID --write-set-file FILE`.
FILE contains the declared write set expanded to explicit relative paths, one per line.
The owner-only `.agent/pr-to-green-run-ID.json` records the predicate: repository,
original selector, providers, initial PR ceiling, merge choices, and write set.
Re-derivation permits only proven advances; repository/provider changes or added PRs
still require redisplay and new confirmation. Never invent a new run ID to retry drift.

Before the first adversarial send, disclose provider, payload and paths. With
`--auto-review`, call `$agentkit/review-remote-pr/scripts/consent-record.sh grant` with the existing worktree/run-dir,
provider and payload arguments plus `--source auto-review-flag --paths-file FILE`.
Use the authorized payload path set; uncovered paths still fail closed. Without
that flag, retain the interactive question and `--source interactive` grant.
`--yolo`, `--fast-mode`, and `--auto-merge` never imply this consent.

### 2. Normalize runnable PRs

Drive Steps 2–4 concurrently per root (never waiting/retargeting). For each,
establish/reuse its isolated worktree through review-remote-pr. Complete
Phase A against the current base: no
conflicts, declared verification passing, CI settled green, mandatory
adversarial receipt settled (including its same-harness blind fallback), and
every observed human item decided. Consolidate accepted changes into
the existing one-push fix batch. A blocked check is named evidence, never green.

A declared-verification failure whose failing paths are all provably unchanged from base and outside
this PR's diff is `baseline-red` — classified by review-remote-pr Step 2's
`$agentkit/review-remote-pr/scripts/verification-baseline.sh`, never re-derived here. It is published
evidence (`$agentkit/parallel-issues/scripts/compose-pr-body.sh --baseline-file`, every skipped check marked SKIPPED), never a passing
check: proceed through commit, push, adversarial review, and receipt — never park on it, and never reformat
unrelated paths just to force a clean run — but ready-flip and merge stay blocked as on any other red (Step 4).
Any other declared-verification failure is `change-caused-red`: fix it.

After a Phase A or C fix push, retain the run's receipt and invoke
`authorize-queue.sh --self-authored-proof PR:FILE` with the same run ID/write set.
Record only this run's successful pushes, findings and commit SHAs; the proof format
and independent checks are in ["$agentkit/pr-to-green/references/auto-merge.md"](references/auto-merge.md#self-authored-fix-advances).
Verified own fixes need no new question, even in attended runs. Missing proof or
outside changes require a fresh displayed queue and confirmation. Rewriting the
display never overrides the receipt's last authorized head. All new heads still
need fresh CI, review-completion and merge gates.

This sequence is a **critical section** (one fixed-path snapshot): only one
root inside it at a time; each re-derives its own authorization on entry.

### 3. Transition and consume provider state

Invoke `review-transition.sh` per `RUNNABLE` record; it may resume a ready PR.
Treat its provider result as follows:

- `AUTO_REVIEW`, `ALREADY_SPENT`, or `LANDED`: enter Phase C and consume
  observed findings through review-remote-pr.
- `TRIGGERED since=TIMESTAMP`: a request was just posted with no terminal
  review observed yet — poll `gh-pr-state.sh`'s `provider:` digest line, or
  `review-transition.sh --observe --pr N --since TIMESTAMP` in bounded rounds,
  until it reports a landed review (or `LANDED`); never re-run the full
  ready-transition flow to re-derive the same fact.
- `STALE_HEAD`: a terminal review targets a head the PR has since moved past
  (postdates the trigger; its own head SHA differs) — never evidence-green;
  keep polling `--observe`; never re-trigger or treat it as `LANDED`.
- `TRIGGER_MISPARSED`: CodeRabbit answered as chat, filing no review. Its
  `<!-- pr-to-green:provider-request provider=coderabbit -->` marker still
  counts the spend — never re-post by hand; stop this PR `BLOCKED` pending
  an operator-authorized retrigger.
- `OBSERVE_ONLY`: consume findings and wait for provider-owned rescans; never
  manufacture a request.
- `DISABLED`: add no provider wait or approval requirement.
- `BLOCKED`: stop this PR on the named evidence; do not advance its descendants.

Phase C uses one consolidated fix/push batch per bounded round; provider-rules.md owns settlement
(replies enter `AWAITING_BOT_RESPONSE`; refresh evidence before `thread-action.sh --settle`). Human items retain
per-item confirmation; human threads stay unresolved. Record a verified fix commit with
`$agentkit/review-remote-pr/scripts/review-ledger.sh cover`; never re-review — see
["$agentkit/pr-to-green/references/auto-merge.md"](references/auto-merge.md).

### 4. Prove evidence-green

Refresh `gh-pr-state.sh --digest` before reporting; cite head/read for CI.
After the last thread action, run `review-transition.sh --observe --repo OWNER/REPO
--pr N --since TRIGGER_TIMESTAMP --settle-after ACTION_TIMESTAMP --rounds 4 --interval 1`.
Report its source/head/read/action/elapsed fields. For Code Quality use
`$agentkit/review-remote-pr/scripts/code-quality-state.sh --repo OWNER/REPO --pr N --head SHA40 --claim`.
Require fresh current-head evidence; pending/unavailable never means complete.
Disabled providers add no gate.

A PR is evidence-green only when all of these are current for its head and base:

- CI and every declared repository check pass with no stale-base residue — a
  `baseline-red` declared-verification outcome (Step 2) is published evidence,
  not a passing check, and never satisfies this bullet;
- mandatory adversarial review is satisfied;
- declared or observed automated findings are fixed, reasoned-dismissed,
  deferred by an explicit decision, or settled after provider response;
- Code Quality findings are auto-cleared or dismissed through its supported
  workflow;
- every human item has an explicit per-item decision; and
- no reply is awaiting an unread provider response.

The merge gate classifies scans as bounded `SETTLING`, named `scan-failed` or
`scan-missing` (with human action), and `not-applicable (path-filtered)` for
all-skipped checks; the last still requires readable zero-alert evidence.

Report provider approval separately; effective `none` and stale approval do not
block evidence-green.

### 5. Advance stacks, merging only under `--auto-merge`

After a predecessor becomes evidence-green, mark its open descendants
`WAITING_FOR_MERGE`. Without `--auto-merge`, never merge it — continue other
independent roots while the chain waits, and report the exact human merge
dependency.

With `--auto-merge`, an evidence-green item merges only after
`scripts/merge-gate.sh` reports `gate=PASS` for its exact confirmed head
(["$agentkit/pr-to-green/references/auto-merge.md"](references/auto-merge.md) has the recipe —
a formal provider approval requirement stays repository policy).
For an explicitly attested absence of human reviewers with the review provider disabled,
pass `--review-capability-file FILE` to queue discovery and the merge gate. Dispatch names
the operator dependency. `ADMIN_ELIGIBLE` is not `PASS`: only the separately authorized,
exact-merge admin procedure in `references/auto-merge.md` may consume it. Never infer
admin consent from `--auto-merge`, queue confirmation, or workflow authorization.
A branch-protection refusal is a named stop; never retry via another merge path. On `gate=PASS`,
invoke `scripts/merge-pr.sh` with the Step 1 authorization file and the saved
`gate=PASS` output — it refuses unless both bind to this exact repository/
PR/head/base/method/delete-branch as a confirmed `RUNNABLE` queue member; the
guard lives at that point of mutation, not just in the calling order. On its
success, move that issue's board item to `Done`. No merge starts while a
predecessor's post-merge revalidation is outstanding.

After predecessor merge, make the direct successor `RETARGET_REQUIRED`; run
`chain-advance.sh` against the default branch and refresh its diff, ancestry,
conflicts, checks, head/base evidence, and closing linkage. Approval remains
residue (`current:post-retarget|residue:stale|none|unknown`) until transition;
disabled providers never produce one. Unexpected expansion, stale proof,
failed retarget, or required rewrite blocks the successor for human or
automated merges.

After retarget, `chain-advance.sh` reruns a head scan or requests
`workflow_dispatch`; otherwise it reports `cannot-trigger: <workflow> has no
dispatch`. Agents never close/reopen PRs to synthesize events; that requires
an operator instruction naming the PR/action.

Regenerate the queue before the successor becomes `RUNNABLE` or spends provider
authority. A merge-down/retarget is deterministic maintenance under Step 1;
refresh it through `authorize-queue.sh --allow-mechanical-advance` (see
["$agentkit/pr-to-green/references/auto-merge.md"](references/auto-merge.md))
instead of redisplaying, unless it names a material judgment. Its proof is
persisted under Git metadata and found by `authorize-queue.sh
--allow-mechanical-advance`; pass `--retarget-proof PR:FILE` only when that
persistence was reported as failed. Prefer that newly unblocked successor,
then continue serially.

## Exit

Continue until each item is evidence-green (merged under `--auto-merge`) or has a
named human/dependency blocker. Report per PR: head/base, CI, adversarial receipt,
provider result, findings, human decisions, stack state, formal approval separately,
and auto-merge gate/outcome. Preserve worktrees and authorization/evidence for resumption.
