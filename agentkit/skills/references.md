# Reference manifest

Every companion reference this plugin ships, with the path to open it and what
it is for. Read this file instead of searching the tree.

It sits here — directly under the skills tree, undotted — on purpose. The
references themselves live in `.shared/` and `<skill>/references/`, and a
dotted directory is invisible to `rg --files` without `--hidden`, to shell
globs without `dotglob`, and to naive `find`-based discovery. The one directory
an agent most needs to enumerate is the one enumeration hides, so the index of
it must not be hidden too.

`$agentkit` is the resolved skills tree from the session contract's
`skills= path=` line (`contract-read.sh --get skills.path` if you need it
again). Every entry below is therefore already an openable path — never
reconstruct the prefix by hand, and never fall back to a filesystem search: a
path here that does not resolve is a manifest mismatch, a clean and nameable
condition, and `tests/lint-reference-manifest.sh` is the gate that says so.

The manifest is an index, not an instruction to preload every file. Read an
entry only when its `Read when:` condition matches the path the run has reached;
when uncertain whether a condition matches, read the reference. Entry grammar,
one per line, checked by that gate:

```
- `$agentkit/<path relative to the skills tree>` -- <one-line purpose> | Read when: <condition>
```

## Shared policy (`.shared/`) — pasted verbatim into worker prompts

- `$agentkit/.shared/github-body-policy.md` -- how every `gh` body must reach the forge: through a file, never an inline string, with body bytes kept literal | Read when: immediately before the run's first GitHub body mutation
- `$agentkit/.shared/shell-portability.md` -- the explicit Bash boundary for agent-composed recipes and the zsh, nested-quoting, and stdin hazards it prevents | Read when: before running the first multi-line shell recipe in a skill or companion reference
- `$agentkit/.shared/six-step-loop.md` -- the six-step ultracode loop every code-bearing change follows, its reporting format, and the Review/Finish gates after it | Read when: before composing or validating an implementation-worker dispatch
- `$agentkit/.shared/spawn-contract.md` -- the implementation-worker spawn contract: model/effort selection, the exact spawn call shape, and the degraded no-spawn path | Read when: before the first implementation-worker dispatch or degraded self-implementation
- `$agentkit/.shared/wait-discipline.md` -- the wait/polling contract: no model turn spent waiting, named bounds, and the durable state to inspect after a completion | Read when: immediately before the first bounded wait or poll

## parallel-issues (`parallel-issues/references/`)

- `$agentkit/parallel-issues/references/chains.md` -- building the chain graph, publishing a locally-built chain base, deferred dispatch, and merge-down after a predecessor advances | Read when: the selected set contains a chain or a late overlap requires chain conversion or merge-down
- `$agentkit/parallel-issues/references/triage-and-selection.md` -- triage adjudication, bulk-mutation ledger discipline, prior-art rules, conflict analysis and dispatch-plan write sets, board adjudication | Read when: Phase 1 reaches triage, selection, board adjudication, or conflict analysis
- `$agentkit/parallel-issues/references/trust-and-fencing.md` -- the verification cache and suite cadence behind `agent-run.sh`'s cached green results | Read when: a verification result, cache decision, or issue-body trust boundary must be interpreted
- `$agentkit/parallel-issues/references/verification-isolation.md` -- Compose project isolation and how to read an `agent-run.sh` failure, including the environment-retry-eligible finding | Read when: the repository declares a Compose-driven command or any `agent-run.sh` result must be interpreted
- `$agentkit/parallel-issues/references/worker-prompts.md` -- the worker prompt templates: issue lead, fix batch, draft PR body, and the diff-size disclosure recipe | Read when: composing an issue-lead or fix-batch prompt, or composing a draft PR body

## pr-to-green (`pr-to-green/references/`)

- `$agentkit/pr-to-green/references/auto-merge.md` -- the `--auto-merge` contract: consent recording, the pre-merge review-completion gate, serialization, and method semantics | Read when: `pr-to-green` is invoked with `--auto-merge`

## review-remote-pr (`review-remote-pr/references/`)

- `$agentkit/review-remote-pr/references/adversarial-review.md` -- the Step 1b adversarial-review contract: materiality, attribution, external-service authorization, cross-provider consent, and the exit-code table | Read when: review Phase A reaches Step 1b or any skill runs an adversarial cross-review
- `$agentkit/review-remote-pr/references/environment-contract.md` -- the runtime-neutrality contract and the Step 0a environment-contract mechanics behind it | Read when: starting `review-remote-pr` Step 0a
- `$agentkit/review-remote-pr/references/grooming.md` -- the post-loop Backlog grooming pass that proposes Ready candidates and never auto-promotes | Read when: the post-loop Backlog grooming pass is requested
- `$agentkit/review-remote-pr/references/provider-rules.md` -- the automated-review provider table, author classification, reply-body integrity gate, and the human-confirmation gate | Read when: review reaches provider-state triage, feedback handling, replies, or thread actions
- `$agentkit/review-remote-pr/references/worker-gate.md` -- the orchestrator/worker split and the worker-owned publication mechanics behind the implementation-worker gate | Read when: a review finding requires an implementation worker or bounded inline-correction decision
