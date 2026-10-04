import unittest
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
import sync
class SyncTests(unittest.TestCase):
    def test_empty_snapshot(self):
        self.assertEqual(sync.snapshot({'sessions':[]}),{'sessions':[],'timezone':'Asia/Tokyo'})
    def test_omits_body_path_title_by_default(self):
        row={'id':'fixture-session','tool':'Codex','start':'2026-10-03T01:00:00Z','last_activity':None,'end':'untrusted','project':'/Users/person/private-project','title':'confidential task','content':'private body','cwd':'/private/full/path'}
        result=sync.snapshot({'sessions':[row]})['sessions'][0]
        self.assertEqual(set(result),set(sync.KEYS));self.assertEqual(result['project'],'private-project');self.assertNotIn('confidential',result['title']);self.assertIsNone(result['end'])
        self.assertEqual(sync.snapshot({'sessions':[row]},True)['sessions'][0]['title'],'confidential task')
if __name__=='__main__':unittest.main()
