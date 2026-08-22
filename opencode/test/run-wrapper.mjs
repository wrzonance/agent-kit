// Boundary test for the OpenCode plugin's contract-injection wiring.
//
// Run under Bun -- the runtime OpenCode plugins actually execute in, and the
// runtime index.js's runContractProbe calls Bun.write/Bun.file(...).unlink()
// against, which only exist there:
//   bun opencode/test/run-wrapper.mjs
//
// Imports the shipped module and drives it exactly the way OpenCode does:
// call the default export with a PluginInput-shaped object, then invoke the
// returned "experimental.chat.system.transform" hook with a fake
// { system: [] } output. No opencode binary or provider credentials
// required -- Bun.write/Bun.file(...).unlink() run for real against
// throwaway /tmp files; only the shell ($) is a stub.

const here = new URL(".", import.meta.url).pathname;
const modulePath = `${here}../index.js`;

let failures = 0;
function check(condition, message) {
    if (condition) {
        console.log(`  ok   ${message}`);
    } else {
        failures += 1;
        console.log(`  FAIL ${message}`);
    }
}

/**
 * A minimal BunShell stand-in. Records every tagged-template invocation and
 * every `.cwd(...)` argument so the assertions below can prove:
 *   - the plugin called `shell` as a tagged template (never `shell.stdin(...)`,
 *     which does not exist as a callable on the real BunShell -- see
 *     index.js's runContractProbe doc comment), and
 *   - the directory it bound the shell to is the one PluginInput supplied.
 */
function makeStubShell({ succeed }) {
    const calls = [];
    const cwdCalls = [];
    const shell = (strings, ...expressions) => {
        calls.push({ strings: [...strings], expressions });
        const promiseLike = {
            cwd(dir) {
                cwdCalls.push(dir);
                return promiseLike;
            },
            quiet() {
                return promiseLike;
            },
            then(resolve, reject) {
                if (!succeed) {
                    reject(new Error("stub shell: simulated probe failure"));
                    return;
                }
                const stdout = Buffer.from(
                    JSON.stringify({
                        hookSpecificOutput: { additionalContext: "FAKE-CONTRACT-TEXT" },
                    }),
                );
                resolve({ stdout, stderr: Buffer.alloc(0), exitCode: 0 });
            },
        };
        return promiseLike;
    };
    shell.calls = calls;
    shell.cwdCalls = cwdCalls;
    // BunShellPromise#stdin is a readonly WritableStream PROPERTY on the real
    // API, never a callable method. If the plugin ever regresses to calling
    // `.stdin(...)`, this throws instead of silently no-opping.
    Object.defineProperty(shell, "stdin", {
        get() {
            throw new Error("shell.stdin must never be read/called -- use a temp file + redirection");
        },
    });
    return shell;
}

function makeFakePluginInput(shell) {
    return {
        directory: "/tmp/agentkit-run-wrapper-fake-project",
        worktree: "/tmp/agentkit-run-wrapper-fake-project",
        project: {},
        serverUrl: new URL("http://localhost:4096/"),
        experimental_workspace: { register() {} },
        client: { app: { log: async () => {} } },
        $: shell,
    };
}

const mod = await import(modulePath);

check(typeof mod.default === "function", "module has a callable default export (loader-accepted shape, see README)");
check(typeof mod.AgentKitPlugin === "function", "module keeps the AgentKitPlugin named export");

// --- plugin() must not read `this` -----------------------------------------
// Called the same way OpenCode's loader calls it: as a plain function, not a
// method, so `this` is undefined. `const { directory, $ } = this` (the
// original defect) throws synchronously right here.
{
    const shell = makeStubShell({ succeed: true });
    let threw = false;
    try {
        await mod.default(makeFakePluginInput(shell));
    } catch {
        threw = true;
    }
    check(!threw, "plugin() does not throw when called unbound (defect: $ read from PluginInput, never `this`)");
}

// --- Happy path: probe succeeds, hook pushes the tagged contract ----------
{
    const shell = makeStubShell({ succeed: true });
    const input = makeFakePluginInput(shell);
    const hooks = await mod.default(input);
    check(
        typeof hooks["experimental.chat.system.transform"] === "function",
        "returns the experimental.chat.system.transform hook",
    );

    const output = { system: [] };
    await hooks["experimental.chat.system.transform"]({ model: {} }, output);
    check(shell.calls.length === 1, "called the PluginInput-supplied shell exactly once");
    check(shell.cwdCalls[0] === input.directory, "bound the shell to PluginInput#directory");
    check(output.system.length === 1, "pushed exactly one entry onto output.system");
    check(
        output.system[0] === "<agentkit-environment-contract>FAKE-CONTRACT-TEXT</agentkit-environment-contract>",
        "pushed entry is the probe text wrapped in <agentkit-environment-contract> tags",
    );

    // Second invocation in the same session must reuse the cached probe, not
    // shell out again ("cache the probe per session ... not per message").
    await hooks["experimental.chat.system.transform"]({ model: {} }, { system: [] });
    check(shell.calls.length === 1, "second transform call in the same session reuses the cached probe (no second shell-out)");
}

// --- Degradation path: probe fails, hook is a silent no-op -----------------
{
    const shell = makeStubShell({ succeed: false });
    const input = makeFakePluginInput(shell);
    const hooks = await mod.default(input);

    const output = { system: [] };
    let threw = false;
    try {
        await hooks["experimental.chat.system.transform"]({ model: {} }, output);
    } catch {
        threw = true;
    }
    check(!threw, "a failing probe does not throw out of the hook (the session stays functional)");
    check(output.system.length === 0, "a failing probe leaves output.system untouched (silent no-op)");
}

console.log(`\nrun-wrapper: ${failures === 0 ? "PASS" : "FAIL"} (${failures} failing assertions)`);
process.exit(failures === 0 ? 0 : 1);
