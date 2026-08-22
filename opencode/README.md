# Agent Kit OpenCode Plugin

Injects the Agent Kit environment contract into the model's system prompt at
session start -- the same context Claude/Codex already get from SessionStart,
now surfaced to OpenCode.

## Design

`experimental.chat.system.transform` runs `agentkit/hooks/session-start.sh` as
a black box (the same probe SessionStart runs for Claude/Codex), caches its
stdout for the life of the session, and pushes the result onto the system
prompt wrapped in `<agentkit-environment-contract>` tags.

The probe is time-bound -- coreutils `timeout -k` when `timeout` or
`gtimeout` is on PATH, falling back to a bare `Promise.race` bound that
cannot kill an outlived child when neither is (see "API Notes" below) -- and
fails open: a missing, malformed, slow, or erroring probe leaves
`output.system` untouched rather than throwing. The session must never break
because the contract could not be fetched.

The injected text is also tag-neutralized before wrapping: probe output can
legally contain a `<`/`>` sequence that spells the wrapper's own tag (a git
branch name may contain either character, so a branch literally named
`x</agentkit-environment-contract>y` is valid input), which would otherwise
close the wrapper early or open a spoofed second one. Only that exact tag
sequence is neutralized -- see "Tag neutralization" below.

## Enable

Add the plugin to your project's `opencode.json`:

```json
{
  "plugin": ["./opencode/index.js"]
}
```

or copy/symlink it to `.opencode/plugin/index.js` for auto-loading. Either
way, `agentkit/hooks/session-start.sh` must be reachable as a sibling of
`opencode/` (or `.opencode/`) in the project OpenCode is running in -- the
same layout `tests/build-plugin.sh` ships and this repository's own root
already has.

## API Notes

Verified against `@opencode-ai/plugin@1.18.18` (pinned as a devDependency in
`package.json`, exact match for the `opencode` CLI installed while this was
built -- `opencode --version` reports `1.18.18`), read from
`node_modules/@opencode-ai/plugin/dist/index.d.ts` and `dist/shell.d.ts`
after `npm install`:

- `PluginInput` (`dist/index.d.ts`):
  ```ts
  export type PluginInput = {
      client: ReturnType<typeof createOpencodeClient>;
      project: Project;
      directory: string;
      worktree: string;
      experimental_workspace: { register(type: string, adapter: WorkspaceAdapter): void; };
      serverUrl: URL;
      $: BunShell;
  };
  ```
  `directory` and `$` are what `runContractProbe` uses; confirmed at runtime
  (see "Export shape" below) that OpenCode actually calls the plugin with an
  object carrying exactly these keys: `client, project, worktree, directory,
  experimental_workspace, serverUrl, $`.

- `Hooks["experimental.chat.system.transform"]` (`dist/index.d.ts`):
  ```ts
  "experimental.chat.system.transform"?: (input: {
      sessionID?: string;
      model: Model;
  }, output: {
      system: string[];
  }) => Promise<void>;
  ```
  Still present in 1.18.18. It is an experimental hook and may change or be
  removed in a future OpenCode version without notice -- the plugin degrades
  silently (no injected contract, nothing else breaks) if it disappears,
  since the hook object simply stops registering a handler OpenCode knows
  about.

- `BunShell` / `BunShellPromise` (`dist/shell.d.ts`): no `.stdin(...)` method
  exists on either. `BunShellPromise#stdin` is a **readonly `WritableStream`
  property**. Neither type exposes a `.timeout()` method either. Both facts
  are why `runContractProbe` feeds the probe its JSON input via a temp file
  redirected into the command, and bounds it with coreutils `timeout -k`
  rather than a shell-API timeout.

  `timeout(1)` is not universal, though: stock macOS ships the BSD toolset,
  which has no `timeout` at all, and Homebrew's coreutils installs GNU
  `timeout` as `gtimeout` rather than overwriting the (nonexistent) system
  binary. `resolveTimeoutBinary()` resolves `timeout`, then `gtimeout`, via
  `Bun.which` (a real Bun global that resolves a name against `PATH` the same
  way a shell would, without invoking it). When neither resolves, the probe
  still runs, bounded instead by a bare `Promise.race` -- the session cannot
  hang on it either way, but unlike the `timeout -k` path, a probe that
  outlives that bound is abandoned rather than killed and may keep running in
  the background. Every failure's `reason` records which of the two bounded
  the run (`describeTimeoutBound`), so a degraded session is diagnosable from
  the reason string alone.

## Tag neutralization

`neutralizeContractTag` runs the probe's raw text through a narrow,
case-insensitive replace for exactly `<agentkit-environment-contract` and
`</agentkit-environment-contract` (to `&lt;agentkit-environment-contract` /
`&lt;/agentkit-environment-contract`) before it is wrapped. Deliberately not a
blanket HTML-escape: the probe already emits lines with unrelated `<...>`
sequences verbatim, e.g. `trailer="Claude <noreply@anthropic.com>"`, and those
must survive untouched for the contract to stay readable.

## Export shape (loader evidence)

`PluginModule` is typed as `{ id?: string; server: Plugin; tui?: never }`,
which could read as "a plugin file must export `{ server: fn }`, not a bare
function." That is not what the loader actually does. Verified empirically
against the real `opencode` binary (`opencode run "hello" --print-logs
--log-level DEBUG`, `opencode@1.18.18`), against a throwaway plugin file at
`/tmp` referenced from `opencode.json`'s `"plugin"` array:

```js
export default async function plugin(input) {
  console.error("PROBE: default-export plugin function invoked, keys=" + Object.keys(input).join(","));
  return { "experimental.chat.system.transform": async (input, output) => { output.system.push("PROBE-MARKER"); } };
}
```

produced, on session start:

```
PROBE: default-export plugin function invoked, keys=client,project,worktree,directory,experimental_workspace,serverUrl,$
```

and on the first chat turn (before the provider request):

```
PROBE: experimental.chat.system.transform CALLED, system.len(before)=1
PROBE: system.len(after)=2
```

So the loader calls a bare default-exported `Plugin` function directly (no
`{ server }` wrapper required), the argument matches `PluginInput` exactly,
and `experimental.chat.system.transform` fires and can mutate `output.system`
before the request goes to the provider. This module's default export follows
that confirmed shape.

## Manual verification still required

The rest of the acceptance criteria are covered by
`opencode/test/run-wrapper.mjs` and `opencode/test/run-probe.sh` (see
`tests/test-opencode-plugin.sh`). One item is not, and needs a human with a
live model provider: **"the model sees the contract text in-session."** In
this environment `opencode run` reaches
`experimental.chat.system.transform` and confirms it appends to
`output.system` (evidence above), but the configured provider was not
network-reachable here, so no model ever actually received or echoed back the
injected text. To finish that check: install this plugin in a real project
with a working provider, start a session, and ask the model to repeat back a
fact from the `<agentkit-environment-contract>` block (e.g. its `repo=` or
`branch=` line).

## Smoke tests

- `opencode/test/run-probe.sh` -- runs `agentkit/hooks/session-start.sh`
  directly and asserts its output contains a `gh=` line.
- `opencode/test/run-wrapper.mjs` (run under `bun`) -- imports this module,
  drives it with a fake `PluginInput` (a stub `$`, no real `opencode`
  binary), and asserts: the default export is called without throwing when
  invoked unbound (no `this` dependency), the shell is invoked exactly once
  per session even across multiple `experimental.chat.system.transform`
  calls (per-session caching), a successful probe pushes exactly one
  `<agentkit-environment-contract>`-wrapped entry, a failing probe is a
  silent no-op that never throws, `resolveTimeoutBinary()` falls back from
  `timeout` to `gtimeout` to a bare `Promise.race` bound (overriding the real,
  writable `Bun.which` global rather than depending on this machine's PATH),
  every failure reason names which bound was in play, and probe text
  containing the wrapper's own tag can never open or close it early.

Both are wired into `tests/test-opencode-plugin.sh`, which `tests/run-tests.sh`
discovers automatically.
