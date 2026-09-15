"""Dynamic efficiency v1; executable input example: tests/fixtures/bench/efficiency.jsonl.

Native call IDs measure requests; harness annotations establish semantic facts.
Coverage is explicit: incomplete counts are observations, never extrapolations.
Model-turn tokens mean input + output (cached input counted once), not user tasks.
Checkpoint evidence must cover the complete required acceptance set for that tree.
Annotations are supplied by the trace importer, never inferred from terminal prose.
"""
from collections import Counter
import json
from efficiency_native import infer_call

TAGS = {'help', 'path_error', 'source_read', 'source_grep', 'reference_read',
        'interface_recovery', 'hook_refusal', 'supported_rewrite', 'full_suite',
        'verification_reuse', 'implementation_edit'}
DISCOVERY = {'help', 'path_error', 'source_read', 'source_grep', 'reference_read', 'interface_recovery'}
GROUPS = {'calls', 'classifications', 'model_turns', 'checkpoints', 'policies'}
RETRIES = {'justified_transient', 'unchanged_deterministic', 'unknown'}
ACTIVITIES = {'execution', 'polling', 'unknown'}
EXCLUSIONS = {'none', 'test_fixture', 'compaction_recovery'}


def require(condition, message):
    if not condition:
        raise ValueError(f'efficiency: {message}')


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def integer(value):
    return type(value) is int and value >= 0


def strings(value):
    return isinstance(value, list) and all(nonempty(v) for v in value)


def choice(value, values):
    return isinstance(value, str) and value in values


def metadata(payload):
    require(type(payload.get('schema_version')) is int and payload['schema_version'] == 1, 'unsupported schema_version')
    require(choice(payload.get('role'), {'root', 'leaf', 'controller', 'unknown'}), 'invalid role')
    require(choice(payload.get('source'), {'complete', 'incomplete', 'sampled'}), 'invalid source')
    coverage = payload.get('coverage', [])
    require(strings(coverage) and set(coverage) <= GROUPS, 'invalid coverage')
    require(strings(payload.get('required_acceptance', [])), 'invalid required_acceptance')
    activation = payload.get('activation', {'status': 'unknown', 'version': None})
    require(isinstance(activation, dict), 'activation must be an object')
    require(choice(activation.get('status'), {'active', 'inactive', 'unknown'}), 'invalid activation status')
    require(activation.get('version') is None or nonempty(activation['version']), 'invalid activation version')
    if activation['status'] == 'active':
        require(nonempty(activation.get('version')) and nonempty(activation.get('evidence')),
                'active workflow needs version and evidence')
    return {**payload, 'activation': activation}


def validate_event(payload):
    kind = payload.get('kind')
    require(choice(kind, {'call', 'model_turn', 'checkpoint', 'policy'}), 'invalid event kind')
    require(nonempty(payload.get('call_id' if kind == 'call' else 'id')), f'{kind} needs identity')
    if kind == 'model_turn':
        require(payload.get('tokens') is None or integer(payload['tokens']), 'invalid model-turn tokens')
        return
    require(nonempty(payload.get('evidence')), f'{kind} needs evidence')
    if kind == 'call':
        require(strings(payload.get('tags')) and set(payload['tags']) <= TAGS, 'invalid call tags')
        require(choice(payload.get('retry', 'unknown'), RETRIES), 'invalid retry attribution')
        require(choice(payload.get('activity', 'unknown'), ACTIVITIES), 'invalid activity')
        require(choice(payload.get('exclusion', 'none'), EXCLUSIONS), 'invalid exclusion')
        for key in ('read_key', 'tree'):
            require(key not in payload or nonempty(payload[key]), f'invalid {key}')
    elif kind == 'checkpoint':
        require(nonempty(payload.get('call_id')) and nonempty(payload.get('tree')), 'invalid checkpoint target')
        require(strings(payload.get('required')) and strings(payload.get('passed')), 'invalid acceptance IDs')
    elif kind == 'policy':
        require(type(payload.get('issue')) is int and payload['issue'] in {730, 731, 732, 733}, 'invalid policy issue')
        require(type(payload.get('correct')) is bool and type(payload.get('false_block')) is bool,
                'policy outcomes must be booleans')
        require(integer(payload.get('avoided_calls')), 'invalid avoided_calls')


def insert_unique(target, key, payload, index, cwd=None):
    require(nonempty(key), 'structured event missing identity')
    if key in target:
        require(target[key]['payload'] == payload, f'conflicting event identity {key}')
    else:
        target[key] = {'payload': payload, 'index': index, 'cwd': cwd}


def collect(records):
    data = {key: {} for key in ('calls', 'call', 'model_turn', 'checkpoint', 'policy')}
    data.update(meta=None, compactions=[], missing_calls=0)
    cwd = None
    for index, record in enumerate(records):
        require(isinstance(record, dict), 'record must be an object')
        kind, payload = record.get('type'), record.get('payload', {})
        if not isinstance(payload, dict):
            require(kind not in ('bench_efficiency_meta', 'bench_efficiency_event'), 'annotation must be an object')
            continue
        if kind == 'turn_context':
            cwd = payload.get('cwd', cwd)
            require(cwd is None or isinstance(cwd, str), 'invalid cwd')
        elif kind == 'bench_efficiency_meta':
            require(data['meta'] is None, 'duplicate metadata')
            data['meta'] = metadata(payload)
        elif kind == 'bench_efficiency_event':
            validate_event(payload)
            identity = payload.get('call_id') if payload['kind'] == 'call' else payload['id']
            insert_unique(data[payload['kind']], identity, payload, index)
        elif kind == 'response_item' and choice(payload.get('type'), {'function_call', 'custom_tool_call'}):
            require(nonempty(payload.get('name')), 'call missing tool name')
            if not nonempty(payload.get('call_id')):
                data['missing_calls'] += 1
                continue
            insert_unique(data['calls'], payload['call_id'], payload, index, cwd)
        elif kind == 'compacted' or (kind == 'event_msg' and payload.get('type') == 'context_compacted'):
            data['compactions'].append(index)
    require(set(data['call']) <= set(data['calls']), 'annotation references a missing call')
    for identity, call in data['calls'].items():
        if identity not in data['call']:
            inferred = infer_call(identity, call['payload'])
            if inferred:
                data['call'][identity] = inferred
    return data


def recovery(data, index, model_turns_complete):
    boundaries = [i for i in data['compactions'] if i < index]
    boundary = max(boundaries, default=-1)
    turns = sum(boundary < t['index'] < index for t in data['model_turn'].values())
    known = boundary < 0 or (model_turns_complete and turns > 0)
    return boundary, known and boundary >= 0 and turns <= 2, known


def activity(payload, annotation):
    if 'activity' in annotation:
        return annotation['activity']
    name = payload.get('name', '').rsplit('.', 1)[-1]
    if name in {'wait', 'wait_agent', 'sleep'}:
        return 'polling'
    if name in {'shell', 'exec_command', 'apply_patch'}:
        return 'execution'
    return 'unknown'


def count_calls(data, model_turns_complete):
    counts, commands, reads = Counter(), set(), set()
    for identity, call in data['calls'].items():
        payload = call['payload']
        annotation = data['call'].get(identity, {}).get('payload', {})
        signature = json.dumps([call['cwd'], payload.get('name'),
                                payload.get('arguments', payload.get('input'))], sort_keys=True)
        counts['duplicate_commands'] += signature in commands
        commands.add(signature)
        counts['tool_calls'] += 1
        counts[activity(payload, annotation)] += 1
        counts[annotation.get('retry', 'unknown') + '_retry'] += 1
        boundary, recovering, recovery_known = recovery(data, call['index'], model_turns_complete)
        exclusion = annotation.get('exclusion', 'none')
        if exclusion == 'none' and recovering:
            exclusion = 'compaction_recovery'
        tags = set(annotation.get('tags', []))
        if exclusion == 'none' and not recovery_known and tags & DISCOVERY:
            counts['uncertain_recovery'] += 1
        if exclusion != 'none' and tags & DISCOVERY:
            counts[exclusion] += 1
        for tag in tags:
            if exclusion == 'none' or tag not in DISCOVERY:
                counts[tag] += 1
        if exclusion == 'none' and annotation.get('read_key'):
            key = (boundary, call['cwd'], annotation['read_key'])
            counts['duplicate_reads'] += key in reads
            counts['duplicate_reference_reads'] += key in reads and 'reference_read' in tags
            reads.add(key)
    return counts


def measure(value, available, complete, denominator):
    status = 'measured' if complete else 'incomplete' if available else 'unavailable'
    return {'value': value if available or complete else None,
            'status': status, 'denominator': denominator}


def window(turns, index, before, complete):
    unknown = {'status': 'unavailable', 'turns': None, 'tokens': None}
    if index is None or not complete:
        return unknown
    chosen = [t['payload'] for t in turns if (t['index'] < index if before else t['index'] > index)]
    tokens = [t.get('tokens') for t in chosen]
    return {'status': 'measured' if all(t is not None for t in tokens) else 'incomplete',
            'turns': len(chosen), 'tokens': sum(tokens) if all(t is not None for t in tokens) else None}


def windows(data, complete):
    required = set((data['meta'] or {}).get('required_acceptance', []))
    edits = {key: data['calls'][key]['index'] for key, value in data['call'].items()
             if 'implementation_edit' in value['payload']['tags']}
    valid = []
    for checkpoint in data['checkpoint'].values():
        p = checkpoint['payload']
        edit = data['call'].get(p['call_id'], {}).get('payload', {})
        if (p['call_id'] in edits and checkpoint['index'] > edits[p['call_id']]
                and p['tree'] == edit.get('tree') and required
                and set(p['required']) == required and required <= set(p['passed'])):
            valid.append(edits[p['call_id']])
    turns = list(data['model_turn'].values())
    covered = all(complete[g] for g in ('calls', 'classifications', 'model_turns'))
    return {'before_first_edit': window(turns, min(edits.values(), default=None), True, covered),
            'after_correct_checkpoint': window(turns, min(valid, default=None), False,
                                               covered and complete['checkpoints'])}


def policies(data, complete):
    result = {}
    for issue in (730, 731, 732, 733):
        cases = [v['payload'] for v in data['policy'].values() if v['payload']['issue'] == issue]
        result[str(issue)] = {
            'status': 'measured' if cases and complete else 'incomplete' if cases else 'unavailable',
            'denominator': len(cases),
            **{out: sum(c[key] for c in cases) if cases else None
               for out, key in [('correct', 'correct'), ('false_blocks', 'false_block'),
                                ('avoided_calls', 'avoided_calls')]}}
    return result


def build_efficiency(records):
    data = collect(records)
    meta = data['meta'] or {'role': 'unknown', 'source': 'incomplete', 'coverage': [],
                            'activation': {'status': 'unknown', 'version': None}}
    complete = {g: meta['source'] == 'complete' and g in meta['coverage'] for g in GROUPS}
    complete['calls'] &= not data['missing_calls']
    complete['classifications'] &= complete['calls'] and set(data['calls']) == set(data['call'])
    counts = count_calls(data, complete['model_turns'])
    complete['classifications'] &= not counts['uncertain_recovery']
    native = {'tool_calls', 'duplicate_commands', 'execution', 'polling', 'unknown'}
    classified = TAGS | {'duplicate_reads', 'duplicate_reference_reads', 'test_fixture',
                         'compaction_recovery', 'justified_transient', 'unchanged_deterministic'}
    for name in RETRIES - {'unknown'}:
        counts[name] = counts[name + '_retry']
    metrics = {name: measure(counts[name], bool(data['calls'] if name in native else data['call']),
                             complete['calls' if name in native else 'classifications'], 'tool_calls')
               for name in sorted(native | classified)}
    metrics['model_turns'] = measure(len(data['model_turn']), bool(data['model_turn']),
                                     complete['model_turns'], 'actor_run')
    return {'role': meta['role'], 'source': meta['source'], 'activation': meta['activation'],
            'coverage': sorted(meta['coverage']), 'unidentified_calls': data['missing_calls'],
            'denominators': {'tool_calls': metrics['tool_calls'], 'model_turns': metrics['model_turns']},
            'metrics': metrics, 'windows': windows(data, complete),
            'series': {'effort_sensitive': ['help', 'path_error'],
                       'kit_sensitive': ['duplicate_reference_reads', 'source_read', 'source_grep']},
            'policies': policies(data, complete['policies'])}
