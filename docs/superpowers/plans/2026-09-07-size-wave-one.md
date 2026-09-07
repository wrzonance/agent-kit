# Skill-tree size reduction, wave one — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut roughly 20,000 estimated tokens from the shipped skill markdown — the mandatory-read set the root re-reads on every fresh context and after every compaction — without adding a file, a rule, a gate, or a round trip, and ratchet the size ceilings down to the measured minimum in the same PRs.

**Architecture:** Nine independent, mechanical prose cuts, one file family per PR, each preserving every literal a test pins and every behaviour a helper already enforces. Tasks 2–7 touch disjoint files and can run in parallel worktrees; Task 8 (tree-wide marker removal) touches files from every earlier task and runs only after Tasks 2–7 have merged. Task 1 first collapses the size-gate ratchet so every later ceiling change is a one-line edit.

**Tech Stack:** Bash test suite (`tests/run-tests.sh`), `tests/lint-skill-size.sh` (body-token gate, `bytes/4` estimator in `tests/lib/token-estimate.sh`), `gh` over REST, git worktrees under `.worktrees/`.

**Spec:** `docs/superpowers/specs/2026-09-07-size-audit.md` (the read-only audit this plan implements; committed by Task 1). Raw data that the spec cites — `proposals-with-pins.csv`, `test-pins.csv` — lives beside it in `docs/superpowers/specs/2026-09-07-size-audit/`.

## Global Constraints

- **Repository:** `wrzonance/agent-kit`, trunk `main` at `ed63627` when this plan was written. Skills live under `agentkit/skills/`; tests under `tests/`. Line numbers below are from that commit — **re-anchor with the quoted grep before every edit**; lines drift after earlier tasks in the same file.
- **Never edit the root checkout** (`/home/adam/github/agent-kit`); every task works in `.worktrees/<branch>` created from `origin/main` (or from its predecessor branch where the task says so).
- **Never commit to `main`.** Branches are `refactor/size-w1-<slug>`.
- **One PR per task, always `gh pr create --draft`.** PR body = Why + What + Testing checkboxes, opens with `This was written agentically; verify its assertions:` and closes with `🤖 Co-authored by Claude Fable 5.1. Closes #N.`
- **Commits:** Conventional Commits, `refactor(<scope>): …`, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- **No new files under `agentkit/`** (`tests/test-helper-end-of-options.sh` pins exactly 66 executables; `tests/lint-reference-manifest.sh` requires one manifest entry per reference). Docs under `docs/` are the only additions (Task 1).
- **Every pinned literal listed in a task stays verbatim and on a single line** unless the task says the pinning test flattens whitespace. When a test fails on a literal the task did not list, restore that sentence verbatim rather than deleting the assertion.
- **Ceilings ratchet down, never up.** `tests/lint-skill-size.sh` `KNOWN_OVERSIZE[<skill>]="LINES:TOKENS:TARGET"` is set to the exact measured body size in the same PR, and `tests/test-skill-size.sh` pins those numbers in its ratchet-message assertions (lines 185, 195, 224, 226) — change both together.
- **Verification before push:** `tests/run-tests.sh` (canonical local verification) exits 0. `--only NAME` accepts only `tests/test-*.sh` suite names (the file name without `test-`/`.sh`); the `lint-*.sh` gates are not suites — run them directly as `tests/lint-<name>.sh agentkit/skills` (`lint-versioned-plugin-paths.sh agentkit`). Use `--only` plus the relevant lints for the fast loop; the full run is the pre-push gate.
- **GitHub API:** REST via `gh api` for issues/PRs; the board helper for status moves.
- **North star:** nothing in this plan may add a turn, a read, or a confirmation to any run. A cut that would remove the *only* home of an executed recipe or a pinned rule is out of scope for this wave.

---

## Shared step: commit, push, and open the draft PR

Every task's final step runs this exact recipe from inside its worktree with its own values. `ISSUE` comes from the Task 0 ledger (`grep '^T<n> ' /tmp/claude-1000/-home-adam-github-agent-kit/c8271f1d-01eb-41e9-bc21-3daab578d54b/scratchpad/plan/issues/ledger.txt | cut -d' ' -f2`).

```bash
# Set these six before running (`$agentkit` = the installed skills tree, e.g. /home/adam/.claude/plugins/cache/agent-kit/agentkit/0.7.4/skills); every other line is fixed.
SCOPE=spawn-contract                       # commit/PR scope
TITLE='one-line in-block comments and a 15-line prose summary'
WHY='Both dispatching skills read this file in full on every fresh context; 98 comment lines and an 80-line restatement of a block whose own stderr says each of those things.'
WHAT='In-block comment essays become one line each (executed code byte-identical); the prose after the block keeps every pinned sentence in ~15 lines. 29,384 -> <measured> bytes.'
ISSUE=<number from the ledger>

# Stage ONLY the files the task names (never a blanket add: .agent/ carries local state).
git status --short                                   # confirm every listed path is a task file
FILES=(agentkit/skills/.shared/spawn-contract.md tests/test-skills-contract.sh)   # this task's files
"$agentkit/.shared/scripts/worktree-commit.sh" --exact --message "refactor($SCOPE): $TITLE" --body "$WHY" \
    --trailer 'Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>' -- "${FILES[@]}"
git push -u origin "$(git branch --show-current)"
body=$(mktemp); printf '%s\n' 'This was written agentically; verify its assertions:' '' '## Why' "$WHY" '' '## What' "$WHAT" '' '## Testing' '- [ ] Byte ceiling assertion added in this PR fails before the cut and passes after' '- [ ] Every pinned literal named in the plan task survives (`tests/run-tests.sh` green)' '- [ ] Executed fences unchanged where the task requires (md5 in the task)' '- [ ] CI green' '' "🤖 Co-authored by Claude Fable 5.1. Closes #$ISSUE." > "$body"
gh pr create --draft --title "refactor($SCOPE): $TITLE" --body-file "$body"
```

Then the orchestrator (not the worker) moves the issue to In review: `"$agentkit/parallel-issues/scripts/move-github-project-item.sh" --issue-number "$ISSUE" --status "In review" --repo wrzonance/agent-kit`.

---

### Task 0: Tracking issues and board state

**Files:**
- Create (scratch, not committed): `/tmp/claude-1000/-home-adam-github-agent-kit/c8271f1d-01eb-41e9-bc21-3daab578d54b/scratchpad/plan/issues/ledger.txt`

**Interfaces:**
- Produces: issue numbers `ISSUE_T1 … ISSUE_T8` used by every later task's branch PR body (`Closes #N`).

- [ ] **Step 1: Create one issue per task over REST, ledgered so a re-run never duplicates**

```bash
S=/tmp/claude-1000/-home-adam-github-agent-kit/c8271f1d-01eb-41e9-bc21-3daab578d54b/scratchpad/plan/issues; mkdir -p "$S"; L="$S/ledger.txt"; touch "$L"
mk() { id=$1; title=$2; body=$3; grep -q "^$id " "$L" && { echo "skip $id"; return; }
  printf '%s\n' "$body" > "$S/$id.md"
  n=$(gh api repos/wrzonance/agent-kit/issues -f "title=$title" -F "body=@$S/$id.md" -f 'labels[]=enhancement' -f 'labels[]=area/skills' -f 'labels[]=p2' --jq .number) && echo "$id $n" >> "$L"; sleep 2; }
F='🤖 Co-authored by Claude Fable 5.1.'
H='This was written agentically; verify its assertions:

## North star

Every token in a mandatory-read skill file is paid on every fresh root context and again after every compaction (5 in the 2026-09-05 HonkHonk run). This is wave one of the 2026-09-07 size audit: cut prose that a helper already prints or enforces, or that another mandatory read already carries, and ratchet the size ceiling down to the measured minimum in the same PR. No new file, rule, gate, or round trip.'
mk T1 'refactor(tests): collapse the KNOWN_OVERSIZE ratchet to one declaration and commit the size-audit plan' "$H

## What
\`tests/lint-skill-size.sh\` declares KNOWN_OVERSIZE once and re-assigns it nine times (lines 75–241, each with a history paragraph). Keep one declaration per skill at today's effective values (parallel-issues 1105:19905:900, review-remote-pr 513:8337:450) with a one-line comment each; commit the audit spec and the wave-one plan under docs/superpowers/.

$F"
mk T2 'refactor(spawn-contract): one-line in-block comments and a 15-line prose summary' "$H

## What
\`.shared/spawn-contract.md\`: the 98 in-block comment lines become one line each (the executed code is byte-identical), and the 80-line prose restatement after the block (sanctioned set, roster, pivot, OpenCode tier) becomes ~15 lines keeping every sentence tests pin. Target ≈ −2,400 tokens on a file both dispatching skills read in full.

$F"
mk T3 'refactor(auto-merge): stop narrating merge-gate, authorize-queue, and merge-pr internals' "$H

## What
\`pr-to-green/references/auto-merge.md\`: the mechanical-advance buckets (84 lines), merge-gate flag paragraphs (80), code-scanning proof essay (40), and dependents/delete section (50) each restate what the helper prints (\`blocked reason=\`, \`exemptions=disabled reason=\`, exit 3 naming dependents). Reduce each to the flag or bucket plus one line. Target ≈ −2,900 tokens.

$F"
mk T4 'refactor(provider-rules): dedupe the pitfalls table and the two digest legends' "$H

## What
\`review-remote-pr/references/provider-rules.md\`: keep the ~10 pitfall rows carrying a unique fact, drop the ~20 that restate rules from the same file; compress the Provider-identity section (restates the classifier; legends digest lines gh-pr-state.sh prints with next: hints) and the CodeRabbit-state legend to one line per state. Target ≈ −2,000 tokens on a mandatory Step 1a read.

$F"
mk T5 'refactor(chains): replace exemption internals and fixed-bug history with the proof-line legend' "$H

## What
\`parallel-issues/references/chains.md\`: retarget-proof exemption internals (52 lines) become an 8-line legend of the tokens the proof line prints; the publishing-a-chain-base section stops repeating the join push rule; the human-merge/delete section points at auto-merge.md; the contract-inheritance section keeps the 3-step recovery and drops the 'before this was fixed' narrative. Target ≈ −1,900 tokens.

$F"
mk T6 'refactor(worker-prompts): trim template blocks the composer skips or the helper enforces' "$H

## What
\`parallel-issues/references/worker-prompts.md\`, issue-lead and fix-batch templates: the <WHEN … trust record.> author blurbs (never reach a worker) shrink to the two marker lines the composer matches; the trailer essay ×2 becomes 4 lines (worktree-commit.sh refuses an empty trailer); file-image freshness ×2 and the duplicated scope/instructions paragraphs in the fix-batch template tighten. Saves in the file and in every composed worker prompt.

$F"
mk T7 'refactor(parallel-issues): cut helper-output narration and network re-derivations; make the read set section-conditional' "$H

## What
\`parallel-issues/SKILL.md\`: delete the Process dot graph, the sample triage listing, the six board-move no-op shapes, the fence-prep restatement, duplicated Final-draft-sweep sentences, and the Common-Mistakes pointer list (pointers kept in Limits); replace \`gh repo view\`/\`git remote show origin\` with contract-read.sh --get repo.slug|base.branch (and the same in worker-gate.md); read triage-and-selection.md and worker-prompts.md by section and drop six-step-loop.md from the root read set (the composer pastes it). Ratchet KNOWN_OVERSIZE[parallel-issues] to the measured minimum.

$F"
mk T8 'refactor(skills): drop the redundant rehydration marker comment; the guard line already names the remedy' "$H

## What
30 copies of \`# >>> prepend THE CACHE REHYDRATION (defined once in Step 0) <<<\` (onboard-repo, parallel-issues, review-remote-pr SKILL.md) sit above a guard line whose own error message says exactly that. Delete the marker lines (the guard, which lint-skill-invocations.sh and test-contract-provenance.sh execute against, stays), repoint the two awk checks that keyed on the marker, and ratchet both oversize ceilings. ≈ −500 tokens in every re-read. Runs after the other wave-one PRs merge.

$F"
cat "$L"
```

- [ ] **Step 2: Confirm each issue landed on project 10 in Backlog** (GitHub auto-add did this for #606–#613):

```bash
agentkit=/home/adam/.claude/plugins/cache/agent-kit/agentkit/0.7.4/skills
for n in $(cut -d' ' -f2 "$L"); do "$agentkit/.shared/scripts/board-list.sh" --issue "$n" | tail -1; done
```

Expected: eight `#N  Backlog  refactor(...)` lines. If a row is missing: `gh project item-add 10 --owner wrzonance --url https://github.com/wrzonance/agent-kit/issues/N` (GraphQL; one call each).

- [ ] **Step 3: Move each issue to In progress when its task is dispatched, In review when its PR opens** — via `"$agentkit/parallel-issues/scripts/move-github-project-item.sh" --issue-number N --status "In progress" --repo wrzonance/agent-kit`. The orchestrator does this, never the worker.

---

### Task 1: Collapse the size-gate ratchet; commit the spec and plan

**Files:**
- Modify: `tests/lint-skill-size.sh:27-241`, `tests/test-skill-size.sh:242` (its malformed-entry fixture rewrites the re-assignment form and must match the declare form)
- Create: `docs/superpowers/specs/2026-09-07-size-audit.md` (copy of the audit `REPORT.md`), `docs/superpowers/specs/2026-09-07-size-audit/proposals-with-pins.csv`, `docs/superpowers/specs/2026-09-07-size-audit/test-pins.csv`, `docs/superpowers/plans/2026-09-07-size-wave-one.md` (this file)
- Test: `tests/test-skill-size.sh` (the pinned numbers do not move; only the fixture's sed at line 242 changes)

**Interfaces:**
- Produces: exactly one `KNOWN_OVERSIZE[parallel-issues]=` and one `KNOWN_OVERSIZE[review-remote-pr]=` line, which Tasks 7 and 8 edit in place.

- [ ] **Step 1: Worktree and branch**

```bash
git fetch origin main
git worktree add .worktrees/refactor/size-w1-ratchet -b refactor/size-w1-ratchet origin/main
cd .worktrees/refactor/size-w1-ratchet && git branch --show-current
```

Expected: `refactor/size-w1-ratchet`.

- [ ] **Step 2: Record the baseline (this is the failing-test surrogate: the gate must print the same result before and after)**

```bash
tests/lint-skill-size.sh agentkit/skills | tail -3
grep -c 'KNOWN_OVERSIZE\[' tests/lint-skill-size.sh
```

Expected: `4 skills checked, 0 violations` and `11` (nine re-assignments plus the two lookups at lines 300–301; the `declare -A KNOWN_OVERSIZE=(` line does not match the pattern).

- [ ] **Step 3: Replace lines 27–241 with a single declaration**

Delete from the line `declare -A KNOWN_OVERSIZE=(` (line 27) through the line `KNOWN_OVERSIZE[parallel-issues]="1105:19905:900"` (line 241) inclusive, and insert:

```bash
# Exact measured body sizes; ratchet history lives in `git blame`, not here.
declare -A KNOWN_OVERSIZE=(
    # LINES:TOKENS:TARGET
    [review-remote-pr]="513:8337:450"
    [parallel-issues]="1105:19905:900"
)
```

- [ ] **Step 4: Repoint the malformed-entry fixture and verify the gate result is unchanged**

In `tests/test-skill-size.sh` line 242 the fixture rewrites the allowlist with `sed -E "s|KNOWN_OVERSIZE\[review-remote-pr\]=\"[^\"]*\"|…|"`, which only matches the re-assignment form; change it to:

```bash
sed -E "s|\[review-remote-pr\]=\"[^\"]*\"|[review-remote-pr]=\"$escaped\"|" "$lint" > "$copy"
```

Then:

```bash
tests/lint-skill-size.sh agentkit/skills | tail -1
grep -c 'KNOWN_OVERSIZE\[' tests/lint-skill-size.sh
tests/run-tests.sh --only skill-size
```

Expected: `4 skills checked, 0 violations`; `2` (the two lookup lines; entries inside the declare do not match); `skill-size` suite 43/0 (the pinned numbers 513/8337/1105/19905 are unchanged).

- [ ] **Step 5: Add the spec and plan documents**

```bash
A=/tmp/claude-1000/-home-adam-github-agent-kit/c8271f1d-01eb-41e9-bc21-3daab578d54b/scratchpad
mkdir -p docs/superpowers/specs/2026-09-07-size-audit docs/superpowers/plans
cp "$A/size-audit/REPORT.md" docs/superpowers/specs/2026-09-07-size-audit.md
cp "$A/size-audit/proposals-with-pins.csv" "$A/size-audit/test-pins.csv" docs/superpowers/specs/2026-09-07-size-audit/
cp "$A/plan/2026-09-07-size-wave-one.md" docs/superpowers/plans/2026-09-07-size-wave-one.md
sed -i '1,4s#^Repo: .*#Repo: `wrzonance/agent-kit` @ `ed63627` (prep for 0.7.5). Raw data: `2026-09-07-size-audit/`.#' docs/superpowers/specs/2026-09-07-size-audit.md
tests/run-tests.sh
```

Expected: full suite exits 0 (docs are outside every gate's scan root; confirm no lint names `docs/`).

- [ ] **Step 6: Commit and open the draft PR**

```bash
agentkit=/home/adam/.claude/plugins/cache/agent-kit/agentkit/0.7.4/skills
"$agentkit/.shared/scripts/worktree-commit.sh" --exact --message 'refactor(tests): collapse the KNOWN_OVERSIZE ratchet to one declaration' \
    --body 'Nine re-assignments with history paragraphs made every ceiling change a tenth append. One declaration per skill at today'"'"'s effective values; the history stays in blame. Commits the 2026-09-07 size-audit spec and the wave-one plan it drives.' \
    --trailer 'Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>' -- tests/lint-skill-size.sh tests/test-skill-size.sh docs/superpowers/specs/2026-09-07-size-audit.md docs/superpowers/specs/2026-09-07-size-audit/proposals-with-pins.csv docs/superpowers/specs/2026-09-07-size-audit/test-pins.csv docs/superpowers/plans/2026-09-07-size-wave-one.md
git push -u origin refactor/size-w1-ratchet
gh pr create --draft --title 'refactor(tests): collapse the KNOWN_OVERSIZE ratchet to one declaration' --body-file <(printf '%s\n' 'This was written agentically; verify its assertions:' '' '## Why' 'Every wave-one PR ratchets a ceiling; nine stacked re-assignments made that a tenth append with a history paragraph. Commits the audit spec and plan so the wave is reviewable from the repo.' '' '## What' 'One `KNOWN_OVERSIZE` declaration per skill at the current effective values (unchanged numbers). Adds `docs/superpowers/specs/2026-09-07-size-audit.md` (+ CSV data) and `docs/superpowers/plans/2026-09-07-size-wave-one.md`.' '' '## Testing' '- [ ] `tests/lint-skill-size.sh` prints `4 skills checked, 0 violations` before and after' '- [ ] `tests/run-tests.sh` green' '- [ ] CI green' '' "🤖 Co-authored by Claude Fable 5.1. Closes #$(grep '^T1 ' /tmp/claude-1000/-home-adam-github-agent-kit/c8271f1d-01eb-41e9-bc21-3daab578d54b/scratchpad/plan/issues/ledger.txt | cut -d' ' -f2).")
```

---

### Task 2: `.shared/spawn-contract.md` — SC-01 (comment essays) and SC-02 (prose restatement)

**Files:**
- Modify: `agentkit/skills/.shared/spawn-contract.md:34-46, 56-60, 90-93, 102-106, 111-119, 125-139, 149-151, 156-160, 169-178, 181-190, 211-221, 224-231, 255-334`
- Test: `tests/test-skills-contract.sh:118-182`, `tests/test-parallel-dispatch-contract.sh:1586-1606` (pins), `tests/test-spawn-contract-roster.sh` (executes the bash fence)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: an executed fence (lines 24–253) whose non-comment lines are byte-identical to today's; headings `### Harness-neutral roster (`AGENT_WORKER_MODELS`/`_FALLBACK`)` and `### Harness-aware pivot` retained.

**Pinned literals (each on one line; raw-text assertions unless marked flat):** `AGENT_WORKER_MODELS`, `AGENT_WORKER_MODELS_FALLBACK`, `gpt-5.6-luna`, `gpt-5.6-terra`, `using built-in default`, `--get "$key") && [[ -n $value ]]; then`, `explicit user authorization`, `reasoning_effort: "$worker_effort"`, `model: "$selected_worker_model"`, `set `selected_worker_model` to `worker_model``, `"$agentkit/.shared/scripts/repo-config.sh"`, `sanctioned no-extra-authorization model set is exactly`, `Validate both resolved `worker_model` and `worker_model_fallback``, `Any other syntactically safe configured preferred or fallback model`, `### Harness-aware pivot`, `--get harness.name`, `claude-sonnet-5`, `pivoted from cross-harness declaration` (flat), `Never pivot a same-family value that merely fails the` (flat), `explicit user authorization required` (flat), `so a substitution is always evidence, never inferred` (flat), `sanctioned no-extra-authorization model set is exactly **`gpt-5.6-luna`** and **`gpt-5.6-terra`**` (flat), plus every `## Bounded inline corrections` literal after line 336 (untouched). The first `[ -d "${agentkit:-}/.shared/scripts"` line (29) must stay above `worker_config_value() {`.

- [ ] **Step 1: Worktree, branch, baseline**

```bash
cd /home/adam/github/agent-kit && git fetch origin main
git worktree add .worktrees/refactor/size-w1-spawn-contract -b refactor/size-w1-spawn-contract origin/main
cd .worktrees/refactor/size-w1-spawn-contract
wc -c agentkit/skills/.shared/spawn-contract.md
awk '/^```bash$/{f=1;next} /^```$/{f=0} f && !/^[[:space:]]*#/' agentkit/skills/.shared/spawn-contract.md | md5sum
for p in 'using built-in default' 'Never pivot a same-family value that merely fails the' 'so a substitution is always evidence, never inferred'; do grep -n -F "$p" agentkit/skills/.shared/spawn-contract.md | cut -c1-80; done
```

Expected: 29,384 bytes; an md5 you record (the non-comment fence bytes must be identical after Step 3); three grep hits (note which are in code vs prose — prose hits must survive Step 4).

- [ ] **Step 2 (red): write the size assertion for this file, run it, watch it fail**

Add to `tests/test-skills-contract.sh` immediately after line 129 (`'spawn contract treats empty resolver output as absent'`):

```bash
# 2026-09-07 size wave one: the dispatcher-side contract is a mandatory read
# for both dispatching skills; hold its byte size at the ratcheted ceiling.
spawn_contract_bytes=$(wc -c < "$spawn_contract")
assert_eq yes "$([[ $spawn_contract_bytes -le 20000 ]] && printf yes || printf no)" \
    "spawn contract stays at or under 20000 bytes (measured $spawn_contract_bytes)"
```

Run: `tests/run-tests.sh --only skills-contract`
Expected: FAIL on `spawn contract stays at or under 20000 bytes`.

- [ ] **Step 3 (SC-01): replace each in-block comment essay with one line** — anchor by the first words quoted; delete the whole run of consecutive `#` lines and insert the replacement:

| Anchor (first line of the run) | Replacement (single `#` line) |
|---|---|
| `# AGENT_WORKER_MODELS / AGENT_WORKER_MODELS_FALLBACK (roster form): a` | `# Roster keys: one candidate per harness family, picked by the contract's harness= name; a declared entry is sanctioned by declaration and wins over the singular keys.` |
| `        # OpenCode has no fixed model-id prefix to \`case\`-match, the same` | `        # OpenCode ids are provider/model-id: "exactly one slash" needs =~, not a case glob.` |
| `# The declarations above are Codex-shaped by convention (gpt-5.6-*): a` | `# Unsuffixed keys are Codex-shaped by convention; re-resolve them for the running harness.` |
| `    # OpenCode has no fixed vendor tier -- there is no single OpenCode model` | `    # OpenCode has no fixed worker tier: a repository that declares nothing stops for configuration.` |
| `# Takes an EXPLICIT harness, not just $running_harness: it is also used to ask` | `# Takes an explicit harness so a foreign value is checked against ITS OWN sanctioned worker tier (claude-sonnet-5; never claude-opus-5, the reviewer tier).` |
| `            # OpenCode's sanctioned worker tier is repository-declared, not a` | `            # OpenCode: any well-formed provider/model-id (exactly one '/') is sanctioned by declaration; =~ because a case glob cannot express "exactly one slash".` |
| `        # Checked after the two prefix cases above so neither can be` | `        # gpt-5.6-*/claude-* never contain '/', so ordering here is cosmetic.` |
| `# The provider namespace OpenCode addresses a foreign harness's own sanctioned` | `# Provider namespace OpenCode addresses a foreign harness's sanctioned model under when pivoting into OpenCode.` |
| `# Resolves ONE declaration slot (AGENT_WORKER_MODEL or AGENT_WORKER_MODEL_FALLBACK)` | `# Resolves one declaration slot for the running harness; sets $resolved_value/$pivot_note as globals and exits 1 on an unsanctioned model -- call as a plain statement, never inside $(...) (a subshell exit would not stop the script).` |
| `    # Roster form takes precedence over the singular key when both are` | `    # A declared roster is authoritative: no entry for the running harness is a configuration error, never a silent fallback to the singular key or built-in default.` |
| `        # The declaration states intent for a DIFFERENT harness's own` | `        # A foreign-family value that is that harness's own sanctioned worker tier pivots to this harness's native tier; any other unsanctioned value falls through to the stop below.` |
| `            # OpenCode has no fixed native default to pivot INTO (see the` | `            # OpenCode pivots INTO its provider-qualified address for the declared model (openai/gpt-5.6-luna), never a guessed id.` |

Keep the four `# shellcheck disable=SC2034` lines (244, 246, 249, 251) exactly. Anchor each row by prefix — the quoted anchors are the start of the line, not the whole line.

- [ ] **Step 4 (SC-02): replace lines 255–333 (from `On Codex, the sanctioned no-extra-authorization` through the line ending `as `gpt-5.6-luna` does today.`; line 334 is the blank separator before `Inspect the current …` and stays) with:**

```markdown
On Codex, the sanctioned no-extra-authorization model set is exactly **`gpt-5.6-luna`** and
**`gpt-5.6-terra`**; on Claude it is exactly **`claude-sonnet-5`**; OpenCode sanctions any declared
`provider/model-id` and has no built-in default (a repository that declares nothing there stops for
configuration). Validate both resolved `worker_model` and `worker_model_fallback` against that set
before dispatch. Any other syntactically safe configured preferred or fallback model must stop for
explicit user authorization; never silently substitute a sanctioned model. An empty or malformed
declaration is reported and falls back to its built-in value (`using built-in default`). The
configured effort is the per-run default; a dispatch-plan entry's `workerEffort` override (with its
`effortReason`) replaces it for that issue only.

### Harness-neutral roster (`AGENT_WORKER_MODELS`/`_FALLBACK`)

One comma-separated candidate per harness family (e.g. `claude-sonnet-5,gpt-5.6-luna`);
`resolve_worker_slot` picks the entry whose family matches the contract's `harness= name=`
(`--get harness.name`), never the value's shape. A declared roster entry is sanctioned by
declaration, wins over the singular keys, and is authoritative once valid: no entry for the running
harness is a configuration error naming the roster and the running harness, never a silent fallback.

### Harness-aware pivot

A bare `AGENT_WORKER_MODEL` value shaped for a *different* harness pivots to the running harness's
native worker tier (`gpt-5.6-luna` on Codex, `claude-sonnet-5` on Claude, `<home-provider>/<model>`
on OpenCode, e.g. `openai/gpt-5.6-luna`) only when it is itself that other harness's sanctioned
worker tier — `claude-opus-5` read on Codex still stops. Never pivot a same-family value that merely fails the
sanctioned check, or a value in no known family; both stop for explicit user authorization
required by the gate above. The completion table records every pivot verbatim, e.g.
`worker=claude-sonnet-5 high (pivoted from cross-harness declaration 'gpt-5.6-luna')`, so a
substitution is always evidence, never inferred from prompt text alone.
```

- [ ] **Step 5 (green): verify bytes, executed code unchanged, pins, suite**

```bash
awk '/^```bash$/{f=1;next} /^```$/{f=0} f && !/^[[:space:]]*#/' agentkit/skills/.shared/spawn-contract.md | md5sum   # identical to Step 1
wc -c agentkit/skills/.shared/spawn-contract.md                                                                       # <= 20000
tests/run-tests.sh --only skills-contract,parallel-dispatch-contract,spawn-contract-roster
tests/lint-markdown-blocks.sh agentkit/skills && tests/lint-skill-invocations.sh agentkit/skills && tests/lint-helper-refs.sh agentkit/skills
tests/run-tests.sh
```

Expected: same md5; ≤ 20,000 bytes (from 29,384); all green. If a pinned-literal assertion fails, restore that sentence verbatim on one line and re-run.

- [ ] **Step 6: Shared step** with `SCOPE=spawn-contract`, `TITLE='one-line in-block comments and a 15-line prose summary'`, `WHY='Both dispatching skills read this file in full on every fresh context; 98 comment lines and an 80-line restatement of a block whose own stderr says each of those things.'`, `WHAT='In-block comment essays become one line each (executed code byte-identical, md5 in the PR); the prose after the block keeps every pinned sentence in ~15 lines. 29,384 -> <measured> bytes.'`, `ISSUE=<T2>`.

---

### Task 3: `pr-to-green/references/auto-merge.md` — AM-01…AM-04

**Files:**
- Modify: `agentkit/skills/pr-to-green/references/auto-merge.md:100-183, 184-265, 331-371, 450-500`
- Test: `tests/lint-helper-refs.sh` (path tokens `scripts/authorize-queue.sh`, `scripts/merge-gate.sh`, `parallel-issues/references/chains.md` must resolve), `tests/test-pr-to-green-*.sh`

**Pinned tokens:** `scripts/authorize-queue.sh`, `scripts/merge-gate.sh`, `parallel-issues/references/chains.md`, `../../parallel-issues/scripts/chain-advance.sh`. Leave lines 372–373 (`**Never dispatch a workflow …`) and the `## Board move` heading untouched.

- [ ] **Step 1: Worktree/branch `refactor/size-w1-auto-merge` from `origin/main`; record `wc -c` (33,852).**

- [ ] **Step 2 (red):** add to `tests/test-pr-to-green-authorize-queue.sh` immediately before its final `finish` line a byte ceiling: `assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/pr-to-green/references/auto-merge.md") -le 21500 ]] && printf yes || printf no)" 'auto-merge reference stays at or under 21500 bytes'` — run `tests/run-tests.sh --only pr-to-green-authorize-queue`, expect FAIL.

- [ ] **Step 3 (AM-03): replace lines 100–183** (from `` `scripts/authorize-queue.sh --allow-mechanical-advance` closes that gap without`` through `freshly confirmed one.`) with:

```markdown
`scripts/authorize-queue.sh --allow-mechanical-advance` closes that gap without widening consent.
It still requires an exact repository and provider-decision match; only when the live queue drifts
from the displayed snapshot does it reconcile each confirmed PR against fresh `pr-queue.sh`
evidence into exactly one bucket:

- **unchanged** — no drift.
- **root merge-down** — prior state `RUNNABLE`, same base, head changed, same diff fingerprint,
  and the authorized head proven an ancestor of the new head by a live `compare` read.
- **stacked retarget** — prior state `WAITING_FOR_MERGE`/`RETARGET_REQUIRED`, base changed, the
  same fingerprint and ancestry proof, plus `--retarget-proof PR:FILE` naming the exact line
  `../parallel-issues/scripts/chain-advance.sh --retarget` printed for this PR (matching base and
  head, `ancestry=verified`, `green:post-retarget`, an `approval=` token, a positive
  `closing-issues=`; `behind=`/`generated-only=`/`provider-check=` tokens may precede it).
- **verified merge** — a confirmed PR absent from the live queue and independently read as
  `merged:true`.

The diff fingerprint is a sha256 over the sorted per-file `{filename, blob sha, patch}` list from a
live `pulls/N/files` read, computed by `pr-queue.sh`; a failed or oversized read yields a null
fingerprint that satisfies no bucket. Anything that fits no bucket fails closed with the same
redisplay-and-reconfirm refusal as without the flag, and the helper prints why. The Step 3
transition and `merge-pr.sh` still re-read the live PR at the moment of mutation. Several roots
share the one confirmed-queue file, so their re-run/reconfirm sequences serialize; reviews and
transitions stay concurrent.
```

- [ ] **Step 4 (AM-01): replace lines 184–265** (from `## The pre-merge review-completion gate` through `a truncated `{` from a pretty-printed JSON error body.`) with:

```markdown
## The pre-merge review-completion gate

Before any merge, run `scripts/merge-gate.sh` for the exact confirmed head. It re-reads the PR and
its reviews live and consumes:

- `--pr-state-digest FILE` — `gh-pr-state.sh --full` output for this head, captured with its own
  `--digest-out FILE` (never a shell redirect: a group- or world-writable file is rejected). A
  digest whose `sha=` is not the confirmed head blocks.
- `--provider-result RESULT` — the CodeRabbit result the transition step printed (`AUTO_REVIEW`,
  `TRIGGERED`, `ALREADY_SPENT`, `LANDED`, `STALE_HEAD`, `OBSERVE_ONLY`, `DISABLED`, `BLOCKED`,
  `NONE`). `AUTO_REVIEW`, `ALREADY_SPENT`, and `LANDED` pass; `TRIGGERED` (review in flight) and
  `STALE_HEAD` (review for an earlier head) block.
- `--human-items-decided yes|no` — `no` blocks.
- `--adversarial-review-status covered-head|covered-diff|covered-lineage|stale|absent|blocked|not-required`
  — the word `review-ledger.sh status` prints for this head. The three `covered-*` values pass;
  `stale`, `absent`, and `blocked` block; `not-required` is only ever passed through from a
  documented materiality skip.
- `--code-quality-scan-state complete|pending|not-enabled` and/or `--code-quality-state-file FILE`
  — from `code-quality-state.sh --head SHA --pr N` (its `--state-file` output is the file form;
  both must agree byte-for-byte). `pending` blocks; `complete` and `not-enabled` pass; an
  unreadable probe reports `unknown` and blocks.

Every block prints `blocked reason=…`; `scripts/merge-gate.sh --help` carries the full enum.
```

- [ ] **Step 5 (AM-02): replace lines 331–370** (from `Code-scanning completion is proven from` through `at all" exception below waives that.`) with:

```markdown
Code-scanning completion is proven from `GET code-scanning/analyses`, never from a check-run's
`app.slug`: an analysis on `refs/pull/N/merge` matching the head or the PR's `merge_commit_sha`, or
on `refs/pull/N/head` matching the head. A still-running scan under either app slug only rules
completion out. A repository whose recent history has no `refs/pull/*` analysis but does scan its
base is reported `code-scanning: scheduled-only, last analysis <date> on <ref>` and does not block
on completion; it still needs a readable zero-count alerts line. Every other absence blocks, and an
unreadable probe never grants an exemption. The gate prints which case applied.
```

- [ ] **Step 6 (AM-04): replace lines 450–499** (from `### Dependents check before delete (issue #564)` through `point `authorize-queue.sh` composes the authorization record.`) with:

```markdown
### Dependents check before delete (issue #564)

Deleting a merged head branch can make GitHub close, rather than retarget, an open dependent that
is a draft or not cleanly mergeable. `--delete-branch` therefore reads
`pulls?state=open&base=<head>` first: with no dependents it deletes; with dependents it refuses,
names them, and exits 3 (the merge already succeeded); an unreadable check refuses too.
`--retarget-dependents` is opt-in and only repoints each dependent's base with a verified `PATCH` —
pass it only after the merge-down and `chain-advance.sh --retarget` proof in
`parallel-issues/references/chains.md` are complete for every dependent. After a delete under that
flag, `merge-pr.sh` re-reads each dependent and recovers any closed one via
`../../parallel-issues/scripts/chain-advance.sh --recover-closed` (best-effort; reported as
`dependent-recovery-failed` when it cannot). `authorize-queue.sh` records `deleteBranch:
"deferred"` for a predecessor with an open successor in the same confirmed queue, and
`merge-pr.sh` refuses that delete on the record alone.
```

- [ ] **Step 7 (green):** `wc -c` ≤ 21,500 (the plan text measures 21,344); `tests/run-tests.sh --only pr-to-green-authorize-queue,pr-to-green-merge-gate,pr-to-green-merge-pr` (use the suite names `ls tests/test-pr-to-green-*.sh` prints) plus `tests/lint-helper-refs.sh agentkit/skills && tests/lint-markdown-blocks.sh agentkit/skills`; then full `tests/run-tests.sh`. Restore any pinned sentence a test names.

- [ ] **Step 8: Shared step** with `SCOPE=auto-merge`, `TITLE='stop narrating merge-gate, authorize-queue, and merge-pr internals'`, `WHY='Four sections restated what merge-gate.sh, authorize-queue.sh, and merge-pr.sh print and enforce (blocked reason=, exemptions=disabled reason=, exit 3 naming dependents) on a reference every --auto-merge run reads.'`, `WHAT='Mechanical-advance buckets, merge-gate flags, code-scanning proof, and dependents/delete each reduced to the flag or bucket plus one line. 33,852 -> <measured> bytes.'`, `ISSUE=<T3>`.

---

### Task 4: `review-remote-pr/references/provider-rules.md` — PV-01…PV-03

**Files:**
- Modify: `agentkit/skills/review-remote-pr/references/provider-rules.md:124-174, 218-245, 454-481`
- Test: `tests/lint-helper-refs.sh` (tokens `scripts/classify-issue-comment-findings.sh`, `"$agentkit/.shared/shell-portability.md"` on the Pitfalls intro line must survive), `tests/test-recipe-safety.sh:77`, `tests/test-review-author-classification.sh`, `tests/test-gh-pr-state.sh`

- [ ] **Step 1: Worktree/branch `refactor/size-w1-provider-rules`; record `wc -c` (38,631).**

- [ ] **Step 2 (red):** add to `tests/test-review-author-classification.sh` immediately before its final `finish` line `assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/review-remote-pr/references/provider-rules.md") -le 32000 ]] && printf yes || printf no)" 'provider-rules reference stays at or under 32000 bytes'`; run its suite; expect FAIL.

- [ ] **Step 3 (PV-02): replace lines 124–174** (`## Provider identity — why the author matters` through `this probe at most once per invocation.`) with:

```markdown
## Provider identity — why the author matters

Only CodeRabbit (`coderabbitai[bot]`, `coderabbitai` — exact logins, never a substring) and
`github-code-quality[bot]` get provider-specific handling. Other authors enter the generic automated
lane only when the forge type is `Bot` or the login ends exactly in `[bot]`; **every ambiguous
author is human**, including the authenticated `gh` account. Reserved
`<!-- review-remote-pr:agent-... -->` markers identify workflow-created comments and nothing else.
The digest's `generic=`/`human=` counts, `classification:` line, and `next:` lines apply exactly
this rule — follow `next:` instead of re-deriving a step from a raw count. `nitpicks: N unhandled`
is a mechanical proxy (review and conversation bodies matching /nitpick/i or the broom emoji, minus
threads this workflow already opened); `issue-comment-findings: N open` (agent-kit#566) is the
separate count `scripts/classify-issue-comment-findings.sh list --comments FILE` produces for
findings posted as plain issue comments (see Step 5). `alerts: code-scanning n/a` means 403/404
and is not a failure. `code-quality-state.sh --probe` resolves `state=not-enabled` only on a 403
that says the feature is disabled; anything else is `state=unknown` and stays blocked (issue #403).
```

- [ ] **Step 4 (PV-03): replace lines 218–245** (`## CodeRabbit state check (informational — never a trigger decision)` through `Never advise buying credits.`) with:

```markdown
## CodeRabbit state check (informational — never a trigger decision)

A green "CodeRabbit" check or an ack comment is not a review. Read `gh-pr-state.sh`'s
`provider: coderabbit=…` line, built from the most recent terminal review object:

- `reviewed state=… threads=N since=TIMESTAMP` — a review landed for the current head; work its
  threads in Phase C Step 5 (0 threads is a legitimate outcome).
- `stale-head state=STATE commit=SHA` — a real review for an earlier head; keep waiting, never
  re-trigger, never treat as `none`.
- `none` — nothing landed; post no review command and leave any trigger decision to the user.
- `rate-limited` — observe bounded rounds and report; never advise buying credits.
```

- [ ] **Step 5 (PV-01): in the `## Pitfalls` table (lines 454–481) keep the header row, the separator, and exactly these twelve rows, deleting the rest:** `resolveReviewThread` returns NOT_FOUND; Code Quality findings request 403s mid-gate; Inaccurate Code Quality finding; Code Quality dismissal command temptation; Code Quality vs code scanning API confusion; Multiple provider review cycles (the only home of the incremental-review autopause rule); CodeRabbit check green but no real review; CodeRabbit trigger comment answered as chat, no review filed; Body nitpick has no thread ID; Tempted by `@coderabbitai resolve` (bulk) (the only home of that prohibition); Backticks in a comment body get command-substituted; Reply to comment returns 404. Line 452 (the shell-portability pointer) stays byte-identical.

- [ ] **Step 6 (green):** `wc -c` ≤ 32,000 (≈ 31,800 expected); `tests/run-tests.sh --only recipe-safety,review-author-classification,gh-pr-state` plus `tests/lint-helper-refs.sh agentkit/skills && tests/lint-markdown-blocks.sh agentkit/skills`; full suite.

- [ ] **Step 7: Shared step** with `SCOPE=provider-rules`, `TITLE='dedupe the pitfalls table and the two digest legends'`, `WHY='A mandatory Step 1a read carried a 32-row pitfalls table that restates rules from the same file and two legends for digest lines gh-pr-state.sh already prints with next: hints.'`, `WHAT='Pitfalls keeps the 10 rows with a unique fact; Provider identity and the CodeRabbit state legend become one line per fact/state. 38,631 -> <measured> bytes.'`, `ISSUE=<T4>`.

---

### Task 5: `parallel-issues/references/chains.md` — CH-04, CH-01, CH-05, CH-03

**Files:**
- Modify: `agentkit/skills/parallel-issues/references/chains.md:63-86, 166-217, 238-267, 314-350`
- Test: `tests/test-parallel-dispatch-contract.sh:161-180` (flat-text pins), `tests/test-chain-advance.sh`

**Pinned (flat text):** `pushed commit`, `Publishing a locally-built chain base`, `a linear chain is not protected from this just because it only had one predecessor` (keep on one line), plus every join-recipe literal in lines 19–61 (untouched).

- [ ] **Step 1: Worktree/branch `refactor/size-w1-chains`; record `wc -c` (25,481).**

- [ ] **Step 2 (red):** add to `tests/test-chain-advance.sh` immediately before its final `finish` line `assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/parallel-issues/references/chains.md") -le 18000 ]] && printf yes || printf no)" 'chains reference stays at or under 18000 bytes'`; run `--only chain-advance`; expect FAIL.

- [ ] **Step 3 (CH-04): replace lines 63–86** (`## Publishing a locally-built chain base` through `and it does not wait for the PR to exist.`) with:

```markdown
## Publishing a locally-built chain base

`create-issue-worktree.sh` pushes a branch exactly once, at creation; any merge commit added
afterward (a join's integration commit, or a successor's merge-down of an advanced predecessor) is
invisible to `origin` until pushed — a linear chain is not protected from this just because it only had one predecessor.
Push before handing a commit to a successor's worktree creation or to review; a worker's interim
verification needs no push, since `agent-run.sh` runs against what is on disk.

Chains gate on the predecessor's **pushed commit** (the completion report carries the full SHA),
never on PR state or the root's publication ceremony.
```

- [ ] **Step 4 (CH-01): replace lines 166–217** (`Two of these proofs tolerate evidence a retarget can never make current` through `but it is a record, not a gate.`) with:

```markdown
Two proofs tolerate evidence a retarget can never make current (issue #577), and the proof line
reports them ahead of `closing-issues=`:

- `behind=N generated-only=yes|no` — a `behind_by` gap confined entirely to declared
  `AGENT_GENERATED_PATHS` is reported, not refused; any undeclared path in the gap refuses.
- `provider-check=<names>|none|unreadable` — a stale check is excused only when its check-run's own
  `.app.slug` belongs to a provider in `AGENT_REVIEW_PROVIDERS`; unreadable grants nothing.
- `approval=current:post-retarget|residue:stale|none|unknown` — recorded, never a gate (issue #455):
  formal approval is provider policy and settles at the ready/provider transition.

Both exemptions read *this checkout's* `.agent/config.env` and print
`exemptions=disabled reason=repo-mismatch` when the checkout's own slug differs from `--repo`.
```

- [ ] **Step 5 (CH-05): replace lines 238–267** (`For an interactive human merge, merging in dependency order` through `provider action is trigger or observe.`) with:

```markdown
For an interactive human merge, deleting the merged head may make GitHub close a draft or
not-cleanly-mergeable successor instead of retargeting it (#484, #561, issue #564).
`merge-pr.sh --delete-branch` never relies on that: it reads for open dependents first and by
default refuses the delete and names them; `--retarget-dependents` is opt-in after this file's
merge-down-then-`chain-advance.sh --retarget` procedure has completed for every dependent, and a
dependent GitHub closes anyway is recovered with `chain-advance.sh --recover-closed` (also the fix
for a successor an older kit or a human merge left closed). See
`pr-to-green/references/auto-merge.md`'s "Dependents check before delete" for the contract.

A retarget invalidates the successor's evidence: after every parent merge, revalidate each open
successor with the helper's live `base...head` ancestry read and require CI against the new base
before treating it as green; a stale digest is a stop signal, and a stale approval is reported as
`approval=residue:stale`, never inherited or re-triggered.
```

- [ ] **Step 6 (CH-03): replace lines 314–350** (`## Contract-inheritance refusal and recovery` through `re-dispatching the link's lead.`) with:

```markdown
## Contract-inheritance refusal and recovery

`create-issue-worktree.sh` carries the root's `.agent/env-contract.txt` into each new worktree with
`agent-preflight.sh --inherit-session`, and a same-harness source past the inheritance window is
revalidated (never-widen on every field) rather than discarded, so a long chain's pushed commit
handoff no longer trips `compose-worker-prompt.sh`'s `worktree-contract-less-restrictive-than-root`
refusal. If that refusal still appears (a source written by a different harness is never inherited):

1. Re-run preflight at the ROOT checkout.
2. Re-run `agent-preflight.sh --worktree <worktree> --inherit-session <root-env-contract>`.
3. Re-run `compose-worker-prompt.sh` for that link.

Safe to repeat; nothing mutates git state or re-dispatches the lead.
```

- [ ] **Step 7 (green):** `wc -c` ≤ 18,000 (the plan text measures 17,699); `tests/run-tests.sh --only parallel-dispatch-contract,chain-advance` plus `tests/lint-helper-refs.sh agentkit/skills && tests/lint-markdown-blocks.sh agentkit/skills`; full suite.

- [ ] **Step 8: Shared step** with `SCOPE=chains`, `TITLE='replace exemption internals and fixed-bug history with the proof-line legend'`, `WHY='The retarget-proof exemption internals, the before-this-was-fixed inheritance narrative, and a duplicate of auto-merge.md dependents contract cost every chain run tokens the proof line already prints.'`, `WHAT='An 8-line token legend for behind=/generated-only=/provider-check=/approval=; the 3-step recovery without the history; publishing-a-chain-base and human-merge sections trimmed to their rule. 25,481 -> <measured> bytes.'`, `ISSUE=<T5>`.

---

### Task 6: `parallel-issues/references/worker-prompts.md` — WP-01, WP-02, WP-05, WP-06

**Files:**
- Modify: `agentkit/skills/parallel-issues/references/worker-prompts.md:89-93, 111-121, 162-176, 217-231, 661-670, 709-723, 728-735, 751-765`
- Test: `tests/test-compose-worker-prompt.sh`, `tests/test-compose-worker-prompt-scope.sh:305-318`, `tests/test-parallel-dispatch-contract.sh:714-722, 810-820`, `tests/test-contract-provenance.sh:207-215`

**Composer contract:** `compose-worker-prompt.sh:1120-1124` starts skipping on a line containing `<WHEN this parallel-issues invocation carried --yolo` and stops on the first *later* line containing `trust record.>`; the placeholder lines `__DECLARED_COMMANDS__` and `__IMAGE_INVALIDATING_WRITERS__` are substituted and must stay.

**Pinned (raw, one line each):** `paths-touched.ndjson` (`test-parallel-dispatch-contract.sh:1389`), `Harness-global rules are already applied`, `Never search outside the worktree`, `` Vendored and `node_modules` instruction files ``, `` do not load `review-remote-pr/SKILL.md` `` (case-sensitive; `test-parallel-dispatch-contract.sh:345, 639-657`), `` Use the authoritative `instructions=` line from `.agent/env-contract.txt`; inspect only `` (`:1090`), `**Filesystem scope:**`, `**Ownership boundary:**`, `Your working set is the current worktree`, `` contract `skills=` tree ``, `` `/tmp`, contract cache directories ``, `` no `$HOME` sweeps, sibling repositories ``, `Before generating any patch, re-read the target file`, `expanded literal value`, `worker_attribution=`, `contract-read.sh`, `Committing and pushing the assigned branch is yours`.

- [ ] **Step 1: Worktree/branch `refactor/size-w1-worker-prompts`; record `wc -c` (50,903) and the composed issue-lead prompt size:**

```bash
bash agentkit/skills/parallel-issues/scripts/compose-worker-prompt.sh --template issue-lead --boundary public-fenced --write-set 'src/**' --worktree "$(pwd)" --issue 1 --branch feat/issue-1 --worker-model gpt-5.6-luna --worker-effort high 2>/dev/null | wc -c
```

- [ ] **Step 2 (red):** in `tests/test-compose-worker-prompt.sh`, right after the `prompt=$(bash "$compose" --template issue-lead …)` capture (line ~104), add `printf 'issue-lead prompt bytes: %s\n' "${#prompt}"` and run `tests/run-tests.sh --only compose-worker-prompt` once to read the measured size M. Then replace that printf with `assert_eq yes "$([[ ${#prompt} -le 20500 ]] && printf yes || printf no)" "issue-lead prompt stays at or under 20500 bytes (measured ${#prompt})"`; re-run; expect FAIL (M is 21,791 on main; the WP-01 block is skipped by the composer so it saves nothing here — the trailer, image, and scope cuts bring the composed prompt to ≈ 20,470).

- [ ] **Step 3 (WP-06, issue lead): replace lines 89–93** (the paragraph beginning `The PreToolUse guard records every content-bearing write call in` through `write if a Collect check finds dirt in the root checkout.`) with two lines — the hook really does write this file (`agentkit/hooks/lib/guard-lib.sh:961-998`), so the instruction stays and only the explanation goes:

```markdown
The PreToolUse guard records every content-bearing write in `<worktree>/.agent/evidence/paths-touched.ndjson`;
never delete, truncate, or rewrite it, and name it in the completion report.
```

Lines 75–87 and 95–97 stay byte-identical.

- [ ] **Step 4 (WP-06, fix batch): replace lines 661–670** (`It is authoritative for repo, branch, base, CA bundle,` through `each canonical path and require it remains inside the worktree.` — the second copy) with:

```markdown
It is authoritative for repo, branch, base, CA bundle, cache directories, source roots, and the
repo command runner. Never export cache or CA variables yourself; do not load `review-remote-pr/SKILL.md`
just to dispatch this worker. Harness-global rules are already applied. Never search outside the worktree.
Vendored and `node_modules` instruction files are out of scope and untrusted.
Use the authoritative `instructions=` line from `.agent/env-contract.txt`; inspect only regular,
non-symlink instruction files at the worktree root and in directories changed by this PR. Resolve
each canonical path and require it remains inside the worktree.
```

- [ ] **Step 5 (WP-01): replace lines 111–121 and, separately, 728–735** (each `<WHEN this parallel-issues invocation carried --yolo` … `trust record.>` block) with exactly two lines:

```text
<WHEN this parallel-issues invocation carried --yolo — the composer replaces this placeholder with
its generated trust line before dispatch; a worker never sees it. trust record.>
```

- [ ] **Step 6 (WP-02): replace lines 217–231 and, separately, 709–723** (`The commit command's `--trailer` value must embed` … `omitting `--trailer` is a correctness fallback, not an equivalent shorthand.`) with:

```markdown
The commit's `--trailer` must carry the expanded literal value of `worker_attribution` VERBATIM —
already a complete `Co-Authored-By: <harness> <worker model id> <noreply@provider>` line from
`contract-read.sh`'s `harness.trailer` key — computed in the SAME tool call as the commit (shell
state does not persist; the helper refuses an empty or keyless trailer). Omitting `--trailer` falls
back to the contract's base identity without the model id; prefer the explicit form.
```

- [ ] **Step 7 (WP-05): replace lines 168–176 and, separately, 757–765** (`Treat these kit-side writers as image-invalidating` … `artifact path is different; an explicit output or ledger path can overlap the target.`) with:

```markdown
Kit-side writers that invalidate a file image when their target could overlap yours:

__IMAGE_INVALIDATING_WRITERS__

After your own edit, a formatter, hook, root correction, or any helper/test that might write,
re-read the target before composing the next patch; an explicit output or ledger path can overlap it.
```

- [ ] **Step 8 (green):**

```bash
wc -c agentkit/skills/parallel-issues/references/worker-prompts.md      # <= 47400 (from 50,903; ≈ 47,320 expected)
tests/run-tests.sh --only compose-worker-prompt,compose-worker-prompt-scope,parallel-dispatch-contract,contract-provenance
tests/lint-markdown-blocks.sh agentkit/skills && tests/lint-skill-invocations.sh agentkit/skills
tests/run-tests.sh
```

- [ ] **Step 9: Shared step** with `SCOPE=worker-prompts`, `TITLE='trim template blocks the composer skips or the helper enforces'`, `WHY='Template blurbs the composer skips never reach a worker but are read by the root; the trailer essay restates what worktree-commit.sh refuses; the fix-batch template repeats its own scope paragraph.'`, `WHAT='<WHEN…trust record.> blocks to the two marker lines; trailer, file-image, write-ledger, and fix-batch scope paragraphs tightened with every pinned sentence kept. 50,903 -> <measured> bytes; composed issue-lead prompt 21,791 -> <measured>.'`, `ISSUE=<T6>`.

---

### Task 7: `parallel-issues/SKILL.md` narration/NET cuts, section-conditional read set, WG-02, ceiling ratchet

**Files:**
- Modify: `agentkit/skills/parallel-issues/SKILL.md:28, 158-179, 247-250, 288-331, 360-369, 527-533, 637-650, 705-712, 858-868, 889-895, 1029-1036, 1065-1073, 1101-1105`
- Modify: `agentkit/skills/review-remote-pr/references/worker-gate.md:89`
- Modify: `agentkit/skills/references.md:46, 53, 56` (read-when conditions)
- Modify: `tests/lint-skill-size.sh` (`[parallel-issues]=` entry), `tests/test-skill-size.sh:224,226`
- Test: `tests/test-parallel-dispatch-contract.sh`, `tests/test-skills-contract.sh:460-476`, `tests/test-wait-bound.sh:55-65`, `tests/test-adversarial-review-receipt.sh`, `tests/test-autonomy-flags.sh:197`, `tests/lint-helper-refs.sh` (first-mention rule), `tests/lint-reference-manifest.sh`, `tests/lint-rest-routing.sh`

**Pinned (raw unless marked flat):** the `Single issue, no chain:` line up to `Defer chain/review references` must still name `"$agentkit/references.md"`, `references/triage-and-selection.md`, `references/worker-prompts.md`, `.shared/spawn-contract.md`, and `.shared/six-step-loop.md`, and must not name `references/chains.md` or `review-remote-pr/references/` (`test-parallel-dispatch-contract.sh:1333-1353`); the first line naming each `references/<file>.md` must carry a `Read … in full` or `See … for` cue (`test-skills-contract.sh:426-446`); `**900 s** minimum, draft-loop/review/CI waits **600 s**`; `` Dispatch already printed this worker's own bound as a `wait-bound=` ``; `### Polling discipline` (section marker); `### Root review and draft PR after a worker push` (marker); `Environment-refusal fallback only`; `Invoke returned argv once, then push the branch` (flat); `preserves the raw command text for audit` (flat); `parse into validated arguments without eval`; `validate-handback.sh`; `if ! "$agentkit/.shared/scripts/validate-handback.sh"`; `### Final draft sweep` (marker) with `Final draft sweep`, `CI settled`, `Code Quality dispositioned`, `exactly one of {adversarial receipt, verified skip receipt}`, `gh-pr-state.sh` before `post-receipt.sh" status`, `--full --no-cache`, `10:receipt=none` inside that section; `exit 0`; `../.shared/six-step-loop.md`, `../.shared/spawn-contract.md`, `../.shared/wait-discipline.md`, `../.shared/github-body-policy.md`, `../.shared/shell-portability.md` (each must appear somewhere in the body); `--no-brainstorm`; every literal in the receipt precheck/publish blocks (979–1031, untouched).

- [ ] **Step 1: Worktree/branch `refactor/size-w1-parallel-issues` from Task 1's branch `refactor/size-w1-ratchet` (its declare form is what the probe below edits; chain the PR on Task 1 or wait for it to merge); baseline**

```bash
tests/lint-skill-size.sh agentkit/skills | tail -1
sed -i 's/^    \[parallel-issues\]=".*"/    [parallel-issues]="1:1:900"/' tests/lint-skill-size.sh; tests/lint-skill-size.sh agentkit/skills 2>&1 | grep -o 'grew to [0-9]* lines\|~[0-9]* tokens' ; git checkout tests/lint-skill-size.sh
```

Expected: the second command prints today's measured body size (`1105 lines`, `~19905 tokens`) — the ceiling-probe recipe used again in Step 13.

- [ ] **Step 2 (red): lower the ceiling first.** Set `[parallel-issues]="1040:18750:900"` in `tests/lint-skill-size.sh` and change `tests/test-skill-size.sh:224,226` to `1040 lines` / `18750 tokens`. Run `tests/run-tests.sh --only skill-size`. Expected: FAIL (`grew to 1105 lines, past its ratcheted ceiling of 1040`).

- [ ] **Step 3 (PI-01): delete lines 158–179** (`## Process` heading, the ```` ```dot ```` fence, and the blank line after it). Then run `tests/lint-helper-refs.sh agentkit/skills 2>&1 | grep -i 'first helper mention' || true`. It will report `agent-preflight.sh`: the new first mention is line 185 (`Run `agent-preflight.sh` once before any other command`); change it to `` Run `$agentkit/.shared/scripts/agent-preflight.sh` once before any other command `` (lines 205 and 236 also precede the `preflight=` assignment, so the fix must be at 185).

- [ ] **Step 4 (PI-03 + B-03): rewrite Step 1's block (lines 288–327) as**

```bash
set -euo pipefail

# >>> prepend THE CACHE REHYDRATION (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend THE CACHE REHYDRATION block" >&2; exit 1; }
repository_root=$contract_root
# Declared config facts win; absent ones come from the Step 0 contract, never from the network.
resolver="$agentkit/.shared/scripts/repo-config.sh"
[[ -x $resolver ]] && eval "$("$resolver" --export)"

repository=${AGENT_REPO_SLUG:-}
[[ -n $repository ]] || repository=$("$agentkit/.shared/scripts/contract-read.sh" --repo-root "$repository_root" --get repo.slug) || exit 1
[[ $repository == */* ]] || { printf '%s\n' 'repo=none in the environment contract; re-run the Step 0 preflight from a checkout with a GitHub origin' >&2; exit 1; }
base=${AGENT_BASE_BRANCH:-}
[[ -n $base ]] || base=$("$agentkit/.shared/scripts/contract-read.sh" --repo-root "$repository_root" --get base.branch) || exit 1
[[ $base != none ]] || { printf '%s\n' 'base=none in the environment contract; set origin/HEAD (git remote set-head origin -a) and re-run preflight' >&2; exit 1; }

IFS=/ read -r owner repository_name <<< "$repository"
printf 'repository_root=%s\nrepository=%s\nowner=%s\nrepository_name=%s\nbase=%s\n' \
    "$repository_root" "$repository" "$owner" "$repository_name" "$base"
```

and delete the three-line paragraph after the block (`The Step 0 preflight already reported whether a config exists…`). Update the table row at line 276 that says the Bash blocks re-derive repo/base because each block is self-contained and that `repo=none` is where Step 1 does real work: it now reads `Step 1 reads `repo.slug`/`base.branch` from the contract and stops on `none`.` (`contract-read.sh` prints the literal `none` with exit 0 for an absent value — the two guards above are what replaced the network fallback). Verify the keys exist: `agentkit/skills/.shared/scripts/contract-read.sh --repo-root /home/adam/github/agent-kit --get repo.slug` prints `wrzonance/agent-kit` and `--get base.branch` prints `main`. Also replace lines 247–250 (the `if ! repository_root=$(git rev-parse …` guard in the preflight block) with `repository_root=$contract_root` placed after that block's guard line. In the chain-base block (lines 526–539) **delete lines 529–536** (the `repository_root` guard and the `base=$(git remote show origin …)` guard) and insert, **immediately after the rehydration guard line at 539** (below `issue_number=123 …` and the guard, above `chain_base_sha=`), these two lines — a helper call above the guard fails `lint-skill-invocations.sh` (`GUARD AFTER HELPER`):

```bash
repository_root=$contract_root
base=$("$agentkit/.shared/scripts/contract-read.sh" --repo-root "$repository_root" --get base.branch) && [[ $base != none ]] || exit 1
```

(`contract_root` is set by the pasted rehydration block, line 221, and by the resolver, line 198.)

- [ ] **Step 5 (PI-04): delete lines 360–369** (the ```` ```text ```` sample listing after `Each line reads …`) and its trailing blank line.

- [ ] **Step 6 (PI-08): replace lines 637–650** with:

```markdown
**The printed line is the evidence.** `move-github-project-item.sh` prints one terminal stdout line
per issue and board; every shape returns exit 0 (a board move never fails real work), so only a
leading `moved #N -> STATUS` or `no-op: issue #N already "STATUS"` completes that issue's phase —
never follow it with a verification query or a second invocation. It needs Projects access (fleet
App: `Projects: write`).
```

- [ ] **Step 7 (PI-09): replace lines 705–712** with:

```markdown
The root is the sole artifact producer: the script fetches, validates, and atomically publishes the
fenced files, raw payload, and ready marker into excluded `.agent/` state, and the prompt embeds
those bytes verbatim. Re-running on an existing complete set is refused (exit `12`, with the exact
remedy printed); `--resume` archives the set under `.agent/evidence/fence-history/<timestamp>/` and
regenerates without touching implementation files.
```

- [ ] **Step 8 (PI-10): replace lines 858–868** with:

```markdown
**Environment-refusal fallback only** — two shapes. A post-commit **push refusal**: the worker
reports the commit SHA and push command; root verifies the SHA exists in the worktree and pushes. A
**commit refusal** (`worktree-commit.sh` exit 2): the worker returns the publication handback and
root preserves the raw command text for audit. Validator: parse into validated arguments without eval;
validate the expected worktree-commit.sh helper, Conventional Commit, required worker trailer, every
explicit path inside the worktree and allowed, and every staged path declared and unprotected; emit NUL
argv naming the canonical helper. Invoke returned argv once, then push the branch. Only after
publication does the root inspect `base...HEAD`; never validate a base diff.
```

(No bare `validate-handback.sh` mention here: the rooted call in the block below is the file's first mention and `lint-helper-refs.sh` requires it to stay first.)

- [ ] **Step 9 (PI-11): replace lines 889–895** (`### Polling discipline …` through `read it and stop.`) with:

```markdown
### Polling discipline (applies to every wait in this skill)

Read [.shared/wait-discipline.md](../.shared/wait-discipline.md) in full before the first wait; it
owns the no-model-turn rule, one wait per interval, and the durable-state recipe. A bounded wait is
silent until terminal: emit only the one completion or expiry line and redirect any heartbeat to a log.

Every wait names its numeric bound at the call site: worker implementation waits are **900 s** minimum, draft-loop/review/CI waits **600 s** (the shared file's default-bounds table). Dispatch already printed this worker's own bound as a `wait-bound=` line when composing its prompt — quote that printed value instead of recalling this rule. A `timed_out:true` return is never re-issued at the same duration; escalate the bound or run the Collect section's stall check.

After completion, inspect durable state (worktree `git status`/`log`, then
`$agentkit/review-remote-pr/scripts/gh-pr-state.sh --pr N --repo OWNER/REPO` with acceptance args):
[.shared/wait-discipline.md](../.shared/wait-discipline.md#durable-state-to-inspect-after-a-completion).
The digest exits 0 for green, failing, or pending CI — read it and stop.
```

(`silent until terminal` is pinned raw at `test-parallel-dispatch-contract.sh:333` and the rooted `gh-pr-state.sh` path here is the file's first mention.)

- [ ] **Step 10 (PI-13 trimmed, PI-14, PI-15):**
  - Keep lines 1029–1031 (the two `#` comment lines and the closing ```` ``` ```` fence) and replace lines 1032–1036 (the paragraph `The ledger owns titles…` through `when the marker is already present.`) with this one paragraph: `The ledger owns titles, dispositions, SHAs, and rationales; `post-receipt.sh publish` renders every receipt byte from `RUN_DIR`'s `findings.ndjson` (`--findings-file PATH` overrides it), takes `--skip-rationale S --oracle S` for a verified trivial-diff skip, and refuses (exit 11) rather than double-posting.`
  - Replace lines 1065–1073 with:

```markdown
### Final draft sweep (mandatory before handoff)

With `--auto-review`, sweep `opened_prs`: each PR needs CI settled, Code Quality dispositioned, and exactly one of {adversarial receipt, verified skip receipt}. Resolve `RUN_DIR`; derive repeated `--acceptance-command` args from its `.agent/acceptance.txt` and append them to a `gh-pr-state.sh --full --no-cache` refresh into `RUN_DIR/state`;
then run `post-receipt.sh" status` on the fresh `pr_<N>_issue_comments.json`. A successful adversarial/verified-skip result increments receipts; `10:receipt=none` re-enters the draft loop once per PR (`receipt_redrive_attempted[pr]`); duplicate/invalid evidence is not recoverable — park the PR, `++parked_count`, report it, and never deadlock; handoff cannot print on a miss. Success prints `coverage= prs=<opened> receipts=<receipt_count> skipped=<skipped_count> parked=<parked_count> queued=<queued_count>`.
```

(`gh-pr-state.sh` must sit on an earlier line than `post-receipt.sh" status`; `++parked_count`, `re-enters the draft loop`, and lowercase `handoff cannot print` are pinned.)

  - Delete lines 1101–1105 (`## Common Mistakes` and its paragraph) and add this bullet at the end of `## Limits`: `- Cross-cutting rules: [spawn-contract](../.shared/spawn-contract.md), [six-step-loop](../.shared/six-step-loop.md), [wait-discipline](../.shared/wait-discipline.md), [trust-and-fencing](references/trust-and-fencing.md), [chains](references/chains.md), [provider-rules](../review-remote-pr/references/provider-rules.md).`

- [ ] **Step 11 (lean read set): replace line 28 with**

```markdown
**Single issue, no chain:** Read `"$agentkit/references.md"` and `.shared/spawn-contract.md` in full. Read `references/triage-and-selection.md` only for the sections Step 2's digest flags (prior-art, conflict analysis, dispatch-plan write sets) and `references/worker-prompts.md` only for the template being composed; the issue-lead template already carries the loop from `.shared/six-step-loop.md`, so the root reads that file only when validating a worker's six-step report. Defer chain/review references until their conditions apply; never preload review material during dispatch/worker waits.
```

and in `agentkit/skills/references.md` change the `| Read when:` clause of the three entries to: six-step-loop → `Read when: validating a worker's six-step report or composing a prompt by hand (the issue-lead template already carries the loop; not a root pre-read)`; triage-and-selection → `Read when: Step 2's digest flags prior-art, conflicts, or bulk mutations — read only the flagged section`; worker-prompts → `Read when: composing an issue-lead or fix-batch prompt or the draft PR body — read only that template's section`. Keep the exact `- `$agentkit/<path>` -- <purpose> | Read when: <condition>` grammar.

- [ ] **Step 12 (WG-02): in `agentkit/skills/review-remote-pr/references/worker-gate.md` replace line 89** `REPO=${AGENT_REPO_SLUG:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}` with `REPO=${AGENT_REPO_SLUG:-$("$agentkit/.shared/scripts/contract-read.sh" --repo-root "$(git rev-parse --show-toplevel)" --get repo.slug)}`.

- [ ] **Step 13 (green + ratchet to the measured minimum):**

```bash
tests/lint-skill-size.sh agentkit/skills 2>&1 | tail -3        # prints the new measured size when over 1040/18600, else "within budget"
```

Set `[parallel-issues]="L:T:900"` to exactly the printed lines/tokens (if the lint says the skill is within the probe ceiling, temporarily set `1:1:900`, read the printed values, then set them) and update `tests/test-skill-size.sh:224,226` to the same two numbers. Then:

```bash
tests/run-tests.sh --only skill-size,parallel-dispatch-contract,skills-contract,wait-bound,adversarial-review-receipt,autonomy-flags,contract-provenance
for l in helper-refs reference-manifest rest-routing skill-invocations markdown-blocks skill-size; do tests/lint-$l.sh agentkit/skills || echo "LINT FAIL $l"; done
tests/run-tests.sh
```

Expected: all green; body ≈ 1012 lines / ~18,718 tokens (measured on the reviewer's scratch tree with exactly these texts); set the entry and the two pins to the printed values. Any pinned-literal failure → restore that sentence verbatim on one line.

- [ ] **Step 14: Shared step** with `SCOPE=parallel-issues`, `TITLE='cut helper-output narration and network re-derivations; section-conditional read set'`, `WHY='The most re-read file in the tree (twice after compactions in the 2026-09-05 run) narrated helper output shapes, re-derived repo facts over the network that the contract already holds, and ordered two 43-51 KB references read in full on every run.'`, `WHAT='Process graph, triage sample, board-move shapes, fence-prep prose, Common Mistakes and duplicated sweep sentences cut; Step 1 and the chain-base block read repo.slug/base.branch from contract-read.sh and stop loudly on none; triage-and-selection.md and worker-prompts.md read by section, six-step-loop.md dropped from the root pre-read; KNOWN_OVERSIZE[parallel-issues] 1105:19905 -> <measured>.'`, `ISSUE=<T7>`.

---

### Task 8: Tree-wide rehydration marker removal (B-01-lite) — runs after Tasks 2–7 merge

**Files:**
- Modify (delete lines only): `agentkit/skills/parallel-issues/SKILL.md` (11 marker lines), `review-remote-pr/SKILL.md` (9), `onboard-repo/SKILL.md` (10) — the references and `.shared` files carry the different `# >>> prepend THE RESOLVER (defined once in Step 0) <<<` marker, which this task does not touch
- Modify: `tests/test-contract-provenance.sh:125-127, 158-161`, `tests/lint-skill-invocations.sh:26` (comment), `tests/lint-skill-size.sh` (both entries), `tests/test-skill-size.sh:185,195,224,226`

**Invariant preserved:** every helper-invoking fence outside Step 0 still carries the executed guard `[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { … "agentkit unresolved: prepend THE CACHE REHYDRATION block" …; exit 1; }` — that line is what `tests/lint-skill-invocations.sh` (GUARD_EXPR_DIR + GUARD_EXPR_SENTINEL), `tests/test-adversarial-review-receipt.sh:62-63`, and `tests/test-parallel-dispatch-contract.sh:356-358` execute against, and its message already names the remedy. Only the comment line above it goes. The onboard-repo warm-up marker `# >>> prepend THE RESOLVER (initial warm-up only) <<<` stays (`test-contract-provenance.sh:106,155,173` key on it).

- [ ] **Step 1: Worktree/branch `refactor/size-w1-markers` from `origin/main` after Tasks 2–7 merged; confirm nothing executable keys on the marker**

```bash
grep -rn 'prepend THE CACHE REHYDRATION' agentkit/skills --include='*.sh' agentkit/hooks bench 2>/dev/null; echo "scripts: $?"   # expect no hits, exit 1
grep -rn '# >>> prepend THE CACHE REHYDRATION' agentkit/skills --include='*.md' | wc -l                                      # 30
```

If any `.sh`, hook, or bench file matches, STOP and report; the marker is load-bearing somewhere the audit missed.

- [ ] **Step 2 (red): repoint the two awk checks and lower both ceilings**

In `tests/test-contract-provenance.sh` delete lines 125–127 (`if (!initial && block !~ /# >>> prepend THE CACHE REHYDRATION \(defined once in Step 0\) <<</) printf "missing context rehydration before guard …"`), and change line 160's regex from `/# >>> prepend THE CACHE REHYDRATION \(defined once in Step 0\) <<</` to `/agentkit unresolved: prepend THE CACHE REHYDRATION block/` (the onboarding fresh-shell check now keys on the guard message). In `tests/lint-skill-invocations.sh` line 26–27 comment, replace the two example lines with one: `#   [ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf ...prepend THE CACHE REHYDRATION block...; exit 1; }`. Set `[parallel-issues]="1001:18539:900"` and `[review-remote-pr]="493:8167:450"` (the sizes measured after this deletion on the reviewer's scratch tree; the probe in Step 4 confirms them) and mirror the four numbers in `tests/test-skill-size.sh:185,195,224,226`. Run `tests/run-tests.sh --only skill-size,contract-provenance`; expect the size suite to FAIL and the provenance suite to PASS (the marker is still present, so the loosened check still holds).

- [ ] **Step 3: Delete every marker line**

```bash
grep -rl '# >>> prepend THE CACHE REHYDRATION' agentkit/skills --include='*.md' | xargs sed -i '/^[[:space:]]*# >>> prepend THE CACHE REHYDRATION/d'
grep -rn 'prepend THE CACHE REHYDRATION' agentkit/skills --include='*.md' | grep -v 'agentkit unresolved' | grep -v '#### THE CACHE REHYDRATION' ; echo "leftover markers: $?"   # expect exit 1
```

Keep the headings `#### THE CACHE REHYDRATION (prepend to each later guarded block)` and the prose that names them.

- [ ] **Step 4 (green + ratchet):** probe each skill's measured size with the `1:1:TARGET` trick from Task 7 Step 1, set both `KNOWN_OVERSIZE` entries and the four `tests/test-skill-size.sh` pins to the measured minimum, then:

```bash
tests/run-tests.sh --only skill-size,contract-provenance,adversarial-review-receipt,parallel-dispatch-contract,skills-contract
for l in skill-invocations markdown-blocks skill-size helper-refs; do tests/lint-$l.sh agentkit/skills || echo "LINT FAIL $l"; done
tests/run-tests.sh
```

- [ ] **Step 5: Shared step** with `SCOPE=skills`, `TITLE='drop the redundant rehydration marker comment; the guard line already names the remedy'`, `WHY='30 marker comments in the three single-source skills sit above a guard whose own error message says exactly the same thing, and every one is re-read after every compaction.'`, `WHAT='Marker lines deleted tree-wide; guards untouched; test-contract-provenance.sh keys on the guard message; both KNOWN_OVERSIZE entries ratcheted to the measured minimum (<before> -> <after> each).'`, `ISSUE=<T8>`.

---

## Deferred to wave two (with the reason)

- **B-02 single resolver block** — `tests/test-contract-provenance.sh:22-27,96-102` asserts the resolver's provenance literals inside *each* SKILL.md and `tests/test-skill-path-resolution.sh`/`test-skills-contract.sh:57-82` extract it from onboard-repo; the pointer form needs those four tests re-pointed at the canonical home. Net per-context saving is ~1.2K tokens because `shell-portability.md` is already read.
- **Full B-01 (guard-line removal)** — five test surfaces (`lint-skill-invocations.sh` GUARD_EXPR_*, `test-contract-provenance.sh` FULL_GUARD, `test-adversarial-review-receipt.sh:62-63`, `test-parallel-dispatch-contract.sh:356-358,1195`, `test-skill-invocations.sh`) would need a new invariant. Task 8 takes the marker only.
- **PI-22** — moves executed lines (`test-parallel-dispatch-contract.sh:471-497` kind c) into `compose-worker-prompt.sh`; overlaps #613.
- **RR-03** — `gh pr view --json baseRefName` is correct for a stacked PR whose base is not the default branch; the contract's `base.branch` is not a substitute. `mergeable` is read in 0b before the Step 1 digest exists.
- **PV-04+, AM-05+, CH-02, WP-03/04/07+, TS-*, OB-*, RR-*, PG-*, WD-01, EC-01, GB-01, SS-01, TF-01** — the remaining 70 rows of the audit; each is small and file-local, and wave two can take them file by file with the same red→green ratchet recipe.
