# Verification isolation and findings

Read this when a declared verification command may use Docker Compose or when a worker receives
an `agent-run.sh` failure. The runner exports a deterministic per-worktree
`COMPOSE_PROJECT_NAME`, so isolated worktrees do not share a Compose project.

The runner reports repository Compose files, `.env` values, and command argv that hardcode a
project name. Treat that warning as an isolation finding, especially when a literal
`-p`/`--project-name` takes precedence over the export. When isolation is defeated, serialize full-suite verification:
let one unchanged full-suite command finish before starting another,
and record the serialization reason with the verification evidence.

Compose dependency-start collisions are reported as `environment-retry-eligible` findings,
distinct from code regressions. Retry only the unchanged declared command after the conflicting
dependency has drained or been isolated; do not rewrite the command or silently call the result
a code failure.
