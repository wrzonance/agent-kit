# Verification isolation and findings

Read this when a declared verification command may use Docker Compose or when a worker receives
an `agent-run.sh` failure. The runner exports a deterministic per-worktree
`COMPOSE_PROJECT_NAME`, so isolated worktrees do not share a Compose project.

The runner reports repository Compose files, `.env` values, and command argv that hardcode a
project name. A repository `.env` value or a compose-file `name:` is reported and deliberately
overridden by the export -- that override is what isolates the worktree, and it is safe for an
ephemeral verification run. A literal `-p`/`--project-name` in the declaration outranks the export,
so isolation cannot be established at all; `agent-run.sh` exits 5 without running rather than
walking into the collision. That is the case that requires you to serialize full-suite verification:
let one unchanged full-suite command finish before starting another,
and record the serialization reason with the verification evidence. Re-run the serialized command
with `AGENT_COMPOSE_SERIALIZED=1` to assert that no concurrent full-suite run is in flight.

Compose dependency-start collisions are reported as `environment-retry-eligible` findings,
distinct from code regressions. Retry only the unchanged declared command after the conflicting
dependency has drained or been isolated; do not rewrite the command or silently call the result
a code failure.
