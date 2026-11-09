"""Host-only adapter regressions. All platform processes are synthetic."""
from contextlib import contextmanager
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.devtools import commands, xcode_tests  # noqa: E402
from scripts.devtools.cli import main  # noqa: E402

CONTRACT = commands.testing_contract(ROOT)
METHOD = 'TodayTests/StoreUpgradeTests/oldStoreOpensWithCurrentSchema'


def tree(ids, status='Passed'):
    return {'testNodes': [{'nodeType': 'Test Case', 'nodeIdentifier': value, 'result': status} for value in ids]}


class XcodeTests(unittest.TestCase):
    def test_source_plans_and_cross_lane_union(self):
        lanes = xcode_tests.selected(CONTRACT, ROOT, ['ios-unit', 'integration', 'snapshot'])
        self.assertEqual(set(lanes), {'unit', 'integration', 'snapshot'})
        self.assertTrue(all(x.startswith('TodayTests/') for lane in ('unit', 'integration') for x in lanes[lane]))
        self.assertTrue(all(x.startswith('TodaySnapshotTests/') for x in lanes['snapshot']))
        expected = lanes['unit'] + lanes['integration']
        report = xcode_tests.completed_report(CONTRACT, expected, 'unit', tree(expected), 0, '')
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(report['expected_count'], len(expected))
        with self.assertRaises(ValueError):
            xcode_tests.selected(CONTRACT, ROOT, ['integration'], ['NativeSnapshotTests'])
        with self.assertRaises(ValueError):
            xcode_tests.selected(CONTRACT, ROOT, ['integration'], ['Missing/testMissing'])
        with self.assertRaises(ValueError):
            xcode_tests.selected(CONTRACT, ROOT, ['unit'])

    def test_swift_testing_and_xctest_dispatch_use_their_actual_identifiers(self):
        swift = 'TodayTests/StoreUpgradeTests/oldStoreOpensWithCurrentSchema'
        xctest = 'TodaySnapshotTests/NativeSnapshotTests/testHealthStepsLight'
        self.assertEqual(xcode_tests.execution_selectors(CONTRACT, ROOT, [swift, xctest]), [swift + '()', xctest])
        with self.assertRaisesRegex(ValueError, 'Missing execution framework'):
            xcode_tests.execution_selectors(CONTRACT, ROOT, ['TodayTests/Unknown/missing'])

    def test_fail_closed_completed_leaves(self):
        cases = [
            (tree([]), 0, '', None, 'parser_error'),
            (tree([METHOD + 'Extra']), 0, '', None, 'unexpected_tests'),
            (tree([METHOD], 'Skipped'), 0, '', None, 'unexpected_skip'),
            (tree([METHOD], 'Mystery'), 0, '', None, 'parser_error'),
            (tree([METHOD]), 65, '', None, 'process_exit:65'),
            (tree([METHOD]), 0, 'BadSelector: unknown test', None, 'log_diagnostic'),
            (tree([METHOD]), 0, '', 'invalid JSON', 'parser_error'),
            ({'passedTests': 1}, 0, '', None, 'parser_error'),
            (tree([METHOD]).get('testNodes') + tree([METHOD], 'Failed')['testNodes'],
             0, '', None, 'test_failure'),
            (tree([METHOD]), 0, "Test Case '-[StoreUpgradeTests frozenStoreReopensAndMutates]' failed", None, 'log_failure'),
        ]
        for data, code, raw, error, expected_error in cases:
            with self.subTest(expected_error=expected_error, data=data):
                report = xcode_tests.completed_report(CONTRACT, [METHOD], 'integration', data, code, raw, error)
                self.assertEqual(report['status'], 'failed')
                self.assertIn(expected_error, report['errors'])
        report = xcode_tests.completed_report(CONTRACT, [METHOD, METHOD + 'Missing'], 'integration', tree([METHOD]), 0, '')
        self.assertIn('missing_tests', report['errors'])
        report = xcode_tests.completed_report(CONTRACT, [], 'integration', tree([METHOD]), 0, '')
        self.assertIn('zero_expected', report['errors'])

    def run_mocked(self, directory, *, process_exit=0, parser_exit=0, active=False, missing_bundle=False, summary_fail=False, snapshot=False):
        calls, locks = [], []
        journal = Mock()
        evidence = SimpleNamespace(path=directory / 'initial.log', journal=journal, session='synthetic',
                                   record=Mock(), close=Mock())

        @contextmanager
        def lock(*args):
            locks.append(args)
            yield
            locks.pop()

        def process(argv, *, cwd, evidence, timeout):
            self.assertEqual(len(locks), 4)
            calls.append(argv)
            content, code = '', 0
            if argv[:4] == ['xcrun', 'simctl', 'list', 'devices']:
                devices = [] if not active else [{'name': xcode_tests.simulator_name(ROOT),
                    'deviceTypeIdentifier': xcode_tests.DEVICE, 'state': 'Booted',
                    'udid': '00000000-0000-0000-0000-000000000001'}]
                content = json.dumps({'devices': {xcode_tests.RUNTIME: devices}})
            elif argv[:3] == ['xcrun', 'simctl', 'create']:
                content = '00000000-0000-0000-0000-000000000001'
            elif argv[0] == 'xcodebuild':
                if not missing_bundle:
                    Path(argv[argv.index('-resultBundlePath') + 1]).mkdir()
                    (Path(argv[argv.index('-resultBundlePath') + 1]) / 'raw').write_text('completed')
                code = process_exit
            elif argv[:3] == ['xcrun', 'xcresulttool', 'get']:
                self.assertTrue(any(c[0] == 'xcodebuild' for c in calls[:-1]))
                content = json.dumps({'failedTests': int(summary_fail)} if 'summary' in argv else tree([METHOD]))
                code = parser_exit
            evidence.path.write_text(content)
            return SimpleNamespace(returncode=code, log=evidence.path)

        with patch.multiple(xcode_tests, host_lock=lock, dd_lock=lock, ResourceLock=lock), \
                patch.object(xcode_tests, 'Evidence', return_value=evidence), \
                patch.object(xcode_tests, 'run_process', side_effect=process), \
                patch('scripts.devtools.resolve.locked_arguments', return_value=['-disableAutomaticPackageResolution']), \
                patch.object(xcode_tests, 'selected', return_value=({'snapshot': [METHOD]} if snapshot else {'unit': [METHOD], 'integration': [METHOD]})):
            if active:
                with self.assertRaisesRegex(ValueError, 'shutdown'):
                    xcode_tests.run(ROOT, CONTRACT, ['ios-unit', 'integration'])
                return calls, journal, []
            code = xcode_tests.run(ROOT, CONTRACT, ['ios-unit', 'integration'])
        reports = list(directory.rglob('*.report.json'))
        return calls, journal, (code, json.loads(reports[0].read_text()))

    def test_real_command_shape_union_lifecycle_and_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            calls, journal, (code, report) = self.run_mocked(Path(temporary))
        self.assertEqual(code, 0)
        builds = [c for c in calls if c[0] == 'xcodebuild']
        self.assertEqual(len(builds), 1)
        build = builds[0]
        self.assertEqual(build[1], 'test')
        self.assertEqual(build[build.index('-scheme') + 1], 'TodayTests')
        self.assertEqual(build[build.index('-derivedDataPath') + 1], str(xcode_tests.derived_data(ROOT)))
        self.assertEqual(build.count('-only-testing:' + METHOD + '()'), 1)
        self.assertEqual(calls[-1][:3], ['xcrun', 'simctl', 'shutdown'])
        self.assertEqual(report['status'], 'passed')
        self.assertGreaterEqual(journal.artifact.call_count, 2)

    def test_nonzero_and_parser_exits_stay_failed_and_shutdown(self):
        for options in ({'process_exit': 65}, {'parser_exit': 1}, {'missing_bundle': True}, {'summary_fail': True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as temporary:
                calls, _, (code, report) = self.run_mocked(Path(temporary), **options)
                self.assertNotEqual(code, 0)
                self.assertEqual(report['status'], 'failed')
                self.assertEqual(calls[-1][:3], ['xcrun', 'simctl', 'shutdown'])

    def test_snapshot_uses_its_separate_generated_scheme(self):
        with tempfile.TemporaryDirectory() as temporary:
            calls, _, (code, _) = self.run_mocked(Path(temporary), snapshot=True)
        self.assertEqual(code, 0)
        build = next(c for c in calls if c[0] == 'xcodebuild')
        self.assertEqual(build[build.index('-scheme') + 1], 'TodaySnapshotTests')

    def test_busy_owned_device_is_never_shutdown_or_used(self):
        with tempfile.TemporaryDirectory() as temporary:
            calls, _, _ = self.run_mocked(Path(temporary), active=True)
        self.assertEqual(len(calls), 1)

    def test_cli_routes_ios_unit_without_launching_tools(self):
        with patch.object(commands, 'test', return_value=0) as test:
            self.assertEqual(main(['test', 'ios-unit', '--only', 'SceneRegistryTests'], ROOT), 0)
        test.assert_called_once_with(ROOT, 'ios-unit', only=['SceneRegistryTests'], full=False)

    def test_full_collection_once_in_order_retains_first_failure(self):
        events = []

        @contextmanager
        def lock(root):
            yield

        def execute(root, argv, **kwargs):
            events.append(argv[0])
            self.assertFalse(kwargs['heavy'])
            return SimpleNamespace(returncode=0, log=Path(__file__))

        def run(*args, **kwargs):
            events.append('xcode')
            self.assertEqual(args[2], ['ios-unit', 'integration', 'snapshot'])
            self.assertTrue(kwargs['locked'])
            return 65

        fake = Mock()
        fake.load_manifest.return_value = {'skip_rules': []}
        fake.plan.return_value = {'selectors': {'logic': [METHOD]}}
        fake.report.return_value = {'status': 'failed', 'executed_count': 0, 'missing': [METHOD]}
        with patch.multiple(commands, host_lock=lock, dd_lock=lock), \
                patch.object(commands, 'testing_contract', return_value=fake), \
                patch.object(commands, 'generate', return_value=0), \
                patch.object(commands, 'execute', side_effect=execute), \
                patch.object(commands, 'atomic_json'), patch.object(commands, 'Evidence'), \
                patch.object(xcode_tests, 'run', side_effect=run):
            self.assertEqual(commands.test(ROOT, 'release', full=True), 1)
        self.assertEqual(events, ['swift', 'xcode'])
        with self.assertRaises(ValueError):
            commands.test(ROOT, 'release')
        with self.assertRaises(ValueError):
            commands.test(ROOT, 'release', full=True, only=['*'])


if __name__ == '__main__':
    unittest.main()
