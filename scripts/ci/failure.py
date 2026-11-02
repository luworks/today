"""Failure-only CI evidence, using the existing process owner and QA journal.

Only redacted logs and allowlisted metadata are uploadable. Verbatim command bytes stay private in primary tests/results;
GitHub runner-local private bytes disappear with the runner (not an off-host backup).
No environment dump, DerivedData, simulator store or signing material is exported.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

from scripts.devtools.core import canonical_root
from scripts.devtools.process import Evidence, Redactor, run_process

# Export at most 32 MiB of command logs.
LOG_LIMIT = 32 * 1024 * 1024


def probe(root, *argv):
    try:
        result = subprocess.run(argv, cwd=root, capture_output=True, text=True, timeout=5)
        return result.stdout.strip() if result.returncode == 0 else 'unavailable'
    except (OSError, subprocess.TimeoutExpired):
        return 'unavailable'


class FailureEvidence:
    def __init__(self, root, temp, products, *, lane):
        self.root = root
        self.session = 'ci-' + uuid.uuid4().hex
        self.export = temp / 'failure' / self.session
        self.export.mkdir(parents=True)
        self.private = canonical_root(root) / 'tests/results/ci' / self.session
        self.private.mkdir(parents=True, mode=0o700)
        self.redact = Redactor(secrets=[str(root), str(Path.home())])
        self.commands = []
        self.first_failure = None
        self.data = {'diagnostic_only': True, 'lane': lane, 'status': 'running',
                     'commands': self.commands,
                     'privacy': 'Redacted export; raw logs runner-local/private, indexed by QA journal. '
                                'Redaction is best effort; restrict artifact access. No environment dump.',
                     'source': probe(root, 'git', 'rev-parse', 'HEAD'),
                     'tree': probe(root, 'git', 'rev-parse', 'HEAD^{tree}'),
                     'source_dirty': bool(probe(root, 'git', 'status', '--porcelain')),
                     'workflow_sha': os.environ.get('GITHUB_SHA', 'not_set'),
                     'run_id': os.environ.get('GITHUB_RUN_ID', 'not_set'),
                     'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT', 'not_set'),
                     'products': {p: {'expected_bundle_id': b, 'status': 'not_checked'} for p, b in products.items()}}
        self.write()
        self.data['toolchain'] = {'xcode': probe(root, 'xcodebuild', '-version'),
                                  'swift': probe(root, 'swift', '--version')}
        self.write()

    def write(self):
        path = self.export / 'metadata.json'
        pending = path.with_suffix('.pending')
        pending.write_text(self.redact(json.dumps(self.data, indent=2)) + '\n')
        pending.replace(path)

    def run(self, *argv, capture=False, check=True, timeout=900, allowed=(0,)):
        index = len(self.commands)
        evidence = Evidence(self.root, self.session, self.redact)
        # run_process flushes this redacted log during execution, including cancellation.
        evidence.path = self.export / f'{index:02d}.log'
        raw_path = self.private / f'{index:02d}.raw.log'
        entry = {'argv': self.redact.arguments(argv), 'status': 'running', 'log': evidence.path.name}
        self.commands.append(entry)
        self.write()
        captured = bytearray()
        pending = bytearray()
        def observe(chunk):
            raw.write(chunk)
            raw.flush()
            if capture:
                captured.extend(chunk)
            else:
                pending.extend(chunk)
                while b'\n' in pending:
                    line, _, rest = pending.partition(b'\n')
                    pending[:] = rest
                    print(evidence.redact(line.decode('utf-8', errors='replace')), flush=True)
                if len(pending) > 1024 * 1024:
                    pending.clear()
                    print('[Overlong provider output line omitted]', flush=True)
        try:
            with raw_path.open('xb') as raw:
                raw_path.chmod(0o600)
                result = run_process(argv, cwd=self.root, evidence=evidence,
                                     output_observer=observe, timeout=timeout, grace=5,
                                     env={**os.environ, 'TODAY_CI_STREAM_LOGS': '1'}, stream_output=False)
            entry.update(status='passed' if result.returncode in allowed else 'failed',
                         exit=result.returncode, reason=result.reason, seconds=round(result.seconds, 3),
                         raw_sha256=evidence.journal.artifact(self.session, raw_path))
            if result.returncode not in allowed and self.first_failure is None:
                self.first_failure = dict(entry)
            if check and result.returncode not in allowed:
                raise subprocess.CalledProcessError(result.returncode, argv)
            return captured.decode('utf-8', errors='replace') if capture else result.returncode
        except BaseException as error:
            if entry['status'] == 'running':
                entry.update(status='interrupted', error=type(error).__name__, exit=1)
                if self.first_failure is None:
                    self.first_failure = dict(entry)
            raise
        finally:
            self.data['first_failure'] = self.first_failure
            self.write()
            evidence.journal.artifact(self.session, self.export / 'metadata.json')
            evidence.close()

    def finish(self, code):
        self.data.update(status='passed' if code == 0 else 'failed', exit=code)
        remaining = LOG_LIMIT
        first_log = (self.first_failure or {}).get('log')
        logs = sorted(self.export.glob('*.log'), key=lambda log: (log.name != first_log, log.name))
        marker = b'\n[Export truncated; full raw bytes remain private]\n'
        for log in logs:
            original_size = log.stat().st_size
            if original_size > remaining:
                budget = max(0, remaining - len(marker))
                with log.open('rb') as stream:
                    prefix = stream.read(budget // 2)
                    stream.seek(-budget + budget // 2, 2)
                    suffix = stream.read() if budget else b''
                log.write_bytes(prefix + marker + suffix if remaining >= len(marker) else b'')
            remaining = max(0, remaining - log.stat().st_size)
            for command in self.commands:
                if command['log'] == log.name:
                    command['export_truncated'] = log.stat().st_size != original_size
                    command['export_sha256'] = hashlib.sha256(log.read_bytes()).hexdigest()
        self.write()
        evidence = Evidence(self.root, self.session, self.redact)
        try:
            evidence.journal.archive_files(self.export, self.session)
        finally:
            evidence.close()
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with open(summary, 'a') as stream:
                stream.write(f'\nCI evidence: `{self.data["lane"]}` exit `{code}`. '
                             'Diagnostics are not an install/device acceptance receipt. '
                             'Failure/cancellation artifacts contain redacted logs; checkout/provider failures '
                             'before the recorder starts have Actions logs only.\n')
