// bench/accept/lib/isolated.mjs -- runScenario() runs one
// bench/accept/scenarios/<id>.mjs in a forked child process (see
// lib/scenario-runner.mjs), fully separate from this process's own
// `assert` module and `node:test` bookkeeping (PR #363 review finding 1).
//
// The ONLY pass/fail signal trusted here is the single structured IPC
// message the child sends -- the child's exit code is never inspected.
// A child that exits without ever sending a message (crashed, or called
// process.exit() while importing target code) surfaces as a failed
// runScenario() call, exactly like a thrown assertion -- it can never
// look like a pass just by exiting 0. A child that never responds within
// timeoutMs is killed and also surfaces as a failed call (this is
// finding 2's per-call timeout; run-accept.sh's outer per-suite `timeout`
// wrapper is the remaining backstop for anything this misses).
import { fork } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { targetRoot } from './target.mjs';

const RUNNER = path.join(path.dirname(fileURLToPath(import.meta.url)), 'scenario-runner.mjs');
// Overridable so the forgery/hang regression tests in
// tests/test-bench-accept.sh don't have to wait out the production
// default to prove a hung scenario is killed and scored as a failure.
const envTimeoutMs = Number(process.env.BENCH_ACCEPT_SCENARIO_TIMEOUT_MS);
const DEFAULT_TIMEOUT_MS = Number.isFinite(envTimeoutMs) && envTimeoutMs > 0 ? envTimeoutMs : 10_000;

function forkScenario(scenarioId, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    const child = fork(RUNNER, [scenarioId], {
      cwd: targetRoot(),
      stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
    });

    const finish = (outcome) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.removeAllListeners();
      child.kill('SIGKILL');
      resolve(outcome);
    };

    const timer = setTimeout(() => {
      finish({ ok: false, error: `scenario "${scenarioId}" did not respond within ${timeoutMs}ms and was killed` });
    }, timeoutMs);

    child.once('message', (message) => {
      finish(
        message && typeof message === 'object' && 'ok' in message
          ? message
          : { ok: false, error: `scenario "${scenarioId}" sent a malformed IPC message` },
      );
    });

    child.once('error', (error) => {
      finish({ ok: false, error: `scenario-runner failed to start for "${scenarioId}": ${String(error)}` });
    });

    child.once('exit', () => {
      // Only reaches here if 'exit' fires before any 'message' did --
      // e.g. the child crashed, or target code called process.exit()
      // while being imported, before scenario-runner ever got to send.
      finish({ ok: false, error: `scenario "${scenarioId}" exited without sending a result` });
    });
  });
}

export async function runScenario(scenarioId, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const outcome = await forkScenario(scenarioId, timeoutMs);
  if (!outcome.ok) {
    throw new Error(`runScenario("${scenarioId}") failed: ${outcome.error}`);
  }
  return outcome.value;
}
