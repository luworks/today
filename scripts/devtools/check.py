"""Bounded selection of existing dev authorities and retained invocation receipts."""
import hashlib
import math
from pathlib import Path
import sys
import time
import uuid

from .core import atomic_json, fingerprint, state_root
from .process import Evidence, Redactor, run_process

CHECKS = {
    'format': ('format', '--check'),
    'lint': ('lint',),
    'unit': ('test', 'unit'),
    'ios-unit': ('test', 'ios-unit'),
    'integration': ('test', 'integration'),
    'snapshot': ('test', 'snapshot'),
}
DEFAULT_CHECKS = ('format', 'lint', 'unit')


def invoke(root, arguments, *, timeout=600, cancel=None, label='check'):
    """Run one existing CLI authority; it alone owns resource locks/lifecycle."""
    root = Path(root).resolve()
    evidence = Evidence(root, 'dev-' + label + '-' + uuid.uuid4().hex, Redactor())
    started = time.time()
    command = [sys.executable, str(root / 'dev'), *map(str, arguments)]
    try:
        result = run_process(command, cwd=root, evidence=evidence, timeout=timeout, cancel=cancel, grace=5)
        receipt = {'argv': evidence.redact.arguments(command), 'cwd': str(root),
                   'started': started, 'ended': time.time(), 'seconds': result.seconds,
                   'exit': result.returncode, 'reason': result.reason,
                   'log': str(result.log),
                   'log_sha256': hashlib.sha256(result.log.read_bytes()).hexdigest()}
        return receipt
    finally:
        evidence.close()


def retain(root, kind, data):
    """Publish only completed immutable receipts; raw logs remain in place."""
    path = state_root(root) / 'runs' / (uuid.uuid4().hex + '.' + kind + '.json')
    evidence = Evidence(root, 'dev-' + kind + '-' + path.stem, Redactor())
    try:
        atomic_json(path, data)
        evidence.journal.artifact(evidence.session, path)
        evidence.record(str(path), 'passed' if data.get('exit') == 0 else 'failed')
    finally:
        evidence.close()
    return path


def run(root, checks=DEFAULT_CHECKS, *, timeout=600, cancel=None):
    """Return a receipt dict; CLI prints it and returns its integer `exit`."""
    root = Path(root).resolve()
    checks = tuple(checks)
    if not checks or len(set(checks)) != len(checks) or set(checks) - CHECKS.keys():
        raise ValueError('Select unique existing checks: ' + ', '.join(CHECKS))
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('timeout must be positive')
    before = fingerprint(root)
    attempts = []
    for name in checks:
        if cancel and cancel.is_set():
            break
        attempt = invoke(root, CHECKS[name], timeout=timeout, cancel=cancel)
        attempts.append({'check': name, **attempt})
        if attempt['exit']:
            break
    changed = fingerprint(root) != before
    code = next((a['exit'] for a in attempts if a['exit']), 0)
    code = code or (130 if len(attempts) != len(checks) else 1 if changed else 0)
    data = {'schema': 1, 'kind': 'check', 'worktree': str(root), 'fingerprint': before,
            'selected': list(checks), 'attempts': attempts, 'source_changed': changed,
            'not_run': list(checks[len(attempts):]), 'exit': code,
            'status': 'passed' if code == 0 else 'failed'}
    path = retain(root, 'check', data)
    return {**data, 'receipt': str(path)}
