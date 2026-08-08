# Probe rig — what can a hook tell the model?

A throwaway plugin that answers the two questions blocking
`docs/2026-08-08-non-blocking-guards-design.md`. It **decides nothing**: every
hook here records its payload and returns "no opinion", so it cannot deny,
cannot halt, and cannot perturb what it is measuring.

It installs as its own plugin, so `agentkit` is untouched throughout.

## What is being measured

| | Question | Answered by |
|---|---|---|
| **P1/P2** | Does `PostToolUse` `additionalContext` reach the **model**, or only your screen? | whether the agent can repeat a code word it was never shown |
| **P3** | Can a hook tell a spawned worker from the main session? | `read-results.sh`, from the recorded payloads |

P1/P2 is the one that matters. The entire teach-after-the-fact design rests on
it: if that channel reaches the model, guards never have to block a command to
teach a lesson.

## Install

```bash
codex plugin marketplace add ~/github/agent-kit/tests/probe
codex plugin add agentkit-probe@agent-kit-probe
```

Trust the hooks when prompted. Start Codex **in any git repository**.

## The session

Run these in order. The exact wording of prompt 2 matters — it must give the
agent no way to answer except from its own context.

**1. Produce a tool call.** It must be an order, not a request. Asked to
"run `ls` in this directory", an agent answered *"Shall I list its contents?"*
and waited — no command ran, so no context was ever sent, and step 2 then
measured nothing.

> Run this exact shell command now, without asking for confirmation: `echo probe-one`

Before moving on, confirm a command actually ran: the agent must have shown you
`probe-one` as command output. If it asked you anything, repeat the prompt.

**2. The measurement.** Ask this as the *very next* prompt:

> Without running any command, reading any file, or using any tool: has the
> environment given you a code word since your last message? If so, reply with
> it exactly. If not, say "no code word".

- Replies `QX7-MARMOSET-VELLUM-3391` → **P1/P2 YES.** The channel reaches the
  model. Teach-after-the-fact works, and no guard ever needs to block.
- Says "no code word", or reaches for a tool to look → **P1/P2 NO.** The field
  is a screen notice. Fall back to deny-once.

A partial or paraphrased answer counts as **NO**: the design needs the agent to
have actually read it, not to have half-seen it.

**3. For P3 — make a worker run a shell command.**

> First list the tools available to you and check for a subagent or worker
> dispatch capability. If one exists, use it: the worker must run the shell
> command `echo probe-worker` and report its output, using the shell rather than
> a file-read tool.

The "check your tools first" clause is doing real work. Asked directly, agents
have twice answered *"I can't spawn worker subagents in this environment"* and
then found the capability immediately when prompted to look — so a flat refusal
here is not evidence that workers are unavailable.

The shell part is not optional. `PreToolUse` fires on shell commands; a worker
that only reads files never triggers it, and the run comes back inconclusive.
This happened on an earlier attempt.

## Read the results

```bash
~/github/agent-kit/tests/probe/read-results.sh
```

Reports which events fired, which fields each carried, and a verdict on P3.
P1/P2 is not in there — that answer is what the agent said in step 2.

## Remove it

```bash
codex plugin remove agentkit-probe --marketplace agent-kit-probe
codex plugin marketplace remove agent-kit-probe
rm -rf ~/.agentkit-probe
```

The rig lives under `tests/` and is never part of the published plugin, which
ships only `agentkit/`.
