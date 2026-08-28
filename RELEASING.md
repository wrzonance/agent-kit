# Releasing

## Version consistency (enforced)

`agentkit/.claude-plugin/plugin.json`, `agentkit/.codex-plugin/plugin.json`,
`plugin/agentkit/.claude-plugin/plugin.json`, and `plugin/agentkit/.codex-plugin/plugin.json`
must all declare the same version; `opencode/package.json` and `plugin/opencode/package.json`
are checked too, whenever an `opencode/` tree is present. A published
GitHub Release's tag must match it too. `tests/check-release-version.sh` gates both; CI runs it
on every push, tag, and release (`.github/workflows/ci.yml`).

```bash
tests/build-plugin.sh
tests/check-release-version.sh                    # local: agreement only
tests/check-release-version.sh --tag "v$VERSION"   # what CI runs on a tag/release push
```

Bump the version in all four plugin manifests together, and in `opencode/package.json` and
`plugin/opencode/package.json` too, before tagging -- every manifest the gate above checks.
Nothing here requires the version to *increase* for a given change -- see below for what that
implies.

Use the fixed-scope bump helper from the repository root so linked worktrees cannot be touched:

```bash
agentkit/skills/.shared/scripts/bump-version.sh "$VERSION"
```

It updates exactly the three source manifests above and refuses to run from inside `.worktrees/`.
Before committing worker changes, `worktree-commit.sh` rejects staged tracked files outside the
declared issue operands unless each exception is named with `--allow-outside PATH`. Refreshing
onboarding also reports such worktree drift and prunes dangling Git worktree registrations.

## Step 0: does the installed tree match `main`? (#453)

Two trees can answer to the same version string: `main` with a fix, and an already-installed
plugin copy without it. The version-consistency gate above only checks that *one* tree agrees
with itself -- it says nothing about whether a downstream install still matches `main`.

Before trusting a session against an installed `agentkit` plugin, compare its **content
stamp**, not its version string -- when that stamp is a real hash; see below. The environment
contract's `skills-content=` line carries a sha256 hash of the actual shipped skill/script tree
the session is running -- independent of, and never appended to, the `skills= path=` record:

```text
skills= path=/home/you/.claude/plugins/cache/agent-kit/agentkit/0.6.8/skills
skills-content= sha256=<64-hex>
```

When no `sha256sum`/`shasum` is available, or the tree cannot be read, `agent-preflight.sh`
emits the literal `skills-content= sha256=unavailable` instead of a hash. Treat that as
**inconclusive**, never as a match or a mismatch -- there is nothing to compare, so Step 0
cannot rule out staleness either way in that case.

Read it directly, or via the helper:

```bash
"$agentkit/.shared/scripts/contract-read.sh" --repo-root "$repo" --get skills.content
```

Two trees with identical shipped content always hash identically, regardless of what version
string either one claims; two trees that differ never do. To check an installed copy against
`main`, compute the same stamp for a `main` checkout's own `agentkit/skills` tree and compare --
either run that checkout's own `agent-preflight.sh` (it always hashes the tree it lives in), or
call the hashing function directly:

```bash
source /path/to/main-checkout/agentkit/skills/.shared/scripts/lib/skills-content-hash.sh
skills_content_hash /path/to/main-checkout/agentkit/skills
```

A mismatch between two real hashes, under a matching version string, means the installed copy is
stale; reinstall it (`codex plugin add` / `/plugin install`, per the README) rather than trusting
the version string alone. If either side reads `unavailable`, that comparison proves nothing --
fix whatever is stopping the hash (usually a missing `sha256sum`/`shasum`) before relying on it.

This is deliberately **read-only**: nothing in a session fetches, updates, or mutates an
installed plugin tree on its own. The stamp only makes an existing mismatch visible; a stale
install is still fixed the normal way, by reinstalling.

**Chosen seam:** this is seam 1 from issue #453 (a content stamp that makes staleness visible).
Seam 2 (a release gate that refuses to let shipped content change land on an already-published
version string) is a separate, independent hardening step and is not part of this change.
