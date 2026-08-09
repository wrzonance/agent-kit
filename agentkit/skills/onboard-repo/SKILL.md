---
name: onboard-repo
description: >-
  Use when a repository has no .agent/config.env, when the session contract says
  "not onboarded", or when its declared commands, labels, or board mapping are
  missing or wrong. Triggers: /onboard-repo, "onboard this repo", "set up
  agentkit here", "yes, onboard it", "why are the guards inert", "declare the
  verify commands".
---

# Onboard a repository

`bootstrap-repo.sh` discovers what it can and **deliberately leaves the rest
blank**: it suggests commands and labels as commented lines rather than guessing,
because a wrong declaration is worse than an absent one — it gets invoked.

Filling those blanks is a judgement task, which is why it is a skill and not more
script. The cost is one upfront conversation; every later session reads the
result instead of rediscovering it.

**Finish the job.** A repository left with `config.env` but no declared command
is barely better off than an un-onboarded one: the `Stop` verification check has
nothing to enforce and `--cmd` resolves nothing.

---

## Step 0 — resolve the tree

```bash
agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" -maxdepth 4 -type d \
    -path '*/agentkit/*/skills' 2>/dev/null | sort | tail -1)
[ -n "$agentkit" ] || agentkit="${CODEX_HOME:-$HOME/.codex}/skills"
# shellcheck disable=SC2034  # used by every later block; env does not
# persist between tool calls, so each block re-derives it.
shared="$agentkit/.shared/scripts"
```

## Step 1 — look before writing

```bash
"$shared/bootstrap-repo.sh" --dry-run
```

Read the output back to the user in two or three lines: the repo slug, the trunk
branch, and whether a Project board was found. **Stop and ask** if any of it is
wrong — a wrong board number is written into a committed file and every later
session trusts it.

If the repo is already onboarded and you are here to fix it, add `--force`.

## Step 2 — write the files

```bash
"$shared/bootstrap-repo.sh"
```

This writes `.agent/config.env`, `.agent/board.json`, and the `.gitignore` rules
that keep the rest of `.agent/` out of history. If it reports already-tracked
working state, surface that — it needs `git rm --cached`, which is a history
decision for the user to make.

## Step 3 — find what it left blank

```bash
"$shared/repo-config.sh" --list
grep -n '^# AGENT_' .agent/config.env
```

Anything still commented is a blank the script would not guess. In practice:

- **`AGENT_CMD_*`** — the important one. Absent entirely when nothing
  root-runnable was detected.
- **`AGENT_LABEL_TYPES` / `AREAS` / `PRIORITIES`** — the repo's real labels,
  listed but not classified.
- **`AGENT_ADR_DIR`** — only when the repo keeps decision records.
- **`AGENT_PROTECTED_PATHS`** — repo-specific files that gate other checks
  (migrations, a decisions log). CI definitions, git hooks and harness config are
  already covered; this is for what only this repository knows.

## Step 4 — work out the commands

This is the part worth thinking about. Look at what the repository actually runs:
CI workflow steps, a pre-commit hook, a `Makefile`, `package.json` scripts, a
`tools/` directory, `CONTRIBUTING.md`.

Three shapes come up:

**Declare `SETUP` if a fresh checkout needs one.** A worktree starts with none
of the repository's installed dependencies, so without it the first verification
in every parallel worktree fails for a reason unrelated to the change:

```ini
AGENT_CMD_SETUP=<the locked, offline-capable install command>
```

**`VERIFY` is the per-turn gate — make it fast.** `Stop` runs it at the end of
every turn, so its cost is paid on a one-line comment as surely as on a
refactor. A repository that declared only a full suite charged five minutes for
adding one line to a YAML file. Declare the seconds-long gate as `VERIFY` and
keep the slow one as `TEST`:

```ini
AGENT_CMD_VERIFY=<lint and typecheck, seconds>
AGENT_CMD_TEST=<the full suite, minutes>
```

**One entry point.** Declare it and move on.

```ini
AGENT_CMD_VERIFY=tools/verify
```

**One ecosystem, several commands.** Declare each by name. Values are argv, so
no shell syntax — no pipes, no `&&`, no `cd`. A command that must run inside a
component says so with a companion key rather than by wrapping itself:

```ini
AGENT_CMD_DASHBOARD_TEST=node_modules/.bin/vitest run
AGENT_RUNDIR_DASHBOARD_TEST=dashboard
```

Reach for that whenever the root-runnable form looks strained. Forcing a
component command to run from the root is how one of these ended up globbing
into `node_modules` and running a dependency's test suite.

```ini
AGENT_CMD_TEST=<the repo's test command>
AGENT_CMD_LINT=<the repo's lint command>
```

**A polyglot monorepo** — several components, no single root-runnable command.
Do not invent one silently. Either declare the per-component commands that *do*
run from the root:

```ini
AGENT_CMD_LINT=server/.venv/bin/ruff check server
```

…or propose a small `tools/verify` dispatcher and let the user decide. Say which
you are recommending and why; a dispatcher is a change to their repository, so it
is their call. Note that once `tools/verify` exists, bootstrap detects it on its
own next time.

**Compare what you declared against what CI enforces** — `"$shared/ci-gap.sh"`
lists the pull-request gates no declared command covers. A live run had `VERIFY`
pass locally and CI fail, because CI checked a source-size limit the declared
command did not. `Stop` was guarding less than it appeared to, and nothing said
so until the push. Read the CI definition, list its gates, and say plainly which
ones no declared command covers — that sentence is the deliverable, even when
you cannot close the gap.

**Never declare a command you have not run.** A command that fails on first use
teaches the agent to distrust the whole contract, and `Stop` blocks turns on it.

## Step 5 — propose everything at once

Give the user **one message** containing the complete proposed additions —
commands, label classification, ADR directory — with a one-line reason for each.
Not a question per line.

Say plainly what you could not determine, and what the consequence is: "no test
command runs from the root, so `Stop` will not gate on tests until a dispatcher
exists" is useful; silently omitting it is not.

## Step 6 — write and validate

Edit `.agent/config.env` directly. Values are read line-wise and never sourced,
so no quoting is needed — write the command exactly as you would type it,
unquoted, arguments and all.

Then prove it parses, and prove every command you declared actually runs:

```bash
"$shared/repo-config.sh" --list
# ...then once per name you declared:
"$shared/agent-run.sh" --cmd verify
```

`--list` prints warnings for values the resolver rejects. A declared command that
does not pass here is not finished work — fix it or remove it before continuing.

## Step 7 — commit

```bash
git add .agent/config.env .agent/board.json .gitignore
```

Commit with the trailer from the contract's `harness=` line. `.agent/config.env`
and `.agent/board.json` are meant to be committed; everything else under
`.agent/` is working state the new ignore rules exclude.

## Step 8 — check the harness itself

```bash
"$shared/harness-advice.sh"
```

Silent means nothing needs changing. Anything it prints is a setting **the
operator must decide on** — never apply one yourself, and never edit their
harness config. Relay the block verbatim, including the risk note: the
writable-roots setting trades a filesystem protection for a pattern-based one,
and that is theirs to weigh.

This is what turns "gh says my token is invalid" and "why does every commit need
approval" into a one-line decision, instead of the twelve-command investigation
each of them has cost in practice.

## Step 9 — report

Tell the user what is now declared, what you left blank and why, and what changed
as a result: which guards became active, and what `Stop` will now enforce.

---

## Reference

| Key | What it does |
|---|---|
| `AGENT_REPO_SLUG` | `owner/name`, so nothing re-probes the remote |
| `AGENT_BASE_BRANCH` | trunk to branch from and target PRs at |
| `AGENT_PROJECT_OWNER` / `AGENT_PROJECT_NUMBER` | the Project board |
| `AGENT_STATUS_VOCAB` | the board's Status column names, in order |
| `AGENT_CMD_<NAME>` | a command invoked as `agent-run.sh --cmd <name>` |
| `AGENT_RUNDIR_<NAME>` | the directory that command runs in, relative to the repo root |
| `AGENT_CMD_SETUP` | how a FRESH worktree installs dependencies; parallel work runs it before the first verify |
| `AGENT_REPO_RUNNER` | a single dispatcher; skills call `runner <name>` instead |
| `AGENT_WORKTREE_ROOT` | where isolated worktrees are created |
| `AGENT_PROTECTED_PATHS` | extra paths that gate other checks; edits to them are refused once |
| `AGENT_LABEL_TYPES` / `AREAS` / `PRIORITIES` | labels to reuse rather than invent |

`AGENT_CMD_VERIFY` (or, failing that, `AGENT_CMD_TEST`) is what opts the
repository into the `Stop` check, and it runs at the end of every turn — so
which of the two you declare decides what every trivial edit costs. Declare neither and end-of-turn verification never fires — which is
a legitimate choice, but make it a stated one rather than an accident.

**Nothing secret belongs in `config.env`.** Tokens, proxies and CA paths are
refused by the resolver: the file is committed, and anyone who can open a pull
request can influence it.
