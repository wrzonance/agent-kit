#!/usr/bin/env node
// tally-08 public smoke test.
import assert from 'node:assert/strict';
import { exportState } from '../src/exporter.js';
import { createState, addItem } from '../src/store.js';

const state = addItem(createState(), 'Coffee');
const result = exportState(state);

assert.equal(result.filename, 'tally-export.json');
assert.equal(result.mimeType, 'application/json');
assert.deepEqual(JSON.parse(result.content), { items: state.items, nextId: state.nextId });

console.log('PASS bench/gold/tally exporter smoke: 3 assertions');
