"""Measure actual bounded dev invocations without cleaning shared caches."""
import math
from pathlib import Path
import statistics

from .check import invoke, retain
from .core import derived_data, fingerprint, provenance

KINDS = ('cold', 'incremental', 'unit', 'ui', 'screenshot', 'gallery')


def run(root, kind, *, n=1, arguments=(), conditions='', timeout=600, cancel=None):
    """Measure wall seconds, retaining each actual argv, exit and raw log.

    arguments are existing CLI suffixes, never shell text. Gallery is explicitly
    unsupported until the gallery authority exposes a bounded refresh command.
    """
    root = Path(root).resolve()
    arguments = tuple(map(str, arguments))
    if kind not in KINDS or type(n) is not int or n < 1 or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('Known benchmark kind, positive integer n and timeout required')
    if kind == 'gallery':
        raise ValueError('Gallery serves indefinitely; no authoritative bounded refresh command exists')
    if not conditions.strip():
        raise ValueError('Describe actual cache/device/environment conditions with conditions')
    if kind in ('cold', 'incremental') and arguments:
        raise ValueError('Build benchmarks use the canonical Debug Today command without overrides')
    dd_existed = derived_data(root).exists()
    if kind == 'cold' and (n != 1 or dd_existed):
        raise ValueError('Cold requires n=1 and absent worktree derived data; no cache is deleted')
    before = fingerprint(root)
    cache = provenance(root, before)
    if kind == 'incremental' and not cache['valid']:
        raise ValueError('Incremental requires valid existing build provenance: ' + cache['reason'])
    if kind == 'screenshot' and ('--scene' not in arguments or '--output' not in arguments):
        raise ValueError('Screenshot requires existing capture --scene and fresh --output inputs')
    if kind == 'screenshot' and n != 1:
        raise ValueError('Screenshot n=1 preserves the existing fresh-output contract')
    prefix = {'cold': ('build', 'Debug'), 'incremental': ('build', 'Debug'),
              'unit': ('test', 'unit'),
              'screenshot': ('ui', 'capture')}[kind]
    samples = []
    for _ in range(n):
        if cancel and cancel.is_set():
            break
        sample = invoke(root, (*prefix, *arguments), timeout=timeout, cancel=cancel, label='benchmark')
        samples.append(sample)
        if sample['exit']:
            break
    changed = fingerprint(root) != before
    code = next((s['exit'] for s in samples if s['exit']), 0)
    code = code or (130 if len(samples) != n else 1 if changed else 0)
    successful = [s['seconds'] for s in samples if s['exit'] == 0 and s['reason'] == 'exited']
    data = {'schema': 1, 'kind': 'benchmark', 'benchmark': kind, 'worktree': str(root),
            'conditions': conditions, 'fingerprint': before, 'provenance_before': cache,
            'derived_data_existed_before': dd_existed,
            'requested_n': n, 'attempted_n': len(samples), 'successful_n': len(successful),
            'samples': samples, 'source_changed': changed, 'exit': code,
            'status': 'completed' if code == 0 else 'failed',
            'measurement': 'end-to-end invocation wall seconds including CLI and evidence overhead',
            'statistics': {'median_seconds': statistics.median(successful),
                           'min_seconds': min(successful), 'max_seconds': max(successful)} if successful else None,
            'limitations': ['No P95 estimate; samples are reported individually.',
                            'Cold means absent worktree derived data, not cold OS/SPM caches.',
                            'Process completion is not independent test or visual acceptance.']}
    path = retain(root, 'benchmark', data)
    return {**data, 'receipt': str(path)}
