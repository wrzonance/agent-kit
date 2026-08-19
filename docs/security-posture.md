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

`.agent/config.env` is a per-machine, ignored repository-facts file. It declares
facts such as repository commands, branch and board values, and label vocabularies.
The resolver parses it line by line, never sources it, and rejects credential-like
keys; the file carries no credentials. A keyword match on `.env` is therefore a
name-substring collision with `config.env`, not a secrets-bearing design.

Evidence: the [repository-config design](2026-08-07-agent-repo-config-design.md), and the
[repository-config tests](../tests/test-repo-config.sh). The related scanner
class is recorded in [PR #78's discussion](https://github.com/wrzonance/agent-kit/pull/78#discussion_r3763041205).

## The command trust gate is defense-in-depth, not a human-only guarantee

**Removed 2026-08-19.** This gate — a terminal approval before a declared command's first run,
backed by a fingerprinted trust record and an unattended `--yolo` bypass scoped to
trunk-carried inputs — no longer exists. `agent-run.sh --cmd NAME` now runs a declared command
directly, with no approval step and no trust record. The heading above is kept as written
because it is a pinned structural anchor (`tests/test-skills-contract.sh` fails loudly if this
rationale class disappears without a deliberate review); read it as the closed rationale for a
control this project used to run, not a description of current behavior.

The gate was always defense in depth rather than cryptographic proof of a human — another
process running as the same user could imitate the terminal or alter the trust state — and
removing it was a deliberate owner decision for a tool built around one already-trusted
operator: the approval step re-authorized commands for an operator who had already authorized
them by choosing to run agent-kit in the first place. The 2026-08-11 forged-approval incident,
which prompted the original defense-in-depth framing, is historical context for why the gate
existed, not a reason it remains.

Evidence: the [command-runner tests](../tests/test-agent-run-cmd.sh) and the
[verification cache reference](../agentkit/skills/parallel-issues/references/trust-and-fencing.md),
which still documents the one still-live mechanism (the verification result cache) that used to
share this file with the removed gate.

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
