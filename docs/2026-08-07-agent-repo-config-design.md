# Repo-carried agent configuration (`.agent/`) and single-call issue triage

**Date:** 2026-08-07
**Status:** Approved — ready for implementation planning
**Scope:** `~/.codex/skills/` (`parallel-issues`, `review-remote-pr`, `.shared`)
**Predecessor:** Task 1, shipped as `skill-bash-v4.tar.gz`

## Problem

The two skills re-derive the same static facts on every run, and re-derive some of
them once per issue. Measured against the current tree:

| Fact | Sites | Cost per run (4 candidate issues) |
|---|---|---|
| repo slug | ~8 `gh repo view` sites across both SKILL.md bodies | 8 calls |
| base branch | `git remote show origin` | 1 call (network) |
| project / field / option IDs | `gh project list` + `gh project field-list` | 2 calls **per status move** |
| project-item ID | `gh project item-list` | 1 call **per status move** |
| board membership + Status | `gh issue view --json projectItems` | 4 calls |
| cross-referenced PRs | `gh api …/timeline --paginate --slurp` | 4 calls, each potentially thousands of tokens |
| fuzzy prior art | `gh pr list --search` | 4 calls |
| ADR directory | 6-way `[[ -d ]]` probe | free, but re-reasoned every run |

The board path is the worst: the canonical lifecycle (`In progress → In review →
Done`) is 3 moves, and `move-github-project-item.sh` spends 4 `gh` calls per move.
That is **12 calls per issue, 9 of which re-resolve IDs that never change** — ~36
wasted round-trips for a 4-issue batch, each dragging JSON into the context window.

None of this is a correctness bug. It is token burn and latency, and it is charged
to the account with the least headroom.

## Non-goals

- Making the skills aware of any specific organization, repository, or board. The
  shipped tree stays org-agnostic; this is the contract established in Task 1 and
  it is not relaxed here.
- Automating judgment that requires reading a PR or an ADR.
- Replacing the human checkpoints at `parallel-issues` Steps 3c and 5.
- Caching machine-specific facts (CA bundle, cache roots, sandbox state). Those
  stay probed at runtime by `agent-preflight.sh` because they differ per developer,
  not per repository.

## Design

### Layering

Repo-specific facts live only in the target repository's own `.agent/` directory.
Nothing about any particular repo ships in the skill tarball.

```
~/.codex/skills/.shared/            <repo>/.agent/
  scripts/
    repo-config.sh    ──reads──▶      config.env    committed, hand-reviewable
    bootstrap-repo.sh ──writes─▶      board.json    committed, generated
    triage-issues.sh  ──writes─▶      cache/        gitignored, regenerable
                                      runner        pre-existing convention
  schema/
    config.env.example
```

Absence of `.agent/` is a supported state: every script falls back to the live
discovery it performs today, and the existing SKILL.md prose remains correct.

### `repo-config.sh` — the only reader

A resolver, not a config format. Responsibilities:

1. Locate `<git-toplevel>/.agent/config.env`.
2. Parse **line-wise** into a whitelist of known keys. It must never `source` the
   file. A committed file in a shared repository is reachable by anyone who can
   open a pull request; treating it as executable shell would make it an injection
   vector into every agent's environment.
3. Validate each value against the shape declared for its key. A value that fails
   validation is dropped with a warning on stderr; the run continues.
4. Export surviving keys as `AGENT_*`, then fall through to live discovery for
   anything absent.

Entry points:

- `eval "$(repo-config.sh --export)"` — for scripts.
- `repo-config.sh --get KEY` — for one-off use in skill code blocks.

Exit codes follow the tree's existing convention: `0` success (including "no config
found"), `2` bad usage. It never blocks a run.

### `config.env` schema

`KEY=value`, one per line, `#` comments permitted. Unknown keys are ignored with a
warning so that a newer repo config cannot break an older skill tree.

| Key | Validation | Replaces |
|---|---|---|
| `AGENT_REPO_SLUG` | `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` | `gh repo view` |
| `AGENT_BASE_BRANCH` | ref-safe chars; rejects `..`, leading `-`, whitespace | `git remote show origin` |
| `AGENT_PROJECT_OWNER` | `^[A-Za-z0-9._-]+$` | `gh project list` |
| `AGENT_PROJECT_NUMBER` | `^[0-9]{1,6}$` | `gh project list` |
| `AGENT_STATUS_VOCAB` | comma list; no newlines, quotes, or control chars | column-name guessing |
| `AGENT_ADR_DIR` | relative path; rejects `..`, leading `/`, symlink escape | 6-way directory probe |
| `AGENT_BRANCH_PREFIXES` | comma list of `[a-z]+` | branch-convention prose |
| `AGENT_WORKTREE_ROOT` | relative path; rejects `..`, leading `/` | Step 0a default |
| `AGENT_LABEL_TYPES` / `_AREAS` / `_PRIORITIES` | comma lists, label-safe chars | label-taxonomy guessing |
| `AGENT_REVIEW_PROVIDERS` | enum list: `coderabbit`, `github-code-quality`, `none` | provider-identity probing (advisory only — see below) |
| `AGENT_REPO_RUNNER` | must resolve **inside the repo tree** and be executable | already supported |

`AGENT_REPO_RUNNER` is the only key naming a command. This is not new exposure:
`agent-run.sh` already executes `<git-toplevel>/.agent/runner` today, so a
repository capable of shipping a runner could already reach this. The resolver adds
the containment check that the bare convention lacked.

`AGENT_REVIEW_PROVIDERS` is **advisory only**. It tells the agent which providers to
expect so it does not spend calls probing for a bot that was never installed. It
must not gate anything: `review-remote-pr`'s existing provider-identity logic still
reads the actual comment author from the Step 1 artifact, because a config file
cannot know that a provider was enabled, disabled, or renamed since it was written.
A provider that appears but is not listed is a warning, never a skip.

**Deliberately unsupported keys:** any token, credential, hostname, proxy URL, or
CA certificate path or body. A validation failure is not enough here — these keys
are rejected outright and their presence is reported as a warning, so that a
misguided commit is visible rather than silently honored.

### `board.json` schema

Generated by `bootstrap-repo.sh`, committed alongside `config.env`.

```json
{
  "schemaVersion": 1,
  "generatedAt": "<ISO-8601>",
  "owner": "<owner>",
  "project": { "number": 7, "id": "PVT_…", "title": "…" },
  "statusField": {
    "id": "PVTSSF_…",
    "name": "Status",
    "options": { "Backlog": "…", "Ready": "…", "In progress": "…", "In review": "…", "Done": "…" }
  },
  "fingerprint": "sha256:…"
}
```

`fingerprint` is a SHA-256 over the project ID, the Status field ID, and the sorted
option IDs. It exists so that a board change produces one actionable line instead
of a silently wrong column assignment.

The GitHub node IDs recorded here are opaque handles, not secrets, and they are
committed into the same repository whose board they describe. They carry no access
of their own.

### `cache/board-items.json` schema

Gitignored, regenerable, written by `triage-issues.sh`.

```json
{ "schemaVersion": 1, "project": "PVT_…", "items": { "57": "PVTI_…", "54": "PVTI_…" } }
```

Keyed by project node ID, so switching or recreating a board invalidates the whole
file rather than yielding stale entries.

These IDs are repo-correct **by construction**: they come from a
`repository(owner, name).issues` query, not from scanning a board that may span
several repositories. This is strictly stronger than the repository-filter fix
currently applied to the `item-list` scan, and it removes the class of bug that fix
was defending against.

### `triage-issues.sh` — one query

A single GraphQL request against `repository(owner, name)` returning, for every
candidate issue: number, title, labels, body, `projectItems { id, project, Status }`,
and `timelineItems` filtered to cross-reference events with their source pull
request's number, state, merge status, and title.

That one response satisfies four separate call sites: issue fetch, board
membership, cross-referenced prior art, and the project-item IDs the board cache
needs.

**Digest format** — one line per issue on stdout:

```
triage= repo=<owner/name> project=<n> issues=<n> calls=1 items-cached=<n>

#57  Ready        clean        adr=-                    pr=-
#54  Ready        merged-ref   adr=-                    pr=#212 merged 2026-07-30
#62  Backlog      in-flight    adr=-                    pr=#231 open
#48  In progress  active       adr=-                    pr=-
#41  Ready        attempted    adr=-                    pr=#198 closed-unmerged
#39  Ready        clean        adr=docs/adr/0012-*.md   pr=-
```

**Verdict vocabulary — strictly what the query proves:**

| Verdict | Evidence |
|---|---|
| `in-flight` | an OPEN pull request cross-references the issue |
| `merged-ref` | a MERGED pull request cross-references the issue |
| `attempted` | a CLOSED-unmerged pull request cross-references the issue |
| `active` | board Status is `In progress` or `In review` |
| `done` | board Status is `Done` (excluded from the proposed set) |
| `clean` | none of the above |
| `unknown` | the query returned no usable data for this issue |

An issue may match several rows at once. Exactly one verdict is emitted, resolved
by this precedence, highest first: `unknown`, `done`, `active`, `in-flight`,
`attempted`, `merged-ref`, `clean`. The ordering is deliberate — a state that
should stop a dispatch outranks a state that merely warrants reading, so the most
restrictive applicable verdict always wins. The `pr=` column names the pull request
that produced the winning verdict; when several qualify, the most recently updated
one is shown, followed by `(+N more)`.

The script must **not** emit "fully addressed" or "partially addressed", and must
not judge ADR conflicts. It can prove that a merged PR references an issue; it
cannot prove that PR covered the whole ask. It reports `merged-ref` and the agent
reads that single PR to decide.

Likewise the `adr=` column only *locates* candidates. Matching is deliberately
crude and defined precisely so it is reproducible: lowercase the issue title, drop
tokens shorter than four characters and a small stopword list, and score each file
under `AGENT_ADR_DIR` by how many surviving tokens appear in its filename or its
`# ` / `title:` line. Files scoring two or more are candidates; the top two by
score are printed, `-` if none. The agent reads them and applies the Step 4a rules.
A miss here is silence, never a blocked run — this column is a pointer, not a gate.

This boundary — mechanical evidence in the script, interpretation in the agent — is
what keeps the design from drifting into a policy engine.

The fuzzy `gh pr list --search KEYWORDS` sweep, which finds pull requests that never
referenced the issue, becomes **opt-in per issue** (`--fuzzy N`) rather than
automatic. It is the lowest-yield call in the set.

### `bootstrap-repo.sh` — user-run, once

Discovers every `config.env` and `board.json` value with `gh`, writes both files,
and prints what it found. Requirements:

- Idempotent; refuses to overwrite an existing file without `--force`.
- Writes only whitelisted keys. It never copies environment or token material into
  its output.
- `--dry-run` prints the files it would write without touching disk.
- Fails loudly and completely — a partial `board.json` is never written, because a
  half-populated option map would produce wrong-column moves.
- Prints the `.gitignore` line needed for `.agent/cache/`.

### `move-github-project-item.sh` — optimistic fast path

Add a fast path in front of existing behavior; do not remove the existing behavior.

1. Read `board.json` and `cache/board-items.json`. If the project ID, Status option
   ID, and item ID are all present, call `gh project item-edit` directly — **1 call
   instead of 4**.
2. On rejection, fall back to today's full discovery, rewrite both files, retry
   **once**, and print `board changed — commit the regenerated .agent/board.json`.
3. With no cache present, behave exactly as today.

A single retry, not a loop: a second rejection is a real error and must surface.

### Skill edits

**`parallel-issues/SKILL.md`**

- Steps 2, 3, and 4 collapse into one triage step invoking `triage-issues.sh`.
- The 3c and 4c decision tables **stay**, re-framed from procedure to adjudication
  reference, prefixed with "consult only for issues the digest flagged." They carry
  the context the agent needs to reason well; they should not drive a call per
  issue.
- Step 3d's Ready-first ordering becomes free — Status is already a digest column.
- Step 1's repo/branch detection becomes `eval "$(repo-config.sh --export)"`.

**`review-remote-pr/SKILL.md`**

- Step 0a honors `AGENT_WORKTREE_ROOT`, defaulting to today's `.worktrees/pr-N`.
- The repeated `gh repo view` sites read `AGENT_REPO_SLUG` when available.

Unchanged: `agent-run.sh`, `worktree-commit.sh`, `claude-adversarial-review.sh`,
`codex-adversarial-review.sh`, `gh-pr-state.sh`, `gh-comment.sh`. `agent-preflight.sh`
gains one `config=` line reporting whether a config was found and which keys it
supplied.

## Implementation sequencing

The work is one coherent design but more than one reviewable slice. It sequences
into three layers, each independently useful and each leaving the tree green:

1. **Resolver + schema** — `repo-config.sh`, `config.env.example`, the `config=`
   line in `agent-preflight.sh`. Nothing consumes it yet; the tree behaves
   identically. Provable with the `gh` stub and malformed-input fixtures.
2. **Board fast path** — `bootstrap-repo.sh`, `board.json` handling, and the
   optimistic path in `move-github-project-item.sh`. Delivers the 4-calls-to-1 win
   on its own, with layer 1 already verified underneath it.
3. **Triage** — `triage-issues.sh`, its fixtures, and the `parallel-issues` Step
   2/3/4 collapse plus the `review-remote-pr` Step 0a change. The largest slice and
   the one carrying the untested GraphQL assumption, so it lands last where a
   revision is cheapest.

Layers 1 and 2 are pure addition. Only layer 3 rewrites existing skill prose, which
is where regression risk concentrates and where the markdown-block lint matters
most.

## Failure behavior

| Condition | Behavior |
|---|---|
| No `.agent/` directory | Live discovery, existing prose — identical to today |
| Corrupt or partial `config.env` | Offending keys dropped with a warning; the rest used |
| Rejected key present (token, CA, proxy) | Rejected and reported as a warning |
| `gh` absent, unauthenticated, or network blocked | Exit **3**, matching the adversarial reviewers' environment-blocked convention |
| Board renamed, moved, or recreated | `item-edit` fails → rediscover → retry once → print the commit-the-regenerated-file notice |
| GraphQL partially resolves | Emit what resolved; mark the remainder `unknown`; never fabricate a verdict |
| `board.json` `schemaVersion` unrecognized | Ignore the file, fall back to discovery, warn |

Guard paths fail closed (a bad status name never reaches `item-edit`); context
paths fail open (a missing ADR directory is silence, not an error).

## Verification

The target repository cannot be reached from this machine, and no `gh` call may be
made against it. Verification is therefore local and fixture-based:

1. `shellcheck -S style` and `bash -n` on every script.
2. The markdown code-block extractor over both SKILL.md bodies.
3. **Fixture tests** for the classifier: recorded GraphQL response JSON in,
   asserted digest lines out, zero network. Fixtures cover each verdict, an issue
   on no board, an issue with several referencing PRs, and a partial response.
4. **`gh` stub on `PATH`** proving that (a) a fully populated config produces no
   live `gh` call on the fast path, and (b) malformed config values never reach
   `gh`.
5. Schema round-trip: `bootstrap-repo.sh` output against the stub parses cleanly in
   `repo-config.sh` and `move-github-project-item.sh`.
6. Neutrality grep: no organization, repository, board, or host name anywhere in
   the shipped tree.

What this does **not** verify is the GraphQL query against a real board. The
bootstrap is built to fail loudly, completely, and idempotently for that reason,
and its first run should be inspected with `--dry-run`.

## Open risk

The single largest untested assumption is the GraphQL query shape — specifically
whether `timelineItems` cross-reference filtering and `fieldValueByName("Status")`
behave as expected against a real Projects v2 board. If the query needs revision,
it is contained to `triage-issues.sh`; every consumer reads the digest, not the
raw response.
