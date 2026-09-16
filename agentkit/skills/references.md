# Reference manifest

Reference paths and purposes. Use this index: plain globs and default `rg --files` miss `.shared/`.

`$agentkit` is the contract's resolved `skills= path=` tree
(`$agentkit/.shared/scripts/contract-read.sh --repo-root DIR --get skills.path` retrieves it).
Open these paths directly; do not reconstruct prefixes or search. An unresolved path is a manifest
mismatch, enforced by `tests/lint-reference-manifest.sh`.

Shared executable helpers live in `$agentkit/.shared/scripts/`; skill-specific helpers in
`$agentkit/<skill>/scripts/`; name each helper by its complete `$agentkit`-relative path at first mention
in a SKILL.md. `$agentkit/.shared/scripts/lib/` holds sourced libraries, not helpers — except that
`$agentkit/.shared/scripts/lib/contract-cache.sh` has an explicit CLI:
`--read-session-context --repo-root DIR [--get KEY]`; there is no sibling with that basename under `.shared/scripts/`.

The manifest is an index, not an instruction to preload every file: read an entry only when its
`Read when:` condition matches the path the run has reached (when uncertain, read it). Entry grammar, one
per line, checked by that gate:

```text
- `$agentkit/<path relative to the skills tree>` -- <one-line purpose> | Read when: <condition>
```

## Shared policy (`.shared/`) — pasted verbatim into worker prompts

- `$agentkit/.shared/reading-discipline.md` -- read references once without preliminary size probes | Read when: starting any workflow, before its first reference read
- `$agentkit/.shared/github-body-policy.md` -- how every `gh` body must reach the forge: through a file, never an inline string, with body bytes kept literal | Read when: immediately before the run's first GitHub body mutation
- `$agentkit/.shared/shell-portability.md` -- Bash recipes: zsh, quoting, stdin hazards | Read when: before the first multi-line skill/reference recipe
- `$agentkit/.shared/six-step-loop.md` -- the six-step ultracode loop every code-bearing change follows, its reporting format, and the Review/Finish gates after it | Read when: validating a worker's six-step report or composing a prompt by hand (the issue-lead template already carries the loop; not a root pre-read)
- `$agentkit/.shared/spawn-contract.md` -- the implementation-worker spawn contract: model/effort selection, the exact spawn call shape, and the degraded no-spawn path | Read when: before the first implementation-worker dispatch or degraded self-implementation
- `$agentkit/.shared/wait-discipline.md` -- the wait/polling contract: no model turn spent waiting, named bounds, and the durable state to inspect after a completion | Read when: immediately before the first bounded wait or poll

## parallel-issues (`parallel-issues/references/`)

- `$agentkit/parallel-issues/references/implementation-worker.md` -- leaf contract | Read when: consumed automatically by `compose-worker-prompt.sh`
- `$agentkit/parallel-issues/references/chains.md` -- building the chain graph, publishing a locally-built chain base, deferred dispatch, and merge-down after a predecessor advances | Read when: the selected set contains a chain or a late overlap requires chain conversion or merge-down
- `$agentkit/parallel-issues/references/triage-and-selection.md` -- triage adjudication, bulk-mutation ledger discipline, prior-art rules, conflict analysis and dispatch-plan write sets, board adjudication | Read when: Step 2's digest flags prior-art, conflicts, or bulk mutations — read only the flagged section
- `$agentkit/parallel-issues/references/trust-and-fencing.md` -- the verification cache and suite cadence behind `agent-run.sh`'s cached green results | Read when: a verification result, cache decision, or issue-body trust boundary must be interpreted
- `$agentkit/parallel-issues/references/verification-isolation.md` -- Compose project isolation and how to read an `agent-run.sh` failure, including the environment-retry-eligible finding | Read when: the repository declares a Compose-driven command or any `agent-run.sh` result must be interpreted
- `$agentkit/parallel-issues/references/worker-prompts.md` -- setup, fix-batch and publication templates | Read when: composing that prompt or draft PR — read only that section

## pr-to-green (`pr-to-green/references/`)

- `$agentkit/pr-to-green/references/auto-merge.md` -- the `--auto-merge` contract: consent recording, the pre-merge review-completion gate, serialization, and method semantics | Read when: `pr-to-green` is invoked with `--auto-merge`

## review-remote-pr (`review-remote-pr/references/`)

- `$agentkit/review-remote-pr/scripts/ci-artifacts.sh` -- REST artifact and failed-job log collection into the assigned worktree's .agent cache | Read when: an assigned CI failure does not reproduce locally, before a zero-change hand-back
- `$agentkit/review-remote-pr/references/adversarial-review.md` -- the Step 1b adversarial-review contract: materiality, attribution, external-service authorization, cross-provider consent, and the exit-code table | Read when: review Phase A reaches Step 1b or any skill runs an adversarial cross-review
- `$agentkit/review-remote-pr/references/environment-contract.md` -- the runtime-neutrality contract and the Step 0a environment-contract mechanics behind it | Read when: starting `review-remote-pr` Step 0a
- `$agentkit/review-remote-pr/references/grooming.md` -- the post-loop Backlog grooming pass that proposes Ready candidates and never auto-promotes | Read when: the post-loop Backlog grooming pass is requested
- `$agentkit/review-remote-pr/references/provider-rules.md` -- the automated-review provider table, author classification, reply-body integrity gate, and the human-confirmation gate | Read when: review reaches provider-state triage, feedback handling, replies, or thread actions
- `$agentkit/review-remote-pr/references/worker-gate.md` -- the orchestrator/worker split and the worker-owned publication mechanics behind the implementation-worker gate | Read when: a review finding requires an implementation worker or bounded inline-correction decision
