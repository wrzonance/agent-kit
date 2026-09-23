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
- **claude** (Claude Code 2.1.280): blocked in this sandbox before a
  same-condition run completed — see task-0-report.md for detail and the
  operator decision needed to unblock it.
