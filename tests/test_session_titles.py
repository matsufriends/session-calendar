import json
from pathlib import Path
import tempfile
import unittest
import app
import sync

class SessionTitleTests(unittest.TestCase):
    def test_official_titles_and_privacy(self):
        cases=json.loads((Path(__file__).parent/'fixtures/session-titles.json').read_text())['cases']
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            for case in cases:
                base=root/('.codex/sessions' if case['tool']=='Codex' else '.claude/projects/fixture')
                base.mkdir(parents=True,exist_ok=True)
                (base/(case['id']+'.jsonl')).write_text(''.join(json.dumps(r)+'\n' for r in case['records'])+''.join(r+'\n' for r in case.get('raw_records',[])))
            (root/'.codex/session_index.jsonl').write_text(''.join(json.dumps(c['index'])+'\n' for c in cases if 'index' in c))
            result=app.collect(root)
        self.assertFalse(result['warnings'])
        rows={r['id']:r for r in result['sessions']}
        for case in cases:self.assertEqual(rows[case['id']]['title'],app.normalized_title(case['expected']))
        self.assertNotIn('Body must remain local',json.dumps(result))
        self.assertNotIn('Body must remain local',json.dumps(sync.snapshot(result,True)))
        private=sync.snapshot(result)
        for row in private['sessions']:
            self.assertEqual(row['title'],f"{row['tool']} セッション {row['id'][:8]}")
