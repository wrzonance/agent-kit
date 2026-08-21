// bench/accept/lib/smoke.mjs -- shared "node test/smoke.mjs still exits 0"
// and "node test/<module>.smoke.mjs exits 0 and prints PASS" checks every
// bench/issues/*.md acceptance list repeats. Each per-issue oracle suite
// calls one of these once so a base-behavior regression, or a per-module
// smoke failure, fails that issue's suite too -- without duplicating the
// spawnSync/timeout/assertion boilerplate across five-plus files.
//
// Bounded timeout: a hung target smoke script (an infinite loop, an
// unresolved top-level await) must not stall the whole oracle run forever
// -- see bench/accept/run-accept.sh's header comment for the matching
// outer per-suite timeout. A timeout here fails this assertion, which
// fails this suite, which run-accept.sh already scores as `fail`, never
// skipped.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { targetRoot } from './target.mjs';

export const SMOKE_TIMEOUT_MS = 10_000;

function runSmoke(relPath) {
  return spawnSync(process.execPath, [relPath], {
    cwd: targetRoot(),
    encoding: 'utf8',
    timeout: SMOKE_TIMEOUT_MS,
  });
}

function describeFailure(relPath, result) {
  if (result.error?.code === 'ETIMEDOUT') {
    return `${relPath} did not exit within ${SMOKE_TIMEOUT_MS}ms and was killed`;
  }
  return `${relPath} exited ${String(result.status)}: ${result.stderr}`;
}

export function assertBaseSmokeOk() {
  const result = runSmoke('test/smoke.mjs');
  assert.equal(result.status, 0, describeFailure('test/smoke.mjs', result));
}

export function assertModuleSmokeOk(relPath) {
  const result = runSmoke(relPath);
  assert.equal(result.status, 0, describeFailure(relPath, result));
  assert.match(result.stdout, /^PASS/m, `${relPath} did not print a line starting with PASS`);
}
