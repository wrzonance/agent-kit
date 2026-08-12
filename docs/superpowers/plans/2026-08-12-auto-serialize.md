# `--auto-serialize` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a parallel-issues batch contains conflicting or intra-batch-blocked issues, chain them — each successor's worktree branches from the root-published commit of its predecessor — instead of dropping them or gating on PR merges.

**Architecture:** One new `agent-run.sh` option (`--yolo-base <sha>`) extends the trust gate to root-published ancestor commits; everything else is recipe/prose changes in `parallel-issues/SKILL.md` pinned by contract tests. Spec: `docs/superpowers/specs/2026-08-12-auto-serialize-design.md`.

**Tech Stack:** bash (shellcheck-clean; scoped disables carry a reason), repo test harness (`tests/run-tests.sh`, `tests/lib/assert.sh`), fixture repos with real bare origins.

## Global Constraints

- Branch: `feat/auto-serialize` from `origin/main`; never commit to main.
- Every verification through the wrapper: `agent-run.sh --cmd test --only <suite> --yolo` (focused) and `agent-run.sh --cmd test --yolo` (full). Focused suite names are logical (`agent-run-cmd`, `parallel-dispatch-contract`), not filenames.
- Trust anchor rules (spec, verbatim): `--yolo-base` requires `--yolo`; value is a full 40-hex commit SHA; SHA must be a server-advertised origin head or a content-addressed ancestor of one (`git ls-remote --heads origin` — never locally writable `refs/remotes/origin/*` tracking refs; adversarial-review P1) AND an ancestor of the worktree's HEAD; all failures fail closed with a message naming the SHA.
- Ordering sources (spec, verbatim): Step 3 file-conflict pairs + native blocked-by edges pointing inside the selected set. Issue-body prose is never an ordering input.
- Chain depth cap: 4. Chains gate on root-published commits, never PR state.
- Conventional Commits with `Co-Authored-By` trailer naming the actual implementing agent.

---

### Task 1: `--yolo-base` option parsing and usage constraints

**Files:**
- Modify: `agentkit/skills/.shared/scripts/agent-run.sh` (option loop ~line 150s; constraint block after it, near the `--approve`/`--yolo` mutual-exclusion checks ~line 185; usage text ~line 40s)
- Test: `tests/test-agent-run-cmd.sh` (append after the existing sentinel/`__tests__` cases)

**Interfaces:**
- Produces: global `yolo_base_opt=''` (set by `--yolo-base <value>`), validated to `^[0-9a-f]{40}$` and co-required with `--yolo`. Task 2 consumes `yolo_base_opt`.

- [ ] **Step 1: Write the failing tests**

```bash
# --- --yolo-base usage constraints -----------------------------------------
repo=$tmp/yolo-base-usage
make_yolo_repo "$repo"
printf '#!/bin/sh\nexit 0\n' > "$repo/tools/runner"
chmod +x "$repo/tools/runner"
printf 'AGENT_CMD_TEST=tools/runner\n' > "$repo/.agent/config.env"
commit_yolo_base "$repo"
pin_sha=$(git -C "$repo" rev-parse HEAD)

rc=0
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo-base "$pin_sha" 2>&1) || rc=$?
assert_eq 1 "$rc" 'yolo-base without yolo exits 1'
assert_contains "$out" -- '--yolo-base requires --yolo' \
    'yolo-base without yolo names the dependency'

rc=0
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo --yolo-base "${pin_sha:0:12}" 2>&1) || rc=$?
assert_eq 1 "$rc" 'abbreviated yolo-base sha exits 1'
assert_contains "$out" 'full 40-character' 'abbreviated sha refusal explains the format'

rc=0
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo --yolo-base "refs/heads/main" 2>&1) || rc=$?
assert_eq 1 "$rc" 'symbolic yolo-base ref exits 1'
```

- [ ] **Step 2: Run to verify they fail**

Run: `./agentkit/skills/.shared/scripts/agent-run.sh --cmd test --only agent-run-cmd --yolo`
Expected: FAIL — first case dies `Unknown option: --yolo-base`.

- [ ] **Step 3: Implement**

In the globals near `yolo_cmd=0`: add `yolo_base_opt=''`. In the option `case` loop, before the `-*)` arm:

```bash
--yolo-base)
    (($# >= 2)) || die '--yolo-base requires a commit SHA.'
    yolo_base_opt=$2
    shift 2
    ;;
```

In the constraint block (beside the `--approve`/`--yolo` exclusivity check):

```bash
if [[ -n $yolo_base_opt ]]; then
    ((yolo_cmd)) || die '--yolo-base requires --yolo.'
    [[ $yolo_base_opt =~ ^[0-9a-f]{40}$ ]] ||
        die '--yolo-base requires a full 40-character lowercase commit SHA, not a ref or abbreviation.'
fi
```

Usage text, after the `--yolo` entry:

```
  --yolo-base SHA  With --yolo: validate command inputs against this pinned,
                 origin-reachable ancestor commit instead of the remote trunk.
                 For chained worktrees whose base is a root-published commit
                 from an earlier issue in the same run.
```

- [ ] **Step 4: Run to verify pass** — same command, expect the three new cases green.
- [ ] **Step 5: Commit**

```bash
git add agentkit/skills/.shared/scripts/agent-run.sh tests/test-agent-run-cmd.sh
git commit -m 'feat(run): parse --yolo-base with fail-closed usage constraints'
```

---

### Task 2: pinned-base validation — origin-reachable ancestor or refusal

**Files:**
- Modify: `agentkit/skills/.shared/scripts/agent-run.sh` (new function above `yolo_gate()`, ~line 1015)
- Test: `tests/test-agent-run-cmd.sh`

**Interfaces:**
- Consumes: `yolo_base_opt` (Task 1).
- Produces: `yolo_pinned_base SHA` — prints the SHA on success; dies naming the SHA on: unknown commit, not reachable from any `refs/remotes/origin/*`, or not an ancestor of HEAD. Task 3 wires it into `yolo_gate`.

- [ ] **Step 1: Write the failing tests**

```bash
# A local commit never pushed anywhere cannot anchor trust.
repo=$tmp/yolo-base-unpushed
make_yolo_repo "$repo"
printf '#!/bin/sh\nexit 0\n' > "$repo/tools/runner"
chmod +x "$repo/tools/runner"
printf 'AGENT_CMD_TEST=tools/runner\n' > "$repo/.agent/config.env"
commit_yolo_base "$repo"
printf 'local-only\n' > "$repo/local.txt"
git -C "$repo" add local.txt && git -C "$repo" commit -qm local-only
unpushed_sha=$(git -C "$repo" rev-parse HEAD)
rc=0
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo --yolo-base "$unpushed_sha" 2>&1) || rc=$?
assert_eq 1 "$rc" 'unpushed pin exits 1'
assert_contains "$out" 'not reachable from any origin ref' \
    'unpushed pin refusal names reachability'
assert_contains "$out" "$unpushed_sha" 'unpushed pin refusal names the sha'

# An origin-published commit that is NOT an ancestor of HEAD cannot anchor trust.
repo=$tmp/yolo-base-sideline
make_yolo_repo "$repo"
printf '#!/bin/sh\nexit 0\n' > "$repo/tools/runner"
chmod +x "$repo/tools/runner"
printf 'AGENT_CMD_TEST=tools/runner\n' > "$repo/.agent/config.env"
commit_yolo_base "$repo"
git -C "$repo" checkout -q -b sideline
printf 'side\n' > "$repo/side.txt"
git -C "$repo" add side.txt && git -C "$repo" commit -qm side
git -C "$repo" push -q origin HEAD:sideline
side_sha=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q feature
git -C "$repo" fetch -q origin
rc=0
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo --yolo-base "$side_sha" 2>&1) || rc=$?
assert_eq 1 "$rc" 'non-ancestor pin exits 1'
assert_contains "$out" 'not an ancestor' 'non-ancestor pin refusal names ancestry'
```

- [ ] **Step 2: Run to verify they fail** (focused suite; currently `--yolo-base` parses but is unused, so both runs would pass verification against trunk — assertions on the refusal text fail).
- [ ] **Step 3: Implement** — above `yolo_gate()`:

```bash
# A pinned base substitutes for the trunk anchor. Root-published only: the SHA
# must sit behind some origin ref (workers cannot push, so only the root can
# put a commit there) and be an ancestor of this worktree's HEAD. Same
# defense-in-depth level as the rest of the gate, no stronger claim.
yolo_pinned_base() {
    local sha=$1
    git -C "$git_top" cat-file -e "$sha^{commit}" 2> /dev/null ||
        die "--yolo-base: no such commit in this repository: $sha"
    # AMENDED (adversarial-review P1): remote-tracking refs are writable local
    # files. Validate against server-advertised heads instead — the pin must be
    # an advertised head or a content-addressed ancestor of one:
    #   git ls-remote --heads origin  →  accept iff sha == head, or
    #   merge-base --is-ancestor sha head for some advertised head.
    # See the shipped yolo_pinned_base() for the final implementation.
    git -C "$git_top" merge-base --is-ancestor "$sha" HEAD 2> /dev/null ||
        die "--yolo-base: $sha is not an ancestor of this worktree's HEAD."
    printf '%s' "$sha"
}
```

Wire into `yolo_gate()` (its first lines currently `base=$(yolo_base_ref) || die …`):

```bash
if [[ -n $yolo_base_opt ]]; then
    base=$(yolo_pinned_base "$yolo_base_opt")
else
    base=$(yolo_base_ref) \
        || die '--yolo: no remote trunk ref to validate command inputs against; review the declaration and approve it from your own terminal instead.'
fi
```

- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit** — `feat(run): validate --yolo-base as an origin-reachable ancestor`

---

### Task 3: pinned anchor drives the gate; messages name the pin

**Files:**
- Modify: `agentkit/skills/.shared/scripts/agent-run.sh` (skip/refusal message lines inside `yolo_gate()`)
- Test: `tests/test-agent-run-cmd.sh`

**Interfaces:**
- Consumes: `yolo_pinned_base` (Task 2). No new symbols produced.

- [ ] **Step 1: Write the failing test** — the chain happy path: a declared input changed vs trunk but committed at the pin passes, executes, and says so:

```bash
# Chain link: predecessor changed a declared input; the pin authorizes it.
repo=$tmp/yolo-base-chain
make_yolo_repo "$repo"
printf '#!/bin/sh\ntouch "%s/chain-ran"\n' "$tmp" > "$repo/tools/runner"
chmod +x "$repo/tools/runner"
printf 'payload v1\n' > "$repo/payload.txt"
printf 'AGENT_CMD_TEST=tools/runner --require=payload.txt\n' > "$repo/.agent/config.env"
commit_yolo_base "$repo"
printf 'payload v2 from issue A\n' > "$repo/payload.txt"
git -C "$repo" add payload.txt && git -C "$repo" commit -qm 'issue A'
git -C "$repo" push -q origin HEAD:feat-issue-a
git -C "$repo" fetch -q origin
chain_sha=$(git -C "$repo" rev-parse HEAD)

rc=0
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo 2>&1) || rc=$?
assert_eq 1 "$rc" 'plain yolo still refuses the chained input change'

rc=0
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo --yolo-base "$chain_sha" 2>&1) || rc=$?
assert_eq 0 "$rc" 'pinned yolo passes on the chain base'
assert_eq yes "$([[ -e $tmp/chain-ran ]] && echo yes || echo no)" \
    'the pinned run actually executes the command'
assert_contains "$out" 'pinned base' 'skip message names the pinned anchor'
```

- [ ] **Step 2: Run to verify it fails** (pass happens, but "pinned base" phrasing absent).
- [ ] **Step 3: Implement** — in `yolo_gate()`, derive a description once and use it in both the skip line and every refusal line:

```bash
base_desc=$base
[[ -n $yolo_base_opt ]] && base_desc="pinned base $base"
```

Replace `"$base"` with `"$base_desc"` in the `trust gate skipped` printf, the `add_note` line, and each `refusing --yolo` message inside `yolo_gate` (the comparison plumbing keeps using `$base`).

- [ ] **Step 4: Run focused, then full suite** (`--cmd test --yolo`) — all green.
- [ ] **Step 5: Commit** — `feat(run): anchor yolo gate at the pinned base and name it in every verdict`

---

### Task 4: SKILL.md — chain planning in Step 3, depth cap in Limits

**Files:**
- Modify: `agentkit/skills/parallel-issues/SKILL.md` (Step 3 ~line 562; Limits ~line 1624; Flags table ~line 23)
- Test: `tests/test-parallel-dispatch-contract.sh` (near the existing Step 3 / flag-table assertions; `$skill` holds the SKILL text)

**Interfaces:**
- Produces: the flag name `--auto-serialize`, the phrase "chain plan", the two ordering sources, cycle fallback, depth cap 4. Tasks 5–6 reference "chain" vocabulary; keep the spellings below exactly.

- [ ] **Step 1: Write the failing contract assertions**

```bash
assert_contains "$skill" -- '--auto-serialize' 'auto-serialize flag is documented'
assert_contains "$skill" 'file-conflict pairs and native blocked-by edges inside the selected set' \
    'chain ordering sources are exactly the two mechanical ones'
assert_contains "$skill" 'never an ordering input' \
    'issue-body prose is excluded from ordering'
assert_contains "$skill" 'chain depth cap: 4' 'chain depth cap is pinned'
assert_contains "$skill" 'cycle' 'cycles fall back instead of chaining'
```

- [ ] **Step 2: Run `--only parallel-dispatch-contract` — expect the new assertions red.**
- [ ] **Step 3: Write the prose.** Flags table row:

```
| `--auto-serialize` | — | Convert Step 3 conflicts into chains instead of drops: the later issue of an ordered pair builds on the earlier issue's root-published commit. Ordering evidence is file-conflict pairs and native blocked-by edges inside the selected set; issue-body prose is never an ordering input. |
```

Step 3 addition (after the `--fast-mode` paragraph):

```
**With `--auto-serialize`,** ordered pairs become chain edges instead of drops. Build the
dependency graph from file-conflict pairs and native blocked-by edges inside the selected set,
decompose it into linear chains, and print the chain plan next to the conflict table
(attended: get approval; `--fast-mode`: proceed). A cycle cannot be chained — report the cyclic
members and fall back to drop/ask for exactly those. Chain depth cap: 4; deeper tails are
dropped with a named report. Chains gate on root-published commits, never on PR state.
```

Limits bullet: `- Chain depth cap: 4 under --auto-serialize; chains count against the issue limit.`

- [ ] **Step 4: Focused suite green.**
- [ ] **Step 5: Commit** — `feat(skills): document --auto-serialize chain planning`

---

### Task 5: SKILL.md — deferred dispatch, parameterized worktree base, threaded pin

**Files:**
- Modify: `agentkit/skills/parallel-issues/SKILL.md` (Step 5 recipe ~line 619; Dispatch ~line 735; both WHEN-yolo blocks ~lines 951 and 1379)
- Test: `tests/test-parallel-dispatch-contract.sh`

**Interfaces:**
- Consumes: chain vocabulary (Task 4); `--yolo-base` (Tasks 1–3).
- Produces: variable name `chain_base_sha`; threading phrase `--yolo --yolo-base $chain_base_sha`.

- [ ] **Step 1: Write the failing contract assertions**

```bash
assert_contains "$skill" 'chain_base_sha' 'chain base sha variable is named'
assert_contains "$skill" 'git worktree add "$worktree" -b "$branch" "${chain_base_sha:-origin/$base}"' \
    'worktree recipe parameterizes its start point'
assert_contains "$skill" -- '--yolo --yolo-base $chain_base_sha' \
    'chained WHEN-yolo threading pins the base'
assert_contains "$skill" 'only after the root has validated, committed, and pushed' \
    'chain successors defer on root publication, not PR state'
```

- [ ] **Step 2: Run focused — red.**
- [ ] **Step 3: Write the changes.**

Step 5 recipe: replace the `git worktree add "$worktree" -b "$branch" "origin/$base"` line with

```bash
# For a chained issue, chain_base_sha is the root-published commit of its
# predecessor (worktree-commit.sh printed it); empty means an independent
# issue starting from trunk.
chain_base_sha="${chain_base_sha:-}"
git worktree add "$worktree" -b "$branch" "${chain_base_sha:-origin/$base}" || {
```

Dispatch section addition:

```
**Chained issues defer.** A chain successor's worktree is created and its lead dispatched
only after the root has validated, committed, and pushed the predecessor's handback. Record
`chain_base_sha` from the commit line `worktree-commit.sh` printed. A deferred issue holds no
concurrency slot. If the predecessor's lead fails or is BLOCKED, its successors are never
dispatched — park the chain and name it in the report.
```

Both WHEN-yolo blocks: extend the threading sentence with

```
For a chained issue, append `--yolo --yolo-base $chain_base_sha` instead — the pin is the
root-published predecessor commit this branch was created from.
```

- [ ] **Step 4: Focused suite green.**
- [ ] **Step 5: Commit** — `feat(skills): chain scheduling with pinned-base threading`

---

### Task 6: SKILL.md — stacked publication and merge-order handoff

**Files:**
- Modify: `agentkit/skills/parallel-issues/SKILL.md` (publication recipe ~line 1197; Step 3c ~line 1504)
- Test: `tests/test-parallel-dispatch-contract.sh` (`$publication_section` covers the publication recipe)

**Interfaces:**
- Consumes: chain vocabulary; predecessor branch name `feat/issue-<A>`.
- Produces: PR body line `Stacked on #`; handoff phrase `merge order`.

- [ ] **Step 1: Write the failing contract assertions**

```bash
assert_contains "$publication_section" 'Stacked on #' \
    'stacked PRs declare their base PR in the body'
assert_contains "$publication_section" 'retargets this one to' \
    'stacked body explains the auto-retarget unwind'
assert_contains "$skill" 'merge order' 'ready-flip handoff states the chain merge order'
```

- [ ] **Step 2: Run focused — red.**
- [ ] **Step 3: Write the changes.** Publication recipe, after the `pr_close_line` guard:

```
For a chained issue, pass the predecessor branch as the PR base
(`--base feat/issue-<A>` instead of `--base "$base"`) and append this line to the body,
substituting the predecessor's PR number as a fixed literal:

    Stacked on #__BASE_PR__ — merge that PR first; GitHub retargets this one to the default
    branch automatically when its base branch is deleted on merge.
```

Step 3c addition:

```
When the batch contains chains, the ready-flip handoff lists each chain's merge order
explicitly (base PR first). A stacked PR merged out of order merges into its base branch,
not the trunk — say so in the handoff.
```

- [ ] **Step 4: Focused suite green, then the full suite** (`agent-run.sh --cmd test --yolo`) — ALL GREEN.
- [ ] **Step 5: Commit** — `feat(skills): stacked draft PRs with explicit merge order`

---

### Task 7: docs + final verification

**Files:**
- Add: `docs/superpowers/specs/2026-08-12-auto-serialize-design.md`, `docs/superpowers/plans/2026-08-12-auto-serialize.md` (already written, uncommitted)

- [ ] **Step 1:** Full suite via the wrapper; capture the log path and `=== agent-run exited rc=0` marker.
- [ ] **Step 2:** Commit the two docs — `docs: auto-serialize design and implementation plan`.
- [ ] **Step 3:** Push `feat/auto-serialize`, open the draft PR (body-file recipe, `Closes` the issue this plan gets filed under), CI, single adversarial review at the end of the draft phase — the standard finish.

## Self-review notes

- Spec coverage: semantics→Task 4; scheduling→Task 5; trust→Tasks 1–3; publication→Task 6; failure modes→Tasks 4 (cycle, cap) and 5 (parked chains); re-pin-after-review-fixes is root procedure recorded in the dispatch prose of Task 5's deferral paragraph — no code surface.
- The `${chain_base_sha:-origin/$base}` form keeps the recipe byte-stable for the independent-issue path, so existing contract pins that quote the old literal must be updated in the same edit (Task 5 Step 3 — check for pins of the previous `git worktree add` line and update them red-first).
- Type/name consistency: `yolo_base_opt`, `yolo_pinned_base`, `chain_base_sha`, `--yolo-base` — spelled identically across all tasks.
