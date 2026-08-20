#!/usr/bin/env node
// tally-07 public smoke test.
import assert from 'node:assert/strict';
import { matchShortcut } from '../src/keyboard.js';

assert.equal(matchShortcut({ key: '+' }), 'increment');
assert.equal(matchShortcut({ key: '-' }), 'decrement');
assert.equal(matchShortcut({ key: 'Delete' }), 'remove');
assert.equal(matchShortcut({ key: 'a' }), null);

console.log('PASS bench/gold/tally keyboard smoke: 4 assertions');
