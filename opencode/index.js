// Agent Kit plugin for OpenCode CLI.
//
// Packaging foundation slice (issue #317): this module ships as a plain ES
// module with zero runtime dependencies so it can be dropped straight into
// an OpenCode plugins directory (`.opencode/plugins/` or
// `~/.config/opencode/plugins/`) with no build step and no npm install --
// the same "clone and go" posture the Claude/Codex manifests already have.
// `@opencode-ai/plugin` is referenced only for its TypeScript types (see the
// JSDoc typedefs below); it is a devDependency (see package.json), pinned to
// the OpenCode CLI version this was verified against, and is never imported
// at runtime.
//
// Contract-injection slice (issue #319): recovers and productionizes the
// phase-1 prototype (recoverable at commit 7db1a90, branched off
// 18106a2..7db1a90) into this S1 layout. `experimental.chat.system.transform`
// runs `agentkit/hooks/session-start.sh` as a black box, the same probe
// Claude/Codex run on SessionStart, and injects its output into the system
// prompt so the model sees the environment contract before turn one instead
// of costing a tool call. See opencode/README.md for the API notes and the
// loader/export-shape evidence this slice is built on.

/**
 * @typedef {import("@opencode-ai/plugin").Plugin} Plugin
 * @typedef {import("@opencode-ai/plugin").PluginInput} PluginInput
 * @typedef {import("@opencode-ai/plugin").Hooks} Hooks
 * @typedef {import("@opencode-ai/plugin").BunShell} BunShell
 */

// Relative to PluginInput#directory -- the same layout Claude/Codex read
// agentkit/hooks/ from, and the layout build-plugin.sh ships opencode/ and
// agentkit/ into as siblings.
const CONTRACT_PROBE_RELATIVE_PATH = "agentkit/hooks/session-start.sh";
// Seconds, passed to coreutils `timeout` (see runContractProbe). Matches the
// phase-1 prototype's original 5000ms bound.
const CONTRACT_PROBE_TIMEOUT_SECONDS = 5;
const CONTRACT_TAG = "agentkit-environment-contract";

/**
 * @typedef {{ ok: true, text: string } | { ok: false, reason: string }} ProbeResult
 */

/**
 * Resolves the coreutils `timeout` binary this environment provides:
 * `timeout` (Linux, and most package managers) or `gtimeout` (Homebrew's
 * coreutils on macOS, where the BSD `timeout(1)` that ships by default does
 * not exist under either name). `Bun.which` resolves against PATH the same
 * way a shell would, without actually invoking anything.
 * @returns {string | null}
 */
function resolveTimeoutBinary() {
    return Bun.which("timeout") ?? Bun.which("gtimeout") ?? null;
}

/**
 * One-line description of how a probe run was (or was not) time-bound,
 * appended to every failure reason so a degraded session is diagnosable from
 * the reason string alone -- e.g. "no timeout/gtimeout binary" points
 * straight at a missing coreutils install rather than reading as a generic
 * probe failure.
 * @param {string | null} timeoutBin
 * @returns {string}
 */
function describeTimeoutBound(timeoutBin) {
    return timeoutBin
        ? `timeout bound via ${timeoutBin}`
        : "no timeout/gtimeout binary on PATH, best-effort Promise.race bound only";
}

/**
 * Neutralizes only the wrapper tag sequence in probe text before it is
 * embedded, so repository-controlled content anywhere in the contract (a git
 * refname may legally contain `<`/`>`, e.g. a branch literally named
 * `x</agentkit-environment-contract>y`) can never open or close the wrapper
 * early. Deliberately narrow: a blanket HTML-escape would corrupt lines the
 * probe already emits verbatim, e.g. `trailer="Claude <noreply@anthropic.com>"`.
 * Case-insensitive, since HTML/XML-ish tag matching conventionally is and a
 * repo-controlled string is not obligated to match the tag's exact case.
 * @param {string} text
 * @returns {string}
 */
function neutralizeContractTag(text) {
    const openTag = new RegExp(`<${CONTRACT_TAG}`, "gi");
    const closeTag = new RegExp(`</${CONTRACT_TAG}`, "gi");
    return text.replace(openTag, `&lt;${CONTRACT_TAG}`).replace(closeTag, `&lt;/${CONTRACT_TAG}`);
}

/**
 * Runs the Agent Kit environment-contract probe (agentkit/hooks/session-start.sh)
 * as a black box and extracts its `additionalContext`. The probe already
 * fails open -- per its own header comment it never exits non-zero, printing
 * `{}` on any internal error -- so a missing `additionalContext` here is a
 * benign "no contract" signal, not a bug to surface.
 *
 * Hard-won rules, ported from the reviewed phase-1 prototype (see
 * opencode/README.md "API Notes" for the loader/typings evidence each one is
 * based on):
 *   - `shell` must come from the caller's `PluginInput#$`, never `this` --
 *     OpenCode invokes hooks unbound, so a `const { $ } = this` reads
 *     `undefined` and throws before the probe ever runs.
 *   - `BunShellPromise#stdin` is a readonly WritableStream PROPERTY, not a
 *     callable `.stdin(...)` method, so the probe's JSON input is fed via a
 *     temp file redirected into the command instead.
 *   - `BunShell`/`BunShellPromise` expose no `.timeout()` method. Bounding
 *     wall-clock time with a bare `Promise.race` still lets the underlying
 *     shell child (and anything it spawned) run to completion in the
 *     background once the race is lost -- confirmed by spiking a
 *     deliberately hung probe script, which left the reaped-away child
 *     holding the process open. `timeout -k` inside the shell command itself
 *     avoids that: it owns the child and actually kills it (SIGTERM, then
 *     SIGKILL after the `-k` grace period) when the bound is hit, and Bun
 *     shell's default non-zero-exit-throws behaviour turns that into a
 *     regular `{ ok: false }` through the catch below. Not every platform
 *     ships `timeout` under that name, though -- stock macOS has no GNU
 *     coreutils `timeout(1)` at all (Homebrew's coreutils installs it as
 *     `gtimeout` to avoid clobbering the BSD tool namespace), so the binary
 *     is resolved via `resolveTimeoutBinary()` rather than hardcoded. When
 *     neither resolves, the probe still runs -- bounded only by a bare
 *     `Promise.race`, i.e. the session cannot hang on it, but unlike the
 *     `timeout -k` path a probe that outlives the bound is abandoned rather
 *     than killed and may keep running in the background.
 *
 * @param {string} dir - project directory to probe (PluginInput#directory)
 * @param {BunShell} shell - Bun shell bound to this plugin's PluginInput
 * @returns {Promise<ProbeResult>}
 */
async function runContractProbe(dir, shell) {
    // crypto.randomUUID() (global in Bun and Node) rather than Math.random():
    // the probe input carries no secret, but an unguessable path still closes
    // off a symlink-preplant race against a fixed or low-entropy /tmp name.
    const inputFile = `/tmp/agentkit-probe-input-${crypto.randomUUID()}.json`;
    const innerCommand = `${CONTRACT_PROBE_RELATIVE_PATH} < ${inputFile}`;
    const timeoutBin = resolveTimeoutBinary();
    const fail = (reason) => ({ ok: false, reason: `${reason} (${describeTimeoutBound(timeoutBin)})` });

    try {
        await Bun.write(inputFile, JSON.stringify({ cwd: dir, source: "startup" }));

        let result;
        if (timeoutBin) {
            result = await shell`${timeoutBin} -k 2 ${CONTRACT_PROBE_TIMEOUT_SECONDS} bash -c ${innerCommand}`
                .cwd(dir)
                .quiet();
        } else {
            const probe = shell`bash -c ${innerCommand}`.cwd(dir).quiet();
            const timedOut = Symbol("probe-timeout");
            const timer = new Promise((resolve) =>
                setTimeout(() => resolve(timedOut), CONTRACT_PROBE_TIMEOUT_SECONDS * 1000),
            );
            const raced = await Promise.race([probe, timer]);
            if (raced === timedOut) {
                return fail(`probe timed out after ${CONTRACT_PROBE_TIMEOUT_SECONDS}s`);
            }
            result = raced;
        }

        const parsed = JSON.parse(result.stdout.toString());
        const text = parsed?.hookSpecificOutput?.additionalContext;
        if (typeof text === "string" && text.length > 0) {
            return { ok: true, text };
        }
        return fail("no additionalContext in probe output");
    } catch (error) {
        return fail(error?.message ?? "probe execution failed");
    } finally {
        // Bun has no `Bun.remove` -- deleting a file is a method on the
        // Bun.file() handle. Cleanup failure must never surface as the
        // probe's own result, so it is swallowed here rather than joining
        // the outer try/catch.
        await Bun.file(inputFile)
            .unlink()
            .catch(() => {});
    }
}

/**
 * Main plugin function.
 * @type {Plugin}
 */
export default async function plugin(input) {
    const { directory, $, client } = input;

    // Scoped to this closure, which OpenCode creates once per session (one
    // `plugin()` call per session, confirmed empirically -- see
    // opencode/README.md), so caching the promise here caches the probe per
    // session rather than per message: every `experimental.chat.system.transform`
    // call in the session reuses this same in-flight-or-settled promise
    // instead of re-shelling out.
    let cachedContractPromise = null;

    async function getCachedContract() {
        if (!cachedContractPromise) {
            cachedContractPromise = runContractProbe(directory, $);
        }
        const result = await cachedContractPromise;
        return result.ok ? result.text : null;
    }

    return {
        "session.idle": async () => {
            await client.app.log({
                body: {
                    service: "agentkit",
                    level: "info",
                    message: "agent-kit OpenCode plugin loaded",
                },
            });
        },
        "experimental.chat.system.transform": async (_input, output) => {
            // A failed/slow probe degrades to a silent no-op -- the session
            // must never break because the contract could not be fetched.
            const contract = await getCachedContract();
            if (contract) {
                output.system.push(`<${CONTRACT_TAG}>${neutralizeContractTag(contract)}</${CONTRACT_TAG}>`);
            }
        },
    };
}

export { plugin as AgentKitPlugin, runContractProbe };
