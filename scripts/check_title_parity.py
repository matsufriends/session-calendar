"""Compare actual Native output with Python API/dry-run titles; artificial fixtures only."""
import json
from pathlib import Path
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
import app
import sync

path=Path(sys.argv[1])
cases=json.loads((ROOT/'tests/fixtures/session-titles.json').read_text())['cases']
with tempfile.TemporaryDirectory() as temp:
    home=Path(temp)
    for case in cases:
        base=home/('.codex/sessions' if case['tool']=='Codex' else '.claude/projects/fixture')
        base.mkdir(parents=True,exist_ok=True)
        lines=''.join(json.dumps(row)+'\n' for row in case['records'])+''.join(row+'\n' for row in case.get('raw_records',[]))
        (base/(case['id']+'.jsonl')).write_text(lines)
    (home/'.codex/session_index.jsonl').write_text(''.join(json.dumps(c['index'])+'\n' for c in cases if 'index' in c))
    collected=app.collect(home)
assert not collected['warnings']
def titles(data):return {(row['tool'],row['id']):row['title'] for row in data['sessions']}
assert titles(collected)==titles(json.loads(path.read_text())),'Python API != Native prepared'
for anonymous in [False,True]:
    native=json.loads(Path(str(path)+('.anonymous' if anonymous else '')).read_text())
    assert titles(sync.snapshot(collected,not anonymous))==titles(native),'Python dry-run != Native prepared'
fixtures=json.loads((ROOT/'native/Tests/SessionCalendarTests/Fixtures/title-normalization.json').read_text())
actual=json.loads(Path(str(path)+'.normalization').read_text())
def expanded(value):return value if isinstance(value,str) else value['repeat']*value['count']+value.get('suffix','')
expected=[{'name':f['name'],'title':app.normalized_title(expanded(f['input']))} for f in fixtures]
assert actual==expected,'Native/Python normalization differs'
Path(str(path)+'.python-parity').write_text(json.dumps({'ok':True,'session_cases':len(cases),'normalization_cases':len(fixtures),'title_on':True,'anonymous':True,'api_matches_native':True},indent=2)+'\n')
print(f'Python API/dry-run == Native prepared: {len(cases)} session cases; {len(fixtures)} Unicode boundary cases; title-on/anonymous; invalid surrogate rejected')
