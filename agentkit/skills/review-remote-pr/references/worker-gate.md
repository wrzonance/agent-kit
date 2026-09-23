Read this before dispatching any implementation worker — it carries the full orchestrator/worker
split and the worker-owned publication mechanics behind the MANDATORY "Implementation-worker gate"
section `SKILL.md` states ahead of "The Loop"; Step 2 points back to that gate rather than
restating it.

## Implementation-worker gate

The PR-loop agent orchestrates — inspects state, evaluates findings, owns human-confirmation
gates — and never generates a fix batch on its own model; the two allowed implementation exceptions are a genuinely
spawn-unavailable path and a qualifying bounded inline correction. Every other code change dispatches one
real worker as the sole writer for that batch, with model/effort resolved from `AGENT_WORKER_MODEL`,
`AGENT_WORKER_MODEL_FALLBACK`, and `AGENT_WORKER_EFFORT` (harness-aware: see
[../../.shared/spawn-contract.md](../../.shared/spawn-contract.md)'s "Harness-aware pivot"). The Step 1b
reviewer (read-only) **never** satisfies this gate. Read ["$agentkit/.shared/spawn-contract.md"](../../.shared/spawn-contract.md)
for the spawn call shape and the degraded no-spawn path, and ["$agentkit/.shared/six-step-loop.md"](../../.shared/six-step-loop.md)
for the loop — **paste the six-step contract verbatim into the worker's prompt, never as a pointer** (`fork_context: false`).

### Compose review repairs

Root creates the immutable snapshot, records the interval, and alone Collects; leaves never make a
baseline or discover `cross-write-check.sh`. Initial dispatches, follow-ups, and resumes use
`pr-fix-batch` with accepted findings, worktree, branch, scope, and `test` verification.

```bash
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
: "${repair_worktree:?set repair worktree}" "${repair_branch:?set repair branch}"
: "${repair_scope:?set accepted findings scoped write set}" "${accepted_findings:?set findings ledger}"
: "${repair_prompt:?set root-owned prompt output path}"
: "${RUN_DIR:?}" "${PR:?}" "${REPO_ROOT:?}" "${worker_model:?}" "${worker_effort:?}"
[[ $RUN_DIR == /* && -d $RUN_DIR ]] || exit 1
repair_snapshot="$RUN_DIR/repair-$PR-pre-dispatch.snapshot"
repair_start="$RUN_DIR/repair-$PR-started-at"
if [[ -e $repair_snapshot || -L $repair_snapshot ]]; then
    [[ -f $repair_snapshot && ! -L $repair_snapshot && -f $repair_start && ! -L $repair_start ]] || exit 1
    repair_started_at=$(<"$repair_start")
    [[ -n $repair_started_at ]] || exit 1
else
    [[ ! -e $repair_start && ! -L $repair_start ]] || exit 1
    "$agentkit/parallel-issues/scripts/cross-write-check.sh" snapshot \
        --worktree "$REPO_ROOT" --output "$repair_snapshot" --write-set "$repair_scope" || exit 1
    repair_started_at=$(date -u +%FT%TZ) || exit 1
    printf '%s\n' "$repair_started_at" >"$repair_start" || exit 1
fi
printf 'repair_started_at=%s\n' "$repair_started_at"
"$agentkit/parallel-issues/scripts/compose-worker-prompt.sh" --template pr-fix-batch \
    --worktree "$repair_worktree" --issue "$PR" --branch "$repair_branch" \
    --worker-model "$worker_model" --worker-effort "$worker_effort" \
    --write-set "$repair_scope" --findings-file "$accepted_findings" --output "$repair_prompt" || exit 1
grep -Fq -- '--cmd test' "$repair_prompt" || exit 1
# Spawn with $repair_prompt; root records its end, then Collects with this snapshot, interval, and scope.
```

## Worker-owned publication

Workers commit and push their own branch. Between those actions, run unfocused `agent-run.sh --cmd test`
after the repair commit and before push. Use focused checks while editing; commit via `worktree-commit.sh`
with explicit files and a trailer; push only after the clean committed HEAD passes. Return a completion report
with branch, full SHA, diffstat, and green log. Root passes it to `finding-ledger.sh evidence`, which refuses
focused, red, dirty, unbound, or different-HEAD logs; send the worker back to verify.
The root owns the pushed `base...HEAD` review, PR metadata, board, replies, and next cycle.

## Environment-refusal fallback

A refused harness patch *tool* is not a refused *shell*: before reporting an environment refusal a worker
probes the shell with a trivial write and names what it tried. See [../../.shared/six-step-loop.md](../../.shared/six-step-loop.md)'s
"How to write a file" for the write-mechanism order and the hand-authored-diff prohibition; an interrupted
change leaves the tree fully applied or fully reverted, never partial.

The unstaged publication handback is only an environment-refusal fallback: if
`worktree-commit.sh` exits 2, return scoped dirt, diffstat, green log, branch, and exact commit command;
if the push was refused after the commit succeeded, return SHA and `git push -u origin BRANCH`.

After push, root inspects `base...HEAD` and continues the existing PR's CI, reply, review, and metadata cycle;
it does not create a DRAFT PR. Surface unrelated dirt; do not adopt it.

For a correction cycle, resume the same worker with `followup_task` when possible rather than
spawning a new one; never create concurrent writers in one PR worktree.

### Bounded inline corrections

Skip dispatch only for a purely mechanical diff with no new behavior, data shape, or control flow,
at most five changed lines, where root authored the exact diff and reruns full declared verification.
Record its recorded reason with root harness attribution; otherwise resume the same worker with `tools.send` first.

Workers use absolute worktree paths and restore/report any cross-write.
