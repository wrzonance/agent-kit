"""Prepare a synthetic plugin for a root-operated live harness probe; launches nothing."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
target = Path(sys.argv[1]).resolve()
target.relative_to(root / ".agent")
target.mkdir(mode=0o700)
plugin = target / "plugin"
shutil.copytree(root / "agentkit", plugin)
for skill in (plugin / "skills").glob("*/SKILL.md"):
    skill.write_text("---\nname: " + skill.parent.name + "\ndescription: Synthetic activation probe only.\n---\n"
                     "This is a synthetic live acceptance probe. Execute only the exact receipt command "
                     "in the invocation boundary context. After it succeeds, return the identity line "
                     "and ACTIVATION-LIVE-RECEIPT. You may inspect the receipt helper first. Do not dispatch workers, access "
                     "the network, or perform the real workflow.\n")
# Keep only activation boundary events: no unrelated onboarding/network probes.
hooks = {"hooks": {event: [{"hooks": [{"type": "command", "command": command}]}]
                   for event, command in {
                       "UserPromptSubmit": '"${CLAUDE_PLUGIN_ROOT}/hooks/user-prompt-submit.sh"',
                       "PreToolUse": '"${CLAUDE_PLUGIN_ROOT}/skills/.shared/scripts/workflow-activation.sh" hook',
                   }.items()}}
(plugin / "hooks/hooks.json").write_text(json.dumps(hooks, indent=2))
repo = target / "repo"
repo.mkdir(mode=0o700)
subprocess.run(["git", "init", "-q", str(repo)], check=True)
(target / "settings.json").write_text("{}\n")
(target / "mcp.json").write_text('{"mcpServers":{}}\n')
(target / "prompt.txt").write_text(
    "$agentkit:parallel-issues\n"
    "I am testing the session-only agent-kit plugin's activation receipt protocol. "
    "Please receive its synthetic workflow through the hook. Inspect the receipt helper "
    "with the native Read tool, then, if safe, execute the acknowledgement command supplied "
    "by the hook. This authorizes only "
    "the local receipt record and printed identity, not issue implementation, dispatch, "
    "or network activity. Then report ACTIVATION-LIVE-RECEIPT with the observed identity.\n")
print(json.dumps({"repo": str(repo), "plugin": str(plugin), "artifacts": str(target)}, indent=2))
