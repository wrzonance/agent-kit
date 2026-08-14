# Security posture

This document records deliberate security decisions that are easy to misread when
they are encountered as isolated flags, filenames, or transport steps. The links
below are the evidence for the design; the document explains the posture rather
than prescribing ways around it.

## Autonomy flags are per-invocation operator grants

`--yolo`, `--fast-mode`, and `--auto-review` are typed by the operator at the
trusted root session for one invocation. They are not standing autonomy. The
flags remove only the specific pauses described by their procedures: for
example, `--yolo` carries the operator's unattended-run grant to verification,
while `--auto-review` permits the one declared cross-provider review flow for
that invocation. Egress consent names the exact payload and destination, and a
changed payload or destination requires a new grant.

Evidence: the [parallel-issues flag contract](../agentkit/skills/parallel-issues/SKILL.md#flags),
the [review-remote-pr flag contract](../agentkit/skills/review-remote-pr/SKILL.md#flags),
and the [autonomy-flags tests](../tests/test-autonomy-flags.sh). The scanner
classes that motivated this standing rationale are recorded in [PR #78's
discussion](https://github.com/wrzonance/agent-kit/pull/78#discussion_r3763041205).

## .agent/config.env is a secrets-free facts file

`.agent/config.env` is a committed repository-facts file. It declares facts such
as repository commands, branch and board values, and label vocabularies. The
resolver parses it line by line, never sources it, and rejects credential-like
keys; the file carries no credentials. A keyword match on `.env` is therefore a
name-substring collision with `config.env`, not a secrets-bearing design.

Evidence: the committed [repository facts file](../.agent/config.env), the
[repository-config design](2026-08-07-agent-repo-config-design.md), and the
[repository-config tests](../tests/test-repo-config.sh). The related scanner
class is recorded in [PR #78's discussion](https://github.com/wrzonance/agent-kit/pull/78#discussion_r3763041205).

## The command trust gate is defense-in-depth, not a human-only guarantee

Terminal approval covers repository command declarations and detects changed
inputs, but it is defense in depth rather than cryptographic proof of a human:
another process running as the same user could imitate the terminal or alter the
trust state. Unattended work uses the explicit, logged `--yolo` path for
trunk-carried command inputs; changed declarations or payloads remain refused.
This boundary lets an authorized unattended worker continue without stalling at
an approval prompt while preserving an auditable, fail-closed check. The
2026-08-11 forged-approval incident is the reason the posture states this limit
explicitly.

Evidence: the [command-trust and fencing design](../agentkit/skills/parallel-issues/references/trust-and-fencing.md),
the [approval-gate tests](../tests/test-agent-run-approval-gate.sh), the
[command-runner tests](../tests/test-agent-run-cmd.sh), and the
[non-blocking guards design](2026-08-08-non-blocking-guards-design.md).

## Untrusted content is fenced and never shell-expanded

Issue and pull-request bodies are data, not instructions to the shell. Issue
content is persisted and fenced with a generated collision-resistant delimiter
before a worker sees it. GitHub bodies are transported through protected files
with `--body-file` or `--input`; they are never interpolated into shell strings.
Any egress sentence names the exact payload and destination before the transfer.

Evidence: the [issue-body boundary tests](../tests/test-issue-body-boundary.sh),
the [issue-fetch and fence tests](../tests/test-issue-fetch-fence.sh), the
[parallel-dispatch contract tests](../tests/test-parallel-dispatch-contract.sh),
and the [GitHub body transport policy](../agentkit/skills/.shared/github-body-policy.md).
