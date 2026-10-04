import json
import tempfile
import unittest
from pathlib import Path

from app import adapt_dot_snapshot, load_dot_snapshot


class DotTaskImportTests(unittest.TestCase):
    def snapshot(self, **changes):
        task = {
            'id': 'fixture-task-1',
            'attachedAt': '2026-10-03T01:00:00Z',
            'latestTurn': {'status': 'completed', 'assistantText': 'must not be retained'},
            'title': 'Fixture task',
            'project': 'FixtureProject',
            'conversation': 'must not be retained',
        }
        task.update(changes)
        return {'snapshot_observed_at': '2026-10-04T01:00:00Z', 'tasks': [task], 'other': 'ignored'}

    def test_allowlist_strips_unknown_fields_and_keeps_registration_semantics(self):
        record, = adapt_dot_snapshot(self.snapshot())
        self.assertEqual(record, {
            'id': 'fixture-task-1', 'source': 'dot-task', 'tool': 'ChatGPT',
            'task_registered_at': '2026-10-03T01:00:00Z',
            'latest_turn_status': 'completed',
            'snapshot_observed_at': '2026-10-04T01:00:00Z',
            'project': 'FixtureProject', 'title': 'Fixture task',
        })
        self.assertFalse({'conversation', 'assistantText', 'other'} & set(record))

    def test_successive_snapshot_refresh_updates_same_task_id(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.json'
            path.write_text(json.dumps(self.snapshot()), encoding='utf-8')
            first, = load_dot_snapshot(path)
            updated = self.snapshot(title='Updated fixture title')
            updated['snapshot_observed_at'] = '2026-10-04T02:00:00Z'
            updated['tasks'][0]['latestTurn']['status'] = 'running'
            path.write_text(json.dumps(updated), encoding='utf-8')
            second, = load_dot_snapshot(path)
        self.assertEqual(first['id'], second['id'])
        self.assertEqual(second['title'], 'Updated fixture title')
        self.assertEqual(second['latest_turn_status'], 'running')
        self.assertNotEqual(first['snapshot_observed_at'], second['snapshot_observed_at'])

    def test_rejects_duplicate_ids_missing_fields_invalid_json_and_cli_collision(self):
        duplicate = self.snapshot()
        duplicate['tasks'].append(duplicate['tasks'][0].copy())
        cases = [duplicate]
        missing_id = self.snapshot(); del missing_id['tasks'][0]['id']; cases.append(missing_id)
        missing_status = self.snapshot(); del missing_status['tasks'][0]['latestTurn']; cases.append(missing_status)
        missing_time = self.snapshot(); del missing_time['tasks'][0]['attachedAt']; cases.append(missing_time)
        for data in cases:
            with self.subTest(data=data):
                with self.assertRaises(ValueError): adapt_dot_snapshot(data)
        with self.assertRaises(ValueError): adapt_dot_snapshot(self.snapshot(), {'fixture-task-1'})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.json'
            path.write_text('{broken', encoding='utf-8')
            with self.assertRaises(json.JSONDecodeError): load_dot_snapshot(path)

    def test_missing_optional_title_and_project_use_safe_fallbacks(self):
        task = self.snapshot()['tasks'][0]
        del task['title']; del task['project']
        record, = adapt_dot_snapshot({'tasks': [task]}, observed_at='2026-10-04T01:00:00Z')
        self.assertEqual(record['title'], 'ChatGPT タスク e-task-1')
        self.assertEqual(record['project'], '不明')


if __name__ == '__main__':
    unittest.main()
