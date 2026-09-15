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

missing="$tmp/missing"
mkdir -p "$missing/scripts"
cp "$root/agentkit/skills/review-remote-pr/scripts/claude-model-discovery.mjs" "$missing/scripts/"
rc=0
node "$missing/scripts/claude-model-discovery.mjs" --list-models >/dev/null 2>"$tmp/missing.err" || rc=$?
assert_eq 1 "$rc" 'missing optional SDK reports model discovery unavailable'
assert_contains "$(<"$tmp/missing.err")" 'npm install --ignore-scripts --no-save' \
    'missing SDK output gives an opt-in install command'

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
CLAUDE_EXECUTABLE="$tmp/fake-claude" bash \
    "$scripts/claude-adversarial-review.sh" --mode probe --no-payload \
    --model claude-fable-5.1 --transcript "$run_dir/transcript" \
    >"$tmp/rejection.out" 2>"$tmp/rejection.err" || rc=$?
assert_eq 1 "$rc" 'invalid model remains a failed review, not an automatic fallback'
diagnostic=$(<"$tmp/rejection.err")
assert_contains "$diagnostic" 'sonnet' \
    'invalid-model diagnostic lists the exact session selector'
assert_contains "$diagnostic" 'effort: low, medium, high, xhigh, max' \
    'invalid-model diagnostic lists exact effort levels'
assert_contains "$diagnostic" 'no prompt submitted' \
    'invalid-model diagnostic identifies metadata-only model discovery'

finish
