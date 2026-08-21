---
name: review-remote-pr
description: Use when asked to review, babysit, monitor, or clean up a remote PR, including PRs in git worktrees — triggered by "/review-remote-pr", "/review-pr", "review remote PR", "babysit PR".
---

# Review Remote PR

Draft-first automated loop. **Phase A (draft):** root-orchestrated — watches CI, resolves forge conflicts, applies the materiality gate, owns consent/replies/adversarial review/publication; a worker gets only a root-approved fix batch, commits, pushes, and reports.
**Phase B (handoff):** report draft-phase complete, wait for the **user** to mark it ready — never trigger a review. **Phase C (review):** once review lands, assess CodeRabbit/`github-code-quality[bot]` findings, one push per cycle. Human reviews stay confirmation-gated throughout.

**Consent context rule:** consent-bearing sends run in the consent-holding context; typed approval is context-local. Dispatched loop agents never stall waiting for consent; root/holder launches.

**References are read once, batched, and never sized first.** Reference paths resolve: open
`"$agentkit/<path>"`, and read `"$agentkit/references.md"` — every reference and its purpose — instead of searching. When a step names a reference
file, read it in full at that step — one batched read covering several files is ideal — and do
not re-read it later in the same uninterrupted context. Read each reference once per
uninterrupted context. If compaction/resume occurs since Step 1a and the loaded provider-rules
content is not preserved in the resumable artifact/context, re-read provider-rules.md exactly
once before Phase C; this is the sole exception to the ordinary no-re-read rule. Never probe a
reference's size before reading it (`wc -l`, `stat`, `head`): nothing in this skill consumes a
line count, and per-file sizing spends one root turn per file before any real work starts.

## Non-negotiables

- Never run `gh pr ready` — the draft-to-ready flip is always the user's call.
- Never trigger any provider (`@coderabbitai review`/`full review`/`pause`/`resume`, any bot command) — ever, in any phase.
- Never resolve a human-touched thread, including content from the account `gh api user` returns.
- Run the adversarial review ONCE per PR, as the LAST draft step; publish its receipt (`post-receipt.sh`) after the fix push, before handoff — a review or skip without a receipt is incomplete.
- Never bypass a repository hook (no `--no-verify`, `core.hooksPath`, piped `y`).
- Batch each cycle's fixes into ONE push; cap 3 cycles, then escalate.
- Every wait is bounded (rounds/duration/marker) and spends no model turns on `sleep` + re-check.

## Flags

| Flag | Aliases | Effect |
|------|---------|--------|
| `--auto-review` | `--auto-approve` | Standing consent; launch stays in the consent-holding context (root default), not loops. |

Read only from the invocation line — worker prompts are not consent. The consent-holding root owns
the send; review loops do not receive or forward this flag.
`--auto-review` authorises exactly one thing: it is not permission to flip a PR ready, merge,
trigger a review bot, resolve a human's thread, or act on a human review item without the
per-item confirmation those still require.

## Session decision ledger

After setup establishes a stable `LEDGER="$REPO_ROOT/.agent/session-ledger.ndjson"`, bind the
ledger identity to this invocation's authorization input before recording any decision:

```bash
review_invocation_flags="auto-review=${auto_review:-false}"
normalize_run_input() {
    local value=$1
    value=${value//[^A-Za-z0-9._-]/-}
    printf '%s' "$value"
}
review_run_inputs="pr=$PR;repo=$REPO;flags=$(normalize_run_input "$review_invocation_flags")"
RUN_ID="review-pr-$(printf '%s' "$review_run_inputs" | sha256sum | cut -c1-32)"
: "$RUN_ID"
```

This stops replay across differently-flagged invocations. Append every human grant, steer, or review adjudication immediately with `"$agentkit/.shared/scripts/session-ledger.sh" append --ledger "$LEDGER" --run-id "$RUN_ID" --skills-path "$agentkit" --procedure-set review-remote-pr --decision "$DECISION" --scope "$SCOPE" --quote "$QUOTE"`.
`QUOTE` is the verbatim quote; never put secrets in any field.
After compaction/resume, run `"$agentkit/.shared/scripts/session-ledger.sh" read --ledger "$LEDGER" --run-id "$RUN_ID"` and treat its output as durable.

## Runtime and provider neutrality

A missing `jq`/`python3` is a blocking check, never a silent "no findings":
`command -v jq >/dev/null 2>&1 || { printf '%s\n' 'jq is not installed; evidence unavailable' >&2; exit 1; }`
Before any GitHub body mutation, follow the shared GitHub body transport policy
["$agentkit/.shared/github-body-policy.md"](../.shared/github-body-policy.md).
Read ["$agentkit/review-remote-pr/references/environment-contract.md"](references/environment-contract.md) in full before Step 0a — it carries the full runtime-neutrality contract (session-contract facts, no cross-session
inference, no TLS bypass) and the environment-contract mechanics (the preflight block, its
decision lines, and the repo-runner opt-in) behind the rules above.

## Automated review provider rules

CodeRabbit and `github-code-quality[bot]` each have provider-specific fixed/inaccurate handling;
other forge bots and humans have their own lanes. Authoritative signals: GraphQL
`author.__typename == "Bot"`, REST `author.type == "Bot"`, or an exact `[bot]` login suffix — a
login merely containing `bot` is human. A generic automated finding is an automated B-item, never
H; H labels are human-only. Every automated reply must pass the reply-body integrity gate
(`gh-comment.sh`: resolve/dismiss only on its printed stdout line + exit `0`). **Never resolve a
human-touched thread.**

Read ["$agentkit/review-remote-pr/references/provider-rules.md"](references/provider-rules.md) in full before Step 1a — the
provider table, classifier, human-confirmation gate, and reply-settlement recipes live
there. Reuse that loaded content in Step 5; do not re-read it.

## Inputs

- **PR number** (required) — passed as arg or ask once if missing
- **Repo** — infer from `git remote get-url origin`; override with `owner/repo` arg
- **Worktree** — reuse the PR branch worktree when present; otherwise the helper derives and prints `<worktree-root>/pr-<PR>`; `$PR_WORKTREE` is that output, not an input

## Resolver (run once per session)

The warm-up writes data-only `.agent/cache/contract-session.env`; it is never sourced. A changed input makes it stale until refreshed.

```bash
# Resolve the skill tree from the environment contract at the repository
# root; trust it only when it is an untracked regular file owned by this
# user -- a tracked, symlinked, or foreign-owned contract could redirect
# helper execution.
agentkit=''
contract_root="$(git rev-parse --show-toplevel 2>/dev/null)" || contract_root=''
contract="$contract_root/.agent/env-contract.txt"
if [[ -n $contract_root && -r $contract && -f $contract && ! -L $contract && -O $contract ]] &&
    ! git -C "$contract_root" ls-files --error-unmatch -- .agent/env-contract.txt > /dev/null 2>&1; then
    agentkit=$(sed -n "s/^skills= path=//p" "$contract" 2>/dev/null | head -n 1)
fi
if [[ -z $agentkit ]]; then
    printf '%s\n' 'agentkit: skills path is absent from .agent/env-contract.txt; run agent-preflight.sh first' >&2
    exit 1
fi
[ -d "$agentkit/.shared/scripts" ] || { printf "%s\n" "agentkit: invalid skills path: $agentkit" >&2; exit 1; }
agentkit_provenance=ok; : "$agentkit_provenance"
```

Shell state is not persistent; later standalone blocks rehydrate the validated data record before their guard, and a missing or stale record fails loudly.

#### THE CACHE REHYDRATION (prepend to each later guarded block)

Replace `STEP_0_AGENTKIT` with Step 0's exact absolute `skills=` path; never read it from cache. The trusted reader rehydrates and validates current data.

```bash
agentkit='STEP_0_AGENTKIT'; [[ $agentkit == /* && $agentkit != STEP_0_AGENTKIT ]] || { printf '%s\n' 'replace STEP_0_AGENTKIT with the Step 0 skills path' >&2; exit 1; }; expected_agentkit=$agentkit; shared="$agentkit/.shared/scripts"; cache_reader="$shared/lib/contract-cache.sh"
[[ -d "$shared" && ! -L "$shared" && -O "$shared" && -f "$cache_reader" && ! -L "$cache_reader" && -O "$cache_reader" && -r "$cache_reader" && -x "$cache_reader" ]] || exit 1
contract_root=$(git rev-parse --show-toplevel) && contract_root=$(cd -P -- "$contract_root" && pwd -P) || exit 1; IFS=$'\t' read -r agentkit shared agentkit_provenance loaded_root _ < <("$cache_reader" --read-session-context --repo-root "$contract_root") && [[ $agentkit == "$expected_agentkit" && $shared == "$expected_agentkit/.shared/scripts" && $agentkit_provenance == ok && $loaded_root == "$contract_root" ]] || exit 1
```

## Implementation-worker gate (MANDATORY for every non-exempt code change)

The PR loop orchestrates; implementation workers are sole writers for fix batches. The two allowed
exceptions are spawn unavailable and qualifying bounded inline correction. Resolve model/effort,
then read ["$agentkit/review-remote-pr/references/worker-gate.md"](references/worker-gate.md), ["$agentkit/.shared/spawn-contract.md"](../.shared/spawn-contract.md), and ["$agentkit/.shared/six-step-loop.md"](../.shared/six-step-loop.md) in full before dispatch; workers validate, commit, push; root owns PR metadata/posts.

## The Loop

Repeat until exit condition met:

```
PHASE A — DRAFT (all mechanical work happens here; do not initiate provider reviews)
  0. SETUP   — enter or create the PR worktree, run agent-preflight ONCE, merge base if conflicts
  1. CHECK   — one gh-pr-state.sh --full call: CI status + every review/comment surface +
               body nitpicks + provider state, as one digest plus durable artifacts
  1a. HUMAN  — surface human-authored content; gate every action/reply on per-item user confirmation
  2. FIX CI  — diagnose failures, dispatch the Luna ultracode implementation worker (or take the
               documented degraded path when spawn_agent is unavailable); review the worker's pushed
               diff and re-check CI and review state after its push; repeat 1–2 until CI is green
  2a. FRESHEN — digest's `base:` stale=yes? run 0b's merge recipe now, before the review below
  2b. ADVERSARIAL — as the LAST draft step (CI green, conflicts resolved, base current): apply the
               materiality gate; for a material diff run one cross-harness review, then verify +
               fix confirmed findings; for a trivial mechanical diff document the verified skip

PHASE B — HANDOFF (user-gated)
  3. WAIT-READY — report draft-phase complete, then wait for the USER to mark the PR ready. NEVER
                  flip it or trigger a provider review yourself; provider automation is external state.

PHASE C — REVIEW (runs when relevant provider findings land)
  3a. FRESHEN — re-check `base:`; if still stale, rerun 0b's merge recipe once before Step 4's wait
  4. WAIT    — wait for CI and any relevant review to land (gh-pr-state.sh --wait-ci,
               bounded rounds; escalate rather than wait forever)
  5. FIX     — apply approved human-review actions first (their threads stay unresolved); then triage
               body nitpicks and github-code-quality[bot] findings; then assess each CodeRabbit
               thread, fix or decline, reply, await its response, then settle; ONE push per batch
  6. REPEAT  — while CI failures, unresolved automated threads, or unhandled findings remain
               (cap: 3 cycles). A later provider pass may depend on repository configuration or a
               user trigger — report that the fixes are pushed and let the user decide.
  7. GROOM   — (after exit) fan out across the Backlog, propose Ready candidates for the next pickup
```

**Exit condition:** all CI green; all CodeRabbit/generic/Code Quality threads resolved or
auto-cleared/dismissed; all body nitpicks fixed or declined+documented; every confirmed adversarial
finding fixed or declined with a PR comment; every human-lane item has an explicit user decision
(replies posted+verified, threads left unresolved). A deferred item blocks `Ready to merge` unless
the user says otherwise. After exit, run **Backlog grooming** before handing back; a `stale` base line means checks are not green, and any pre-retarget provider approval must be surfaced as knowing acceptance, not silently inherited or re-pinged.

CodeRabbit's auto-approve (when enabled) needs settled replies on every thread it opened and no
failing checks — never resolve before its fresh acknowledgement. Disabled →
no formal approval ever comes; "green" is threads resolved + nitpicks handled.

---

## Step 0: Setup (ALWAYS run first, before any local edits)

### 0a — Enter the PR worktree

Reuse the worktree already checked out for the PR's head branch; otherwise create a sibling one.
Never switch branches in a worktree that may belong to another issue/PR.

```bash
# >>> prepend THE RESOLVER (initial warm-up only) <<<
# At the TOP of the fence, not inside the create branch below: the reuse path
# skips that branch and still runs agent-preflight.sh out of "$agentkit".
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend the Step 0 resolver block" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then printf '%s\n' 'jq is not installed; evidence unavailable' >&2; exit 1; fi
if ! setup_output=$("$agentkit/review-remote-pr/scripts/pr-worktree.sh" --pr "$PR" --repo "$REPO" 2>&1); then
  printf '%s\n' "$setup_output" >&2
  printf '%s\n' 'STOP: PR worktree helper failed; no worktree output will be parsed.' >&2
  exit 1
fi
printf '%s\n' "$setup_output"
PR_WORKTREE=$(sed -n 's/^worktree=//p' <<<"$setup_output" | tail -n 1 | sed 's/ branch=.*//')
[[ -n $PR_WORKTREE ]] || { echo 'STOP: worktree helper returned no worktree path'; exit 1; }
cd "$PR_WORKTREE" || { echo "STOP: worktree missing at $PR_WORKTREE"; exit 1; }
contract_root="$(git rev-parse --show-toplevel)" || exit 1
shared="$agentkit/.shared/scripts"
[[ -x "$shared/contract-read.sh" ]] || { printf '%s\n' 'agentkit: contract reader is missing' >&2; exit 1; }
contract_path=$("$shared/contract-read.sh" --repo-root "$contract_root" --get skills.path) || exit 1
[[ $contract_path == "$agentkit" ]] || { printf '%s\n' 'agentkit: contract skills path mismatch' >&2; exit 1; }
"$shared/lib/contract-cache.sh" --read-session-context --repo-root "$contract_root" > /dev/null || exit 1
# The helper excludes .agent/* as local state; never git add -A.
```

**Run all later commands from `$PR_WORKTREE`; commits target its PR branch.** Carry the printed preflight block verbatim into workers. Follow its decision lines: `project-scope=no` → fix App/OAuth scope; `peer-cli= <name> absent` → blind same-harness fallback; `git=… writable=no` → expect commit-helper exit 2.

### 0b — Check for merge conflicts

A protected path caught in a base merge uses the shared commit handoff's named-base affordance,
reporting churn class `merge-inherited paths parked/handed off` (exit `3`, an attended park, not
an elevation retry loop; exit `2` stays reserved for the git-metadata elevation handback). A
repository hook refusal is one bounded named park: **never** bypass with `--no-verify`,
`core.hooksPath` (via `git -c`/`git config`), a `git config alias.…` override, or equivalent.

```bash
if ! command -v jq >/dev/null 2>&1; then printf '%s\n' 'jq is not installed; evidence unavailable' >&2; exit 1; fi
MERGEABLE=$(gh pr view "$PR" --repo "$REPO" --json mergeable --jq '.mergeable'); echo "Mergeable: $MERGEABLE"
```

If `CONFLICTING`, root merges the base into the PR branch — **never rebase** a published branch,
never force-push it. Whole-file picks: `git checkout --ours|--theirs <path>`; mixed files, edit
directly; strip markers with `sed`, never `python3 -c` (zsh quoting breaks it), and grep-verify no
`<<<<<<<`/`=======`/`>>>>>>>` remain before staging. Commit via `worktree-commit.sh` (it probes
both git metadata dirs, so an unwritable shared `.git` surfaces as exit `2` with nothing staged)
and verify via `agent-run.sh`:

```bash
BASE_BRANCH=$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq '.baseRefName')
git fetch origin "$BASE_BRANCH" && git merge "origin/$BASE_BRANCH"
git diff --name-only --diff-filter=U   # resolve each listed file, then:
# >>> prepend THE CACHE REHYDRATION (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend THE CACHE REHYDRATION block" >&2; exit 1; }
resolved=src/example.ts   # repeat per resolved path
# harness.trailer composes a full "Co-Authored-By: ..." line already; pass it verbatim.
contract_root="$(git rev-parse --show-toplevel)"
worker_model=$("$agentkit/.shared/scripts/repo-config.sh" --repo-root "$contract_root" \
  --get AGENT_WORKER_MODEL 2>/dev/null || true)
[ -n "$worker_model" ] || { printf 'no worker model; re-run agent-preflight.sh\n' >&2; exit 1; }
worker_attribution=$("$agentkit/.shared/scripts/contract-read.sh" \
  --repo-root "$contract_root" --get harness.trailer --worker-model "$worker_model" 2>/dev/null || true)
[ -n "$worker_attribution" ] || { printf 'no harness= trailer; re-run agent-preflight.sh\n' >&2; exit 1; }
# Chained: no `set -e` here, so unchained these would push even after the commit
# helper or a verification failed -- what the rule below forbids.
"$agentkit/.shared/scripts/worktree-commit.sh" --message 'fix(example): resolve merge conflicts with the base branch' \
  --trailer "$worker_attribution" -- "$resolved" &&
"$agentkit/.shared/scripts/agent-run.sh" --cmd lint --if-declared &&
"$agentkit/.shared/scripts/agent-run.sh" --cmd test &&
git push   # upstream set in 0a; fork PRs push to the fork via gh pr checkout's config
```

Run only declared `agent-run.sh --cmd` commands — they run directly, with no approval step. Use a focused suite during red/green and the full suite before commit; never push without local verification. Commit-helper exit 2 requires the exact elevated retry. 2a/3a reuse this recipe whenever `base:` reads `stale=yes`, conflicting or not; a clean merge auto-commits — skip straight to `agent-run.sh --cmd test` then `git push`.

### 0c — Create the private review-artifact directory

Review payloads carry private source and review text. Create one randomly named `0700` run
directory, carrying its path forward as `RUN_DIR` in every later block; never substitute `/tmp`, a
PR-number-only path, or non-`0700` permissions:

```bash
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/review-remote-pr.XXXXXXXXXX") || exit 1
printf 'Review artifacts: %s\n' "$RUN_DIR"
```

Keep it for audit, remove only once triage and verification complete. Re-set it at the top of every
later block: `: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"`

---

## Step 1: Check

One helper call replaces the whole fetch-then-summarize cluster:

```bash
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' 'jq is not installed; evidence unavailable' >&2
    exit 1
fi
# >>> prepend THE CACHE REHYDRATION (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend THE CACHE REHYDRATION block" >&2; exit 1; }
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
"$agentkit/review-remote-pr/scripts/gh-pr-state.sh" \
  --pr "$PR" --repo "$REPO" --full --tmpdir "$RUN_DIR/state"
```

Pass `--repo` explicitly. CI state is data, not an error: unlike `gh pr checks` (exit `8` on
pending/failing), this stays at exit `0`; exit `1` = usage/API failure. `--full` writes five
PR-namespaced files under `$RUN_DIR/state` that Step 1a/5/6 re-read — **read full bodies before
triaging**, thread-less actionable content exists. `threads: truncated=yes` means paginate with an
`after:` cursor before trusting any count, never a clean zero.

**Step 1a — surface human review content:** route every item through the classifier; exclude
recognized providers, authoritative Bot/`[bot]` authors, and exact
`<!-- review-remote-pr:agent-doc|agent-reply -->` comments — **not** the `gh api user` login. Read
["$agentkit/review-remote-pr/references/provider-rules.md"](references/provider-rules.md) for the H/B presentation formats and
wait for an explicit per-item decision before acting.

## Step 1b (runs as 2b): Adversarial Review — ONCE, at the end of the draft phase

Apply this gate once as the LAST step of Phase A, after CI is green and conflicts are resolved.
Read ["$agentkit/review-remote-pr/references/adversarial-review.md"](references/adversarial-review.md) in full before running
or skipping — it carries materiality, attribution, external-service authorization/consent, the
exit-code table and one-shot `adversarial-run.sh --pr N --repo OWNER/REPO --run-dir DIR` contract;
the runner reads `harness=`/`peer-cli=` facts for selection and blind same-harness fallback. Pass
`--peer-cli-absent` only with `peer-cli= ... absent`.

**Spent-budget precheck (must precede launch).** Before starting any reviewer, run
`post-receipt.sh precheck` against the Step 1 PR-conversation artifact:

```bash
# Step 1 already fetched this file; do not make a second comments query here.
# >>> prepend THE CACHE REHYDRATION (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend THE CACHE REHYDRATION block" >&2; exit 1; }
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
receipt_comments="$RUN_DIR/state/pr_${PR}_issue_comments.json"
precheck_rc=0
"$agentkit/review-remote-pr/scripts/post-receipt.sh" precheck --comments "$receipt_comments" || precheck_rc=$?
case "$precheck_rc" in
    0)  printf '%s\n' 'adversarial review budget spent; do not rerun reviewer'; exit 0 ;;
    10) printf '%s\n' 'not spent — proceed to the adversarial review gate below' ;;
    *)  exit 1 ;; # evidence unavailable (missing jq, unreadable/invalid artifact) -- fails closed
esac
```

Do not treat a missing/unreadable artifact as an empty comment set — that is a **no-silent-skip**
failure; stop with evidence unavailable. A receipt marker is authoritative from the PR alone.

---

## Step 2: Fix CI Failures

**Step 1c — batch pushes:** review behavior after a push is provider configuration, not a
workflow guarantee — still batch each cycle's fixes into **one** push; never post
`@coderabbitai pause`/`resume`.

Diagnose the causal failure (`gh run view --log-failed "$run_id" | grep -E "FAIL|error|Error"`,
run ID from the `gh pr checks` URL column), then run the **Implementation-worker gate** above.
The worker verifies independently before its cycle push, through `agent-run.sh`:

```bash
# >>> prepend THE CACHE REHYDRATION (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend THE CACHE REHYDRATION block" >&2; exit 1; }
agent_run="$agentkit/.shared/scripts/agent-run.sh"
"$agent_run" --cmd lint --if-declared
"$agent_run" --cmd test
```

For red/green iterations the worker uses `"$agent_run" --cmd test --only NAME[,NAME...]` (forwards through the
repo's `AGENT_CMD_TEST_FOCUS` declaration); after the final tree change, the worker must run the unfocused `"$agent_run" --cmd test` once for the full-suite verdict
before worker publication. A successful run prints one `PASS:` line; a failure prints `FAIL(rc=N):`,
context, `note:` lines, matched errors, and the log path. **Never push without local verification passing.**

### Wait contract: one turn-free wait

Read ["$agentkit/.shared/wait-discipline.md"](../.shared/wait-discipline.md) in full before waits: it owns the
no-model-turn, bounds, and durable-state rules; Step 4 adds CI settlement specifics.

This loop keeps waits silent until terminal: background output wakes the orchestrator for a turn; log
heartbeats and emit one completion/expiry line.

### Adversarial-review receipt:

After all confirmed adversarial findings are fixed or explicitly declined, push those fixes; the
receipt is published **after fixes are pushed** and **before draft-phase-complete handoff**, as
exactly one durable top-level PR comment. Required for both a material review and a verified
trivial-diff skip — a review or skip without it is never complete. It records provider, model,
effort, mode (`cross-provider` or `blind fallback` + reason), `P1`/`P2`/total counts, one
`confirmed finding` line per finding (title, verdict, `fix commit` SHA(s) or `decline rationale`),
or the `verified-skip rationale` + oracle. The order is executable: `adversarial-run.sh` must
return `0` before `finding-ledger.sh add` records any disposition (exit `13` means the review
result is missing or incomplete), and receipt publication consumes that ledger. Create an empty
`$RUN_DIR/findings.ndjson` for a clean review or verified skip. `post-receipt.sh publish` derives it from RUN_DIR the same way `finding-ledger.sh` does, refusing evidence-unavailable and naming the expected path if RUN_DIR is bad. Run it
(only after the finding-fix push — this is the final Phase A action):

```bash
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
: "${PR:?re-set PR to the current pull request; shell state does not persist}"
: "${REPO:?re-set REPO to OWNER/REPO; shell state does not persist}"
# >>> prepend THE CACHE REHYDRATION (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend THE CACHE REHYDRATION block" >&2; exit 1; }
receipt_comments="$RUN_DIR/state/pr_${PR}_issue_comments.json"
# Repeat the ledger command once per confirmed outcome, after the runner returned 0:
"$agentkit/review-remote-pr/scripts/finding-ledger.sh" add --title 'SHORT_TITLE' --severity P1 --verdict fixed --sha SHA
"$agentkit/review-remote-pr/scripts/finding-ledger.sh" add --title 'OTHER_TITLE' --severity P2 --verdict declined --rationale 'RATIONALE'
publish_rc=0
RUN_DIR="$RUN_DIR" "$agentkit/review-remote-pr/scripts/post-receipt.sh" publish \
    --pr "$PR" --repo "$REPO" --comments "$receipt_comments" --require-pushed \
    --provider "$PROVIDER" --model "$MODEL" --effort "$EFFORT" \
    --mode "$MODE" --mode-reason "$MODE_REASON" --p1 "$P1_COUNT" --p2 "$P2_COUNT" \
    --agent-identity "$AGENT_IDENTITY" || publish_rc=$?
# The ledger owns titles, dispositions, SHAs, and rationales; the script owns
# every receipt byte, deriving findings.ndjson from RUN_DIR (--findings-file PATH overrides it). Pass --skip-rationale S --oracle S for a verified skip.
case "$publish_rc" in
    0)  : ;; # posted and byte-verified
    11) printf '%s\n' 'receipt already spent -- no second post, no rerun' ;;
    12) printf '%s\n' 'receipt refused: fixes are dirty or not reachable from origin' >&2; exit 1 ;;
    13) printf '%s\n' 'receipt refused: finding pipeline is out of order' >&2; exit 1 ;;
    *)  printf '%s\n' 'receipt publication failed' >&2; exit 1 ;;
esac
# Any other nonzero has already triggered a fresh live comment re-fetch inside
# post-receipt.sh. Do not retry from receipt_comments; inspect the fresh live comments first.
```

## Step 3 (Phase B): Wait for the user to decide the ready transition

**Never run `gh pr ready`.** The draft-to-ready flip is always the user's call.

When Phase A is done — CI green, conflicts resolved, every adversarial finding fixed or
declined-with-comment, every human item decided — report the draft-phase summary (Exit Report) and
wait per ["$agentkit/.shared/wait-discipline.md"](../.shared/wait-discipline.md) instead of spending model
turns on a `gh pr view` plus sleep/re-check loop. Then observe a real CodeRabbit review landing
(actionable-comments/walkthrough body, not just an ack). If none arrives, report it — do not infer
configuration or trigger one. If rate-limited, perform **bounded blocking re-check rounds** (~10 minutes each, up to ~90 minutes total): use
one blocking helper/harness wait to own the rounds, then escalate to the user. **Never trigger a review.**

---

## Step 4: Wait for CI

Wait in **bounded rounds** — never one unbounded wait:

```bash
# >>> prepend THE CACHE REHYDRATION (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend THE CACHE REHYDRATION block" >&2; exit 1; }
"$agentkit/review-remote-pr/scripts/gh-pr-state.sh" \
  --pr "$PR" --repo "$REPO" --wait-ci --rounds 4 --interval 60
```

Bounds 1–60 rounds, 1–3600 seconds; progress on stderr, the Step 1 digest on stdout. Do NOT grep
repo-specific check names; `SKIPPED`/`NEUTRAL` count as passing; `/coderabbit/i` checks are ignored
when deciding settlement but still counted in `pending=`. Still pending after the bounded rounds →
**stop and escalate**; do not keep raising `--rounds`. Never infer review behavior from a push.

---

## Step 5: Assess Automated-Review & Adversarial-Review Findings

Before assessing any saved artifact, prove its parser is available — a missing parser is a
blocked check and must never be summarized as “no findings.”

Use the provider-rules.md content loaded in Step 1a for the full cycle order (approved human
actions first → body nitpicks + Code Quality → one implementation-worker batch → post/verify
replies → CodeRabbit reply-settlement LAST), the VALID/INVALID/NITPICK recipes, the generic-B
and Code Quality handling, and the canonical reply/settlement command shapes.
Adversarial-review findings from `$RUN_DIR/adversarial.result.json` route through the same
assess → fix → document logic, documented in a **PR comment** (no thread to resolve). The cycle
ends with its single batched push (Step 1c); post declines before that push — a later full review
re-evaluates from scratch and can re-raise them. Root reviews pushed diff; never stages worker
handback files or uses `git add -A` (`.agent/` is untracked working state).

---

## Step 6: Evaluate and Repeat

Refresh every artifact with the same single call as Step 1 — no separate `gh pr checks`, no
hand-rolled GraphQL re-query:

```bash
# >>> prepend THE CACHE REHYDRATION (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend THE CACHE REHYDRATION block" >&2; exit 1; }
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
"$agentkit/review-remote-pr/scripts/gh-pr-state.sh" \
  --pr "$PR" --repo "$REPO" --full --tmpdir "$RUN_DIR/state"
```

The digest's `agent-docs: N eligible` line reports which unresolved threads are this workflow's
own marked agent-doc threads (see the provider-rules.md content loaded in Step 1a for the exact
resolution rule). If any CI failed, any automated-review thread/finding remains
unhandled, or any body nitpick or confirmed adversarial finding is unaddressed → back to Step 1
(max 3 full cycles — see The Loop's cap). If human-authored content lacks an explicit user
decision, surface the gate and wait; do not post, resolve, or claim readiness.

---

## Exit Report

**Draft-phase report (end of Phase A, before the Step 3 wait):**
```text
PR #N: draft phase complete — CI green, conflicts none,
Adversarial review [Claude Opus 5 | blind Codex-agent fallback (reason: <blockedReason>|absent)]: M findings, M handled.
Implementation worker: [<model> <effort> | worker=self — reason: <why>], six-step gate complete.
Human review: [none | H1 approved/replied/open | H2 awaiting confirmation].
Waiting for you to mark it ready — this skill will not trigger a review.
```

**Final report (loop exit):**
```text
PR #N: all CI green, N/N CodeRabbit threads handled, all body nitpicks handled,
GitHub Code Quality: [no findings | auto-cleared | dismissed with reasons | blocked],
CodeRabbit approval: [approved | not observable | no provider review observed],
Adversarial review [Claude Opus 5 | blind Codex-agent fallback (reason: <blockedReason>|absent)]: M findings, M handled.
Implementation worker: [<model> <effort> | worker=self — reason: <why>].
Human review: [none | H1 approved/replied/open, H2 declined/open | H3 awaiting confirmation].
[Ready to merge | Awaiting user confirmation; not claiming readiness].
```
(Identify which reviewer ran and any fallback reason; who wrote the code and its model/effort or
`worker=self` reason; every human-review item's decision, verified-reply state, and open-thread state.)

Then run **Backlog grooming** — read ["$agentkit/review-remote-pr/references/grooming.md"](references/grooming.md) in full —
before handing back. It proposes Ready candidates from the Backlog and never auto-promotes; it
no-ops silently when there is no board/scope for it, never failing the PR handoff.
