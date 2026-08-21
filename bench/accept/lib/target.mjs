// bench/accept/lib/target.mjs -- resolves the Tally tree an oracle suite
// scores. Every bench/accept/tally-NN.test.mjs reads BENCH_ACCEPT_TARGET
// rather than hardcoding bench/gold/tally or bench/fixtures/tally, so the
// same suite scores any tree shaped like Tally: the gold reference, the
// untouched fixture skeleton, or a trial agent's tree (epic #152,
// issue #326). See bench/accept/README.md for the full interface.
//
// importFromTarget executes target code and MUST only ever be called from
// inside the forked scenario-runner child (see lib/scenario-runner.mjs and
// lib/isolated.mjs, PR #363 review finding 1) -- never from a
// tally-NN.test.mjs process, which shares its own assert module and
// node:test bookkeeping with nothing else. readFromTarget/existsInTarget
// execute no code (plain fs reads) and are safe to call from either side.
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

// Resolves relPath strictly inside targetRoot(): rejects absolute paths and
// ".." segments outright, then rejects the resolved path (both the literal
// join and its realpath, to catch a symlink planted inside the target tree
// -- the target tree's *contents* are attacker-controlled, even though
// relPath itself is always an oracle-authored literal) landing outside the
// root. Without this, a crafted target tree could redirect
// importFromTarget('src/store.js') into reading/executing a file outside
// BENCH_ACCEPT_TARGET, reintroducing finding 1 by a different route.
export function resolveInTarget(relPath) {
  if (typeof relPath !== 'string' || relPath.length === 0) {
    throw new Error('resolveInTarget: relPath must be a non-empty string');
  }
  if (path.isAbsolute(relPath)) {
    throw new Error(`resolveInTarget: relPath must be relative, got an absolute path: ${relPath}`);
  }
  if (relPath.split(/[\\/]+/).includes('..')) {
    throw new Error(`resolveInTarget: relPath must not contain ".." segments: ${relPath}`);
  }

  const root = targetRoot();
  const resolved = path.resolve(root, relPath);
  const rootWithSep = root.endsWith(path.sep) ? root : root + path.sep;
  if (resolved !== root && !resolved.startsWith(rootWithSep)) {
    throw new Error(`resolveInTarget: resolved path escapes BENCH_ACCEPT_TARGET: ${relPath}`);
  }

  let real = resolved;
  try {
    real = fs.realpathSync(resolved);
  } catch {
    // Nothing on disk yet at this path -- existence is the caller's
    // concern (existsInTarget), not path containment's.
  }
  const realRoot = fs.realpathSync(root);
  const realRootWithSep = realRoot.endsWith(path.sep) ? realRoot : realRoot + path.sep;
  if (real !== realRoot && !real.startsWith(realRootWithSep)) {
    throw new Error(`resolveInTarget: ${relPath} resolves (via symlink) outside BENCH_ACCEPT_TARGET`);
  }

  return resolved;
}

export function importFromTarget(relPath) {
  return import(pathToFileURL(resolveInTarget(relPath)).href);
}

export function readFromTarget(relPath) {
  return fs.readFileSync(resolveInTarget(relPath), 'utf8');
}

export function existsInTarget(relPath) {
  try {
    return fs.existsSync(resolveInTarget(relPath));
  } catch {
    return false;
  }
}
