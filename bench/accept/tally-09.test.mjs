// bench/accept/tally-09.test.mjs -- oracle for
// bench/issues/09-tally-import-json.md. Hidden from the trial container;
// injected only for scoring (see bench/accept/README.md). Scores the
// Tally tree at BENCH_ACCEPT_TARGET.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { importFromTarget, existsInTarget, targetRoot } from './lib/target.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';

test('tally-09: src/importer.js exports a pure, never-throwing parseImport', async () => {
  assert.ok(existsInTarget('src/importer.js'), 'src/importer.js must exist');
  const { parseImport } = await importFromTarget('src/importer.js');
  assert.equal(typeof parseImport, 'function', 'parseImport is exported as a function');

  const ok = parseImport('{"items":[],"nextId":1}');
  assert.deepEqual(ok, { ok: true, state: { items: [], nextId: 1 } }, 'valid JSON parses to ok:true');

  assert.doesNotThrow(() => parseImport('not json'), 'invalid JSON does not throw');
  const badJson = parseImport('not json');
  assert.equal(badJson.ok, false, 'invalid JSON returns ok:false');
  assert.equal(typeof badJson.error, 'string', 'invalid JSON returns a string error');
  assert.ok(badJson.error.length > 0, 'invalid JSON returns a non-empty error message');

  assert.doesNotThrow(() => parseImport('{"nextId":1}'), 'a shape mismatch does not throw');
  const badShape = parseImport('{"nextId":1}');
  assert.equal(badShape.ok, false, 'missing items returns ok:false');
});

test('tally-09: node test/importer.smoke.mjs exits 0 and prints a PASS line', () => {
  const result = spawnSync(process.execPath, ['test/importer.smoke.mjs'], {
    cwd: targetRoot(),
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, `test/importer.smoke.mjs exited ${String(result.status)}: ${result.stderr}`);
  assert.match(result.stdout, /^PASS/m, 'test/importer.smoke.mjs prints a line starting with PASS');
});

test('tally-09: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
