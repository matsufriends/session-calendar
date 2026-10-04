import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import app
import codex_source as source

ROW = dict(id='fixture', name='explicit name', createdAt=1, updatedAt=2,
           cwd='/private/person/project', source='exec', status={'type':'notLoaded'},
           preview='SECRET user body', turns=[{'text':'SECRET hidden analysis'}],
           credential='SECRET token', path='/private/file')

class AdapterTests(unittest.TestCase):
    def server(self, behavior):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name)/'server.py'
        path.write_text('''import sys,json,time,os
for line in sys.stdin:
 r=json.loads(line)
 if r['method']=='initialized': continue
 if r['method']=='initialize':
  sys.stdout.write(json.dumps({'id':r['id'],'result':{}})+'\\n');sys.stdout.flush();continue
 assert r['method']=='thread/list'
 assert r['params']['useStateDbOnly'] is True
 assert len(r['params']['sourceKinds'])==10
 assert r['params']['modelProviders']==[]
''' + behavior)
        return [sys.executable, str(path)]

    def test_projection_allowlist(self):
        row = dict(ROW)
        result = source.project_thread(row, True)
        self.assertNotIn('preview', row)
        self.assertEqual(set(result), {'id','tool','title','project','start','last_activity','end','source','status','archived'})
        self.assertNotIn('SECRET', json.dumps(result))
        self.assertEqual(result['project'], 'project')
        self.assertEqual(result['status'], 'notLoaded')
        self.assertIsNone(result['end'])
        self.assertEqual(source.project_thread(dict(ROW, name=None, source={'subAgent':{'thread_spawn':{'parent_thread_id':'secret'}}}), False)['source'], 'subAgentThreadSpawn')

    def test_paging_framing_duplicates_and_eof_reap(self):
        command = self.server(''' row = '''+repr(ROW)+'''
 if r['params']['cursor']: row['updatedAt']=3
 result={'data':[row], 'nextCursor':None if r['params']['cursor'] else 'next'}
 message=json.dumps({'id':r['id'],'result':result})+'\\n'
 sys.stdout.write(json.dumps({'method':'ignored','params':{'text':'SECRET'}})+'\\n'+message[:5]);sys.stdout.flush()
 time.sleep(.01)
 sys.stdout.write(message[5:]);sys.stdout.flush()
''')
        processes=[]
        original=source.subprocess.Popen
        def track(*args, **kwargs):
            p=original(*args, **kwargs);processes.append(p);return p
        with patch.object(source.subprocess,'Popen',side_effect=track):
            result=source.collect_codex(command, timeout=3)
        self.assertEqual(len(result),1)
        self.assertEqual(result[0]['last_activity'],'1970-01-01T00:00:03Z')
        self.assertNotIn('SECRET',json.dumps(result))
        self.assertEqual(processes[0].returncode,0)

    def test_timeout_and_reap(self):
        command=self.server(' time.sleep(30)\n')
        processes=[];original=source.subprocess.Popen
        def track(*args,**kwargs):
            p=original(*args,**kwargs);processes.append(p);return p
        with patch.object(source.subprocess,'Popen',side_effect=track):
            with self.assertRaisesRegex(source.SourceError,'timeout'):
                source.collect_codex(command,timeout=.05)
        self.assertIsNotNone(processes[0].returncode)

    def test_malformed_response_no_payload_leak(self):
        for behavior in (" sys.stdout.write('SECRET invalid json\\n');sys.stdout.flush()\n",
                         " print(json.dumps({'id':r['id'],'error':{'message':'SECRET token'}}),flush=True)\n",
                         " print(json.dumps({'id':999,'result':{}}),flush=True)\n",
                         " print(json.dumps({'id':r['id'],'result':{'data':{},'nextCursor':None}}),flush=True)\n",
                         " print(json.dumps({'id':r['id'],'result':{'data':[], 'nextCursor':'same'}}),flush=True)\n"):
            with self.subTest(behavior=behavior):
                with self.assertRaises(source.SourceError) as error:
                    source.collect_codex(self.server(behavior),timeout=2)
                self.assertNotIn('SECRET',str(error.exception))

    def test_forced_kill_reaps_stubborn_process(self):
        command=self.server(' import signal\n signal.signal(signal.SIGTERM,signal.SIG_IGN)\n time.sleep(30)\n')
        processes=[];original=source.subprocess.Popen
        def track(*args,**kwargs):
            p=original(*args,**kwargs);processes.append(p);return p
        with patch.object(source.subprocess,'Popen',side_effect=track):
            with self.assertRaises(source.SourceError):
                source.collect_codex(command,timeout=.1)
        self.assertEqual(processes[0].returncode,-9)

    def test_invalid_metadata_fails_closed(self):
        for changes in ({'createdAt':True}, {'status':{'type':'completed'}}, {'name':['SECRET']}):
            with self.subTest(changes=changes), self.assertRaises(source.SourceError):
                source.project_thread(dict(ROW,**changes),False)

    def test_merge_preserves_jsonl_only(self):
        old=dict(source.project_thread(dict(ROW),False),title='old')
        other=dict(old,id='jsonl-only')
        new=source.project_thread(dict(ROW),False)
        merged=source.merge_codex([old,other],[new])
        self.assertEqual(len(merged),2)
        self.assertEqual(merged[0]['title'],'explicit name')

    def test_explicit_home_never_launches_real_cli(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(app,'collect_codex') as reader:
            result=app.collect(directory)
        reader.assert_not_called()
        self.assertEqual(result['sessions'],[])
        self.assertIn('fixture',result['source_scope'])

    def test_integrated_datetime_identity_and_metadata_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory)
            base=home/'.codex/sessions';base.mkdir(parents=True)
            record={'type':'session_meta','payload':{'id':'fixture','timestamp':'2026-10-04T23:00:00+09:00','cwd':'/fixture'}}
            (base/'fixture.jsonl').write_text(json.dumps(record)+'\n')
            claude=home/'.claude/projects';claude.mkdir(parents=True)
            (claude/'fixture.jsonl').write_text(json.dumps({'type':'user','sessionId':'fixture','timestamp':'2026-10-04T15:30:00Z','cwd':'/fixture'})+'\n')
            newer=dict(source.project_thread(dict(ROW),False), start='2026-10-04T23:00:00+09:00',title='Explicit metadata title')
            result=app.collect(home,codex_reader=lambda:[newer])
        self.assertEqual([row['tool'] for row in result['sessions']],['Claude','Codex'])
        self.assertEqual(len(result['sessions']),2)
        self.assertEqual(result['sessions'][1]['title'],'Explicit metadata title')
        self.assertIn('app-server 1件',result['source_scope'])
        self.assertFalse(result['warnings'])

    def test_fallback_scope_and_failure(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(app.Path,'home',return_value=Path(directory)), patch.object(app,'collect_codex',side_effect=source.SourceError('timeout')):
            sessions=Path(directory)/'.codex/sessions';sessions.mkdir(parents=True)
            (sessions/'fixture.jsonl').write_text(json.dumps({'type':'session_meta','payload':{'id':'fixture','timestamp':'2026-01-01T00:00:00Z','cwd':'/private/project'}})+'\nSECRET invalid second line')
            result=app.collect()
        self.assertEqual(len(result['sessions']),1)
        self.assertIn('JSONL',result['source_scope'])
        self.assertIn('fallback',result['warnings'][0])
        self.assertNotIn('SECRET',json.dumps(result))

if __name__=='__main__':unittest.main()
