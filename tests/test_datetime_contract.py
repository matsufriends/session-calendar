import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import app


class DateContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads((ROOT / 'tests/fixtures/session-dates.json').read_text())['sessions']

    def test_collect_compares_instants_and_skips_bad_session_only(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp) / '.claude/projects/fixture'
            base.mkdir(parents=True)
            for case in self.fixture:
                lines = []
                for event in case['events']:
                    lines.append(json.dumps({**event, 'sessionId': case['id'], 'cwd': '/tmp/fixture', 'message': 'private body'}))
                (base / f"{case['id']}.jsonl").write_text('\n'.join(lines) + '\n')
            result = app.collect(temp)

        rows = {row['id']: row for row in result['sessions']}
        self.assertEqual(set(rows), {case['id'] for case in self.fixture if case['expected_start']})
        for case in self.fixture:
            if not case['expected_start']:
                continue
            self.assertEqual(rows[case['id']]['start'], case['expected_start'])
            self.assertEqual(rows[case['id']]['last_activity'], case['expected_last_activity'])
            instant = datetime.fromisoformat(rows[case['id']]['start'].replace('Z', '+00:00'))
            jst_day = instant.astimezone(__import__('datetime').timezone(__import__('datetime').timedelta(hours=9))).date().isoformat()
            self.assertEqual(jst_day, case['expected_jst_day'])
        self.assertTrue(result['warnings'])
        self.assertNotIn('private body', json.dumps(result))

    def test_parser_requires_timezone_and_accepts_z_offsets_and_fractional_seconds(self):
        for value in ['2026-10-04T15:30:00Z', '2026-10-04T23:00:00+09:00', '2026-10-04T15:00:00.250Z']:
            self.assertIsNotNone(app.parse_instant(value))
        for value in ['not-a-datetime', '2026-10-04T15:30:00', None]:
            self.assertIsNone(app.parse_instant(value))


if __name__ == '__main__':
    unittest.main()
