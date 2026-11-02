"""Synthetic CI plumbing only: no Xcode build, simulator or phone."""
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.ci import failure, job  # noqa: E402 - direct script execution from any cwd


class FailureCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(patch.stopall)
        qa = self.root / 'tests/qa'
        qa.mkdir(parents=True)
        for name in ('journal.py', 'activity-v1.sql'):
            shutil.copyfile(ROOT / 'tests/qa' / name, qa / name)
        patch.object(failure, 'probe', return_value='synthetic-source').start()
        self.evidence = failure.FailureEvidence(self.root, self.root / 'temp', job.PRODUCTS, lane='synthetic')

    def tearDown(self):
        # Keep synthetic command bytes after temp cleanup,
        # indexed with the same primary-checkout journal as ./dev's test log.
        evidence = failure.Evidence(ROOT, 'synthetic-' + self.evidence.session, failure.Redactor())
        try:
            files = [path for path in self.root.rglob('*') if path.is_file() and
                     path.suffix in ('.log', '.json') and
                     'archives' not in path.relative_to(self.root).parts]
            evidence.journal.archive_files(self.root, evidence.session, files=sorted(files))
        finally:
            evidence.close()

    def test_failure_preserves_exit_raw_hash_and_redacted_export(self):
        with patch.dict(os.environ, {'CI_TEST_TOKEN': 'private-secret'}):
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                self.evidence.run(sys.executable, '-c',
                                  "import os,sys; print(os.environ['CI_TEST_TOKEN']); print(os.getcwd()); sys.exit(37)")
        self.assertEqual(caught.exception.returncode, 37)
        self.evidence.finish(37)
        raw = (self.evidence.private / '00.raw.log').read_bytes()
        exported = (self.evidence.export / '00.log').read_text()
        self.assertIn(b'private-secret', raw)
        self.assertNotIn('private-secret', exported)
        self.assertNotIn(str(self.root), exported)
        data = json.loads((self.evidence.export / 'metadata.json').read_text())
        self.assertEqual(data['exit'], 37)
        self.assertEqual(data['first_failure']['exit'], 37)
        self.assertEqual(data['commands'][0]['raw_sha256'], hashlib.sha256(raw).hexdigest())
        with self.assertRaises(subprocess.CalledProcessError):
            self.evidence.run(sys.executable, '-c', 'raise SystemExit(9)')
        self.assertEqual(self.evidence.first_failure['exit'], 37)

    def test_signal_keeps_partial_output(self):
        # The child cancels this owned runner; its existing signal handler reaps the child.
        code = self.evidence.run(sys.executable, '-c',
                                 'import os,signal,time; print("before-signal", flush=True); os.kill(os.getppid(), signal.SIGINT); time.sleep(20)',
                                 check=False)
        self.assertEqual(code, 130)
        self.assertEqual(self.evidence.commands[0]['reason'], 'cancelled')
        self.evidence.finish(code)
        self.assertIn('before-signal', (self.evidence.export / '00.log').read_text())

    def test_nested_dev_process_trace_reaches_failure_export_redacted(self):
        script = (f'import sys; sys.path.insert(0, {str(ROOT)!r}); '
                  'from pathlib import Path; from scripts.devtools.commands import execute; '
                  'result = execute(Path.cwd(), [sys.executable, "-c", '
                  '"import os; print(\\\"AssertionError: nested fixture\\\"); '
                  'print(os.environ[\\\"CI_TEST_TOKEN\\\"]); raise SystemExit(37)"]); '
                  'raise SystemExit(result.returncode)')
        with patch.dict(os.environ, {'CI_TEST_TOKEN': 'nested-private-secret'}):
            code = self.evidence.run(sys.executable, '-c', script, check=False)
        self.assertEqual(code, 37)
        self.evidence.finish(code)
        exported = (self.evidence.export / '00.log').read_text()
        self.assertIn('AssertionError: nested fixture', exported)
        self.assertEqual(exported.count('AssertionError: nested fixture'), 1)
        self.assertNotIn('nested-private-secret', exported)
        self.assertEqual(self.evidence.first_failure['exit'], 37)

    def test_log_export_limit_keeps_raw_bytes_and_the_first_failure(self):
        self.evidence.run(sys.executable, '-c', 'print("x" * 200)')
        with patch.object(failure, 'LOG_LIMIT', 80):
            self.evidence.finish(1)
        self.assertIn('Export truncated', (self.evidence.export / '00.log').read_text())
        self.assertIn('x' * 100, (self.evidence.private / '00.raw.log').read_text())
        # A prior successful command cannot consume the first failure's log allowance.
        failed = failure.FailureEvidence(self.root, self.root / 'temp', job.PRODUCTS, lane='synthetic')
        failed.run(sys.executable, '-c', 'print("success" * 200)')
        failed.run(sys.executable, '-c', 'print("head" + "x" * 200 + "known-error-tail"); raise SystemExit(37)', check=False)
        with patch.object(failure, 'LOG_LIMIT', 100):
            failed.finish(37)
        exported = (failed.export / '01.log').read_text()
        self.assertIn('head', exported)
        self.assertIn('known-error-tail', exported)
        self.assertLessEqual(sum(log.stat().st_size for log in failed.export.glob('*.log')), 100)

    def test_entry_preserves_first_command_exit_if_later_verification_fails(self):
        self.evidence.first_failure = {'exit': 65}
        with patch.object(job, 'FailureEvidence', return_value=self.evidence), \
                patch.object(job, 'build', side_effect=SystemExit('missing product')):
            self.assertEqual(job.entry(['--build']), 65)


if __name__ == '__main__':
    unittest.main()
