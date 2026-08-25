# Design documents

The specs here record *why* the pieces are shaped the way they are — the
constraints discovered along the way, and the alternatives rejected.

| Document | Covers |
|---|---|
| `2026-08-07-agent-repo-config-design.md` | The `.agent/` contract and single-call issue triage |
| `2026-08-07-agent-kit-plugin-and-hooks-design.md` | Plugin packaging, the four hooks, and named commands |
| `2026-08-08-non-blocking-guards-design.md` | Guards that teach once and never stop autonomous work |
| `manual-test-plan.md` | Prompt-by-prompt checks for behaviour only a live agent exercises |
| `onboarding-lessons.md` | Incidents behind `onboard-repo/SKILL.md`'s rules — why each one exists |
| `fleet-identity.md` | The GitHub App installation, credential lanes, Project mutations, and authorship boundary |

The matching implementation plans are deliberately not kept here: they were
session-scoped working documents, full of absolute scratch paths that mean
nothing outside the machine that produced them.
