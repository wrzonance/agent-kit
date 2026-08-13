# Automated review provider rules

## Contents

- Provider table
- Deterministic author classification and routing lanes
- Reply-body integrity gate
- Human-review confirmation gate
- Provider identity — why the author matters
- Step 1a: surfacing formats (H items, B items)
- CodeRabbit state check
- Step 5: assess findings (VALID/INVALID/NITPICK, generic B, Code Quality)
- Step 5 recipes: reply, anchored nitpick thread, resolve thread
- End of cycle
- Step 6: agent-doc threads at exit
- Decline Rationale Templates
- Pitfalls

This is the detail behind the SKILL.md body's provider-rules heading and Step 1a/5/6 pointers.
Read the relevant section when Phase C findings land.

## Provider table

Treat these as separate providers. Identify them from the comment/review author, not from a check name:

| Provider | Findings live in | Fixed finding | Inaccurate finding |
|---|---|---|---|
| CodeRabbit | Reviews, inline comments, and conversation bodies | Reply with the commit SHA, then resolve its review thread | Reply with a concrete rationale, then resolve its review thread |
| `github-code-quality[bot]` | Inline PR review comments and their review threads | Implement the suggested fix verbatim, reply with the commit SHA, push, and wait for the next Code Quality scan to auto-clear the finding | Use GitHub's **Dismiss finding** action and provide a specific reason; do not silently resolve the thread |
| Other authoritative forge bots | Inline comments, review threads, and conversation comments | Assess on the merits, fix or decline with an attributed reason, reply, then resolve a bot-only thread; for code-scanning findings note that the fix clears on the next rescan | Reply with the concrete reason and resolve the bot-only thread; never trigger the bot |
| Human reviewer | Reviews, inline comments, review threads, and conversation comments | Surface the exact feedback, proposed action, and draft reply; act and reply only after explicit user confirmation | Same confirmation gate; never resolve the thread |

Neither bot may be triggered by this skill. Review and scan timing is controlled by each provider's
repository and organization configuration; observe the resulting state instead of inferring it.

## Deterministic author classification and routing lanes

Classify every author from authoritative forge data before routing a finding. GitHub GraphQL's
`author.__typename == "Bot"` and REST's `author.type == "Bot"` are authoritative type signals;
an exact terminal login suffix of `[bot]` is the other accepted signal. A login merely containing
`bot` (for example `botond` or `abbott`) is human, as are missing or unqueryable authors.

The classifier emits one signal and one lane:

| Signal | Lane | Meaning |
|---|---|---|
| `known-provider` | known-provider | CodeRabbit (login exactly `coderabbitai[bot]` or `coderabbitai`) or `github-code-quality[bot]`; use the provider-specific rules above |
| `type=Bot` | generic-automated | An authoritative forge Bot with no known provider |
| `login-suffix` | generic-automated | Any exact `[bot]` login suffix with no known provider |
| `human` | human | No authoritative automation signal; confirmation-gated |

Use `scripts/classify-author.sh` for a single author fixture or boundary check. The state dump
reports the same signal counts. A generic automated finding is an automated B-item (`B1`, `B2`, ...),
never an H-item; H labels are human-only. A generic bot-only thread may be resolved only after an
attributed reply. Human content anywhere in the thread moves the whole thread to the human lane,
which is never auto-resolved. Do not invoke or trigger any provider, including a generic bot.

GitHub's public Code Quality REST API currently exposes finding retrieval, not a supported per-finding dismissal mutation. Use `gh` to inspect and reply, but do not invent an endpoint:

```bash
# Inspect Code Quality findings available through the public API (read-only).
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' 'jq is not installed; evidence unavailable' >&2
    exit 1
fi
gh api "repos/$REPO/code-quality/findings?state=open&per_page=100" \
  -H "X-GitHub-Api-Version: 2026-03-10"
# The PR finding comments and their IDs come from the Step 1 artifact — no re-query.
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
jq -r '.[] | "\(.id)\t\(.path)\t\(.line)\t\(.commit_id)"' \
  <"$RUN_DIR/state/pr_${PR}_code_quality_comments.json"
```

## Reply-body integrity gate

After every automated reply, the created comment must be re-fetched by
its returned ID and its stored body compared byte-for-byte with the exact intended text. Do not
resolve or dismiss a finding until they match.

`scripts/gh-comment.sh` **is** the procedural implementation of that gate — do not hand-roll it.
It reads the body from a file (never from a shell string), posts it as JSON, re-fetches the stored
comment, and `cmp`s the exact decoded bytes. On success it prints one line
(`posted id=… url=… verified=exact`) and exits `0`. On any mismatch it prints a capped unified diff
to stderr, leaves stdout empty, and exits `1`. The safe caller rule is therefore: **resolve or
dismiss only when the helper printed a line on stdout AND exited `0`.** See below for the call
shapes (`--reply-to`, `--anchor`, `--update`).

## Human-review confirmation gate

Treat every review, inline comment, review thread, and PR conversation comment in the **human lane**
as human-authored content. This includes content whose author login equals the account returned by
`gh api user --jq .login`: an authenticated `gh` session proves which account will post the agent's
actions, not who authored earlier content. A generic automated lane item is not confirmation-gated,
but it still requires a merits assessment and an attributed reply before resolution.

When human-authored content appears at any point in the run:

1. Surface it immediately with a stable local label (`H1`, `H2`, ...), author, URL or comment ID, current resolution state, and the exact substantive text. Generic automated findings use a separate `B1`, `B2`, ... label and never enter this gate.
2. Show the agent's assessment, any proposed code change, and the exact draft reply. Wrap the draft in the required agentic attribution.
3. Ask the user to approve, edit, decline, or defer each labeled item. A generic "continue", silence, elapsed time, or approval of bot work is not confirmation.
4. Continue independent CI and automated-provider work when safe, but do not change code solely because of that human feedback and do not post or edit a response until the user explicitly confirms that item and its proposed handling.
5. After confirmation, perform only the approved action and post the exact approved reply. If the reply changes materially after approval, surface it again.
6. Fetch the stored reply and verify its body exactly matches the approved text. Correct a mismatch in place and verify again.
7. **Never call `resolveReviewThread` for a human-authored thread**, even after fixing the code or posting an approved reply. Resolution belongs to the human reviewer.

Batching several human items into one gate is allowed only when every item has its own label, proposed action, and draft reply so the user can approve them independently. If confirmation is unavailable, leave the items untouched, report them as `awaiting user confirmation`, and do not claim the PR is ready to merge.

Use `<!-- review-remote-pr:agent-doc -->` only on workflow-created bookkeeping threads and `<!-- review-remote-pr:agent-reply -->` on workflow-created replies. These markers identify individual agent-created comments; they never make a thread resolvable when it also contains unmarked human content. Never infer agent ownership from a GitHub login, commit author, PR author, or authenticated account.

## Provider identity — why the author matters

Only explicitly recognized providers get provider-specific handling: CodeRabbit and
`github-code-quality[bot]`. Match CodeRabbit against the exact configured accounts —
`coderabbitai[bot]` and `coderabbitai` — never a substring of the login. A substring test hands the
known-provider lane to any human who registers `mycoderabbit`, and that lane is what makes a thread
replyable and resolvable *without* the human confirmation gate. An account that merely looks like a
provider is ambiguous, and every ambiguous author is human. Other authors enter the generic automated lane only
when the authoritative forge type is `Bot` or the login ends exactly in `[bot]`; **every ambiguous
author is human**, including the account the authenticated `gh` session posts as. An authenticated
session proves which account *will* post the agent's actions, never who authored earlier content.
The reserved `<!-- review-remote-pr:agent-... -->` markers identify individual workflow-created
comments and nothing else; never infer agent ownership from a login containing `bot`, a commit
author, or the PR author.

The digest's counts follow exactly that rule. `generic=N` is an unresolved generic automated thread
with no human comment. `human=N` is any unresolved thread carrying at least one human-lane comment
that is neither marked, and a bot-originated thread a human replied in counts as human. The
`classification:` line reports `known-provider`, `type=Bot`, `login-suffix`, and `human` signals for
the same evidence. The digest's `next:` lines already point each non-zero lane at its step — see
those instead of re-deriving where to go from a raw count.

`nitpicks: N unhandled` is a **mechanical proxy**, not a judgement: CodeRabbit review bodies plus PR
conversation comment bodies matching /nitpick/i or carrying the broom emoji, minus the anchored
threads this workflow already opened to document them (`<!-- review-remote-pr:agent-doc -->`).
Inline review comments are deliberately excluded — they live in review threads and are already
counted on the `threads:` line, so counting them here would make the number unreachable.

`alerts: code-scanning n/a` means the endpoint returned 403/404 — typically code scanning is not
enabled on the repository, or the token lacks `security_events`. It is not a failure and never
changes the exit code.

## Step 1a: surfacing formats

Inspect the complete paginated review, inline-comment, issue-comment, and review-thread dumps from Step 1. Route each item through the classifier. Exclude from the human gate:

- explicitly recognized automated-provider authors such as CodeRabbit and `github-code-quality[bot]`;
- other authors with an authoritative `Bot` type or exact `[bot]` login suffix (generic automated lane);
- exact workflow-created comments containing `<!-- review-remote-pr:agent-doc -->` or `<!-- review-remote-pr:agent-reply -->`.

Do not exclude the login returned by `gh api user`; feedback authored through that account is human unless the individual comment has an exact agent marker.

For each new or still-pending human item, present:

```text
H1 — @author — [review | inline thread | PR comment] — open/resolved — <URL or ID>
Feedback: <exact substantive text>
Assessment: <valid / invalid / question / informational, with rationale>
Proposed action: <specific code change or no code change>
Draft reply:
This was written agentically; verify its assertions:
<!-- review-remote-pr:agent-reply -->
<exact proposed response>
🤖 Co-authored by <actual agent identity>.
Approve H1 as drafted, approve with edits, decline, or defer?
```

Wait for an explicit per-item decision before handling the human item. Approved code changes still go through the repository verification commands (run each through `agent-run.sh`) and normal commits. Post the reply only after the approved action is complete, include the resulting commit SHA when applicable, verify the stored reply body exactly, and leave the thread unresolved. Record the decision so repeated polling does not ask again unless the human adds new content.

For generic automated items, use the B namespace and continue unattended after a merits assessment:

```text
B1 — @github-advanced-security[bot] — [generic automated inline thread] — open — <ID>
Signal: login-suffix
Assessment: <valid / invalid, with rationale>
Proposed action: <smallest safe fix or decline>
Reply: This was written agentically; verify its assertions: ...
```

Fix or decline each B-item with an attributed reason and reply before resolving it. If the finding is
backed by code scanning, say that a pushed fix clears it on the next rescan; do not manually trigger
that scan. A bot-only generic thread can be resolved after the verified reply. If any human-lane
comment joins it, relabel the thread H and leave it unresolved.

## CodeRabbit state check (informational — never a trigger decision)

A green "CodeRabbit" status check is NOT proof a review happened. Detect the real signal in the
comment **body** (rate-limit warnings and bare "✅ finished" acks both leave the check green):
`gh-pr-state.sh`'s digest carries this as its `provider: coderabbit=…` line, computed from the same
Step 1 artifact with last-signal-wins ordering — a stale walkthrough from an earlier cycle never
masks a rate-limit on the current trigger. No separate query is needed; read the value already
printed by the Step 1/Step 6 `--full` call.

- `reviewed` → a review posted real findings; work its items (Phase C Step 5).
- `none` → no matching review has landed yet. Do NOT post any review command or infer whether the
  provider is configured for automatic, incremental, or manual review; continue the current phase
  and leave any trigger decision to the user.
- `rate-limited` → the provider reports throttling. Do not infer automatic retry or the action
  required to request another pass. Observe bounded rounds and report the state; leave any retry
  decision to the user. Never advise buying credits.

### Stale approval residue

When `gh-pr-state.sh` reports a stale base after a parent merge, a CodeRabbit approval earned
before retargeting is residue from the old merge state, not approval of the revalidated PR. State
that residue as a knowing acceptance in the handoff. The one-review/one-ping rule forbids silently
inheriting it or triggering a second provider pass merely to make the approval look fresh.

## Step 5: assess findings

Before assessing any saved review artifact, prove the parser used by the recipe is available.
An empty artifact is acceptable only after that parser ran successfully; a missing parser is a
blocked check and must never be summarized as "no findings."

**Order matters: apply explicitly approved human-review actions without resolving their threads; triage body nitpicks and GitHub Code Quality findings FIRST; reply-and-resolve CodeRabbit's threads LAST.** Resolving CodeRabbit's threads can arm its auto-approve, while Code Quality findings need a fresh scan to establish their state. Work the cycle in this order:

1. For each user-approved human item, record the exact approved code action; replies still wait until the verified fix exists and human threads remain unresolved
2. Triage every body nitpick, `github-code-quality[bot]` finding, confirmed adversarial finding, and CodeRabbit thread into one accepted code-change/decline batch
3. If the batch contains code changes, dispatch exactly one Luna implementation worker through the six-step gate; inspect and independently verify its returned commit(s)
4. Post and integrity-check approved human replies, body-nitpick documentation, Code Quality replies, and adversarial-review outcome comments
5. Then reply to and resolve CodeRabbit's own eligible threads; never resolve human-touched threads

For each unresolved **CodeRabbit** thread, each CodeRabbit body nitpick surfaced from `$RUN_DIR/state/pr_${PR}_reviews.json`, `$RUN_DIR/state/pr_${PR}_comments.json`, or `$RUN_DIR/state/pr_${PR}_issue_comments.json`, AND each confirmed adversarial-review finding from `$RUN_DIR/adversarial.result.json` (Step 1b):

```text
VALID   → fix the code, commit; reply explaining what was fixed + commit SHA
INVALID → write decline rationale (cross-module consistency, deliberate design choice, etc.)
          reply with rationale
NITPICK → fix if trivial (< 5 min), decline if not; reply either way
```

Body-only nitpicks are still actionable. Do not skip them just because they do not have a `PRRT_...` review-thread node ID.

### Generic automated finding handling

For each unresolved generic automated (`B1`, `B2`, ...) thread, assess the finding on its merits,
then put the smallest safe fix or a concrete decline reason in an attributed reply. A bot-only
thread may be resolved after the reply has passed the exact-body integrity gate. If the author is a
code-scanning bot, state that a pushed fix is expected to clear on the next rescan; never trigger a
scan or a review bot. If any human-lane comment is present, convert the item to `H#`, leave it open,
and apply the human confirmation gate instead.

### GitHub Code Quality finding handling

For each unresolved comment from `github-code-quality[bot]`:

```text
VALID → apply the suggested autofix verbatim (or the smallest equivalent only when
        the suggestion cannot be applied mechanically) and run the repository
        checks through `agent-run.sh`. Fixes accumulate into the cycle's ONE
        batch: commit with the rest of it and let the single end-of-cycle push
        carry them -- a push per finding triggers a scan while later findings
        are still unhandled, and contradicts the single-push contract below.
        Reply to the original comment with the short commit SHA, then wait for
        the next Code Quality scan and verify that the finding auto-clears.

INVALID → do not resolve the thread as a shortcut. Reply to the original comment
          with a specific dismissal reason (false positive, intentional pattern,
          test-only code, legacy code, or another repository-specific reason), then
          use GitHub's Dismiss finding action with that same reason. Verify the
          finding is dismissed after the scan.
```

A Code Quality finding is complete only when GitHub reports it auto-cleared after the pushed fix or reports it dismissed with a reason. `resolveReviewThread` is not a Code Quality dismissal API and must not be used for an inaccurate finding. Do not use `/code-scanning/alerts/...` unless the finding has independently been identified as a code-scanning alert — Code Quality and code scanning are distinct API resources. If the UI does not expose **Dismiss finding**, stop and report the missing permission; do not silently close the thread or use the whole-review dismissal endpoint (`PUT .../reviews/$REVIEW_ID/dismissals` dismisses an entire PR review, never one finding).

**Never interpolate a comment body into a double-quoted shell string.** Backticks inside a
double-quoted argument are command-substituted by the shell, so ``Fixed in `abc1234`.`` posts as
`Fixed in .` — the SHA is silently stripped and the reply becomes unverifiable. Write the body to a
file with a **quoted** heredoc (`<<'EOF'`, which expands nothing) and let `gh-comment.sh` transport
it; substitute varying values with `printf` arguments, never by unquoting the heredoc.

## Step 5 recipes

**Reply to inline comments:**
```bash
# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
comment_id=1234567890                       # from $RUN_DIR/state/pr_${PR}_comments.json
short_sha=$(git rev-parse --short HEAD)
agent_identity='Codex gpt-5.6-luna'         # the agent that actually wrote the fix
reply_body="$RUN_DIR/reply_${comment_id}.md"

cat >"$reply_body" <<'EOF'
This was written agentically; verify its assertions:
<!-- review-remote-pr:agent-reply -->
EOF
# shellcheck disable=SC2016  # the backticks are LITERAL markdown in the comment
# body; single quotes are precisely what stops the shell from substituting them.
printf 'Fixed in commit `%s`. [or: Declining — rationale here.]\n' "$short_sha" >>"$reply_body"
printf '🤖 Co-authored by %s.\n' "$agent_identity" >>"$reply_body"

"$agentkit/review-remote-pr/scripts/gh-comment.sh" \
  --pr "$PR" --repo "$REPO" --body-file "$reply_body" --reply-to "$comment_id"
```

`gh-comment.sh` **is** the reply-body integrity gate: it posts the file's
exact bytes, re-fetches the stored comment, and `cmp`s them. On success it prints one line
(`posted id=… url=… verified=exact`) and exits `0`; on a mismatch it prints a unified diff to stderr
and exits `1` with stdout empty. **Resolve or dismiss only when that stdout line exists and the exit
code was `0`** — no line means nothing is proven, so nothing gets resolved. Use `--update ID` to
edit a top-level conversation comment in place (that endpoint cannot edit an inline review comment).

**Document body-only nitpicks as NEW anchored threads — not top-level comments:**

A `gh pr comment` floats in the conversation, disconnected from the code — CodeRabbit can't tie it to the change. Instead, open a **new review thread** anchored on the file the nitpick names, at the exact lines you changed (for declines: the lines the nitpick cites), referencing the commit and mentioning `@coderabbitai`:

```bash
# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
nitpick_path=src/example.ts                 # from the nitpick body
nitpick_line=42                             # must be inside the PR diff
short_sha=$(git rev-parse --short HEAD)
agent_identity='Codex gpt-5.6-luna'
doc_body="$RUN_DIR/nitpick_${nitpick_line}.md"

cat >"$doc_body" <<'EOF'
This was written agentically; verify its assertions:
<!-- review-remote-pr:agent-doc -->
EOF
# shellcheck disable=SC2016  # the backticks are LITERAL markdown in the comment
# body; single quotes are precisely what stops the shell from substituting them.
printf '@coderabbitai Body nitpick addressed: %s. Fixed in `%s`. [or: Declining — rationale here.]\n' \
  'rename the exported helper' "$short_sha" >>"$doc_body"
printf '🤖 Co-authored by %s.\n' "$agent_identity" >>"$doc_body"

"$agentkit/review-remote-pr/scripts/gh-comment.sh" \
  --pr "$PR" --repo "$REPO" --body-file "$doc_body" \
  --anchor "${nitpick_path}:${nitpick_line}"
```

`--anchor` takes `commit_id` from `git rev-parse HEAD`, so run it from inside the PR worktree. Add
`--start-line 40` for a multi-line anchor (`start_side` follows `--side`, default `RIGHT`). If the
API 422s because the line is not in the PR diff — e.g. a declined nitpick on an untouched line — the
helper prints that exact hint; follow it by re-running the identical command with `--anchor` dropped,
which posts a top-level comment quoting the nitpick. These **marked agent-documentation** threads are
yours: leave them open so CodeRabbit sees the mention on its next provider pass, then resolve
them at exit only if no unmarked human comment has joined the thread.

**Resolve threads (requires GraphQL thread node ID from Step 1):**
```bash
gh api graphql -f query='
mutation {
  resolveReviewThread(input: {threadId: "PRRT_kwDO..."}) {
    thread { isResolved }
  }
}'
```

Resolve CodeRabbit and generic automated threads — both accepted fixes and declined suggestions —
only when they contain no unmarked human-lane comment, and always **reply BEFORE resolving**. A
declined thread is resolved after the reply explains why. **Never resolve a human-touched thread** —
post only a user-approved reply, leave resolution to the human, and list it in the exit report. This
includes feedback authored by the authenticated `gh` login. Body-only nitpicks are complete when
documented in their marked anchored thread. **Adversarial-review findings** have no review thread;
record each outcome in a PR comment.

## End of cycle: one push, zero review commands

The cycle ends with its **single batched push**. Post **no** review command in any phase —
a fresh CodeRabbit pass on the batch depends on provider configuration or a user decision; report that
the fixes are pushed so they can decide. Why decline replies still matter: a later `full review` can
re-evaluate the PR **from scratch, disregarding previous comments** — it can re-raise previously
declined items. Decline replies store Learnings (see Decline Rationale Templates) that survive that;
post them before the cycle's push.

## Step 6: agent-doc threads at exit

Marked agent-documentation threads may be resolved at exit only when every non-bot comment has an
agent marker. An unmarked human reply converts the whole thread to confirmation-gated and leaves it
open. Never substitute `author == gh api user` for a marker. Do not apply this rule to an original
`github-code-quality[bot]` finding: it must auto-clear or be dismissed with a reason.

Re-open `$RUN_DIR/state/pr_${PR}_reviews.json`, `$RUN_DIR/state/pr_${PR}_comments.json`, `$RUN_DIR/state/pr_${PR}_issue_comments.json`, and `$RUN_DIR/state/pr_${PR}_code_quality_comments.json`. Confirm every automated-review body nitpick has a matching anchored thread (or fallback comment) recording its fix/decline, and every Code Quality comment is either gone/auto-cleared after the pushed fix or explicitly dismissed with a reason. Confirm every confirmed adversarial-review `[P1]/[P2]` finding has a matching fix/decline PR comment.

## Decline Rationale Templates

```text
"Declining — [existing module X] uses the same pattern without [Y];
introducing [Y] here alone creates inconsistency before a cross-module
refactor is planned."

"Declining — deliberate design choice: [reason]. Tracked for future consideration."

"Declining — nitpick; tradeoff of [readability vs brevity] is acceptable here."
```

Post declines as replies **on the specific code comment**, mention the relevant provider, and explain the *why*, not just the what. For CodeRabbit, mention `@coderabbitai` so its learning system stores a **Learning** that stops the same suggestion from being re-raised on this and future PRs (docs.coderabbit.ai/knowledge-base/learnings). For `github-code-quality[bot]`, repeat the same concrete reason in GitHub's **Dismiss finding** action; a reply or a resolved thread alone is not a dismissal. Resolving a thread without a why teaches no provider anything useful.

## Pitfalls

| Problem | Fix |
|---|---|
| `resolveReviewThread` returns NOT_FOUND | You passed REST comment ID, not GraphQL thread node ID (`PRRT_...`). Fetch thread IDs via GraphQL first. |
| Waiting for a review after the ready flip | The flip's review behavior is repository/provider configuration. Report draft-phase complete; do not trigger a review yourself. |
| Waiting for a review after a push | Re-check observed provider state in bounded rounds. Report fixes pushed; the user decides whether to trigger anything. |
| `github-code-quality[bot]` finding remains after a fix | Wait for the next Code Quality scan and inspect the refreshed finding state. Do not manually resolve it as a substitute for the scan. |
| Inaccurate Code Quality finding | Reply with a concrete reason, then use GitHub's **Dismiss finding** action with that reason. The public Code Quality REST API is read-only for findings; do not guess a mutation. |
| Code Quality dismissal command temptation | `PUT /pulls/$PR/reviews/$REVIEW_ID/dismissals` dismisses an entire PR review, not one finding. Never use it for a single Code Quality comment. |
| Code Quality vs code scanning API confusion | `github-code-quality[bot]` findings use the Code Quality surface. `/code-scanning/alerts/...` is a different resource; use it only after independently identifying a code-scanning alert. |
| CodeRabbit review body vs inline comments | Review bodies, inline comment bodies, and PR conversation comment bodies can include actionable nitpick sections. Read full bodies from the Step 1 temp files; do not rely only on review threads. |
| Thread already resolved | Skip — don't re-resolve. Only target `isResolved: false` threads. |
| Multiple provider review cycles | Do not assume full-pass or incremental semantics. Reconcile all unresolved findings from the state artifacts; use `submitted_at` only to identify newly observed reviews. |
| CodeRabbit check green but no real review | Rate-limit warning / bare "✅ finished" ack leaves the check green. Detect the real signal in the comment **body** (`Actionable comments posted` / `walkthrough` = reviewed; `Review limit reached` = throttled — wait for provider state, don't buy credits). `none` = no matching review has landed. |
| Body nitpick has no thread ID | Fix or decline it anyway, then open a NEW anchored thread on the nitpick's file/lines referencing the commit and mentioning @coderabbitai. Only `PRRT_...` threads can be resolved through GraphQL. |
| Body nitpick documented as top-level comment | A floating `gh pr comment` is disconnected from the code — CodeRabbit can't tie it to the change. Use the anchored-thread POST above; top-level comment is the 422 fallback only. |
| Threads resolved before body nitpicks handled | Resolving CodeRabbit's threads arms its auto-approve (when enabled) — an approval can fire on a PR with unhandled nitpicks. Follow the ordering above: nitpicks first, reply+resolve threads last. |
| CodeRabbit never auto-approves | Its approval workflow may be disabled for this org/repo entirely — then none ever comes; exit on threads-resolved + nitpicks-handled. If enabled, auto-approve needs BOTH a reply and a resolve on every thread CodeRabbit opened, plus passing pre-merge checks. |
| Full review re-raises declined items | A (user-run) `full review` re-evaluates from scratch, disregarding previous comments. Post decline replies with the WHY first — Learnings persist the decision across reviews (see Decline Rationale Templates). |
| Tempted by `@coderabbitai resolve` (bulk) | NEVER use it — it resolves every CodeRabbit thread at once, reply-less. Each thread must be individually triaged, replied to, and resolved; a bulk resolve can also arm auto-approve while items are still unhandled. |
| Authenticated `gh` user authored the review | Treat it as human. Login equality never proves agent authorship; only reserved markers identify individual workflow-created comments. |
| Human replies inside a bot-originated thread | The whole thread is human-touched. Gate the response and never resolve it, even though the first author is a bot. |
| Human review appears during the run | Surface exact feedback, assessment, proposed action, and draft reply; wait for explicit per-item approval before code changes or posting. Never resolve its thread. |
| Human reviewer thread unresolved | Expected after an approved reply — resolution belongs to the human. List it in the exit report. An undecided item blocks a ready-to-merge claim. |
| Backticks in a comment body get command-substituted | ``-f body="Fixed in `abc1234`."`` is a double-quoted shell string, so the shell runs `abc1234` as a command and posts `Fixed in .` — the SHA vanishes silently. Never interpolate a body into a shell string. Write it to a file with a **quoted** heredoc (`<<'EOF'`) and inject varying values with `printf` arguments, then post it with `gh-comment.sh --body-file`. |
| Posted reply body doesn't match intended text | Post through `gh-comment.sh`: it sends the file's exact bytes, re-fetches the stored comment, and `cmp`s them, printing a unified diff on mismatch. Resolve or dismiss only when it printed a stdout line AND exited `0`. |
| Reply to comment returns 404 | URL must include PR number: `repos/$REPO/pulls/$PR/comments/$COMMENT_ID/replies`. The shorter form without `$PR` returns 404. |
| `python3 -c "..."` fails with `unmatched "` | zsh breaks on double-quoted multi-line python. Never use `python3 -c "..."` for multi-line scripts; write the script to a file first, then run it. |
| `cmd \| python3 << 'EOF'` SyntaxError | Pipe and heredoc both claim stdin — the shell concatenates them and Python sees the piped bytes prepended to the script. Always write the output to a file first (`cmd > file.json`), then `python3 << 'EOF'` reading the file. |
