# activation-ordering probe

`bench/activation-ordering.sh` asks a harness to echo, as its first and only
tool call, the `nonce` from the workflow-activation receipt delivered in its
`UserPromptSubmit` context. It then compares that call against
`.agent/activation/<sha256(session)>.json`. The result answers: does hook
context reach the model before its first tool call?

## Results

- **codex** (codex-cli 0.155.1), 2026-09-23: `ORDER=context-before-first-call
  harness=codex`. Plugin used: the user's locally installed
  `~/.codex/plugins/cache/agent-kit/agentkit/0.9.13` (no `--plugin-dir`
  equivalent on Codex; the installed cache is what Codex loads). The nonce
  appeared as a `printf` argument in the model's first attempted command
  even though a PreToolUse hook then blocked that command pending session
  acknowledgement — proof the context, including the nonce, was already in
  the model's hands at its first tool call.
- **claude** (Claude Code 2.1.280), 2026-09-23: `ORDER=context-before-first-call
  harness=claude`. Plugin loaded via `--plugin-dir` from
  `plugin/agentkit` at `b9db1ed` (the built tree, `tests/build-plugin.sh`,
  never the user's installed `agentkit@agent-kit` plugin, which is disabled
  at 0.8.1 on this machine and was the root cause of the earlier
  `no-delivery` run). Run via `claude -p --allowedTools='Bash(printf:*)'
  --plugin-dir <path-to-plugin/agentkit>` (a precise allow list for the
  probe's one command, never a permission bypass). The receipt written at
  `.agent/activation/<sha256(session)>.json` has `skillsRoot` pointing at
  `plugin/agentkit/skills` and `nonce` `282b0f7d...`, which matches
  the model's sole tool call byte-for-byte:
  `printf "PROBE_NONCE=%s\n" 282b0f7def57c884547f519693ca5fd401777aaf92640965`.
  No distinct `UserPromptSubmit` line appears among the transcript's
  `system` hook events (only `SessionStart` does) — Claude Code folds that
  delivery into context rather than logging it as a separate hook-event
  transcript entry — but the receipt file and the matched nonce are direct
  proof the hook ran and its context reached the model before its first
  tool call.
