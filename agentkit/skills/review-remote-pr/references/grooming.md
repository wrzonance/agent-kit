# After the Loop: Groom the Backlog → propose Ready candidates

Finishing this PR drains the Ready / In-progress queue. Before handing back, fan out across the Project **Backlog** and propose which issues are vetted enough to promote to **Ready**, so the next pickup (`parallel-issues`, autonomous pull) has a clean queue. This is the *producer* side of the queue those *consume*.

**Propose, never auto-promote.** Backlog → Ready is a vetting decision (`github-projects.md`: Backlog = captured but *not vetted*; Ready = *cleared* for pickup). Surface candidates with rationale; only run the board helper with `--status 'Ready'` after the user confirms.

**No-op silently** (never fail the PR work over a board move) when there is no GitHub remote, the repo is on no Project board, the board has no Backlog/Ready column, or `gh` lacks `project` scope (`gh auth refresh -s project`).

## Pull the Backlog

List the Backlog column of the board this repo's issues live on:

```bash
# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
# board-list.sh deliberately reports every item type (draft items, PRs, issues
# alike) rather than filtering -- see its own comment. A PR/draft row renders
# indistinguishably from an issue ("#N  title"), so the vetting worklist comes
# from --json, not the table.
#
# Queried ONCE and captured, for two reasons: the previous shape called the same
# column twice for nothing, and piping straight into jq replaces board-list.sh's
# exit status with jq's -- so a failed query produced an empty list that read as
# "no Issue-typed rows" and silently skipped grooming instead of reporting it.
# Exit 3 is the documented "environment cannot support the query": no-op.
backlog_rc=0
backlog_json=$("$agentkit/.shared/scripts/board-list.sh" --status Backlog --json) || backlog_rc=$?
case "$backlog_rc" in
    0) printf '%s\n' "$backlog_json" | jq -r '.[] | select(.type == "Issue") | .number' ;;
    3) printf 'board query unsupported here (no gh, or no board declared); skipping Backlog grooming\n' >&2 ;;
    *) printf 'board-list.sh failed (exit %s); Backlog grooming not attempted\n' "$backlog_rc" >&2; exit 1 ;;
esac
```

It reads the project number and owner from `.agent/board.json`, so there is no separate
`gh project list` discovery call. Exit `0` is the table; exit `3` means the environment cannot
support the query (no `gh`, no board declared) — no-op silently per the rule above; exit `1` is a
failed call.

If Ready already holds enough queued work (≈3+ items) — `"$agentkit/.shared/scripts/board-list.sh"
--status Ready` — say so and stop; a full queue does not need topping up.

## Vet each issue against the Ready bar (fan out)

Fan out only over the Issue numbers from the `--json` list above — draft items and PRs on the
Backlog column are out of scope for this vetting pass.

Read each Backlog issue's body and judge it against the bar below. Where your runtime supports parallel agents, fan out one **read-only** assessor per issue (reads the body, greps the code); otherwise assess sequentially.

| Ready-bar check | Promote when… |
|---|---|
| **Specified** | concrete acceptance criteria / scope / file pointers — not a vague wish |
| **Unblocked** | no open dependency, no "Blocked-by", no prerequisite PR still open |
| **Right-sized** | one demonstrable change, ≤ ~500 LOC (chunking rule) — not an epic or tracking shell |
| **Independent** | does not overlap files with an In-progress / In-review issue |
| **Still real** | not stale, not a duplicate, not already shipped by a merged PR |

**Leave in Backlog (and say why)** anything that needs a human call before it is pickup-ready: research / decision issues, tracking bundles, and epics that must be **sliced** into child issues first.

## Propose (then stop)

Print the proposal — move nothing yet:

```
Backlog → Ready candidates (after PR #N):
  PROMOTE
    #62  Logging cleanup        ✅ specified · isolated (src/logger.ts) · ~80 LOC
    #71  Rate-limit guest API   ✅ clear AC · unblocked · ~200 LOC
  HOLD (needs a human call first)
    #58  "Make setbuilder fast"  ⚠️ no acceptance criteria — scope it first
    #506 split god-components    ⚠️ epic — slice into per-file child issues first
```

On confirmation, promote the approved set and stop; the next pickup takes them from Ready. Use the
board helper bundled with `parallel-issues` — it walks every board the issue is on, prints one line
per board, and no-ops cleanly (still exiting `0`) when there is no board, no `Status` field, or no
matching option:

```bash
# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
board_helper="$agentkit/parallel-issues/scripts/move-github-project-item.sh"

for issue_number in 62 71; do   # only the numbers the user approved
  "$board_helper" --issue-number "$issue_number" --status 'Ready' --repository "$REPO"
done
```

A leading `moved ` is the evidence the promotion happened; an already-target line such as
`no-op: issue #123 already "Ready"` is the terminal redundant no-op evidence. Both exit
`0`, so never treat the exit status alone as proof.

## Pitfalls

| Problem | Fix |
|---|---|
| Auto-promoting Backlog → Ready | Don't. Backlog is unvetted; promotion is the user's vetting call. Propose with rationale, move only after confirmation. |
| `gh project item-list` shows no `.status` | The board's single-select status field may be named differently. Inspect `jq '.items[0]'` and match the column by intent (Backlog/Ready); no-op if none matches. |
| Grooming blocks the PR handoff | It's best-effort. If the board/scope/`gh project` access isn't there, no-op silently and still report the PR as merge-ready. |
