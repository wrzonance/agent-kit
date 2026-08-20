# Implementation-worker spawn contract

Read this before dispatching any implementation worker — issue leads in `parallel-issues`
Phase 2's Dispatch step, and mechanical fix-batch workers in `review-remote-pr`'s
Implementation-worker gate.
It is the single detailed home for model/effort selection, the exact spawn call shape, and
the degraded no-spawn path. The dispatching skill's own body states only that the gate is
mandatory and names this file for the detail.

## Model/effort selection (MANDATORY before dispatch)

Implementation work is assigned to a worker for role separation: each worker receives fresh fenced context
with sole-writer isolation, while the root performs independent root validation before publication. Resolve
the repository's `AGENT_WORKER_MODEL`,
`AGENT_WORKER_MODEL_FALLBACK`, and `AGENT_WORKER_EFFORT` declarations before inspecting the
current `collaboration.spawn_agent` capability; worker model and effort are configuration, not a
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

# The declarations above are Codex-shaped by convention (gpt-5.6-*): a config
# that only declares the unsuffixed keys is Codex-scoped data, not
# harness-neutral data. Resolve the running harness and re-resolve worker_model
# / worker_model_fallback for it before trusting the values above.
running_harness=$("$agentkit/.shared/scripts/contract-read.sh" \
    --repo-root "$repository_root" --get harness.name) || {
    printf '%s\n' 'no harness= line in the environment contract; report BLOCKED' >&2
    exit 1
}
case $running_harness in
    codex)  native_model_default='gpt-5.6-luna';    native_fallback_default='gpt-5.6-terra' ;;
    claude) native_model_default='claude-sonnet-5'; native_fallback_default='claude-sonnet-5' ;;
    # OpenCode has no fixed vendor tier -- there is no single OpenCode model
    # id every repository should default to, the way gpt-5.6-luna/
    # claude-sonnet-5 are for Codex/Claude. So there is no built-in default:
    # a repository that declares nothing stops for explicit configuration
    # (see resolve_worker_slot below) rather than guessing a provider.
    opencode) native_model_default=''; native_fallback_default='' ;;
    *) printf 'unrecognized harness %s; report BLOCKED\n' "$running_harness" >&2; exit 1 ;;
esac

# Takes an EXPLICIT harness, not just $running_harness: it is also used to ask
# "is this foreign-family value even sanctioned on ITS OWN harness" before a
# pivot is allowed. Codex's pair stays as-is; Claude's worker tier is
# claude-sonnet-5 -- the same Root/Worker split (claude-opus-5 reviews,
# claude-sonnet-5 implements) already used for cross-harness adversarial
# review, which is exactly why claude-opus-5 must NOT satisfy this check: it
# is a real Claude model id, but the reviewer tier, not the worker tier.
# Extend both here and in the tier-mapping section below together, in
# lockstep, the moment a harness gains a second sanctioned worker tier.
model_in_sanctioned_set() {
    case "$1:$2" in
        codex:gpt-5.6-luna | codex:gpt-5.6-terra) return 0 ;;
        claude:claude-sonnet-5) return 0 ;;
        # OpenCode's sanctioned worker tier is repository-declared, not a
        # fixed allowlist: any value shaped as a well-formed
        # provider/model-id pair (non-empty on both sides of exactly one
        # '/') is sanctioned for OpenCode purely by being declared and
        # correctly shaped -- there is no OpenCode equivalent of
        # gpt-5.6-luna to enumerate here.
        opencode:?*/?*) return 0 ;;
        *) return 1 ;;
    esac
}
model_family() {
    case $1 in
        gpt-5.6-*) printf codex ;;
        claude-*) printf claude ;;
        # Checked after the two prefix cases above so neither can be
        # mis-classified: gpt-5.6-*/claude-* never contain '/', so ordering
        # only matters for readability here, not correctness.
        */*) printf opencode ;;
        *) printf unknown ;;
    esac
}
# The provider namespace OpenCode addresses a foreign harness's own sanctioned
# model under, when pivoting a foreign-family declaration INTO a running
# OpenCode session (see resolve_worker_slot below). Not a claim that these are
# the ONLY providers hosting these models on OpenCode -- just the pivot
# target's provider prefix for the two families this contract already knows.
model_home_provider() {
    case $1 in
        codex) printf openai ;;
        claude) printf anthropic ;;
        *) printf '' ;;
    esac
}

# Resolves ONE declaration slot (AGENT_WORKER_MODEL or AGENT_WORKER_MODEL_FALLBACK)
# for the running harness -- the unsuffixed key is the only declaration; the
# harness supplies the concrete model, never a second harness-keyed key.
#
# Sets $resolved_value and $pivot_note (empty when no pivot occurred) as
# globals for the completion-table record, and calls `exit 1` directly on an
# unsanctioned model -- so this is called as a plain statement, NEVER wrapped
# in `$(...)`. Command substitution forks a subshell: an `exit` inside one
# would only kill that subshell while the real script kept running on an
# empty resolved value, silently defeating the authorization stop.
resolve_worker_slot() {
    local base=$1 native_default=$2 value family
    value=$(worker_config_value "$base" "$native_default")
    if model_in_sanctioned_set "$running_harness" "$value"; then
        resolved_value=$value
        pivot_note=''
        return
    fi
    family=$(model_family "$value")
    if [[ $family != "$running_harness" && $family != unknown ]] &&
        model_in_sanctioned_set "$family" "$value"; then
        # The declaration states intent for a DIFFERENT harness's own
        # SANCTIONED worker tier, not a request for this specific unsanctioned
        # model on THIS harness -- pivot to the running harness's native tier
        # instead of stopping. A foreign-family value that is not itself that
        # harness's sanctioned worker tier (e.g. claude-opus-5, a real Claude
        # model id but the reviewer tier, not the worker tier) is an
        # unsupported configured model, not a mapping problem, and falls
        # through to the stop below -- so does a same-family value that
        # merely fails the sanctioned check (e.g. a typo'd fallback), and a
        # value in neither known family, which pivoting could not resolve
        # correctly anyway.
        local pivot_target=$native_default
        if [[ $running_harness == opencode ]]; then
            # OpenCode has no fixed native default to pivot INTO (see the
            # case statement above) -- its "native tier" for a cross-harness
            # pivot is instead OpenCode's own provider-qualified address for
            # the EXACT sanctioned model that was declared, built from the
            # declaring harness's home provider rather than an invented
            # OpenCode model id. A codex-declared gpt-5.6-luna therefore
            # pivots to 'openai/gpt-5.6-luna' on OpenCode, never to a blank
            # or guessed value.
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

resolve_worker_slot AGENT_WORKER_MODEL "$native_model_default"
# shellcheck disable=SC2034  # consumed by the spawn shape and completion-table record below
worker_model=$resolved_value
# shellcheck disable=SC2034  # consumed by the completion-table record below
model_pivot_note=$pivot_note
resolve_worker_slot AGENT_WORKER_MODEL_FALLBACK "$native_fallback_default"
# shellcheck disable=SC2034  # consumed by the spawn shape and completion-table record below
worker_model_fallback=$resolved_value
# shellcheck disable=SC2034  # consumed by the completion-table record below
fallback_pivot_note=$pivot_note
```

The sanctioned no-extra-authorization model set is exactly **`gpt-5.6-luna`** and
**`gpt-5.6-terra`**. Validate both resolved `worker_model` and `worker_model_fallback` against
that set before dispatch. Any other syntactically safe configured preferred or fallback model
must stop for explicit user authorization; never silently substitute a sanctioned model.
(This is scoped to the running harness — see "Harness-aware pivot" below for the one deliberate
exception: a bare declaration recognizably shaped for a *different* harness pivots instead of
stopping.)
The built-in defaults preserve existing behavior when a repository declares nothing. An empty,
malformed, or otherwise rejected declaration is reported and falls back to its built-in value;
the fallback model declaration is not optional just because the preferred model declaration is
present. A syntactically safe but unsupported model therefore remains visible to the explicit user
authorization gate. The configured effort is carried through unchanged after resolver
validation — it is the per-run **default**: a dispatch-plan entry's `workerEffort` override
(recorded with its `effortReason`; see `parallel-issues`'s triage-and-selection reference)
replaces it for exactly that issue. Effort follows the issue, not the run.

### Harness-aware pivot

`worker_model`/`worker_model_fallback` are re-resolved above for the running harness, read once
from `harness.name` (already established at Step 0; no extra probe). A bare `AGENT_WORKER_MODEL`
declaration is Codex-shaped data by convention, not harness-neutral data: on a repository that
declares only the unsuffixed keys, resolution on a harness that does not match that shape pivots
to *that* harness's own native worker tier rather than stopping — the declaration states the
*intent* ("dispatch the standard worker tier at high effort"), and `harness.name` supplies the
concrete model id (`gpt-5.6-luna` on Codex, `claude-sonnet-5` elsewhere). There is no second,
harness-keyed declaration key: the unsuffixed `AGENT_WORKER_MODEL`/`AGENT_WORKER_MODEL_FALLBACK`
remain the only declarations, on every harness.

A foreign-family value pivots only when it is ITSELF the sanctioned worker tier on its own
harness — a name recognizably belonging to a different harness's family is not by itself enough.
`claude-opus-5` is a real Claude model id (the root/reviewer tier — see Tier mapping below), but it
is not the sanctioned Claude *worker* tier, so `AGENT_WORKER_MODEL_FALLBACK=claude-opus-5` read on
Codex still stops for explicit authorization rather than silently becoming `gpt-5.6-terra`. Never
pivot a same-family value that merely fails the sanctioned check (e.g. a typo'd
`AGENT_WORKER_MODEL_FALLBACK=gpt-5.6-sol` read on Codex), a value recognizable in neither known
family, or a foreign-family value that is not that harness's own sanctioned worker tier — all three
are a real unsupported configured model and still stop for explicit user authorization, unchanged
from the gate above. Only a declaration recognizably shaped for a *different* harness AND
sanctioned as that harness's own worker tier pivots silently.

When a pivot occurred, the completion table records it verbatim beside the model and effort — e.g.
`worker=claude-sonnet-5 high (pivoted from cross-harness declaration 'gpt-5.6-luna')` — so a
substitution is always evidence, never inferred from prompt text alone.

**OpenCode's native tier.** Unlike Codex/Claude, OpenCode has no single fixed worker model:
`AGENT_WORKER_MODEL` on an OpenCode repository is expected in `provider/model-id` form (e.g.
`wrzcluster/qwen3-coder`), and *any* well-formed `provider/model-id` value is sanctioned purely by
being declared that way — there is no OpenCode equivalent of `gpt-5.6-luna` to enumerate. That
absence of a fixed default has two consequences: a repository that declares nothing on OpenCode
stops for explicit configuration rather than guessing a vendor, and a pivot *into* OpenCode from a
foreign-family declaration (`AGENT_WORKER_MODEL=gpt-5.6-luna` read while running OpenCode) resolves
to OpenCode's own provider-qualified address for that exact foreign model — `openai/gpt-5.6-luna` —
rather than an invented OpenCode-native id. `model_home_provider` names the provider each known
family is pivoted under (`codex` → `openai`, `claude` → `anthropic`); this is the pivot target's
provider prefix, not a claim that it is the only provider hosting that model on OpenCode. A pivot
*out of* OpenCode is unaffected: a `provider/model-id` declaration read on Codex or Claude is a
foreign-family value like any other, and pivots to that harness's own fixed native default exactly
as `gpt-5.6-luna` does today.

Inspect the current `collaboration.spawn_agent` capability before dispatch:

- Preferred model: the resolved `worker_model`, with automatic fallback to the resolved
  `worker_model_fallback`; the resolved `worker_effort` applies to either.
- During capability selection, set `selected_worker_model` to `worker_model` when the preferred
  model is advertised, otherwise to `worker_model_fallback` after that fallback passes the same
  sanctioned-model gate. Bind `selected_worker_pivot_note` at that same moment, to whichever
  slot's note actually applies: `model_pivot_note` when the preferred model was selected,
  `fallback_pivot_note` when the fallback was — the pivot notes are per-slot, so a fallback
  selected after a cross-harness pivot must not lose its own audit note to the preferred slot's
  (which may be empty, or may record a different pivot, or none at all).
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
  claim is never inferred from prompt text alone. When `selected_worker_pivot_note` is non-empty,
  the completion table appends it beside that same model and effort — this is what carries a
  fallback's own pivot into the record when the fallback, not the preferred model, was the one
  actually selected.
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

## Bounded inline corrections

The root may apply a correction inline, at zero dispatches, only when **all** four conditions
hold: the diff is purely mechanical with no new behavior, data shape, or control flow; it is at most five changed lines; the root authored the exact diff
during review; and the full declared verification is rerun afterward. The root records the decision and its recorded reason, and the commit uses
root harness attribution rather than the worker's. Anything past this bar resumes
the same worker with `collaboration.followup_task` first; a fresh worker is the exception when
follow-up is unavailable. The inline/dispatch decision is never silent.

## Tier mapping

Root = trust/judgment and every privileged or forge-facing action. Luna = mechanical
execution, the default worker tier; Terra `high` is its automatic fallback (see Model/effort
selection above) — a Luna-unavailable worker is still a dispatched worker, not a blind
fallback. Terra `xhigh` is reserved for the context-free blind same-harness adversarial-review
fallback only. A single clean unit of work may be handled by the root without a dispatched
**lead** — that is, without an intermediate orchestration tier. It is not permission to skip the
**implementation worker**: any code change still goes through one dispatched worker as its sole
writer, except for the two allowed implementation exceptions: a genuinely spawn unavailable path
(each consuming skill's degraded path must be labelled `worker=self` with the reason) or a
qualifying bounded inline correction. Root omitting a lead is an
org-chart shortcut; root writing the code itself bypasses the isolated model, the six-step gate,
and the audited handback.

Luna/Terra are Codex's own tier names. On Claude the same Root/Worker split maps to
`claude-opus-5` (root judgment, the same reviewer used for cross-harness adversarial review) and
`claude-sonnet-5` (the dispatched worker) — see "Harness-aware pivot" above for how a repository's
declaration resolves to the concrete model on whichever harness is actually running. On OpenCode
there is no fixed root/worker pair of its own to name here — the worker tier is the
repository-declared `provider/model-id` above, and OpenCode has no local reviewer tier at all: its
adversarial review always runs cross-harness, against whichever peer CLI `peer-cli=` names (see
below).

**Peer-cli mapping.** Claude and Codex each have a fixed 1:1 peer (Claude → Codex, Codex → Claude),
so `harness-id.sh` names exactly one candidate for `agent-preflight.sh`'s `probe_peer_cli` to check.
OpenCode has no such fixed pairing — a self-hosted OpenCode session may have either or both peer
CLIs installed — so `harness-id.sh` hands `probe_peer_cli` an ordered, comma-separated candidate
list (`codex,claude`: Codex checked first, Claude as fallback) instead of a single name.
`probe_peer_cli` still emits exactly one winning `peer-cli= <name> present|absent` line, so every
existing consumer of that contract line keeps its single-name parse; only the *search* is
multi-candidate, never the emitted fact.
