# GitHub identity for the automation fleet

## Decision

Use a GitHub App installation for unattended Agent Kit orchestration. Do not
share a maintainer's personal token across workers, and do not create one
shared machine account for the fleet.

The App is the durable automation principal; each orchestrator receives a
short-lived installation token for the repositories it is allowed to operate
on. This gives the fleet its own rate pool and makes API authorship visible as
the App's bot identity. The installation is scoped to the organization and an
explicit repository allow-list, rather than all repositories.

### Installation plan and permissions

Create one App for the fleet, install it only on the organization/repositories
that Agent Kit operates on, and mint an installation token just before an
orchestrator session. Start with these least-privilege permissions:

| Permission | Access | Why |
| --- | --- | --- |
| Metadata | Read | Required repository and Project discovery metadata |
| Projects | Read and write | Project reads and the GraphQL-backed Status mutations |
| Issues | Read and write | Issue triage and workflow-created issue comments |
| Pull requests | Read and write | Draft PR creation and workflow-created PR/review-thread comments |
| Contents | Read and write | Branch publication when the fleet, rather than a human, pushes the worker branch |

Do not grant administration, organization-management, secrets, Actions, or
member-management permissions. If branch publication remains a human/CI
responsibility, reduce Contents to Read; the installation plan must match the
actual publisher instead of granting write access preemptively.

## Orchestrator authentication

The secret broker or launcher must place the current installation token in the
orchestrator process as `GH_TOKEN` (or `GITHUB_TOKEN` when `GH_TOKEN` is not
used). GitHub CLI commands inherit that process identity, including the
one-call helpers. The token is runtime state, not repository configuration:

- Never put the token, a token command, or a credential-shaped value in
  `.agent/config.env`, a committed file, a prompt, or a log.
- Do not run `gh auth login` inside an unattended orchestrator session. It can
  replace the intended fleet identity with a human credential.
- Keep the token lifetime bounded to the session and rotate/revoke the App
  installation if the launcher or broker is compromised.
- Before dispatching work, verify the identity without printing the token:

  ```bash
  [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || {
      printf '%s\n' 'fleet GitHub token is not present' >&2
      exit 1
  }
  gh api graphql -f query='{ viewer { login } }' --jq '.data.viewer.login'
  ```

The returned account must be the installed fleet App/bot identity. A
successful `gh` call under a maintainer login is not a valid fleet check; it
only proves that the human credential can reach GitHub.

## Board mutation boundary

GitHub Projects v2 is the GraphQL-only mutation surface in Agent Kit. The
following helpers are the supported path for Project operations:

- `agentkit/skills/parallel-issues/scripts/move-github-project-item.sh` for
  Status moves; its `gh project item-edit` calls are GraphQL-backed.
- `agentkit/skills/.shared/scripts/board-setup.sh` for the guarded Project
  setup/Status-schema mutation; its explicit `gh api graphql` call is also
  GraphQL-backed.

Run these helpers only from an orchestrator process carrying the fleet
installation token. Do not override `GH_TOKEN` with a personal token for a
board read or mutation, and do not hand-roll a Project GraphQL mutation. The
fleet installation must have `Projects: write` for mutations; a missing or
expired fleet token is an authentication failure to report, not a reason to
fall back to a human account.

The same fleet identity should be used for the other unattended `gh` work
(issue triage, draft PR creation, and workflow-authored comments). That keeps
the rate pool and API authorship consistent. GitHub CLI authentication and Git
commit authorship are separate controls: configure the Git author and required
agent trailer honestly for commits, while the App identity is the visible
author of API-created PRs and comments.

## Human-gated actions stay human

The fleet identity is not a substitute for human judgment. The following
actions remain outside the orchestrator lane and must be performed by a human
from a human-authenticated shell:

- flipping a PR from draft to ready;
- approving a PR; and
- merging a PR.

Before a human-gated action, leave the orchestrator environment and verify
that the shell is using the maintainer's intended account. Never perform one
of these actions while a fleet `GH_TOKEN` or `GITHUB_TOKEN` is exported. Agent
Kit's skills do not flip readiness, issue approvals, or merge PRs; a handback
must make those actions explicit for the human owner.

## Rollout checklist

1. Create the App and record its owner, App ID, and installation allow-list in
   the organization's secret-management documentation, not in this
   repository.
2. Grant only the permissions above, install it on the allowed repositories,
   and confirm that `Projects: write` is enabled for the target Project owner.
3. Teach the orchestrator launcher/broker to mint a short-lived installation
   token and export it as `GH_TOKEN` for the session.
4. Verify `gh api graphql -f query='{ viewer { login } }' --jq '.data.viewer.login'` reports
   the fleet identity, then run the normal Agent Kit preflight and named
   verification commands.
5. Verify a board Status move through the bundled helper and confirm the audit
   trail attributes it to the App, not a maintainer.
6. Keep ready-flips, approvals, and merges in a separately authenticated human
   workflow.
