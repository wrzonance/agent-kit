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

## Workflow activation receipt probe (#722)

This separate probe uses `prepare-activation-live.py ABSOLUTE_WORKTREE/.agent/NEW_DIR`.
It prepares a session-only plugin and synthetic workflow; it launches no agent and
changes no global registration. A root/operator launches the supported harness with
that plugin, the generated empty settings/MCP files, native Read and the acknowledgement
shell command allowed, a 120-second process bound, and the generated `prompt.txt` as input.
For Claude Code, absolute Read permission patterns start with `//`, for example
`Read(//absolute/path/to/plugin/**)`; a single slash anchors at the settings source.
Capture structured hook/tool events and stderr beside the fixture. The synthetic
workflow only acknowledges receipt and prints `ACTIVATION-LIVE-RECEIPT`.

Acceptance requires all three independent observations:

1. A real UserPromptSubmit event produced pending delivery with an unpredictable nonce.
2. The session's shell tool executed the exact delivered acknowledgement command,
   returned `agentkit: skill=parallel-issues version=<v> hash=<first12>`, and printed
   the synthetic completion marker. Copying the command into a fixture is insufficient.
3. The durable record is active with `receiptSource=session-acknowledgement` and
   `capabilities.pre-tool-use=observed`. These are runtime observations, distinct
   from the installed tree digest. No record claims native registry loading.

`test-activation.py` provides boundary fixtures only, not live harness acceptance.

### Supported boundary and limitations

[Codex hooks](https://learn.chatgpt.com/docs/hooks) and
[Claude Code hooks](https://code.claude.com/docs/en/hooks) document UserPromptSubmit
`additionalContext` and blocking output. The boundary handles a **leading explicit**
`$agentkit:NAME` or `/agentkit:NAME`; prose mentioning a skill is not an invocation.
The supported path delivers the selected installed workflow explicitly even when
the native skill registry lacks it. Missing workflow files fail `workflow-unavailable`;
bare standalone aliases fail `standalone-registration`; changed installed content
fails `activation-mismatch`; conflicting Skill calls fail `competing-workflow`.

A plugin cannot detect its own absence. With no engaged prompt hook, this interception
is unavailable; installed files or plugin listings do not establish it. Start a fresh
session with the current plugin and trusted hooks, then require acknowledged receipt
before unattended work. Unsupported harnesses or hook versions remain unavailable;
never replace that failure with a plausible workflow. Codex app-server `skills/list`
describes that server process, not an already running TUI. No automatic native
registry proof or arbitrary prose-routing detection is claimed.

### Capability interface for callers

`workflow-activation.sh check --repo-root ROOT --session ID --skill NAME` returns
the schemaVersion 1 JSON record only when receipt and installed content match.
Repeated `--require CAPABILITY` options additionally require each capability to be
`observed`; missing or unknown values fail once with `capability-unavailable`.
Currently `user-prompt-submit` and `pre-tool-use` are observed separately. A record's
`deliverySource`, `receiptSource`, `installedDigest`, and `deliveredDigest` must not
be conflated: installedDigest hashes the shipped skills tree; deliveredDigest hashes
the exact SKILL.md bytes supplied as context. `identity` reports installed bytes
only and never writes activation.
Preflight accepts `--activation-session ID --workflow NAME` and validates before
probes or cached-contract reuse. SessionStart revalidates durable evidence on resume
and compaction without inventing receipt for the current context. It re-arms the
PreToolUse capability to unknown until the resumed harness emits that event again.

### Live acceptance evidence (2026-09-15 UTC)

Three root-operated Claude Code 2.1.271 / `claude-sonnet-5` attempts used isolated session-only
plugins and synthetic workflow text. All processes exited 0; none acknowledged
receipt, so process completion is **not** activation acceptance. The first attempt
exposed blocked helper inspection; its fix has regression coverage. The second used
a shell pipeline and remained blocked. The final attempt offered native Read and
explicit user authorization for the synthetic receipt test, but the model refused
the hook instructions without using tools. Its record remains `status=pending`,
`receiptSource=unknown`, and `pre-tool-use=unknown`.

Local immutable evidence is retained under `.agent/live-activation-probe`,
`.agent/live-activation-probe-v2`, and `.agent/live-activation-probe-v3`, each with
`events.ndjson` and `launch.json`. Fixture checks do not override these results.
A fresh consolidated candidate probe using Claude Code 2.1.272 and
`claude-fable-5-1` at `xhigh` succeeded. Its first turn exposed an incorrectly
anchored Read permission rule and did not acknowledge. A second user turn in the
same session supplied the exact command captured from UserPromptSubmit and
explicitly authorized the local test. The Bash tool executed that command,
returned the identity line, and the assistant printed `ACTIVATION-LIVE-RECEIPT`.
The durable record became active with `receiptSource=session-acknowledgement`
and both `user-prompt-submit` and `pre-tool-use` observed.

Evidence is retained under `.agent/live-activation-consolidated`: `events.ndjson`,
`user-messages.ndjson`, `launch.json`, and independently derived `acceptance.json`.
The transcript SHA-256 is
`394ae3030e5e2a5bb9f8648442c44cf7b6e5c5485828be2b530c540292c0467c`.
This proves the synthetic Claude receipt boundary with an explicit follow-up;
it does not by itself prove first-turn unattended activation or actual issue dispatch.

After correcting the Read rule to `//absolute/path`, the fresh
`.agent/live-activation-first-turn` probe passed in one user turn on the same
CLI/model/effort. Claude inspected the wrapper, its libraries and Python helper,
then executed the exact hook-delivered acknowledgement. All inspections succeeded,
the command exited zero, the receipt became active with both hooks observed, and
the assistant printed the completion marker. Its independently checked
`acceptance.json` binds transcript SHA-256
`bcc33c6cd2881a4573584c7a3792960574d23ea590dc09ba3cc0552312b7b7e5`.
This establishes first-turn synthetic Claude activation. Codex runtime acceptance
and actual issue dispatch were not run. Callers still require their own session's
active receipt and observed guard capability before dispatch.

The installed digest describes the tree serving the boundary/helper. No independent
latest-install inventory is queried: an unchanged old cached hook cannot discover
a newer installation in a separate directory by itself. That case also remains
outside demonstrated acceptance; do not infer current installation from an old receipt.
