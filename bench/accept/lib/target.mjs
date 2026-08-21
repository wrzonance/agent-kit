// bench/accept/lib/target.mjs -- resolves the Tally tree an oracle suite
// scores. Every bench/accept/tally-NN.test.mjs reads BENCH_ACCEPT_TARGET
// rather than hardcoding bench/gold/tally or bench/fixtures/tally, so the
// same suite scores any tree shaped like Tally: the gold reference, the
// untouched fixture skeleton, or a trial agent's tree (epic #152,
// issue #326). See bench/accept/README.md for the full interface.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export function targetRoot() {
  const target = process.env.BENCH_ACCEPT_TARGET;
  if (!target) {
    throw new Error('BENCH_ACCEPT_TARGET is not set -- run suites through bench/accept/run-accept.sh');
  }
  const resolved = path.resolve(target);
  if (!fs.existsSync(resolved) || !fs.statSync(resolved).isDirectory()) {
    throw new Error(`BENCH_ACCEPT_TARGET does not resolve to a directory: ${resolved}`);
  }
  return resolved;
}

export function importFromTarget(relPath) {
  const absolute = path.join(targetRoot(), relPath);
  return import(pathToFileURL(absolute).href);
}

export function readFromTarget(relPath) {
  return fs.readFileSync(path.join(targetRoot(), relPath), 'utf8');
}

export function existsInTarget(relPath) {
  return fs.existsSync(path.join(targetRoot(), relPath));
}
