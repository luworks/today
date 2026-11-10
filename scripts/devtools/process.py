"""Owned process groups with bounded cancellation and durable redacted evidence."""
from dataclasses import dataclass
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import threading
import time
import traceback
import uuid

from .core import canonical_root, worktree_id

SECRET_KEY = re.compile(r'(secret|token|password|passwd|api[_-]?key|authorization|credential)', re.I)


class Redactor:
    def __init__(self, env=None, secrets=()):
        env = os.environ if env is None else env
        self.values = sorted({str(v) for k, v in env.items() if SECRET_KEY.search(k) and v} |
                             {str(v) for v in secrets if v}, key=len, reverse=True)

    def arguments(self, argv):
        result, sensitive = [], False
        for argument in map(str, argv):
            if sensitive:
                result.append('[REDACTED]')
                sensitive = False
            elif SECRET_KEY.search(argument.split('=', 1)[0]) and argument.startswith('-'):
                key, separator, value = argument.partition('=')
                result.append(key + '=[REDACTED]' if separator else key)
                sensitive = not separator
            else:
                result.append(self(argument))
        return result

    def __call__(self, text):
        for value in self.values:
            text = text.replace(value, '[REDACTED]')
        text = re.sub(r'(?i)(Bearer\s+)\S+', r'\1[REDACTED]', text)
        text = re.sub(r'(?i)((?:password|passwd|token|secret|api[_-]?key)\s*[=:]\s*)("[^"]*"|\'[^\']*\'|[^\s,;]+)',
                      r'\1[REDACTED]', text)
        return re.sub(r'(https?://)[^\s/@]+:[^\s/@]+@', r'\1[REDACTED]@', text)


class Evidence:
    """Use the repository's QA journal, never the app Activity database."""
    def __init__(self, root, session, redactor):
        self.session, self.redact = session, redactor
        self.owner = str(Path(root).resolve())
        self.owner_identity = worktree_id(root)
        spec = importlib.util.spec_from_file_location('devtools_qa_journal', Path(root) / 'tests/qa/journal.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        results = canonical_root(root) / 'tests/results'
        self.journal = module.Journal(results / 'activity.sqlite')
        self.path = results / 'devtools/logs' / (uuid.uuid4().hex + '.log')
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def record(self, text, status):
        self.journal.record(self.session, 'qa.command.devtools', self.redact(text), status=status,
                            props={'owner': self.owner, 'worktree_id': self.owner_identity,
                                   'pid': os.getpid()})

    def close(self):
        self.journal.close()


@dataclass(frozen=True)
class ProcessResult:
    returncode: int
    reason: str
    seconds: float
    log: Path


class PhaseDiagnostics:
    """Independent partial evidence: allowlisted metadata, never acceptance or stdout."""
    def __init__(self, argv):
        self.path = None
        self.start = time.monotonic()
        self.pid = None
        self.phase = 'process'
        for value in map(str, argv):
            if value in ('build', 'build-for-testing', 'test-without-building', 'bootstrap',
                         'generate', 'resolve', 'business', 'integration', 'snapshots'):
                self.phase = value
                break
        if os.environ.get('TODAY_CI_DIAGNOSTICS') == '1':
            directory = Path(os.environ['RUNNER_TEMP']) / 'today-diagnostics'
            if any(p.is_symlink() for p in (directory, *directory.parents)):
                raise ValueError('symlink diagnostic output rejected')
            directory.mkdir(exist_ok=True)
            self.path = directory / (uuid.uuid4().hex + '.jsonl')

    def emit(self, event, **fields):
        if self.path is None:
            return
        record = {'diagnostic_only': True, 'event': event, 'phase': self.phase,
                  'pid': self.pid, 'started_unix': round(time.time() - (time.monotonic() - self.start), 3),
                  'elapsed_seconds': round(time.monotonic() - self.start, 3), **fields}
        line = json.dumps(record) + '\n'
        # Each writer owns one file. Flush every record before continuing work.
        with self.path.open('a', encoding='utf-8') as stream:
            stream.write(line)
            stream.flush()
        print('DEV_PHASE ' + line.rstrip(), flush=True)

    def observe(self, line):
        # Keep source test identifiers only; drop titles, chat, Health values,
        # arbitrary output and argv, even when they contain no recognizable secret.
        match = re.search(r"Test Case '-?\[((?:Today|One)[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)?) (test[A-Za-z0-9_]+)\]' (started|passed|failed|skipped)", line)
        if match:
            self.emit('selector', selector=match[1] + '/' + match[2], state=match[3])


def build_activity(pid):
    """Read only this build's process tree; a failed probe must not fail a build."""
    result = {'cpu_count': os.cpu_count(), 'processes': []}
    try:
        result['load_average'] = os.getloadavg()
        raw = subprocess.run(
            ['ps', '-axo', 'pid=,ppid=,%cpu=,rss=,etime=,command='],
            capture_output=True, text=True, timeout=2, check=True).stdout
        rows = []
        for line in raw.splitlines():
            fields = line.split(None, 5)
            if len(fields) == 6:
                rows.append((int(fields[0]), int(fields[1]), line))
        owned = {pid}
        while True:
            children = {child for child, parent, _ in rows if parent in owned}
            if children <= owned:
                break
            owned.update(children)
        result['processes'] = [line for child, _, line in rows if child in owned]
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        result['probe_error'] = type(error).__name__
    return result


def run_process(argv, *, cwd, evidence, env=None, timeout=600, cancel=None, grace=1, output_observer=None,
                stream_output=None):
    """Execute argv without a shell; signal only the new session created here.

    Adapters acquire resource locks before calling. SIGINT/SIGTERM are converted
    to cancellation on the main thread, then prior handlers are restored.
    An optional in-memory output observer can reject raw bytes before log redaction.
    """
    if not argv or timeout <= 0 or grace < 0:
        raise ValueError('argv and positive timeout required; grace must be nonnegative')
    # Include injected child credentials and sensitive flag values in output redaction.
    extra, sensitive = [], False
    for argument in map(str, argv):
        if sensitive:
            extra.append(argument)
            sensitive = False
        elif argument.startswith('-') and SECRET_KEY.search(argument.split('=', 1)[0]):
            key, separator, value = argument.partition('=')
            if separator:
                extra.append(value)
            else:
                sensitive = True
    evidence.redact = Redactor(env, secrets=[*evidence.redact.values, *extra])
    cancelled = threading.Event()
    handlers = {}
    proc = None
    group_killed = False
    reason, code = 'exited', 1
    failure = None
    pending = b''
    if stream_output is None:
        stream_output = (os.environ if env is None else env).get('TODAY_CI_STREAM_LOGS') == '1'
    start = time.monotonic()
    diagnostics = PhaseDiagnostics(argv)
    next_diagnostic = 30
    profile_build = Path(str(argv[0])).name == 'xcodebuild' and len(argv) > 1 and argv[1] in ('build', 'build-for-testing')
    next_profile = 0
    evidence.record(repr(evidence.redact.arguments(argv)), 'running')
    try:
        if threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGINT, signal.SIGTERM):
                handlers[sig] = signal.getsignal(sig)
                signal.signal(sig, lambda signum, frame: cancelled.set())
        with evidence.path.open('x', encoding='utf-8') as log, selectors.DefaultSelector() as selector:
            proc = subprocess.Popen(list(map(str, argv)), cwd=cwd, env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
            diagnostics.pid = proc.pid
            diagnostics.emit('started')
            selector.register(proc.stdout, selectors.EVENT_READ)
            pending = b''
            dropping_line = False
            stopped = None
            eof = False
            while not eof or proc.poll() is None:
                now = time.monotonic()
                if now - start >= next_diagnostic:
                    diagnostics.emit('running')
                    next_diagnostic = now - start + 30
                if profile_build and now - start >= next_profile:
                    record = {'seconds': round(now - start, 3), **build_activity(proc.pid)}
                    log.write('DEV_BUILD_ACTIVITY ' + evidence.redact(json.dumps(record)) + '\n')
                    next_profile = now - start + 30
                if stopped is None and (cancelled.is_set() or (cancel and cancel.is_set()) or now - start >= timeout):
                    reason = 'cancelled' if cancelled.is_set() or (cancel and cancel.is_set()) else 'timeout'
                    stopped = now
                    diagnostics.emit(reason)
                    _signal_group(proc.pid, signal.SIGTERM)
                if stopped is not None and now - stopped >= grace:
                    _signal_group(proc.pid, signal.SIGKILL)
                    group_killed = True
                    # Bound cancellation even if an escaped descendant retains the pipe.
                    break
                for key, _ in selector.select(0.05):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        eof = True
                        continue
                    if output_observer:
                        output_observer(chunk)
                    if dropping_line:
                        if b'\n' not in chunk:
                            continue
                        chunk = chunk.split(b'\n', 1)[1]
                        dropping_line = False
                    pending += chunk
                    while b'\n' in pending:
                        line, pending = pending.split(b'\n', 1)
                        decoded = evidence.redact(line.decode('utf-8', errors='replace'))
                        diagnostics.observe(decoded)
                        if profile_build and decoded.startswith((
                                'SwiftDriver ', 'SwiftCompile normal ', 'SwiftEmitModule ',
                                'Ld ', 'ComputeTargetDependencyGraph', 'Resolve Package Graph')):
                            log.write('DEV_BUILD_PHASE ' + json.dumps({
                                'seconds': round(time.monotonic() - start, 3), 'phase': decoded}) + '\n')
                        log.write(decoded + '\n')
                        if stream_output:
                            # CI's outer recorder must receive tool traces, not just a log path.
                            print(decoded, flush=True)
                if len(pending) > 1024 * 1024:
                    log.write('[Overlong output line omitted]\n')
                    pending = b''
                    dropping_line = True
                log.flush()
            log.write(evidence.redact(pending.decode('utf-8', errors='replace')))
            if stream_output and pending:
                print(evidence.redact(pending.decode('utf-8', errors='replace')), flush=True)
            code = proc.wait()
            if reason != 'exited':
                code = 124 if reason == 'timeout' else 130
    except BaseException as error:
        failure = error
    finally:
        # Cleanup failures must not erase the original operation or its log.
        cleanup_errors = []
        if proc:
            if not group_killed:
                try:
                    _signal_group(proc.pid, signal.SIGKILL)
                except OSError as error:
                    cleanup_errors.append(error)
                    # The Popen child is ours; never discover or signal other PIDs.
                    if proc.poll() is None:
                        try:
                            proc.kill()
                        except OSError as child_error:
                            cleanup_errors.append(child_error)
            try:
                proc.wait(timeout=max(grace, 1))
            except subprocess.TimeoutExpired as error:
                cleanup_errors.append(error)
            if proc.stdout:
                proc.stdout.close()
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
        diagnostics.emit('reaped', exit=proc.returncode if proc else None, reason=reason,
                         cleanup_failed=bool(cleanup_errors))
        if failure is None and cleanup_errors:
            failure = cleanup_errors.pop(0)
        if failure is not None:
            # Keep syscall/line attribution and partial compiler output together.
            diagnostic = (f'Owned process pid={proc.pid if proc else None}; reason={reason}; '
                          f'child_exit={proc.returncode if proc else None}; '
                          f'elapsed={time.monotonic() - start:.3f}s\n')
            diagnostic += ''.join(traceback.format_exception(type(failure), failure, failure.__traceback__))
            for error in cleanup_errors:
                diagnostic += '\nCleanup failure: ' + repr(error)
            with evidence.path.open('a', encoding='utf-8') as log:
                log.write(evidence.redact(pending.decode('utf-8', errors='replace')))
                log.write('\n' + evidence.redact(diagnostic))
            failure.process_log = evidence.path
            evidence.record(diagnostic, 'failed')
        if evidence.path.exists():
            evidence.journal.artifact(evidence.session, evidence.path)
    if failure is not None:
        raise failure
    evidence.record(f'{reason}; exit={code}; log={evidence.path}',
                    'passed' if code == 0 else 'interrupted' if reason == 'cancelled' else 'failed')
    return ProcessResult(code, reason, time.monotonic() - start, evidence.path)


def _signal_group(pid, sig):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass
    except OSError as error:
        detail = f'os.killpg(pgid={pid}, signal={sig}); owned start_new_session child'
        error.strerror = f'{error.strerror}; {detail}'
        raise
