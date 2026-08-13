# Triage adjudication and set selection

## Contents
- [Bulk mutation discipline: ledger, chunks, and resource budget](#bulk-mutation-discipline-ledger-chunks-and-resource-budget) — the resumable-ledger recipe for any batch of 2+ forge writes
- [Prior-art adjudication (only for merged-ref, in-flight, and attempted)](#prior-art-adjudication-only-for-merged-ref-in-flight-and-attempted) — reading the referenced PR and applying the ADR rules
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

**Pickup order (auto mode).** Take from **Ready** first, top of column first; **Backlog**
is not auto-pulled — surface it and ask. Issues on no board are fair game; rank them after
Ready items. `active`/`done` are already excluded by triage. Present the proposed set in
board order, one line per issue, with the prior-art verdicts.

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

Invoked with issue numbers, use them; this step is for `/parallel-issues --yolo --fast-mode`
with none. The board decides, and one script answers the mechanical half so an issue body
cannot argue its way into a dispatch.

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

1. **Ready before Backlog.** Exhaust vetted work before promoting unvetted work. Take
   Backlog only when Ready is empty or too small for the slot count.
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

Announce the chosen set, the dropped-for-conflict set, and the skipped-as-blocked set
before dispatching. `--fast-mode` removes the approval gate, not the disclosure.

If nothing is eligible, say so and stop. An empty selection is an answer; it is never a
reason to widen the query, ignore a blocker, or reach for `Done`.
