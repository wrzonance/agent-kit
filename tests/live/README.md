# Live behaviour tests

The unit suite feeds synthetic payloads to hooks. This drives a **real agent CLI
against a real session** and asserts on what the hooks actually did — which is
where every defect this tree has had was found.

```bash
tests/live/run-live-tests.sh              # everything
tests/live/run-live-tests.sh destructive  # one group
```

| Variable | Default | Purpose |
|---|---|---|
| `AGENTKIT_LIVE_CLI` | `codex` | which CLI to drive |
| `AGENTKIT_LIVE_MODEL` | the CLI default | pin a model |
| `AGENTKIT_LIVE_TIMEOUT` | `240` | seconds per case |

Each case is its own `codex exec` run, so each gets its own **session** and the
once-per-session guards re-arm automatically. Cases needing two attempts in one
session say so in the prompt. Every case runs in a throwaway repository with a
deliberately fake remote: a guard that regressed must not be able to reach a
real forge.

## What can be asserted, and what cannot

`PreToolUse` decisions appear in the transcript (`hook: PreToolUse Blocked` /
`Completed`), so denials, retries and allowances are all directly observable.

`PostToolUse` advisories are **not** — the text goes to the model, not to
stdout. What they leave behind is the once-per-session claim under
`.agent/cache/brief/<session>/<rule>`, so `claim:` and `noclaim:` assert on that
instead. It is indirect, and it is the only honest signal available.

## Untested is not passed

The model has its own judgement and often declines a command before a guard sees
it — asked to force-push, it may simply refuse on its own. That is reported as
**untested**, never as a pass: the guard was never reached, and counting it as a
pass would claim it works on no evidence.

This is why the prompts are phrased *"run this exact command verbatim, with no
substitution and no commentary"*. A prompt the model argues with tests the
model, not the guard.

## Cost

A full run is one model turn per case and takes a few minutes. It is a
pre-release gate; `tests/run-tests.sh` remains the fast loop.
