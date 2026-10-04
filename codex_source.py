"""Codex 0.139.0 metadata adapter; never call thread/read or retain previews."""
import datetime as dt
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time

SOURCE_KINDS = ('cli', 'vscode', 'exec', 'appServer', 'subAgent',
                'subAgentReview', 'subAgentCompact', 'subAgentThreadSpawn',
                'subAgentOther', 'unknown')
SCOPE = 'Codex: このMacのstate DB metadata＋JSONL補完（全source・archive含む）。cloud網羅は保証しません'


class SourceError(Exception):
    """Fixed diagnostic only: never expose raw server errors or payloads."""


def timestamp(value):
    if not isinstance(value, int) or isinstance(value, bool):
        raise SourceError('日時形式不一致')
    try:
        return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat().replace('+00:00', 'Z')
    except (ValueError, OverflowError, OSError):
        raise SourceError('日時形式不一致') from None


def project_thread(row, archived):
    # preview is unavoidable in thread/list transport; discard before projection.
    if not isinstance(row, dict):
        raise SourceError('thread形式不一致')
    row.pop('preview', None)
    sid = row.get('id')
    if not isinstance(sid, str) or not sid:
        raise SourceError('ID形式不一致')
    name = row.get('name')
    if name is not None and not isinstance(name, str):
        raise SourceError('name形式不一致')
    cwd = row.get('cwd')
    if not isinstance(cwd, str):
        raise SourceError('cwd形式不一致')
    source = row.get('source')
    if isinstance(source, dict):
        sub = source.get('subAgent')
        if sub == 'review':
            source = 'subAgentReview'
        elif sub == 'compact':
            source = 'subAgentCompact'
        elif isinstance(sub, dict) and 'thread_spawn' in sub:
            source = 'subAgentThreadSpawn'
        else:
            source = 'subAgentOther' if sub is not None else 'unknown'
    if source not in SOURCE_KINDS:
        source = 'unknown'
    status = row.get('status')
    status = status.get('type') if isinstance(status, dict) else None
    if status not in ('notLoaded', 'idle', 'systemError', 'active'):
        raise SourceError('status形式不一致')
    return dict(id=sid, tool='Codex', title=name or f'Codex セッション {sid[:8]}',
                project=Path(cwd).name if cwd else '不明', start=timestamp(row.get('createdAt')),
                last_activity=timestamp(row.get('updatedAt')), end=None,
                source=source, status=status, archived=archived)


class StdioClient:
    def __init__(self, command, timeout):
        self.deadline = time.monotonic() + timeout
        self.buffer = b''
        self.sequence = 0
        try:
            self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            raise SourceError('CLIを起動できません') from None
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)

    def send(self, message):
        try:
            self.process.stdin.write((json.dumps(message) + '\n').encode())
            self.process.stdin.flush()
        except (OSError, ValueError):
            raise SourceError('stdio切断') from None

    def request(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.send(dict(id=request_id, method=method, params=params))
        while True:
            if time.monotonic() >= self.deadline:
                raise SourceError('timeout')
            while b'\n' not in self.buffer:
                remaining = self.deadline - time.monotonic()
                if remaining <= 0 or not self.selector.select(remaining):
                    raise SourceError('timeout')
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise SourceError('stdio切断')
                self.buffer += chunk
                if len(self.buffer) > 8 * 1024 * 1024:
                    raise SourceError('応答サイズ超過')
            line, self.buffer = self.buffer.split(b'\n', 1)
            try:
                message = json.loads(line)
            except (ValueError, UnicodeError):
                raise SourceError('JSONL形式不一致') from None
            if not isinstance(message, dict):
                raise SourceError('応答形式不一致')
            if 'method' in message:
                if 'id' in message:
                    raise SourceError('予期しないserver request')
                continue  # Drop all notifications without retaining their contents.
            if message.get('id') != request_id or 'error' in message or not isinstance(message.get('result'), dict):
                raise SourceError('応答形式不一致')
            return message['result']

    def close(self):
        # Protocol has no shutdown method. EOF first; reap even after failed startup.
        try:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=2)
        finally:
            self.selector.close()
            self.process.stdout.close()
            self.buffer = b''


def collect_codex(command=('codex', 'app-server', '--stdio'), timeout=20):
    client = StdioClient(command, timeout)
    sessions = {}
    try:
        client.request('initialize', {'clientInfo': {'name': 'session_calendar', 'version': '0.1.0'}})
        client.send({'method': 'initialized', 'params': {}})
        for archived in (False, True):
            cursor = None
            cursors = set()
            for _ in range(1000):
                result = client.request('thread/list', dict(sourceKinds=list(SOURCE_KINDS),
                    useStateDbOnly=True, modelProviders=[], archived=archived, limit=100, cursor=cursor))
                rows = result.get('data')
                if not isinstance(rows, list):
                    raise SourceError('一覧形式不一致')
                # Remove every preview immediately, before validation of individual rows.
                for row in rows:
                    if isinstance(row, dict):
                        row.pop('preview', None)
                for row in rows:
                    session = project_thread(row, archived)
                    previous = sessions.get(session['id'])
                    if previous is None or session['last_activity'] >= previous['last_activity']:
                        sessions[session['id']] = session
                cursor = result.get('nextCursor')
                if cursor is None:
                    break
                if not isinstance(cursor, str) or not cursor or cursor in cursors:
                    raise SourceError('cursor形式不一致')
                cursors.add(cursor)
            else:
                raise SourceError('ページ上限超過')
        return list(sessions.values())
    finally:
        client.close()


def merge_codex(fallback, metadata):
    """State DB wins by ID; keep JSONL-only threads and other tools."""
    unique = {(s['tool'], s['id']): s for s in fallback}
    unique.update({('Codex', s['id']): s for s in metadata})
    return list(unique.values())
