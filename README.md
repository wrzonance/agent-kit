# Agent Kit

Skills, lifecycle hooks, and a per-repository contract that let a coding agent do
board-driven work without rediscovering the same facts on every run.

Works with **Codex CLI** and **Claude Code** from the same directory.

---

## What's in it

| Piece | What it does |
|---|---|
| **`parallel-issues`** skill | Triage a GitHub Projects board, split independent issues across worktrees, drive each to a draft PR |
| **`review-remote-pr`** skill | Take a PR from draft to green: CI, review threads, an adversarial review, and the board move |
| **`.shared/scripts`** | The procedural half — preflight, command runner, board mover, one-call triage, commit guard |
| **Four hooks** | Inject the environment contract, and stop the agent spending calls it doesn't need to |

The idea throughout: **a repository declares its own facts once**, and everything
else reads them instead of guessing.

---

## Install

```bash
git clone <this repo> ~/github/agent-kit

codex plugin marketplace add ~/github/agent-kit
codex plugin add agentkit@agent-kit
```

That's the whole install. No build step — the repository *is* the marketplace.

Claude Code reads the same `.claude-plugin/marketplace.json`, so the identical
directory installs there too.

Verify:

```bash
codex plugin list      # agentkit@agent-kit  installed, enabled
```

---

## Set up a repository

Run this once inside any repository you want the skills to work on:

```bash
cd /path/to/your/repo

agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -maxdepth 4 -type d \
    -path '*/agentkit/*/skills' 2>/dev/null | sort | tail -1)

"$agentkit/.shared/scripts/bootstrap-repo.sh" --dry-run   # look first
"$agentkit/.shared/scripts/bootstrap-repo.sh"             # then write

printf '.agent/cache/\n' >> .gitignore
```

This writes two committed files:

- **`.agent/config.env`** — repo slug, trunk branch, board number, Status column
  names, ADR directory, and commented suggestions for your verify commands.
- **`.agent/board.json`** — the board's node IDs, so a status move costs one API
  call instead of seven.

Both are readable text. Nothing secret goes in either — tokens, proxies, and CA
paths are refused outright, because these files are committed and anyone who can
open a pull request can influence them.

Then open `.agent/config.env` and uncomment the verify commands it found:

```bash
AGENT_CMD_VERIFY=tools/verify
AGENT_CMD_TEST=npm run test
```

Skills refer to these **by name** (`agent-run.sh --cmd test`), so no skill ever
hardcodes an ecosystem. If your repo drives everything through one dispatcher,
point `AGENT_REPO_RUNNER` at it and the skills will call `runner test` instead.

---

## What the hooks do

| Hook | Behaviour |
|---|---|
| `SessionStart` | Probes the environment once and hands the agent a twelve-line contract, so it starts knowing the repo, branch, base, sandbox state, CA bundle, and cache roots. In a repository with no `.agent/config.env`, it also prints how to onboard it — otherwise the guards below stay inert and silent, which looks exactly like breakage |
| `SubagentStart` | Injects that same contract into every spawned worker |
| `PreToolUse` | Blocks four wasteful command shapes and tells the agent the command that works instead |
| `Stop` | Won't let a turn finish when a declared verify command hasn't covered the current changes |

Two rules they all follow:

**They never exit non-zero.** A hook that exits `2` halts the agent instead of
informing it. Every hook exits `0` and says what it wants in JSON, so the agent
reads the reason and adapts.

**Guards need evidence.** A repository with no `.agent/` directory gets no
denials at all. Declaring a verify command is what opts you into the `Stop`
check — declare none and it never fires.

---

## Verify your changes

```bash
tests/run-tests.sh
```

Ten gates and eight suites — shellcheck on shipped and test scripts, `bash -n`,
a bash 5.2 compatibility check, every fenced code block in the skill markdown,
plus ~280 assertions. It is the only gate; if it is green, the tree is good.

---

## Repository layout

```
.claude-plugin/marketplace.json   read by Codex AND Claude Code
agentkit/
  .codex-plugin/plugin.json
  hooks.json                      declares the four events
  hooks/                          the dispatchers
  skills/
    parallel-issues/
    review-remote-pr/
    .shared/scripts/              the procedural helpers
tests/                            the harness; never shipped in the plugin
docs/                             design specs and implementation plans
```

---

## Requirements

- `bash` 5.2+, `jq`, `git`, and the `gh` CLI with the `project` scope
  (`gh auth refresh -s project`)
- Codex CLI 0.147+ for hooks; the skills work without them

Targets Debian 13 (trixie). Shell commands run through the agent's login shell,
which may be zsh, so every helper is a `bash` script rather than an inline
snippet.

---

## Licence

MIT.
