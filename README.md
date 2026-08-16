# Agent Kit

Keep your sub-agents in check while systematically working through a GitHub Projects board.

Agent Kit is a plugin for Codex CLI and Claude Code. It ships three skills, a set of bash
helper scripts, and five lifecycle hooks. A repository you onboard declares its own facts
once, in a committed `.agent/` directory: the trunk branch, the Projects board, the label
taxonomy, and the commands that verify it. The skills and hooks read those declarations
instead of rediscovering them on every run.

## What it does

| Piece | Purpose |
|---|---|
| `onboard-repo` skill | Walks a repository through setup. Runs the bootstrap script, audits existing instruction files, fills in verify commands and label meanings, and hands command approval to a human |
| `parallel-issues` skill | Triages the Projects board, picks 2-5 independent issues, runs each in an isolated git worktree with its own sub-agent, and drives each to a draft PR |
| `review-remote-pr` skill | Takes a draft PR to green: CI, merge conflicts, one adversarial cross-review by the peer CLI, review-bot threads, and the board move |
| Helper scripts | Deterministic one-call operations: environment preflight, command runner, board reader and mover, one-request issue triage, worktree commits, PR state digests, verified comment posting |
| Hooks | Inject the environment contract at session start, refuse a short list of destructive commands, teach cheaper commands after wasteful ones, and block the end of a turn until the declared verify command has covered the changes |

## Install

Both harnesses install from a local checkout. Keep it under your home directory; Codex
requires that for a local marketplace.

```bash
git clone https://github.com/wrzonance/agent-kit.git ~/github/agent-kit
```

Codex CLI:

```bash
codex plugin marketplace add ~/github/agent-kit
codex plugin add agentkit@agent-kit
codex plugin list                        # agentkit@agent-kit  installed, enabled
```

Claude Code:

```
/plugin marketplace add ~/github/agent-kit
/plugin install agentkit@agent-kit
```

There is no build step. The same checkout serves both harnesses, with one plugin manifest
per harness and a resolver that searches both plugin caches. Install it on both and they
share one copy of the skills.

## Onboard a repository

Ask the agent to onboard the repository. The `onboard-repo` skill runs the bootstrap
script and fills in the judgement calls the script leaves blank. A session in a repository
that has no `.agent/config.env` says so in the terminal, unprompted.

To run the script directly:

```bash
cd /path/to/your/repo

agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" \
    -maxdepth 4 -type d -path '*/agentkit/*/skills' 2>/dev/null | sort -V | tail -1)

"$agentkit/.shared/scripts/bootstrap-repo.sh" --dry-run   # look first
"$agentkit/.shared/scripts/bootstrap-repo.sh"             # then write
```

This writes two committed files, plus the `.gitignore` rules that keep everything else
under `.agent/` out of your history:

- `.agent/config.env` holds the repo slug, trunk branch, board number, Status column
  names, generator stamp, and commented suggestions for your verify commands.
- `.agent/board.json` caches the board's node IDs, so a status move costs one API call.

On later sessions, `"$agentkit/.shared/scripts/onboard-state.sh" --report` includes a cheap drift
summary. Inspect named findings with `"$agentkit/.shared/scripts/onboard-refresh.sh" --report`; when
the operator chooses to regenerate proposals, use
`"$agentkit/.shared/scripts/bootstrap-repo.sh" --refresh`. Refresh preserves declared values and
never activates a proposal.

Both files are committed and readable, so secrets are refused outright: tokens, proxies,
and CA paths never belong in either.

Then open `.agent/config.env` and uncomment the commands your repository runs:

```ini
AGENT_CMD_VERIFY=tools/verify
AGENT_CMD_TEST=<whatever this repo runs for tests>
```

Command values are argv lists rather than shell strings: unquoted spaces separate
arguments, quotes keep spaces inside one argument, and shell operators are rejected. If
your repository drives everything through one dispatcher, point `AGENT_REPO_RUNNER` at it.
Skills run commands by name (`agent-run.sh --cmd test`), so no skill hardcodes an
ecosystem.

### Command approval

Declaring a command does not let the agent run it. Review the declaration, then approve it
once with `agent-run.sh --approve --cmd NAME`; the confirmation is read from your
controlling terminal. That confirmation is defense in depth, **not** a cryptographic human-only
gate: an agent with arbitrary command execution runs as your user and can bypass it. What the record does guarantee is worth having. It lives in an owner-only state
directory outside the checkout, it makes approval an explicit logged step, and it
fingerprints the declaration, the runner, repository-backed argv paths, and nearby build
manifests, so a changed command or input cannot inherit an old approval.

The rationale for these controls and their deliberately limited exceptions is in the
[security posture](docs/security-posture.md).

### Fleet GitHub identity

Unattended orchestrators use a short-lived GitHub App installation token in
`GH_TOKEN`, never a maintainer's personal token. The Project helpers therefore
use the fleet's own rate pool and bot authorship for GraphQL-backed board
operations. Draft PRs and workflow-authored comments use the same fleet
identity. Ready-flips, approvals, and merges remain human actions from a
human-authenticated shell. See the [fleet identity runbook](docs/fleet-identity.md)
for the installation permissions and rollout checklist.

Runs you launch unattended are the one exception. `agent-run.sh --yolo --cmd NAME` skips
the terminal confirmation for that single invocation, announces the skip on stderr and in
the run log, and records no trust. It applies only when the command's repository-controlled
inputs are identical to the remote trunk's; anything new or changed on the checkout still
requires a terminal approval. Skills thread the flag down from your own `--yolo`
invocation and never add it on their own.

A changed-input refusal under `--yolo` is an adjudication request, not a dead end. The root
must preserve the workstream and produce an input-diff digest listing every changed command
input, its diffstat, and its full diff. It may then use the harness flow from an interactive
terminal — `agent-run.sh --approve --cmd NAME` — so the approval reviewer sees that concrete
diff, or park and hand off the workstream with the digest and exact command. Never strip the
input, retry with a literal equivalent, or treat `--yolo` as an approval record.

## Hooks

| Hook | Behaviour |
|---|---|
| `SessionStart` | Probes the environment once and hands the agent a contract: repo, branch, base, sandbox state, CA bundle, cache roots, and the helpers available here. Without `.agent/config.env` it prints how to onboard instead |
| `SubagentStart` | Codex-only event. Injects the tooling curriculum into spawned workers; each worker's per-worktree contract travels in the dispatcher's prompt |
| `PreToolUse` | Refuses work-destroying commands every time; refuses once for a bare helper name, a trunk commit, or an edit to a file that gates other checks |
| `PostToolUse` | Teaches the cheaper command after a wasteful call returned real data |
| `Stop` | Blocks the end of a turn when the declared verify command has no run covering the current changes |

Three rules govern all five. Hooks always exit 0 and state what they want in JSON, because
a nonzero exit halts an autonomous worker instead of informing it. Guards act only on
declared evidence: a repository with no `.agent/` directory gets nothing, and the `Stop`
check fires only when a verify command is declared. Anything with a usable alternative is
allowed to run and corrected afterwards, so a single denial cannot end a line of work.

The permanent deny list is short: force-push, `reset --hard`, `clean -f`, deleting the
trunk branch, `gh pr merge`, `--no-verify`, and recursive deletes of `~` or `/`. A second
class refuses once and then allows a deliberate retry: bare helper names that cannot
resolve, and edits to files that decide whether other checks run (CI definitions, git
hooks, harness config). Add repository-specific entries with `AGENT_PROTECTED_PATHS`; the
list is additive, so a committed file cannot switch off its own guard.

## Harness configuration

Run this in any repository and it prints only the settings this machine measurably needs;
silence means nothing needs changing:

```bash
agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" \
    -maxdepth 4 -type d -path '*/agentkit/*/skills' 2>/dev/null | sort -V | tail -1)
"$agentkit/.shared/scripts/harness-advice.sh"
```

Its findings cover Codex sandbox network access (a blocked network is misreported by `gh`
as a bad token), `gh` token storage the sandbox cannot read, write access to the
repository's `.git`, and a pinned runtime that is not active in the launching shell.
`onboard-repo` runs it for you.

Granting the sandbox write access to `.git` deserves care. A writable `.git` exposes git
plumbing and `.git/config` keys that execute commands as you and persist after the
session. Agent Kit refuses those commands by pattern, but patterns have been evaded in
review before, and a read-only mount is the stronger control. If you grant it, scope it to
a single repository's `.git`, prefer a per-invocation flag over a global config entry, and
skip it entirely on a machine holding work you do not own.

## Cross-provider review privacy

`review-remote-pr` can send a PR diff, including filenames and code, to the external
provider behind the peer CLI for adversarial review. Repository ownership is not consent
to disclose private, customer, or NDA-protected code. Before the first cross-provider send
in a session, the agent must name the payload, the destination, and the purpose, then ask
for an explicit yes or no. A decline sends nothing and leaves the review gate blocked. An
affirmative answer covers that session and provider; a changed destination or payload
requires fresh confirmation.
The executable `consent-record.sh` stores that decision against the exact PR/diff identity, and
the adversarial launchers refuse to send a diff without a matching record.

## Verify your changes

```bash
tests/run-tests.sh
```

The run checks shell syntax and style, bash 5.2 compatibility, every fenced code block in
the skill markdown, the ecosystem, harness, and environment neutrality gates, and the
behavioural suites. CI runs the same script on every push and pull request. The suite
needs `shellcheck` and `python3` in addition to the runtime requirements below.

## Repository layout

```
.claude-plugin/marketplace.json     the marketplace, read by both harnesses
agentkit/
  .claude-plugin/plugin.json        one plugin manifest per harness; both are required
  .codex-plugin/plugin.json
  hooks/
    hooks.json                      where both harnesses look for it
    lib/guard-lib.sh                logic the hooks must agree on
    *.sh                            the five dispatchers
  skills/
    onboard-repo/
    parallel-issues/                scripts/ holds the board mover and data fencing
    review-remote-pr/               scripts/ holds PR digests, comment posting, reviewers
    .shared/
      schema/config.env.example     every AGENT_* key, documented
      scripts/                      the shared procedural helpers
tests/                              the test harness; never shipped in the plugin
docs/                               design specs and review records
```

## Requirements

- Linux with a GNU userland; the scripts target Debian 13 and `bash` 5.2+
- `jq`, `git`, and the `gh` CLI authenticated as the fleet GitHub App in
  unattended sessions, with the App's `Projects: write` permission; human-gated
  actions use a human account. OAuth users who need Project access can refresh
  the separate `project` scope with `gh auth refresh -s project`.
- Codex CLI or Claude Code for the hook layer; the skills work without hooks

Shell commands run through the agent's login shell, which may be zsh, so every helper is a
`bash` script rather than an inline snippet.

## Licence

MIT.
