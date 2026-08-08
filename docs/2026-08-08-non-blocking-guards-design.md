# Non-blocking guards: teach deterministically, never stop the work

**Date:** 2026-08-08
**Status:** Draft — awaiting one runtime probe (§3) and approval
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

## 3. The probe that decides the architecture (Task 0)

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

### Layer 1 — advisory (conditional on §3)

`PreToolUse` allows the call and attaches the better command as a
`systemMessage`. Applies to every read-shaped rule: board discovery, per-issue
triage. Cost: zero calls. Cannot stop work, by construction.

Same once-per-rule-per-session budget as Layer 2 — an advisory repeated on every
call is noise, and noise is how the environment contract stops being read.

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
| Board discovery | `gh project list\|item-list\|field-list` | `triage-issues.sh` (read), `move-github-project-item.sh` (move) | 1, else 2 |
| Per-issue triage | `gh api …/timeline`, `gh issue view` | `triage-issues.sh` | 1, else 2 |
| Bare helper path | `<helper>.sh` in command position | the resolver | 2 — the command **cannot succeed**; advising alone would waste the call anyway |
| Blanket staging | `git add -A\|--all\|.` | `worktree-commit.sh` | 2 |

`gh issue view` moves to advisory or deny-once either way, which resolves the
§1 contradiction: reading an issue body becomes possible again.

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

- **P1/P2 (§3)** — does `systemMessage` run the call, and does it reach the model?
- **P3 (§5)** — does `PreToolUse` carry `agent_id` inside a subagent?
- Should the staging guard stay deny-once, given `.agent/cache/` is gitignored
  and `config.env`/`board.json` are *meant* to be committed? Its correctness
  value may be lower than assumed, in which case advisory suffices.
