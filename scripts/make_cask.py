import argparse, hashlib
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--url',required=True);args=p.parse_args()
root=Path(__file__).resolve().parent.parent
archive=root/'dist/SessionCalendar.app.zip'
sha=hashlib.sha256(archive.read_bytes()).hexdigest()
text=(root/'packaging/session-calendar.rb.in').read_text().replace('@SHA256@',sha).replace('@ARCHIVE_URL@',args.url.replace('"',''))
(root/'packaging/session-calendar.rb').write_text(text)
print('Generated cask with archive SHA256')
