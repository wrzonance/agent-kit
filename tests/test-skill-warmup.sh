#!/usr/bin/env bash
# Execute the shipped Markdown warm-ups against real contract topologies.
set -uo pipefail
TEST_NAME='skill warmup'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/bin" "$tmp/skills/.shared/scripts"
cat > "$tmp/skills/.shared/scripts/agent-preflight.sh" <<'EOF'
#!/usr/bin/env bash
[[ $1 == --ensure ]] || exit 1
EOF
cat > "$tmp/skills/.shared/scripts/contract-read.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$EXPECTED_SKILLS"
EOF
cat > "$tmp/bin/find" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/skills/.shared/scripts/agent-preflight.sh" \
    "$tmp/skills/.shared/scripts/contract-read.sh" "$tmp/bin/find"

for skill in parallel-issues review-remote-pr pr-to-green onboard-repo; do
    recipe="$tmp/$skill.sh"
    awk '
        /^```bash$/ { inside=1; block=""; next }
        /^```$/ {
            if (inside && block ~ /agentkit=\$\(sed -n/) { printf "%s", block; exit }
            inside=0
        }
        inside { block=block $0 "\n" }
    ' "$root/agentkit/skills/$skill/SKILL.md" > "$recipe"
    assert_eq yes "$([[ -s $recipe ]] && printf yes || printf no)" "$skill warm-up extracted"
    # shellcheck disable=SC2016  # the extracted recipe expands this variable.
    printf '\nprintf "WARMUP_SELECTED=%%s\\n" "$agentkit"\n' >> "$recipe"
    for harness in codex claude opencode unknown; do
        for topology in keyed-only stale-legacy bare-only tracked-keyed symlink-keyed; do
            repo="$tmp/$skill-$harness-$topology"
            git init -q "$repo"
            mkdir "$repo/.agent"
            keyed="$repo/.agent/env-contract.$harness.txt"
            legacy="$repo/.agent/env-contract.txt"
            printf 'skills= path=%s\n' "$tmp/skills" > "$keyed"
            case $topology in
                bare-only) mv "$keyed" "$legacy" ;;
                stale-legacy) printf 'skills= path=/missing/stale/skills\n' > "$legacy" ;;
                tracked-keyed)
                    cp "$keyed" "$legacy"
                    git -C "$repo" add -f -- "$keyed"
                    ;;
                symlink-keyed)
                    mv "$keyed" "$legacy"
                    ln -s "$legacy" "$keyed"
                    ;;
            esac
            signals=()
            case $harness in
                codex) signals=(CODEX_PERMISSION_PROFILE=test) ;;
                claude) signals=(CLAUDECODE=1 CODEX_PERMISSION_PROFILE=test) ;;
                opencode) signals=(OPENCODE=1) ;;
            esac
            rc=0
            out=$(cd "$repo" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
                -u CODEX_HOME -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_PERMISSION_PROFILE \
                -u OPENCODE -u OPENCODE_PID HOME="$tmp/home" PATH="$tmp/bin:$PATH" \
                EXPECTED_SKILLS="$tmp/skills" "${signals[@]}" bash "$recipe" 2>&1) || rc=$?
            case $topology in
                tracked-keyed|symlink-keyed)
                    assert_eq 1 "$rc" "$skill $harness $topology refuses unsafe selected path"
                    assert_not_contains "$out" 'WARMUP_SELECTED=' "$skill $harness $topology never falls back to legacy"
                    ;;
                *)
                    assert_eq 0 "$rc" "$skill $harness $topology resolves"
                    assert_contains "$out" "WARMUP_SELECTED=$tmp/skills" "$skill $harness $topology selects current tree"
                    ;;
            esac
        done
    done
done
finish
