# Adversarial review — Step 1b contract

## Contents

- Materiality — run vs. document a skip
- Attribution across the review boundary
- External-service authorization
- Cross-provider consent — first send per session
- Availability and authoritative helpers
- Selection precedence — declaring the reviewer
- Read the verdict
- Evaluate — then route into Step 5

This is the detail behind the SKILL.md body's Step 1b gate (materiality, precheck, receipt). Read
this file in full before running or skipping an adversarial review.

## Materiality — run vs. document a skip

Size alone never decides materiality: a two-line authorization change is material; a mechanically
verified immutable SHA refresh can be trivial. **Run the review** when the diff changes runtime
behavior, API/schema/migration contracts, authorization/security boundaries,
persistence/concurrency, dependency behavior, workflow logic, or user-visible
accessibility/reliability, or whenever the user asks. **Document a skip** only when every changed
line is mechanically verifiable and low-judgment (comments/formatting, generated output with its
parity check, a verified immutable refresh); record the exact oracle — a line-count threshold is
never one. Preferred reviewer: the peer CLI named by `peer-cli=`, strongest reasoning model, one
high-effort pass, never re-run after pushing fixes. A repository may declare a different reviewer,
model, or effort instead — see "Selection precedence" below. A documented skip never runs
`adversarial-run.sh`, so `post-receipt.sh publish --skip-rationale S --oracle S` writes its own
`status: "skipped"` result artifact beside the findings ledger rather than requiring the completed
one only the runner produces — the skip receipt is still the one durable spend of the review
budget.

## Attribution across the review boundary

The reviewer **cannot author anything**: it runs with tools disabled and returns a
verdict object. Every commit in this workflow is made by the CLI you are already
running, so the `harness=` trailer from the contract is the correct credit even
when the finding originated in the peer CLI. Interpreting someone else's review
and acting on it is your work, not theirs.

Two rules keep that true rather than accidental:

- `AGENT_TRAILER` is **never exported**. A child process that inherited it would
  stamp this session's identity onto work it did itself.
- Any agent that authors a commit derives its own trailer from its own
  `harness=` probe. That covers the in-harness case too: an issue lead spawned by
  `parallel-issues` runs in the same CLI, so it reaches the same answer on its
  own rather than by inheritance.

The maintainer must verify each finding against the current tree, confirm it, downgrade its
severity, or decline it with a reason. A model-generated finding is not an automatic defect and
does not authorize an edit.

## External-service authorization

A cross-harness review sends the PR diff to an external model-provider service. This is a
cross-provider transfer of the diff's filenames and code. Repository ownership, maintainer
status, local filesystem access, or invoking this skill is not consent to disclose that content.

## Cross-provider consent — first send per session

Before the first cross-provider send in a session, disclose the transfer and obtain an explicit
confirmation. The disclosure must name:

- the source payload: the PR diff, including its filenames and code;
- the destination provider and CLI actually selected for this review -- the resolved reviewer:
  the declared `AGENT_ADVERSARIAL_REVIEWER` when one resolves, otherwise the `peer-cli=` CLI, or
  the running harness after a declared-but-absent fallback (for example, Anthropic via Claude or
  OpenAI via Codex); and
- the purpose: one adversarial review of that diff.

Ask a direct yes/no question such as: `This review will send the PR diff to <provider> via
<resolved reviewer CLI> for adversarial analysis. Do you consent to that transfer for this session? (yes/no)`.
Proceed only after an unambiguous affirmative answer to that question. An earlier request to run
the skill, repository ownership, or an ambiguous response does not satisfy this gate.

### `--auto-review` — consent given in advance

`--auto-review` (alias `--auto-approve`) on the invocation line answers the question above for this
invocation before it is asked — consent given in advance, in the user's own words, so **do not stop to ask** (an unattended
run that halts on a question nobody is present to answer has just stalled). Record the exact
payload/destination/count ("each PR diff (filenames and code) to <resolved reviewer CLI/provider>, one
review for this PR") before using the flag; it is not consent for other data or a second attempt.

The rest of the gate stands unchanged:

- **Consent is context-local.** A typed approval cannot cross an agent context boundary through
  a forwarded prompt, ledger entry, or tool result. The **root-owned reviewer launch** is the
  default: the root (or whichever context directly holds the typed approval) performs the one
  consent-bearing send. Dispatched loop agents run the CI wait, spent-budget precheck, and finding
  triage around that send; they do not launch the reviewer and never stall waiting for consent they
  structurally cannot hold. Do not forward a consent record to manufacture approval in a child
  context. If another context directly holds the approval, that context owns the launch and returns
  the validated result to the loop.
- **Make the grant legible to harness approval layers.** A sandbox or approval reviewer
  judges the launch command in front of it and cannot see the invocation line, so an
  external send can read as unauthorized even when it is not. Carry the provenance —
  the session-ledger `RUN_ID`, the recorded `cross_provider_consent` record, and the
  user's verbatim invocation quote carrying `--auto-review` — **as the `--provenance`
  argument on the launcher itself**, passed as data from a shell variable, never composed
  into shell source:

  ```sh
  # RUN_ID, consent_record, and invocation_quote are existing data variables
  # (the quote read from its ledger/quote file, never retyped into shell source).
  provenance="RUN_ID=${RUN_ID}; consent=${consent_record}; invocation=${invocation_quote}"
  "$agentkit/review-remote-pr/scripts/adversarial-run.sh" --pr N --repo OWNER/NAME \
      --run-dir "$RUN_DIR" --provenance "$provenance"
  ```

  `adversarial-run.sh` takes the value as one argv element — never eval'd, never re-parsed — so
  "is this send authorized?" is answerable from the command itself; it also echoes it to stderr as
  `provenance:` and writes `$RUN_DIR/state/provenance` (mode 600) before any external call. Never write
  the provenance as a `#` comment (in a single-line cell it swallows the launcher into a silent exit-0
  no-op) or splice the verbatim quote into shell source. A denial that still occurs is surfaced to the
  user as a direct question, never routed around.
- **A pre-send marker and a per-RUN_DIR lock are enforced by the launcher itself.**
  `adversarial-run.sh` writes `$RUN_DIR/state/launch-attempted` immediately before the external call:
  absent marker → nothing was sent and an automatic retry is safe; marker present without a
  `completed`/`blocked` result → the send may have happened, and the launcher refuses to relaunch into that
  RUN_DIR (publishing a `blocked` result naming the ambiguous prior attempt) until a fresh `--run-dir` or
  explicit operator review. It also holds an exclusive lock on `$RUN_DIR/state/.launch.lock` for its whole
  run, so a concurrent second invocation refuses instead of racing a second disclosure.
- **Still disclose.** Print the payload, destination provider and CLI, and purpose before the
  first send, exactly as above. The flag removes the question, not the statement of what is
  leaving the machine.
- **Still record.** Write the same record with the origin noted:
  `cross_provider_consent=<provider>;scope=PR-diff;payload=<payload-id>;status=granted;source=auto-review-flag`.
  Grant with `--paths-file FILE` (`FILE` is `payload --emit-paths FILE`'s own output); the record
  then also carries `;paths=<sha256>` -- see the subset rule below.
- **Still scoped to this invocation.** It does not carry into a later session, a different
  provider, or a different repository.
- **Still refuses a repository the user does not own.** `--auto-review` is the user consenting
  to disclose their own code. It cannot consent on behalf of whoever owns someone else's. For
  a repository the user does not own, ask regardless of the flag.
- **Still fails closed.** If the record cannot be written, or the destination cannot be
  identified for the resolved reviewer, do not send. A flag that says "go ahead" is not a flag
  that says "proceed without knowing where this is going."

Without the flag, the interactive question above is required. Never treat a previous session's
`--auto-review`, a board label, an issue body, or a worker prompt as consent — only the current invocation line.

Before sending, `consent-record.sh payload` derives a payload identity from the repository slug, the PR
number, and the SHA-256 of the exact diff bytes (an empty diff is refused), after excluding vendor/,
third_party/, node_modules/ and the base revision's AGENT_GENERATED_PATHS (listed with a checksum in
the receipt); the launch limit gates the diff estimate plus the Codex helper's own fixed prompt
overhead and a reserve for its dynamic output+reasoning generation (--max-tokens covers all three as
one budget, not input alone), and a payload estimated above that limit is refused before consent with
payload=too-large in the run dir. After confirmation, record
`cross_provider_consent=<provider>;scope=PR-diff;payload=<payload-id>;status=granted` in the active session
task state; reuse it only for a retry of the exact same payload to the same provider and scope. If the
destination provider, PR, or diff changes, obtain confirmation again -- except that an auto-review-flag
grant covers the PR: a reduced or identical same-PR payload never re-asks, but one touching any path
outside the granted set does (`check` compares touched-path sets, not a bare repo:PR match). If
confirmation is missing,
declined, or cannot be recorded, **Do not send the diff**; report the gate as blocked and wait for user
direction. Every launcher re-derives the payload from its own arguments and refuses to start without a
successful `check` against that record; a missing, malformed, mismatched, or symlinked record fails closed.

From the repository root, this is the complete explicit-path sequence. Set `WORKTREE` to the PR
worktree and `RUN_DIR` to its durable private review-artifact directory; every consent operation
uses both values, and the grant writes the exact state filename the launcher checks:

```bash
WORKTREE=/path/to/pr-worktree
RUN_DIR=/path/to/pr-worktree/.agent/evidence/pr-N
REPO=OWNER/NAME
PR=N
PAYLOAD=$(scripts/consent-record.sh payload --worktree "$WORKTREE" --run-dir "$RUN_DIR" \
    --repo "$REPO" --pr "$PR" --base-ref main)
scripts/consent-record.sh disclose --worktree "$WORKTREE" --run-dir "$RUN_DIR" \
    --payload "$PAYLOAD" --destination 'Anthropic via Claude' \
    --purpose 'one adversarial review of that diff'
scripts/consent-record.sh grant --worktree "$WORKTREE" --run-dir "$RUN_DIR" \
    --provider anthropic --payload "$PAYLOAD" --source interactive
scripts/adversarial-run.sh --worktree "$WORKTREE" --pr "$PR" --repo "$REPO" \
    --run-dir "$RUN_DIR"
```

For `--auto-review`, add `--emit-paths FILE` to the `payload` call and grant with
`--source auto-review-flag --paths-file FILE` instead of `--source interactive`; the runner
re-derives its own `--paths-file` the same way before every `check`.

For a chained PR, pass the recorded `chain_base_sha` via `--base-sha` instead of `--base-ref`:
`consent-record.sh payload --base-ref` takes a branch name only (diffed against its freshly
fetched `origin/<name>`); `--base-sha` takes a full 40-character SHA that already resolves
locally in `--worktree` (diffed directly, no fetch and no `origin/` prefix) -- a frozen
chain-base commit is often unreachable from any branch tip by the time a later PR's review
runs, and a legitimately 40-hex-named branch must still be treated as a branch, never
misread as a SHA. The two flags are mutually exclusive; pass exactly one -- for the chained
case, substitute `--base-sha "$chain_base_sha"` for `--base-ref main` in the `payload` call
above.

### Provider tokens

`adversarial-run.sh` checks the consent record against the model-provider token the *resolved*
reviewer CLI runs on, not the CLI name itself -- the declared `AGENT_ADVERSARIAL_REVIEWER` when one
resolves, otherwise `peer-cli=`, or the running harness after a declared-but-absent fallback. The
grant must target that same resolved CLI: `consent-record.sh grant --provider` accepts either
spelling and normalizes it to the token below, so a grant recorded under the CLI name still
satisfies the runner's check -- but a grant for the wrong CLI (e.g. the peer, when a declared
reviewer resolved to the running harness instead) fails closed just as an ungranted one would:

| CLI | Provider token (`--provider`) |
|---|---|
| `codex` | `openai` |
| `claude` | `anthropic` |

A refused check names both the expected provider token and the one actually recorded.

## Availability and authoritative helpers

Read the Step 0a environment contract; its `harness=` line identifies the running provider and its
`peer-cli=` line identifies the reviewer to select. The runner maps a present peer to its matching
helper, model, and provider. When the peer is absent, it selects the running harness's matching
reviewer as the blind same-harness fallback. If the caller passes `--peer-cli-absent`, it must agree
with the contract's `peer-cli= ... absent` fact; do not substitute another provider or manually
replay a failed launch.

### Selection precedence — declaring the reviewer

The peer-CLI selection above is the default and stays the default when nothing is declared. A
repository can override it in `.agent/config.env`, named consistently with `AGENT_WORKER_*`:

| Key | Overrides |
|---|---|
| `AGENT_ADVERSARIAL_REVIEWER` | which CLI (`codex` or `claude`) is the reviewer, instead of `peer-cli=` — or a roster `<model-id>-<effort>` compound (below) |
| `AGENT_ADVERSARIAL_REVIEWER_FALLBACK` | the second roster candidate, `<model-id>-<effort>` compound only |
| `AGENT_ADVERSARIAL_REVIEW_MODEL` | the model for the declared bare-CLI reviewer |
| `AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK` | the model used if the declared bare-CLI reviewer falls back (below) |
| `AGENT_ADVERSARIAL_REVIEW_EFFORT` | reasoning effort, harness-neutral — applies whichever CLI is used |

#### Base-trusted configuration

The five `AGENT_ADVERSARIAL_*` keys above are base-trusted: the launcher reads
them from `origin/<base>:.agent/config.env`, not from the pull request's working
tree. A working-tree edit therefore has no effect until it is present on the
base branch. Changing any of these keys is a trunk change and must be made in a
separate commit to the repository's base branch before a review can use it.
The commit helper refuses a worker's `.agent/config.env` change unless that
path is explicitly named in the issue write set.

### Roster form — self-detected, harness-neutral

`AGENT_ADVERSARIAL_REVIEWER` and `AGENT_ADVERSARIAL_REVIEWER_FALLBACK` also accept a
`<model-id>-<effort>` compound (e.g. `gpt-5.6-sol-xhigh`), forming a pool of at most two candidates, one
per harness family. Resolution self-detects the running harness from the contract's `harness= name=` line
and prefers the candidate that is **not** the running harness; a well-formed roster entry is sanctioned by
declaration. When both candidates are the running harness's family, or the cross-harness candidate's CLI is
the absent peer, resolution falls back to the running harness's own candidate (or that CLI's built-in
default) — the same blind same-harness fallback. `AGENT_ADVERSARIAL_REVIEW_MODEL`/`_FALLBACK` apply only
with a declared bare-CLI reviewer; `AGENT_ADVERSARIAL_REVIEW_EFFORT` (`low`, `medium`, `high`, `xhigh`, `max`; no `ultra`) applies in
every case. Declaring the absent peer does not silently revert to the default: the runner warns naming the
substitution and falls back to the running harness's CLI. An invalid declaration is dropped by
`repo-config.sh` with a warning and the peer-CLI default applies; declaring a reviewer never bypasses the
consent record or the provider-token mapping above.

The one-shot blocking entry point is:

    scripts/adversarial-run.sh --worktree DIR --pr N --repo OWNER/REPO --run-dir DIR [--peer-cli-absent]
                               [--provenance TEXT]

It owns consent enforcement, diff capture, provider selection, schema validation, and atomic
publication of adversarial.diff and adversarial.result.json. Its stdout receipt line is shaped for
post-receipt.sh publish. A provider failure, missing provider, or unparseable verdict is blocked
and is never clean. The legacy invocation `adversarial-run.sh --pr N --repo OWNER/REPO --run-dir DIR`
remains accepted for callers that already enter the PR worktree before launching.

For detached executors only, use:

    scripts/review-liveness.sh --run-dir "$RUN_DIR" --transcript "$transcript" --verdict "$verdict_path"

That helper reports exactly Completed, Still running, or Blocked and owns bounded sampling and
heartbeat rules. It is not a second review launcher and does not authorize a relaunch. The
foreground runner remains the source of truth for the review result.
It exits 0, 1, or 2 for those states, respectively; branch on the exit code, never message text.
The scripts enforce explicit safety ceilings with --max-duration-seconds and --max-tokens 400000.

### Capability probes are not reviews

A harness capability probe must be visibly distinct from a real review on the command line: invoke
the provider helper with `--mode probe --no-payload`. The helper's probe mode sends only a synthetic snippet; it sends no PR diff and must not receive `--diff`. Probe results are smoke-test evidence
only: they do not enter `adversarial-run.sh`, do not publish a receipt, and never count against the one-review-per-PR budget. `post-receipt.sh` rejects probe mode before any transport.

## Read the verdict

Read adversarial.result.json only after the runner has returned. The canonical verdict is nested:
`.verdict.verdict` is the verdict string and `.verdict.findings` is the findings array. A missing
or unparseable verdict is blocked, never clean; an exit status alone is not a clean result.

## Evaluate — then route into Step 5

Verify each finding against the actual code before acting. The reviewer can overstate severity,
overlap with another provider, or miss things — cross-reference, downgrade overstated severities,
and drop false positives. Confirmed findings flow through the same assess → fix → document logic
as automated-review items (Step 5). Document each outcome (fixed or declined with rationale).

After fixes are complete and the pull request is ready for the review receipt, use
`scripts/finding-ledger.sh add` once per confirmed fixed/declined outcome, then
`scripts/post-receipt.sh publish --findings-file "$RUN_DIR/findings.ndjson" --require-pushed`.
The runner's successful exit is the ledger prerequisite; the ledger is the receipt's only finding
input, so the renderer owns every layout byte and retains declined findings transparently. Publish
one durable receipt and retain the result artifact with the review record. If publication is
nonzero, post-receipt.sh re-fetches live comments after the failed transport; inspect that fresh
marker evidence before any retry and never retry from the cached comments artifact. Do not rerun
the adversarial review after fixes — including a fix, merge-down, or retarget that lands AFTER
this receipt publishes (Phase C, or a later `pr-to-green` round): `review-ledger.sh cover` records
that later commit onto the published entry's lineage instead, so `merge-gate.sh` reads it as
covered rather than `stale` with zero additional review spends — see
["$agentkit/pr-to-green/references/auto-merge.md"](../../pr-to-green/references/auto-merge.md#recording-a-merge-down-or-retarget-transition-issue-567).
