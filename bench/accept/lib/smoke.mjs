// bench/accept/lib/smoke.mjs -- shared "node test/smoke.mjs still exits 0"
// check every bench/issues/*.md acceptance list repeats verbatim. Each
// per-issue oracle suite calls this once so a base-behavior regression in
// the target tree fails that issue's suite too, matching the issue body's
// own acceptance bullet, without tests/**-copying the assertion ten times.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { targetRoot } from './target.mjs';

export function assertBaseSmokeOk() {
  const result = spawnSync(process.execPath, ['test/smoke.mjs'], {
    cwd: targetRoot(),
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, `test/smoke.mjs exited ${String(result.status)}: ${result.stderr}`);
}
