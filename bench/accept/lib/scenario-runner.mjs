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
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { importFromTarget, targetRoot } from './target.mjs';

function sendResult(result) {
  return new Promise((resolve) => {
    if (typeof process.send !== 'function') {
      resolve();
      return;
    }
    // The callback form waits for the IPC write to actually flush before
    // resolving -- calling process.exit() right after a bare process.send()
    // can drop the message if the pipe hasn't drained yet.
    process.send(result, undefined, undefined, () => resolve());
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
