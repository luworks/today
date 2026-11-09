"""Reuse the native authority's host regressions in the bounded CI helper gate."""
import contextlib
import io
import json
import os
import sys
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class BuildDiagnosticsTests(unittest.TestCase):
    def test_partial_phase_is_flushed_before_timeout_without_a_receipt(self):
        from scripts.devtools.process import Evidence, Redactor, run_process
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
                'RUNNER_TEMP': str(Path(temporary).resolve()), 'TODAY_CI_DIAGNOSTICS': '1'}):
            evidence = Evidence(root, 'partial-diagnostics-regression', Redactor())
            self.addCleanup(evidence.close)
            observed = []

            def inspect(chunk):
                # Synchronous reader sees the start while the writer still runs.
                observed.extend(Path(temporary).glob('today-diagnostics/*.jsonl'))
                self.assertTrue(observed)
                self.assertIn('started', observed[0].read_text())

            script = ("import time; print(\"Test Case '-[TodayTests.HealthMetricsTests "
                      "testHealthUpdate]' started.\", flush=True); "
                      "print('private title chat Health value token=fixture-secret', flush=True); time.sleep(10)")
            with contextlib.redirect_stdout(io.StringIO()):
                result = run_process([sys.executable, '-c', script], cwd=root, evidence=evidence,
                                     timeout=1, grace=0.1, output_observer=inspect)
            self.assertEqual((result.returncode, result.reason), (124, 'timeout'))
            self.assertTrue(observed)
            raw = observed[0].read_text()
            events = [json.loads(line) for line in raw.splitlines()]
            self.assertEqual([e['event'] for e in events], ['started', 'selector', 'timeout', 'reaped'])
            self.assertEqual(events[1]['selector'], 'TodayTests.HealthMetricsTests/testHealthUpdate')
            self.assertTrue(all(e['diagnostic_only'] and e['pid'] > 0 for e in events))
            self.assertNotIn('fixture-secret', raw)
            self.assertNotIn('private title', raw)
            self.assertFalse(list(Path(temporary).rglob('report.json')))
            self.assertFalse(list(Path(temporary).rglob('*.xcresult')))
            with self.assertRaises(ProcessLookupError):
                os.kill(events[0]['pid'], 0)

    def test_activity_keeps_only_owned_build_tree(self):
        from scripts.devtools.process import build_activity
        raw = ('10 1 1.0 100 00:01 xcodebuild build\n'
               '20 10 90.0 200 00:01 swift-frontend fixture.swift\n'
               '30 20 20.0 300 00:01 clang\n'
               '40 1 80.0 400 00:01 unrelated-user-build\n')
        with patch('scripts.devtools.process.subprocess.run', return_value=SimpleNamespace(stdout=raw)):
            result = build_activity(10)
        self.assertEqual(len(result['processes']), 3)
        self.assertFalse(any('unrelated' in row for row in result['processes']))
        self.assertIn('90.0 200', result['processes'][1])

    def test_timeout_preserves_phase_time_activity_and_redaction(self):
        from scripts.devtools.process import Evidence, Redactor, run_process
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / 'xcodebuild'
            executable.write_text('#!/bin/sh\n'
                                  'echo "SwiftCompile normal arm64 fixture-secret.swift"\n'
                                  'sleep 10\n')
            executable.chmod(0o755)
            evidence = Evidence(root, 'build-profile-regression', Redactor(secrets=['fixture-secret']))
            self.addCleanup(evidence.close)
            # Arm the synthetic deadline only after output arrives. A loaded
            # host may take longer than 300ms to launch even this shell fixture.
            clock = [0.0]
            real_clock = time.monotonic
            started = real_clock()

            def emitted(chunk):
                if b'SwiftCompile' in chunk:
                    clock[0] = 1.0

            def deadline_clock():
                elapsed = real_clock() - started
                return clock[0] + elapsed if clock[0] or elapsed > 3 else 0.0

            with patch('scripts.devtools.process.build_activity', return_value={'cpu_count': 3, 'processes': []}), \
                    patch('scripts.devtools.process.time.monotonic', side_effect=deadline_clock):
                result = run_process([str(executable), 'build-for-testing'], cwd=root,
                                     evidence=evidence, timeout=0.3, grace=0.1, output_observer=emitted)
            self.assertEqual((result.returncode, result.reason), (124, 'timeout'))
            raw = result.log.read_text()
            self.assertNotIn('fixture-secret', raw)
            phases = [json.loads(line.removeprefix('DEV_BUILD_PHASE '))
                      for line in raw.splitlines() if line.startswith('DEV_BUILD_PHASE ')]
            self.assertEqual(len(phases), 1)
            self.assertGreaterEqual(phases[0]['seconds'], 0)
            self.assertIn('[REDACTED].swift', phases[0]['phase'])
            self.assertIn('DEV_BUILD_ACTIVITY', raw)

    def test_prepare_only_preserves_build_failure_without_publishing_or_running_tests(self):
        from scripts.devtools import commands
        from scripts.devtools.core import NativeBuildError
        root = Path(__file__).resolve().parents[2]
        failure = NativeBuildError(SimpleNamespace(returncode=124, log=Path('failure.log')))
        with patch.object(commands, 'host_lock', return_value=contextlib.nullcontext()), \
                patch.object(commands, 'dd_lock', return_value=contextlib.nullcontext()), \
                patch.object(commands, 'generate', return_value=0), \
                patch.object(commands, 'fingerprint', return_value={}), \
                patch('scripts.devtools.resolve.locked_arguments', return_value=[]), \
                patch('scripts.devtools.core.ensure_test_products', side_effect=failure), \
                patch.object(commands, 'record_build') as publish, \
                patch.object(commands, 'test') as tests, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(commands.build(root, scheme='TodayMock', testing=True), 124)
        publish.assert_not_called()
        tests.assert_not_called()
