# Design documents

The specs here record *why* the pieces are shaped the way they are — the
constraints discovered along the way, and the alternatives rejected.

| Document | Covers |
|---|---|
| `2026-08-07-agent-repo-config-design.md` | The `.agent/` contract and single-call issue triage |
| `2026-08-07-agent-kit-plugin-and-hooks-design.md` | Plugin packaging, the four hooks, and named commands |
| `2026-08-08-non-blocking-guards-design.md` | Guards that teach once and never stop autonomous work |
| `2026-08-09-external-review.md` | The pre-public external adversarial review and its findings |
| `security-posture.md` | Deliberate security decisions: autonomy flags, egress consent, what agent-kit does and does not guard |
| `manual-test-plan.md` | Prompt-by-prompt checks for behaviour only a live agent exercises |
| `onboarding-lessons.md` | Incidents behind `onboard-repo/SKILL.md`'s rules — why each one exists |
| `fleet-identity.md` | The GitHub App installation, credential lanes, Project mutations, and authorship boundary |

`superpowers/specs/` and `superpowers/plans/` hold the design docs and
implementation plans for later work (token-benchmark epic, size waves,
recipe-fold wave, and similar). These are kept in the repository even though
some carry absolute scratch paths from the machine that produced them,
because later waves in the same series read the earlier plan for context.
