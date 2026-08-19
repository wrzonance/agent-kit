# Kill the Turn-Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use `- [ ]` tracking.

**Goal:** Remove agent-kit's Stop turn-gate (the "declared test has not run — paste this command" block) entirely, keeping every other hook and all skills.

**Architecture:** The Stop hook runs `stop.sh`, a self-contained 160-line pure gate that blocks a turn when a declared verify/test command has not stamped the current changes. Delete the hook registration and the script; delete its dedicated test; update the few tests/fixtures/docs that reference it; rebuild the generated `plugin/` tree; drive the suite green.

**Tech Stack:** bash hooks, jq, the repo's own `tests/run-tests.sh` harness, `tests/build-plugin.sh`.

**Spec:** none (bounded change; owner-approved in chat 2026-08-19). Owner philosophy: agent-kit = speed / token-reduction / scope-constraint, NOT end-of-turn verification nagging.

## Global Constraints

- Branch `feat/kill-turn-gate` off `main`; never commit to main. Conventional commits, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Scope is ONLY the Stop turn-gate. Do NOT touch the `--approve/--yolo` approval fence in `agent-run.sh` (that is Plan B, a separate PR). Do NOT touch pre-tool-use / session-start / subagent-start / post-tool-use hooks or any skill.
- `plugin/` is generated from `agentkit/` by `tests/build-plugin.sh` — never hand-edit `plugin/`; regenerate it.
- The suite `tests/run-tests.sh` must pass at the end (allowing the 2 pre-existing `/home`-scope failures already tracked in issue #284 — no NEW failures).
- The agentkit plugin is currently DISABLED in the user's settings.json; re-enable is a post-merge manual step, not part of this plan.

---

### Task 1: Remove the Stop hook registration and script (source)

**Files:**
- Modify: `agentkit/hooks/hooks.json` (remove the `Stop` key)
- Delete: `agentkit/hooks/stop.sh`

- [ ] **Step 1: Confirm stop.sh is a pure gate (no other callers)**

```bash
cd ~/github/agent-kit
grep -rn 'stop\.sh' agentkit/ --include='*.sh' | grep -v 'hooks/stop.sh:'
```
Expected: no output (nothing sources or calls stop.sh except its own hook registration).

- [ ] **Step 2: Remove the Stop block from hooks.json**

```bash
python3 - <<'PY'
import json
p='agentkit/hooks/hooks.json'
d=json.load(open(p))
top=d.get('hooks',d)
top.pop('Stop',None)
json.dump(d,open(p,'w'),indent=2); open(p,'a').write('\n')
PY
python3 -c "import json;print('Stop' in json.load(open('agentkit/hooks/hooks.json')).get('hooks',{}))"
```
Expected: `False`.

- [ ] **Step 3: Delete the script**

```bash
git rm agentkit/hooks/stop.sh
```

- [ ] **Step 4: Commit**

```bash
git add agentkit/hooks/hooks.json
git commit -m "feat: remove Stop turn-gate hook registration and stop.sh

The turn-gate blocked every turn until a declared verify/test command
stamped the changes, forcing manual command pastes. agent-kit is about
speed and scope-constraint, not end-of-turn verification nagging.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Remove the gate's tests, fixtures, and schema wiring

**Files:**
- Delete: `tests/test-stop-attestation.sh`, `tests/fixtures/schema-stop.json`
- Modify: `tests/test-hooks.sh`, `tests/test-contract-provenance.sh`, `tests/test-plugin-install.sh`, `tests/extract-hook-schemas.sh` (drop Stop expectations), and the runner list if it enumerates suites.

- [ ] **Step 1: Find every test/fixture reference to the gate**

```bash
cd ~/github/agent-kit
grep -rln 'stop\.sh\|stop-attestation\|schema-stop\|"Stop"\|decision.*block' tests/
grep -n 'test-stop-attestation' tests/run-tests.sh tests/*.sh 2>/dev/null
```
Expected: a list including `test-stop-attestation.sh`, `schema-stop.json`, `test-hooks.sh`, `test-contract-provenance.sh`, `test-plugin-install.sh`, `extract-hook-schemas.sh`. Note each; these are the edit sites.

- [ ] **Step 2: Delete the dedicated gate test and fixture**

```bash
git rm tests/test-stop-attestation.sh tests/fixtures/schema-stop.json
grep -rn 'test-stop-attestation\|schema-stop' tests/ && echo "STILL REFERENCED — fix in next step" || echo "clean"
```

- [ ] **Step 3: Drop Stop from the hook-wiring assertions**

In `tests/test-hooks.sh`, remove the assertions that expect a `Stop` entry in hooks.json and that exercise `stop.sh` (the 27 `stop` references — but keep any that are substrings of unrelated words; verify each). In `tests/extract-hook-schemas.sh` remove `Stop` from the event list it extracts. In `tests/test-plugin-install.sh` and `tests/test-contract-provenance.sh` remove the single Stop assertion each. Concretely, for each file:

```bash
cd ~/github/agent-kit
# review each hit and delete only the Stop-specific lines/blocks:
grep -n 'Stop\|stop\.sh\|schema-stop' tests/test-hooks.sh
grep -n 'Stop\|stop\.sh' tests/extract-hook-schemas.sh
grep -n 'Stop\|stop\.sh' tests/test-plugin-install.sh
grep -n 'Stop\|stop\.sh' tests/test-contract-provenance.sh
```
Then edit out exactly those Stop-specific assertions (leave PreToolUse/PostToolUse/SessionStart/SubagentStart wiring intact). Do NOT weaken an assertion to pass — delete the now-obsolete expectation.

- [ ] **Step 4: Verify no dangling references remain**

```bash
grep -rn 'stop\.sh\|stop-attestation\|schema-stop' tests/ agentkit/ && echo "DANGLING" || echo "clean"
```
Expected: `clean`.

- [ ] **Step 5: Commit**

```bash
git add -A tests/
git commit -m "test: remove Stop turn-gate tests, fixture, and hook-wiring assertions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Regenerate the plugin tree and drive the suite green

**Files:**
- Regenerate: `plugin/**` (via `tests/build-plugin.sh`)

- [ ] **Step 1: Rebuild the generated plugin tree**

```bash
cd ~/github/agent-kit && bash tests/build-plugin.sh && echo BUILT
python3 -c "import json;print('Stop' in json.load(open('plugin/agentkit/hooks/hooks.json')).get('hooks',{}))"
ls plugin/agentkit/hooks/stop.sh 2>/dev/null && echo "STOP STILL IN PLUGIN — build didn't clean" || echo "stop.sh absent from plugin"
```
Expected: `BUILT`, `False`, `stop.sh absent from plugin`. If build-plugin.sh copies a directory that still holds a stale stop.sh, ensure the dest hooks dir is cleaned first (the script uses `cp -a agentkit/hooks`; if it doesn't clean dest, `rm -rf plugin/agentkit/hooks` before the build step and rebuild).

- [ ] **Step 2: Run the full suite**

```bash
cd ~/github/agent-kit && bash tests/run-tests.sh 2>&1 | tail -30
```
Expected: PASS except the 2 pre-existing `command-derived target cannot self-authorize` failures (issue #284). NO new failures, and no failure mentioning stop/attestation/Stop.

- [ ] **Step 3: Fix any fallout**

For each NEW failure, read the assertion and remove/repair the Stop expectation it still carries (same rule: delete obsolete expectations, never fake-pass). Re-run Step 2 until only the 2 known #284 failures remain.

- [ ] **Step 4: Commit the regenerated plugin**

```bash
git add -A plugin/
git commit -m "build: regenerate plugin tree without the Stop turn-gate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Update docs and open the PR

**Files:**
- Modify: `README.md`, `docs/onboarding-lessons.md`, `docs/manual-test-plan.md`, and any other doc that documents the turn-gate as current behavior.

- [ ] **Step 1: Find doc references to the gate**

```bash
cd ~/github/agent-kit
grep -rln 'turn.?gate\|has not run\|AGENT_CMD_VERIFY\|Stop hook\|stop\.sh\|attestation' README.md docs/ | grep -v superpowers/plans
```

- [ ] **Step 2: Edit those docs** to describe current behavior: the Stop turn-gate is removed; AGENT_CMD_VERIFY/TEST are still declarable and runnable via `agent-run --cmd`, but nothing blocks a turn on them. Historical design docs (dated `docs/2026-08-07-*`, `docs/2026-08-09-*`) may keep their historical text but get a one-line note that the gate was later removed. Do NOT rewrite history docs wholesale.

- [ ] **Step 3: Commit docs**

```bash
git add -A README.md docs/
git commit -m "docs: turn-gate removed; declared commands run without a blocking Stop gate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Push and open a draft PR**

```bash
cd ~/github/agent-kit && git push -u origin feat/kill-turn-gate
gh pr create --draft --title "feat: remove the Stop turn-gate" --body-file - <<'EOF'
This was written agentically; verify its assertions:

## Why
The Stop turn-gate blocked every turn until a declared verify/test command
stamped the changes — forcing manual command pastes to authorize what the
operator already authorized. agent-kit is about speed, token/tool-churn
reduction, and scope-constraint, not end-of-turn verification nagging.

## What
Removes the `Stop` hook registration and `stop.sh` (a self-contained pure
gate), its dedicated test/fixture, and the Stop-specific assertions in the
hook-wiring tests. Regenerates the plugin tree. Every other hook (pre-tool-use
scope guards, session/subagent/post-tool-use) and all skills are untouched.
The `--approve/--yolo` command-trust fence in agent-run.sh is intentionally
NOT touched here — that is a separate, larger PR (Plan B).

## Testing
- [ ] `tests/run-tests.sh` green except the 2 pre-existing #284 failures
- [ ] plugin/ regenerated, no stop.sh, no Stop in hooks.json
- [ ] Manual: reinstall plugin, confirm no turn-gate nag

🤖 Co-authored by Claude Fable 5 (claude-fable-5).
EOF
```

---

## Follow-up (NOT this plan) — Plan B: de-fang the approval fence

Separate branch/PR: remove the ~500-line command-trust subsystem in
`agentkit/skills/.shared/scripts/agent-run.sh` (`trust_*`, `yolo_*`,
`require_human_approval`, `--approve/--yolo/--yolo-base/--yolo-write-set`) so
declared commands run without an approval record, and rewrite the ~15 approval
tests (`test-agent-run-approval-gate.sh`, `test-autonomy-flags.sh`,
`test-cross-provider-consent.sh`, `tests/lib/tty-approve`, etc.). Larger and
more delicate than the turn-gate; do it fresh, not blind.
