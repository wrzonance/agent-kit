// bench/accept/tally-06.test.mjs -- oracle for
// bench/issues/06-tally-dark-mode-toggle.md. Hidden from the trial
// container; injected only for scoring (see bench/accept/README.md).
// Scores the Tally tree at BENCH_ACCEPT_TARGET.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsInTarget, readFromTarget } from './lib/target.mjs';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';
import { parseFragment, query, queryAll } from './lib/dom-stub.mjs';

// Resolved relative to this suite's own file location (not BENCH_ACCEPT_TARGET)
// because the base-fixture comparison is against this repo's own frozen
// bench/fixtures/tally/index.html regardless of which tree is under test.
const here = path.dirname(fileURLToPath(import.meta.url));
const baseFixtureIndexHtml = path.join(here, '..', 'fixtures', 'tally', 'index.html');

// This process never imports target code directly -- runScenario() forks
// scenarios/tally-06.mjs into a separate process for the toggleTheme()
// calls (PR #363 review finding 1). The style.css/index.html checks below
// execute no target code (plain fs reads) and stay in this process.
const obs = await runScenario('tally-06');

test('tally-06: src/theme.js exports a pure toggleTheme', () => {
  assert.equal(obs.toggleThemeFnType, 'function', 'toggleTheme is exported as a function');
  assert.equal(obs.lightToDark, 'dark', "toggleTheme('light') === 'dark'");
  assert.equal(obs.darkToLight, 'light', "toggleTheme('dark') === 'light'");
  assert.equal(obs.undefinedToDark, 'dark', 'toggleTheme(undefined) === \'dark\' (no stored preference)');
});

test('tally-06: style.css defines .theme-light and .theme-dark with background+color', () => {
  assert.ok(existsInTarget('style.css'), 'style.css must exist');
  const css = readFromTarget('style.css');
  for (const selector of ['.theme-light', '.theme-dark']) {
    const escaped = selector.replace(/\./g, '\\.');
    const ruleRe = new RegExp(`${escaped}\\s*\\{([^}]*)\\}`);
    const match = ruleRe.exec(css);
    assert.ok(match, `style.css defines a rule for ${selector}`);
    assert.match(match[1], /background\s*:/, `${selector} declares a background property`);
    assert.match(match[1], /color\s*:/, `${selector} declares a color property`);
  }
});

test('tally-06: index.html links style.css in head; body unchanged from base fixture', () => {
  const html = readFromTarget('index.html');
  const root = parseFragment(html);
  const head = query(root, 'head');
  assert.ok(head, 'index.html has a head element');
  const link = queryAll(head, 'link').find(
    (el) => (el.attrs.rel ?? '').toLowerCase() === 'stylesheet' && el.attrs.href === './style.css',
  );
  assert.ok(link, 'head links ./style.css as a stylesheet');

  const bodyMatch = /<body[^>]*>([\s\S]*)<\/body>/i.exec(html);
  assert.ok(bodyMatch, 'index.html has a body element');
  const baseHtml = fs.readFileSync(baseFixtureIndexHtml, 'utf8');
  const baseBodyMatch = /<body[^>]*>([\s\S]*)<\/body>/i.exec(baseHtml);
  const normalize = (text) => text.replace(/\s+/g, ' ').trim();
  assert.equal(normalize(bodyMatch[1]), normalize(baseBodyMatch[1]), 'body is unchanged from the base fixture');
});

test('tally-06: node test/theme.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/theme.smoke.mjs');
});

test('tally-06: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
