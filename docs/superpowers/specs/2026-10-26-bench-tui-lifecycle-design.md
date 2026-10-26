# Reliable interactive benchmark lifecycle

Issue: #1017. The operator approved implementing its startup and shutdown acceptance criteria.

## Intent and scope

An unattended interactive trial must submit one invocation, confirm an agent turn starts,
and save its score when the CLI exits. Remove the observed manual Enter and the lost score
after four completed fixture issues. Keep the CLI interactive, the pinned kit, models,
permissions, fixture, scoring contract, and Claude arm intact. Do not run the A/B batch here.

## Approaches

- Send text and Enter separately: less change, but still depends on composer timing and
  makes retries ambiguous.
- Use the documented initial prompt argument: selected by the implementer. Both installed
  CLIs and their official references support it. Submit once, then observe a durable turn
  signal; no blind retry of text or Enter.

References: https://learn.chatgpt.com/docs/cli/reference and
https://code.claude.com/docs/en/cli-reference (checked 2026-10-26).

## Contracts

- Startup reads only the trial's root transcript: Codex `session_meta` must match the clone
  cwd and have no parent, followed by `task_started`; Claude must record an assistant response
  for that cwd. A prompt on screen, metadata alone, or a child transcript is insufficient.
- Keep trust-dialog handling, a bounded startup deadline, and a saved pane diagnostic on
  failure. A missing CLI or absent turn fails before receipt polling. Never resend invocation.
- Pin the discovered root for scoring rather than selecting the newest child rollout.
- Cleanup accepts an already absent session and disappearance after the first interrupt.
  Unexpected cleanup errors remain visible, make the trial fail, and still allow scoring.
- If the CLI disappears before all receipts, persist a failed trial; do not declare success.
- The draft PR is stacked on `feat/ak-wave-wait`, where the runner currently lives.

## Verification

Regression tests exercise the runner with external CLI/tmux/GitHub doubles. Cover both
harnesses, metadata-only and child-only startup, missing panes, unexpected cleanup failure,
premature exit, and persisted root/outcome selection. Run static gates, the canonical suite
with bounded concurrency, and one real unattended Codex smoke. Preserve its evidence.
