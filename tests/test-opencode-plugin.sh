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

# --- run-probe.sh resolves the timeout binary rather than hardcoding it ----
# Fix for issue #319/#388 finding F1: a bare `timeout -k` call is BSD-macOS-
# hostile -- stock macOS ships no `timeout` at all, and Homebrew's coreutils
# installs it as `gtimeout` instead, so a hardcoded call exits 127 before the
# probe ever runs. run-probe.sh must resolve the binary the same way
# opencode/index.js's resolveTimeoutBinary() does (`timeout`, then
# `gtimeout`, then no kill bound). This is a grep oracle, not an executed
# assertion: the no-timeout/no-gtimeout fallback path can only be exercised
# on a host missing both binaries, which this Linux host is not.
probe_src=$(cat -- "$run_probe")
assert_not_contains "$probe_src" 'timeout -k' \
    'run-probe.sh has no bare hardcoded "timeout -k" invocation'

# --- run-probe.sh: real probe against the real session-start.sh -----------
probe_out=$("$run_probe" 2>&1)
probe_rc=$?
assert_eq 0 "$probe_rc" 'run-probe.sh exits 0 against this repository'
assert_contains "$probe_out" 'gh=' 'run-probe.sh output contains the expected gh= line'

# --- run-probe.sh fallback: forced no-timeout path still finds gh= --------
# Exercises the AGENTKIT_PROBE_FORCE_NO_TIMEOUT test seam against the REAL
# probe on this host: the fallback path must behave identically to the
# timeout_bin path here, exiting 0 with the expected gh= line, comfortably
# inside the default 10s bound.
forced_fallback_out=$(AGENTKIT_PROBE_FORCE_NO_TIMEOUT=1 "$run_probe" 2>&1)
forced_fallback_rc=$?
assert_eq 0 "$forced_fallback_rc" 'run-probe.sh forced-fallback path exits 0 against the real probe'
assert_contains "$forced_fallback_out" 'gh=' 'run-probe.sh forced-fallback path still finds the gh= line'

# --- run-probe.sh fallback: a hung probe is killed within the bound -------
# Regression for the no-timeout/no-gtimeout fallback running the probe with
# NO bound at all (a hung probe would hang this smoke test, and the whole
# suite, forever). Points run-probe.sh at a throwaway fake probe that never
# exits, via the AGENTKIT_PROBE_SCRIPT test seam, with the watchdog shortened
# to 1s via AGENTKIT_PROBE_BOUND_SECONDS so this assertion itself cannot hang
# the suite -- and an outer `timeout` is a belt-and-braces guard in case the
# fallback's own bound were ever broken again.
hung_probe_script=$(mktemp)
cat > "$hung_probe_script" << 'HUNG_PROBE'
#!/usr/bin/env bash
cat > /dev/null # drain stdin like the real probe does
sleep 300
HUNG_PROBE
chmod +x -- "$hung_probe_script"
hung_out=$(AGENTKIT_PROBE_FORCE_NO_TIMEOUT=1 AGENTKIT_PROBE_SCRIPT="$hung_probe_script" \
    AGENTKIT_PROBE_BOUND_SECONDS=1 timeout 10 "$run_probe" 2>&1)
hung_rc=$?
rm -f "$hung_probe_script"
assert_eq 1 "$hung_rc" 'run-probe.sh exits 1 when the fallback watchdog kills a hung probe'
assert_contains "$hung_out" 'FAIL' 'run-probe.sh prints a FAIL line naming the watchdog bound'

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
