// bench/accept/lib/scenario-runner.mjs -- fork() entrypoint that executes
// exactly one bench/accept/scenarios/<id>.mjs against BENCH_ACCEPT_TARGET,
// in a process fully separate from the oracle's own assert module and
// node:test bookkeeping (PR #363 review finding 1: run-accept.sh's
// original design imported target code directly into the same process
// running the oracle's assertions, letting target code monkeypatch
// assert.ok/assert.equal, or call process.exit() during import to force
// node --test's own exit code to 0 with no assertion ever having run).
//
// This process's own exit code is NEVER the pass/fail signal -- the ONLY
// signal lib/isolated.mjs trusts is the single structured
// process.send({ok, value|error}) message below, delivered over the IPC
// channel (never stdout, so target-code console noise can't be mistaken
// for the result). A crash, a call to process.exit() during target import,
// or simply never finishing all report as "no message received" to the
// caller, which lib/isolated.mjs treats as a failed call -- never a pass.
//
// Forking put target code in a different process than the oracle's own
// assertions, but the fork still shares ITS process with target code --
// and target code is imported by `main()` below while process.send is
// still reachable. Left alone, a target could call
// process.send({ok: true, value: {...}}) at import time and forge the
// entire observation before any real scenario code ever ran (PR #363
// review finding 1, round 2).
//
// The first fix attempt captured `process.send.bind(process)` and deleted
// `process.send`, leaving `process._send` untouched because the bound
// `send` still called into it. That was itself forgeable a different way
// (PR #363 review finding 1, round 2 -- second pass): `process.send`'s own
// body resolves `this._send(...)` AT CALL TIME, so target code imported
// afterward could replace `process._send` with a wrapper that intercepts
// the real outgoing message, reads the genuine token out of it, sends a
// forged `{token, ok: true, value}` first (accepted, since
// lib/isolated.mjs takes the first token-matching message), then forwards
// the real message through -- the fork boundary and the token both held,
// but the *reporting path itself* was still reachable and re-resolvable
// after target import.
//
// The fix: capture the actual low-level sender -- `process._send` itself,
// bound so the reference is frozen to today's function object rather than
// a live `this._send` lookup -- before any target-reachable import, then
// delete BOTH `process.send` and `process._send` so nothing target code
// does afterward (deleting, reassigning, wrapping) can affect what the
// captured reference calls. Every real result is stamped with the per-run
// token lib/isolated.mjs minted and handed over via env, which is then
// stripped from this process's own env so target code cannot read it back
// out (via process.env) and echo it in a forged message.
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { importFromTarget, targetRoot } from './target.mjs';

const ipcToken = process.env.BENCH_ACCEPT_IPC_TOKEN;
delete process.env.BENCH_ACCEPT_IPC_TOKEN;
// Bind captures a reference to TODAY's `process._send` function object --
// not a live `this._send` property lookup -- so reassigning or wrapping
// `process._send` after this line cannot change what `rawSend` calls.
const rawSend = typeof process._send === 'function' ? process._send.bind(process) : null;
delete process.send;
delete process._send;

function sendResult(result) {
  return new Promise((resolve) => {
    if (!rawSend || !ipcToken) {
      resolve();
      return;
    }
    // The callback form waits for the IPC write to actually flush before
    // resolving -- calling process.exit() right after a bare send() can
    // drop the message if the pipe hasn't drained yet.
    rawSend({ ...result, token: ipcToken }, undefined, undefined, () => resolve());
  });
}

async function main() {
  const scenarioId = process.argv[2];
  if (!scenarioId || /[^a-zA-Z0-9_-]/.test(scenarioId)) {
    throw new Error(`scenario-runner: invalid scenario id: ${String(scenarioId)}`);
  }
  const here = path.dirname(fileURLToPath(import.meta.url));
  const scenarioPath = path.join(here, '..', 'scenarios', `${scenarioId}.mjs`);
  const scenarioModule = await import(pathToFileURL(scenarioPath).href);
  const run = scenarioModule.default;
  if (typeof run !== 'function') {
    throw new Error(`scenario-runner: bench/accept/scenarios/${scenarioId}.mjs has no default export function`);
  }
  return run({ importTarget: importFromTarget, targetRoot });
}

main()
  .then((value) => sendResult({ ok: true, value }))
  .catch((error) => sendResult({ ok: false, error: String((error && error.stack) || error) }))
  .then(() => {
    // Let the event loop drain naturally first; force an exit shortly
    // after as a backstop in case target code left something (a timer, an
    // open handle) alive. unref() so this backstop itself never keeps the
    // process running past a natural exit.
    setTimeout(() => process.exit(0), 250).unref();
  });
