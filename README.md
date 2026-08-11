# Agent Kit

Skills, lifecycle hooks, and a per-repository contract that let a coding agent do
board-driven work without rediscovering the same facts on every run.

Works with **Codex CLI** and **Claude Code** from the same directory.

---

## What's in it

| Piece | What it does |
|---|---|
| **`onboard-repo`** skill | Walk a repository through onboarding, including the judgement calls a script can't make: which commands to declare, which labels mean what |
| **`parallel-issues`** skill | Triage a GitHub Projects board, split independent issues across worktrees, drive each to a draft PR |
| **`review-remote-pr`** skill | Take a PR from draft to green: CI, review threads, an adversarial review, and the board move |
| **`.shared/scripts`** | The procedural half — preflight, command runner, board reader, mover and setup, one-call triage, startable-issue selection, commit guard, CI-gap report, toolchain detector |
| **Five hooks** | Inject the environment contract, and teach the cheaper command without blocking the work |

The idea throughout: **a repository declares its own facts once**, and everything
else reads them instead of guessing.

---

## Install

Clone this repository anywhere; the path below is only an example. Both harnesses
install it from a local directory — there is no registry to fetch from.

**Codex CLI:**

```bash
codex plugin marketplace add ~/github/agent-kit
codex plugin add agentkit@agent-kit
codex plugin list                        # agentkit@agent-kit  installed, enabled
```

**Claude Code:**

```
/plugin marketplace add ~/github/agent-kit
/plugin install agentkit@agent-kit
```

That's the whole install. No build step — the repository *is* the marketplace.

The same directory serves both: one manifest per harness (`.claude-plugin/` and
`.codex-plugin/`), `hooks/hooks.json` where each looks for it, and a resolver
that searches both plugin caches. Install it on both and they share one copy of
the skills.

Two differences worth knowing, neither of which needs configuring:

- `SubagentStart` is a Codex event. On Claude Code, spawned workers don't
  receive the injected contract; everything else behaves the same.
- Nothing hardcodes which CLI you're in. The environment contract reports
  `harness=` and `peer-cli=`, so commit attribution credits whichever agent did
  the work, and an adversarial review always goes to the *other* CLI.

### Cross-provider review privacy

The `review-remote-pr` skill can send a PR diff — including filenames and code — to the
external provider behind the peer CLI for adversarial review. Repository ownership is not
consent to disclose private, customer, or NDA-protected code. Before the first cross-provider
send in a session, the agent must name the source payload, destination provider/CLI, and purpose,
then ask for an explicit yes/no confirmation. A decline or missing confirmation sends nothing and
leaves the review gate blocked. An affirmative answer is recorded for that session and provider
so retries do not repeatedly prompt; a changed destination or payload requires confirmation
again.

---

## Set up a repository

Ask the agent to onboard it — the `onboard-repo` skill runs the script *and*
fills in what the script deliberately leaves blank. A session in an un-onboarded
repository says so, unprompted, in the terminal.

To do it by hand instead, run this once inside the repository:

```bash
cd /path/to/your/repo

agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" \
    -maxdepth 4 -type d -path '*/agentkit/*/skills' 2>/dev/null | sort -V | tail -1)

"$agentkit/.shared/scripts/bootstrap-repo.sh" --dry-run   # look first
"$agentkit/.shared/scripts/bootstrap-repo.sh"             # then write
```

This writes two committed files:

- **`.agent/config.env`** — repo slug, trunk branch, board number, Status column
  names, ADR directory, and commented suggestions for your verify commands.
- **`.agent/board.json`** — the board's node IDs, so a status move costs one API
  call instead of seven.

…and the `.gitignore` rules that keep everything *else* under `.agent/` out of
your history — the environment contract carries local paths and your account
name. Re-run with `--force` on a repository bootstrapped before this existed.

Both are readable text. Nothing secret goes in either — tokens, proxies, and CA
paths are refused outright, because these files are committed and anyone who can
open a pull request can influence them.

Then open `.agent/config.env` and uncomment the verify commands it found:

```ini
AGENT_CMD_VERIFY=tools/verify
AGENT_CMD_TEST=<whatever this repo runs for tests>
```

Skills refer to these **by name** (`agent-run.sh --cmd test`), so no skill ever
hardcodes an ecosystem. If your repo drives everything through one dispatcher,
point `AGENT_REPO_RUNNER` at it and the skills will call `runner test` instead.

The declaration is not execution consent. `agent-run.sh --cmd NAME` records no
trust on its first invocation; review the declaration and approve it with
`--approve`, which reads its confirmation from the controlling terminal. That
terminal confirmation is defense-in-depth, **not** a cryptographic human-only
gate. It closes the specific failure it was filed for -- an agent reading an
unapproved-command refusal and re-running the exact `--approve` command the old
refusal printed -- because a non-interactive shell cannot answer the prompt and
the refusal no longer hands back a runnable remedy. It does not authenticate a
human: an agent with arbitrary command execution can allocate a pseudo-terminal
(as this repo's own approval test does) or write the trust record directly,
since it runs as the same user, and no in-band check prevents that. What the
record *does* guarantee is durable and worth having: approval is kept in an
owner-only state directory outside the checkout, and it fingerprints
`config.env`, repository-backed argv paths, and nearby build manifests, so a
changed declaration or repository-backed input cannot inherit an old approval
while ordinary source edits remain runnable. Approval is also an explicit,
logged step -- and under Claude Code, `--approve` surfaces a permission prompt.
Literal commands passed after `--` are caller-supplied and are not covered by
this repository-command approval.

---

## Harness configuration

Three settings decide whether the agent can do its job. Each one here was found
by a real session losing time to its absence — and each failure arrived wearing
someone else's costume, which is why they are worth knowing in advance.

Run this in any repository and it tells you which, if any, you need:

```bash
"$agentkit/.shared/scripts/harness-advice.sh"
```

Silence means nothing needs changing. `onboard-repo` runs it for you.

| Setting | Without it | Looks like |
|---|---|---|
| `sandbox_workspace_write.network_access = true` | No forge calls | **"the token in X is invalid"** — `gh` validates by calling the API, so a blocked network is reported as bad credentials. Costs a re-authentication that cannot help |
| `sandbox_workspace_write.writable_roots = ["<repo>/.git"]` | Every commit, worktree and `.git/info/exclude` needs an approval | A fresh permissions fault, three times a day, each looking unrelated |
| the repository's pinned runtime, active in the launching shell | Every command fails an engine check | `[ERR_PNPM_UNSUPPORTED_ENGINE]` — names the package manager, not the version manager, and not the shell that never activated it. **A version manager switches a shell, not a child process** |

### The risk in `writable_roots`

This is the one that trades something away, so it deserves the detail.

A read-only `.git` is the only thing standing between an agent and the git
*plumbing* — `update-ref`, `reflog expire`, `gc --prune`, `filter-branch` — and
`.git/config` keys like `core.hooksPath` that execute commands during ordinary
git operations, persist after the session, and run as **you** rather than as the
agent.

agentkit refuses those at command level, every time, with no override. Treat
that as a speed bump, not a replacement. The protection moves from the
filesystem to pattern matching, and **the patterns have been evaded in review**:
an external audit found that `git push origin +main`, `git clean --force -d`,
`git branch --delete --force main` and `rm --recursive --force /` all passed
while their short-option spellings were refused. Those four are fixed and
regression-tested, but they were found by reading git's man pages, not by
anything clever — assume more exist.

A read-only mount cannot be evaded by spelling. A pattern can. If you do not
need git plumbing to work unattended, leave `.git` read-only and approve the
occasional write.

**Scope it to one repository's `.git`.** A parent directory like `~/github` hands
every repository under it to any session, and nothing here is repo-aware enough
to stop that. Prefer it per-invocation over a global config entry:

```bash
codex -c 'sandbox_workspace_write.writable_roots=["/path/to/repo/.git"]'
```

On a machine holding work you do not own, don't set it at all. Approvals are
cheap next to that downside.

---

## What the hooks do

| Hook | Behaviour |
|---|---|
| `SessionStart` | Probes the environment once and hands the agent a contract — repo, branch, base, sandbox state, CA bundle, cache roots — plus the list of helpers that exist here. With no `.agent/config.env` it prints how to onboard instead |
| `SubagentStart` | Injects both into every spawned worker. This is the only channel that reaches one |
| `PreToolUse` | Refuses work-destroying commands outright; refuses *once* for a bare helper name or an edit to a file that gates other checks |
| `PostToolUse` | Teaches the cheaper command *after* the call returned real data |
| `Stop` | Won't let a turn finish when a declared verify command hasn't covered the current changes |

Three rules they all follow:

**Nothing that has an alternative gets blocked.** A guard that refuses a command
can end a line of work — a live agent, denied once, answered "It was not run"
and stopped. So the guards let the command run and correct it afterwards, using
a channel measured to reach the model. The agent pays for the wasteful call once
and knows better before the second.

That matters most where nobody is watching. A blocked main session has a human
who can rephrase; a blocked worker is a dead branch, silently.

**They never exit non-zero.** A hook that exits `2` halts the agent instead of
informing it. Every hook exits `0` and says what it wants in JSON.

**Guards need evidence.** A repository with no `.agent/` directory gets nothing
at all. Declaring a verify command is what opts you into the `Stop` check —
declare none and it never fires.

Denials come in exactly two kinds:

**Refused every time** — force-push, `reset --hard`, `clean -f`, deleting trunk,
`gh pr merge`, `--no-verify`, `rm -rf ~|/`. There is no teach-after-the-fact for
a force-push that already landed, and an override that permitted the second
attempt would have it exactly backwards. The list is deliberately short: a long
list of "risky" commands trains an agent to treat denials as noise.

**Refused once, then allowed** — a bare helper name (it cannot succeed; nothing
is on `PATH`), and an edit to a file that decides whether other checks run:
CI definitions, git hooks, harness config. That second one is ordinary work
sometimes and quietly loosening a gate other times, and the diff alone doesn't
say which — so one refusal makes the retry a deliberate choice. Add repo-specific
entries with `AGENT_PROTECTED_PATHS` (additive; a committed file cannot switch
off its own guard).

---

## Verify your changes

```bash
tests/run-tests.sh
```

Eleven gates, then every suite in `tests/` — shellcheck on shipped and test
scripts, `bash -n`, a bash 5.2 compatibility check, every fenced code block in
the skill markdown, ecosystem- harness- and org-neutrality, then the unit
suites. The run prints its own totals, so read them from the run rather than
from here; this file deliberately does not carry a suite count.

**Green does not mean "the tree is good"** — it used to say that, and an external
review then found twenty-two defects through it, several of them in scripts with
no behavioural suite at all (`worktree-commit.sh`, `gh-pr-state.sh`, the
adversarial-review helpers, `ci-gap.sh`). Green means the gates that exist
passed. See `docs/` for the standing review findings.

---

## Repository layout

```
.claude-plugin/marketplace.json   the marketplace, read by both harnesses
agentkit/
  .claude-plugin/plugin.json      one manifest per harness; both are required
  .codex-plugin/plugin.json
  hooks/
    hooks.json                    where both harnesses look for it
    lib/guard-lib.sh              logic the hooks must agree on
    *.sh                          the dispatchers
  skills/
    onboard-repo/
    parallel-issues/
    review-remote-pr/
    .shared/scripts/              the procedural helpers
tests/                            the harness; never shipped in the plugin
docs/                             design specs
```

---

## Requirements

- `bash` 5.2+, `jq`, `git`, and the `gh` CLI with the `project` scope
  (`gh auth refresh -s project`)
- Codex CLI 0.147+ or Claude Code for hooks; the skills work without them

Targets Debian 13 (trixie). Shell commands run through the agent's login shell,
which may be zsh, so every helper is a `bash` script rather than an inline
snippet.

---

## Licence

MIT.
