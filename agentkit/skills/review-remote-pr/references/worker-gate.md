Read this before dispatching any implementation worker — it carries the full orchestrator/worker
split and the root-owned publication mechanics behind the MANDATORY "Implementation-worker gate"
section `SKILL.md` states ahead of "The Loop"; Step 2 points back to that gate rather than
restating it.

## Implementation-worker gate

The PR-loop agent orchestrates — inspects state, evaluates findings, owns human-confirmation
gates — and does **not** generate a fix batch on its own model. Whenever CI, conflicts,
adversarial findings, CodeRabbit, Code Quality, or approved human feedback requires a code change,
dispatch one real worker as the sole writer for that batch. The Step 1b reviewer (read-only)
**never** satisfies this gate.

Before dispatching any worker, read [../../.shared/spawn-contract.md](../../.shared/spawn-contract.md)
for the model/effort selection (Luna→Terra fallback), the exact spawn call shape and parameter
warnings, and the degraded no-spawn path — this file is dispatcher-side guidance, never pasted
into a worker prompt; read [../../.shared/six-step-loop.md](../../.shared/six-step-loop.md) for the
required six-step ultracode loop and its reporting format. **Paste the six-step contract
verbatim into the worker's prompt, alongside the accepted findings, worktree/branch rules, and
the Step 0a environment contract — never as a pointer** — `fork_context: false` leaves it no
other way to see them.

## Root-owned publication handback

Workers are turn-and-burn: edit only the assigned worktree, leave progress unstaged, and finish
with a handback naming the dirty files, the green log, and one exact `worktree-commit.sh`
invocation with the worker trailer and explicit files. Workers never invoke that helper, stage,
commit, stash, push, call forge/board helpers, create PRs, launch reviews, or request escalation.
Before execution, the root preserves the raw handback command text for audit, then parses it into
validated argv without `eval`, verifies the expected helper/trailer/paths, and inspects
`git status --short` + `git diff -- <paths>` (incl. unstaged) before publication. It invokes the
command as argv exactly once, and only afterward inspects `base...HEAD`; it then republishes the
handback command verbatim once before the single cycle push and any forge replies. It then pushes
and opens a DRAFT PR (Why/What/Design decisions/tickable Testing/agent credit/Closes #NNN). For
stacked chains, use `chain-advance.sh` to re-read `baseRefName` and prove `base...head` before
merging a successor; stale approval residue remains a human judgment. A dirty
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
