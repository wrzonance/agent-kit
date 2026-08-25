// Agent Kit plugin for OpenCode CLI.
//
// Packaging foundation slice (issue #317): this module ships as a plain ES
// module with zero runtime dependencies so it can be dropped straight into
// an OpenCode plugins directory (`.opencode/plugins/` or
// `~/.config/opencode/plugins/`) with no build step and no npm install --
// the same "clone and go" posture the Claude/Codex manifests already have.
// `@opencode-ai/plugin` is referenced only for its TypeScript types (see the
// JSDoc typedef below); it is never imported at runtime.
//
// Behavioural hooks (the board-aware guards Claude/Codex get from
// agentkit/hooks/) are intentionally out of scope here -- this issue decides
// where OpenCode artifacts live and what the build/version-census emit, not
// what the plugin does. A follow-on issue wires real hook logic.

/**
 * @typedef {import("@opencode-ai/plugin").Plugin} Plugin
 */

/**
 * @type {Plugin}
 */
export const AgentKitPlugin = async ({ client }) => {
    return {
        "session.idle": async () => {
            await client.app.log({
                body: {
                    service: "agentkit",
                    level: "info",
                    message:
                        "agent-kit OpenCode plugin loaded (packaging slice; no hooks wired yet)",
                },
            });
        },
    };
};

export default AgentKitPlugin;
