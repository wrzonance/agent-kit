Read this once, at Step 0a, before touching anything else. `SKILL.md` keeps the one pinned rule
this file's detail feeds (jq-missing is unavailable evidence, never "no findings") and the exact
Step 0a decision-line actions; this file carries the full runtime-neutrality contract and the
environment-contract mechanics behind them.

## Runtime and provider neutrality

Evidence parsing is a blocking check: empty output is acceptable only when the parser proved it ran;
missing parser ≠ "no findings." Guard every `jq`/`python3` recipe:
`command -v jq >/dev/null 2>&1 || { printf '%s\n' 'jq is not installed; evidence unavailable' >&2; exit 1; }`
Before any GitHub body mutation, follow ["$agentkit/.shared/github-body-policy.md"](../../.shared/github-body-policy.md).
Runtime facts come from the session contract's `sandbox=`/`git=`/`measured-by=` records, never inferred
(absent = "unknown"); a denial or approval in one session never generalizes to another — report the
contract state and the exact operation that needs approval. **Shell state does NOT persist between tool
calls** (re-derive `REPO`/`PR` per block); run project commands through `.shared/scripts/agent-run.sh`,
never hand-export cache/CA/`PYTHONPATH`, never disable TLS verification. **A spawned agent cannot spawn
another.** Review-provider behavior is repo/org configuration: never claim automatic/incremental/manual-only
without current state, and never post a trigger command.

## The environment contract

Run `.shared/scripts/agent-preflight.sh` exactly ONCE, in Step 0a, and treat its printed block
(`skills=`/`repo`/`branch`/`worktree`/`base`/`config`/`git`/`gh`/`sandbox`/`tls`/`caches`/`runners`/
`harness`/`peer-cli`) as the contract for the whole run — never re-probe. **Paste it verbatim into
every dispatched worker prompt.** Decision lines: `gh= … project-scope=no` → a human OAuth session
may need `gh auth refresh -s project`, while an unattended fleet session must verify the App's
`Projects: write` permission and never fall back to a human token; `peer-cli= <name> absent` → skip the Step 1b peer probe
entirely, go straight to the blind same-harness fallback; `config= present=no` → facts come from
discovery instead of `.agent/config.env`.

`skills-path-mismatch` is expected after a kit upgrade changes the skills path; run the printed Bash `contract_cache_refresh_session_context` remedy to refresh the session cache explicitly.

The contract file is keyed by harness (issue #551): `.agent/env-contract.<harness>.txt`, so a second harness
observing a checkout never overwrites the file the first harness's run relies on; `contract-read.sh` and
every guard resolve the running harness's file automatically (the bare name is a read-only legacy fallback).
A contract carrying `mode=observer` means another harness's run was active: treat the checkout root as
read-only and work from a linked worktree. A repo opts into its own command runner via `AGENT_REPO_RUNNER`,
then a committed `.agent/runner`. `.agent/` is untracked (Step 0a excludes it) and `worktree-commit.sh`
stages only its FILE arguments, so `git add -A` is never safe. Unattended orchestration authenticates `gh`
with the fleet App installation token (`GH_TOKEN`/`GITHUB_TOKEN`); never repair a missing fleet credential by
logging the human account into the worker shell — ready flips, approvals, and merges stay human-gated (see the
[fleet identity runbook](../../../../docs/fleet-identity.md)).
