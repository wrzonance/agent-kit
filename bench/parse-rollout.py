#!/usr/bin/env python3
"""bench/parse-rollout.py -- turn one trial's Codex session logs into one
Tier-1 ledger record (epic #152, issue #327; design doc "Instrumentation").

Usage: bench/parse-rollout.py SESSION_FILE [SESSION_FILE ...]
           [--acceptance FILE] [--pricing FILE] [--timestamp TS]

Each SESSION_FILE is one actor's ~/.codex/sessions/*.jsonl rollout for this
trial -- the orchestrator's own file, plus one file per spawned worker (a
real Tier-1 trial container writes one such file per Codex process it runs;
see bench/run-trial.sh). Prints exactly one JSON object -- one complete
ledger row, ready to append to bench/results/tier1.jsonl -- to stdout.

Construction decisions (no rollout schema to defer to)
--------------------------------------------------------
Codex's real ~/.codex/sessions/*.jsonl schema is not shipped as machine-
readable documentation this harness can read from inside its declared
scope, and this issue explicitly forbids running a real (paid) Codex trial
to reverse-engineer it emprically. This parser is therefore written against
a schema modelled on Codex's publicly-documented rollout shape --
{"type": "session_meta"|"turn_context"|"response_item"|"event_msg", ...}
records, tool calls as response_item/function_call, token usage as
event_msg/token_count -- and pinned exactly by the synthetic fixture this
slice ships (tests/fixtures/bench/sessions/*.jsonl). If a real trial later
shows Codex's actual field names differ, adjusting this parser to match is
explicitly an operator follow-up (see the completion report), not a defect
in the dry-run harness this slice delivers.

One field this schema adds beyond anything Codex itself emits:
"bench_trial_meta". The orchestration-level facts the design doc asks for
-- selected issue set, chain plan, serialization/retry events, wall clock,
worker count, exit condition, the assigned effort/model tier, whether this
trial is the drift-control arm -- are properties of the TRIAL as the
harness drove it, not something reliably recoverable by pattern-matching an
LLM's own tool-call transcript (a chain plan lives in gh's blocked_by graph
and the harness's own dispatch log, not in prose the model happened to
emit). bench/run-trial.sh therefore appends one bench_trial_meta record to
the orchestrator's session file after the trial completes, and this parser
treats it as ground truth for exactly those fields -- while every token,
model/effort, and reference-hit figure below is still derived purely from
parsing the real per-turn Codex records, never from bench_trial_meta.
"""
import argparse
import json
import re
import sys
from datetime import datetime, timezone
from efficiency import build_efficiency

PROGRAM = 'parse-rollout'

# Matches a path ending in references/<name>.md or .shared/<name>.md,
# anywhere inside a shell command string -- `cat foo/references/bar.md`,
# `sed -n '1,5p' .shared/baz.md`, etc. Deliberately does not match a bare
# "*.md" outside one of those two directories (bench/README, a PR body
# quoting a filename, ...) -- see the spike this slice's six-step report
# cites for the false-positive/false-negative cases this was checked
# against before being adopted.
REFERENCE_PATH_RE = re.compile(r'(?:^|[\s"\'])((?:[\w./-]*?)(?:references|\.shared)/[\w.-]+\.md)')
PROSE_READ_RE = re.compile(r'(?:^|[\s;&|])(?:cat|head|tail|sed|awk|grep|rg|less|more)(?=\s)')
CUSTOM_EXEC_CMD_RE = re.compile(
    r'''tools\.exec_command\s*\(\s*\{[^{}]*?\bcmd\s*:\s*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)')''',
    re.DOTALL)
INJECTED_SKILL_MARKER = 'agentkit invocation boundary: explicit workflow delivery'

TOKEN_CLASSES = ('input', 'cache_read', 'cache_write', 'output')
CALL_TYPES = ('function_call', 'custom_tool_call')
CALL_OUTPUT_TYPES = ('function_call_output', 'custom_tool_call_output')
PRE_SPAWN_CATEGORIES = (
    'skill_reference_prose', 'repository_source_docs', 'issue_forge_data',
    'tool_interface_discovery', 'unknown_other',
)

# PLACEHOLDER per-1K-token USD rates, keyed by model id -- NOT live provider
# pricing. This table exists so blended_usd is a deterministic,
# spot-checkable number for this dry-run harness and its tests. Before any
# real trial, replace it via --pricing with the model's actual current price
# sheet; see bench/README's Tier-1 stanza and security.md's guidance against
# trusting a fetched pricing claim without independent verification (which
# is exactly why this parser does not attempt to fetch pricing itself).
DEFAULT_PRICING = {
    'gpt-5.6-luna': {'input': 0.003, 'cache_read': 0.0006, 'cache_write': 0.00375, 'output': 0.015},
}

REQUIRED_TRIAL_META_KEYS = (
    'run_id', 'plugin_sha', 'fixture_version', 'assigned_model', 'assigned_effort',
    'is_drift_control', 'selected_issues', 'chain_plan', 'serialization_events',
    'retry_events', 'worker_count', 'wall_clock_seconds', 'exit_condition',
)

PLUGIN_SHA_RE = re.compile(r'^[0-9a-f]{40}$')
EXIT_CONDITIONS = ('complete', 'partial', 'timeout')


def die(message):
    print(f'{PROGRAM}: {message}', file=sys.stderr)
    sys.exit(1)


def empty_token_bucket():
    return dict.fromkeys(TOKEN_CLASSES, 0)


def record_timestamp(record):
    raw = record.get('timestamp')
    if not isinstance(raw, str):
        payload = record.get('payload')
        raw = payload.get('timestamp') if isinstance(payload, dict) else None
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError):
        return None


def decoded_call_arguments(payload):
    raw = payload.get('arguments', payload.get('input', ''))
    if isinstance(raw, dict):
        return raw
    try:
        decoded = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return {}
    return decoded if isinstance(decoded, dict) else {}


def is_poll_call(payload):
    name = payload.get('name', '').rsplit('.', 1)[-1]
    if name in {'wait_agent', 'wait'}:
        return True
    return name == 'write_stdin' and not decoded_call_arguments(payload).get('chars')


def call_command_text(payload):
    raw = payload.get('arguments', payload.get('input', ''))
    decoded = decoded_call_arguments(payload)
    command = decoded.get('cmd', decoded.get('command'))
    if isinstance(command, list):
        return ' '.join(str(part) for part in command)
    if isinstance(command, str):
        return command
    custom_commands = custom_exec_commands(payload)
    if len(custom_commands) == 1:
        return custom_commands[0]
    return raw if isinstance(raw, str) else ''


def is_log_read(payload):
    command = call_command_text(payload)
    return '.agent/logs/' in command and bool(re.search(r'(?:^|[\s;&|])(?:cat|tail|sed)(?=\s)', command))


def custom_exec_commands(payload):
    raw = payload.get('input', '')
    if payload.get('type') != 'custom_tool_call' or not isinstance(raw, str):
        return []
    commands = []
    for double_quoted, single_quoted in CUSTOM_EXEC_CMD_RE.findall(raw):
        try:
            if double_quoted:
                commands.append(json.loads(f'"{double_quoted}"'))
            else:
                value = re.sub(r"\\(['\\])", r"\1", single_quoted)
                if re.search(r"\\(?!['\\])", value):
                    return []
                commands.append(value)
        except (json.JSONDecodeError, TypeError):
            return []
    return commands


def grep_has_noncontent_mode(options):
    index = 0
    while index < len(options):
        token = options[index]
        if token in {'--files-with-matches', '--count'}:
            return True
        if token in {'-e', '-f', '--regexp', '--file'}:
            index += 2
            continue
        if token.startswith('-') and not token.startswith('--'):
            flags = token[1:]
            for offset, flag in enumerate(flags):
                if flag in {'e', 'f'}:
                    if offset == len(flags) - 1:
                        index += 1
                    break
                if flag in {'l', 'c'}:
                    return True
        index += 1
    return False


def command_reads_prose(command):
    for raw_segment in re.split(r'(?:&&|\|\||[;\n]|(?<![|])\|(?!\|)|(?<!&)&(?!&))', command):
        segment = raw_segment.strip()
        if '.md' not in segment or not PROSE_READ_RE.search(segment):
            continue
        words = segment.split()
        options = words[1:]
        if '--' in options:
            options = options[:options.index('--')]
        if words and words[0] == 'rg' and '--files' in options:
            continue
        if words and words[0] == 'grep' and grep_has_noncontent_mode(options):
            continue
        return True
    return False


def command_has_mixed_output(command):
    return bool(re.search(r'(?:&&|\|\||[;\n]|(?<![|])\|(?!\|)|(?<!&)&(?!&))', command))


def mentions_unparsed_prose_read(raw):
    return (isinstance(raw, str) and '.md' in raw and
            bool(re.search(r'\b(?:cat|head|tail|sed|awk|grep|rg|less|more)\b', raw)))


def prose_read_kind(payload):
    call_type = payload.get('type')
    call_name = payload.get('name', '').rsplit('.', 1)[-1].lower()
    if call_type == 'custom_tool_call':
        if call_name != 'exec':
            return 'none'
        raw = payload.get('input', '')
        commands = custom_exec_commands(payload)
        invocation_count = len(re.findall(r'tools\.exec_command\s*\(', raw)) if isinstance(raw, str) else 0
        if invocation_count != len(commands):
            return 'unavailable' if mentions_unparsed_prose_read(raw) else 'none'
        if len(commands) > 1:
            return 'unavailable' if any(command_reads_prose(command) for command in commands) else 'none'
        if len(commands) != 1:
            return 'unavailable' if mentions_unparsed_prose_read(payload.get('input')) else 'none'
        if not command_reads_prose(commands[0]):
            return 'none'
        return 'unavailable' if command_has_mixed_output(commands[0]) else 'exact'
    elif call_name not in {'exec_command', 'shell', 'bash'}:
        return 'none'
    command = call_command_text(payload)
    if not command_reads_prose(command):
        return 'none'
    return 'unavailable' if command_has_mixed_output(command) else 'exact'


def message_texts(payload):
    content = payload.get('content')
    if isinstance(content, str):
        return [content]
    if not isinstance(content, list):
        return []
    return [part['text'] for part in content
            if isinstance(part, dict) and isinstance(part.get('text'), str)]


def injected_skill_chars(payload):
    total = 0
    for value in message_texts(payload):
        marker = value.find(INJECTED_SKILL_MARKER)
        if marker < 0:
            continue
        body = value.find('\n\n---\n', marker)
        if body >= 0:
            total += len(value[body + 2:])
    return total


def output_chars(payload):
    output = payload.get('output', '')
    if isinstance(output, str):
        return len(output)
    if isinstance(output, list):
        return sum(len(part.get('text', '')) for part in output
                   if isinstance(part, dict) and isinstance(part.get('text'), str))
    return 0


def is_empty_poll_output(payload):
    output = payload.get('output', '')
    if output in ('', [], {}):
        return True
    decoded = output
    if isinstance(output, str):
        try:
            decoded = json.loads(output)
        except json.JSONDecodeError:
            decoded = None
    if isinstance(decoded, dict) and isinstance(decoded.get('timed_out'), bool):
        return decoded['timed_out']
    try:
        text = json.dumps(output, sort_keys=True).lower()
    except (TypeError, ValueError):
        return False
    return any(marker in text for marker in ('timed out', 'timeout', 'no activity', 'no updates'))


def is_wait_heartbeat(payload):
    texts = message_texts(payload)
    return len(texts) == 1 and re.fullmatch(
        r'Heartbeat: outstanding=\S+ deadline=\S+', texts[0]) is not None


def is_verification_launch(payload):
    command = call_command_text(payload)
    helper = r'(?:^|\s)["\']?(?:[^\s"\']*/)?agent-run\.sh["\']?(?=\s|$)'
    return (bool(re.search(helper, command)) and
            bool(re.search(r'(?:^|\s)--cmd(?:=|\s)', command)) and
            bool(re.search(r'(?:^|\s)--summary(?=\s|$)', command)))


def runtime_ids_from_output(payload):
    output = payload.get('output')
    if isinstance(output, str):
        try:
            output = json.loads(output)
        except json.JSONDecodeError:
            return set()
    if not isinstance(output, dict):
        return set()
    ids = set()
    for key in ('session_id', 'cell_id'):
        value = output.get(key)
        if ((isinstance(value, str) and value) or
                (isinstance(value, int) and not isinstance(value, bool))):
            ids.add((key, value))
    return ids


def runtime_id_from_arguments(arguments):
    for key in ('session_id', 'cell_id'):
        value = arguments.get(key)
        if ((isinstance(value, str) and value) or
                (isinstance(value, int) and not isinstance(value, bool))):
            return key, value
    return None


def token_count_input(payload):
    info = payload.get('info') if isinstance(payload.get('info'), dict) else {}
    usage = info.get('last_token_usage') if isinstance(info.get('last_token_usage'), dict) else info
    value = usage.get('input_tokens')
    return int(value) if isinstance(value, (int, float)) and value >= 0 else None


def merge_polling_report(actors):
    turns = sum(actor['polling']['turns'] for actor in actors)
    inputs_complete = all(actor['polling']['inputs_complete'] for actor in actors)
    poll_input_tokens = sum(actor['polling']['input_tokens'] for actor in actors) if inputs_complete else None
    intervals = [interval for actor in actors for interval in actor['polling']['intervals']]
    intervals_complete = all(actor['polling']['intervals_complete'] for actor in actors)
    wait_seconds = None
    if intervals_complete:
        elapsed = 0.0
        current_end = None
        for start, end in sorted(intervals):
            if end < start:
                intervals_complete = False
                break
            if current_end is None or start > current_end:
                elapsed += end - start
                current_end = end
            elif end > current_end:
                elapsed += end - current_end
                current_end = end
        if intervals_complete:
            wait_seconds = round(elapsed, 3)
    rate = round(turns / (wait_seconds / 60), 3) if wait_seconds else None
    return turns, poll_input_tokens, wait_seconds, rate


def merge_wait_collection_report(actors):
    roots = [actor for actor in actors if actor['actor'] == 'orchestrator']
    resumptions = sum(actor['polling']['empty_wait_resumptions'] for actor in roots)
    non_wait_calls = sum(actor['polling']['non_wait_calls_between_empty_waits'] for actor in roots)
    commentary = sum(actor['polling']['commentary_messages_between_empty_waits'] for actor in roots)
    heartbeats = sum(actor['polling']['heartbeats'] for actor in roots)
    if not roots or not resumptions:
        status = 'unavailable'
    elif non_wait_calls or commentary:
        status = 'fail'
    else:
        status = 'pass'
    return {
        'status': status,
        'empty_wait_resumptions': resumptions,
        'non_wait_calls_between_empty_waits': non_wait_calls,
        'commentary_messages_between_empty_waits': commentary,
        'heartbeats': heartbeats,
    }


def function_call_text(arguments_raw):
    if isinstance(arguments_raw, str):
        text = arguments_raw
    else:
        text = ''
    try:
        decoded = json.loads(arguments_raw) if isinstance(arguments_raw, str) else arguments_raw
    except (json.JSONDecodeError, TypeError):
        decoded = None
    if isinstance(decoded, dict):
        command = decoded.get('command')
        if isinstance(command, list):
            text = ' '.join(str(part) for part in command)
        elif isinstance(command, str):
            text = command
        else:
            text = ' '.join(str(value) for value in decoded.values())
    elif isinstance(decoded, list):
        text = ' '.join(str(value) for value in decoded)
    return text


def call_arguments(payload):
    return payload.get('arguments', payload.get('input', ''))


def extract_reference_hits(arguments_raw):
    """Reference paths mentioned in one function call's flattened argv."""
    text = function_call_text(arguments_raw)
    return REFERENCE_PATH_RE.findall(text)


def pre_spawn_timestamp(record):
    raw = record.get('timestamp')
    payload = record.get('payload') if isinstance(record.get('payload'), dict) else {}
    raw = raw or payload.get('timestamp')
    if not isinstance(raw, str):
        return None
    try:
        return datetime.fromisoformat(raw.replace('Z', '+00:00'))
    except ValueError:
        return None


def is_spawn_call(payload):
    name = str(payload.get('name', '')).lower()
    return (payload.get('type') in CALL_TYPES
            and re.search(r'(^|[._-])spawn_agent$', name) is not None)


def classify_pre_spawn_call(payload):
    name = str(payload.get('name', '')).lower()
    text = function_call_text(call_arguments(payload)).lower()
    matches = []
    if re.search(r'\bgh\s|/issues/|/pulls/|project item-', text):
        matches.append('issue_forge_data')
    if ('all_tools' in text
            or any(marker in name for marker in ('tool_search', 'list_mcp', 'list_tools'))):
        matches.append('tool_interface_discovery')
    if re.search(r'(references/|\.shared/)[^\s"\']+\.md\b|(^|[/\s])skill\.md\b', text):
        matches.append('skill_reference_prose')
    if re.search(r'(^|[ /])(agents|claude)\.md\b|\.(py|sh|js|ts|json|ya?ml)\b', text):
        matches.append('repository_source_docs')
    if len(matches) == 1:
        return matches[0], False
    return 'unknown_other', len(matches) > 1


def stable_call_id(value):
    return value if ((isinstance(value, str) and value) or
                     (isinstance(value, int) and not isinstance(value, bool))) else None


def item_payload(record):
    if record.get('type') in (*CALL_TYPES, *CALL_OUTPUT_TYPES, 'message'):
        return record
    return record.get('payload') if isinstance(record.get('payload'), dict) else {}


def captured_text_evidence(value):
    if isinstance(value, str):
        return len(value), True
    if isinstance(value, list):
        parts = [captured_text_evidence(item) for item in value]
        return sum(length for length, _ in parts), all(complete for _, complete in parts)
    if isinstance(value, dict):
        text_keys = ('text', 'content', 'output')
        parts = [captured_text_evidence(value[key]) for key in text_keys if key in value]
        unknown_keys = set(value) - set(text_keys) - {'type'}
        has_text_shape = bool(parts) or not value
        return (sum(length for length, _ in parts),
                has_text_shape and not unknown_keys and all(complete for _, complete in parts))
    return 0, value is None


def captured_text_length(value):
    return captured_text_evidence(value)[0]


def collect_pre_spawn_chars(records):
    counts = dict.fromkeys(PRE_SPAWN_CATEGORIES, 0)
    call_categories = {}
    has_text = False
    missing_attribution = False
    for rec in records:
        payload = item_payload(rec)
        if payload.get('type') in CALL_TYPES:
            call_id = stable_call_id(payload.get('call_id'))
            if call_id is not None:
                category, ambiguous = classify_pre_spawn_call(payload)
                if call_id in call_categories or ambiguous:
                    category = 'unknown_other'
                    missing_attribution = True
                call_categories[call_id] = category
            else:
                missing_attribution = True
        elif payload.get('type') in CALL_OUTPUT_TYPES:
            length, output_complete = captured_text_evidence(payload.get('output'))
            call_id = stable_call_id(payload.get('call_id'))
            category = call_categories.get(call_id, 'unknown_other')
            missing_attribution = missing_attribution or not output_complete or (
                length > 0 and call_id not in call_categories)
            counts[category] += length
            has_text = has_text or length > 0
        elif payload.get('type') == 'message':
            length = captured_text_length(payload.get('content'))
            injected = min(injected_skill_chars(payload), length)
            counts['skill_reference_prose'] += injected
            counts['unknown_other'] += length - injected
            has_text = has_text or length > 0
    return counts, has_text, missing_attribution


def elapsed_seconds(start_record, end_record):
    start = pre_spawn_timestamp(start_record)
    end = pre_spawn_timestamp(end_record)
    if not start or not end:
        return None
    try:
        duration = (end - start).total_seconds()
        return duration if duration >= 0 else None
    except TypeError:
        return None


def build_pre_spawn_report(records):
    spawn_index = next((i for i, rec in enumerate(records)
                        if is_spawn_call(item_payload(rec))), None)
    if spawn_index is None:
        return {'seconds': None, 'chars': None,
                'evidence': {'status': 'unavailable', 'missing': ['spawn_boundary']}}

    missing = []
    counts, has_text, missing_attribution = collect_pre_spawn_chars(records[:spawn_index])
    seconds = elapsed_seconds(records[0], records[spawn_index]) if records else None
    if seconds is None:
        missing.append('timestamps')
    if missing_attribution:
        missing.append('category_attribution')
    chars = None
    if has_text:
        chars = {**counts, 'total': sum(counts.values())}
    else:
        missing.append('category_evidence')
    status = 'complete' if not missing else ('partial' if seconds is not None or chars is not None else 'unavailable')
    return {'seconds': seconds, 'chars': chars, 'evidence': {'status': status, 'missing': missing}}


def read_records(path):
    records = []
    try:
        with open(path, encoding='utf-8') as handle:
            for lineno, raw_line in enumerate(handle, start=1):
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError as exc:
                    die(f'{path}:{lineno}: not valid JSON: {exc}')
    except OSError as exc:
        die(f'could not open session file: {path}: {exc}')
    return records


def parse_session_file(path):
    """One actor's contribution: which actor, its realised model/effort,
    summed token classes, reference-read counts, and the bench_trial_meta
    payload if this file carries one (at most the orchestrator's file
    should)."""
    actor = None
    model = None
    effort = None
    tokens = empty_token_bucket()
    reference_hits = {}
    trial_meta = None
    pending_input_tokens = None
    response_calls = []
    polling = {'turns': 0, 'input_tokens': 0, 'inputs_complete': True,
               'intervals': [], 'intervals_complete': True,
               'empty_wait_resumptions': 0,
               'non_wait_calls_between_empty_waits': 0,
               'commentary_messages_between_empty_waits': 0,
               'heartbeats': 0}
    pending_poll_calls = {}
    idle_gap = None
    collection_started_at = None
    last_heartbeat_at = None
    churn = {'resume_calls': 0, 'min_yield_ms': None, 'log_reads_between_resumes': 0}
    pending_verification_calls = set()
    verification_runtime_ids = set()
    resume_state = {}
    active_resume = None
    prose_chars_injected = 0
    prose_chars_read = 0
    pending_prose_reads = set()

    records = read_records(path)
    pre_spawn = build_pre_spawn_report(records)
    try:
        efficiency = build_efficiency(records)
    except ValueError as exc:
        die(f'{path}: {exc}')
    for rec in records:
        rtype = rec.get('type')
        payload = rec.get('payload') if isinstance(rec.get('payload'), dict) else {}
        item = item_payload(rec)

        if rtype == 'session_meta':
            actor = payload.get('originator', actor)
            model = payload.get('model', model)
        elif rtype == 'turn_context':
            model = payload.get('model', model)
            effort = payload.get('effort', effort)
        elif rtype == 'response_item' and payload.get('type') == 'message':
            prose_chars_injected += injected_skill_chars(payload)
            if idle_gap is not None and payload.get('role') == 'assistant':
                message_at = record_timestamp(rec)
                heartbeat_floor = last_heartbeat_at or collection_started_at
                if (is_wait_heartbeat(payload) and message_at is not None
                        and heartbeat_floor is not None and message_at - heartbeat_floor >= 600):
                    idle_gap['heartbeats'] += 1
                    last_heartbeat_at = message_at
                else:
                    idle_gap['commentary'] += 1
        elif (rtype == 'response_item' or rtype in CALL_TYPES) and item.get('type') in CALL_TYPES:
            for ref_path in extract_reference_hits(call_arguments(item)):
                reference_hits[ref_path] = reference_hits.get(ref_path, 0) + 1
            poll_call = is_poll_call(item)
            if idle_gap is not None:
                if poll_call:
                    polling['empty_wait_resumptions'] += 1
                    polling['non_wait_calls_between_empty_waits'] += idle_gap['non_wait_calls']
                    polling['commentary_messages_between_empty_waits'] += idle_gap['commentary']
                    polling['heartbeats'] += idle_gap['heartbeats']
                    idle_gap = None
                else:
                    idle_gap['non_wait_calls'] += 1
            if pending_input_tokens is None:
                response_calls.append(poll_call)
            elif poll_call:
                polling['input_tokens'] += pending_input_tokens

            call_name = item.get('name', '').rsplit('.', 1)[-1]
            arguments = decoded_call_arguments(item)
            call_id = item.get('call_id')
            prose_kind = prose_read_kind(item)
            if prose_kind == 'unavailable':
                prose_chars_read = None
            elif prose_kind == 'exact' and isinstance(call_id, str) and call_id:
                pending_prose_reads.add(call_id)
            elif prose_kind == 'exact':
                prose_chars_read = None
            if is_verification_launch(item) and isinstance(call_id, str) and call_id:
                pending_verification_calls.add(call_id)
            if call_name == 'write_stdin' and not arguments.get('chars'):
                resume_key = runtime_id_from_arguments(arguments)
                active_resume = None
                if resume_key in verification_runtime_ids:
                    slot = resume_state.setdefault(resume_key, {'seen': False, 'pending_reads': 0})
                    if slot['seen']:
                        churn['log_reads_between_resumes'] += slot['pending_reads']
                    slot.update(seen=True, pending_reads=0)
                    active_resume = resume_key
                    churn['resume_calls'] += 1
                    yield_ms = arguments.get('yield_time_ms')
                    if isinstance(yield_ms, int) and yield_ms >= 0:
                        current = churn['min_yield_ms']
                        churn['min_yield_ms'] = yield_ms if current is None else min(current, yield_ms)
            elif active_resume is not None and is_log_read(item):
                resume_state[active_resume]['pending_reads'] += 1
            if poll_call:
                polling['turns'] += 1
                started = record_timestamp(rec)
                if started is None:
                    polling['intervals_complete'] = False
                else:
                    call_id = item.get('call_id')
                    if not isinstance(call_id, str) or not call_id or call_id in pending_poll_calls:
                        polling['intervals_complete'] = False
                    else:
                        pending_poll_calls[call_id] = started
            pending_input_tokens = None
        elif (rtype == 'response_item' or rtype in CALL_OUTPUT_TYPES) and item.get('type') in CALL_OUTPUT_TYPES:
            call_id = item.get('call_id')
            if isinstance(call_id, str) and call_id in pending_prose_reads:
                if prose_chars_read is not None:
                    prose_chars_read += output_chars(item)
                pending_prose_reads.remove(call_id)
            if isinstance(call_id, str) and call_id in pending_verification_calls:
                verification_runtime_ids.update(runtime_ids_from_output(item))
                pending_verification_calls.remove(call_id)
            if isinstance(call_id, str) and call_id in pending_poll_calls:
                ended = record_timestamp(rec)
                if is_empty_poll_output(item):
                    if collection_started_at is None:
                        collection_started_at = pending_poll_calls[call_id]
                    idle_gap = {'non_wait_calls': 0, 'commentary': 0, 'heartbeats': 0}
                else:
                    idle_gap = None
                    collection_started_at = None
                    last_heartbeat_at = None
                if ended is None:
                    polling['intervals_complete'] = False
                else:
                    polling['intervals'].append((pending_poll_calls[call_id], ended))
                del pending_poll_calls[call_id]
        elif rtype == 'event_msg' and payload.get('type') == 'token_count':
            info = payload.get('info') if isinstance(payload.get('info'), dict) else {}
            tokens['input'] += int(info.get('input_tokens', 0) or 0)
            tokens['cache_read'] += int(info.get('cached_input_tokens', 0) or 0)
            tokens['cache_write'] += int(info.get('cache_write_tokens', 0) or 0)
            tokens['output'] += int(info.get('output_tokens', 0) or 0)
            usage_input = token_count_input(payload)
            if response_calls:
                if any(response_calls) and (not all(response_calls) or usage_input is None):
                    polling['inputs_complete'] = False
                elif all(response_calls):
                    polling['input_tokens'] += usage_input
                response_calls.clear()
            else:
                pending_input_tokens = usage_input
        elif rtype == 'bench_trial_meta':
            trial_meta = payload

    if not actor:
        die(f'{path}: no session_meta record carries an "originator" -- cannot attribute this file to an actor')

    if pending_poll_calls:
        polling['intervals_complete'] = False
    if pending_prose_reads:
        prose_chars_read = None
    if any(response_calls):
        polling['inputs_complete'] = False

    return {
        'actor': actor,
        'model': model,
        'effort': effort,
        'tokens': tokens,
        'reference_hits': reference_hits,
        'pre_spawn': pre_spawn,
        'trial_meta': trial_meta,
        'efficiency': efficiency,
        'polling': polling,
        'verification_churn': churn,
        'prose_chars_injected': prose_chars_injected,
        'prose_chars_read': prose_chars_read,
    }


def merge_trial_meta(parsed_files, session_paths):
    metas = [(path, p['trial_meta']) for path, p in zip(session_paths, parsed_files) if p['trial_meta'] is not None]
    if not metas:
        die('no session file carries a bench_trial_meta record -- bench/run-trial.sh appends one to the '
            'orchestrator file after every trial; without it this record cannot be attributed to a run')
    if len(metas) > 1:
        die('more than one session file carries a bench_trial_meta record -- exactly one (the orchestrator\'s) '
            f'should: {", ".join(path for path, _ in metas)}')
    path, meta = metas[0]
    missing = [key for key in REQUIRED_TRIAL_META_KEYS if key not in meta]
    if missing:
        die(f'{path}: bench_trial_meta is missing required key(s): {", ".join(missing)}')
    if not PLUGIN_SHA_RE.match(meta['plugin_sha']):
        die(f'{path}: bench_trial_meta.plugin_sha is not a 40-character lowercase hex SHA: {meta["plugin_sha"]!r}')
    if meta['exit_condition'] not in EXIT_CONDITIONS:
        die(f'{path}: bench_trial_meta.exit_condition must be one of {EXIT_CONDITIONS}: {meta["exit_condition"]!r}')
    return meta


def realised_identity(actors):
    """The (model, effort) pair actually used, judged from worker sessions
    when any exist (the design doc's effort tiers govern AGENT_WORKER_EFFORT,
    i.e. the workers), falling back to the orchestrator's own turn_context
    when the trial ran with no spawned workers at all (spawn unavailable)."""
    workers = [a for a in actors if a['actor'] != 'orchestrator']
    pool = workers if workers else [a for a in actors if a['actor'] == 'orchestrator']
    pairs = sorted({(a['model'], a['effort']) for a in pool})
    return pairs


def build_token_report(actors):
    orchestrator = empty_token_bucket()
    workers = {}
    total = empty_token_bucket()
    for a in actors:
        bucket = a['tokens']
        total = {k: total[k] + bucket[k] for k in TOKEN_CLASSES}
        if a['actor'] == 'orchestrator':
            orchestrator = {k: orchestrator[k] + bucket[k] for k in TOKEN_CLASSES}
        else:
            existing = workers.setdefault(a['actor'], empty_token_bucket())
            workers[a['actor']] = {k: existing[k] + bucket[k] for k in TOKEN_CLASSES}
    return {'orchestrator': orchestrator, 'workers': workers, 'total': total}


def build_reference_report(actors):
    all_paths = sorted({p for a in actors for p in a['reference_hits']})
    actor_ids = [a['actor'] for a in actors]
    report = {}
    for ref_path in all_paths:
        entry = {'orchestrator': 0, 'workers': {}}
        for a in actors:
            count = a['reference_hits'].get(ref_path, 0)
            if a['actor'] == 'orchestrator':
                entry['orchestrator'] = count
            elif a['actor'] in actor_ids:
                entry['workers'][a['actor']] = count
        report[ref_path] = entry
    return report


def compute_blended_usd(actors, pricing):
    total = 0.0
    for a in actors:
        model = a['model']
        if model is None:
            die(f'actor {a["actor"]} has no resolved model id -- cannot price its tokens')
        rates = pricing.get(model)
        if rates is None:
            die(f'no pricing entry for model {model!r} -- pass --pricing with a rate for it '
                '(see bench/parse-rollout.py DEFAULT_PRICING for the expected shape)')
        for token_class in TOKEN_CLASSES:
            total += (a['tokens'][token_class] / 1000.0) * rates[token_class]
    return round(total, 6)


def load_json_file(path, what):
    try:
        with open(path, encoding='utf-8') as handle:
            return json.load(handle)
    except OSError as exc:
        die(f'could not read {what}: {path}: {exc}')
    except json.JSONDecodeError as exc:
        die(f'{path}: not valid JSON ({what}): {exc}')


def parse_args(argv):
    parser = argparse.ArgumentParser(prog=PROGRAM, add_help=True)
    parser.add_argument('session_files', nargs='+', metavar='SESSION_FILE')
    parser.add_argument('--acceptance', metavar='FILE',
                         help='run-accept.sh JSON output ({results, score, total}); embedded verbatim '
                              'under "acceptance". Omit only when scoring is not yet available.')
    parser.add_argument('--pricing', metavar='FILE',
                         help='JSON {model: {input, cache_read, cache_write, output}} $/1K-token rate '
                              'overrides; unset models fall back to DEFAULT_PRICING.')
    parser.add_argument('--timestamp', metavar='TS',
                         help='override measured_at (ISO-8601 UTC, e.g. 2026-08-20T00:00:00Z); default: now')
    # argparse's own usage/error exit code is 2, matching this repo's
    # convention (bench/tier0.sh: usage errors exit 2, runtime failures exit
    # 1) -- nothing further to do here, but documented so a reader does not
    # have to trust argparse's default silently.
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)

    parsed = [parse_session_file(path) for path in args.session_files]
    trial_meta = merge_trial_meta(parsed, args.session_files)

    pairs = realised_identity(parsed)
    assigned = (trial_meta['assigned_model'], trial_meta['assigned_effort'])
    void = False
    void_reasons = []
    if len(pairs) > 1:
        void = True
        void_reasons.append(f'workers disagree on realised (model, effort): {pairs}')
    realised_model, realised_effort = (pairs[0] if pairs else (None, None))
    if pairs and pairs[0] != assigned:
        void = True
        void_reasons.append(f'realised {pairs[0]} != assigned {assigned}')

    token_report = build_token_report(parsed)
    reference_report = build_reference_report(parsed)
    pre_spawn = next(a['pre_spawn'] for a in parsed if a['trial_meta'] is not None)

    pricing = dict(DEFAULT_PRICING)
    if args.pricing:
        overrides = load_json_file(args.pricing, 'pricing file')
        pricing.update(overrides)
    blended_usd = compute_blended_usd(parsed, pricing)
    poll_turns, poll_input_tokens, wait_seconds, requests_per_wait_minute = merge_polling_report(parsed)
    wait_collection = merge_wait_collection_report(parsed)
    workers = [actor for actor in parsed if actor['actor'] != 'orchestrator']

    acceptance = None
    if args.acceptance:
        acceptance = load_json_file(args.acceptance, 'acceptance file')

    timestamp = args.timestamp
    if not timestamp:
        timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

    record = {
        'plugin_sha': trial_meta['plugin_sha'],
        'fixture_version': trial_meta['fixture_version'],
        'model': trial_meta['assigned_model'],
        'effort': trial_meta['assigned_effort'],
        'measured_at': timestamp,
        'run_id': trial_meta['run_id'],
        'is_drift_control': bool(trial_meta['is_drift_control']),
        'model_realised': realised_model,
        'effort_realised': realised_effort,
        'void': void,
        'void_reasons': void_reasons,
        'tokens': token_report,
        'blended_usd': blended_usd,
        'poll_turns': poll_turns,
        'poll_input_tokens': poll_input_tokens,
        'wait_seconds': wait_seconds,
        'requests_per_wait_minute': requests_per_wait_minute,
        'wait_collection': wait_collection,
        'worker_resume_calls': {a['actor']: a['verification_churn']['resume_calls'] for a in workers},
        'worker_min_yield_ms': {a['actor']: a['verification_churn']['min_yield_ms'] for a in workers},
        'log_reads_between_resumes': {
            a['actor']: a['verification_churn']['log_reads_between_resumes'] for a in workers
        },
        'reference_hits': reference_report,
        'pre_spawn_seconds': pre_spawn['seconds'],
        'pre_spawn_chars': pre_spawn['chars'],
        'pre_spawn_evidence': pre_spawn['evidence'],
        'wall_clock_seconds': trial_meta['wall_clock_seconds'],
        'worker_count': trial_meta['worker_count'],
        'selected_issues': trial_meta['selected_issues'],
        'chain_plan': trial_meta['chain_plan'],
        'serialization_events': trial_meta['serialization_events'],
        'retry_events': trial_meta['retry_events'],
        'exit_condition': trial_meta['exit_condition'],
        'acceptance': acceptance,
        'dynamic_efficiency': {
            'schema_version': 1,
            'actors': [{'actor': a['actor'], 'model': a['model'], 'effort': a['effort'],
                        'prose_chars_injected': a['prose_chars_injected'],
                        'prose_chars_read': a['prose_chars_read'],
                        **a['efficiency']} for a in parsed],
        },
    }
    print(json.dumps(record))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
