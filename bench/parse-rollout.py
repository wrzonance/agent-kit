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

PROGRAM = 'parse-rollout'

# Matches a path ending in references/<name>.md or .shared/<name>.md,
# anywhere inside a shell command string -- `cat foo/references/bar.md`,
# `sed -n '1,5p' .shared/baz.md`, etc. Deliberately does not match a bare
# "*.md" outside one of those two directories (bench/README, a PR body
# quoting a filename, ...) -- see the spike this slice's six-step report
# cites for the false-positive/false-negative cases this was checked
# against before being adopted.
REFERENCE_PATH_RE = re.compile(r'(?:^|[\s"\'])((?:[\w./-]*?)(?:references|\.shared)/[\w.-]+\.md)')

TOKEN_CLASSES = ('input', 'cache_read', 'cache_write', 'output')

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


def extract_reference_hits(arguments_raw):
    """Reference paths mentioned in one function_call's arguments -- the
    arguments field is itself a JSON-encoded string (Codex's own
    convention); a {"command": [...]} shell invocation is flattened to text
    before scanning, matching the shape a real `shell` tool call takes."""
    text = arguments_raw if isinstance(arguments_raw, str) else ''
    try:
        decoded = json.loads(arguments_raw)
    except (json.JSONDecodeError, TypeError):
        decoded = None
    if isinstance(decoded, dict):
        command = decoded.get('command')
        if isinstance(command, list):
            text = ' '.join(str(part) for part in command)
        elif isinstance(command, str):
            text = command
    return REFERENCE_PATH_RE.findall(text)


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

    for rec in read_records(path):
        rtype = rec.get('type')
        payload = rec.get('payload') if isinstance(rec.get('payload'), dict) else {}

        if rtype == 'session_meta':
            actor = payload.get('originator', actor)
            model = payload.get('model', model)
        elif rtype == 'turn_context':
            model = payload.get('model', model)
            effort = payload.get('effort', effort)
        elif rtype == 'response_item' and payload.get('type') == 'function_call':
            for ref_path in extract_reference_hits(payload.get('arguments', '')):
                reference_hits[ref_path] = reference_hits.get(ref_path, 0) + 1
        elif rtype == 'event_msg' and payload.get('type') == 'token_count':
            info = payload.get('info') if isinstance(payload.get('info'), dict) else {}
            tokens['input'] += int(info.get('input_tokens', 0) or 0)
            tokens['cache_read'] += int(info.get('cached_input_tokens', 0) or 0)
            tokens['cache_write'] += int(info.get('cache_write_tokens', 0) or 0)
            tokens['output'] += int(info.get('output_tokens', 0) or 0)
        elif rtype == 'bench_trial_meta':
            trial_meta = payload

    if not actor:
        die(f'{path}: no session_meta record carries an "originator" -- cannot attribute this file to an actor')

    return {
        'actor': actor,
        'model': model,
        'effort': effort,
        'tokens': tokens,
        'reference_hits': reference_hits,
        'trial_meta': trial_meta,
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

    pricing = dict(DEFAULT_PRICING)
    if args.pricing:
        overrides = load_json_file(args.pricing, 'pricing file')
        pricing.update(overrides)
    blended_usd = compute_blended_usd(parsed, pricing)

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
        'reference_hits': reference_report,
        'wall_clock_seconds': trial_meta['wall_clock_seconds'],
        'worker_count': trial_meta['worker_count'],
        'selected_issues': trial_meta['selected_issues'],
        'chain_plan': trial_meta['chain_plan'],
        'serialization_events': trial_meta['serialization_events'],
        'retry_events': trial_meta['retry_events'],
        'exit_condition': trial_meta['exit_condition'],
        'acceptance': acceptance,
    }
    print(json.dumps(record))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
