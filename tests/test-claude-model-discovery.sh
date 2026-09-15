#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='Claude model discovery'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/fixture"
mkdir -p "$fixture/scripts" "$fixture/node_modules/@anthropic-ai/claude-agent-sdk"
cp "$root/agentkit/skills/review-remote-pr/scripts/claude-model-discovery.mjs" "$fixture/scripts/"

cat >"$fixture/node_modules/@anthropic-ai/claude-agent-sdk/package.json" <<'EOF'
{"name":"@anthropic-ai/claude-agent-sdk","type":"module","exports":"./index.mjs"}
EOF
cat >"$fixture/node_modules/@anthropic-ai/claude-agent-sdk/index.mjs" <<'EOF'
import { writeFileSync } from 'node:fs';
const record = new URL('./calls.json', import.meta.url);
export function query({ prompt, options }) {
  return {
    async supportedModels() {
      writeFileSync(record, JSON.stringify({ promptType: typeof prompt,
        tools: options.tools, settingSources: options.settingSources,
        permissionMode: options.permissionMode, mcpServers: options.mcpServers,
        cwd: options.cwd, pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
        extraArgs: options.extraArgs }));
      return [
        { value: 'sonnet', displayName: 'Sonnet',
          supportsEffort: true, supportedEffortLevels: ['low', 'medium', 'high', 'xhigh', 'max'] },
        { value: 'haiku', displayName: 'Haiku', supportsEffort: false },
      ];
    },
    close() { writeFileSync(new URL('./closed', import.meta.url), 'closed'); },
  };
}
EOF

out=$(node "$fixture/scripts/claude-model-discovery.mjs" --list-models \
    --claude /opt/claude-code --sdk-dir "$fixture" 2>"$tmp/list.err") || {
    _fail 'metadata listing returns available models' "$(<"$tmp/list.err")"; exit 1;
}
assert_contains "$out" 'sonnet' 'listing emits the exact provider-returned selector, including aliases'
assert_contains "$out" 'xhigh' 'listing emits supported effort levels'
assert_contains "$out" 'Sonnet' 'listing emits the provider-supplied display label separately from its selector'
calls=$(<"$fixture/node_modules/@anthropic-ai/claude-agent-sdk/calls.json")
assert_contains "$calls" '"tools":[]' 'metadata query disables tools'
assert_contains "$calls" '"settingSources":[]' 'metadata query ignores filesystem settings'
assert_contains "$calls" '"permissionMode":"dontAsk"' 'metadata query cannot prompt for permissions'
assert_contains "$calls" '"mcpServers":{}' 'metadata query disables MCP servers'
assert_contains "$calls" '"cwd":"' 'metadata query uses a temporary working directory'
assert_contains "$calls" '"pathToClaudeCodeExecutable":"/opt/claude-code"' 'metadata query uses the explicit Claude CLI path'
assert_contains "$calls" '"safe-mode":null' 'metadata query uses safe mode'
assert_contains "$calls" '"no-session-persistence":null' 'metadata query disables session persistence'
assert_contains "$calls" '"strict-mcp-config":null' 'metadata query requires strict MCP isolation'
assert_contains "$calls" '"no-chrome":null' 'metadata query disables Chrome'
assert_eq closed "$(<"$fixture/node_modules/@anthropic-ai/claude-agent-sdk/closed")" \
    'metadata query closes the SDK process without submitting a prompt'
rm "$fixture/node_modules/@anthropic-ai/claude-agent-sdk/calls.json"
node "$fixture/scripts/claude-model-discovery.mjs" --for-error 'authentication failed' \
    --sdk-dir "$fixture" >/dev/null
assert_eq no "$([[ -e $fixture/node_modules/@anthropic-ai/claude-agent-sdk/calls.json ]] && printf yes || printf no)" \
    'ordinary authentication failures do not query model metadata'

local_sdk="$tmp/local-sdk"
mkdir -p "$local_sdk/scripts/node_modules/@anthropic-ai/claude-agent-sdk"
cp "$fixture/scripts/claude-model-discovery.mjs" "$local_sdk/scripts/"
cp "$fixture/node_modules/@anthropic-ai/claude-agent-sdk/package.json" \
    "$fixture/node_modules/@anthropic-ai/claude-agent-sdk/index.mjs" \
    "$local_sdk/scripts/node_modules/@anthropic-ai/claude-agent-sdk/"
local_out=$(node "$local_sdk/scripts/claude-model-discovery.mjs" --list-models 2>"$tmp/local.err") || {
    _fail 'default SDK discovery is bounded to the helper scripts directory' "$(<"$tmp/local.err")"; exit 1;
}
assert_contains "$local_out" 'sonnet' 'SDK installed beside the helper is discoverable by default'

missing="$tmp/missing"
mkdir -p "$missing/scripts"
cp "$root/agentkit/skills/review-remote-pr/scripts/claude-model-discovery.mjs" "$missing/scripts/"
rc=0
node "$missing/scripts/claude-model-discovery.mjs" --list-models >/dev/null 2>"$tmp/missing.err" || rc=$?
assert_eq 1 "$rc" 'missing optional SDK reports model discovery unavailable'
assert_contains "$(<"$tmp/missing.err")" 'operator-controlled SDK directory' \
    'missing SDK output explains the explicit operator-controlled install path'
assert_contains "$(<"$tmp/missing.err")" 'npm install --ignore-scripts --no-save' \
    'missing SDK output gives a safe opt-in installation command'

integration="$tmp/integration"
scripts="$integration/agentkit/skills/review-remote-pr/scripts"
shared="$integration/agentkit/skills/.shared/scripts/lib"
mkdir -p "$scripts" "$shared" "$integration/node_modules/@anthropic-ai/claude-agent-sdk"
cp "$root/agentkit/skills/review-remote-pr/scripts/claude-adversarial-review.sh" \
    "$root/agentkit/skills/review-remote-pr/scripts/claude-model-discovery.mjs" "$scripts/"
cp "$root/agentkit/skills/.shared/scripts/lib/adversarial-review.sh" \
    "$root/agentkit/skills/.shared/scripts/lib/review-attempt.sh" \
    "$root/agentkit/skills/.shared/scripts/lib/private-dir.sh" "$shared/"
cp "$fixture/node_modules/@anthropic-ai/claude-agent-sdk/package.json" \
    "$fixture/node_modules/@anthropic-ai/claude-agent-sdk/index.mjs" \
    "$integration/node_modules/@anthropic-ai/claude-agent-sdk/"
cat >"$integration/node_modules/@anthropic-ai/claude-agent-sdk/index.mjs" <<'EOF'
import { writeFileSync } from 'node:fs';
if (process.env.SDK_EXEC_MARKER) writeFileSync(process.env.SDK_EXEC_MARKER, 'executed');
export function query() { throw new Error('must not query this untrusted SDK'); }
EOF
cat >"$tmp/fake-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then printf '%s\n' 'Claude Code 2.1.0'; exit 0; fi
if [[ ${1:-} == --help ]]; then
    printf '%s\n' '--print --model --effort --system-prompt --tools --permission-mode'
    printf '%s\n' '--no-session-persistence --safe-mode --disable-slash-commands'
    printf '%s\n' '--strict-mcp-config --mcp-config --output-format --include-partial-messages'
    printf '%s\n' '--json-schema --max-budget-usd --no-chrome --verbose'
    exit 0
fi
printf '%s\n' 'Unknown model: claude-fable-5.1' >&2
exit 1
EOF
chmod +x "$tmp/fake-claude"
run_dir="$tmp/review"
mkdir -m 700 "$run_dir"
rc=0
cd "$integration"
SDK_EXEC_MARKER="$tmp/workspace-sdk-executed" CLAUDE_EXECUTABLE="$tmp/fake-claude" bash \
    "$scripts/claude-adversarial-review.sh" --mode probe --no-payload \
    --model claude-fable-5.1 --transcript "$run_dir/transcript" \
    >"$tmp/rejection.out" 2>"$tmp/rejection.err" || rc=$?
assert_eq 1 "$rc" 'invalid model remains a failed review, not an automatic fallback'
diagnostic=$(<"$tmp/rejection.err")
assert_contains "$diagnostic" 'resolves outside its authorized directory' \
    'invalid-model diagnostic refuses a model SDK found only in a worktree ancestor'
assert_eq no "$([[ -e $tmp/workspace-sdk-executed ]] && printf yes || printf no)" \
    'invalid-model diagnostics never import an SDK found under the review worktree'

escape_root="$tmp/authorized-sdk"
mkdir -p "$escape_root/node_modules/@anthropic-ai" "$tmp/untrusted-sdk"
ln -s "$integration/node_modules/@anthropic-ai/claude-agent-sdk" \
    "$escape_root/node_modules/@anthropic-ai/claude-agent-sdk"
escape_marker="$tmp/escaped-sdk-executed"
rc=0
SDK_EXEC_MARKER="$escape_marker" node "$scripts/claude-model-discovery.mjs" --list-models \
    --sdk-dir "$escape_root" >"$tmp/escape.out" 2>"$tmp/escape.err" || rc=$?
assert_eq 1 "$rc" 'explicit SDK directories reject package symlinks escaping their authorized root'
assert_contains "$(<"$tmp/escape.err")" 'resolves outside its authorized directory' \
    'explicit SDK escape is rejected before import'
assert_eq no "$([[ -e $escape_marker ]] && printf yes || printf no)" \
    'SDK package code outside the explicit root is not executed'

finish
