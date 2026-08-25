# External adversarial review — 2026-08-09

Reviewer: Codex CLI `gpt-5.6-sol`, reasoning effort `xhigh`, read-only sandbox.
Subject: the whole tree at `beea739`, not a diff. 527,714 tokens.

Commissioned before making this repository public. Kept verbatim below the
line; findings are tracked as they are fixed, and the wording is not edited to
match what we ended up doing.

> **2026-08-19 update:** findings 3 and 6 below concern `stop.sh`, which was
> later removed entirely rather than hardened (see the
> [kill-turn-gate plan](superpowers/plans/2026-08-19-kill-turn-gate.md)).

---

# Adversarial engineering review

## Scope and evidence

I reviewed all shipped hooks, helpers, skills, manifests, README/design documentation, test harnesses, and fixtures: 83 tracked files, approximately 16,000 lines. I traced every path that executes repository commands or mutates Git/GitHub state.

Verification was run from a disposable archive; the checkout remained clean:

- ShellCheck: 23 shipped scripts passed.
- `bash -n`: 23 scripts passed.
- Canonical suite: `ALL GREEN`, 11 suites, 600 assertions.

Those results do not cover several security and concurrency paths below.

## Findings

### 1. Repository-controlled system-context injection

- **Severity:** CRITICAL
- **Location:** `agentkit/hooks/session-start.sh:77`, `agentkit/hooks/session-start.sh:96`, `agentkit/hooks/session-start.sh:101`, `agentkit/hooks/session-start.sh:125`, `agentkit/hooks/subagent-start.sh:22`
- **Defect:** A recent repository-controlled `.agent/env-contract.txt` is injected verbatim into model context without provenance, schema, tracking-status, or content validation.
- **Failure scenario:** A hostile repository force-tracks `.agent/env-contract.txt` containing agent instructions and no `harness=` line; `harness_matches` treats the missing identity as a match, and merely opening the repository injects the attacker’s text into SessionStart and every spawned worker as authoritative “established” context.
- **Confidence:** VERIFIED

### 2. Repository-local state writes follow attacker-controlled symlinks

- **Severity:** HIGH
- **Location:** `agentkit/skills/.shared/scripts/agent-preflight.sh:647`, `agentkit/skills/.shared/scripts/agent-preflight.sh:655`, `agentkit/skills/.shared/scripts/agent-run.sh:543`
- **Defect:** Volatile `.agent/` state is written with ordinary redirection, without `O_NOFOLLOW`, ownership checks, or atomic replacement, before its ignore status is guaranteed.
- **Failure scenario:** A repository tracks `.agent/env-contract.txt` as a symlink to `../.git/config`; a stale-cache or compaction preflight truncates `.git/config`, while a recent-cache path reads that config into model context. In a fresh unonboarded repository, the same generated file is stageable by `git add -A` because bootstrap has not written ignore rules yet.
- **Confidence:** VERIFIED

### 3. `AGENT_CMD_*` validation is not a command-execution trust boundary

- **Severity:** HIGH
- **Location:** `agentkit/skills/.shared/scripts/repo-config.sh:182`, `agentkit/skills/.shared/scripts/repo-config.sh:191`, `agentkit/skills/.shared/scripts/agent-run.sh:440`, `agentkit/skills/.shared/scripts/agent-run.sh:636`, `agentkit/hooks/stop.sh:78`
- **Defect:** The lexical validator rejects shell syntax but accepts arbitrary interpreters and build tools, then executes repository-controlled argv without establishing that the declaration or executable came from a trusted revision.
- **Failure scenario:** A contributor changes `AGENT_CMD_VERIFY` to `bash tools/payload.sh` and adds the payload; after checkout, Stop directs the maintainer’s agent to run verification, and `agent-run.sh` executes it with the maintainer’s credentials and available network. Opening alone does not execute it, but the documented normal workflow does.
- **Confidence:** VERIFIED

### 4. GitHub Project operations are not cryptographically bound to the requested repository or issue

- **Severity:** HIGH
- **Location:** `agentkit/skills/parallel-issues/scripts/move-github-project-item.sh:120`, `agentkit/skills/parallel-issues/scripts/move-github-project-item.sh:227`, `agentkit/skills/parallel-issues/scripts/move-github-project-item.sh:243`, `agentkit/skills/.shared/scripts/board-list.sh:120`
- **Defect:** The fast mutation path trusts committed/generated Project node IDs and a force-trackable item cache, while the board reader discards repository identity before matching issue numbers.
- **Failure scenario:** A malicious branch supplies `board.json` and `board-items.json` IDs for an unrelated Project item the user may edit; the next lifecycle move sends those IDs directly to `gh project item-edit`. Separately, on an organization-wide board containing two repositories’ issue `#42`, `board-list --issue 42` reports whichever record appears first.
- **Confidence:** VERIFIED

### 5. Destructive-command guards have ordinary, non-obfuscated evasions

- **Severity:** HIGH
- **Location:** `agentkit/hooks/lib/guard-lib.sh:214`, `agentkit/hooks/lib/guard-lib.sh:225`, `agentkit/hooks/lib/guard-lib.sh:229`, `agentkit/hooks/lib/guard-lib.sh:273`, `README.md:133`
- **Defect:** Pattern matching misses valid destructive spellings even though the README recommends replacing read-only `.git` protection with these patterns.
- **Failure scenario:** `git push origin +main`, `git clean --force -d`, `git branch --delete --force main`, and `rm --recursive --force /` all returned “not destructive” in direct evaluation, while their short-option equivalents were denied.
- **Confidence:** VERIFIED

### 6. The Stop verification attestation is path-unsafe and only blocks once

- **Severity:** HIGH
- **Location:** `agentkit/hooks/stop.sh:16`, `agentkit/hooks/stop.sh:58`, `agentkit/hooks/stop.sh:101`, `README.md:164`
- **Defect:** Stop parses non-NUL Git output, skips deleted or misparsed paths, relies only on mtimes, and unconditionally allows the Stop invocation following its first block.
- **Failure scenario:** Run verification successfully, then delete a tracked source file; the deleted path fails `-e`, so the existing stamp is accepted and the turn finishes without covering the deletion. A missing stamp blocks once, but the immediately re-entered Stop finishes regardless of whether verification ran.
- **Confidence:** VERIFIED

### 7. Both core skills prescribe a nonexistent current Codex dispatch API

- **Severity:** HIGH
- **Location:** `agentkit/skills/parallel-issues/SKILL.md:419`, `agentkit/skills/parallel-issues/SKILL.md:449`, `agentkit/skills/review-remote-pr/SKILL.md:182`, `agentkit/skills/review-remote-pr/SKILL.md:194`
- **Defect:** The procedures require `multi_agent_v1__spawn_agent`, `fork_context`, and no `task_name`, whereas the active Codex interface is `collaboration.spawn_agent` with required `task_name` and `fork_turns`.
- **Failure scenario:** Following the published “parameter names are exact” template either calls an unavailable tool or is rejected for missing `task_name`; the advertised parallel implementation and mandatory fix-worker paths cannot dispatch.
- **Confidence:** VERIFIED against the installed current interface

### 8. Predictable review artifacts permit symlink overwrite and private-code disclosure

- **Severity:** HIGH
- **Location:** `agentkit/skills/review-remote-pr/SKILL.md:735`, `agentkit/skills/review-remote-pr/SKILL.md:777`, `agentkit/skills/review-remote-pr/SKILL.md:786`, `agentkit/skills/review-remote-pr/scripts/claude-adversarial-review.sh:546`, `agentkit/skills/review-remote-pr/scripts/codex-adversarial-review.sh:402`
- **Defect:** PR-number-only filenames under shared `/tmp` are created by shell redirection and transcript truncation without exclusive creation, no-follow handling, or a private per-run directory.
- **Failure scenario:** Another local user precreates `/tmp/claude_pr_42.diff` as a symlink to a user-writable target; `git diff >"$diff_path"` overwrites that target. With a typical `022` umask, the diff, transcript, and verdict can also be readable by other users.
- **Confidence:** VERIFIED

### 9. Bootstrap discovery, validation, and installation use different repository roots

- **Severity:** HIGH
- **Location:** `agentkit/skills/.shared/scripts/bootstrap-repo.sh:67`, `agentkit/skills/.shared/scripts/bootstrap-repo.sh:102`, `agentkit/skills/.shared/scripts/bootstrap-repo.sh:281`, `agentkit/skills/.shared/scripts/bootstrap-repo.sh:301`
- **Defect:** `--repo-root` controls the write target, `gh repo view` still resolves from process cwd, and validation runs against a staging directory containing none of the target repository’s executables.
- **Failure scenario:** Running from repository A with `--repo-root /path/to/B` writes A’s slug, base, and Project metadata into B. On `--force`, a previously valid `AGENT_CMD_VERIFY=tools/verify` is carried into staging and rejected because `staging/tools/verify` does not exist.
- **Confidence:** VERIFIED

### 10. The declared base branch is ignored by branch-safety paths

- **Severity:** HIGH
- **Location:** `agentkit/skills/.shared/scripts/worktree-commit.sh:181`, `agentkit/skills/parallel-issues/SKILL.md:345`, `agentkit/skills/parallel-issues/SKILL.md:516`, `agentkit/skills/parallel-issues/SKILL.md:773`
- **Defect:** Branch protection and conflict instructions hardcode `main|master|trunk` instead of consistently using `AGENT_BASE_BRANCH`.
- **Failure scenario:** In a repository whose trunk is `develop`, `worktree-commit.sh` permits a direct commit on `develop`, while the parallel workflow tells workers to merge nonexistent or irrelevant `origin/main`.
- **Confidence:** VERIFIED

### 11. Human-review classification can be spoofed with a public marker

- **Severity:** HIGH
- **Location:** `agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh:29`, `agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh:246`
- **Defect:** Any comment containing `<!-- review-remote-pr:agent-` is classified as agent-authored regardless of its GitHub author.
- **Failure scenario:** A human reviewer includes or quotes that marker in an actionable comment; `human_touched` becomes false, the item disappears from the user-confirmation queue, and a bot-originated thread can be automatically handled or resolved.
- **Confidence:** VERIFIED

### 12. Repository ownership is treated as consent to disclose private code externally

- **Severity:** HIGH
- **Location:** `agentkit/skills/review-remote-pr/SKILL.md:665`, `agentkit/skills/review-remote-pr/SKILL.md:771`, `agentkit/skills/review-remote-pr/SKILL.md:794`
- **Defect:** The skill treats invoking it on an owned repository as standing authorization to transmit the complete PR diff to a different model provider.
- **Failure scenario:** An employee is a maintainer or owner of a private company repository but is not authorized to send its code to Anthropic; invoking the review skill transmits the diff without disclosing the destination or requesting consent.
- **Confidence:** VERIFIED

### 13. Public issue bodies become instructions for tool-capable workers

- **Severity:** HIGH
- **Location:** `agentkit/skills/parallel-issues/SKILL.md:308`, `agentkit/skills/parallel-issues/SKILL.md:312`, `agentkit/skills/parallel-issues/SKILL.md:602`
- **Defect:** Autonomous mode explicitly treats an untrusted GitHub issue body as the specification and pastes it directly into a worker prompt without a trust boundary or injection warning.
- **Failure scenario:** A public issue says that its “acceptance criteria” require reading credentials, running an attacker-chosen diagnostic, or posting data to GitHub; a tool-capable worker may obey it as task instructions.
- **Confidence:** SUSPECTED — the injection path is verified, but model compliance was not exercised

### 14. Plugin version resolution is lexicographic, not semantic

- **Severity:** MEDIUM
- **Location:** `agentkit/hooks/lib/guard-lib.sh:14`, `README.md:74`, repeated throughout both workflow skills
- **Defect:** `find … | sort | tail -1` selects the lexicographically greatest cached version rather than the newest semantic version.
- **Failure scenario:** With `0.9.0` and `0.10.0` installed, the resolver selects `0.9.0`; this was reproduced directly, and the current test only compares `0.1.0` with `0.2.0`.
- **Confidence:** VERIFIED

### 15. Cached contracts are not invalidated when repository state changes

- **Severity:** MEDIUM
- **Location:** `agentkit/hooks/session-start.sh:99`, `agentkit/hooks/session-start.sh:106`
- **Defect:** Cache validity considers only age and harness identity, not branch, HEAD, worktree identity, configuration digest, or repository path.
- **Failure scenario:** A user starts on `feat/x`, switches the same worktree to `main`, and opens a new session within 30 minutes; the hook injects the stale `branch=feat/x` contract while instructing the agent not to re-probe it.
- **Confidence:** VERIFIED

### 16. `worktree-commit.sh` has no transaction-level concurrency lock

- **Severity:** MEDIUM
- **Location:** `agentkit/skills/.shared/scripts/worktree-commit.sh:225`, `agentkit/skills/.shared/scripts/worktree-commit.sh:235`, `agentkit/skills/.shared/scripts/worktree-commit.sh:254`
- **Defect:** Git’s per-command index locks do not protect the multi-command stage/check/commit transaction.
- **Failure scenario:** Two invocations in one worktree stage different file lists concurrently; invocation A can commit B’s staged files, producing a commit with the wrong scope, message, and agent attribution.
- **Confidence:** VERIFIED

### 17. Adversarial reviews have incomplete time and spend bounds

- **Severity:** MEDIUM
- **Location:** `agentkit/skills/review-remote-pr/SKILL.md:695`, `agentkit/skills/review-remote-pr/SKILL.md:718`, `agentkit/skills/review-remote-pr/SKILL.md:862`, `agentkit/skills/review-remote-pr/scripts/codex-adversarial-review.sh:300`
- **Defect:** The workflow mandates a paid probe and review but has no total-duration timeout, while the Codex fallback has no spend ceiling and its foreground-sleep poller can delay completion by the full polling interval.
- **Failure scenario:** A reviewer API stalls without exiting; the helper continues indefinitely, and the skill explicitly tells the orchestrator not to terminate on silence. A completed Codex review can then wait up to the default 120 seconds for the poller’s `sleep`.
- **Confidence:** VERIFIED

### 18. Public skills hardcode one operator’s mutable environment and SaaS configuration

- **Severity:** MEDIUM
- **Location:** `agentkit/skills/review-remote-pr/SKILL.md:45`, `agentkit/skills/review-remote-pr/SKILL.md:57`, `agentkit/skills/review-remote-pr/SKILL.md:67`, `agentkit/skills/review-remote-pr/SKILL.md:304`
- **Defect:** One measured sandbox profile and one organization’s CodeRabbit settings are stated as universal facts in a dual-harness public procedure.
- **Failure scenario:** In the current session the actual contract says `sandbox active=no network=ok`, contradicting the skill’s “network is disabled” assertion; in another organization with automatic reviews enabled, pushes trigger reviews despite the skill repeatedly asserting that they cannot.
- **Confidence:** VERIFIED

### 19. The central token-efficiency claim excludes the cost of loading the procedures

- **Severity:** MEDIUM
- **Location:** `agentkit/skills/parallel-issues/SKILL.md:1`, `agentkit/skills/review-remote-pr/SKILL.md:1`
- **Defect:** The two central skills contain approximately 25,300 words/175 KB and duplicate the resolver block 24 times, so invoking them consumes substantial context before any repository result is read.
- **Failure scenario:** `/review-pr` loads a 106 KB, 15,239-word procedure to replace several compact shell calls; on a short PR, the fixed instruction cost can exceed the GitHub data it was designed to save and materially reduce the remaining context window.
- **Confidence:** VERIFIED

### 20. Valid repository layouts and one generated command cannot be represented by the contract

- **Severity:** MEDIUM
- **Location:** `agentkit/skills/.shared/scripts/repo-config.sh:115`, `agentkit/skills/.shared/scripts/detect-toolchains.sh:110`, `agentkit/skills/.shared/scripts/detect-toolchains.sh:456`
- **Defect:** Paths are newline-delimited and contract paths reject spaces, while the Markdown detector emits a quoted glob that `safe_argv` rejects.
- **Failure scenario:** A component at `packages/web app/package.json` produces an unusable `AGENT_RUNDIR_*`; a filename containing a newline splits into phantom records; and uncommenting the generated `markdownlint-cli2 "**/*.md"` declaration makes the resolver drop it as invalid.
- **Confidence:** VERIFIED

### 21. The canonical green gate omits behavioral coverage for high-trust scripts

- **Severity:** MEDIUM
- **Location:** `tests/run-tests.sh:180`, `README.md:208`
- **Defect:** There are no behavioral suites for `worktree-commit.sh`, `gh-pr-state.sh`, `gh-comment.sh`, either adversarial-review helper, or `ci-gap.sh`, despite the README claiming that green means “the tree is good.”
- **Failure scenario:** The symlink, poller-delay, human-marker, concurrency, and private-artifact defects above all pass the canonical suite; the README also reports eight suites/~350 assertions while the actual run contains 11 suites/600 assertions.
- **Confidence:** VERIFIED

### 22. Public installation documentation is not actionable

- **Severity:** LOW
- **Location:** `README.md:25`
- **Defect:** The clone instruction contains the literal placeholder `<this repo>` and provides no public source URL or release verification guidance.
- **Failure scenario:** A stranger following the documented installation command cannot clone the plugin and has no canonical repository or release artifact to verify.
- **Confidence:** VERIFIED

## Portability

Within the explicitly declared Debian 13/Bash 5.2 target, I found no additional portability blocker.

Native macOS is unsupported in practice: Bash 3.2 cannot run the associative-array/`mapfile` code, and the scripts require GNU behaviors including `readlink -f`, `stat -c`, `sha256sum`, `xargs -d`, and `timeout`. Because the README states Debian 13 as the target, this is a documented scope limitation rather than a defect. It must be stated as “Linux-only” if public users might otherwise interpret “Works with Codex CLI and Claude Code” as cross-platform.

## Licensing and attribution

Nothing found. The tree has an MIT license and both manifests identify it consistently.

## Design judgment

Teach-after-the-fact is defensible for optimization advice such as replacing chatty GitHub queries. It is not an adequate compensating control for granting writable `.git`, executing repository policy, or protecting credentials.

The three-valued `guard_claim` is sound for its stated purpose: inability to persist a claim fails open for denials and repeats advisories. The problem is the security significance assigned to the patterns around it, not the claim state machine.

The `.agent/` concept is serviceable for declarative facts, but it currently mixes three trust classes under one repository-controlled namespace:

- reviewed static policy;
- generated external object IDs;
- volatile machine/session state.

For public release, executable policy should be user-approved or pinned to a trusted base revision; generated IDs must be revalidated before mutation; volatile state belongs outside the checkout or in a securely created git-common/XDG state directory.

## Blockers for public release

1. Remove repository-controlled SessionStart context injection and secure every state-file write against symlinks, races, and accidental staging.
2. Establish an explicit trust/consent boundary before executing `AGENT_CMD_*` or repository scripts from an untrusted checkout.
3. Revalidate Project, field, option, and item IDs against the requested repository and issue before mutation.
4. Replace the obsolete multi-agent API instructions and test them against both supported harnesses.
5. Stop recommending writable `.git` as protected by regex guards, or replace those guards with a structured enforcement boundary.
6. Make external-provider code disclosure explicit and defend tool-capable worker prompts from issue-body injection.
7. Repair Stop verification, base-branch handling, bootstrap root scoping, and shared temporary-file handling.
8. Add adversarial behavioral tests for the currently untested high-trust scripts.

## What I did not review

- Live GitHub Project, PR, CodeRabbit, and Code Quality behavior: this checkout has no origin or linked board.
- A paid live Claude/Codex adversarial-review run: it would transmit code and consume paid service budget.
- Native macOS execution.
- Probabilistic model obedience to issue-body or diff prompt injection.
- Stress/fuzz testing of races; concurrency findings were traced from the code’s transaction boundaries.
- Claude Code installation and live hook delivery; the canonical integration test exercised the current local Codex installation.
