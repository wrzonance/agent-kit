Read this before dispatching any implementation worker — it carries the full orchestrator/worker
split and the worker-owned publication mechanics behind the MANDATORY "Implementation-worker gate"
section `SKILL.md` states ahead of "The Loop"; Step 2 points back to that gate rather than
restating it.

## Implementation-worker gate

The PR-loop agent orchestrates — inspects state, evaluates findings, owns human-confirmation
gates — and does **not** generate a fix batch on its own model except for a qualifying bounded
inline correction. This is role separation: each worker receives fresh fenced context and
sole-writer isolation, while the root performs independent root validation before publication.
The two allowed implementation exceptions are a genuinely spawn unavailable path and a
qualifying bounded inline correction; all other CI, conflict, adversarial, CodeRabbit, Code
Quality, or approved human feedback requiring a code change dispatches one real worker as the
sole writer for that batch. Resolve `AGENT_WORKER_MODEL`, `AGENT_WORKER_MODEL_FALLBACK`, and
`AGENT_WORKER_EFFORT` for the worker model and effort from the repository declarations, not from a
model tier or the orchestrator's pricing. Resolution is harness-aware: see
[../../.shared/spawn-contract.md](../../.shared/spawn-contract.md)'s "Harness-aware pivot" for how
a declaration shaped for a different harness resolves to the running harness's native tier instead
of stopping. The Step 1b reviewer (read-only) **never** satisfies this gate.

Before dispatching any worker, read ["$agentkit/.shared/spawn-contract.md"](../../.shared/spawn-contract.md)
for the model/effort selection (Luna→Terra fallback), the exact spawn call shape and parameter
warnings, and the degraded no-spawn path — this file is dispatcher-side guidance, never pasted
into a worker prompt; read ["$agentkit/.shared/six-step-loop.md"](../../.shared/six-step-loop.md) for the
required six-step ultracode loop and its reporting format. **Paste the six-step contract
verbatim into the worker's prompt, alongside the accepted findings, worktree/branch rules, and
the Step 0a environment contract — never as a pointer** — `fork_context: false` leaves it no
other way to see them.

## Worker-owned publication

Workers commit and push their own branch: edit only the assigned worktree, run the required
focused and full verification, then finish with a completion report naming the branch, full commit
SHA, diffstat, and green verification log. Commit with `worktree-commit.sh` using explicit file
operands and the expanded contract-derived worker trailer; never stage or publish unrelated dirt.
Workers never call forge/board helpers, create PRs, launch reviews, or request escalation. The root
reviews the pushed `base...HEAD` diff independently and owns PR metadata, board moves, replies,
and the next review cycle.

## Environment-refusal fallback

A refused harness patch *tool* is not a refused *shell*: before a worker reports an environment
refusal it probes the shell with a trivial write and names what it tried, reporting the refusal
only once that probe fails too. See [../../.shared/six-step-loop.md](../../.shared/six-step-loop.md)'s
"How to write a file" for the full write-mechanism preference order (harness tool, then whole-file
shell write, then a scripted surgical edit) and the hand-authored-unified-diff prohibition —
`git apply` matches byte-exact context a model cannot reconstruct from memory. A worker that stops
mid-change leaves the tree coherent, fully applied or fully reverted, never partial.

The unstaged publication handback survives only as an environment-refusal fallback. If
`worktree-commit.sh` exits 2, nothing is committed: stop and return the scoped dirty files,
diffstat, green log, branch, and one exact ready-to-run commit invocation with the expanded trailer;
the root runs it once and then pushes. If the push was refused after the commit succeeded, the tree
is clean: report the full commit SHA and the exact ready-to-run `git push -u origin BRANCH` command;
the root runs that push once and does not retry a commit. Never use an unstaged handback for a
normal worker result.

For the normal path, the root inspects `base...HEAD` only after the worker push. After reviewing
that pushed diff, it continues the existing PR's CI, reply, review, and metadata cycle; it does
not create a DRAFT PR. Draft creation remains in parallel-issues' own root publication flow. For
stacked chains, use `chain-advance.sh` to re-read `baseRefName` and prove `base...head` before
merging a successor; stale approval residue remains a human judgment. A dirty tree not authored
by the worker is surfaced before validation and never adopted.

For a correction cycle, resume the same worker with `followup_task` when possible rather than
spawning a new one; never create concurrent writers in one PR worktree.

### Bounded inline corrections

The root may skip dispatch for an inline correction only when all four conditions hold: the diff
is purely mechanical with no new behavior, data shape, or control flow; it is at most five changed
lines; the root authored the exact diff during review; and the full declared verification is rerun.
Record the inline decision and its recorded reason, and use root harness attribution for its
commit. Anything else must resume the same worker with `collaboration.followup_task` first; a fresh
worker is only the fallback when follow-up is unavailable. A qualifying correction costs zero
dispatches, and the skip is never silent.

Every worker file operation uses an absolute path rooted in its worktree — cwd is not an ownership
boundary; a discovered write outside it is restored (`git diff --binary | git apply -R`) and
reported in the handback. Tier mapping (root/Luna/Terra) is the same as
[../../.shared/spawn-contract.md](../../.shared/spawn-contract.md)'s.

```bash
# Re-derive at the top of EVERY shell call: env does NOT persist between tool calls.
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
resolver="$agentkit/.shared/scripts/repo-config.sh"
[ -x "$resolver" ] && eval "$("$resolver" --export)"
REPO=${AGENT_REPO_SLUG:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
PR=42                                                        # replace with the PR number under review
export REPO PR
```
