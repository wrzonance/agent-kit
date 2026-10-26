# ak waves: Task 0 spike results (2026-10-23)

Throwaway spikes run in separate interactive sessions under tmux; the spike code is gone, these results and the
fixtures in `tests/v2/fixtures/transcripts/` remain.

## Verdicts

- S1: block honored: yes. Hook stdin has NO `source` field (session_id, transcript_path, cwd, prompt_id, permission_mode, hook_event_name, prompt). Session id for Bash = $CLAUDE_CODE_SESSION_ID (== hook session_id). Plugin-shipped hook fires without user config (tested via --plugin-dir).
- S4: completed. A background `sleep 4000` remained alive for 66:34 and exited 0 in an interactive Claude session;
  its completion notice was delivered. No background-task limit was observed, so Task 6 needs no hand-off or
  `AK_WAIT_HANDOFF_S`.
- Ruling 6: the hook matches on prompt text (no `source` field exists): block only when the prompt starts with the <task-notification> envelope whose <summary> starts with `Agent "` (finished OR interim "is waiting on its own background work"); Bash notices always pass, so ak wait's own exit notice is the wake — cost if wrong: an envelope format change in a future Claude Code silently returns us to per-worker wakes (fail open).
- Ruling 7: ak wait's Claude end-signal = subagent .meta.json finished:true (plus transcript end records); a stopped agent has no terminal transcript record — cost if wrong: a stopped worker reads as hung after AK_WAIT_HANG_S instead of ended-without-result at once.
- Ruling 8: marker carries session=$CLAUDE_CODE_SESSION_ID; the hook blocks only on an exact session match (Review Focus 3 fully covered; cwd fallback only when the env var is absent) — cost if wrong: none known.
- S2: path B. exec/write_stdin yield clamped at ~30 s; `wait` tool on a cell returns after ~268–300 s; a child's completion does not interrupt a shell wait (seen at next poll). wait_agent at 3600000 untested but source-verified max.
- Ruling 16: Codex roots use path B (wait_agent timeout_ms=3600000 + `ak wait --check`, exit 3 → wait again with no words) — S2 measured shell blocking capped at ~300 s — cost if wrong: ≤2 cheap root turns per finishing worker on Codex instead of 1 per wave.
- Ruling 17: worker↔transcript mapping: every `spawn` line gains `name=issue-N` (pr-N for PR workers); Codex roots pass it as spawn_agent task_name (→ agent_path /root/issue_N after the tool's lowercase/underscore rule), Claude roots as the Agent `name`; ak wait matches Codex children by parent thread + agent_path and Claude sub-agents by .meta.json/first line containing the worktree path — Codex prompts are encrypted so text matching is impossible there — cost if wrong: a root that ignores name= leaves its Codex workers `unwatched` (fallback to worktree activity), never blocked.
- Ruling 18: the still-working notice in run_lock is removed for both harnesses (path B means no Codex shell wait relies on it) — cost if wrong: a Codex root that loses a yielded plan's output re-runs plan, which resume_run already answers with the same lines.

## Claude report (S1, S3, S4)

## Task 0, Claude half: S1, S3 (Claude), S4 started

Claude Code 2.1.310, model haiku (Haiku 5.5). Scratch: `.superpowers/sdd/2026-10-23-ak-wave-wait/spike-claude/`
(own `git init`; also ignored by the repo via `.git/info/exclude` `.superpowers/`).
Project `.claude/settings.json` held only `permissions.allow` = `Bash(sleep:*)`, `Bash(env)`, `Bash(echo:*)` plus the
UserPromptSubmit hook `hook.sh` (appends stdin to `hook-log.jsonl`; prints `{"decision":"block","reason":"spike block"}`
only when env `SPIKE_BLOCK` is set AND stdin contains `<task-notification>` and `gent`).
Sessions ran with `--permission-mode default` (the first session came up in the user's global "auto" mode and was
cycled to manual with shift+tab before any test prompt; the later ones were started with `--permission-mode default`).
No permission prompts appeared for the allow-listed commands. Nothing was written outside the scratch dir.

### S1 (Claude)

#### 1. Hook stdin JSON field names
Human prompt, as received:
`session_id, transcript_path, cwd, prompt_id, permission_mode, hook_event_name:"UserPromptSubmit", prompt`
There is NO `source` field. Notices arrive through the same hook with the same keys; the notice text is the `prompt`
value. The hook fires for notices, including ones delivered mid-turn ("absorbed_mid_turn" in the transcript).
Samples: `fixtures-claude/notices/hook-stdin-session1.jsonl`.

#### 2. Agent notice vs Bash notice (text in `prompt`)
All start with `<task-notification>\n<task-id>ID</task-id>`.
- Agent, final: `<tool-use-id>` present at first; `<output-file>.../tasks/ID.output</output-file>` (a symlink to the
  sub-agent jsonl); `<status>completed</status>`; `<summary>Agent "NAME" finished</summary>`; `<note>A task-notification
  fires each time this agent stops with no live background children...`; `<result>agent-done</result>`;
  `<usage><subagent_tokens>..</subagent_tokens><tool_uses>..</tool_uses><duration_ms>..</duration_ms></usage>`.
- Agent, INTERIM (agent ended its turn while its own background Bash was still running): same shape but
  `<summary>Agent "NAME" is waiting on its own background work</summary>` and a note "This agent stopped with
  background work of its own still running... the result below may be interim." `<status>` is still `completed`.
  The same task-id notifies again later with `finished`. So "completed" status alone does not mean done; key on
  summary `finished` vs `is waiting on its own background work`.
- Bash: `<summary>Background command "DESC" completed (exit code 0)</summary>`; no `<result>`, no `<usage>`, no `<note>`.
  `<output-file>` is a regular file with the command's stdout.
Discriminator: `Agent "` in `<summary>` (agent) vs `Background command "` (Bash); `<usage>` only on agents.

#### 3. Does the block stop the notice reaching the model?
Fresh session with `SPIKE_BLOCK=1`; one background agent told to reply `pineapple42`.
- Pane: `UserPromptSubmit operation blocked by hook: spike block  Original prompt: <task-notification>...<result>pineapple42</result>`.
  The model produced no turn for it (it showed as a one-time informational line).
- Transcript: the notice appears only as `queue-operation enqueue/dequeue` and a `system` record (`subtype:informational`,
  text "UserPromptSubmit operation blocked by hook"). There is NO `user` record with `origin.kind:"task-notification"` /
  `turnOrigin:"task_notification"` (unblocked notices have both, `promptSource:"system"`).
- Then typed: "What secret word did the sub-agent reply with? ... UNKNOWN if you do not know. Do not run any tools."
  Model answered `UNKNOWN`. The notice content never reached it; it is lost (not redelivered).

**block honored: yes**

#### 4. Typed human message still passes
Yes. In the same blocked-notice session the typed message was logged by the hook (`origin:{kind:"human"}`,
`promptSource:"typed"`, `turnOrigin:"human"`) and answered. Note the hook script has no way to tell a human message from a
notice except by text (no `source`); the transcript's `origin.kind` is the only structured marker and the hook does not
receive it.

#### 5. Session id for a Bash command
`CLAUDE_CODE_SESSION_ID` (verified: value of `/proc/<bash-child>/environ` equals hook `session_id` for the S4 session).
Other env names seen in a Bash tool shell: `CLAUDE_CODE_ENTRYPOINT, CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS,
CLAUDE_CODE_MESSAGING_SOCKET, CLAUDE_CODE_MESSAGING_TOKEN, CLAUDE_CODE_EXECPATH, CLAUDECODE, CLAUDE_CODE_CHILD_SESSION,
CLAUDE_CODE_SESSION_ATTENDED, CLAUDE_PID, CLAUDE_EFFORT` (plus `IMPECCABLE_SESSION_ID` from a user plugin). Hook
`transcript_path` gives the transcript directly; the Bash side can derive it from the session id and cwd slug
(`~/.claude/projects/<cwd with / and . -> ->/<session_id>.jsonl`).

#### 6. Plugin-shipped hook active without user config?
Yes. Local plugin (`plugin/.claude-plugin/plugin.json` + `plugin/hooks/hooks.json`, command using
`${CLAUDE_PLUGIN_ROOT}`), session started `claude --model haiku --permission-mode default --plugin-dir <plugin>`:
the plugin's UserPromptSubmit hook fired on the first prompt and wrote `${CLAUDE_PLUGIN_ROOT}/../plugin-hook-log.jsonl`
with the same JSON shape. No hook-trust dialog. Caveat: tested through `--plugin-dir`, not a marketplace install.

**S1 verdict: gate passes; block honored: yes.**

### S3 (Claude half)

Two agents ended normally, one stopped with TaskStop (TaskStop is a deferred tool; the model loaded it via ToolSearch).
- Path: `~/.claude/projects/<cwd-slug>/<session_id>/subagents/agent-<agentId>.jsonl` plus `agent-<agentId>.meta.json`.
  `<agentId>` equals the `<task-id>` in the notice; `/tmp/claude-1000/<cwd-slug>/<session_id>/tasks/<agentId>.output`
  is a symlink to that jsonl.
- Mapping to the spawn: `.meta.json` = `{"agentType":"general-purpose","isBuiltIn":true,"description":"<Agent description>",
  "toolUseId":"toolu_...","spawnDepth":1,"requestShape":"background","requestNonInteractive":true,"model":"haiku","finished":true}`.
  `toolUseId` equals the parent's Agent tool_use id and the notice's `<tool-use-id>`. First jsonl record is a `user` record
  (`isSidechain:true, agentId, sessionId, parentUuid:null`) whose content is exactly the prompt given to the agent, so
  the worker prompt's first line is greppable. Every record carries `cwd` and `gitBranch` (worker worktree).
- Normal end: last record `assistant`, `stop_reason:"end_turn"`, text `agent-done`; the record before is a `user` record
  starting `[SYSTEM NOTIFICATION - NOT USER INPUT]` (the agent's own background Bash completing). Before that, an interim
  `assistant end_turn` ("30-second sleep is running..."). Note a worker that used `run_in_background` ends its turn
  twice; the first end_turn is NOT the final record.
- Stopped (TaskStop): parent tool result `{"message":"Successfully stopped task: ID (NAME)","task_id":"ID","task_type":"local_agent",...}`.
  The agent jsonl gets NO terminal/killed record: it ends at the last pre-stop record (here the interim `assistant
  end_turn`, "waiting for its completion notice"). `.meta.json` still says `"finished":true`. No further
  `<task-notification>` is emitted for the stopped agent (the hook log shows none after the TaskStop). A stop is therefore
  distinguishable only by the absence of a `finished` notice and by the parent's TaskStop result, not by the sub-agent file.
- Errored session: not run (outside the brief for this half).
- Fixtures (trimmed: user/assistant records only, usage/signatures dropped): `fixtures-claude/normal/`, `fixtures-claude/stopped/`,
  `fixtures-claude/notices/hook-stdin-session1.jsonl`. Source transcript: session `7d0884ba-b7aa-4a06-a83e-e8a37132cb18`.

### S4 (started, not waited on)

- tmux session `ak-spike-s4`, pane `%74`, cwd the scratch dir, `claude --model haiku --permission-mode default`, logging-only hook.
- Background Bash started 2026-10-23 19:50:57 PDT (2026-10-24T02:50:57Z): `sleep 4000; echo s4-done`
  (sleep pid 2713961, parent zsh pid 2713960). 4000 s ends at about 2026-10-23 20:57:37 PDT (03:57:37Z).
- Session id `2d7467c6-ecdf-4f73-87a0-cc1313b83326`; transcript
  `~/.claude/projects/-home-adam-github-agent-kit--worktrees-feat-ak-wave-wait--superpowers-sdd-2026-10-23-ak-wave-wait-spike-claude/2d7467c6-ecdf-4f73-87a0-cc1313b83326.jsonl`.
- Check: `ps -p 2713961` (alive?) and `<scratch>/hook-log.jsonl` for a `<task-notification>` line ("Background command ... completed"
  or a killed/timeout status) with its timestamp. The model was asked for the maximum timeout; whether the harness applies a
  default shorter limit to a background Bash will show only at the end.

### Cleanup
Killed `ak-spike-s1`, `ak-spike-s1b`, `ak-spike-s1c`. Left running: `ak-spike-s4`. (`ak-spike-s2`, `ak-spike-s2b` belong to another
agent's Codex spike and were not touched.)

## Codex report (S2, S3)

## Task 0 (Codex half): S2 and S3 results

Codex CLI 0.164.0, interactive TUI in tmux, `gpt-6-luna` low, bypass sandbox. Scratch: `spike-codex/`. Rollouts are under `~/.codex/sessions/2026/10/23/` (dir date is local time; record timestamps are UTC).

### S2: how long can the Codex root block in the shell without a model turn?

Question: can the root stay blocked >= 30 min in one stretch (path A), or must it loop (path B)?

#### What the harness gives the model
The shell is reached through an `exec` JS cell: `tools.exec_command({cmd, yield_time_ms})`, `tools.write_stdin({session_id, yield_time_ms})`. A separate top-level tool `wait({cell_id, yield_time_ms, terminate})` resumes a yielded `exec` cell.

#### Run 1: `sleep 900; echo done`, plain prompt
Model chose `yield_time_ms:30000` itself. Rollout: 30 tool calls (1 exec_command, 29 write_stdin), one model turn per call. Gaps between consecutive calls 30.7 to 31.5 s. Done at 03:00:13 (started 02:45:14). So 900 s costs about 30 model turns; longest stretch with no model turn is about 31 s.

#### Run 2: does a requested long yield get honored?
Prompted `exec_command` with `yield_time_ms:3600000`: returned after 30.2 s (`wall_time_seconds":30.001`). So `exec_command` and `write_stdin` inside the exec cell are clamped to 30 s, and the cell itself yields "Script running with cell ID N" after about 31 s.

#### Run 3: `wait` tool with `yield_time_ms:3600000`, `sleep 2000`
Sequence repeated 7 times: `write_stdin` (31 s, "Script running with cell ID N") then `wait cell_id=N yield_time_ms=3600000`. Every `wait` returned after 268 s of cell wall time (`wall_time_seconds":300.0` for the underlying session), not after 3600 s. Final one at 03:32:47 returned `exit_code:0, "done"`. 2000 s took about 15 tool calls (about 15 model turns). **Longest stretch with no model turn: about 300 s (a `wait` call), plus about 31 s for the write_stdin leg.**

#### Run 4: child finishing during the root's shell wait
Root spawned `child_sleep` (`sleep 60; echo child-done`, no `wait_agent`), then ran `sleep 600; echo done`. Child finished 02:47:44.943 (`task_complete`). The root's 30 s `write_stdin` poll that was in flight ended on schedule at 02:48:15.128 and the child's `FINAL_ANSWER` agent_message appeared in the root rollout at 02:48:15.147, right after the poll returned. Root shell command finished 02:56:42 (600 s after 02:46:42), `exit_code:0`. **The child's completion did not interrupt the shell wait**; it is delivered as an `agent_message` record on the root's next model turn.

#### Verdict
**Path B.** The shell/`wait` path caps a single blocking stretch at about 30 s (exec_command / write_stdin) or about 300 s (`wait`), regardless of the requested `yield_time_ms`. A blocking `ak wait` cannot hold the Codex root for 30 min without model turns. The root should loop `wait_agent timeout_ms=3600000` with `ak wait --check`. (Not tested here: whether `wait_agent` honors `timeout_ms=3600000`; one `wait_agent` with a short timeout returned "No agents completed yet" as expected.)

### S3 (Codex)

#### Where children live and how to find them
- A child has its own rollout file in the same date dir: `rollout-<local ts>-<child thread id>.jsonl`.
- Child `session_meta.payload` (line 1) holds: `id` (child thread id), `parent_thread_id`, `session_id` (= root thread id), `thread_source:"subagent"`, `agent_path` (`/root/<task_name>`), `agent_nickname`, and `source.subagent.thread_spawn.{parent_thread_id,depth,agent_path,agent_nickname}`.
- Root rollout records: `function_call spawn_agent` -> `function_call_output {"task_name":"/root/victim"}`, and `event_msg item_completed` with `item.type:"SubAgentActivity", kind:"started", agent_thread_id:<child thread id>, agent_path`. Later `kind:"completed"` or `"interrupted"` with the same `agent_thread_id`.
- The spawn `message` is `encrypted_content` in both root and child rollouts, so the prompt text cannot be grepped. Discovery must use `agent_thread_id`/`agent_path`/`parent_thread_id`, not prompt text. The child's cwd equals the root's cwd (no separate worktree unless the prompt does `cd`).

#### Final records
- Normal child: last records `item_completed AgentMessage {phase:"final_answer", text:"FINISHED"}`, `response_item message role=assistant phase=final_answer`, `token_usage_record`, then `event_msg task_complete {last_agent_message:"FINISHED", duration_ms, ...}` (last line). Root sees `SubAgentActivity kind:"completed"` and an `agent_message` `Message Type: FINAL_ANSWER ... Payload:\nFINISHED`.
- Interrupted child (`interrupt_agent`, child mid-tool call): last line `event_msg turn_aborted {"reason":"interrupted","turn_id":...,"duration_ms":34501}`, preceded by `custom_tool_call_output "aborted by user after 6.9s"` and a developer message `<turn_aborted> ...`. No `task_complete`. Root records `SubAgentActivity kind:"interrupted"` and `interrupt_agent` output `{"previous_status":"running"}`.
- Caveat: a child that already ended its turn when interrupted ends with `task_complete` and the output is `{"previous_status":{"completed":"<text>"}}`. A child that starts a background process and replies has already completed (my first "victim" did this).
- Errored child: not producible cheaply. Spawn-time errors create no child rollout at all: `spawn_agent` with bad model returns `function_call_output` text `Unknown model \`no-such-model-xyz\` for spawn_agent. Available models: ...` in the root rollout only.

#### Classification rule from the transcript tail
Last `event_msg` of the child file: `task_complete` = ended normally (text in `last_agent_message`); `turn_aborted` with `reason:"interrupted"` = killed; no terminal record yet = still running; no child file for a spawn call = spawn failed.

Fixtures (scrubbed, trimmed): `spike-codex/fixtures-codex/{child-normal,child-interrupted,root-spawn-records}.jsonl`.

### Cleanup
My tmux sessions (ak-spike-s2, s2b, s2c, s2d, s2e, s3) killed. A Codex trust prompt was accepted for the scratch dir, which Codex records in its own config; nothing else was changed. `ak-spike-s4` and the modified `tests/v2/test-plan.sh`, `v2/lib/plan.sh` in the worktree are not mine.
