# Verification cache and suite cadence

Read this when deciding how often to re-run verification during red/green iteration; `SKILL.md` keeps
the pinned rule sentences. (The command-approval fence was removed 2026-08-19: `agent-run.sh --cmd NAME`
runs a declared command directly, with no approval or trust record.)

## Verification cache and suite cadence

Reuse requires `AGENT_VERIFY_<NAME>_MODE=local` and a nonempty
`AGENT_VERIFY_<NAME>_TOOLCHAIN` list of executable names, including interpreters and transitive
tools. Eligible names are `test`, `lint`, `typecheck`, `coverage`, `verify`, `check`, and component
names ending in `-test`, `-lint`, `-typecheck`, or `-check`. Undeclared/external commands,
delegated runners, baseline comparisons, and state-producing commands always execute.

`local` asserts read-only deterministic behavior independent of credentials, ambient environment,
network, time, and concurrent services. `AGENT_VERIFY_<NAME>_INPUTS` is a comma-separated list of
repository paths (default `.`): tracked and non-ignored untracked bytes are included; explicitly
listed files also include ignored dependency/config freshness receipts. Ignored directory contents
need individual receipts. Declare every relevant input; otherwise leave reuse disabled. Do not
include secrets in declarations or freshness receipts. Symlinks escaping the repository and
unavailable toolchain executables cause a named miss. Resolved command/config, cwd, HEAD, file
content, and toolchain executable paths/bytes all participate; HEAD alone is insufficient.

Records survive under `.agent/verification-records/<fingerprint>`. `verification reuse disabled`
names why reuse is ineligible; a pre-run `verification miss` names unavailable evidence. Both say
fresh execution follows. Only `verification current` and `verification reused` avoid execution.
Running or unknown records return their handle with status 75; inspect it, then use `--force` for
appropriate recovery. `--force` never starts a duplicate while the lease is held. Compose
collisions and permitted transient retries remain retryable. Legacy cache and log formats remain.
Cache-ineligible checks retain evidence in `.agent/run-records/` without granting
reuse. Acceptance collects an active run or spends one run-state recovery per check and candidate head.

During red/green, run focused suites. Commit the completed candidate, then run the required
unfocused full suite on that clean committed HEAD before push. The worker returns its SHA and
evidence; root validation and resume consume unchanged proof without scheduling another run.
Changed code, relevant inputs, or invalid evidence require verification of the new committed state.
After push, GitHub CI is authoritative for that SHA. This guard does not suppress
file reads, git queries, or search, and does not broaden dispatch or provider-review retry budgets.

## Worker baseline exclusions

Workers may opt into a baseline comparison for a failed check by supplying the chain-base ref,
failing test path, and stable test id to `agent-run.sh`. The helper runs the same command from an
isolated base checkout and appends to `.agent/baseline-exclusion.md` only when the command
identity and failure evidence match, deduplicating the test-id/base pair. Ordinary checks retain
their normalized failure signature comparison. A formatter can opt into path-set comparison by
declaring `AGENT_CMD_<NAME>_KIND=format` alongside `AGENT_CMD_<NAME>`; its `[warn] path` records
are normalized, sorted, and compared without volatile order, colour, or timing text. Every
reported path must be unchanged in the worktree and outside the branch diff, and the exclusion
records the complete failing path set. `BASELINE-EXCLUDED` means publication may continue; it is
not green evidence and must not unblock ready or merge. A later ordinary green verification
clears stale exclusions; the file is rendered as unchecked `Testing` boxes carrying each
resolved base SHA, failing path set, and evidence-log path.

During the root's final sweep, coalesce exclusions by test id and base SHA and propose one Backlog
candidate per distinct trunk failure. Candidates are observations only: never promote them to
Ready or otherwise mutate board status automatically.
