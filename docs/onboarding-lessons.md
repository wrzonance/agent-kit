# Onboarding lessons

Design notes, not runtime instructions — `onboard-repo/SKILL.md` states the
rule each of these produced in one sentence; this file keeps the incident that
motivated it, for whoever next wants to relax one of these rules and needs to
know what happens if they do.

## Board Status columns: the mutation that wipes assignments

`updateProjectV2Field` with `singleSelectOptions` replaces the entire option
set and matches nothing by name — every item in every column, including
columns whose names didn't change, comes back unassigned. A session found this
mutation by introspecting the GraphQL schema and fired it directly instead of
going through `board-setup.sh`. It got away with it only because the board
happened to be empty at the time; on a board with live work it would have
silently unassigned every item's status. The helper survives this because it
snapshots assignments first and restores them by name after the mutation —
that snapshot-and-restore is the entire reason hand-rolling the mutation is
unsafe and the helper isn't.

## Re-onboarding a stale config: the missed C# component

`.agent/config.env` and `repo-config.sh --list` both read what a *previous*
onboarding recorded — not the repository as it stands now. A session
re-onboarding a repository whose config predated the multi-language toolchain
detector saw a populated, plausible-looking command list, concluded the
config was already complete, and never ran `detect-toolchains.sh --format
gaps`. It never noticed the repository had grown a C# component alongside the
original Node one — the config stayed silently incomplete because nothing
prompted a fresh look at the tree itself.

## Validating a candidate command by running it twice

The instinct to "check the command works" before declaring it is natural, but
running a candidate once to check and once through `agent-run.sh` to validate
pays the same cost twice. Onboarding a Rust repository this way ran a
25-second Clippy pass and a full test suite twice — bare, then again through
the declaration — spending the entire suite's runtime a second time to prove
something the first run already proved. Declare first; let Step 6's single run
through `agent-run.sh` be the only validation. A wrong declaration costs one
edit to fix; running everything twice costs the whole suite's runtime, every
time this skill is used.

## VERIFY declared as the full suite

`Stop` runs whatever is declared as `AGENT_CMD_VERIFY` at the end of *every*
turn. A repository that declared only its full test suite as `VERIFY` (instead
of splitting a fast lint/typecheck out as `VERIFY` and keeping the full suite
as `TEST`) charged five minutes of suite runtime for adding one line to a YAML
file — every single turn, forever, until someone noticed and re-declared it.

*(The `Stop` hook this lesson describes was later removed — see the
[kill-turn-gate plan](superpowers/plans/2026-08-19-kill-turn-gate.md) — but
splitting `VERIFY` from `TEST` still keeps whichever command you run by hand
fast.)*

## Component commands forced to run from the repo root

A command declared to run from the repository root instead of getting its own
`AGENT_RUNDIR_<COMPONENT>_<TASK>` will run wherever the root's shell globs
land. One onboarding forced a component's test command to run root-relative
instead of giving it a rundir; the glob it used to find test files matched
into `node_modules` and ran a dependency's own test suite instead of the
repository's, silently gathering "passing" results for tests that were never
the point.

## VERIFY passing, CI failing

A repository's declared `AGENT_CMD_VERIFY` passed locally on every turn, and
the same repository's CI failed the same change on push — CI enforced a
source-size limit that no declared command checked. `Stop` had been guarding
less than it appeared to the whole time, and nothing surfaced the gap until
the push failed. This is why `ci-gap.sh` and "read plainly which CI gates
nothing declared covers" is worth saying even when the gap can't be closed
during onboarding itself — a stated gap is a known risk; a silent one is a
surprise at push time.

*(`Stop` no longer exists — nothing runs `AGENT_CMD_VERIFY` automatically — so
this gap now applies to whatever you run by hand, not just what a hook ran for
you.)*

## Onboarding commit landed on `main`

A session that wrote `.agent/config.env` and `.agent/board.json` without
first checking `git branch --show-current` committed the onboarding change
directly to `main`, in a repository where every other change in its history
had arrived by pull request. The fix cost a rebase and an apology; checking
the current branch before the first `git add` costs one command.

## The twelve-command investigation `harness-advice.sh` replaces

Before `harness-advice.sh` existed, diagnosing a symptom like "`gh` says my
token is invalid" or "why does every commit need approval" meant manually
working back through harness settings, plugin cache versions, and permission
config — a real session logged roughly twelve exploratory commands to land on
the actual setting. `harness-advice.sh` prints the same diagnosis directly; the
onboarding skill's job is just to relay it verbatim to the operator, not to
re-derive it by hand.
