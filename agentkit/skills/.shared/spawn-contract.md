# Implementation-worker spawn contract

Read this before dispatching any implementation worker — issue leads in `parallel-issues`
Phase 2's Dispatch step, and mechanical fix-batch workers in `review-remote-pr`'s
Implementation-worker gate.
It is the single detailed home for model/effort selection, the exact spawn call shape, and
the degraded no-spawn path. The dispatching skill's own body states only that the gate is
mandatory and names this file for the detail.

## Model/effort selection (MANDATORY before dispatch)

Bulk implementation belongs on the low-complexity worker tier, never on the orchestrator's
own model. Resolve the repository's worker declarations before inspecting the current
`collaboration.spawn_agent` capability. The resolver reads `.agent/config.env` line-wise and
never sources it:

```bash
worker_model_default='gpt-5.6-luna'
worker_model_fallback_default='gpt-5.6-terra'
worker_effort_default='high'

worker_config_value() {
    # shellcheck disable=SC2034  # values are consumed by the dispatch block below
    local key=$1 default=$2 value
    # >>> prepend THE RESOLVER (defined once in the dispatching skill) <<<
    [ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || {
        printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2
        exit 1
    }
    if value=$("$agentkit/.shared/scripts/repo-config.sh" \
        --repo-root "$repository_root" --get "$key"); then
        printf '%s\n' "$value"
    else
        printf 'worker config: %s is absent or invalid; using built-in default %s\n' \
            "$key" "$default" >&2
        printf '%s\n' "$default"
    fi
}

# shellcheck disable=SC2034  # values are consumed by the spawn shape below
worker_model=$(worker_config_value AGENT_WORKER_MODEL "$worker_model_default")
# shellcheck disable=SC2034  # values are consumed by the spawn shape below
worker_model_fallback=$(worker_config_value AGENT_WORKER_MODEL_FALLBACK \
    "$worker_model_fallback_default")
# shellcheck disable=SC2034  # values are consumed by the spawn shape below
worker_effort=$(worker_config_value AGENT_WORKER_EFFORT "$worker_effort_default")
```

The sanctioned no-extra-authorization model set is exactly **`gpt-5.6-luna`** and
**`gpt-5.6-terra`**. Validate both resolved `worker_model` and `worker_model_fallback` against
that set before dispatch. Any other syntactically safe configured preferred or fallback model
must stop for explicit user authorization; never silently substitute a sanctioned model.
The built-in defaults preserve existing behavior when a repository declares nothing. An empty,
malformed, or otherwise rejected declaration is reported and falls back to its built-in value;
the fallback model declaration is not optional just because the preferred model declaration is
present. A syntactically safe but unsupported model therefore remains visible to the explicit user
authorization gate. The configured effort is carried through unchanged after resolver validation.

Inspect the current `collaboration.spawn_agent` capability before dispatch:

- Preferred model: the resolved `worker_model`, with automatic fallback to the resolved
  `worker_model_fallback`; the resolved `worker_effort` applies to either.
- During capability selection, set `selected_worker_model` to `worker_model` when the preferred
  model is advertised, otherwise to `worker_model_fallback` after that fallback passes the same
  sanctioned-model gate.
- Required context isolation: **`fork_context: false`**. Paste the complete issue/spec,
  prior art, branch rules, and the six-step contract into the prompt — do not rely on
  inherited history.
- Required role: **`agent_type: "worker"`**.
- Never omit `model` or `reasoning_effort`; omission can silently inherit an expensive parent.

- Select the resolved preferred model when advertised; otherwise select the resolved fallback
  automatically. This fallback needs no user authorization when both resolved values pass the
  supported-model gate. If neither model is advertised, **STOP before creating worktrees,
  moving Project items, or editing code** and report the capability block.
- Record the selected model and effort beside every dispatched unit of work. The spawn request
  itself is the model-and-effort evidence — the completion table must carry the actual
  `worker model` and `worker effort` (or `worker=self (spawn unavailable)`) so a tier or effort
  claim is never inferred from prompt text alone.
- This gate applies only when `collaboration.spawn_agent` exists. If the runtime advertises
  **no** spawn capability (`multi_agent = false`), there is no worker to configure and no
  model to select — take the degraded path below instead of blocking the run.
- `review-remote-pr`'s Step 1b read-only reviewer role never satisfies this gate; it is a
  different capability.

## The spawn call

Set the worker's working directory to its assigned worktree whenever the harness supports a
cwd/workdir field; the absolute-path rule in the prompt remains mandatory even when that
field is unavailable.

```text
multi_agent_v1__spawn_agent({
  agent_type: "worker",                                  // default | explorer | worker | report-synthesizer
  fork_context: false,                                   // false = initial prompt only; true = forks this thread
  model: "$selected_worker_model",
  reasoning_effort: "$worker_effort",
  message: "<complete prompt>"
})
// returns { agent_id, nickname }
```

**Parameter names are exact.** There is no `task_name` and no `fork_turns`; an invented key
is silently ignored, so a spawn that *looks* isolated can quietly inherit the calling
thread. `fork_context: false` is what makes the worker start from the pasted prompt alone —
which is why the environment contract and the spec must be pasted as contents, never as a
path or a pointer to this file.

Do not describe this call without making it. A task is dispatched only after `spawn_agent`
returns a task/agent identifier.

## Nesting is blocked

A spawned worker cannot itself spawn — verified: a nested attempt returns "no child-worker
subagent capability is available." A dispatched worker has no mapper or reviewer subagents
of its own; it performs every step itself, strictly sequentially. Only the root orchestrator
spawns.

## Degraded path — `spawn_agent` unavailable (`multi_agent = false`)

Record the reason before falling back, but do not manufacture a call to prove a known
absence: when the runtime **advertises** no spawn capability (`multi_agent = false`), that
advertised state IS the recorded reason — calling a tool the harness does not offer can
error or stall the run, which is the opposite of the degradation this path exists to
provide. Attempt the spawn first only when the capability appears present and might still
fail. Then do the implementation **yourself**, under the identical contract: the
same six-step loop, the same Review and Finish gates, and the same `agent-run.sh` /
`worktree-commit.sh` command lines the prompt would have carried. For a batch of independent
units of work, carry one to completion before starting the next — a single writer has no
parallelism to gain from interleaving.

Label every report and every completion-table row for such work `worker=self (spawn
unavailable)`, so no reader mistakes it for a dispatched Luna/Terra run. This is a
per-batch degradation, not a permanent downgrade: whenever a spawn IS possible, `model` and
`reasoning_effort` remain mandatory and are never inherited from the orchestrator.

## Correction cycles

For a follow-up correction on work already dispatched, resume the same worker with
`collaboration.followup_task` when it remains available, rather than spawning a fresh one;
never create two concurrent writers in one worktree. When `followup_task` is unavailable,
spawn a fresh worker carrying the completed state and the exact remaining step.

## Tier mapping

Root = trust/judgment and every privileged or forge-facing action. Luna = mechanical
execution, the default worker tier; Terra `high` is its automatic fallback (see Model/effort
selection above) — a Luna-unavailable worker is still a dispatched worker, not a blind
fallback. Terra `xhigh` is reserved for the context-free blind same-harness adversarial-review
fallback only. A single clean unit of work may be handled by the root without a dispatched
**lead** — that is, without an intermediate orchestration tier. It is not permission to skip the
**implementation worker**: any code change still goes through one dispatched worker as its sole
writer, and the only exception is a genuinely unavailable spawn (each consuming skill's degraded
path, which must be labelled `worker=self` with the reason). Root omitting a lead is an
org-chart shortcut; root writing the code itself bypasses the isolated model, the six-step gate,
and the audited handback.
