"""Synthetic public CLI regressions; no providers or real session data."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PARSER = HERE.parents[2] / 'bench' / 'parse-rollout.py'
BASE = [json.loads(line) for line in (HERE / 'sessions/orchestrator.jsonl').read_text().splitlines()]
FIXTURE = [json.loads(line) for line in (HERE / 'efficiency.jsonl').read_text().splitlines()]


def event(kind, **fields):
    return {'type': 'bench_efficiency_event', 'payload': {'kind': kind, **fields}}


class Efficiency(unittest.TestCase):
    def parse(self, events, role=None, succeeds=True):
        # Keep the established trial identity while isolating efficiency calls.
        records = [r for r in BASE if r['type'] in ('session_meta', 'bench_trial_meta', 'turn_context')]
        if role:
            records[0]['payload'] = {**records[0]['payload'], 'originator': role}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'session.jsonl'
            path.write_text(''.join(json.dumps(r) + '\n' for r in records + events))
            result = subprocess.run(['python3', str(PARSER), str(path)], capture_output=True, text=True, check=False)
        if not succeeds:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('efficiency', result.stderr)
            self.assertNotIn('Traceback', result.stderr)
            return None
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)['dynamic_efficiency']
        self.assertEqual(report['schema_version'], 1)
        return report['actors'][0]

    def test_complete_counts_and_retrospective_checkpoint(self):
        report = self.parse(FIXTURE)
        counts = report['metrics']
        for key, value in {'tool_calls': 5, 'model_turns': 2, 'duplicate_commands': 1,
                           'duplicate_reads': 1, 'help': 1, 'source_grep': 1,
                           'full_suite': 1, 'unchanged_deterministic': 1}.items():
            self.assertEqual(counts[key]['value'], value, key)
            self.assertEqual(counts[key]['status'], 'measured', key)
        self.assertEqual(report['windows']['before_first_edit']['tokens'], 100)
        self.assertEqual(report['windows']['after_correct_checkpoint']['tokens'], 50)
        self.assertEqual(report['windows']['after_correct_checkpoint']['turns'], 1)
        self.assertEqual(report['policies']['731']['avoided_calls'], 2)
        self.assertEqual(report['policies']['730']['status'], 'unavailable')
        self.assertEqual(report['role'], 'root')

    def test_wrappers_and_terminal_reflow_are_not_executions(self):
        terminal = {'type': 'terminal_snapshot', 'payload': {'text': 'helper.sh --he\nlp\nhelper.sh --help'}}
        replay = [FIXTURE[2], FIXTURE[3], terminal,
                  {'type': 'event_msg', 'payload': {'type': 'exec_command_begin', 'call_id': 'a'}}]
        self.assertEqual(self.parse(FIXTURE + replay)['metrics']['tool_calls']['value'], 5)

    def test_missing_events_and_activation_are_unknown(self):
        report = self.parse([FIXTURE[2]])
        self.assertEqual(report['activation']['status'], 'unknown')
        self.assertEqual(report['metrics']['tool_calls']['status'], 'incomplete')
        self.assertIsNone(report['metrics']['model_turns']['value'])
        self.assertIsNone(report['windows']['after_correct_checkpoint']['tokens'])
        self.assertEqual(report['role'], 'unknown')

    def test_sampled_trace_never_claims_complete_counts(self):
        events = [json.loads(json.dumps(r)) for r in FIXTURE]
        events[0]['payload']['source'] = 'sampled'
        events[0]['payload']['activation'] = {'status': 'inactive', 'version': None}
        report = self.parse(events)
        self.assertEqual(report['metrics']['tool_calls']['status'], 'incomplete')
        self.assertEqual(report['activation']['status'], 'inactive')
        self.assertIsNone(report['windows']['before_first_edit']['tokens'])

    def test_local_green_is_not_full_acceptance(self):
        events = [json.loads(json.dumps(r)) for r in FIXTURE]
        events[-2]['payload']['passed'] = ['unit']
        self.assertIsNone(self.parse(events)['windows']['after_correct_checkpoint']['turns'])
        events[-2]['payload']['passed'] = ['unit', 'acceptance']
        events[-2]['payload']['tree'] = 'different-tree'
        self.assertIsNone(self.parse(events)['windows']['after_correct_checkpoint']['turns'])

    def test_checkpoint_cannot_shrink_required_acceptance(self):
        events = [json.loads(json.dumps(r)) for r in FIXTURE]
        events[0]['payload']['required_acceptance'] = ['unit', 'acceptance']
        events[-2]['payload'].update(required=['unit'], passed=['unit'])
        self.assertIsNone(self.parse(events)['windows']['after_correct_checkpoint']['turns'])

    def test_native_discovery_ignores_embedded_test_code(self):
        commands = ['agentkit/skills/.shared/scripts/helper.sh --help',
                    'cat agentkit/skills/.shared/scripts/helper.sh',
                    'rg usage agentkit/skills/.shared/scripts/helper.sh',
                    'cat agentkit/skills/example/references/example.md',
                    'cat agentkit/skills/example/references/example.md',
                    "printf 'helper.sh --help' > tests/test-example.sh",
                    'bash tests/test-help.sh']
        events = [{'type': 'response_item', 'payload': {'type': 'function_call',
                   'call_id': str(i), 'name': 'exec_command', 'arguments': json.dumps({'cmd': command})}}
                  for i, command in enumerate(commands)]
        metrics = self.parse(events)['metrics']
        for key in ('help', 'source_read', 'source_grep', 'duplicate_reference_reads'):
            self.assertEqual(metrics[key]['value'], 1, key)
            self.assertEqual(metrics[key]['status'], 'incomplete', key)

    def test_malformed_metadata_has_no_traceback(self):
        for field, value in [('role', []), ('source', {}), ('activation', {'status': []})]:
            events = [json.loads(json.dumps(r)) for r in FIXTURE]
            events[0]['payload'][field] = value
            self.parse(events, succeeds=False)

    def test_native_paths_in_patterns_and_edits_are_not_reads(self):
        path = 'agentkit/skills/.shared/scripts/helper.sh'
        commands = [f'rg {path} README.md', f'sed -i s/old/new/ {path}',
                    f'cat --help {path}', f'rg --files {path}']
        for command in commands:
            call = {'type': 'response_item', 'payload': {'type': 'function_call',
                    'call_id': 'native', 'name': 'shell', 'arguments': json.dumps({'command': command})}}
            report = self.parse([call])
            self.assertIsNone(report['metrics']['source_read']['value'], command)
            self.assertIsNone(report['metrics']['source_grep']['value'], command)

    def test_compaction_and_test_help_excluded(self):
        events = [json.loads(json.dumps(r)) for r in FIXTURE]
        events[3]['payload']['exclusion'] = 'test_fixture'
        events.insert(1, {'type': 'compacted', 'payload': {}})
        report = self.parse(events)
        self.assertEqual(report['metrics']['help']['value'], 0)
        self.assertEqual(report['metrics']['duplicate_reads']['value'], 0)
        self.assertGreater(report['metrics']['compaction_recovery']['value'], 0)

    def test_compaction_without_turn_evidence_keeps_native_discovery(self):
        commands = ['agentkit/skills/.shared/scripts/helper.sh --help',
                    'cat agentkit/skills/.shared/scripts/helper.sh',
                    'cat agentkit/skills/example/references/example.md',
                    'cat agentkit/skills/example/references/example.md']
        calls = [{'type': 'response_item', 'payload': {'type': 'function_call',
                  'call_id': str(i), 'name': 'shell', 'arguments': json.dumps({'command': command})}}
                 for i, command in enumerate(commands)]
        for source, coverage in [('incomplete', []), ('complete', ['calls', 'classifications']),
                                 ('sampled', ['calls', 'classifications', 'model_turns']),
                                 ('complete', ['calls', 'classifications', 'model_turns'])]:
            meta = {'type': 'bench_efficiency_meta', 'payload': {
                    'schema_version': 1, 'role': 'root', 'source': source, 'coverage': coverage}}
            metrics = self.parse([meta, {'type': 'compacted', 'payload': {}}] + calls)['metrics']
            for name in ('help', 'source_read', 'duplicate_reference_reads'):
                self.assertEqual(metrics[name]['value'], 1, (source, coverage, name))
                self.assertEqual(metrics[name]['status'], 'incomplete', name)
            self.assertEqual(metrics['compaction_recovery']['value'], 0)

    def test_evidenced_compaction_recovery_expires_after_two_turns(self):
        events = [FIXTURE[0], {'type': 'compacted', 'payload': {}}]
        for number in range(1, 4):
            events += [event('model_turn', id=f'recovery-{number}', tokens=10),
                       {'type': 'response_item', 'payload': {'type': 'function_call',
                        'call_id': f'help-{number}', 'name': 'shell',
                        'arguments': json.dumps({'command': 'agentkit/skills/.shared/scripts/helper.sh --help'})}}]
        metrics = self.parse(events)['metrics']
        self.assertEqual(metrics['help']['value'], 1)
        self.assertEqual(metrics['help']['status'], 'measured')
        self.assertEqual(metrics['compaction_recovery']['value'], 2)

    def test_explicit_recovery_exclusion_needs_no_turn_telemetry(self):
        events = [FIXTURE[2], event('call', call_id='a', tags=['help'],
                  exclusion='compaction_recovery', evidence='retained-recovery-receipt')]
        metrics = self.parse(events)['metrics']
        self.assertEqual(metrics['help']['value'], 0)
        self.assertEqual(metrics['compaction_recovery']['value'], 1)

    def test_role_polling_retry_and_policy_outcomes(self):
        events = [json.loads(json.dumps(r)) for r in FIXTURE]
        events[0]['payload']['role'] = 'controller'
        events[3]['payload'].update(tags=['hook_refusal', 'supported_rewrite'], retry='justified_transient')
        events[11]['payload']['name'] = 'wait'
        events[-1]['payload'].update(correct=False, false_block=True, avoided_calls=0)
        report = self.parse(events)
        self.assertEqual(report['role'], 'controller')
        self.assertEqual(report['metrics']['polling']['value'], 1)
        self.assertEqual(report['metrics']['justified_transient']['value'], 1)
        self.assertEqual(report['policies']['731']['false_blocks'], 1)
        self.assertEqual(report['policies']['731']['correct'], 0)

    def test_invalid_annotations_fail_with_context(self):
        for extra in [event('call', call_id='missing', tags=['help'], evidence='x'),
                      event('model_turn', id='bad', tokens=-1),
                      event('call', call_id='a', tags=['invented'], evidence='x')]:
            self.parse(FIXTURE + [extra], succeeds=False)


if __name__ == '__main__':
    unittest.main()
