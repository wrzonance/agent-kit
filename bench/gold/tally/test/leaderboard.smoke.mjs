#!/usr/bin/env node
// tally-12 public smoke test; imports the real src/sorting.js through leaderboard.js.
import assert from 'node:assert/strict';
import { topItems } from '../src/leaderboard.js';

const state = { items: [{ id: 1, name: 'a', count: 1 }, { id: 2, name: 'b', count: 5 }, { id: 3, name: 'c', count: 3 }], nextId: 4 };
assert.deepEqual(topItems(state, 2).map((i) => i.count), [5, 3]);
assert.deepEqual(topItems(state, 0), []);
console.log('PASS bench/gold/tally leaderboard smoke: 2 assertions');
