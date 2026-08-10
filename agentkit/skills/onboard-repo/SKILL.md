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
agentkit=$(sed -n "s/^skills= path=//p" .agent/env-contract.txt 2>/dev/null | head -n 1)
if [[ -z $agentkit ]]; then
    agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" -maxdepth 4 -type d \
        -path '*/agentkit/*/skills' 2>/dev/null | sort -V | tail -1)
    [ -n "$agentkit" ] || agentkit="${CODEX_HOME:-$HOME/.codex}/skills"
fi
[ -d "$agentkit/.shared/scripts" ] || { printf "%s\n" "agentkit: invalid skills path: $agentkit" >&2; exit 1; }
# shellcheck disable=SC2034  # used by every later block; env does not
# persist between tool calls, so each block re-derives it.
shared="$agentkit/.shared/scripts"

contract_path=''
if [[ -r .agent/env-contract.txt ]]; then
    contract_path=$(grep -m1 '^skills= path=' .agent/env-contract.txt)
fi
if [[ -z $contract_path ]]; then
    "$shared/agent-preflight.sh" --worktree "$(git rev-parse --show-toplevel)" 2>/dev/null
fi
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

### If there is no board, or the columns are wrong

`bootstrap-repo.sh` reads a board; it never creates one. When it reports no
board — or lists several and refuses to guess — ask the user which they want,
and only then:

```bash
"$shared/board-setup.sh" --dry-run          # creates a board, canonical columns, links it
"$shared/board-setup.sh"                    # or --project N to re-column an existing one
```

**Do not do this by hand.** The mutation that sets Status columns
(`updateProjectV2Field` with `singleSelectOptions`) replaces the entire option
set and matches nothing by name: every item in every column — including the
columns whose names did not change — comes back unassigned. A session that
found that mutation by introspecting the GraphQL schema fired it and got away
with it only because the board was empty. The helper snapshots first and
restores by name; that is the only reason it is safe on a board with work on it.

Creating a board does **not** link it to the repository, which is why a repo
can be freshly onboarded and still report "no board". The helper links it.

Then re-run Step 1 with `--project N`.

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
"$shared/detect-toolchains.sh" --format gaps
```

**Run the third command even when the file already looks complete** — especially
then. The first two read `.agent/config.env`, which records what a PREVIOUS
onboarding knew; only the detector looks at the repository. A populated file is
a reason to check, not a reason to skip: a session re-onboarding a repository
whose config predated the multi-language detector saw a full command list,
concluded the work was done, and never noticed the C# component beside the
node one.

If `--format gaps` reports nothing new, say so explicitly in Step 9. "Nothing
was missing" and "I did not look" read identically in a report, and only one of
them is worth anything.

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

Start from the detector rather than hand-guessing:

```bash
"$shared/detect-toolchains.sh" --format suggestions
```

Treat every line as a CANDIDATE, not an answer — it is looking at marker files,
not running anything. Nothing here is proven until Step 6 runs it.

**Do not test a candidate by running it yourself first.** Declare it, then run
it once through `agent-run.sh` in Step 6; if it fails there, remove or fix the
declaration. Onboarding a Rust repository this way took a 25-second Clippy pass
and a full test suite twice — once bare to "check", then again to validate —
which is the entire suite's runtime spent proving something the second run
proved anyway. On a monorepo it emits one block per
component, each with its own `AGENT_CMD_<COMPONENT>_<TASK>` and, unless the
component is the repo root, a companion `AGENT_RUNDIR_<COMPONENT>_<TASK>` —
that is the pairing that keeps a component command from running out of the
wrong directory.

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

**Approval is separate from declaration.** A committed `AGENT_CMD_*` value is
repository-controlled data, not permission to execute. Before the first run,
review the declaration and approve the exact current command explicitly:

```bash
"$shared/agent-run.sh" --approve --cmd verify
"$shared/agent-run.sh" --cmd verify
```

Approval lives outside the checkout and fingerprints the declaration plus
repository-backed command inputs. If either changes, `agent-run.sh` refuses to
run until it is reviewed and approved again. This preserves verification after
ordinary source edits without allowing a changed `tools/verify` or package
manifest to inherit an old approval. Literal commands (`agent-run.sh -- ...`)
remain caller-supplied and do not use this repository-command trust record.

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
"$shared/agent-run.sh" --approve --cmd verify
"$shared/agent-run.sh" --cmd verify
```

`--list` prints warnings for values the resolver rejects. A declared command that
does not pass here is not finished work — fix it or remove it before continuing.

**This is the only place a candidate gets run.** A declaration you have to
withdraw costs one edit; running everything twice costs the whole suite's
runtime, every time this skill is used. Declaring first and removing on failure
is cheaper in both directions.

A command that is genuinely too slow for onboarding to wait on — a release build
with LTO, a suite measured in tens of minutes — should not be declared at all
just because it would eventually pass. Leave it to CI, and say so in Step 9.

## Step 7 — commit

Onboarding changes `.gitignore` and adds two files everyone in the repository
inherits, so it goes through whatever review the repository already uses. Check
where you are standing first — a session that skipped this landed its
onboarding commit on `main` of a repo where every other change arrives by pull
request:

```bash
git branch --show-current
git checkout -b chore/agentkit-onboarding     # unless the repo commits to trunk
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

Named repository commands require an explicit approval before their first run
and after a declaration or repository-backed input changes:
`agent-run.sh --approve --cmd <name>`. The approval record is owner-only state
outside the checkout; it is intentionally not a committed config key that a
pull request could change alongside the command.

**`VERIFY` and `TEST` are the only names anything relies on.** Skills reach for
others (`lint`, `build`, `coverage`) with `--if-declared`, so a repository that
declares none of them is not broken — it simply skips those steps. Declare the
names that mean something here, not a checklist.

`AGENT_CMD_VERIFY` (or, failing that, `AGENT_CMD_TEST`) is what opts the
repository into the `Stop` check, and it runs at the end of every turn — so
which of the two you declare decides what every trivial edit costs. Declare neither and end-of-turn verification never fires — which is
a legitimate choice, but make it a stated one rather than an accident.

**Nothing secret belongs in `config.env`.** Tokens, proxies and CA paths are
refused by the resolver: the file is committed, and anyone who can open a pull
request can influence it.
