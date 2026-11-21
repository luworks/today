"""Reuse the native authority's host regressions in the bounded CI helper gate."""
import contextlib
import io
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class BuildDiagnosticsTests(unittest.TestCase):
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

    def test_an_exited_group_that_refuses_the_signal_is_not_a_failure(self):
        from scripts.devtools import process
        root = Path(__file__).resolve().parents[2]
        evidence = process.Evidence(root, 'exited-group', process.Redactor())
        self.addCleanup(evidence.close)
        with patch.object(process.os, 'killpg', side_effect=PermissionError(1, 'Operation not permitted')):
            result = process.run_process(['/usr/bin/true'], cwd=root, evidence=evidence, timeout=30)
        self.assertEqual((result.returncode, result.reason), (0, 'exited'))

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
