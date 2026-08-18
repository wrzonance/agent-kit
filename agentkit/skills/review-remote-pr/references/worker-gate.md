Read this before dispatching any implementation worker — it carries the full orchestrator/worker
split and the worker-owned publication mechanics behind the MANDATORY "Implementation-worker gate"
section `SKILL.md` states ahead of "The Loop"; Step 2 points back to that gate rather than
restating it.

## Implementation-worker gate

The PR-loop agent orchestrates — inspects state, evaluates findings, owns human-confirmation
gates — and does **not** generate a fix batch on its own model. This is role separation: each worker receives fresh fenced context
and sole-writer isolation, while the root performs independent root validation before publication. Whenever CI, conflicts, adversarial findings, CodeRabbit, Code
Quality, or approved human feedback requires a code change, dispatch one real worker as the sole
writer for that batch. Resolve `AGENT_WORKER_MODEL`, `AGENT_WORKER_MODEL_FALLBACK`, and
`AGENT_WORKER_EFFORT` for the worker model and effort from the repository declarations, not from a
model tier or the orchestrator's pricing. The Step 1b reviewer (read-only) **never** satisfies this
gate.

Before dispatching any worker, read [../../.shared/spawn-contract.md](../../.shared/spawn-contract.md)
for the model/effort selection (Luna→Terra fallback), the exact spawn call shape and parameter
warnings, and the degraded no-spawn path — this file is dispatcher-side guidance, never pasted
into a worker prompt; read [../../.shared/six-step-loop.md](../../.shared/six-step-loop.md) for the
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

The unstaged publication handback survives only as an environment-refusal fallback. If
`worktree-commit.sh` exits 2, nothing is committed: stop and return the scoped dirty files,
diffstat, green log, branch, and one exact ready-to-run commit invocation with the expanded trailer;
the root runs it once and then pushes. If the push was refused after the commit succeeded, the tree
is clean: report the full commit SHA and the exact ready-to-run `git push -u origin BRANCH` command;
the root runs that push once and does not retry a commit. Never use an unstaged handback for a
normal worker result.

For the normal path, the root inspects `base...HEAD` only after the worker push and then opens a
DRAFT PR through the canonical composer (Why/What/Decisions/checkbox Testing/signature/separate
Closes #NNN). For stacked chains, use `chain-advance.sh` to re-read `baseRefName` and prove
`base...head` before merging a successor; stale approval residue remains a human judgment. A dirty
tree not authored by the worker is surfaced before validation and never adopted.

For a correction cycle, resume the same worker with `followup_task` when possible rather than
spawning a new one; never create concurrent writers in one PR worktree.

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
