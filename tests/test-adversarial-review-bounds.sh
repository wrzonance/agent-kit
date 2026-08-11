#!/usr/bin/env bash
# Regression coverage for adversarial-review duration and token ceilings.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='adversarial review bounds'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

claude="$root/agentkit/skills/review-remote-pr/scripts/claude-adversarial-review.sh"
codex="$root/agentkit/skills/review-remote-pr/scripts/codex-adversarial-review.sh"

cat >"$tmp/fake-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then
    printf '%s\n' 'claude 2.1.0'
    exit 0
fi
if [[ ${1:-} == --help ]]; then
    printf '%s\n' '--print --model --effort --system-prompt --tools --permission-mode'
    printf '%s\n' '--no-session-persistence --safe-mode --disable-slash-commands'
    printf '%s\n' '--strict-mcp-config --mcp-config --output-format'
    printf '%s\n' '--include-partial-messages --json-schema --max-budget-usd --no-chrome --verbose'
    exit 0
fi
sleep 5
EOF
chmod +x "$tmp/fake-claude"

cat >"$tmp/fake-codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == exec && ${2:-} == --help ]]; then
    printf '%s\n' '--model --config --sandbox --ephemeral --ignore-user-config'
    printf '%s\n' '--ignore-rules --skip-git-repo-check --output-schema'
    printf '%s\n' '--output-last-message --json'
    exit 0
fi
last_file=''
while (($#)); do
    if [[ $1 == --output-last-message ]]; then
        last_file=$2
        shift 2
    else
        shift
    fi
done
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1000,"output_tokens":1000}}'
if [[ -n $last_file ]]; then
    printf '%s\n' '{"verdict":"no_findings","findings":[]}' >"$last_file"
fi
sleep 5
EOF
chmod +x "$tmp/fake-codex"

private="$tmp/run"
mkdir -- "$private"
chmod 700 -- "$private"

invalid_err="$tmp/invalid.err"
invalid_rc=0
bash "$claude" --mode probe --model claude-test --transcript "$private/invalid" \
    --max-duration-seconds 0 > /dev/null 2>"$invalid_err" || invalid_rc=$?
assert_eq 1 "$invalid_rc" 'Claude rejects a zero duration ceiling'
assert_contains "$(<"$invalid_err")" '--max-duration-seconds' \
    'Claude names the duration option in validation errors'

claude_err="$tmp/claude.err"
claude_rc=0
CLAUDE_EXECUTABLE="$tmp/fake-claude" bash "$claude" --mode probe --model claude-test \
    --transcript "$private/claude.ndjson" --poll-seconds 1 --max-duration-seconds 1 \
    --max-budget-usd 0.25 > /dev/null 2>"$claude_err" || claude_rc=$?
assert_eq 1 "$claude_rc" 'Claude review expires at its duration ceiling'
assert_contains "$(<"$claude_err")" 'duration' \
    'Claude reports a duration-bound review as a safety failure'

codex_err="$tmp/codex.err"
codex_rc=0
CODEX_EXECUTABLE="$tmp/fake-codex" bash "$codex" --mode probe --model gpt-test \
    --transcript "$private/codex.jsonl" --poll-seconds 1 --max-duration-seconds 30 \
    --max-tokens 1024 > /dev/null 2>"$codex_err" || codex_rc=$?
assert_eq 1 "$codex_rc" 'Codex rejects usage above its token ceiling'
assert_contains "$(<"$codex_err")" 'token' \
    'Codex reports a token-bound review as a safety failure'

codex_text=$(<"$codex")
assert_contains "$codex_text" "sleep \"\$POLL_SECONDS\" &" \
    'Codex progress sleep is interruptible during cleanup'

skill="$root/agentkit/skills/review-remote-pr/SKILL.md"
skill_text=$(<"$skill")
assert_contains "$skill_text" '--max-duration-seconds' \
    'the review skill passes an explicit duration ceiling'
assert_contains "$skill_text" '--max-tokens' \
    'the review skill passes an explicit Codex token ceiling'

finish
