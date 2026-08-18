# Triage adjudication and set selection

## Contents
- [Bulk mutation discipline: ledger, chunks, and resource budget](#bulk-mutation-discipline-ledger-chunks-and-resource-budget) — the resumable-ledger recipe for any batch of 2+ forge writes
- [Prior-art adjudication (only for merged-ref, in-flight, and attempted)](#prior-art-adjudication-only-for-merged-ref-in-flight-and-attempted) — reading the referenced PR and applying the ADR rules
- [Conflict analysis and dispatch-plan write sets](#conflict-analysis-and-dispatch-plan-write-sets) — pinning predicted operands and recording revisions
- [Board adjudication](#board-adjudication) — same-board STOP rationale, the `--fast-mode` decision rule, and pickup order
- [Optional: fuzzy prior art](#optional-fuzzy-prior-art) — the opt-in low-yield search
- [Step 2b: Choose the set yourself — `--fast-mode` only](#step-2b-choose-the-set-yourself----fast-mode-only) — the mechanical selection procedure `--fast-mode` uses in place of the approval gate

This is the detail behind SKILL.md's Step 2 triage digest: read the section you were pointed at
for the verdict(s) the digest actually flagged, or the `--fast-mode` set-selection procedure when
that flag is in play. A `clean` verdict needs none of this file.

## Bulk mutation discipline: ledger, chunks, and resource budget

Any batch that creates or edits more than one forge object carries a resumable
apply ledger. The planning ID is the stable key; a successful mutation is
followed immediately by one `record` call containing the returned number and
URL. The shared helper is deliberately a ledger, not an orchestrator:

```bash
# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
ledger=.agent/apply-ledger.json
plan=.agent/apply-plan.json
apply_ledger="$agentkit/.shared/scripts/apply-ledger.sh"
"$apply_ledger" init --ledger "$ledger" --plan "$plan"
```

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
      "effortReason": "novel cache-ownership rewrite; three prior attempts failed"
    }
  ],
  "conflictMap": {
    "pairs": [{"issues": [164, 167], "overlap": ["agentkit/skills/parallel-issues/**"]}],
    "revisions": []
  }
}
```

The dispatch-time artifact stays at schema version 1 while PR numbers and
pushed heads do not exist. At the ready-flip handoff, write those verified
facts to an owner-only merge-plan input and pass both files through
`scripts/write-merge-plan.sh`. The helper validates that every selected issue
appears exactly once, upgrades the dispatch plan atomically, and preserves the
existing entries and conflict audit. The resulting shape is:

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
cap, run [Step 2b's procedure](#step-2b-choose-the-set-yourself----fast-mode-only) to promote
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

## Step 2b: Choose the set yourself — `--fast-mode` only

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
pick= project=10 owner=example-org candidates=4 of=18 selectable=2 calls=2
  #10  Ready  a title
  SKIP #11  Ready  another title  [blocked by #99]
  #12  Backlog  a groomable title
```

**Only `selectable` lines are eligible.** A `SKIP` line is a decision the script already
made; do not re-litigate it, and never dispatch one because the blocker "looks stale".
GitHub issue dependencies live on the issue, not on the board card, so a board read alone
would have reported `#11` as ready to start.

Then apply, in order:

1. **Ready before Backlog, promoted to fill a thin cap.** Exhaust vetted Ready work first; a
   thin Ready column (fewer eligible issues than the slot cap) is normal, not a reason to stop.
   Rank Backlog candidates by native blocked-by edges (an issue blocking or blocked by an
   already-selected issue ranks higher) and shared-area interrelation (touches the same
   files/modules/labels as an already-selected issue), then take top-ranked candidates until the
   cap is filled or Backlog is exhausted. For a numbered invocation with a thematic promotion
   instruction, restrict this ranking to Backlog issues matching the named theme (title/label
   token overlap).
2. **Run Step 3's conflict analysis over the eligible set**, and drop the later issue from
   every colliding pair. This is the part no script can do — it is a judgement about which
   files each issue will touch.
3. **Cap the set at the Limits section's slot count.** More eligible issues than slots is
   the normal case, not a reason to raise the cap.
4. **Move all chosen issues to `In progress` in one batch** with `move-github-project-item.sh`,
   including the Backlog ones — a promoted issue skips `Ready` because it is being started now,
   and leaving it in Backlog while a worker builds it makes the board lie. The helper accepts
   `--issue-numbers 57,54` (or repeatable `--issue-number` flags), shares the live board lookups,
   and emits one terminal `moved #N -> In progress` or `no-op:` line per issue. Once that line
   appears, that issue/status/phase is complete; never re-invoke the helper merely to verify or
   interleave a second move.

Announce the chosen set, every promoted-from-Backlog issue with its ranking reason, the
dropped-for-conflict set, and the skipped-as-blocked set before dispatching. `--fast-mode`
removes the approval gate, not the disclosure — it proceeds straight to dispatch on that
disclosure. An attended run (with or without given issue numbers) surfaces the same disclosure
and asks instead of refusing to start on a thin Ready set or silently leaving thematic Backlog
matches out of a numbered set.

If nothing is eligible, say so and stop. An empty selection is an answer; it is never a
reason to widen the query, ignore a blocker, or reach for `Done`.
