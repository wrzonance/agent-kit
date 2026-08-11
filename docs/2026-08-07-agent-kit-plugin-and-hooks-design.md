# Dual-harness plugin packaging, lifecycle hooks, and declared repo commands

**Date:** 2026-08-07
**Status:** Approved — ready for implementation planning
**Scope:** the agent skill tree (`parallel-issues`, `review-remote-pr`, `.shared`)
**Predecessors:** Task 1 (bash conversion), Task 2 (`.agent/` config + single-call triage)

## Problem

Three separate gaps, one root cause: the tree has no way to be *told* things, so it
either guesses or instructs the agent to remember.

1. **No lifecycle integration.** The environment contract costs a tool call every
   session, and `parallel-issues` *instructs* the agent to paste it verbatim into
   every spawned worker prompt. An instruction can be forgotten; the recorded
   consequence is a worker rediscovering caches, `PYTHONPATH`, and the git
   `index.lock` elevation one failure at a time.
2. **Ecosystem names are baked into the skills.** Both SKILL.md files demonstrate
   verification as `pnpm lint` / `pnpm test`. A repository driven by a bespoke
   dispatcher, `make`, `uv`, `cargo`, or `just` gets an example that is simply
   wrong, and an agent copying it burns a failed call discovering that. Measured
   across three repositories on one machine: one uses a bespoke `tools/verify`
   *plus* 22 npm scripts, one is Cargo, one is neither.
3. **Distribution is a tarball.** There is no version, no upgrade path, and no way
   to declare hooks at all.

## Findings that shape the design

Established empirically against codex-cli 0.147.0 by reading the schemas embedded
in the binary and by running the CLI, not from documentation.

| Finding | Consequence |
|---|---|
| 11 hook events exist with complete JSON schemas; `hooks` is a **stable, enabled** feature | A hook layer is possible |
| The `hooks.json` format and wire protocol are **identical to Claude Code's**, and Codex accepts `.claude-plugin/marketplace.json` | One plugin directory serves both harnesses |
| Hooks are **plugin-scoped** — neither repo-level `.codex/hooks.json` nor `$CODEX_HOME/hooks.json` fires | Packaging as a plugin is a precondition, not a preference |
| A local marketplace must live under `$HOME`; plugin source paths must start with `./` | Constrains the install instructions |
| `SessionStart` output supports `additionalContext` | Its output reaches model context |
| `PreToolUse` supports `permissionDecision: allow\|deny\|ask`, and `deny` overrides even `bypassPermissions` | Guards cannot be bypassed by permission mode |
| The binary carries a *"does not support hook input rewriting for payload"* string | `updatedInput` rewriting is at best selective; do not rely on it |
| **Exit code 2 makes the agent stop and wait for the user** rather than adapt ([claude-code#24327](https://github.com/anthropics/claude-code/issues/24327)); JSON `deny` with a `reason` is read and acted on | Never exit 2 |
| Codex executes shell commands via `$SHELL -lc`, which is zsh on the target machine | Skill-block bashisms are a live hazard; keep logic in bash scripts |
| **Hooks do not fire under `codex exec`**, even with the plugin installed and `bypass_hook_trust=true` | The hook layer is unverified and sequences last |

That last row is the design's open risk and is treated as such throughout.

## Non-goals

- Making any hook, script, or skill aware of a specific organization, repository,
  board, or ecosystem. Repository facts live only in that repository's `.agent/`.
- Relying on `updatedInput` to rewrite tool input.
- Blocking work in repositories that have not opted in. Every hook does strictly
  less when `.agent/` is absent — never something different.
- Replacing the skills' own verification gates. The `Stop` hook checks that
  verification *happened*; it does not re-run it.

## Design

### Packaging

```
agent-kit/                          a git repository
  .claude-plugin/marketplace.json   read by BOTH Codex and Claude Code
  agentkit/
    .codex-plugin/plugin.json
    hooks.json                      declares the four events
    hooks/                          thin dispatchers, bash
      session-start.sh
      subagent-start.sh
      pre-tool-use.sh
      stop.sh
    skills/
      parallel-issues/
      review-remote-pr/
      .shared/
```

Install, replacing the tarball:

```bash
codex plugin marketplace add ~/agent-kit
codex plugin add agentkit@agent-kit
```

**Hooks contain no policy.** Each dispatcher reads the event JSON on stdin, calls
one existing `.shared/scripts/` helper, and emits JSON. `session-start.sh` runs
`agent-preflight.sh` — the same script the skill documents. One implementation of
every fact means a hook and a skill cannot disagree, which is the specific failure
mode that made the previous hook set harmful.

**Two invariants, applied to every hook:**

1. **Never `exit 2`.** Always exit 0 with JSON on stdout. A blocked action returns
   `permissionDecision: "deny"` with a `reason` naming the correct command.
2. **Guards fail closed; context fails open.** A guard that cannot decide allows. A
   context hook that cannot build its payload returns empty context, never a block.

### The four hooks

**`SessionStart`** → `additionalContext` carrying the twelve-line environment
contract, present before turn one instead of costing a tool call.

The preflight probes `gh`, which is a network round-trip, and this fires on every
session. So the hook reuses `<worktree>/.agent/env-contract.txt` when its mtime is
under 30 minutes old and re-probes otherwise. When `source == "compact"` it always
re-emits, because compaction is exactly when that context was lost. Fails open: no
contract → no `additionalContext`, session proceeds normally.

**`SubagentStart`** → the same cached contract, injected into every spawned worker.

This replaces an instruction the agent can forget with a mechanism that cannot. It
reads the file the parent already wrote and performs no probe of its own. Fails
open identically.

**`PreToolUse`** (matcher `Bash`) → `deny` with a reason, or `allow`.

**No `updatedInput` rewriting.** Rewrite support is at best selective, and a reason
the agent reads teaches the correct command where a silent rewrite hides it.

Four rules, each traceable to an observed failure, each conditional on evidence:

| Command shape | Condition | Reason returned |
|---|---|---|
| bare `<helper>.sh …` with no `/` | always | the `"$codex_home/skills/…"` form |
| `git add -A` / `git add .` | always | `worktree-commit.sh`; `.agent/` is untracked working state |
| `gh project list\|item-list\|field-list` | `.agent/board.json` exists | `move-github-project-item.sh` — seven calls become one |
| `gh api …/timeline`, or `gh issue view` | `.agent/config.env` exists | `triage-issues.sh` — the whole storm in one call |

Anything not matching allows. A repository with no `.agent/` receives no denial
from the last two rules at all.

**`Stop`** → `decision: "block"` with a reason, or allow.

`agent-run.sh` writes `<repo>/.agent/cache/verify-stamp` on a successful run.

The rule, stated precisely so it is reproducible. **Declaring a verify command is
the opt-in**; a repository that declares none is never blocked:

1. Resolve the verify command. Not resolvable → **allow**.
2. Collect tracked files reported changed by `git status --porcelain` (staged,
   unstaged, and untracked-but-not-ignored). Empty → **allow**.
3. No `verify-stamp` → **block**: a verify command is declared and there are
   changes, but verification never ran.
4. Any changed file's mtime newer than the stamp's → **block**.
5. Otherwise → **allow**.

`reason` names the exact command to run, so the agent acts on it rather than
guessing.

This deliberately replaces the previous hook's blind 300-second re-verify, which
duplicated work the skills' own gates had already done — the conflict that made
hooks feel harmful. This hook never runs verification itself; it only checks that
verification happened.

### Declared commands

`agent-run.sh` gains `--cmd <name>`:

```bash
"$codex_home/skills/.shared/scripts/agent-run.sh" --cmd test
"$codex_home/skills/.shared/scripts/agent-run.sh" --cmd verify
```

Every `pnpm lint` / `pnpm test` example in both SKILL.md files becomes this form.
No ecosystem name survives in the shipped tree.

Resolution order:

1. `AGENT_CMD_<NAME>` from `.agent/config.env`, parsed to argv
2. else the existing runner (`AGENT_REPO_RUNNER` / `.agent/runner`) invoked as
   `runner <name>`
3. else exit 2 naming exactly which key to add

The "never exit 2" rule above governs **hook dispatchers**, where exit 2 halts the
agent instead of informing it. `agent-run.sh` is an ordinary script the agent
invokes directly, and 2 is this tree's established usage-error code; its stderr is
returned to the agent as normal tool output. The two cases are unrelated.

Step 2 matters: a bespoke dispatcher **is** the runner, and `runner test` is
already how the runner convention invokes it. No special case is required for it.

**The command is argv, never a shell string.** Unquoted spaces separate tokens;
single or double quotes group spaces into one token, and the resulting argv is
`exec`'d directly. `;`, `|`, `&`, backticks, `$(…)`, redirects, backslashes, and
newlines are rejected at validation rather than interpreted. This also removes
the shell question entirely — nothing passes through a login shell, so the
zsh-versus-bash split cannot affect it. A repository that genuinely needs shell
syntax uses `.agent/runner`, which is an executable it already controls.

New `config.env` keys, validated as above: `AGENT_CMD_VERIFY`, `AGENT_CMD_TEST`,
`AGENT_CMD_LINT`, `AGENT_CMD_TYPECHECK`, `AGENT_CMD_BUILD`.

**`bootstrap-repo.sh` suggests, never guesses.** It probes for `tools/verify`,
`bin/verify`, `scripts/verify`, `package.json` scripts, `Makefile` targets,
`justfile`, `Taskfile.yml`, `Cargo.toml`, and `pyproject.toml`, then emits
commented `# AGENT_CMD_TEST=…` lines. Where a repository has both a bespoke
dispatcher and 22 npm scripts, it surfaces both and lets the human choose; it does
not decide which is canonical. This is the same honest pattern already used for
the label taxonomy.

## Failure behavior

| Condition | Behavior |
|---|---|
| No `.agent/` at all | Hooks emit no context and no denials; `--cmd` falls to the runner or exits 2 |
| `agent-preflight.sh` fails or is missing | `SessionStart`/`SubagentStart` emit empty context; session proceeds |
| `PreToolUse` cannot parse its input | Allow. A guard that cannot decide must not block |
| `Stop` finds no stamp, no verify command, or no edits | Allow |
| A hook script itself errors | Exit 0 with `{}`; never exit 2, never block on a hook bug |
| `codex` absent | Plugin integration tests skip; everything else still runs |
| Hooks never fire (the open risk) | The tree behaves exactly as it does today; nothing regresses |

## Testing

- **Hook contract tests.** Feed each hook its documented input JSON on stdin and
  assert the emitted JSON's required fields and enum values with `jq`. The four
  authoritative output schemas are extracted once from the codex binary and
  committed as fixtures, so tests check Codex's real contract rather than a reading
  of it. Verified extractable for all four events.
- **`PreToolUse` rule tests.** A table of command strings in, expected
  `allow`/`deny` and reason substring out. Every rule gets a positive case, a
  negative case, and a no-evidence case proving it allows when `.agent/` is absent.
- **Command-resolution tests.** `--cmd` against a declared key, against a runner
  fallback, against neither, and against every rejected metacharacter.
- **Plugin integration test.** Create a temp `CODEX_HOME`, run `codex plugin
  marketplace add` and `codex plugin add` against the built plugin, assert it
  registers as `installed, enabled`. This path is already proven to work, so it is
  a real integration test. Skips cleanly when `codex` is absent.
- **Existing gates unchanged:** `shellcheck -S style`, `bash -n`, the bash-5.2
  gate, markdown block extraction, the bare-invocation gate, the vendor checksum,
  and org-neutrality.

## Implementation sequencing

Ordered so that the unverified capability lands last, where a negative result costs
least. Each layer leaves the tree green and is independently useful.

1. **Declared commands** — `--cmd` in `agent-run.sh`, the `AGENT_CMD_*` keys, the
   bootstrap suggestions, and the SKILL.md example rewrite. Removes the last
   ecosystem names from the tree. Depends on nothing new.
2. **Plugin packaging** — the directory restructure, both manifests, and the
   integration test. Delivers a real install and upgrade path on its own, whether
   or not hooks ever fire.
3. **The hook layer** — the four dispatchers, `hooks.json`, the verify stamp in
   `agent-run.sh`, and the contract fixtures.

## Open risk

Hooks are not known to fire. They do not fire under `codex exec` with a plugin
installed, enabled, and `bypass_hook_trust=true`; the likely explanation is that
they are wired to the interactive session path, which cannot be tested from a
non-interactive harness. This must be confirmed interactively before layer 3 is
worth building:

```bash
cd ~/github/<any-repo-with-the-plugin> && codex   # then ask it to run a trivial shell command
```

If hooks turn out not to fire in this version, layers 1 and 2 still stand on their
own, and layer 3's dispatchers remain valid — they are plain scripts with tested
input and output contracts, usable the moment the capability lands.
