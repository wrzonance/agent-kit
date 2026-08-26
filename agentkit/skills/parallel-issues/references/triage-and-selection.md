# Triage adjudication and set selection

## Contents
- [Bulk mutation discipline: ledger, chunks, and resource budget](#bulk-mutation-discipline-ledger-chunks-and-resource-budget) — the resumable-ledger recipe for any batch of 2+ forge writes
- [Prior-art adjudication (only for merged-ref, in-flight, and attempted)](#prior-art-adjudication-only-for-merged-ref-in-flight-and-attempted) — reading the referenced PR and applying the ADR rules
- [Work-shape verdict](#work-shape-verdict) — classifying implementation vs. no-code/research before Step 5 ever creates a worktree
- [Conflict analysis and dispatch-plan write sets](#conflict-analysis-and-dispatch-plan-write-sets) — pinning predicted operands and recording revisions
- [Board adjudication](#board-adjudication) — same-board STOP rationale, the `--fast-mode` decision rule, and pickup order
- [Optional: fuzzy prior art](#optional-fuzzy-prior-art) — the opt-in low-yield search
- [Step 2b: Choose the set yourself](#step-2b-choose-the-set-yourself) — the mechanical selection procedure for a thin Ready column, `--fast-mode`, and thematic Backlog matching, in place of the approval gate

This is the detail behind SKILL.md's Step 2 triage digest: read the section you were pointed at
for the verdict(s) the digest actually flagged, or the `--fast-mode` set-selection procedure when
that flag is in play. A `clean` verdict needs none of this file.

## Bulk mutation discipline: ledger, chunks, and resource budget

Any batch that creates or edits more than one forge object carries a resumable
apply ledger. The planning ID is the stable key; a successful mutation is
followed immediately by one `record` call containing the returned number and
URL. This batch has no PR yet, so its ledger and plan are transient bulk
artifacts: they belong in the private, mode-0700 run directory addressed by
the invocation-level `RUN_ID` SKILL.md's Session decision ledger section
establishes — never at a bare repository-relative path, which lands as an
untracked addition mixed into the operator's own working tree. `run-dir.sh`
is the same helper Step 3b's `RUN_DIR` uses for PR-keyed evidence;
`--run-id` is its addressing mode for a run that has no PR to key on. The
shared ledger helper itself is deliberately a ledger, not an orchestrator:

```bash
# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
bulk_dir=$("$agentkit/review-remote-pr/scripts/run-dir.sh" --run-id "$RUN_ID" --repo-root "$repository_root") || exit 1
ledger="$bulk_dir/apply-ledger.json"
plan="$bulk_dir/apply-plan.json"
apply_ledger="$agentkit/.shared/scripts/apply-ledger.sh"
"$apply_ledger" init --ledger "$ledger" --plan "$plan"
```

`record`'s `--number` is always the mutation's subject issue/PR number, not
the ID of whatever the mutation created underneath it: the newly created
number for a created issue/PR, or the existing issue/PR number a comment,
close, reopen, or board-move mutation acted on. `--url` must embed that same
number -- either the plain `.../issues/N` or `.../pull/N` form (created
issue/PR, and reused as-is for a close, reopen, or board-move on an existing
one), or, for a created comment, that same form with the `#issuecomment-<id>`
fragment GitHub's response actually returns.

Before every mutation, consume only the IDs from `pending --ids`; never retry
an ID present in `applied`. Keep chunks bounded (the default recipe is 20
objects), and persist after every success:

```bash
report_batch_failure() {
    local reason=$1 evidence
    printf 'bulk batch stopped: %s\n' "$reason" >&2
    if evidence=$("$apply_ledger" status --ledger "$ledger" --json); then
        printf 'ledger evidence (applied/remaining): %s\n' "$evidence" >&2
    else
        printf 'ledger evidence unavailable: %s\n' "$ledger" >&2
    fi
    exit 1
}

while :; do
    # Budget FIRST, before any mutation: checking after the chunk lets an
    # already-exhausted pool through for one whole chunk. An artifact that
    # exists but cannot be read or parsed fails closed -- treating it as
    # "absent, carry on" is how an exhausted budget reads as unlimited.
    if [[ -e .resources.graphql ]]; then
        if [[ ! -r .resources.graphql ]]; then
            report_batch_failure 'budget artifact exists but is unreadable'
        fi
        sed -n '1,120p' .resources.graphql
        if grep -Eq 'remaining[^0-9]*0|exhausted[^a-z]*true' .resources.graphql; then
            report_batch_failure 'GraphQL budget exhausted before this chunk'
        fi
    fi
    # Status-checked, NOT a process substitution: `mapfile < <(cmd)` discards
    # cmd's exit status, so a failed pending lookup yields an empty array and
    # the emptiness test below reads it as "batch complete" -- retiring the run
    # with unapplied IDs and no ledger report.
    if ! pending_ids=$("$apply_ledger" pending --ledger "$ledger" --ids); then
        report_batch_failure 'pending lookup failed'
    fi
    mapfile -t chunk <<<"$(printf '%s\n' "$pending_ids" | head -n 20)"
    [[ ${chunk[0]:-} ]] || break
    for planning_id in "${chunk[@]}"; do
        # perform exactly one REST mutation for this ID and parse its number/URL
        if ! mutation_json=$(perform_rest_mutation "$planning_id"); then
            report_batch_failure "mutation failed for $planning_id"
        fi
        if ! created_number=$(jq -er '.number' <<<"$mutation_json"); then
            report_batch_failure "mutation response omitted number for $planning_id"
        fi
        if ! created_url=$(jq -er '.html_url' <<<"$mutation_json"); then
            report_batch_failure "mutation response omitted URL for $planning_id"
        fi
        if ! "$apply_ledger" record --ledger "$ledger" --id "$planning_id" \
            --number "$created_number" --url "$created_url"; then
            report_batch_failure "ledger record failed for $planning_id"
        fi
    done
    # The next iteration's budget check is the inspection point between chunks.
done
```

Between chunks, explicitly inspect the current `.resources.graphql` budget
artifact (when present) and stop before starting a chunk that has no remaining
GraphQL budget. On exhaustion, retain the ledger and report its machine-readable
`applied`/`remaining` split; do not retry an empty pending pool or claim that
unrecorded mutations succeeded. A rerun starts from the same ledger and thus
creates zero duplicates. The ledger's `idMap` is the follow-on input for a
dependent batch.

REST routing is equally strict: issue/PR bodies, labels, state, comments,
reviews, sub-issues, dependencies, and cross-references use
`gh api repos/<owner>/<repo>/...`; do not use `gh issue`/`gh pr` porcelain
`--json` for those fields. The only GraphQL-only surfaces are Projects v2
queries/mutations and PR review-thread resolution. Name the surface and reason
at the call site when using GraphQL; a general-purpose GraphQL escape hatch is
not an allowlist.

`gh api` infers its HTTP method from the flags it's given: any `-f`/`-F`
parameter promotes the request to POST unless `-X GET` is passed explicitly,
so a filtered read that omits it silently becomes a write against a
repository this run does not own. Pass `-X GET` on every REST read that
carries `-f`/`-F`:

```bash
gh api -X GET "repos/$REPO/issues" -f labels=bug -f state=open
```

## Prior-art adjudication (only for merged-ref, in-flight, and attempted)

The digest names the pull request. Read it, then classify:

| Verdict | Signal | Action |
|---|---|---|
| **Fully addressed** | merged PR implements the whole ask | Drop from set; propose closing the issue with a comment linking the PR (user confirms the close) |
| **Partially addressed** | merged PR covers part of the scope | Keep, rescoped to the remainder; brainstorm/agent prompt MUST link the prior PR and state what's already done |
| **In flight** | an OPEN PR references the issue | Flag and ask — it's already being worked; don't double-dispatch |
| **Attempted & abandoned** | closed-unmerged PR references it | Read that PR's review threads before proceeding — they usually say why it died |
| **ADR conflict** | an `adr=` candidate rejected or decided this differently | HOLD for human call |
| **Clean** | none of the above | Proceed |

For an `adr=` candidate, scan its title and Status line (accepted / superseded /
rejected) against the issue:

- Issue proposes what an ADR **rejected or decided differently** → HOLD — human call
  needed (close the issue, or supersede the ADR first). Never dispatch an agent to
  implement against a standing ADR.
- Issue **already satisfied** by an accepted ADR's design → verify in code; if
  shipped, treat as *fully addressed*.
- Issue **overlaps** an ADR's scope → keep; the ADR becomes required context — cite
  its file path in the brainstorm and the agent prompt.

Only Clean, rescoped Partially-addressed, and ADR-cited issues continue.

## Work-shape verdict

Step 3's body read for conflict analysis is also the cheapest place to catch a mismatch
between what an issue asks for and what this skill knows how to run: the standard
worktree → branch → commit → draft-PR machinery. An issue whose body forbids branches,
worktrees, commits, or pull requests -- or otherwise states a research/analysis-only ask
-- is a different shape of work, and discovering that after Step 5 has already created a
worktree is the expensive way to find out (see #444).

Classify every surviving candidate exactly once, from the same body text Step 3 already
reads for file hints -- never a second fetch performed for this check alone:

```bash
# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
"$agentkit/.shared/scripts/triage-issues.sh" --classify-shape "$body_file"
```

`$body_file` holds the issue body bytes already in hand for this candidate's conflict
analysis, written to a file for the call. The mode is a pure text classifier: no `gh`
call, no network, exit 0 either way.

```
work-shape=no-code signal=explicitly prohibited branches, worktrees, commits, ...
work-shape=implementation signal=-
```

| Verdict | Signal | Disposition |
|---|---|---|
| `implementation` | no forbidding language found | Proceed through the standard worktree → branch → PR path |
| `no-code` | body explicitly forbids branches, worktrees, commits, or pull requests | **HOLD** — record the matched signal as the reason, drop from the dispatch set before Step 5, never create a worktree |

The `no-code` disposition is HOLD, not an alternate dispatch path: this skill defines
exactly one end-to-end shape (worktree → branch → commit → draft PR), and improvising a
read-only/no-PR variant per run is the failure this axis exists to stop. A future skill
revision may define a second shape end-to-end, including where its output goes; until
then HOLD is the only sanctioned disposition for `no-code`, the same posture as an ADR
conflict above.

Record the verdict on the dispatch-plan entry (`workShape`, and `holdReason` when
`no-code`) so a later step or a resumed session reads it back instead of re-classifying
-- see the `workShape`/`holdReason` fields in the
[dispatch-plan schema](#conflict-analysis-and-dispatch-plan-write-sets). A `no-code`
candidate counts toward the Selection funnel's `no-code-hold` exclusion category,
printed and named exactly like any other exclusion -- never silently dropped.

The classifier is deliberately crude, the same posture as the ADR token-matching above:
a miss is silence (verdict `implementation`), never proof the issue is safe to
implement, and a hit is a signal to read and confirm, not a final verdict on its own.
Genuine ambiguity is a Step 3 conflict-analysis judgment call like any other.

## Tracker classification

An `active` candidate is classified `tracker` when triage proves that it has at least one
sub-issue or carries an `epic` or `tracker` label, or the canonical Step 3 body read finds a
task-list line referencing another selected issue. This is a parent record, not a workstream:
hold it silently and allow its selected children to proceed. Record the structural reason so the
hold is auditable.

With `--fast-mode`, every other `active` candidate is dropped with a one-line `active` reason;
there is no hold/skip question. Tracker holds are counted separately from the refill queue. The
queue contains the first-N pickup-order overflow implementation candidates and is refilled as
slots free. Under `--auto-serialize`, a chain-depth overflow enters this same queue rather than
becoming an exclusion; the successor is refilled only after its immediate predecessor's commit
is pushed. A fast-mode disclosure therefore includes `queued=` and `tracker=` even when either is
zero.

## Conflict analysis and dispatch-plan write sets

Step 3 produces a root-owned `dispatch-plan` artifact before any worker is
dispatched. It is the audit record for the selected set, not a worker-owned
guess. Every selected issue gets exactly one entry with a non-empty
`predictedWriteSet` of repository-relative paths or globs taken from this
conflict analysis. The plan uses this schema:

```json
{
  "schemaVersion": 1,
  "entries": [
    {
      "issue": 167,
      "predictedWriteSet": ["agentkit/skills/parallel-issues/**", "tests/test-*.sh"],
      "workerEffort": "xhigh",
      "effortReason": "novel cache-ownership rewrite; three prior attempts failed",
      "uncoveredVerification": [4, 6]
    },
    {
      "issue": 172,
      "predictedWriteSet": ["docs/research/**"],
      "workShape": "no-code",
      "holdReason": "issue body: 'do not open a pull request for this analysis'"
    }
  ],
  "conflictMap": {
    "pairs": [{"issues": [164, 167], "overlap": ["agentkit/skills/parallel-issues/**"]}],
    "revisions": []
  }
}
```

The dispatch-time artifact stays at schema version 1 while PR numbers and
pushed heads do not exist. Immediately after atomically persisting it, run
`"$agentkit/parallel-issues/scripts/write-merge-plan.sh" --dispatch-plan "$dispatch_plan" --validate-only`;
the dispatch must not begin unless the helper prints `schemaVersion=1 valid`.
This catches a missing or malformed schema at the write boundary instead of in
the downstream queue consumer.

`workShape` and `holdReason` are optional and travel together: omitted entirely, an
entry defaults to `implementation`; present, `workShape` must be `implementation` (with
no `holdReason`) or `no-code` (with a non-empty `holdReason`) -- see
[Work-shape verdict](#work-shape-verdict). The write-time gate rejects a `no-code` entry
with no reason and a stray reason on an `implementation` entry, so a misclassification
is a validation failure, never a silent pass-through. A `no-code` entry never reaches
Step 5; it is dropped from the dispatch set before any worktree is created. Because a
HOLD never gets a worktree, branch, PR, or head, the ready-flip upgrade to schema 2
(below) requires the merge plan to cover only the **implementation-shaped** entries --
those with `workShape` absent or `implementation` -- and rejects a merge plan that
includes a `no-code` issue's number or omits any implementation issue. A `no-code`
entry stays in `entries` at schema 2 for audit and Selection-funnel accounting; it is
simply never expected in `independent`/`chains`.

`dispatch-plan` and `merge-plan` name the same owner-only file at its two
lifecycle stages: schema 1 before the ready flip and schema 2 afterward. The
temporary merge-plan input below is only the verified PR/head facts used to
perform that in-place upgrade.

At the ready-flip handoff, write the verified
facts to an owner-only **merge-plan input** file and pass both files through
`scripts/write-merge-plan.sh --dispatch-plan FILE --merge-plan FILE`. This
input carries only the ready-flip facts -- `entries` and `conflictMap` stay
owned by the dispatch plan and are never repeated here. Its required shape is:

```json
{
  "generatedAt": "2026-08-17T20:00:00Z",
  "independent": [
    {"issue": 170, "pr": 303, "branch": "feat/standalone", "chainBaseSha": null,
     "headSha": "cccccccccccccccccccccccccccccccccccccccc"}
  ],
  "chains": [[
    {"issue": 164, "pr": 301, "branch": "feat/root", "chainBaseSha": null,
     "headSha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    {"issue": 167, "pr": 302, "branch": "feat/child",
     "chainBaseSha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
     "headSha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
  ]]
}
```

- `generatedAt` -- **required**, an ISO-8601 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`).
- `independent` -- **required** array of records (may be empty); each record's
  `chainBaseSha` must be `null`.
- `chains` -- **required** array of chains (may be empty); each chain is an
  array of at least 2 records, ordered base-to-tip, whose first record has a
  `null` `chainBaseSha` and whose every successor's `chainBaseSha` equals its
  immediate predecessor's `headSha`.
- Every record (in `independent` or inside a `chain`) carries exactly these
  keys: `issue` (positive integer), `pr` (positive integer), `branch` (a safe
  git ref name), `chainBaseSha` (`null` or a 40-hex-char commit SHA), `headSha`
  (a 40-hex-char commit SHA).
- Across the whole file, `pr`, `issue`, and `branch` values must each be
  unique, there must be at least one record total, and the set of `issue`
  values must match the dispatch plan's `entries[].issue` set exactly.

The helper validates that every selected issue appears exactly once, upgrades
the dispatch plan atomically, and preserves the existing entries and conflict
audit; on a rejected input it names the first field that failed validation
(for example `generatedAt` missing, or an out-of-order chain). The resulting
schema-2 dispatch-plan shape is:

```json
{
  "schemaVersion": 2,
  "generatedAt": "2026-08-17T20:00:00Z",
  "entries": [
    {"issue": 164, "predictedWriteSet": ["src/a/**"]},
    {"issue": 167, "predictedWriteSet": ["src/b/**"]}
  ],
  "conflictMap": {"pairs": [], "revisions": []},
  "independent": [],
  "chains": [[
    {"issue": 164, "pr": 301, "branch": "feat/root", "chainBaseSha": null,
     "headSha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    {"issue": 167, "pr": 302, "branch": "feat/child",
     "chainBaseSha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
     "headSha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
  ]]
}
```

`independent` uses the same record shape, with null `chainBaseSha`. Each
`chains` array is ordered base-to-tip; each successor pins its immediate
predecessor's recorded head. `pr-to-green` verifies every recorded PR and head
but performs no discovery graph walk while the artifact is current. An absent
artifact or recorded-head drift activates forge derivation; malformed records,
duplicates, or an unsafe live base fail closed.

`uncoveredVerification` records the verification steps this issue's spec
enumerates that no declared command covers. `compose-worker-prompt.sh` reports
them when it composes the issue-lead prompt -- before the worker is spawned --
as `spec-verification= issue=N steps=K covered=C uncovered=U uncovered-steps=…`,
where the values are 1-based step indices counted in order of appearance inside
the composed `## Spec` block. A non-zero `uncovered` belongs on the entry, so the
gap is a disclosed dispatch fact rather than something the worker discovers
mid-implementation and reconciles alone; omit the key when the composer reports
`uncovered=0`. It is a disclosure, never a gate: the composer's matching is
textual and deliberately approximate (the same posture as `ci-gap.sh` for CI
gates), so an uncovered step is a prompt to declare the missing command or to
accept the gap in writing, not a reason to hold the dispatch.

`workerEffort` is the optional per-issue effort override — **effort follows the issue, not
the run**. Omitted, the issue dispatches at the `AGENT_WORKER_EFFORT` default; present, it
must carry an `effortReason`, and the value is what the prompt composer receives for that
issue. Raise effort for genuinely novel or repeatedly-failed work; never blanket-raise the
run. An `xhigh` override applies to the resolved **Luna** worker only: when dispatch falls
back to Terra, cap that issue's effort at `high` — Terra `xhigh` is reserved for the blind
adversarial-review fallback (see `.shared/spawn-contract.md`), and a copied plan must not
smuggle a worker into that reservation. The completion table's `worker=<model> <effort>` column is the evidence of what
actually ran. Root design review and adversarial review keep their own effort settings
regardless of any entry here.

Write-set intersection checks always add shared root files by default, even
when an issue body does not mention them: build configuration, lockfiles, and
generated contracts (including the repository's equivalent names and globs).
The resulting paths belong in each affected `predictedWriteSet`; they are not
optional cleanup. Record the conflict pairs and their overlap globs in
`conflictMap.pairs` before selection is finalized.

The same declared list (`AGENT_GENERATED_PATHS` in `.agent/config.env`) also
tells `gh-pr-state.sh` which post-merge trunk-automation commits (a
results-recording workflow, for example) must not stale a queued PR's base --
a base advance confined entirely to those paths reports `stale=no`, so
`merge-gate.sh` does not block `pr-to-green`'s merge gate on it. Declare
generated/results paths there once and both the write-set check above and
the staleness exemption pick it up; see `agentkit/skills/onboard-repo/SKILL.md`'s
`AGENT_GENERATED_PATHS` reference entry.

After selection, never silently revise a conflict edge, predecessor, or
successor. Append a `conflictMap.revisions` object with a non-empty `reason`
for every post-selection change, including a successor swap. A revision that
authorizes a `writeSetDisposition` must also carry `issues` naming the affected
issue numbers and `paths` covering that disposition's paths: a bare list of
revisions proves only that *some* revision exists, so without that binding a
revision recorded for another issue would authorize this one's operand. If a handback
names an operand outside its pinned prediction, the entry must carry
`writeSetDisposition` with a `kind` of exactly `chain-conversion`, `merge-down`,
or `prediction-expansion`, a non-empty `reason`, and `paths` covering every
out-of-prediction operand. The handback validator rejects an uncovered
operand; a changed prediction is never implicit.

Late-discovered overlap names inherited #137 chain conversion + merge-down as
the sanctioned response. Record the affected paths and reason in the plan,
then validate the handback against that revised artifact. Do not swap a
successor or widen a write set in prose after dispatch.

## Board adjudication

Status is already a digest column, so this costs nothing extra. Two issues sharing a
Project (v2) board likely share a milestone or sequencing decision the maintainer made
deliberately — parallelizing across them risks duplicate work, conflicting designs, or
merging out of order.

- Two or more candidates on the **same** board → STOP. Ask explicitly: "These
  share Project X. Proceed in parallel, or sequence them?"
- Candidates on **different** boards → safe to parallelize (still run Step 3).
- Candidates on **no** board → safe; proceed.
- A candidate in a column like "Blocked" → flag and ask before including.

**With `--fast-mode`, do not stop for board adjudication.** Nobody is watching, so
the STOP-and-ask above becomes a decision rule: same-board candidates proceed in
parallel when the Step 3 conflict analysis clears them, and any colliding pair is
resolved by that step's own drop rule. This is not silent — print the shared-board
finding (which Project, which issues) in the disclosure where an attended run would
have asked. A candidate in a "Blocked"-style column is dropped with a printed
reason, not asked about. Without `--fast-mode`, ask as above.

**Pickup order (auto mode).** Take from **Ready** first, top of column first. **A thin Ready
column is an invitation, not a blocker**: when eligible Ready issues are fewer than the slot
cap, run [Step 2b's procedure](#step-2b-choose-the-set-yourself) to promote
unblocked Backlog issues and fill the cap — `--fast-mode` proceeds and discloses the promotion;
an attended run surfaces the promoted candidates and asks instead of refusing to start on a thin
set. Issues on no board are fair game; rank them after Ready and promoted-Backlog items.
`active`/`done` are already excluded by triage. Present the proposed set in board order, one line
per issue, with the prior-art verdicts.

## Optional: fuzzy prior art

Some pull requests fix an issue without ever referencing it, so the digest
cannot see them. That search is the lowest-yield call in the set, so it is
opt-in per issue rather than automatic:

```bash
# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
"$agentkit/.shared/scripts/triage-issues.sh" --issues 57 --fuzzy 57
```

## Step 2b: Choose the set yourself

Invoked with issue numbers and no thematic Backlog instruction, use them; this step also runs
for `/parallel-issues --yolo --fast-mode` with none, for an attended automatic invocation whose
eligible Ready set is thinner than the slot cap, and for a numbered invocation that names a
thematic promotion instruction (e.g. "move issues out of backlog associated with logging and the
revit add-in") — that last case runs the procedure filtered to the theme and adds the matches
beside the given numbers; a thematic instruction is explicit authorization to include them, never
a reason to drop them silently. The board decides, and one script answers the mechanical half so
an issue body cannot argue its way into a dispatch.

```bash
set -euo pipefail

# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }

# Ready first. Add --include-backlog to groom unblocked Backlog work in as well.
"$agentkit/.shared/scripts/pick-issues.sh" --include-backlog
```

```text
pick= project=10 owner=example-org scanned=18 of=18 candidates=4 selectable=2 calls=2
  #10  Ready  a title
  SKIP #11  Ready  another title  [blocked by #99]
  #12  Backlog  a groomable title
```

`scanned=` and `of=` are two different populations on purpose: `scanned=` is how many cards
the read actually fetched, `of=` is the board's declared total. When they diverge the script
refuses to select at all -- a `TRUNCATED:` block and a nonzero exit, no candidate/SKIP lines --
because a partial read cannot judge the whole board. Re-run with the suggested `--limit` rather
than trusting a subset.

**Only `selectable` lines are eligible.** A `SKIP` line is a decision the script already
made; do not re-litigate it, and never dispatch one because the blocker "looks stale".
GitHub issue dependencies live on the issue, not on the board card, so a board read alone
would have reported `#11` as ready to start.

Then apply, in order:

1. **Ready before Backlog, promoted to fill a thin cap — for `--fast-mode` or an attended
   automatic invocation with no issue numbers.** For a numbered invocation carrying a thematic
   promotion instruction, skip this Ready sweep entirely: the candidate set is only the given
   numbers plus Backlog issues matching the named theme (title/label token overlap), never an
   unrelated Ready issue picked up along the way. Otherwise, exhaust vetted Ready work first; a
   thin Ready column (fewer eligible issues than the slot cap) is normal, not a reason to stop.
   Rank Backlog candidates by native blocked-by edges (an issue blocking or blocked by an
   already-selected issue ranks higher) and shared-area interrelation (touches the same
   files/modules/labels as an already-selected issue), then take top-ranked candidates until the
   cap is filled or Backlog is exhausted.
2. **Run Step 3's conflict analysis over the eligible set**, and drop the later issue from
   every colliding pair. This is the part no script can do — it is a judgement about which
   files each issue will touch.
3. **Cap the current wave at the Limits section's slot count.** More eligible issues than slots is
   the normal case. In `--fast-mode`, dispatch the first candidates by pickup order and queue the
   remainder for refill as slots free; attended mode reports the overflow and asks before dispatch.
4. **Move all chosen issues to `In progress` in one batch** with `move-github-project-item.sh`,
   including the Backlog ones — a promoted issue skips `Ready` because it is being started now,
   and leaving it in Backlog while a worker builds it makes the board lie. The helper accepts
   `--issue-numbers 57,54` (or repeatable `--issue-number` flags), shares the live board lookups,
   and emits one terminal `moved #N -> In progress` or `no-op:` line per issue. Once that line
   appears, that issue/status/phase is complete; never re-invoke the helper merely to verify or
   interleave a second move.

After conflict analysis and the slot cap have fixed the dispatch set, print exactly one
single-line reconciliation in this shape:

```text
Selection funnel: requested=<requested-count> eligible=<eligible-count> dispatched=<dispatch-count> queued=<queue-count>[#<issue>,...] tracker=<tracker-count> exclusions=<reason>:<count>[#<issue>,...]|none
```

For automatic selection with no supplied count, `requested` is the effective Limits-section slot cap.
For a numbered invocation, it is the number of supplied candidates. `eligible` is the number that survived existing triage and
mechanical eligibility before conflict/serialization and the slot cap, so it may exceed
`requested`. `dispatched` is the number actually launched in this wave and must not exceed
`requested`; `queued` is the number retained for refill after the wave cap or
chain-depth cap, followed by its issue IDs in pickup order as `queued=N[#...]` (use `queued=0`
when empty); `tracker` is the number of active parent/epic records held without a prompt. Group all
other candidates not dispatched under stable categorical reasons such as
`blocked-by`, `tier`, `already-implemented`, `conflict-serialized`, or `slot-cap`; use the
specific existing verdict instead of a catch-all when one applies. Each considered candidate
appears exactly once: in the dispatched set, queue, tracker holds, or exactly one exclusion group.
When more than one exclusion could describe it, use the earliest terminal decision made by the existing
selection procedure, so the groups are mutually exclusive and their counts match their issue
lists. This is reporting only; never change eligibility to make the arithmetic look fuller.
A [work-shape verdict](#work-shape-verdict) of `no-code` reports under `no-code-hold`.

Examples cover all queue shapes:

```text
Selection funnel: requested=3 eligible=3 dispatched=3 queued=0 tracker=0 exclusions=none
Selection funnel: requested=3 eligible=2 dispatched=1 queued=0 tracker=0 exclusions=blocked-by:1[#11],conflict-serialized:1[#12]
Selection funnel: requested=11 eligible=11 dispatched=10 queued=1 tracker=1 exclusions=none
Selection funnel: requested=6 eligible=6 dispatched=5 queued=1[#6] tracker=0 exclusions=none
Selection funnel: requested=3 eligible=0 dispatched=0 queued=0 tracker=0 exclusions=tier:1[#20],already-implemented:1[#21],no-code-hold:1[#22]
Selection funnel: requested=12 eligible=11 dispatched=10 queued=1 tracker=1 exclusions=none
```

For compatibility with pre-queue attended logs, these legacy examples remain recognizable:
`Selection funnel: requested=3 eligible=3 dispatched=3 exclusions=none`,
`Selection funnel: requested=3 eligible=2 dispatched=1 exclusions=blocked-by:1[#11],conflict-serialized:1[#12]`,
and `Selection funnel: requested=3 eligible=0 dispatched=0 exclusions=tier:1[#20],already-implemented:1[#21]`.

The first line says the full requested count was dispatched. The second makes a thin dispatch
legible without widening it. The remaining lines cover depth queueing, empty selection, and
eligible overflow.

Announce the chosen set, every promoted-from-Backlog issue with its ranking reason, the
dropped-for-conflict set, and the skipped-as-blocked set before dispatching. `--fast-mode`
removes the approval gate, not the disclosure — it proceeds straight to dispatch on that
disclosure. An attended run (with or without given issue numbers) surfaces the same disclosure
and asks instead of refusing to start on a thin Ready set or silently leaving thematic Backlog
matches out of a numbered set.

If nothing is eligible, say so and stop. An empty selection is an answer; it is never a
reason to widen the query, ignore a blocker, or reach for `Done`.
