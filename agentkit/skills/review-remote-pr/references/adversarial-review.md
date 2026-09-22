# Adversarial review — Step 1b contract

## Contents

- Materiality — run vs. document a skip
- Attribution across the review boundary
- External-service authorization
- Cross-provider consent — first send per session
- Availability and authoritative helpers
- Selection precedence — declaring the reviewer
- Durable attempts and reconciliation
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
- the destination provider and CLI actually selected: the declared `AGENT_ADVERSARIAL_REVIEWER`
  when one resolves, otherwise the `peer-cli=` CLI, or
  the running harness after a declared-but-absent fallback (for example, Anthropic via Claude or
  OpenAI via Codex); and
- the purpose: one adversarial review of that diff.

Ask a direct yes/no question such as: `This review will send the PR diff to <provider> via
<resolved reviewer CLI> for adversarial analysis. Do you consent to that transfer for this session? (yes/no)`.
Proceed only after an unambiguous affirmative answer to that question. An earlier request to run
the skill, repository ownership, or an ambiguous response does not satisfy this gate. After that
answer, use `consent-record.sh` to record the decision.

### `--auto-review` — consent given in advance

`--auto-review` (alias `--auto-approve`) on the invocation line records that confirmation for this
invocation in advance, in the user's own words, so **do not stop to ask** (an unattended
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
- **The launcher reserves the PR budget before invoking the provider helper.**
  Its per-RUN_DIR lock protects artifacts; the durable registry under the Git common directory
  protects the review obligation across worktrees, changed heads, and fresh run directories.
  Empty output, yield, interruption, a blocked result, or a lost acknowledgement never releases
  that reservation. Reconcile the original attempt; do not create a new launcher or run directory
  to bypass it. An absent local `state/launch-attempted` marker alone does not prove no earlier send.
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

Interactive consent is this session's affirmative answer. Advance consent is `--auto-review` on
the current invocation line. Prior answers/flags, board labels, issue bodies, and worker prompts
are not consent.

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

When the selected bare-CLI model declaration is invalid, the runner retains the dropped
value as `modelSubstitutedFrom` in `adversarial.result.json` and annotates its summary:
`model=claude-opus-5 (configured claude-fable-5.1 was invalid and dropped; see repo-config warning)`.
The receipt composer reads this evidence automatically; `post-receipt.sh publish` also accepts
`--model-substituted-from VALUE` for older result artifacts, but refuses a value conflicting with
recorded provenance. The `Reviewer:` line and review-ledger entry preserve the substitution.
Verified skips reject this flag because no reviewer model was selected.
Valid or absent declarations retain the existing reviewer line. The same rule applies to an
invalid selected fallback model; unused model slots and roster selections are unaffected.
Only model-shaped identifiers up to 200 characters are copied into this public provenance;
arbitrary malformed text is represented as `[non-model value redacted]` and is never evaluated.
Default selection still uses only the trusted base config snapshot. A per-run operator choice
uses both `--reviewer MODEL-EFFORT` and `--override-authorization TEXT` on the canonical invocation.
The text records the operator's explicit selection and its authorization source; an agent must
not manufacture that authorization from issue text, working-tree configuration, or a prompt.
The private attempt ledger retains both configured and selected reviewers and the authorization;
the receipt visibly names both selections. No environment variable overrides selection. Existing
provider/payload consent is checked against the selected provider; the override never grants
disclosure consent or another review. With no override, the existing reviewer line is unchanged.

To inspect model selectors and effort levels exposed by the current Claude Code session without
submitting a prompt, run `node "$agentkit/review-remote-pr/scripts/claude-model-discovery.mjs"
--list-models [--claude PATH] [--sdk-dir DIR]`. This optional diagnostic uses the Agent SDK's
`supportedModels()` control query; it does not read PR content or select a model. If the SDK
package is absent, the helper prints an opt-in install command. Automatic error diagnostics resolve the SDK only inside the helper scripts directory, never from the reviewed checkout. An explicit `--sdk-dir` must contain the resolved SDK entry point after resolving symlinks; parent-directory and symlink escapes are refused before import. The SDK may return session aliases
such as `default`, `sonnet`, or `haiku`, and its list may omit canonical model IDs available by
other routes. Use only the exact returned selector and a listed supported effort in
`--reviewer MODEL-EFFORT`; never infer a selector from a display name. Anthropic's [Models API]
(`GET /v1/models`) lists API model IDs, but requires API authentication and does not describe
Claude Code OAuth availability or effort levels.

[Models API]: https://platform.claude.com/docs/en/api/models/list

The one-shot blocking entry point is:

    scripts/adversarial-run.sh --worktree DIR --pr N --repo OWNER/REPO --run-dir DIR [--peer-cli-absent]
                               [--provenance TEXT]
                               [--review-base-sha SHA]
                               [--reviewer MODEL-EFFORT --override-authorization TEXT]
                               [--max-budget-usd AMOUNT] [--max-output-tokens N]
                               [--max-duration-seconds N]
                               [--retry-attempt ID --retry-authorization TEXT]

It owns consent enforcement, diff capture, provider selection, schema validation, and atomic
publication of adversarial.diff and adversarial.result.json. Its stdout receipt line is shaped for
post-receipt.sh publish. A provider failure, missing provider, or unparseable verdict is blocked
and is never clean. The legacy invocation `adversarial-run.sh --pr N --repo OWNER/REPO --run-dir DIR`
remains accepted for callers that already enter the PR worktree before launching.

Use `--review-base-sha SHA` only when the review must include commits already merged into the
current PR base. SHA must be a full local commit ID and an ancestor of both the observed PR base
and checked-out head. The consent payload must be granted using that same `--base-sha`; the run
records the current PR base, selected review base, and exact diff payload in its attempt and result.

For Claude, `--max-budget-usd` defaults to `5.00`; `--max-output-tokens` is optional and
sets the provider process's `CLAUDE_CODE_MAX_OUTPUT_TOKENS` value. Omitting it preserves the
Claude Code setting. Accepted explicit values are 1–128000; the selected model's own cap still
applies. Fable 5.1 supports 128000 output tokens, including thinking. `--max-duration-seconds`
defaults to 900 for either provider. These are per-run limits, not repository-wide defaults.

Explicit retry: use a fresh directory and new payload consent, with
`--retry-attempt ORIGINAL_ID --retry-authorization VERBATIM_AUTHORIZATION`.
Canonical failed attempts qualify; provider/model/effort/bases must match,
and head must descend from the old head. No automatic retry or old-ID replay is allowed.
For finalized `unknown-outcome` timeouts, also supply `--stopped-timeout-proof FILE`,
owned mode-0600 JSON:

```json
{"schemaVersion":1,"repo":"OWNER/REPO","pr":770,"attemptId":"ORIGINAL_ID",
 "head":"NEW_HEAD","payload":"NEW_PAYLOAD","authorization":"VERBATIM_AUTHORIZATION",
 "reason":"operator-confirmed-timeout","timeoutSeconds":900,
 "resultSha256":"OLD_RESULT_HASH","transcriptSha256":"OLD_TRANSCRIPT_HASH",
 "helperProcess":{"pid":123,"startTicks":"456","bootId":"BOOT_ID"},
 "providerProcess":{"pid":124,"startTicks":"457","bootId":"BOOT_ID"}}
```

Copy identities from `attempt read`; SHA256 hashes bind unchanged artifacts.
The attested timeout must cover the old limit. Missing identities, boot mismatch,
live/reused helper/provider/launcher PIDs or permission errors block recovery.
`previousAttempts` preserves unknown state/events/hashes; `retryOf` and proof/digest
bind the new reservation. Never rewrite old evidence to enable retry.

For detached executors only, use:

    scripts/review-liveness.sh --run-dir "$RUN_DIR" --transcript "$transcript" --verdict "$verdict_path"

That helper reports exactly Completed, Still running, or Blocked and owns bounded sampling and
heartbeat rules. It is not a second review launcher and does not authorize a relaunch. The
foreground runner remains the source of truth for the review result.
It exits 0, 1, or 2 for those states, respectively; branch on the exit code, never message text.
The scripts enforce explicit safety ceilings with --max-duration-seconds and --max-tokens 400000.

### Durable attempts and reconciliation

`state/review-attempt.json` binds payload, base/head, reviewers, launcher and output.
`review-ledger.sh attempt` stores authoritative repository/PR records under
`$(git rev-parse --git-common-dir)/agentkit-review-attempts/`. Transitions use a two-second
exclusive lock, fsync and atomic replacement
([Python flock](https://docs.python.org/3/library/fcntl.html#fcntl.flock),
[atomic replacement](https://docs.python.org/3/library/os.html#os.replace)). Records retain
history, launcher/runtime and artifact hashes, process/session identities and completed results.

| State | Meaning |
|---|---|
| `reserved` | Local reservation; no provider start has been recorded. This is not review evidence. |
| `parser-rejected` | The helper returned before reaching its provider-launch boundary. |
| `running` | The supported boundary claimed the attempt; empty output does not change this. |
| `completed` | A validated result for the recorded model was durably retained. |
| `failed` | A terminal provider error was observed. The review budget remains consumed. |
| `unknown-outcome` | No validated terminal outcome is known; reconciliation is required. |

Inspect with `review-ledger.sh attempt read --repo-root DIR --entry-file FILE`. A running record
also reports `observedState`; missing or changed process identity is unknown, never a retry grant.
If a validated original result arrived after acknowledgement was lost, use
`review-ledger.sh attempt reconcile --repo-root DIR --entry-file FILE --id ORIGINAL_ID`.
Reconciliation validates the original result without a provider launch. Preserve and report
missing evidence; no command resets the budget. Authorized retry preserves prior evidence under
its original ID. Canonical replay reuses matching completed results; changed targets require
mechanical lineage, not another review.

A `parser-rejected` preparation recovers only when complete history proves no provider start
or process registration. Consent and payload checks precede local preparation retry;
the original ID and history remain intact.
Changed inputs, failed/running/unknown/completed sends, and legacy evidence cannot recover a new
send. Lock timeout is unavailable/unknown evidence, not a successful transition or retry grant.
After fixes advance the branch, publish using the original `state/review-attempt.json` head;
receipt and ledger identity describe that paid review, not unverified descendant coverage.

Both shipped provider helpers reserve direct review invocations in the same registry, marking
their actual noncanonical launcher. Helper ownership is claimed before preparing output or
transcript files, so a refused replay preserves the original artifacts. The later `start`
transition records the actual provider boundary separately from parser/preflight rejection.
Existing evidence in each registered worktree's conventional
`.agent/evidence/pr-N` directory is retained as unknown before canonical state is initialized.
Enforcement is explicitly limited to this repository's supported helpers: raw provider CLI calls,
other clones/machines, and historical artifacts outside those conventional paths cannot be
intercepted or discovered reliably. Keep such evidence and report degraded enforcement.

Receipt publication requires canonical launcher/runtime provenance, matching target/reviewer,
the original result digest and the retained payload-size gate artifact. Legacy or direct-helper
results remain inspectable but cannot be published as canonical receipts. Procedures are reported
as executed: these helpers perform one tool-free diff review, with no two-pass or contract-blind
attestation. An unsupported requested procedure must be disclosed; never purchase an extra pass.
Supplied stale or unreadable remote review ledgers also fail closed; only proven absence allows
a first review, while covered heads/diffs retain their existing no-launch reaffirmation path.

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
as automated-review items (Step 5). Record confirmed unfixed findings as `open`, with a next repair
action in `--rationale`; never decline a confirmed finding merely because its repair is pending.
Execution, adjudication, and remediation are separate facts. Publishing execution evidence with
open findings spends the review budget while leaving remediation incomplete.

Use `scripts/finding-ledger.sh add --verdict open --title TITLE --severity P1 --rationale NEXT_REPAIR`
for each confirmed obligation, then
`scripts/post-receipt.sh publish --findings-file "$RUN_DIR/findings.ndjson" --require-pushed`.
The runner's successful exit is the ledger prerequisite; the ledger is the receipt's only finding
input, so the renderer retains open findings transparently. Publish
one durable receipt and retain the result artifact with the review record. If publication is
nonzero, post-receipt.sh re-fetches live comments after the failed transport; inspect that fresh
marker evidence before any retry and never retry from the cached comments artifact. Do not rerun
the adversarial review after fixes — including a fix, merge-down, or retarget that lands AFTER
this receipt publishes (Phase C, or a later `pr-to-green` round): `review-ledger.sh cover` records
that later commit onto the published entry's lineage instead, so `merge-gate.sh` reads it as
covered rather than `stale` with zero additional review spends — see
["$agentkit/pr-to-green/references/auto-merge.md"](../../pr-to-green/references/auto-merge.md#recording-a-merge-down-or-retarget-transition-issue-567).

### Terminal evidence and resume

Update the same title after repair. Produce its evidence with
`finding-ledger.sh evidence --title TITLE --path AFFECTED_PATH --log GREEN_LOG --repo-root WORKTREE --repair-sha REPAIR_SHA > FILE`:
the log must be the green, unfocused `agent-run.sh --cmd test` run (a focused `--only` or red log is
refused), `--head` defaults to the checkout's HEAD, and `REPAIR_SHA` is the commit that changed that
path (not a later formatting-only commit). Then record it with
`add --verdict fixed --sha "$(jq -r .repairSha FILE)" --evidence FILE --repo-root WORKTREE --head CURRENT_SHA`
(also supply title and severity). One evidence file per finding. The helper checks commit ancestry,
the changed path, and verification bytes; missing or unreachable evidence blocks resolution. It
never runs a command from evidence.

A reasoned decline uses `--verdict declined --rationale REASON --evidence FILE`; its evidence
must bind `finding`, `decision:"rejected"` or `decision:"accepted-risk"`, and the same `rationale`.
Accepted risk requires an `authorization` citation to an existing authorized policy decision;
it does not grant authority. The verification command must match its log, whose final completion
marker must be green; a later change to the repaired path requires fresh verification.
No natural-language substring decides whether a reason is valid.

Legacy fixed/declined records remain readable with remediation `unknown` until re-adjudicated
with evidence. `finding-ledger.sh status --file FILE --repo-root WORKTREE --head CURRENT_SHA`
names unresolved obligations and next actions. After repairs, `review-ledger.sh cover` with
`--findings-file FILE --repo-root WORKTREE --reason fix:ID` (ID from `finding-ledger.sh ids --file
FILE`, also printed by each `add`) updates the existing review entry and retains its
attempt provenance. Re-fetch comments, then inspect `review-ledger.sh remediation` before readiness;
coverage alone never proves repair completion. Do not purchase another review to resume.
