#!/usr/bin/env node
// tally-14 public smoke test; imports the real src/search.js through results.js.
import assert from 'node:assert/strict';
import { renderResults } from '../src/results.js';

const state = { items: [{ id: 1, name: 'Coffee', count: 0 }, { id: 2, name: 'Tea', count: 0 }], nextId: 3 };
const html = renderResults(state, 'tea');
assert.ok(html.includes('Tea') && !html.includes('Coffee'));
assert.equal(renderResults(state, 'zzz'), '<p class="tally-empty">No matches</p>');
console.log('PASS bench/gold/tally results smoke: 3 assertions');
