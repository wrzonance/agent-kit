#!/usr/bin/env bash
# Suite: the OpenCode contract-injection plugin (issue #319).
#
# Covers what test-plugin-install.sh cannot: test-plugin-install.sh proves the
# BUILT module imports cleanly and exposes session.idle; this suite drives the
# actual contract-injection wiring (the experimental.chat.system.transform
# hook, its probe, its cache, and its degradation path) against the SOURCE
# module, plus the two prototype-derived smoke checks the issue calls for --
# opencode/test/run-probe.sh (must be shellcheck-clean) and
# opencode/test/run-wrapper.mjs.
set -uo pipefail

TEST_NAME='opencode-plugin'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

opencode_dir="$root/opencode"
index_js="$opencode_dir/index.js"
run_wrapper="$opencode_dir/test/run-wrapper.mjs"
run_probe="$opencode_dir/test/run-probe.sh"

# --- zero-runtime-dependency invariant --------------------------------------
# @opencode-ai/plugin is a devDependency for typings only (see
# opencode/package.json); the shipped module must never import it (or
# anything else) at runtime. JSDoc `@typedef {import(...)}` comments do not
# count -- only a real top-of-file `import` statement would.
import_lines=$(grep -n '^import ' "$index_js" || true)
assert_eq '' "$import_lines" 'index.js has no top-level runtime import statement'

if ! command -v bun > /dev/null 2>&1; then
    printf '%s: bun not installed, skipping the wrapper/probe checks below\n' "$TEST_NAME"
    printf '%s: nothing about the contract-injection wiring was verified\n' "$TEST_NAME"
    finish
    exit $?
fi

# --- shellcheck the probe smoke test ----------------------------------------
# run-probe.sh lives under opencode/test/, outside run-tests.sh's tests/-only
# and agentkit/-only shellcheck sweeps, so this suite is the only gate that
# ever lints it. The issue calls this out explicitly: "shellcheck-clean".
assert_rc 0 'opencode/test/run-probe.sh is shellcheck-clean' \
    -- shellcheck -x -P SCRIPTDIR -S style "$run_probe"
assert_rc 0 'opencode/test/run-probe.sh parses under bash -n' -- bash -n "$run_probe"

# --- run-probe.sh: real probe against the real session-start.sh -----------
probe_out=$("$run_probe" 2>&1)
probe_rc=$?
assert_eq 0 "$probe_rc" 'run-probe.sh exits 0 against this repository'
assert_contains "$probe_out" 'gh=' 'run-probe.sh output contains the expected gh= line'

# --- run-wrapper.mjs: the contract-injection wiring, including the ---------
# three ported prototype defect classes and the degradation path.
wrapper_out=$(bun "$run_wrapper" 2>&1)
wrapper_rc=$?
assert_eq 0 "$wrapper_rc" 'run-wrapper.mjs exits 0'
assert_contains "$wrapper_out" 'run-wrapper: PASS' 'run-wrapper.mjs reports all assertions passing'
# shellcheck disable=SC2016  # literal text from run-wrapper.mjs's own output, not a shell expansion
assert_contains "$wrapper_out" 'defect: $ read from PluginInput, never `this`' \
    'covers defect class 1: $ taken from PluginInput, never this'
assert_contains "$wrapper_out" 'loader-accepted shape' \
    'covers defect class 3: default export is the loader-accepted shape'
assert_contains "$wrapper_out" 'a failing probe does not throw out of the hook' \
    'covers probe failure/timeout leaving the session functional'
assert_contains "$wrapper_out" 'reuses the cached probe' \
    'covers per-session (not per-message) probe caching'

finish
