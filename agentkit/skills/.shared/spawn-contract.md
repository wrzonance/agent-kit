# Implementation-worker spawn contract

Read this before dispatching any implementation worker — issue leads in `parallel-issues`
Phase 2's Dispatch step, and mechanical fix-batch workers in `review-remote-pr`'s
Implementation-worker gate.
It is the single detailed home for model/effort selection, spawn policy, and
the degraded no-spawn path. The dispatching skill's own body states only that the gate is
mandatory and names this file for the detail.

## Model/effort selection (MANDATORY before dispatch)

Implementation work is assigned to a worker for role separation: each worker receives fresh fenced context
with sole-writer isolation, while the root performs independent root validation before publication. Resolve
the repository's `AGENT_WORKER_MODEL`,
`AGENT_WORKER_MODEL_FALLBACK`, and `AGENT_WORKER_EFFORT` declarations before inspecting the
current `spawn_agent` capability; worker model and effort are configuration, not a
model-tier or pricing judgment. The resolver reads `.agent/config.env` line-wise and never
sources it:

The root/orchestrator must not implement when a real worker can be dispatched except for the two
allowed implementation exceptions: a genuinely spawn unavailable degraded path (`worker=self`)
or a qualifying bounded inline correction.

```bash
worker_model_default='gpt-5.6-luna'
worker_model_fallback_default='gpt-5.6-terra'
worker_effort_default='high'

[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || {
    printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2
    exit 1
}

# Roster keys: one candidate per harness family, picked by the contract's harness= name; a declared entry is sanctioned by declaration and wins over the singular keys.
roster_entry_for_family() {
    local csv=$1 family=$2 item
    [ -n "$csv" ] || return 1
    IFS=, read -ra roster_items <<< "$csv"
    for item in "${roster_items[@]}"; do
        [ "$(model_family "$item")" = "$family" ] && { printf '%s\n' "$item"; return 0; }
    done
    return 1
}

worker_config_value() {
    # shellcheck disable=SC2034  # values are consumed by the dispatch block below
    local key=$1 default=$2 value
    if value=$("$agentkit/.shared/scripts/repo-config.sh" \
        --repo-root "$repository_root" --get "$key") && [[ -n $value ]]; then
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

# Unsuffixed keys are Codex-shaped by convention; re-resolve them for the running harness.
running_harness=$("$agentkit/.shared/scripts/contract-read.sh" \
    --repo-root "$repository_root" --get harness.name) || {
    printf '%s\n' 'no harness= line in the environment contract; report BLOCKED' >&2
    exit 1
}
case $running_harness in
    codex)  native_model_default='gpt-5.6-luna';    native_fallback_default='gpt-5.6-terra' ;;
    claude) native_model_default='claude-sonnet-5'; native_fallback_default='claude-sonnet-5' ;;
    # OpenCode has no fixed worker tier: a repository that declares nothing stops for configuration.
    opencode) native_model_default=''; native_fallback_default='' ;;
    *) printf 'unrecognized harness %s; report BLOCKED\n' "$running_harness" >&2; exit 1 ;;
esac

# Takes an explicit harness so a foreign value is checked against ITS OWN sanctioned worker tier (claude-sonnet-5; never claude-opus-5, the reviewer tier).
model_in_sanctioned_set() {
    case "$1:$2" in
        codex:gpt-5.6-luna | codex:gpt-5.6-terra) return 0 ;;
        claude:claude-sonnet-5) return 0 ;;
        opencode:*)
            # OpenCode: any well-formed provider/model-id (exactly one '/') is sanctioned by declaration; =~ because a case glob cannot express "exactly one slash".
            [[ $2 =~ ^[^/]+/[^/]+$ ]]
            ;;
        *) return 1 ;;
    esac
}
# Single home: repo-config.sh's model_family (issue #606).
model_family() { "$agentkit/.shared/scripts/repo-config.sh" --model-family "$1" 2> /dev/null || printf unknown; }
# Provider namespace OpenCode addresses a foreign harness's sanctioned model under when pivoting into OpenCode.
model_home_provider() {
    case $1 in
        codex) printf openai ;;
        claude) printf anthropic ;;
        *) printf '' ;;
    esac
}

# Resolves one declaration slot for the running harness; sets $resolved_value/$pivot_note as globals and exits 1 on an unsanctioned model -- call as a plain statement, never inside $(...) (a subshell exit would not stop the script).
resolve_worker_slot() {
    local base=$1 native_default=$2 roster_key=$3 value family roster_csv roster_value roster_get_rc=0
    # A declared roster is authoritative: no entry for the running harness is a configuration error, never a silent fallback to the singular key or built-in default.
    # --get exits 2, not the absent-key 1, when the roster line IS declared but rejected by validate() -- captured below so a malformed roster degrades on its own message, not as silently-unset (issue #606 round 3).
    roster_csv=$("$agentkit/.shared/scripts/repo-config.sh" \
        --repo-root "$repository_root" --get "$roster_key" 2> /dev/null) || roster_get_rc=$?
    if [ -n "$roster_csv" ]; then
        if roster_value=$(roster_entry_for_family "$roster_csv" "$running_harness"); then
            resolved_value=$roster_value
            pivot_note=''
            return
        fi
        if [ "${yolo_invocation:-false}" = true ]; then
            printf '%s\n' "yolo: declared roster $roster_key='$roster_csv' has no entry for running harness '$running_harness'; falling back to the singular key or built-in default $native_default" >&2
        else
            printf '%s\n' "declared roster $roster_key='$roster_csv' has no entry for the running harness '$running_harness'; the roster is authoritative once declared and never falls back to $base or a built-in default -- add a $running_harness entry or remove the roster declaration" >&2
            exit 1
        fi
    elif [ "$roster_get_rc" -eq 2 ]; then
        if [ "${yolo_invocation:-false}" = true ]; then
            printf '%s\n' "yolo: declared roster $roster_key is invalid; falling back to the singular key or built-in default $native_default" >&2
        else
            printf '%s\n' "declared roster $roster_key is invalid; never falls back silently -- fix or remove the declaration (see repo-config.sh --validate)" >&2
            exit 1
        fi
    fi
    value=$(worker_config_value "$base" "$native_default")
    if model_in_sanctioned_set "$running_harness" "$value"; then
        resolved_value=$value
        pivot_note=''
        return
    fi
    family=$(model_family "$value")
    if [[ $family != "$running_harness" && $family != unknown ]] &&
        model_in_sanctioned_set "$family" "$value"; then
        # A foreign-family value that is that harness's own sanctioned worker tier pivots to this harness's native tier; any other unsanctioned value falls through to the stop below.
        local pivot_target=$native_default
        if [[ $running_harness == opencode ]]; then
            # OpenCode pivots INTO its provider-qualified address for the declared model (openai/gpt-5.6-luna), never a guessed id.
            pivot_target="$(model_home_provider "$family")/$value"
        fi
        resolved_value=$pivot_target
        pivot_note="pivoted from cross-harness declaration '$value' (declared for $family) to native '$pivot_target'"
        return
    fi
    printf 'unsanctioned model for %s: %s; explicit user authorization required\n' \
        "$running_harness" "$value" >&2
    exit 1
}

resolve_worker_slot AGENT_WORKER_MODEL "$native_model_default" AGENT_WORKER_MODELS
# shellcheck disable=SC2034  # consumed by the spawn shape and completion-table record below
worker_model=$resolved_value
# shellcheck disable=SC2034  # consumed by the completion-table record below
model_pivot_note=$pivot_note
resolve_worker_slot AGENT_WORKER_MODEL_FALLBACK "$native_fallback_default" AGENT_WORKER_MODELS_FALLBACK
# shellcheck disable=SC2034  # consumed by the spawn shape and completion-table record below
worker_model_fallback=$resolved_value
# shellcheck disable=SC2034  # consumed by the completion-table record below
fallback_pivot_note=$pivot_note
```

On Codex, the sanctioned no-extra-authorization model set is exactly **`gpt-5.6-luna`** and
**`gpt-5.6-terra`**; on Claude it is exactly **`claude-sonnet-5`**; OpenCode sanctions any declared
`provider/model-id` and has no built-in default (a repository that declares nothing there stops for
configuration). Validate both resolved `worker_model` and `worker_model_fallback` against that set
before dispatch. Any other syntactically safe configured preferred or fallback model must stop for
explicit user authorization; never silently substitute a sanctioned model. An empty or malformed
declaration is reported and falls back to its built-in value (`using built-in default`). The
configured effort is the per-run default; a dispatch-plan entry's `workerEffort` override (with its
`effortReason`) replaces it for that issue only.

### Harness-neutral roster (`AGENT_WORKER_MODELS`/`_FALLBACK`)

One comma-separated candidate per harness family (e.g. `claude-sonnet-5,gpt-5.6-luna`);
`resolve_worker_slot` picks the entry whose family matches the contract's `harness= name=`
(`--get harness.name`), never the value's shape. A declared roster entry is sanctioned by
declaration, wins over the singular keys, and is authoritative once valid: no entry for the running
harness is a configuration error naming the roster and the running harness, never a silent fallback.
Under `--yolo` the same case falls through to the singular key or built-in default with one stderr
line instead: a malformed declaration in an authorized run is a warning, not a stop.

### Harness-aware pivot

A bare `AGENT_WORKER_MODEL` value shaped for a *different* harness pivots to the running harness's
native worker tier (`gpt-5.6-luna` on Codex, `claude-sonnet-5` on Claude, `<home-provider>/<model>`
on OpenCode, e.g. `openai/gpt-5.6-luna`) only when it is itself that other harness's sanctioned
worker tier — `claude-opus-5` read on Codex still stops. Never pivot a same-family value that merely fails the
sanctioned check, or a value in no known family; both stop for explicit user authorization
required by the gate above. The completion table records every pivot verbatim, e.g.
`worker=claude-sonnet-5 high (pivoted from cross-harness declaration 'gpt-5.6-luna')`, so a
substitution is always evidence, never inferred from prompt text alone.

Inspect the current `spawn_agent` capability before dispatch:

- Preferred model: the resolved `worker_model`, with automatic fallback to the resolved
  `worker_model_fallback`; the resolved `worker_effort` applies to either.
- During capability selection, set `selected_worker_model` to `worker_model` when the preferred
  model is advertised, otherwise to `worker_model_fallback` after that fallback passes the same
  sanctioned-model gate. Bind `selected_worker_pivot_note` at that same moment, to whichever
  slot's note actually applies: `model_pivot_note` when the preferred model was selected,
  `fallback_pivot_note` when the fallback was — the pivot notes are per-slot, so a fallback
  selected after a cross-harness pivot must not lose its own audit note to the preferred slot's
  (which may be empty, or may record a different pivot, or none at all).
- Required context isolation: Paste the complete issue/spec,
  prior art, branch rules, and the six-step contract into the prompt — do not rely on
  inherited history.
- Required role: **`agent_type: "worker"`**.
- Never omit `model` or `reasoning_effort`; omission can silently inherit an expensive parent.

- If neither resolved model is advertised, **STOP before creating worktrees, moving Project items, or
  editing code** and report the capability block. The spawn request is the model-and-effort evidence:
  the completion table carries the actual `worker model` and `worker effort` (or `worker=self (spawn unavailable)`)
  plus `selected_worker_pivot_note` when non-empty, so a tier claim is never inferred from prompt text.
- This gate applies only when `spawn_agent` exists. If the runtime advertises
  **no** spawn capability (`multi_agent = false`), there is no worker to configure and no
  model to select — take the degraded path below instead of blocking the run.
- `review-remote-pr`'s Step 1b read-only reviewer role never satisfies this gate; it is a
  different capability.

## The spawn call

Set the worker's working directory to its assigned worktree whenever the harness supports a
cwd/workdir field; the absolute-path rule in the prompt remains mandatory even when that
field is unavailable.

Do not describe this call without making it. A task is dispatched only after `spawn_agent`
returns a task/agent identifier.

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

## Bounded inline corrections

Before any root write in a worker worktree, including an inline correction, merge-down, or
chain-base publish, prove quiescence: no unacknowledged `SendMessage` remains for that lead,
`git status --porcelain` is clean except declared operator-pending paths, and a ledger line
beginning `quiescence:` records the worktree and status evidence. An `idle_notification` whose
timestamp predates the newest outbound message to that lead is stale and cannot satisfy this gate.
Prefer `collaboration.followup_task` for a resumable lead.

The root may apply a correction inline, at zero dispatches, only when **all** conditions hold:
the diff is purely mechanical with no new behavior, data shape, or control flow; it is at most five changed lines;
the quiescence gate holds; the root authored the exact diff during review; and
the full declared verification is rerun afterward. Inline corrections commit with
`worktree-commit.sh --exact`. The root records the decision and its reason, and the commit uses
root harness attribution rather than the worker's. Anything past this bar resumes the same worker
with `collaboration.followup_task` first; a fresh worker is the exception when follow-up is
unavailable. The inline/dispatch decision is never silent.

## Tier mapping

Root = trust/judgment and every privileged or forge-facing action. Luna = mechanical execution, the
default worker tier; Terra `high` is its automatic fallback — a Luna-unavailable worker is still a dispatched
worker. Terra `xhigh` is reserved for the blind same-harness adversarial-review fallback. A single clean unit
of work may skip the dispatched **lead** (the orchestration tier), never the **implementation worker**: any
code change goes through one dispatched sole writer, except the two allowed implementation exceptions: a genuinely spawn unavailable path
(labelled `worker=self` with the reason) or a qualifying bounded inline correction.

On Claude the same split maps to `claude-opus-5` (root judgment and the cross-harness reviewer) and
`claude-sonnet-5` (the dispatched worker) — see "Harness-aware pivot" for how a declaration resolves on
the running harness. OpenCode has no fixed pair: the worker tier is the repository-declared
`provider/model-id`, and its adversarial review always runs cross-harness against the peer CLI
`peer-cli=` names (`harness-id.sh` probes `codex,claude` in order and emits one `peer-cli= <name> present|absent` line).
