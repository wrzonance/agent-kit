Read this once, at Step 0a, before touching anything else. `SKILL.md` keeps the one pinned rule
this file's detail feeds (jq-missing is unavailable evidence, never "no findings") and the exact
Step 0a decision-line actions; this file carries the full runtime-neutrality contract and the
environment-contract mechanics behind them.

## Runtime and provider neutrality

Evidence parsing is a blocking check: empty output is acceptable only when the parser proved it
ran; missing parser ≠ "no findings." Guard every `jq`/`python3` recipe:
`command -v jq >/dev/null 2>&1 || { printf '%s\n' 'jq is not installed; evidence unavailable' >&2; exit 1; }`
Before any GitHub body mutation, follow the shared
[GitHub body transport policy](../../.shared/github-body-policy.md).

Runtime facts come from the session contract's `sandbox=`/`git=`/`measured-by=` records, never
inferred; absent = "unknown." A denial or approval in one session does not establish the same
result in another: when a write, forge call, or worktree operation is denied, report the contract
state and the exact operation that needs the harness's approval, and do not generalize that denial
to another session. **Shell state does NOT persist between tool calls** — re-derive
`REPO`/`PR` at the top of every block; run project/test/lint through `.shared/scripts/agent-run.sh`,
never hand-export cache/CA/`PYTHONPATH`. **A spawned agent cannot spawn another** — only the root
orchestrator dispatches. Review-provider behavior is repo/org configuration: never claim
automatic/incremental/manual-only without current state, and never post a trigger command. Never
disable TLS verification to work around a failure; `agent-run.sh` relocates a read-only `$HOME`
cache and reports the substitution as a `note:` line.

## The environment contract

Run `.shared/scripts/agent-preflight.sh` exactly ONCE, in Step 0a, and treat its printed block
(`skills=`/`repo`/`branch`/`worktree`/`base`/`config`/`git`/`gh`/`sandbox`/`tls`/`caches`/`runners`/
`harness`/`peer-cli`) as the contract for the whole run — never re-probe. **Paste it verbatim into
every dispatched worker prompt.** Decision lines: `gh= … project-scope=no` → a human OAuth session
may need `gh auth refresh -s project`, while an unattended fleet session must verify the App's
`Projects: write` permission and never fall back to a human token; `peer-cli= <name> absent` → skip the Step 1b peer probe
entirely, go straight to the blind same-harness fallback; `config= present=no` → facts come from
discovery instead of `.agent/config.env`.

A repo opts into its own command runner via exactly two mechanisms, in order: `AGENT_REPO_RUNNER`
env var, then a committed `.agent/runner`. `.agent/` is untracked; Step 0a adds it to local
excludes; `worktree-commit.sh` stages only the FILE arguments given to it, so a careless
`git add -A` is not safe.

For unattended orchestration, `gh` must inherit the fleet GitHub App installation token through
`GH_TOKEN` (or `GITHUB_TOKEN` when `GH_TOKEN` is absent). This identity owns Project GraphQL reads
and mutations, draft PR creation, and workflow-authored comments. Never repair a missing fleet
credential by logging the human account into the worker shell. Draft-to-ready flips, approvals, and
merges remain human-gated actions from a separately authenticated human shell; see the
[fleet identity runbook](../../../../docs/fleet-identity.md).
