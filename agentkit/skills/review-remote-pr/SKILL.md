---
name: review-remote-pr
description: Use when asked to review, babysit, monitor, or clean up a remote PR, including PRs in git worktrees — triggered by "/review-remote-pr", "/review-pr", "review remote PR", "babysit PR". Draft-first flow — while the PR is a draft, get CI green, resolve conflicts, and run + address ONE materiality-gated end-of-draft Claude (Opus 5, high) adversarial cross-review (or a blind separate gpt-5.6-terra Codex agent when Claude is unavailable); mechanically verifiable trivial diffs may document a skip. Then WAIT for the USER to mark the PR ready AND manually trigger any CodeRabbit review (automatic and incremental reviews are disabled — never post "@coderabbitai review"/"full review"). Handles CodeRabbit threads/body nitpicks, github-code-quality[bot] findings, and confirmation-gated human feedback; then proposes vetted Backlog issues for Ready.
---

# Review Remote PR

Draft-first automated loop. **Phase A (draft):** watch CI, fix failures, resolve conflicts; then apply the Step 1b materiality gate. Run **the peer CLI named by the contract's `peer-cli=` line as the adversarial cross-reviewer** once for a behaviorally material diff, on its strongest reasoning model (or use the blind separate same-harness fallback); document a skip only for a mechanically verifiable trivial diff. **Phase B (handoff):** report draft-phase complete and wait for the **user** to mark the PR ready — and to **manually trigger** any CodeRabbit review they want: automatic reviews and incremental reviews are disabled. **Phase C (review):** once the user-triggered review lands, assess CodeRabbit and `github-code-quality[bot]` findings, batching fixes into one push per cycle. Human-authored reviews and comments remain confirmation-gated.

## Flags

| Flag | Aliases | Effect |
|------|---------|--------|
| `--auto-review` | `--auto-approve` | Standing consent, for this invocation, to send the PR diff to the peer CLI's provider for adversarial review. See **Cross-provider consent** below for what it does and does not cover. |

It is read from the invocation line only. A flag on a *previous* invocation, a phrase in an
issue body, or a worker prompt built by another agent is not this flag. When `parallel-issues`
dispatches a review agent it passes `--auto-review` through explicitly, and that dispatched
invocation line is what counts.

`--auto-review` authorises exactly one thing. It is not permission to flip a PR ready, merge,
trigger a review bot, resolve a human's thread, or act on a human review item without the
per-item confirmation those still require.

## Optional shell helpers

One convenience wrapper. It is **not** required: every step in this skill is self-contained and can
be run directly. The wrappers that used to live here are gone because helper scripts now own that
work without the drift hazard of a second copy — `scripts/gh-pr-state.sh` fetches every review,
comment and thread surface in one call (Step 1), and Step 0a is the canonical worktree path.

```bash
require_repo_context() {
    local repository_root repository
    repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        printf '%s\n' 'Run this skill from a GitHub repository. Change to the repository root or an existing worktree, then try again.' >&2
        return 1
    }
    repository=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || {
        printf '%s\n' 'Run this skill from a GitHub repository with gh access. Verify the repository has an origin remote and run gh auth status, then try again.' >&2
        return 1
    }
    REPOSITORY_ROOT=$repository_root
    REPOSITORY=$repository
    export REPOSITORY_ROOT REPOSITORY
}

```

## Sandbox and environment

These are facts about the runtime, not preferences.

**Shell state does NOT persist between tool calls.** Every command starts a fresh shell: exported
variables, `cd`, and anything you `source`d are gone. Each command must therefore be self-sufficient
— re-derive `REPO`/`PR` at the top of any block that uses them. That is precisely what
`.shared/scripts/agent-run.sh` exists for: it prepares the environment for **one** command and runs
it, so you never hand-export cache, CA-bundle, or `PYTHONPATH` variables and hope they survive to
the next call. Always invoke project/test/lint commands through it rather than exporting first.

**Every git write needs elevation — this is structural, not occasional.** Measured under the
`:workspace` permission profile: the working tree is writable, but `.git` and `.git/worktrees/<name>`
are mounted **read-only**, so `git add` fails with
`Unable to create '.../.git/worktrees/<name>/index.lock': Read-only file system`. This is the
default for a plain repository too; a linked worktree only makes it more visible. Expect to request
elevation for the *first* `git add`/`commit`/`worktree add` of a run and plan for it, rather than
discovering it through a failure. `.shared/scripts/worktree-commit.sh` probes both metadata
directories *before* staging anything and exits `2` naming the unwritable path, so nothing is half-
staged: obtain write permission for that path, then re-run the identical command. Exit `2` is an
environment condition, not a code problem — never treat it like exit `1`.

**The network is disabled inside the sandbox.** `CODEX_SANDBOX_NETWORK_DISABLED=1` is set and DNS
does not resolve, so every `gh` call, `git fetch`, and `git push` fails until the command is
escalated. That escalation is what the approval round-trips are buying — which is the real reason to
prefer one dense command (`gh-pr-state.sh`) over six chatty ones.

**Only the workspace is writable; the rest of the filesystem is readable.** Sibling directories,
`$HOME`, and parent directories can all be *read* but not written. So a worktree created beside the
repository cannot be written to, while one under the repository root can. Prefer an in-repo
`.worktrees/` path.

**A spawned agent cannot spawn another.** Nesting returns `no child-worker subagent capability is
available`, so only the root orchestrator can dispatch. Any agent that was itself spawned must do
its own implementation work — see the spawn-unavailable path in the implementation-worker gate.

**Package managers behind a corporate MITM CA need the system CA bundle.** `agent-run.sh` detects a
site CA and exports `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, and
`CURL_CA_BUNDLE` for the wrapped command, and exports `UV_SYSTEM_CERTS=1` for uv rather than splicing a
flag into its argv. Never work around a TLS failure by disabling verification.

**`$HOME`'s package-manager cache may be read-only.** `agent-run.sh` falls back to a writable cache
root (`XDG_CACHE_HOME`, `UV_CACHE_DIR`, `NPM_CONFIG_CACHE`, `PIP_CACHE_DIR`) and reports the
substitution as a `note:` line in its failure output.

### The environment contract

**Run `.shared/scripts/agent-preflight.sh` exactly ONCE, in Step 0a, and treat its printed block as
the environment contract for the whole run.** It prints a `skills= path=ABSOLUTE_PATH` record
first, then one `key=value` line per probe, in the fixed order `repo` / `branch` / `worktree` /
`base` / `config` / `git` / `gh` / `sandbox` /
`tls` / `caches` / `runners` / `harness` / `peer-cli`; diagnostics go to stderr. Read the block, carry it forward, and do **not**
re-probe those facts later — re-running `gh auth status`, re-detecting the base branch, or
re-testing writability is wasted turns. **Paste the block verbatim into any dispatched worker
prompt** so the worker inherits the same contract instead of rediscovering it.

It reports rather than blocks: a missing `gh`, an unreachable API, a read-only git dir, and an
unwritable cache all still exit `0` with the condition stated as a value. Only invalid usage
exits `2`.

Three lines change what this skill does:

- `config= present=yes …` — the repository declared its own facts in
  `.agent/config.env`, so the slug, base branch, and worktree root below come from a
  committed file rather than from probing. `present=no` is not an error; everything
  still works, it just costs the discovery calls.

- `gh= … project-scope=yes|no` — `no` means the token cannot move a Project item. The fix is
  `gh auth refresh -s project`. Surface that instead of discovering it through a failed board call
  during Backlog grooming.
- `peer-cli= <name> absent` — skip the Step 1b peer probe entirely and go straight to the blind same-harness
  fallback. `peer-cli= <name> present … probe=not-run` only proves the binary resolves on `PATH`; the
  helper's own preflight decides whether it can actually execute here.

A repository opts into its own command runner through exactly two mechanisms, checked in this
order and nothing else: the `AGENT_REPO_RUNNER` environment variable (absolute path to an
executable), then a committed `<git-toplevel>/.agent/runner` file whose first non-blank,
non-comment line is the runner path. `agent-run.sh` delegates to it when present. Never probe for a
vendor-specific tool path.

`agent-preflight.sh` creates `<worktree>/.agent/` (the contract file plus `agent-run.sh`'s logs).
That directory is untracked, so Step 0a adds it to the worktree's local excludes — a repo-local
change that never appears in a commit. `worktree-commit.sh` is already safe here because it stages
only the FILE arguments you give it; a careless `git add -A` is not.

## Automated review provider rules

Treat these as separate providers. Identify them from the comment/review author, not from a check name:

| Provider | Findings live in | Fixed finding | Inaccurate finding |
|---|---|---|---|
| CodeRabbit | Reviews, inline comments, and conversation bodies | Reply with the commit SHA, then resolve its review thread | Reply with a concrete rationale, then resolve its review thread |
| `github-code-quality[bot]` | Inline PR review comments and their review threads | Implement the suggested fix verbatim, reply with the commit SHA, push, and wait for the next Code Quality scan to auto-clear the finding | Use GitHub's **Dismiss finding** action and provide a specific reason; do not silently resolve the thread |
| Human reviewer | Reviews, inline comments, review threads, and conversation comments | Surface the exact feedback, proposed action, and draft reply; act and reply only after explicit user confirmation | Same confirmation gate; never resolve the thread |

Neither bot may be manually triggered: CodeRabbit reviews run only when the human starts one, and `github-code-quality[bot]` has no manual trigger at all — it re-scans on pushes per the repo's Code Quality configuration.

GitHub's public Code Quality REST API currently exposes finding retrieval, not a supported per-finding dismissal mutation. Use `gh` to inspect and reply, but do not invent an endpoint:

```bash
# Inspect Code Quality findings available through the public API (read-only).
gh api "repos/$REPO/code-quality/findings?state=open&per_page=100" \
  -H "X-GitHub-Api-Version: 2026-03-10"
# The PR finding comments and their IDs come from the Step 1 artifact — no re-query.
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
jq -r '.[] | "\(.id)\t\(.path)\t\(.line)\t\(.commit_id)"' \
  <"$RUN_DIR/state/pr_${PR}_code_quality_comments.json"
```

**Reply-body integrity gate:** after every automated reply, the created comment must be re-fetched by
its returned ID and its stored body compared byte-for-byte with the exact intended text. Do not
resolve or dismiss a finding until they match.

`scripts/gh-comment.sh` **is** the procedural implementation of that gate — do not hand-roll it.
It reads the body from a file (never from a shell string), posts it as JSON, re-fetches the stored
comment, and `cmp`s the exact decoded bytes. On success it prints one line
(`posted id=… url=… verified=exact`) and exits `0`. On any mismatch it prints a capped unified diff
to stderr, leaves stdout empty, and exits `1`. The safe caller rule is therefore: **resolve or
dismiss only when the helper printed a line on stdout AND exited `0`.** See Step 5 for the call
shapes (`--reply-to`, `--anchor`, `--update`).

## Human-review confirmation gate

Treat every review, inline comment, review thread, and PR conversation comment not authored by an explicitly recognized automated provider as **human-authored content**. This includes content whose author login equals the account returned by `gh api user --jq .login`: an authenticated `gh` session proves which account will post the agent's actions, not who authored earlier content.

When human-authored content appears at any point in the run:

1. Surface it immediately with a stable local label (`H1`, `H2`, ...), author, URL or comment ID, current resolution state, and the exact substantive text.
2. Show the agent's assessment, any proposed code change, and the exact draft reply. Wrap the draft in the required agentic attribution.
3. Ask the user to approve, edit, decline, or defer each labeled item. A generic "continue", silence, elapsed time, or approval of bot work is not confirmation.
4. Continue independent CI and automated-provider work when safe, but do not change code solely because of that human feedback and do not post or edit a response until the user explicitly confirms that item and its proposed handling.
5. After confirmation, perform only the approved action and post the exact approved reply. If the reply changes materially after approval, surface it again.
6. Fetch the stored reply and verify its body exactly matches the approved text. Correct a mismatch in place and verify again.
7. **Never call `resolveReviewThread` for a human-authored thread**, even after fixing the code or posting an approved reply. Resolution belongs to the human reviewer.

Batching several human items into one gate is allowed only when every item has its own label, proposed action, and draft reply so the user can approve them independently. If confirmation is unavailable, leave the items untouched, report them as `awaiting user confirmation`, and do not claim the PR is ready to merge.

Use `<!-- review-remote-pr:agent-doc -->` only on workflow-created bookkeeping threads and `<!-- review-remote-pr:agent-reply -->` on workflow-created replies. These markers identify individual agent-created comments; they never make a thread resolvable when it also contains unmarked human content. Never infer agent ownership from a GitHub login, commit author, PR author, or authenticated account.

## Inputs

- **PR number** (required) — passed as arg or ask once if missing
- **Repo** — infer from `git remote get-url origin`; override with `owner/repo` arg
- **Worktree** — reuse the existing worktree for the PR branch when present; otherwise create `$PR_WORKTREE` or a sibling `<repo>-pr-<PR>` worktree

## Implementation-worker gate (MANDATORY for every code change)

The PR-loop agent is the orchestrator: it inspects GitHub state, evaluates findings, owns human-confirmation gates, verifies replies, and performs final integration checks. It does **not** generate a batch of fixes on its own model. Whenever CI, conflicts, adversarial findings, CodeRabbit, Code Quality, or approved human feedback requires a code change, dispatch one real collaboration worker as the sole writer for that batch.

### Model and spawn contract

- Preferred code-writing model: **`gpt-5.6-luna`**, with automatic fallback to **`gpt-5.6-terra`**; both use `reasoning_effort: "high"`.
- Required role and isolation: **`agent_type: "worker"`, `fork_context: false`**.
- Paste the absolute worktree, branch rules, exact accepted findings, relevant logs, applicable repo instructions, and full six-step contract into the worker message.
- Never omit `model` or `reasoning_effort`; otherwise a worker can inherit the orchestrator (for example `gpt-5.6-sol medium` which would be not good and burn tokens).
- Select `gpt-5.6-luna` when advertised; otherwise select `gpt-5.6-terra` automatically at high reasoning. Stop before local edits only when neither model is advertised. Do not use the contextual parent as a hidden fallback.
- The Luna-to-Terra fallback requires no user authorization or pause. A model other than `gpt-5.6-luna` or `gpt-5.6-terra` still requires explicit user approval. Report the actual model/effort in the exit report.
- The Step 1b adversarial reviewer (peer CLI, strongest reasoning model) is read-only and **never satisfies this implementation-worker gate**.

Make the call; prose saying that a worker should exist is not a dispatch:

```text
multi_agent_v1__spawn_agent({
  agent_type: "worker",                                  // default | explorer | worker | report-synthesizer
  fork_context: false,                                   // false = initial prompt only; true = forks this thread
  model: "<selected gpt-5.6-luna or gpt-5.6-terra>",     // sol | terra | luna | gpt-5.5 | gpt-5.4
  reasoning_effort: "high",                              // low | medium | high | xhigh | max | ultra
  message: "<complete fix-batch prompt>"
})
// returns { agent_id, nickname }
```

Parameter names are exact. There is no `task_name` and no `fork_turns`; an invented key is silently
ignored, so a spawn that *looks* isolated can quietly inherit this thread. `fork_context: false` is
the only thing that makes a reviewer blind — verified: a worker spawned that way answered
`NO-PRIOR-CONTEXT` to facts established in its parent's turn.

Include the Step 0a environment-contract block verbatim in `message`, so the worker starts from the
same facts (worktree, base, cache/CA posture, runner) instead of re-probing them.

### Degraded path — `collaboration.spawn_agent` unavailable

A separate worker is **strongly preferred whenever the harness can create one**: it keeps the
orchestrator's context clean and keeps authorship separate from review. But the mandate has a
fallback, because a stalled loop is worse than a self-implemented batch — an agent that could not
spawn a worker once blocked, was closed, and its work was redone from scratch.

If `collaboration.spawn_agent` is genuinely unavailable — the call is not offered by the harness,
or multi-agent execution is disabled (for example `multi_agent = false`) — the loop agent MAY
implement the batch itself, under all of these conditions:

1. **Attempt the spawn first** and record the exact reason it was unavailable. An unavailable
   capability is a reason; "it seemed faster to do it myself" is not.
2. **Run the same six-step ultracode gate on yourself**, in order, producing the same evidence:
   Structs, Interfaces, Todos, Spike + Revert, Invariants, Implementation (TDD).
3. **Verify to the same standard** — inspect `base...HEAD`, run the repository checks through
   `agent-run.sh`, and push once per cycle.
4. **Label it in the exit report as `worker=self (spawn unavailable)`**, naming the reason. Never
   report a self-implemented batch as if a worker had been dispatched.

The degraded path is per-batch, not a permanent downgrade: retry the spawn on the next cycle.

### Required six-step ultracode loop

The worker reports and completes these gates in order. Stages 1–3 precede every edit; Stage 4 is the sole temporary-edit exception and is fully reverted before Stage 5; production implementation begins only in Stage 6:

1. **STRUCTS** — identify data structures introduced or reshaped by the accepted fixes.
2. **INTERFACES** — define changed contracts, inputs, outputs, and errors before production edits.
3. **TODOS** — map every affected file, call site, wiring point, test boundary, and verification command.
4. **SPIKE + REVERT** — for every code-bearing batch, rough-implement one bounded vertical slice, record what the design missed, then revert every spike change. `N/A` is allowed only when the approved action contains no code change.
5. **INVARIANTS** — fold spike learnings back into the design and state boundary invariants that become regression tests.
6. **IMPLEMENTATION (TDD)** — red → verify the expected failure → minimal green → refactor; run scoped checks per task and the full relevant suite before handoff, each through `agent-run.sh`.

The worker returns the six-stage status, commit SHA(s), changed paths, RED/GREEN evidence, full verification output summary, and clean-worktree status. The orchestrator independently inspects `base...HEAD`, runs the required verification through `agent-run.sh`, performs any elevated commands the platform requires, pushes once per cycle, and posts/rechecks GitHub replies. Resume the same worker with `followup_task` for corrections when possible; do not create concurrent writers in one PR worktree.

```bash
# Re-derive these at the top of EVERY shell call: env does NOT persist between
# tool calls, so nothing exported in an earlier call is still set here.
# The preflight contract covers both CODEX_HOME and CLAUDE_CONFIG_DIR plugin layouts.
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
resolver="$agentkit/.shared/scripts/repo-config.sh"
[ -x "$resolver" ] && eval "$("$resolver" --export)"
# Config first, forge second. Each block still re-derives its own values -- env
# does not persist between tool calls -- it just stops paying the network to.
REPO=${AGENT_REPO_SLUG:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
PR=42                                                        # replace with the PR number under review
export REPO PR
```

## The Loop

Repeat until exit condition met:

```
PHASE A — DRAFT (all mechanical work happens here; no review runs unless the user starts one)
  0. SETUP   — enter or create the PR worktree, run agent-preflight ONCE, merge base if conflicts
  1. CHECK   — one gh-pr-state.sh --full call: CI status + every review/comment surface +
               body nitpicks + provider state, as one digest plus durable artifacts
  1a. HUMAN  — surface human-authored content; gate every action/reply on per-item user confirmation
  2. FIX CI  — diagnose failures, dispatch the Luna ultracode implementation worker (or take the
               documented degraded path when spawn_agent is unavailable), verify its fix,
               commit/push once (pushes trigger no CodeRabbit review — none are
               automatic); repeat 1–2 until CI is green
  2b. ADVERSARIAL — as the LAST draft step (CI green, conflicts resolved): apply the materiality
               gate; for a material diff run one cross-harness review (Step 1b), then verify + fix
               confirmed findings; for a trivial mechanical diff document the verified skip

PHASE B — HANDOFF (user-gated)
  3. WAIT-READY — report draft-phase complete, then wait for the USER to mark the PR ready AND to
                  manually trigger any CodeRabbit review they want. NEVER flip it or trigger a
                  review yourself.

PHASE C — REVIEW (runs only after the user manually triggers CodeRabbit)
  4. WAIT    — wait for CI and the user-triggered review to land (gh-pr-state.sh --wait-ci,
               bounded rounds; escalate rather than wait forever)
  5. FIX     — apply approved human-review actions first (their threads stay unresolved); then triage
               body nitpicks and github-code-quality[bot] findings; then assess each CodeRabbit
               thread, fix or decline, reply AND resolve; batch all fixes into ONE push
  6. REPEAT  — while CI failures, unresolved automated threads, or unhandled findings remain
               (cap: 3 cycles). Another CodeRabbit pass on the pushed fixes happens only if the
               user re-triggers it — report that the fixes are pushed and let them decide.
  7. GROOM   — (after exit) fan out across the Backlog, propose Ready candidates for the next pickup
```

**NEVER trigger CodeRabbit reviews.** The org config has automatic reviews OFF and incremental reviews OFF — nothing (not the ready flip, not a push) starts a review; only the human does, manually. Do not post `@coderabbitai review`, `@coderabbitai full review`, `@coderabbitai pause`, or `@coderabbitai resume` — ever, in any phase, for any reason. With automation off there is nothing to pause; the only `@coderabbitai` text you may post is mentions inside replies or anchored threads. `github-code-quality[bot]` likewise gets no bot commands.

**Exit condition:** All CI checks pass; all CodeRabbit threads are resolved; all `github-code-quality[bot]` findings are either auto-cleared after a verified verbatim fix or explicitly dismissed with a reason; all CodeRabbit body-only nitpicks are fixed or explicitly declined and documented; every confirmed adversarial-review finding is fixed or declined with a documenting PR comment; and every discovered human-authored item has an explicit user decision (approve, edited approval, decline, or defer). Approved human replies are posted and verified but their threads remain unresolved. A deferred item does not restart the loop, but it must be reported and prevents a `Ready to merge` claim unless the user explicitly says otherwise. After exit, run **Backlog grooming** (below) before handing back.

**CodeRabbit auto-approve gate:** when the user has CodeRabbit's approval workflow enabled, it only approves once every thread *it* generated has BOTH a reply AND a resolved state, with no failing pre-merge checks. When disabled (an org/repo setting you often can't see in-repo), no formal approval ever comes — don't wait for one; "green" is threads resolved + nitpicks handled. Always reply first, then resolve, on every CodeRabbit thread, and handle body nitpicks BEFORE resolving threads (Step 5 ordering) so an approval can't fire while nitpicks are still outstanding.

**Human-reviewer content is confirmation-gated** — surface it during the run (Step 1a), act or reply only after explicit per-item user approval, never resolve its thread, and list its decision and open state in the exit report.

**Iteration cap: 3 full cycles.** CodeRabbit will keep finding new nitpicks on churned code — the loop does not naturally converge, and every extra pass costs the user a manual trigger. After the 3rd cycle, stop pushing: summarize every remaining item with your fix/decline stance and escalate to the user instead of iterating again.

---

## Step 0: Setup (ALWAYS run first, before any local edits)

### 0a — Enter the PR worktree

Get the PR's head branch name and move into the worktree dedicated to that branch. If another worktree already has the branch checked out, use it. Otherwise create a sibling worktree for this PR. This avoids switching branches in a worktree that may belong to another issue/PR.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
HEAD_BRANCH=$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq '.headRefName')
CROSS_REPO=$(gh pr view "$PR" --repo "$REPO" --json isCrossRepository --jq '.isCrossRepository')
echo "PR branch: $HEAD_BRANCH (fork PR: $CROSS_REPO)"

git fetch origin

EXISTING_WORKTREE=$(git worktree list --porcelain | awk -v branch="refs/heads/$HEAD_BRANCH" '
  $1 == "worktree" { wt = $2 }
  $1 == "branch" && $2 == branch { print wt; exit }
')

if [ -n "$EXISTING_WORKTREE" ]; then
  PR_WORKTREE="$EXISTING_WORKTREE"
else
  # In-repo, not a sibling: only the workspace is writable under the sandbox,
  # so ../<repo>-pr-N cannot be created. .worktrees/ is gitignored below.
  exclude_path="$(git rev-parse --git-path info/exclude)"
  worktree_root="${AGENT_WORKTREE_ROOT:-.worktrees}"
  grep -Fxq "$worktree_root/" "$exclude_path" 2>/dev/null ||
    printf '%s\n' "$worktree_root/" >> "$exclude_path"
  # A repository may name its own worktree root; .worktrees/ is the default.
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
  resolver="$agentkit/.shared/scripts/repo-config.sh"
  [ -x "$resolver" ] && eval "$("$resolver" --export)"
  PR_WORKTREE="${PR_WORKTREE:-$REPO_ROOT/${AGENT_WORKTREE_ROOT:-.worktrees}/pr-$PR}"
  if [ -e "$PR_WORKTREE" ]; then
    echo "Worktree path exists: $PR_WORKTREE"
    echo "Set PR_WORKTREE to an unused path, then rerun setup."
    exit 1
  fi
  if [ "$CROSS_REPO" = "true" ]; then
    # Fork PR: the head branch does NOT exist on origin. Let gh wire up the
    # fork remote and push target — plain `git push` then goes to the fork.
    git worktree add --detach "$PR_WORKTREE" && \
      ( cd "$PR_WORKTREE" && gh pr checkout "$PR" --repo "$REPO" )
  else
    git worktree add -b "$HEAD_BRANCH" "$PR_WORKTREE" "origin/$HEAD_BRANCH" 2>/dev/null || \
      git worktree add "$PR_WORKTREE" "$HEAD_BRANCH"
  fi
fi

# Guard the cd — if worktree creation failed you are STILL IN THE MAIN REPO;
# proceeding would edit/commit on whatever branch is checked out there.
cd "$PR_WORKTREE" || { echo "STOP: worktree missing at $PR_WORKTREE"; exit 1; }
[ "$CROSS_REPO" = "true" ] || git pull --ff-only origin "$HEAD_BRANCH"
git status --short
```

**Run all subsequent commands from `$PR_WORKTREE`.** Never switch branches or make PR edits in a worktree owned by another issue/PR. All commits for this PR go to `$HEAD_BRANCH`.

**The FIRST command inside the worktree is the environment preflight.** Run it once; its printed
block is the environment contract for the entire run (see *Sandbox and environment*):

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
"$agentkit/.shared/scripts/agent-preflight.sh" \
  --repo "$REPO" --worktree "$PR_WORKTREE"

# Keep the untracked .agent/ directory out of any accidental `git add -A`.
git_common_dir=$(git rev-parse --git-common-dir)
mkdir -p "$git_common_dir/info"
# `.agent/*`, never `.agent/`: excluding the directory stops git descending
# into it and defeats the .gitignore allowlist that keeps config.env committable.
grep -qxF '.agent/*' "$git_common_dir/info/exclude" 2>/dev/null ||
  printf '%s\n' '.agent/*' >>"$git_common_dir/info/exclude"
```

Carry the 10-line block forward for the whole run and **paste it verbatim into every dispatched
worker prompt**. Do not re-probe those facts later. Act on its decision lines immediately:
`project-scope=no` means Backlog grooming needs `gh auth refresh -s project`; `peer-cli= <name> absent` means
Step 1b skips the probe and goes straight to the blind same-harness fallback; `git= … writable=no` means to
expect `worktree-commit.sh` exit `2` on the first commit (an elevation problem with a documented
retry, not a code problem).

### 0b — Check for merge conflicts

```bash
MERGEABLE=$(gh pr view "$PR" --repo "$REPO" --json mergeable --jq '.mergeable')
echo "Mergeable: $MERGEABLE"
```

If `MERGEABLE` is `CONFLICTING`, merge the base branch before doing anything else. The PR branch is already published; preserving its history avoids a permission-gated force-push:

```bash
BASE_BRANCH=$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq '.baseRefName')
git fetch origin "$BASE_BRANCH"

# Integrate current base without rewriting published PR history
git merge "origin/$BASE_BRANCH"
```

If the merge has conflicts, resolve each conflicting file:

```bash
# List conflicting files
git diff --name-only --diff-filter=U

# Whole-file one-side picks — during a MERGE, sides have their usual meaning:
# "ours" = the PR branch, "theirs" = the base branch being merged.
conflicted=src/example.ts             # one path from the list above
git checkout --ours  "$conflicted"    # keep the PR side
git checkout --theirs "$conflicted"   # keep the base-branch side
```

For genuinely mixed files (different hunks go different ways), edit the file directly. If stripping markers mechanically, **use `sed` — not `python3 -c`** (double-quote quoting breaks in zsh) — and beware `/^=======$/` can also match decorative/setext lines in docs, so always run the verify grep:

```bash
conflicted=src/example.ts   # the file being resolved

# Keep HEAD (PR branch) side — discard incoming base-branch changes for this hunk
sed -i '/^<<<<<<< HEAD$/,/^>>>>>>> .*$/{ /^<<<<<<< HEAD$/d; /^=======$/,/^>>>>>>> .*$/d }' "$conflicted"

# Keep INCOMING (base branch) side — discard HEAD/PR changes for this hunk
sed -i '/^<<<<<<< HEAD$/,/^=======$/{ /^<<<<<<< HEAD$/d; /^=======$/d }; /^>>>>>>> .*$/d' "$conflicted"

# Verify no markers remain before staging (no output = clean)
if grep -n "^<<<<<<\|^=======\|^>>>>>>>" "$conflicted"; then
  printf '%s\n' 'Conflict markers remain — resolve before staging.' >&2
fi
```

Then commit the resolution through `worktree-commit.sh` and verify through `agent-run.sh`. The
commit helper probes both git metadata directories before staging, so an unwritable shared `.git`
surfaces as exit `2` with nothing staged instead of a half-applied index:

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
resolved=src/example.ts   # repeat for each resolved path

# The trailer names the agent that AUTHORED the commit, read from the
# contract rather than hardcoded: the same repository worked from the other
# CLI must credit that CLI. Deliberately NOT exported -- a child process
# derives its own trailer from its own harness, never inherits this one.
AGENT_TRAILER=$(sed -n 's/^harness=.*trailer="\([^"]*\)".*/\1/p' "$contract")
[ -n "$AGENT_TRAILER" ] || { printf 'no harness= trailer; re-run agent-preflight.sh\n' >&2; exit 1; }
"$agentkit/.shared/scripts/worktree-commit.sh" \
  --message 'fix(example): resolve merge conflicts with the base branch' \
  --trailer "Co-Authored-By: $AGENT_TRAILER" \
  -- "$resolved"

# Repository verification — always wrapped, never hand-exported.
# Named, not hardcoded: the repository declares what "lint" and "test" mean in
# .agent/config.env, or its .agent/runner resolves them.
"$agentkit/.shared/scripts/agent-run.sh" --cmd lint --if-declared
"$agentkit/.shared/scripts/agent-run.sh" --cmd test
```

`--cmd NAME` resolves through the repository's own declaration — `AGENT_CMD_LINT` in
`.agent/config.env`, else its `.agent/runner` invoked as `runner lint`. If the repository declares
neither, `agent-run.sh` exits `1` naming the key to add; surface that to the user rather than
guessing a command.

**Command-trust gate:** `--cmd` commands need a recorded human approval
(`agent-run.sh --approve`, terminal-only). When the invocation that dispatched this loop was
explicitly unattended (parallel-issues `--yolo`), its prompts carry `--yolo` on every
`agent-run.sh` line, which skips the gate for that invocation, loudly, recording nothing.
Refused as `unapproved repository command` without that flag: report BLOCKED. Never forge
the approval — no pseudo-terminals, no piped `y`, no hand-written trust records.

Exit `2` from the commit helper means "obtain write permission for the named path
and re-run the identical command" — it is safe to retry verbatim.

Then plain-push:
```bash
git push   # upstream set in Step 0a; fork PRs push to the fork via gh pr checkout's config
```

Wait for GitHub to recalculate mergeability (`MERGEABLE` → `MERGEABLE`) before proceeding to Step 1.

---

### 0c — Create the private review-artifact directory

Review payloads contain private source and review text. Create one run directory with a random name
and carry the printed absolute path forward as `RUN_DIR` in every later command block. Keep it for
the audit trail; remove it only after all triage and verification are complete.

```bash
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/review-remote-pr.XXXXXXXXXX") || exit 1
chmod 700 -- "$RUN_DIR" || { printf 'cannot secure %s\n' "$RUN_DIR" >&2; exit 1; }
printf 'Review artifacts: %s\n' "$RUN_DIR"
```

Every artifact path below is derived from this directory. Do not substitute `/tmp`, a PR-number-only
path, or a directory with permissions other than `0700`. `gh-pr-state.sh --full` enforces the same
boundary and writes artifact files with a private umask.

Shell state does not persist between tool calls. At the start of **every later command block** that
uses this directory, re-set `RUN_DIR` to the absolute path printed above; the guard in each block
then fails before any path is used if you forgot:

```bash
RUN_DIR=/absolute/path/printed-by-step-0c
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
```

---

## Step 1: Check

One helper call replaces the whole fetch-then-summarize cluster. `gh-pr-state.sh --full` fetches
every surface once, writes the durable artifacts the later steps read, and prints a compact digest
instead of dumping JSON into your context:

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
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
"$agentkit/review-remote-pr/scripts/gh-pr-state.sh" \
  --pr "$PR" --repo "$REPO" --full --tmpdir "$RUN_DIR/state"
```

Pass `--repo` explicitly from inside a worktree: it saves a round trip and removes any
remote-detection ambiguity. The digest is one fact per line:

```text
pr=42 draft=true mergeable=MERGEABLE head=feat/issue-NNN sha=abc1234
ci=3/6 failing pending=2 failing=1
threads: coderabbit=2 unresolved  code-quality=1 open  human=3
nitpicks: 1 unhandled
alerts: code-scanning open=0
saved: $RUN_DIR/state/pr_42_{reviews,comments,issue_comments,threads,code_quality_comments}.json
```

CI state is data, not an error: unlike `gh pr checks` (which exits `8` on pending/failing and can
cancel sibling parallel calls), a failing or pending run leaves this helper at exit `0`. Exit `1`
means a usage or API failure, and the message names the failing endpoint.

### The artifacts

`--full` writes exactly these five PR-namespaced files beneath the private `RUN_DIR/state` directory,
which Step 1a, Step 5, and the Step 6 sweep re-read:

- `$RUN_DIR/state/pr_${PR}_reviews.json` — every review submission, including body-embedded nitpicks
- `$RUN_DIR/state/pr_${PR}_comments.json` — every inline review comment, with the IDs Step 5 replies to
- `$RUN_DIR/state/pr_${PR}_issue_comments.json` — top-level PR conversation comments
- `$RUN_DIR/state/pr_${PR}_threads.json` — the raw GraphQL `reviewThreads` response; thread node IDs look
  like `PRRT_kwDO...` and this file persists for the Step 5 resolution calls
- `$RUN_DIR/state/pr_${PR}_code_quality_comments.json` — the `github-code-quality[bot]` subset of the inline
  comments, derived locally from the already-fetched data at no extra API cost

Keep any temp file you add beneath `RUN_DIR`; the random `0700` directory prevents concurrent loops
from colliding. **Read the full bodies from these artifacts before triaging** —
review bodies, inline comment bodies, and PR conversation comment bodies can each carry actionable
content that has no review thread attached, which a thread-only view misses.

**Pagination is handled, and it matters.** REST list endpoints default to 30 per page sorted
OLDEST-first, so an unpaginated fetch silently drops the *newest* reviews on a chatty PR; the helper
paginates every list endpoint. GraphQL review threads are requested `first: 100`; when the response
is truncated the digest appends `truncated=yes` to the `threads:` line and every count on it becomes
a lower bound. Treat `truncated=yes` as "page with an `after:` cursor before trusting any count" —
never as a clean zero.

### Provider identity — why the author matters

Only explicitly recognized automated providers get provider-specific automatic handling: CodeRabbit
(login contains `coderabbit`) and `github-code-quality[bot]`. **Every other author is human**,
including the account the authenticated `gh` session posts as — an authenticated session proves
which account *will* post the agent's actions, never who authored earlier content. The reserved
`<!-- review-remote-pr:agent-... -->` markers identify individual workflow-created comments and
nothing else; never infer agent ownership from a login, a commit author, or the PR author.

The digest's counts follow exactly that rule. `human=N` is any unresolved thread carrying at least
one comment that is neither a recognized bot nor marked — so a non-zero value is your Step 1a
queue, and a bot-originated thread a human replied in counts as human.

`nitpicks: N unhandled` is a **mechanical proxy**, not a judgement: CodeRabbit review bodies plus PR
conversation comment bodies matching /nitpick/i or carrying the broom emoji, minus the anchored
threads this workflow already opened to document them (`<!-- review-remote-pr:agent-doc -->`).
Inline review comments are deliberately excluded — they live in review threads and are already
counted on the `threads:` line, so counting them here would make the number unreachable. Working
Step 5 properly drives it to `0`.

`alerts: code-scanning n/a` means the endpoint returned 403/404 — typically code scanning is not
enabled on the repository, or the token lacks `security_events`. It is not a failure and never
changes the exit code.

---

## Step 1a: Surface human review content and wait for confirmation

Inspect the complete paginated review, inline-comment, issue-comment, and review-thread dumps from Step 1. Exclude only:

- explicitly recognized automated-provider authors such as CodeRabbit and `github-code-quality[bot]`;
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

---

## Step 1b (runs as 2b): Adversarial Review — ONCE, at the end of the draft phase

Apply this gate once as the LAST step of Phase A, after CI is green and conflicts are resolved.
Size alone never decides: a two-line behavioral authorization change is material; a mechanically
verified immutable SHA refresh can be trivial; a broad refactor is material even when each edit is
small.

**Run the adversarial review** when the diff changes runtime behavior, API/schema/migration
contracts, authorization/security boundaries, persistence/concurrency, dependency behavior,
workflow logic, or user-visible accessibility/reliability. Also run it whenever the user asks.

**Document a skip** only when every changed line is mechanically verifiable and low-judgment, such
as comments/formatting, generated output with its authoritative parity check, or an immutable
reference refresh whose upstream identity and intended equivalence were independently verified.
Record the exact oracle that replaces model review. A line-count threshold is never an oracle.

For a material diff, run one high-effort pass and never re-run it after pushing its fixes. Preferred
reviewer: the **peer CLI named by the contract's `peer-cli=` line**, on its strongest reasoning
model, unless the user requested a specific one. A review from the CLI you are already running
is not independent -- harness-allow: the pairing is the whole point of a cross-harness review.

### Attribution across the review boundary

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

### External-service authorization

A cross-harness review sends the PR diff to an external model-provider service. This is a
cross-provider transfer of the diff's filenames and code. Repository ownership, maintainer
status, local filesystem access, or invoking this skill is not consent to disclose that content.

### Cross-provider consent — first send per session

Before the first cross-provider send in a session, disclose the transfer and obtain an explicit
confirmation. The disclosure must name:

- the source payload: the PR diff, including its filenames and code;
- the destination provider and CLI from the `peer-cli=` contract (for example, Anthropic via
  Claude or OpenAI via Codex); and
- the purpose: one adversarial review of that diff.

Ask a direct yes/no question such as: `This review will send the PR diff to <provider> via
<peer CLI> for adversarial analysis. Do you consent to that transfer for this session? (yes/no)`.
Proceed only after an unambiguous affirmative answer to that question. An earlier request to run
the skill, repository ownership, or an ambiguous response does not satisfy this gate.

#### `--auto-review` — consent given in advance

`--auto-review` (alias `--auto-approve`) on the invocation line answers the question above for
this invocation, before it is asked. It is consent from the user in the user's own words, so
treat the gate as satisfied and **do not stop to ask**. Stopping anyway is the specific failure
the flag exists to remove: an unattended run that halts on a question nobody is present to
answer has not been careful, it has just stalled.

The rest of the gate stands unchanged:

- **Still disclose.** Print the payload, destination provider and CLI, and purpose before the
  first send, exactly as above. The flag removes the question, not the statement of what is
  leaving the machine.
- **Still record.** Write the same record with the origin noted:
  `cross_provider_consent=<provider>;scope=PR-diff;payload=<payload-id>;status=granted;source=--auto-review`.
- **Still scoped to this invocation.** It does not carry into a later session, a different
  provider, or a different repository.
- **Still refuses a repository the user does not own.** `--auto-review` is the user consenting
  to disclose their own code. It cannot consent on behalf of whoever owns someone else's. For
  a repository the user does not own, ask regardless of the flag.
- **Still fails closed.** If the record cannot be written, or the destination cannot be
  identified from `peer-cli=`, do not send. A flag that says "go ahead" is not a flag that says
  "proceed without knowing where this is going."

Without the flag, the interactive question above is required. Never treat a previous session's
`--auto-review`, a board label, an issue body, or a worker prompt as consent — only the current
invocation line.

Before sending, derive a payload identity from the PR number and SHA-256 hash of the exact diff
bytes to be sent. After confirmation, record
`cross_provider_consent=<provider>;scope=PR-diff;payload=<payload-id>;status=granted` in the
active session task state. Reuse that record only for a retry of the exact same payload to the
same provider and scope, so polling or retries do not create repeated prompts. If the destination
provider, PR, or diff changes, obtain confirmation again. If confirmation is missing,
declined, or cannot be recorded, **do not send the diff**; report the gate as blocked and wait for
user direction rather than silently substituting another external reviewer.

### Availability → pick the reviewer

**Read the Step 0a environment contract; do not re-probe.** Its `peer-cli=` line already decides this:

- `peer-cli= <name> absent` → **skip the probe entirely** and run the blind same-harness fallback below. Do not
  spend an agent lifecycle discovering that the peer CLI cannot start. This is not a blocked gate — the
  fallback reviewer still runs the gate.
- `peer-cli= <name> present … probe=not-run` → the binary resolves on `PATH`, which is **not** proof it can
  execute in this sandbox. Continue to the probe; the helper's own preflight settles it.

### Environment-blocked (exit 3) vs a real failure (exit 1)

`claude-adversarial-review.sh` separates "Claude cannot run here" from "the review ran and the
answer is no". **Branch on the exit code, never on message text:**

| rc | Meaning | What you do |
|---|---|---|
| `0` | The review completed and every invariant held | stdout is exactly one JSON result object — consume the verdict |
| `3` | **Environment-blocked**: Claude cannot run here at all, so no verdict is obtainable | stdout is a blocked JSON object carrying `blockedReason`, `detail`, and `"fallback":"blind-codex-agent"`. Take the blind same-harness fallback **immediately**. Do not retry, do not re-dispatch the agent, and **never report the gate as BLOCKED for this reason** |
| `1` | A genuine failure — usage error, or the harness ran and an invariant/verdict check said no | stdout is **empty**; the reason is on stderr. Do not parse stdout as JSON on this path. *This* is a blocked gate: report it blocked, never `no_findings` |

`blockedReason` is a closed vocabulary: `peer-cli-missing`, `exec-denied`, `network-unreachable`,
`unauthenticated`, `budget-exhausted`, `cli-contract-missing`. Anything else is a helper bug.
`budget-exhausted` is the single exit-3 class where raising `--max-budget-usd` and re-running is a
legitimate response; for every other reason, retrying only burns turns.

### Tested one-shot invocation and monitoring

Use `scripts/claude-adversarial-review.sh`, under Bash. It implements the vendor's documented
programmatic pattern (`--print`, piped diff input, `stream-json --verbose
--include-partial-messages`, `--json-schema`), reports condition state every `--poll-seconds`, and
enforces a total-duration ceiling with `--max-duration-seconds` in addition to Claude's hard
`--max-budget-usd` spend cap. It resolves the executable itself (`$CLAUDE_EXECUTABLE`, else the
first `claude` on `PATH`); pass `--claude PATH` only for an install that is not on `PATH`.

**Stream contract:** stdout carries **exactly one** JSON object — the completed result, or the
blocked object on exit `3`. Progress objects go to **stderr**, one per `--poll-seconds`. Capture
stdout directly (`>"$verdict_path"` or `verdict=$(…)`); there is no stream to fold with `jq -s last`,
and do not redirect stderr to `/dev/null` if you want the liveness signal.

The helper preflights the installed CLI and blocks before sending the diff unless the tested
isolation/streaming flags are present; do not silently drop a missing flag to support an older CLI.
It then verifies `system/init`: the requested model must initialize, the tool manifest must contain
exactly `StructuredOutput`, and no MCP server may load. Do not add `--disallowedTools '*'` — it
removes the internal `StructuredOutput` tool, yielding exit `0` with no structured verdict. Plugin
metadata may appear in `system/init`, but plugin tools must not appear in the tool manifest. The
advertised `--safe-mode` contract disables project instruction files, skills, plugins, hooks, MCP
servers, custom commands/agents, styles, workflows, and other customizations; the helper
additionally starts the reviewer in a new empty temp directory rather than the PR worktree.

Run a minimal probe once per review run (or whenever the CLI version/model/flags change) before
sending a real diff. A probe is complete only when it returns a deliberate P1 finding, valid
structured output, verified isolation, the initialized model in non-empty `modelUsage`, and exit
`0`; a requested full `claude-*` id must match the initialized model exactly. Probes are cheap —
`--max-budget-usd 0.25` is ample.

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
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
helper="$agentkit/review-remote-pr/scripts/claude-adversarial-review.sh"
reviewer_model='claude-opus-5'
reviewer_effort='high'

base_branch=$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq '.baseRefName')
git fetch origin "$base_branch" || {
    printf 'Could not fetch origin/%s\n' "$base_branch" >&2
    exit 1
}

diff_path="$RUN_DIR/adversarial.diff"
# A blind reviewer has no repository, so it needs surrounding context -- but the
# width is the single largest cost lever in this whole gate, and it is charged to
# whichever account you have least headroom on. Measured on a 3-file/9-hunk change:
# -U3 1.0x, -U10 1.9x, -U25 3.7x, -U80 10.4x, where -U80 emitted 77% of the full
# text of every touched file. -U25 keeps real context at ~a third of -U80's cost.
# Raise it only for a diff whose hunks genuinely need more surrounding code.
git --no-pager diff --find-renames --unified=25 "origin/$base_branch...HEAD" >"$diff_path" || {
    printf '%s\n' 'Could not build the adversarial-review diff.' >&2
    exit 1
}

probe_out="$RUN_DIR/claude_probe.json"
probe_transcript="$RUN_DIR/claude_probe.ndjson"

probe_rc=0
"$helper" --mode probe --model "$reviewer_model" --effort "$reviewer_effort" \
    --transcript "$probe_transcript" --poll-seconds 120 --max-duration-seconds 900 --max-budget-usd 0.25 \
    >"$probe_out" || probe_rc=$?

case "$probe_rc" in
  0) printf '%s\n' 'probe ok — proceed to the review pass' ;;
  3) printf 'environment-blocked (%s) — take the blind same-harness fallback now; do not retry\n' \
       "$(jq -r '.blockedReason' <"$probe_out")" >&2 ;;
  *) printf '%s\n' 'probe failed on its own terms — report the adversarial gate as BLOCKED' >&2 ;;
esac
```

Only on `probe_rc` `0`, run the review pass:

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
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
helper="$agentkit/review-remote-pr/scripts/claude-adversarial-review.sh"
reviewer_model='claude-opus-5'
reviewer_effort='high'

transcript="$RUN_DIR/claude.ndjson"
verdict_path="$RUN_DIR/adversarial.result.json"

# stdout = one JSON object (verdict, or the blocked object on rc 3).
# stderr = one progress object per --poll-seconds.  --transcript = raw NDJSON for auditing.
review_rc=0
"$helper" --mode review --model "$reviewer_model" --effort "$reviewer_effort" \
    --diff "$diff_path" --transcript "$transcript" \
    --poll-seconds 120 --max-duration-seconds 900 --max-budget-usd 5.00 >"$verdict_path" || review_rc=$?
printf 'adversarial-review rc=%s verdict=%s transcript=%s\n' \
    "$review_rc" "$verdict_path" "$transcript"
```

Launch the helper through an asynchronous executor and check its yielded process/cell at least as
often as `--poll-seconds`. Each stderr progress record is one JSON object reporting `runnerPid` (the
helper's own PID, not the reviewer's), `elapsedSeconds`, `secondsSinceLastEvent`, `eventCount`,
`lastEvent`, and `transcriptBytes`. Continue while the process is alive, but honor the helper's hard
`--max-duration-seconds` ceiling: a duration breach is a blocked review, never `no_findings`. Silence
is a diagnostic warning until that ceiling; do not shrink the diff to the last commit merely to meet
an estimate.

Do not accept plain prose or exit `0` alone. Completion requires all of: verified `system/init`, a
final `result/success` event, `is_error == false`, a valid `structured_output` verdict, and process
exit `0` — the helper enforces every one of these, which is why exit `1` means the gate is blocked
and exit `3` means the environment is. Preserve the NDJSON transcript either way. Report both the
requested/initialized model and every model in `canonicalModels`/`modelUsage`; an auxiliary small
model may be disclosed alongside the requested primary model.

Do not invoke `claude ultrareview`: it is a different nested orchestration surface. This workflow
needs one blind diff-only reviewer with deterministic output and monitoring.

**Fallback — blind Codex review.** Take this path when the Step 0a contract said `peer-cli= <name> absent`,
when the helper exited `3` (any `blockedReason`), or when external-service authorization is absent.
There are two ways to run it; prefer the first.

**Preferred — a separate in-harness agent.** Start a **separate agent in the CLI you are
already running** on
`gpt-5.6-terra` at `xhigh` with no inherited turn history or project context (`fork_context=false`).
Its entire prompt contains only the review rubric below and the explicit PR diff — never the issue
number/body, repository name, branch/worktree path, design docs, ADRs, goals, PR description, or
previous findings. Instruct it not to use tools or read files. Blindness is mandatory: it judges
only what the diff does. This is cheaper than the CLI: a fresh `codex exec` process re-sends its
whole base instruction set (measured at ~43k input tokens for even a one-word reply).

**When in-harness spawn is unavailable** — the same condition as the degraded path above — use
`scripts/codex-adversarial-review.sh`, the Codex twin of the Claude helper. Same `--mode`,
`--model`, `--effort`, `--diff`, `--transcript` flags; same `0` / `1` / `3` exit codes; same split
of progress-on-stderr and one result object on stdout. It enforces blindness mechanically rather
than by instruction: `--sandbox read-only`, `--ephemeral`, `--ignore-user-config` (no user MCP
servers or settings), `--ignore-rules` (no `AGENTS.md` discovery), and a throwaway non-repo working
directory, with the verdict constrained by `--output-schema`.

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
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
helper="$agentkit/review-remote-pr/scripts/codex-adversarial-review.sh"
diff_path="$RUN_DIR/adversarial.diff"
verdict_path="$RUN_DIR/adversarial.result.json"
"$helper" --mode review --model gpt-5.6-terra --effort xhigh \
    --diff "$diff_path" \
    --transcript "$RUN_DIR/codex.jsonl" --max-duration-seconds 900 --max-tokens 400000 >"$verdict_path" || {
    printf '%s\n' 'Blind same-harness review did not complete; report the gate as blocked.' >&2
    exit 1
}
jq '{verdict: .verdict.verdict, findings: .verdict.findings, tokenUsage}' <"$verdict_path"
```

Two asymmetries against the peer-CLI path (harness-allow: comparing the two is the subject), both reported in the result object rather than hidden:
`codex exec` exposes no provider spend flag, so the helper applies a hard observed-token ceiling
with `--max-tokens` as well as a total-duration ceiling with `--max-duration-seconds`; both are
reported as safety failures rather than accepted verdicts. Its event stream carries no model field,
so the initialized model cannot be verified the way Claude Code's `system/init` allows
(`modelVerification: "unsupported-by-codex-exec"`). It reports the observed `tokenUsage` and the
configured/used token ceiling in the result object.

```text
Adversarially review the following diff BLIND. You have no issue, spec, ADR, goal, or project context by design. Do not use tools or read files. Find only concrete correctness, security, reliability, or contract regressions. Rank findings [P1]/[P2], cite file:line, explain the failure scenario, and suggest the smallest safe fix. Ignore style-only preferences.

<explicit diff only>
```

Capture the separate agent's findings in the private run directory at the neutral shared result
path (`$RUN_DIR/adversarial.result.json`), using the same nesting
(`.verdict.verdict`, `.verdict.findings[]` with `priority`), so the Step 5 routing below is
identical. If the harness cannot create a separate no-history agent, *then* report the
adversarial review as blocked; do not substitute the parent agent's contextual self-review.

(Both paths land findings in the same verdict path so the Step 5 routing below is identical.)

### CodeRabbit state check (informational — never a trigger decision)

A green "CodeRabbit" status check is NOT proof a review happened. Detect the real signal in the comment **body** (rate-limit warnings and bare "✅ finished" acks both leave the check green):

```bash
# Re-set RUN_DIR as shown in Step 0c when this is a separate shell call.
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
# Reads the Step 1 artifact; no extra API call. Comments arrive oldest-first, so
# the LAST signal wins — a stale walkthrough from an earlier cycle must not mask
# a rate-limit on the CURRENT trigger.
jq -r '
  map(select((.user.login // "") | test("coderabbit"; "i")) | (.body // ""))
  | reduce .[] as $b ("none";
      if   ($b | test("actionable comments posted|<summary>walkthrough"; "i")) then "reviewed"
      elif ($b | test("review limit reached|rate limit"; "i"))                 then "rate-limited"
      else . end)
  | "CodeRabbit state: " + .
' <"$RUN_DIR/state/pr_${PR}_issue_comments.json"
```

- `reviewed` → a user-triggered review posted real findings; work its items (Phase C Step 5).
- `none` → the user has not triggered a review yet (automatic and incremental reviews are disabled — silence is the default state, not an outage). Do NOT post any review command; continue the current phase and leave triggering to the user.
- `rate-limited` → the user's trigger got throttled; it auto-retries when the fair-usage window refreshes (no re-push, no command needed). Wait with long bounded rounds (Step 4). Never advise buying credits — the throttle self-resolves.

### Read the verdict

The captured stdout is **exactly one** JSON object — no stream to fold, so no `jq -s last`. The
verdict payload is **nested**: `.verdict.verdict` is the `findings`/`no_findings` string and
`.verdict.findings` is the array. The raw NDJSON transcript stays beside it for auditing.

```bash
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
verdict_path="$RUN_DIR/adversarial.result.json"

# Success path (rc 0) only. rc 3 -> read .blockedReason and take the blind Codex
# fallback; rc 1 -> stdout is empty and the reason is on stderr. See the table above.
jq '{verdict:  .verdict.verdict,
     p1_count: ([.verdict.findings[]? | select(.priority == "P1")] | length),
     findings: .verdict.findings,
     requestedModel, initModel, canonicalModels, totalCostUsd}' <"$verdict_path"
```

### Evaluate — then route into Step 5 (don't auto-apply)

Verify each finding against the actual code before acting. The reviewer can overstate severity, overlap with another provider, or miss things — cross-reference, downgrade overstated severities, drop false positives. Confirmed findings flow through the **same** assess → fix → document logic as automated-review items (Step 5). They have no GitHub review thread, so document each outcome (fixed + commit SHA, or declined + rationale) in a **PR comment** (`gh pr comment $PR --repo $REPO --body=...`) — there is nothing to `resolveReviewThread`.

---

## Step 1c: Batch pushes (tidiness — pushes trigger nothing)

With automatic and incremental reviews disabled, pushes never trigger a CodeRabbit review in any phase — there is no quota mechanic to manage and nothing to pause. Still batch each cycle's fixes into **one** push: the user triggers reviews manually, and a settled branch state means their trigger reviews the whole batch instead of a moving target. Never post `@coderabbitai pause`/`resume` — with automation off they are meaningless, and all bot commands stay banned.

---

## Step 2: Fix CI Failures

```bash
# Take the run ID from the gh pr checks URL column (.../actions/runs/<ID>)
run_id=1234567890
gh run view --log-failed "$run_id" 2>&1 | grep -E "FAIL|error|Error" | head -50
```

Diagnose the causal failure and define the accepted fix batch. Then run the **Implementation-worker gate** above: dispatch the Luna worker (or take the documented degraded path when `spawn_agent` is unavailable), require its six-step evidence and commit, and inspect the diff.

Then verify independently, before the single cycle push. Route every verification through `agent-run.sh` — it prepares caches, CA bundles and `PYTHONPATH` for that one command, so nothing has to be exported and nothing leaks between calls:

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
agent_run="$agentkit/.shared/scripts/agent-run.sh"

# Ask by name; the repository owns the definition.
"$agent_run" --cmd lint --if-declared
"$agent_run" --cmd test
```

A successful run prints one `PASS:` line and suppresses the output into `.agent/logs/`. A failure prints `FAIL(rc=N):`, the `cwd`/`runner` context, any environment `note:` lines (cache fallback, `UV_SYSTEM_CERTS`), up to 20 matched error lines, and the full log path — so a failing run needs no follow-up turn to explain itself. `agent-run.sh` passes the wrapped command's exit status through unchanged; its own usage errors are distinguishable because they print `agent-run: error: …` and no `PASS`/`FAIL` line.

If the repository declares its own runner (`AGENT_REPO_RUNNER`, or a committed `.agent/runner`), `agent-run.sh` execs it and that runner owns the output — expect no `PASS`/`FAIL` line in that case.

**Never push without local verification passing.**

---

## Step 3 (Phase B): Wait for the user to flip ready and trigger the review

When Phase A is done — CI green, conflicts resolved, every confirmed adversarial-review finding fixed or declined-with-comment, every discovered human item decided — report the draft-phase summary to the user (see Exit Report) and **wait**. The user, not you, marks the PR ready for review AND manually triggers any CodeRabbit review they want: with automatic reviews off, the flip alone starts nothing.

```bash
# Long-interval poll; run as a background task so the wait survives turns.
# NEVER gh pr ready "$PR" — the flip is the user's call, always.
while [ "$(gh pr view "$PR" --repo "$REPO" --json isDraft --jq .isDraft)" = "true" ]; do
  sleep 120
done
echo "PR #$PR marked ready — waiting for the user-triggered CodeRabbit review (if any)"
```

Then watch for a real CodeRabbit review landing (actionable-comments/walkthrough body, not just an ack — Step 1b state check). If none arrives, that's the expected default — the user may not want a bot pass at all; ask rather than assume, and never trigger one yourself. If the state check reports `rate-limited`, keep waiting in long bounded rounds (~10 min each, up to ~90 min); escalate to the user after that instead of triggering anything.

---

## Step 4: Wait for CI

After pushing, wait in **bounded rounds** — never one unbounded wait (a shell call caps around ~10 min, and a stuck or approval-gated workflow would hang you forever). One call does the polling and the evaluation together:

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
"$agentkit/review-remote-pr/scripts/gh-pr-state.sh" \
  --pr "$PR" --repo "$REPO" --wait-ci --rounds 4 --interval 60
```

It polls up to `--rounds` times at `--interval` seconds (bounds: 1–60 rounds, 1–3600 seconds), prints one progress line per round to **stderr**, and then prints the same digest as Step 1 on **stdout** — so `$( … )` captures only the digest. After the last round it reports the current state rather than failing.

Do NOT grep for repo-specific check names ("Test|Build|Lint"): names differ per repo, and a no-match grep piped to `grep -qv` loops forever. The helper reads the status rollup by shape instead, counts `SKIPPED` and `NEUTRAL` conclusions as passing (so `ci=N/N green` is reachable on repos with conditionally-skipped jobs), and ignores any check matching /coderabbit/i when deciding whether things have settled — that check can sit pending under a rate limit and would never settle — while still counting it in the reported `pending=` figure so the digest stays truthful.

If the digest still reports `pending` after the bounded rounds, **stop and escalate to the user**. Do not keep waiting, and do not keep raising `--rounds`.

Do NOT wait for a CodeRabbit review after a push — pushes trigger nothing. A fresh pass on the pushed fixes happens only if the user re-triggers it; report that the fixes are pushed and let them decide.

---

## Step 5: Assess Automated-Review & Adversarial-Review Findings

**Order matters: apply explicitly approved human-review actions without resolving their threads; triage body nitpicks and GitHub Code Quality findings FIRST; reply-and-resolve CodeRabbit's threads LAST.** Resolving CodeRabbit's threads can arm its auto-approve, while Code Quality findings need a fresh scan to establish their state. Work the cycle in this order:

1. For each user-approved human item, record the exact approved code action; replies still wait until the verified fix exists and human threads remain unresolved
2. Triage every body nitpick, `github-code-quality[bot]` finding, confirmed adversarial finding, and CodeRabbit thread into one accepted code-change/decline batch
3. If the batch contains code changes, dispatch exactly one Luna implementation worker through the six-step gate; inspect and independently verify its returned commit(s)
4. Post and integrity-check approved human replies, body-nitpick documentation, Code Quality replies, and adversarial-review outcome comments
5. Then reply to and resolve CodeRabbit's own eligible threads; never resolve human-touched threads

For each unresolved **CodeRabbit** thread, each CodeRabbit body nitpick surfaced from `$RUN_DIR/state/pr_${PR}_reviews.json`, `$RUN_DIR/state/pr_${PR}_comments.json`, or `$RUN_DIR/state/pr_${PR}_issue_comments.json`, AND each confirmed adversarial-review finding from `$RUN_DIR/adversarial.result.json` (Step 1b):

```
VALID   → fix the code, commit; reply explaining what was fixed + commit SHA
INVALID → write decline rationale (cross-module consistency, deliberate design choice, etc.)
          reply with rationale
NITPICK → fix if trivial (< 5 min), decline if not; reply either way
```

Body-only nitpicks are still actionable. Do not skip them just because they do not have a `PRRT_...` review-thread node ID.

### GitHub Code Quality finding handling

For each unresolved comment from `github-code-quality[bot]`:

```text
VALID → apply the suggested autofix verbatim (or the smallest equivalent only when
        the suggestion cannot be applied mechanically), run the repository checks
        through `agent-run.sh`,
        commit and push; reply to the original comment with the short commit SHA;
        wait for the next Code Quality scan and verify that the finding auto-clears.

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

**Reply to inline comments:**
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

`gh-comment.sh` **is** the reply-body integrity gate (provider rules above): it posts the file's
exact bytes, re-fetches the stored comment, and `cmp`s them. On success it prints one line
(`posted id=… url=… verified=exact`) and exits `0`; on a mismatch it prints a unified diff to stderr
and exits `1` with stdout empty. **Resolve or dismiss only when that stdout line exists and the exit
code was `0`** — no line means nothing is proven, so nothing gets resolved. Use `--update ID` to
edit a top-level conversation comment in place (that endpoint cannot edit an inline review comment).

**Document body-only nitpicks as NEW anchored threads — not top-level comments:**

A `gh pr comment` floats in the conversation, disconnected from the code — CodeRabbit can't tie it to the change. Instead, open a **new review thread** anchored on the file the nitpick names, at the exact lines you changed (for declines: the lines the nitpick cites), referencing the commit and mentioning `@coderabbitai`:

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
yours: leave them open so CodeRabbit sees the mention on its next user-triggered pass, then resolve
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

Resolve CodeRabbit threads — both accepted fixes and declined suggestions — only when they contain no unmarked human-authored comment, and always **reply BEFORE resolving**. A declined thread is resolved after the reply explains why. **Never resolve a human-touched thread** — post only a user-approved reply, leave resolution to the human, and list it in the exit report. This includes feedback authored by the authenticated `gh` login. Body-only nitpicks are complete when documented in their marked anchored thread. **Adversarial-review findings** have no review thread; record each outcome in a PR comment.

### End of cycle: one push, zero review commands

The cycle ends with its **single batched push** (Step 1c). Post **no** review command in any phase — a fresh CodeRabbit pass on the batch happens only if the user manually triggers one; report that the fixes are pushed so they can decide. Why decline replies still matter: when the user does trigger a `full review`, it re-evaluates the PR **from scratch, disregarding previous comments** — it can re-raise previously declined items. Decline replies store Learnings (see Decline Rationale Templates) that survive that; post them before the cycle's push.

---

## Step 6: Evaluate and Repeat

Refresh every artifact with the same single call as Step 1 — CI state, threads, nitpicks and Code
Quality comments all come back in one digest, so there is no separate `gh pr checks` and no
hand-rolled GraphQL re-query here:

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
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
"$agentkit/review-remote-pr/scripts/gh-pr-state.sh" \
  --pr "$PR" --repo "$REPO" --full --tmpdir "$RUN_DIR/state"
```

The digest answers "is CI green" and "how many unresolved coderabbit / code-quality / human threads
remain". One classification the digest does not carry is which unresolved threads are this
workflow's own **marked agent-doc** threads, eligible for resolution at exit. Derive that from the
refreshed `$RUN_DIR/state/pr_${PR}_threads.json`:

```bash
# Re-set RUN_DIR as shown in Step 0c when this is a separate shell call.
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
# Path passed as argv, not via the environment — nothing is exported across calls.
python3 - "$RUN_DIR/state/pr_${PR}_threads.json" << 'EOF'
import json, re, sys
d = json.load(open(sys.argv[1]))
rt = d['data']['repository']['pullRequest']['reviewThreads']
if rt['pageInfo']['hasNextPage']:
    print('WARNING: >100 threads — page with an after: cursor before trusting counts')
threads = rt['nodes']
def comments(t):
    return t['comments']['nodes']
def author(c):
    return (((c.get('author') or {}).get('login')) or '').lower()
def body(c):
    return c.get('body') or ''
def is_bot(c):
    return bool(re.search(r'coderabbit|github-code-quality', author(c)))
def is_agent_comment(c):
    return '<!-- review-remote-pr:agent-' in body(c)
def has_human_content(t):
    return any(not is_bot(c) and not is_agent_comment(c) for c in comments(t))
unresolved = [t for t in threads if not t['isResolved']]
automated = [t for t in unresolved if comments(t) and is_bot(comments(t)[0]) and not has_human_content(t)]
agent_docs = [t for t in unresolved if comments(t) and '<!-- review-remote-pr:agent-doc -->' in body(comments(t)[0]) and not has_human_content(t)]
human = [t for t in unresolved if has_human_content(t)]
print(f'{len(automated)} unresolved automated-review threads of {len(threads)} total')
if agent_docs:
    print(f'{len(agent_docs)} unresolved MARKED AGENT-DOC threads — resolve them now (exit time)')
if human:
    print(f'{len(human)} unresolved HUMAN threads — confirmation-gated; NEVER auto-resolve these')
EOF
```

Marked agent-documentation threads may be resolved at exit only when every non-bot comment has an agent marker. An unmarked human reply converts the whole thread to confirmation-gated and leaves it open. Never substitute `author == gh api user` for a marker. Do not apply this rule to an original `github-code-quality[bot]` finding: it must auto-clear or be dismissed with a reason.

Also re-open `$RUN_DIR/state/pr_${PR}_reviews.json`, `$RUN_DIR/state/pr_${PR}_comments.json`, `$RUN_DIR/state/pr_${PR}_issue_comments.json`, and `$RUN_DIR/state/pr_${PR}_code_quality_comments.json`. Confirm every automated-review body nitpick has a matching anchored thread (or fallback comment) recording its fix/decline, and every Code Quality comment is either gone/auto-cleared after the pushed fix or explicitly dismissed with a reason. Confirm every confirmed adversarial-review `[P1]/[P2]` finding has a matching fix/decline PR comment.

If any CI failed OR any automated-review thread/finding remains unhandled OR any body nitpick remains unaddressed OR any confirmed adversarial-review finding remains unaddressed → go back to Step 1 (max 3 full cycles — see The Loop's iteration cap; remember another CodeRabbit pass needs the user's trigger). If human-authored content lacks an explicit user decision, surface the gate and wait; do not post, resolve, or claim readiness.

---

## Common Pitfalls

| Problem | Fix |
|---|---|
| `resolveReviewThread` returns NOT_FOUND | You passed REST comment ID, not GraphQL thread node ID (`PRRT_...`). Fetch thread IDs via GraphQL first. |
| Tempted to trigger a review | `@coderabbitai review` / `full review` / `pause` / `resume` are ALL banned. Automatic + incremental reviews are disabled — only the human triggers reviews, manually. Silence is the default state, not an outage. |
| Waiting for a review after the ready flip | The flip triggers nothing (automation is off). Report draft-phase complete; the user triggers a review if and when they want one. |
| Waiting for a review after a push | Pushes trigger nothing either. Report fixes pushed; the user decides whether to re-trigger. |
| Running the adversarial review early or repeatedly | Apply the materiality gate ONCE as the LAST draft step (CI green first). For a material diff, fix confirmed findings and do not re-review the fixes. |
| Same-harness fallback given context | A reviewer that reads the issue/ADRs/design doc rubber-stamps intent. Create a separate no-history agent in the running CLI; give it only the diff and review rubric, and instruct it not to use tools or read files. |
| Contextual PR-loop agent writes fixes itself | Dispatch the separate Luna implementation worker; the loop agent orchestrates, reviews, verifies, pushes, and handles GitHub state |
| Implementation worker inherits the parent model | Use `fork_context: false`, `model: "gpt-5.6-luna"`, and `reasoning_effort: "high"` on every code-writing spawn |
| Skipping the six-step fix design because the patch looks small | Every code-bearing batch reports Structs, Interfaces, Todos, performs Spike + Revert, states Invariants, then implements through TDD |
| Luna unavailable in `spawn_agent` | Select `gpt-5.6-terra` at high reasoning automatically; stop before code edits only when neither Luna nor Terra is available |
| `collaboration.spawn_agent` itself unavailable | Do not stall and do not silently self-implement. Attempt the spawn, record why it was unavailable (e.g. `multi_agent = false`), then take the documented degraded path: same six-step gate on yourself, same independent verification, and label the exit report `worker=self (spawn unavailable)`. Retry the spawn next cycle. |
| Claude external-review authorization is absent | Do not send the diff. Run the blind separate Codex-agent fallback and disclose the substitution in the exit report. |
| Tempted to run `claude ultrareview` | Don't. Use the blind, diff-only, structured one-shot helper in Step 1b; nested orchestration is a different surface. |
| Tempted to run `codex exec review` | Don't. That subcommand reviews the *current repository* with full context — the opposite of a blind diff-only reviewer, and non-deterministic in shape. Use `codex-adversarial-review.sh`. |
| `codex exec "prompt"` hangs forever | It reads stdin even when the prompt is an argument (it prints `Reading additional input from stdin...`) and blocks until EOF. Always redirect: `</dev/null`, or pass `-` and redirect the prompt file in. Measured: hangs past 180s without redirection, completes in ~5s with it. |
| Review diff built with a wide `-U` | Context width is the largest cost lever in the gate. Measured on a 3-file/9-hunk change, `-U80` cost 10.4× `-U3` and emitted 77% of the full text of every touched file. Step 1b uses `-U25`; raise it only for hunks that genuinely need more surrounding code. |
| Expecting a provider-dollar ceiling on the Codex path | `codex exec` has no `--max-budget-usd` equivalent. The helper enforces observed `--max-tokens` and `--max-duration-seconds`, while also bounding input with `--max-diff-bytes`; it reports actual `tokenUsage`. |
| Trusting the Codex reviewer's model identity | Its event stream carries no model field, so `modelVerification` is `unsupported-by-codex-exec`. Only the Claude helper can assert the initialized model matches the requested one. |
| Treating a fixed wall-clock timeout as a verdict | Keep the explicit `--max-duration-seconds` safety cap. A breach is a blocked review, never `no_findings`; do not shrink the diff to meet an estimate. |
| Claude is silent between polls | Report PID, elapsed time, seconds since last event, and transcript growth. Silence is a warning until the helper's duration ceiling, then the helper must terminate the review. |
| Claude exits 0 with no verdict | Exit code is necessary, not sufficient. Require verified `system/init` plus final `result/success.structured_output`; otherwise the gate is blocked. |
| Adversarial helper exits 3 reported as BLOCKED | Exit `3` is **environment-blocked**, not a blocked gate: Claude cannot run here, so stdout carries `{"status":"blocked","blockedReason":…,"fallback":"blind-codex-agent"}`. Take the blind same-harness fallback immediately, do not retry, and never report the gate blocked for this reason. Only exit `1` (stdout empty, reason on stderr) is a genuinely blocked gate. |
| Probing Claude when the preflight already said `peer-cli= <name> absent` | Skip the probe entirely and go straight to the fallback. The Step 0a contract already answered it; probing burns an agent lifecycle to rediscover `ENOTIMP`. |
| Using `--disallowedTools '*'` with `--json-schema` | It removes the internal `StructuredOutput` tool. Use `--tools ''` and verify the init manifest is exactly `StructuredOutput`. |
| Skipping review because the diff is short | Size is not risk. Skip only with a deterministic mechanical oracle; runtime, contract, security, persistence, workflow, or accessibility changes are material. |
| Auto-applying adversarial findings | Evaluate first — verify each `[P1]/[P2]` against the actual code, downgrade overstated severities, drop false positives. Confirmed findings go through Step 5; document outcomes in a PR comment (no thread to resolve). |
| `github-code-quality[bot]` finding remains after a fix | Wait for the next Code Quality scan and inspect the refreshed finding state. Do not manually resolve it as a substitute for the scan. |
| Inaccurate Code Quality finding | Reply with a concrete reason, then use GitHub's **Dismiss finding** action with that reason. The public Code Quality REST API is read-only for findings; do not guess a mutation. |
| Code Quality dismissal command temptation | `PUT /pulls/$PR/reviews/$REVIEW_ID/dismissals` dismisses an entire PR review, not one finding. Never use it for a single Code Quality comment. |
| Code Quality vs code scanning API confusion | `github-code-quality[bot]` findings use the Code Quality surface. `/code-scanning/alerts/...` is a different resource; use it only after independently identifying a code-scanning alert. |
| CodeRabbit review body vs inline comments | Review bodies, inline comment bodies, and PR conversation comment bodies can include actionable nitpick sections. Read full bodies from the Step 1 temp files; do not rely only on review threads. |
| CI pending forever | Check `gh run list --pr $PR` — may be a different run. Use the run ID from the `gh pr checks` URL column. |
| Requesting `--json commits` on every poll | Don't. The commit list is the largest field on a PR and nothing in this workflow consumes it — it is pure payload bloat repeated every round. `gh-pr-state.sh` never requests it; if you hand-roll a `gh pr view`, ask only for the fields you will read. |
| Coverage threshold failure | Run the repo's coverage command through `agent-run.sh` locally first: `agent-run.sh --cmd coverage --if-declared` when the repo's `.agent/runner` resolves that name, otherwise pass it literally as `agent-run.sh --label coverage -- <the repo's coverage command>`. Check the per-file breakdown. Add targeted tests. |
| `$HOME` package-manager cache is read-only | The sandbox may mount `$HOME` read-only, so `npm`/`pip`/`uv` fail on their cache before they fail on your code. Do not `sudo` or `--no-cache` around it: run the command through `agent-run.sh`, which relocates `XDG_CACHE_HOME`/`UV_CACHE_DIR`/`NPM_CONFIG_CACHE`/`PIP_CACHE_DIR` to a writable root and says so in a `note:` line. |
| A package-scoped tool run from the wrong cwd | Tools that resolve their config from the nearest ancestor manifest silently run the wrong target, or none, when invoked from a monorepo root. Pass the package directory explicitly: `agent-run.sh --dir web --cmd test`. |
| `.git/worktrees/<name>/index.lock` permission denied | The per-worktree metadata dir is outside the writable bind mount. `worktree-commit.sh` detects this *before* staging and exits `2` naming the path, with nothing staged — obtain write permission for that path and re-run the identical command. Never work around it by committing from the main checkout. |
| Thread already resolved | Skip — don't re-resolve. Only target `isResolved: false` threads. |
| Multiple CodeRabbit review cycles | Each user-triggered review is a fresh pass. Fetch reviews sorted by `submitted_at` — process the latest. |
| CodeRabbit check green but no real review | Rate-limit warning / bare "✅ finished" ack leaves the check green. Detect the real signal in the comment **body** (`Actionable comments posted` / `walkthrough` = reviewed; `Review limit reached` = throttled — wait, it self-resolves; don't buy credits). `none` = the user simply hasn't triggered one. |
| Body nitpick has no thread ID | Fix or decline it anyway, then open a NEW anchored thread on the nitpick's file/lines referencing the commit and mentioning @coderabbitai (Step 5). Only `PRRT_...` threads can be resolved through GraphQL. |
| Body nitpick documented as top-level comment | A floating `gh pr comment` is disconnected from the code — CodeRabbit can't tie it to the change. Use the anchored-thread POST from Step 5; top-level comment is the 422 fallback only. |
| Threads resolved before body nitpicks handled | Resolving CodeRabbit's threads arms its auto-approve (when enabled) — an approval can fire on a PR with unhandled nitpicks. Follow Step 5's order: nitpicks first, reply+resolve threads last. |
| CodeRabbit never auto-approves | Its approval workflow may be disabled for this org/repo entirely — then none ever comes; exit on threads-resolved + nitpicks-handled. If enabled, auto-approve needs BOTH a reply and a resolve on every thread CodeRabbit opened, plus passing pre-merge checks. |
| Full review re-raises declined items | A (user-run) `full review` re-evaluates from scratch, disregarding previous comments. Post decline replies with the WHY first — Learnings persist the decision across reviews (see Decline Rationale Templates). |
| Marking the PR ready yourself | Never — `gh pr ready` is the user's call alone; it is the human sign-off that the draft phase is complete. Report and wait (Step 3). |
| Tempted by `@coderabbitai resolve` (bulk) | NEVER use it — it resolves every CodeRabbit thread at once, reply-less. Each thread must be individually triaged, replied to, and resolved (Step 5); a bulk resolve can also arm auto-approve while items are still unhandled. |
| PR shows `mergeable: CONFLICTING` | Run Step 0b — merge the base branch, resolve conflicts, verify, and plain-push. Wait for GitHub to update mergeability before continuing. |
| Wrong worktree or branch when editing | Always run Step 0a first. Check `pwd` and `git branch --show-current` before every commit. If wrong, stop and move to `$PR_WORKTREE`; do not switch branches in another issue/PR's worktree. |
| Worktree path already exists | Set `PR_WORKTREE` to an unused directory and rerun Step 0a, or `cd` into the existing PR worktree if it is already for `$HEAD_BRANCH`. |
| Merge conflict loop | Resolve each conflict file, verify no markers remain, commit the merge with `worktree-commit.sh`, then run the repository verification commands through `agent-run.sh`. |
| Published branch appears to require force-push | Stop. This workflow preserves published history with a merge; do not rewrite the PR branch without separate explicit user authorization. |
| Fork (cross-repo) PR | `origin/$HEAD_BRANCH` doesn't exist and pushes must go to the fork. Step 0a detects `isCrossRepository` and uses `gh pr checkout` in a detached worktree; push with plain `git push`. |
| Authenticated `gh` user authored the review | Treat it as human. Login equality never proves agent authorship; only reserved markers identify individual workflow-created comments. |
| Human replies inside a bot-originated thread | The whole thread is human-touched. Gate the response and never resolve it, even though the first author is a bot. |
| Human review appears during the run | Surface exact feedback, assessment, proposed action, and draft reply; wait for explicit per-item approval before code changes or posting. Never resolve its thread. |
| Human reviewer thread unresolved | Expected after an approved reply — resolution belongs to the human. List it in the exit report. An undecided item blocks a ready-to-merge claim. |
| Backticks in a comment body get command-substituted | ``-f body="Fixed in `abc1234`."`` is a double-quoted shell string, so the shell runs `abc1234` as a command and posts `Fixed in .` — the SHA vanishes silently. Never interpolate a body into a shell string. Write it to a file with a **quoted** heredoc (`<<'EOF'`) and inject varying values with `printf` arguments, then post it with `gh-comment.sh --body-file`. |
| Posted reply body doesn't match intended text | Post through `gh-comment.sh`: it sends the file's exact bytes, re-fetches the stored comment, and `cmp`s them, printing a unified diff on mismatch. Resolve or dismiss only when it printed a stdout line AND exited `0`. |
| Loop never converges (new nitpicks every trigger) | Iteration cap: 3 full cycles, then summarize remaining items + your stance and escalate to the user. |
| Truncated reviews/threads on chatty PRs | REST defaults to 30/page (oldest-first — you lose the NEWEST). `gh-pr-state.sh` paginates every list endpoint; for threads it requests `first: 100` and appends `truncated=yes` to the digest's `threads:` line when there is more. Treat `truncated=yes` as "page with an `after:` cursor", never as a clean zero. |
| Parallel loops clobber temp files | All review artifacts live beneath the random `RUN_DIR` (`0700`) — parallel-issues Phase 3 runs several loops concurrently; never write review payloads to shared `/tmp`. |
| `python3 -c "..."` fails with `unmatched "` | zsh breaks on double-quoted multi-line python. Use heredoc instead: `cmd \| python3 << 'EOF'\n...\nEOF`. Never use `python3 -c "..."` for multi-line scripts. |
| Conflict resolution with python3 | Prefer `git checkout --ours/--theirs <file>` for whole-file picks; `sed` only for mechanical marker stripping (see Step 0b). Python inline scripts fail on files that contain quotes. |
| `gh pr checks` cancels parallel calls | `gh pr checks` exits 8 when checks are pending/failing, and a parallel runner treats exit 8 as an error and cancels siblings. Prefer `gh-pr-state.sh` (CI state is data; it stays at exit 0); if you must call `gh pr checks` directly, append `\|\| true`. |
| Shell state assumed to persist | Exports, `cd`, and `source` do not survive to the next tool call. Re-derive `REPO`/`PR` in every block, and run project/test/lint commands through `agent-run.sh` instead of exporting cache/CA/`PYTHONPATH` variables first. |
| `cmd \| python3 << 'EOF'` SyntaxError | Pipe and heredoc both claim stdin — shell concatenates them, Python sees JSON prepended to the script. Always `cmd > /tmp/file.json` then `python3 << 'EOF'` reading the file. |
| Reply to comment returns 404 | URL must include PR number: `repos/$REPO/pulls/$PR/comments/$COMMENT_ID/replies`. The shorter form without `$PR` returns 404. |
| Auto-promoting Backlog → Ready | Don't. Backlog is unvetted; promotion is the user's vetting call. Propose with rationale, move only after confirmation. |
| `gh project item-list` shows no `.status` | The board's single-select status field may be named differently. Inspect `jq '.items[0]'` and match the column by intent (Backlog/Ready); no-op if none matches. |
| Grooming blocks the PR handoff | It's best-effort. If the board/scope/`gh project` access isn't there, no-op silently and still report the PR as merge-ready. |

## Decline Rationale Templates

```
"Declining — [existing module X] uses the same pattern without [Y]; 
introducing [Y] here alone creates inconsistency before a cross-module 
refactor is planned."

"Declining — deliberate design choice: [reason]. Tracked for future consideration."

"Declining — nitpick; tradeoff of [readability vs brevity] is acceptable here."
```

Post declines as replies **on the specific code comment**, mention the relevant provider, and explain the *why*, not just the what. For CodeRabbit, mention `@coderabbitai` so its learning system stores a **Learning** that stops the same suggestion from being re-raised on this and future PRs (docs.coderabbit.ai/knowledge-base/learnings). For `github-code-quality[bot]`, repeat the same concrete reason in GitHub's **Dismiss finding** action; a reply or a resolved thread alone is not a dismissal. Resolving a thread without a why teaches no provider anything useful.

## Exit Report

**Draft-phase report (end of Phase A, before the Step 3 wait):**
```
PR #N: draft phase complete — CI green, conflicts none,
Adversarial review [Claude Opus 5 | blind separate Codex-agent fallback (reason: <blockedReason> | claude absent)]: M findings, M handled.
Implementation worker: [gpt-5.6-luna high | automatic gpt-5.6-terra high fallback
                        | worker=self (spawn unavailable) — reason: <why>], six-step gate complete.
Human review: [none | H1 approved/replied/open | H2 awaiting confirmation].
Waiting for you to mark it ready and trigger any CodeRabbit review you want
(automatic reviews are off — nothing runs until you trigger it).
```

**Final report (loop exit):**
```
PR #N: all CI green, N/N CodeRabbit threads handled, all body nitpicks handled,
GitHub Code Quality: [no findings | all findings auto-cleared | inaccurate findings dismissed with reasons | blocked],
CodeRabbit approval: [approved | n/a — approval workflow disabled | not re-triggered by user],
Adversarial review [Claude Opus 5 | blind separate Codex-agent fallback (reason: <blockedReason> | claude absent)]: M findings, M handled.
Implementation worker: [gpt-5.6-luna high | gpt-5.6-terra high | worker=self (spawn unavailable) — reason: <why>].
Human review: [none | H1 approved/replied/open, H2 declined/open | H3 awaiting confirmation].
[Ready to merge | Awaiting user confirmation; not claiming readiness].
```
(Always identify which reviewer ran — cross-harness Claude or the blind separate Codex-agent fallback — so the human knows the review depth, and name the fallback's reason when one was taken. Always identify who wrote the code: a dispatched worker with its model/effort, or `worker=self (spawn unavailable)` with the reason. List every human-review item, the user's decision, whether an approved reply was verified, and the still-open thread state.)

Then run **Backlog grooming** below before handing back.

---

## After the Loop: Groom the Backlog → propose Ready candidates

Finishing this PR drains the Ready / In-progress queue. Before handing back, fan out across the Project **Backlog** and propose which issues are vetted enough to promote to **Ready**, so the next pickup (`parallel-issues`, autonomous pull) has a clean queue. This is the *producer* side of the queue those *consume*.

**Propose, never auto-promote.** Backlog → Ready is a vetting decision (`github-projects.md`: Backlog = captured but *not vetted*; Ready = *cleared* for pickup). Surface candidates with rationale; only run the board helper with `--status 'Ready'` after the user confirms.

**No-op silently** (never fail the PR work over a board move) when there is no GitHub remote, the repo is on no Project board, the board has no Backlog/Ready column, or `gh` lacks `project` scope (`gh auth refresh -s project`).

### Pull the Backlog

Find the board this repo's issues live on, then list its Backlog issues:

```bash
IFS='/' read -r OWNER _ <<< "$REPO"
gh project list --owner "$OWNER" --format json   # pick the board whose items are this repo's issues
PROJECT=3                                        # replace with that board's number
gh project item-list "$PROJECT" --owner "$OWNER" --format json --limit 200 \
  | jq -r '.items[]
           | select(.status=="Backlog" and .content.type=="Issue")
           | "#\(.content.number)\t\(.content.title)"'
```

If Ready already holds enough queued work (≈3+ items), say so and stop — a full queue does not need topping up.

### Vet each issue against the Ready bar (fan out)

Read each Backlog issue's body and judge it against the bar below. Where your runtime supports parallel agents, fan out one **read-only** assessor per issue (reads the body, greps the code); otherwise assess sequentially.

| Ready-bar check | Promote when… |
|---|---|
| **Specified** | concrete acceptance criteria / scope / file pointers — not a vague wish |
| **Unblocked** | no open dependency, no "Blocked-by", no prerequisite PR still open |
| **Right-sized** | one demonstrable change, ≤ ~500 LOC (chunking rule) — not an epic or tracking shell |
| **Independent** | does not overlap files with an In-progress / In-review issue |
| **Still real** | not stale, not a duplicate, not already shipped by a merged PR |

**Leave in Backlog (and say why)** anything that needs a human call before it is pickup-ready: research / decision issues, tracking bundles, and epics that must be **sliced** into child issues first.

### Propose (then stop)

Print the proposal — move nothing yet:

```
Backlog → Ready candidates (after PR #N):
  PROMOTE
    #62  Logging cleanup        ✅ specified · isolated (src/logger.ts) · ~80 LOC
    #71  Rate-limit guest API   ✅ clear AC · unblocked · ~200 LOC
  HOLD (needs a human call first)
    #58  "Make setbuilder fast"  ⚠️ no acceptance criteria — scope it first
    #506 split god-components    ⚠️ epic — slice into per-file child issues first
```

On confirmation, promote the approved set and stop; the next pickup takes them from Ready. Use the
board helper bundled with `parallel-issues` — it walks every board the issue is on, prints one line
per board, and no-ops cleanly (still exiting `0`) when there is no board, no `Status` field, or no
matching option:

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
board_helper="$agentkit/parallel-issues/scripts/move-github-project-item.sh"

for issue_number in 62 71; do   # only the numbers the user approved
  "$board_helper" --issue-number "$issue_number" --status 'Ready' --repository "$REPO"
done
```

A leading `moved ` is the evidence the promotion happened; a `no-op:` line means it did not. Both
exit `0`, so never treat the exit status alone as proof.
