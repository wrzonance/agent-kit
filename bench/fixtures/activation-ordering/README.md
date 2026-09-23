# activation-ordering probe

`bench/activation-ordering.sh` asks a harness to echo, as its first and only
tool call, the `nonce` from the workflow-activation receipt delivered in its
`UserPromptSubmit` context. It then compares that call against
`.agent/activation/<sha256(session)>.json`. The result answers: does hook
context reach the model before its first tool call?

## Results

- **codex** (codex-cli 0.155.1), 2026-09-23: `ORDER=context-before-first-call
  harness=codex`. The nonce appeared as a `printf` argument in the model's
  first attempted command even though a PreToolUse hook then blocked that
  command pending session acknowledgement — proof the context, including the
  nonce, was already in the model's hands at its first tool call.
- **claude** (Claude Code 2.1.280), 2026-09-23: `ORDER=no-delivery
  receipt-missing=.../.agent/activation/<sha256>.json`. Run via
  `claude -p --allowedTools='Bash(printf:*)'` (a precise allow list for the
  probe's one command, never a permission bypass) against the same
  throwaway clone. No `UserPromptSubmit` hook fired at all in this
  invocation (only `SessionStart` hooks appear in the transcript), so the
  model correctly reported no receipt/nonce in its context and printed
  `PROBE_NONCE=none`. On the kit's pre-change gate, the probe's first
  `printf` is expected to be denied as "pending session acknowledgement,"
  and the probe reads the composed command from that block notice rather
  than requiring it to execute; that path wasn't exercised here because
  delivery itself didn't happen. Task 4 re-runs this probe after the
  activation-gate change lands.
