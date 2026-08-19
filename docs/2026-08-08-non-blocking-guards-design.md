# Non-blocking guards: teach deterministically, never stop the work

**Date:** 2026-08-08
**Status:** Approved — probe answered 2026-08-08 (§3), ready for implementation planning
**Scope:** `agentkit/hooks/` (all four dispatchers), `.shared/scripts` messaging
**Predecessors:** the plugin/hooks design (2026-08-07), the `.agent/` config design (2026-08-07)

---

## 1. Why

The guards currently work by permanent denial. Three sessions of live evidence
say that is the wrong primitive.

**It contradicts the tree's own design.** `triage-issues.sh` documents, in its
own source, that it deliberately omits issue bodies because "the agent reads the
body of the two or three issues it actually picks up rather than all thirty."
Rule 4 then denies `gh issue view` permanently. The digest is built around a
follow-up call the guard forbids. There is no override.

**A deny does not reliably redirect — sometimes it terminates.** Denied
`gh project item-list`, a live agent answered *"It was not run"* and stopped. It
did not reach for the helper the message named. One turn of work was lost, not
redirected.

**Enumerating `gh` is unwinnable.** `gh` has hundreds of command shapes. Any
guard built by listing the bad ones is permanently incomplete, and any guard
built by denying the class is permanently over-broad. Neither converges.

The third point matters most for autonomy. A blocked *main* session has a human
watching who can rephrase. A blocked *worker* has nobody: under `parallel-issues`
a dead worker is a dead branch, silently. **A hook must never be able to stop
autonomous work.**

## 2. Goals and non-goals

**Goals**

- The agent learns each lesson **at most once per session**, and never re-learns it.
- Worst case **≤3 wasted tool calls per session**; target **0**.
- Every guard leaves a path forward the agent will actually take.
- Subagents are never blocked into a dead branch.
- Guards stay deterministic and testable.

**Non-goals**

- Preventing a determined agent from being wasteful. This is teaching, not
  policing. An agent that ignores the briefing and issues twelve calls is
  allowed to. We measure it; we do not block it.
- Covering every `gh` shape. Guards fire only where a **deterministic helper is
  strictly better**. A denial that offers no alternative is worse than allowing.

## 3. The probe that decided the architecture — ANSWERED

**Measured 2026-08-08 with the rig in `tests/probe/`. Result: the guards do not
need to block at all.**

`PostToolUse` accepts `additionalContext`, and **it reaches the model**. Given a
code word through that channel and then asked for it while forbidden from using
any tool, the agent returned `QX7-MARMOSET-VELLUM-3391` exactly. The channel is
the same one `SessionStart` uses, and it carries into the model's context, not
merely onto the operator's screen.

This makes **teach-after-the-fact** the primary mechanism (§4, Layer 1):

- the command runs and returns real data — zero wasted calls
- `PreToolUse` stays silent for every teachable rule, so it is *structurally
  incapable* of halting work, which is the property autonomy needs
- no per-session state, so the deny-loop hazard that dominated §7 largely
  disappears

`systemMessage`, the field originally proposed, was **not needed and not used**.
The runtime distinguishes it from `additionalContext`; only the latter was shown
to reach the model.

`PreToolUse` payload fields, recorded rather than assumed:

```
cwd  hook_event_name  model  permission_mode  session_id
tool_input  tool_name  tool_use_id  transcript_path  turn_id
```

Two findings worth carrying forward. **A null run reads exactly like a negative
one**: the first attempt returned "no code word" because the agent had asked
whether to proceed and run nothing at all, so no context was ever sent. The
reader now reports whether the code word was delivered before any conclusion is
drawn from the answer. And **subagent availability varies by session** — the
session that answered this probe enumerated its tools and had no dispatch
capability, while earlier sessions in the same repository spawned workers
freely.

### The original probe design (retained for the record)

The `PreToolUse` output schema carries `systemMessage` as a top-level string,
independent of `hookSpecificOutput.permissionDecision`. If a hook can emit

```json
{"systemMessage": "..."}
```

with **no** `permissionDecision`, the tool call proceeds *and* the agent is
taught — zero wasted calls, and no possibility of stopping work. That is a
strictly better primitive than anything else in this document.

**It must be probed, not assumed.** The same embedded schema lists
`permissionDecision: "allow"`, which the runtime rejects outright. The schema
describes intent, not behavior.

Two questions, one live session each:

- **P1** — Does a `systemMessage` with no `permissionDecision` let the call run?
- **P2** — Does that text reach the **model**, or only the user's terminal? If it
  is user-only it teaches nobody and is useless here.

**P2 is the load-bearing one.** Probe by emitting a `systemMessage` containing a
specific token and then asking the agent, in the next turn, to repeat it.

| Outcome | Architecture |
|---|---|
| P1 and P2 both yes | **Advisory mode** is primary (§4, Layer 1). Layer 2 exists only for the staging guard |
| P1 yes, P2 no | Layer 1 is dropped. Layer 0 + Layer 2 carry everything |
| P1 no | Layer 1 is dropped. Same as above |

The rest of this spec is written so that Layers 0 and 2 stand alone. Layer 1 is
an accelerator, not a dependency.

## 4. Architecture — three layers

### Layer 0 — the curriculum, in context, at zero cost

`SessionStart` and `SubagentStart` already inject an environment contract the
agent demonstrably honors: after it landed, agents stopped re-probing the repo
slug. The same channel carries a **tooling contract**: the helpers that exist,
and the one question each answers.

This is the primary defense against re-learning, because it arrives before the
first mistake and costs nothing.

Constraints:

- **Only helpers that resolve.** Each entry is verified on disk before it is
  named. A curriculum that names a missing script teaches a broken path — the
  exact failure the `no pre-plugin paths` gate exists to catch.
- **Only helpers relevant to this repository.** No `.agent/config.env` means no
  board section; the onboarding notice takes its place.
- **Budget: ~12 lines.** It competes with the environment contract for the
  agent's attention. If it grows past that, it is a skill, not a contract.

### Layer 1 — teach after the fact (confirmed available, §3)

`PreToolUse` stays **silent** for every teachable rule. The command runs, returns
its data, and `PostToolUse` then puts the better command into the model's context
through `additionalContext`:

> You just ran `gh issue view 442`. For board state and cross-referenced pull
> requests, `triage-issues.sh` returns all of it in one call.

Applies to board discovery and per-issue triage. **Cost: zero wasted calls** —
the agent pays for the call it wanted, gets the real answer, and knows better
before the second one. It cannot halt a session or strand a worker, because
nothing is ever refused.

Budgeted once per rule class per session: an advisory repeated on every call is
noise, and noise is how the environment contract stops being read. That budget
is the only state Layer 1 needs, and a lost flag costs a duplicate sentence
rather than a blocked command — so the §6 fail-open rule is not load-bearing
here the way it is for Layer 2.

### Layer 2 — deny-once, with an explicit override

Where a denial is still worth one call, it fires **once per rule class per
session**, and the message states plainly that the retry will be permitted:

> If this exact command is what the task needs, run it again — it will be allowed.

That sentence is **mandatory, not decorative**. Without it the observed agent
behavior is to stop and report, which converts a two-stage guard into a
one-stage halt. The whole design rests on the agent knowing stage two exists.

After the brief, the rule class is open for the remainder of the session.

### Which rules go where

| Rule | Trigger | Better answer | Layer |
|---|---|---|---|
| Board discovery | `gh project list\|item-list\|field-list` | `triage-issues.sh` (read), `move-github-project-item.sh` (move) | **1** |
| Per-issue triage | `gh api …/timeline`, `gh issue view` | `triage-issues.sh` | **1** |
| Bare helper path | `<helper>.sh` in command position | the resolver | **2** — the only remaining denial |
| Blanket staging | `git add -A\|--all\|.` | correct ignore rules (§4.1) | **1** |

Layer 2 survives for exactly one rule. A bare helper invocation cannot succeed —
nothing in the tree is on `PATH` — so letting it run buys a guaranteed
"command not found" and teaches the same lesson one call later. Denying is
cheaper *and* the failure is self-evident, so the risk of the agent giving up is
low. Everything else teaches after the fact.

`gh issue view` moves to advisory or deny-once either way, which resolves the
§1 contradiction: reading an issue body becomes possible again.

### 4.1 Staging: enforced by git, not by a hook

The staging guard is **removed as a denial**, and the thing it was protecting is
handed to the mechanism that can actually enforce it.

`bootstrap-repo.sh` currently *prints* `add to .gitignore: .agent/cache/` and
writes nothing. Two problems follow:

- **Advice that is not applied is not protection.** A bootstrapped repository can
  reach steady state with no ignore rule at all, which is the case in the
  repository this was first exercised against.
- **`.agent/cache/` is the wrong pattern.** It leaves `env-contract.txt` and
  `logs/` tracked-eligible. The contract is probe output: it carries the local
  home path, the CA bundle location, and the authenticated account name. That is
  machine-specific detail with no business in a shared history.

Bootstrap instead **writes** an allowlist, which states the intent directly —
everything under `.agent/` is working state except the two declared files:

```gitignore
.agent/*
!.agent/config.env
!.agent/board.json
```

With that in place `git add -A` is simply correct, and no hook is needed to make
it so. Git enforces it deterministically, offline, for every tool and every
human — not just for agents whose commands happen to match a pattern.

A Layer 1 advisory naming `worktree-commit.sh` may still be attached if §3
allows, purely as a nudge toward the helper. It is not protection and does not
gate anything.

**Migration:** repositories bootstrapped before this change have no ignore rule.
`bootstrap-repo.sh --force` rewrites it; the change is additive and safe to
re-run. Already-committed contract or log files must be removed from the index
separately — bootstrap reports them rather than deleting them.

## 5. Subagent policy

**Workers are never denied.** A worker that stops is a dead branch nobody sees;
the parent can absorb a wasted call, a worker cannot.

- Workers receive Layer 0 through `SubagentStart` — the same curriculum, free.
- Layer 2 is suppressed when the payload identifies a subagent.

Detection is best-effort: the runtime carries `agent_id` and `agent_type` on
subagent events, but whether `PreToolUse` propagates them is unverified (**P3**,
measured alongside §3). If it does not, the fallback is already sound — the
mandatory override sentence means even a denied worker has a stated path
forward. Detection improves the guarantee; it is not load-bearing.

`Stop` is unchanged: it already exits early on `stop_hook_active`, blocks at
most once, and is opt-in per repository.

*(2026-08-19 update: `Stop` was later removed entirely — see the
[kill-turn-gate plan](superpowers/plans/2026-08-19-kill-turn-gate.md).)*

## 6. State

Per-session, per-rule, under the cache the repository already ignores:

```
.agent/cache/brief/<session-id>/<rule-id>
```

**Rule-id keyed, never command-hashed.** Hashing the command makes
`gh issue view 442`, `…443`, `…444` three distinct lessons — twelve briefings
where one was intended. The lesson is about the *class*.

**Created atomically with `mkdir`**, not `touch`: two tool calls in one turn race
otherwise, and both brief.

**Written before the deny is emitted. If the write fails, allow.** This is the
one inviolable rule in this document. A guard that denies on state it could not
persist denies again on the retry, and again — an unrecoverable loop with no
human in the loop for a worker. A read-only `.agent/` has already bitten this
tree once. *Cannot record → do not deny.*

**Re-armed on compaction.** `SessionStart` fires with `source: "compact"`, which
is precisely when the injected lesson was summarized away. Clearing the session's
brief directory there restores the curriculum for a context that no longer holds
it.

**Pruned by age** (>7 days) on session start. Cosmetic, but the directory is
committed-adjacent and should not accumulate.

## 7. Failure modes

| Failure | Consequence | Mitigation |
|---|---|---|
| State unwritable | **Unrecoverable deny loop** | Write before deny; write fails → allow (§6) |
| Concurrent calls race | Two briefs, one wasted call | Atomic `mkdir` |
| Compaction erases the lesson | Agent naive, guard spent | Re-arm on `source: "compact"` |
| Subagent shares parent's session id | Worker inherits "already briefed" | Layer 0 covers it; override sentence is the floor |
| Agent ignores the brief | Wasteful session | Accepted (§2). Logged, not blocked |
| Rule fires where no helper is better | Pure waste, worse than nothing | Triggers stay narrow (§4) |
| Curriculum names a missing helper | Teaches a broken path | Verify on disk before naming |
| Hooks stop being pure functions | Harder to test and debug | State is one inspectable file per rule; suites create and destroy it explicitly |

## 8. Testing

Extends `tests/test-hooks.sh`; the ten gates are unchanged.

- **Once-per-class:** first call briefs, second identical call proceeds, a
  *different* number in the same class also proceeds.
- **Loop safety:** unwritable `.agent/cache` → allow, never deny. Asserted
  directly, because this is the failure with no human in the loop.
- **Override text present** in every Layer 2 message. A missing sentence is a
  broken guard, so it is asserted, not assumed.
- **Concurrency:** two simultaneous invocations produce exactly one brief.
- **Compaction:** `source: "compact"` clears the flags.
- **Subagent:** a payload marked as a worker is never denied.
- **Curriculum integrity:** every helper named in Layer 0 exists and is
  executable — extracted from the shipped text, not restated in the test.
- **Budget:** a scripted ten-call session yields **≤3** denials.
- **Ignore rules (§4.1):** bootstrap *writes* them; a repository with the rules
  in place stages nothing from `.agent/` under `git add -A` except the two
  declared files — asserted against a real `git add -A` in a scratch repository,
  since the claim is about git's behavior and not about a pattern's text.
  Re-running bootstrap is idempotent and does not duplicate the block.

## 9. Rejected alternatives

**Hard deny with a better message.** What exists today. Cannot fix §1: no
message makes a permanently-forbidden command available when the task needs it.

**Allow everything, teach only in context.** Zero enforcement; loses the
just-in-time correction that makes lessons stick. Layer 0 alone did not stop an
agent from hand-rolling GraphQL.

**Command-hash keyed state.** Twelve briefings instead of one (§6).

**Rewriting the command via `updatedInput`.** Hides the lesson entirely — the
agent never learns why, and re-issues the same shape next session. Rejected in
the predecessor spec for the same reason; unchanged here.

**Wrapping `gh` on `PATH`.** Cannot be relied on: the agent may call it by
absolute path, and it silently changes a tool the human also uses.

## 10. Open questions

- **P1/P2 — ANSWERED (§3).** `PostToolUse` `additionalContext` reaches the model.
  Teach-after-the-fact is the primary mechanism; `systemMessage` was not needed.
- **P3 — deferred, and now nearly moot.** The probe session had no dispatch
  capability at all, so no worker ran and nothing was measured. It matters far
  less than when it was written: with Layer 1 refusing nothing, the only denial
  a worker can meet is the bare-helper rule, and that command was going to fail
  regardless. Re-measure opportunistically in a session that does expose
  workers; do not block implementation on it.

**Resolved 2026-08-08** — the staging guard will not deny. Investigating it
showed the protection was never really the hook's to give: bootstrap only
*printed* ignore advice, and the pattern it printed did not cover the probe
output it needed to. Writing correct ignore rules (§4.1) removes the hazard at
its source and removes a possible halt with it.
