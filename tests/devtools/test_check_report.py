"""Host-only behavior tests; no app build or simulator work."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from scripts.devtools import benchmark, check, report
from scripts.devtools.core import atomic_json
from scripts.devtools.process import Evidence, Redactor, run_process

ROOT = Path(__file__).resolve().parents[2]


class CheckReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dev check spaces ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.results = self.root / 'tests/results'
        self.results.mkdir(parents=True)

    def sample(self, code=0, reason='exited'):
        log = self.results / ('raw log ' + str(code) + '.log')
        log.write_text('actual output\n')
        return {'exit': code, 'reason': reason, 'seconds': .01, 'log': str(log),
                'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest()}

    def test_check_selects_authorities_stops_on_failure_and_retains(self):
        with patch.object(check, 'fingerprint', return_value={'sha256': 'source'}), \
                patch.object(check, 'invoke', side_effect=[self.sample(), self.sample(7)]) as invoke, \
                patch.object(check, 'retain', return_value=self.results / 'receipt.json') as retain:
            data = check.run(self.root)
        self.assertEqual(data['exit'], 7)
        self.assertEqual(data['not_run'], ['unit'])
        self.assertEqual([c.args[1] for c in invoke.call_args_list], [('format', '--check'), ('lint',)])
        self.assertEqual(retain.call_args.args[2]['status'], 'failed')

    def test_invalid_selection_and_precancel_launch_nothing(self):
        cancel = threading.Event()
        cancel.set()
        with patch.object(check, 'invoke') as invoke, \
                patch.object(check, 'fingerprint', return_value={}), \
                patch.object(check, 'retain', return_value=self.results / 'receipt.json'):
            for selection in ((), ('unknown',), ('unit', 'unit')):
                with self.assertRaises(ValueError):
                    check.run(self.root, selection)
            self.assertEqual(check.run(self.root, ['unit'], cancel=cancel)['exit'], 130)
            invoke.assert_not_called()

    def test_source_change_rejects_successful_selection(self):
        with patch.object(check, 'fingerprint', side_effect=[{'sha256': 'before'}, {'sha256': 'after'}]), \
                patch.object(check, 'invoke', return_value=self.sample()), \
                patch.object(check, 'retain', return_value=self.results / 'receipt.json'):
            data = check.run(self.root, ['unit'])
        self.assertEqual(data['exit'], 1)
        self.assertTrue(data['source_changed'])

    def test_benchmark_records_n_and_no_percentile_or_retry(self):
        with patch.object(benchmark, 'fingerprint', return_value={}), \
                patch.object(benchmark, 'provenance', return_value={'valid': False}), \
                patch.object(benchmark, 'invoke', side_effect=[self.sample(), self.sample(124, 'timeout')]), \
                patch.object(benchmark, 'retain', return_value=self.results / 'receipt.json'):
            data = benchmark.run(self.root, 'unit', n=3, conditions='Host-only synthetic child')
        self.assertEqual((data['requested_n'], data['attempted_n'], data['successful_n']), (3, 2, 1))
        self.assertEqual(data['exit'], 124)
        self.assertNotIn('p95', data['statistics'])

    def test_benchmark_rejects_destructive_or_unbounded_conditions(self):
        with patch.object(benchmark, 'fingerprint', return_value={}), \
                patch.object(benchmark, 'provenance', return_value={'valid': False, 'reason': 'missing'}), \
                patch.object(benchmark, 'invoke') as invoke:
            for kind, kwargs in [('gallery', {}), ('cold', {'n': 2}), ('incremental', {}),
                                 ('screenshot', {})]:
                with self.subTest(kind=kind), self.assertRaises(ValueError):
                    benchmark.run(self.root, kind, conditions='Explicit host conditions', **kwargs)
            invoke.assert_not_called()

    def test_report_hashes_evidence_and_never_writes(self):
        path = self.results / 'receipt.json'
        atomic_json(path, {'schema': 1, 'kind': 'check', 'status': 'passed', 'exit': 0,
                           'attempts': [self.sample()]})
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.root.rglob('*') if p.is_file()}
        result = report.collect(self.root, [path])
        self.assertEqual(result['status'], 'observed')
        self.assertEqual(before, {p: (p.read_bytes(), p.stat().st_mtime_ns)
                                  for p in self.root.rglob('*') if p.is_file()})
        Path(result['records'][0]['data']['attempts'][0]['log']).write_text('modified')
        self.assertEqual(report.collect(self.root, [path])['status'], 'blocked')

    def test_report_empty_malformed_outside_and_failed(self):
        self.assertEqual(report.collect(self.root)['exit'], 1)
        malformed = self.results / 'bad.json'
        malformed.write_text('{')
        self.assertEqual(report.collect(self.root, [malformed])['exit'], 1)
        outside = self.root / 'outside.json'
        outside.write_text(json.dumps({'status': 'passed'}))
        self.assertEqual(report.collect(self.root, [outside])['exit'], 1)
        failed = self.results / 'failure.json'
        failed.write_text(json.dumps({'status': 'failed', 'missing': ['actual/test']}))
        result = report.collect(self.root, [failed])
        self.assertEqual(result['records'][0]['data']['missing'], ['actual/test'])
        self.assertEqual(result['exit'], 1)

    def test_real_owned_process_spaces_timeout_cancel_and_isolated_primary_evidence(self):
        # Exercise linked-worktree routing with a synthetic primary, never live results.
        primary = self.root / 'synthetic primary'
        gitdir = primary / '.git/worktrees/owner'
        gitdir.mkdir(parents=True)
        (gitdir / 'commondir').write_text('../..')
        owner = self.root / 'synthetic owner'
        (owner / 'tests/qa').mkdir(parents=True)
        (owner / '.git').write_text('gitdir: ' + str(gitdir))
        for name in ('journal.py', 'activity-v1.sql'):
            shutil.copyfile(ROOT / 'tests/qa' / name, owner / 'tests/qa' / name)
        for mode in ('exited', 'timeout', 'cancelled'):
            with self.subTest(mode=mode):
                evidence = Evidence(owner, 'dev-check-report-host-tests', Redactor())
                try:
                    cancel = threading.Event()
                    if mode == 'cancelled':
                        cancel.set()
                    code = 'print("space path works")' if mode == 'exited' else 'import time; time.sleep(5)'
                    result = run_process([sys.executable, '-c', code], cwd=self.root, evidence=evidence,
                                         timeout=.15 if mode == 'timeout' else 5, cancel=cancel, grace=.05)
                    self.assertEqual(result.reason, mode)
                    self.assertEqual(result.returncode, {'exited': 0, 'timeout': 124, 'cancelled': 130}[mode])
                    self.assertTrue(result.log.is_file())
                    self.assertEqual(result.log.parent, primary.resolve() / 'tests/results/devtools/logs')
                    self.assertFalse((owner / 'tests/results').exists())
                finally:
                    evidence.close()


if __name__ == '__main__':
    unittest.main()
