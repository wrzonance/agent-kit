#!/usr/bin/env node
// tally-06 public smoke test.
import assert from 'node:assert/strict';
import { toggleTheme } from '../src/theme.js';

assert.equal(toggleTheme('light'), 'dark');
assert.equal(toggleTheme('dark'), 'light');
assert.equal(toggleTheme(undefined), 'dark');

console.log('PASS bench/gold/tally theme smoke: 3 assertions');
