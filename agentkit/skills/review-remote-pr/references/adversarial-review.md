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
- Pitfalls

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

Recommended disclosure wording is explicit about payload, destination, and count: "sending each
PR diff (filenames and code) to the resolved reviewer CLI for exactly one adversarial review;
destination: <resolved reviewer CLI/provider>; count: one review for this PR." Record that exact
payload/destination/count before using the flag; it is not consent for any other data or a second
attempt.

`--auto-review` (alias `--auto-approve`) on the invocation line answers the question above for
this invocation, before it is asked. It is consent from the user in the user's own words, so
treat the gate as satisfied and **do not stop to ask**. Stopping anyway is the specific failure
the flag exists to remove: an unattended run that halts on a question nobody is present to
answer has not been careful, it has just stalled.

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
  external send can read as unauthorized even when it is not. Carry the provenance inline
  at the launch site — the session-ledger `RUN_ID`, the recorded `cross_provider_consent`
  record, and the user's verbatim invocation quote carrying `--auto-review` — **as an
  argument, never a comment**, in the block that launches the reviewer, so "is this send
  authorized?" is answerable from the command itself. Use the no-op-statement idiom, not a
  `#` comment:

  ```sh
  : 'provenance: RUN_ID=<id>; consent=<cross_provider_consent record>; invocation=<verbatim quote>'; \
      "$agentkit/review-remote-pr/scripts/adversarial-run.sh" --pr N --repo OWNER/NAME --run-dir "$RUN_DIR"
  ```

  or pass the provenance directly as data via `--provenance TEXT` on the helper itself, if one is
  declared. Never write the provenance as a `#` comment. In a single-line shell cell, `#` starts a
  comment that runs to end of line — including the launcher after it — so a `# provenance: …;
  adversarial-run.sh …` line is a silent no-op: it exits 0, sends nothing, and produces no
  artifact, while looking exactly like a normal review to a script that only checks the exit code.
  The `: '…'; launcher` form cannot do that: `:` is itself an ordinary (no-op) command, so the
  `;` after its argument still separates two real statements and the launcher always runs. A
  denial that still occurs is surfaced to the user as a direct question, never routed around.
- **A pre-send marker makes a no-op provably distinguishable from a lost receipt, and the
  launcher enforces it itself.** `adversarial-run.sh` writes `$RUN_DIR/state/launch-attempted`
  (timestamp, PR, head SHA, payload id) once every local output-path preparation for the run has
  already succeeded, immediately before the external helper is invoked — so its presence or
  absence answers "did we even try to send this?" independently of whether the send itself
  succeeded, and a purely local abort never leaves one behind. If the marker is absent, nothing
  was sent and an automatic retry is safe with no operator authorization (this is exactly the
  state a swallowed-by-`#` launcher leaves behind). If the marker is present but
  `adversarial.result.json` never reached a `completed` or `blocked` status, the send may have
  happened; `adversarial-run.sh` itself refuses to relaunch into that RUN_DIR — it publishes a
  `blocked` result naming the ambiguous prior attempt and exits nonzero rather than risking a
  second, silent disclosure — so clearing it takes a fresh `--run-dir` or explicit operator
  review, never an automatic retry. A marker next to an already-valid completed or blocked result
  is left to the ordinary findings-ledger / result-clearing flow, unaffected by this guard.
- **Still disclose.** Print the payload, destination provider and CLI, and purpose before the
  first send, exactly as above. The flag removes the question, not the statement of what is
  leaving the machine.
- **Still record.** Write the same record with the origin noted:
  `cross_provider_consent=<provider>;scope=PR-diff;payload=<payload-id>;status=granted;source=auto-review-flag`.
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

Before sending, derive a payload identity from the repository slug, the PR number, and the
SHA-256 hash of the exact diff bytes to be sent. The repository is part of that identity because
PR numbers repeat across repositories: without it, the same number and identical bytes elsewhere
derive the same payload, and a reused record would satisfy `check` for a repository that was
never disclosed. After confirmation, record
`cross_provider_consent=<provider>;scope=PR-diff;payload=<payload-id>;status=granted` in the
active session task state. Reuse that record only for a retry of the exact same payload to the
same provider and scope, so polling or retries do not create repeated prompts. If the destination
provider, PR, or diff changes, obtain confirmation again. If confirmation is missing,
declined, or cannot be recorded, **Do not send the diff**; report the gate as blocked and wait for
user direction rather than silently substituting another external reviewer.

The executable record is the consent boundary, not a replacement for the disclosure and decision.
Use `scripts/consent-record.sh` for disclosure, grant, and check. Every review launcher derives
the payload again from its own repository, PR, and diff arguments and refuses to start without a
successful check against this state record. A missing, malformed, unwritable, mismatched,
symlinked, or empty (or whitespace-only) diff record fails closed -- `payload` refuses to mint an
identity for an empty diff itself, the same emptiness check the launcher already enforces before
it ever calls this helper.

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
| `AGENT_ADVERSARIAL_REVIEWER` | which CLI (`codex` or `claude`) is the reviewer, instead of `peer-cli=` |
| `AGENT_ADVERSARIAL_REVIEW_MODEL` | the model for the declared reviewer |
| `AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK` | the model used if the declared reviewer falls back (below) |
| `AGENT_ADVERSARIAL_REVIEW_EFFORT` | reasoning effort, harness-neutral — applies whichever CLI is used |

`AGENT_ADVERSARIAL_REVIEW_MODEL` and its `_FALLBACK` counterpart are only meaningful paired with a
declared `AGENT_ADVERSARIAL_REVIEWER`: a bare model id has no CLI to be interpreted against, so
either is ignored without it. `AGENT_ADVERSARIAL_REVIEW_EFFORT` applies regardless. The resolver
accepts exactly `low`, `medium`, `high`, `xhigh`, `max` for effort — the same enum the provider
helpers themselves accept (no `ultra`); an unsupported value is refused and named at declaration
time rather than failing at launch.

Availability is only ever a question for the peer slot: only two CLIs exist to declare (`codex`,
`claude`), the running harness is definitionally present, and the contract already probed the peer
once (`peer-cli= ... absent`). So declaring the running harness itself as reviewer is always
honored; declaring the peer when the contract says it is absent does not silently revert to the
peer-CLI default — the runner warns naming the declared CLI and the substitution, then falls back to
the running harness's own CLI using `AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK` when declared, or that
CLI's built-in default model otherwise. `AGENT_ADVERSARIAL_REVIEW_EFFORT`, if declared, still applies
in that fallback. This is the same blind same-harness path used when a peer is simply absent;
declaring a reviewer never bypasses the consent record or changes the provider-token mapping below.

An invalid declaration for any of these four keys is dropped by `repo-config.sh` with a warning
naming the accepted set, and the run proceeds on the peer-CLI default exactly as if nothing had
been declared.

The one-shot blocking entry point is:

    scripts/adversarial-run.sh --pr N --repo OWNER/REPO --run-dir DIR [--peer-cli-absent]

It owns consent enforcement, diff capture, provider selection, schema validation, and atomic
publication of adversarial.diff and adversarial.result.json. Its stdout receipt line is shaped for
post-receipt.sh publish. A provider failure, missing provider, or unparseable verdict is blocked
and is never clean.

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
the adversarial review after fixes.

## Pitfalls

| Problem | Fix |
|---|---|
| Running the adversarial review early or repeatedly | Apply the materiality gate ONCE as the LAST draft step (CI green first). For a material diff, fix confirmed findings and do not re-review the fixes. |
| Skipping review because the diff is short | Size is not risk. Skip only with a deterministic mechanical oracle; runtime, contract, security, persistence, workflow, or accessibility changes are material. |
| Auto-applying adversarial findings | Evaluate first — verify each finding against the actual code, downgrade overstated severities, and drop false positives. Confirmed findings go through Step 5; document outcomes. |
