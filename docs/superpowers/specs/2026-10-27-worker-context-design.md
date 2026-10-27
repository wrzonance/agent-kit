# Worker context reduction (#1012 / PR #1013)

The operator selected two follow-on changes: dispatch by prompt-file reference,
then reduce worker overhead. Preserve the completed six-trial 82093d0 comparison
before changing behavior; commit and push the follow-on and leave the next live
benchmark to the operator.

## Approach

Use the existing absolute `cwd`, `prompt`, model, effort and name fields. The
root's task message is a short recipe: work only in the given worktree; read and
follow the given prompt file; own that work through its final result. For Codex,
use a fresh worker context (`fork_turns=none`). The root need not load or duplicate
the prompt. A worker whose prompt cannot be read reports the missing path rather
than guessing its task. Resumed workers read rewritten prompts on redispatch.

Inline prompts duplicate data into root history. A new dispatch command or shared
state schema adds an unnecessary interface: the existing spawn line already
contains all required references. This design uses those references directly.
The selected reference approach matches Anthropic's just-in-time context guidance:
https://www.anthropic.com/research/effective-context-engineering-for-ai-agents
Concise tool results follow:
https://www.anthropic.com/research/writing-tools-for-agents

## Worker changes

Keep each playbook self-contained. Define the absolute `ak` path once and use the
short name in the steps, explicitly requiring invocation by that absolute path.
Condense repeated phrasing and PR-writing instructions, keeping exact required
headings. Keep repository instructions, ownership, TDD, partial completion,
merge-downs, untrusted tracker boundaries, review dispositions, CI retries,
threads and final receipt semantics. Preserve issue text verbatim.

Tool responses retain status, exit codes, log locations and failure diagnostics.
Keep command-start and heartbeat evidence; remove the repeated wait tutorial from
fast successful setup/verify calls and put the wait rule once in the playbook.
A reused review points to its existing findings instead of advertising another
review. Explicit `--again` remains available; this changes the default guidance.

## Verification and measurement

Fresh-context application samples (five control, five updated) exercise issue and
PR dispatch, shell handle collection, missing prompt and correction/merge paths.
Behavioral shell tests cover concise output, retained logs and failures, heartbeat,
and review reuse without an extra provider invocation. Run v2 and canonical gates.
The branch already consumed its allowed adversarial review; do not repeat it.

Preserve raw batch rows in `bench/results/batches/`. Compare 82093d0 against the
new candidate with the same locally patched harness and fixture; join the saved
baseline for a historical three-ref table. Track acceptance, total/root/worker
tokens, elapsed time and calls. Prompt bytes are a mechanism check, not proof of
end-to-end token savings. Do not change models, scorer, acceptance or workload.
