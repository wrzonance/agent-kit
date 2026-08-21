#!/usr/bin/env node
// tally-09 public smoke test.
import assert from 'node:assert/strict';
import { parseImport } from '../src/importer.js';

const good = parseImport('{"items":[],"nextId":1}');
assert.deepEqual(good, { ok: true, state: { items: [], nextId: 1 } });

const badJson = parseImport('not json');
assert.equal(badJson.ok, false);
assert.ok(typeof badJson.error === 'string' && badJson.error.length > 0);

const badShape = parseImport('{"nextId":1}');
assert.equal(badShape.ok, false);
assert.ok(typeof badShape.error === 'string' && badShape.error.length > 0);

console.log('PASS bench/gold/tally importer smoke: 5 assertions');
