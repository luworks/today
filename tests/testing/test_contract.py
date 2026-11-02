"""Synthetic host contracts; no Xcode/Swift/Simulator invocation."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/testing'))
import contract as c  # noqa: E402 - standalone test import bootstrap


def tree(*results):
    return {'testNodes': [{'nodeType': 'Test Plan', 'result': 'Passed', 'children': [
        {'nodeType': 'Test Case', 'nodeIdentifier': test, 'result': status, 'skipReason': reason}
        for test, status, reason in results]}]}


class ExecutionContract(unittest.TestCase):
    expected = ['TodayUITests/Sample/testOne', 'TodayUITests/Sample/testTwo']

    def report(self, data, **kwargs):
        return c.report(self.expected, c.xcresult_attempts(data), **kwargs)

    def test_modern_xctest_and_swift_testing_leaves(self):
        result = self.report(tree(('OneUITests/Sample/testOne()', 'Passed', ''),
                                  ('Sample/testTwo()', 'Passed', '')))
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(result['executed_count'], 2)
        self.assertEqual(result['counts'], {'passed': 2})

    def test_legacy_typed_xcresult(self):
        data = {'tests': {'_values': [{'identifier': {'_value': 'Sample/testOne()'},
                                     'testStatus': {'_value': 'Success'}}]}}
        self.assertEqual(c.xcresult_attempts(data)[0]['test'], self.expected[0])

    def test_zero_and_parser_error(self):
        for data in ({}, {'testNodes': [{'nodeType': 'Test Suite', 'result': 'Passed'}]},
                     tree(('Sample/testOne', 'Unknown', ''))):
            with self.subTest(data=data), self.assertRaises(ValueError):
                c.xcresult_attempts(data)
        self.assertIn('zero_executed', c.report(self.expected, [])['errors'])

    def test_missing_method_cannot_be_hidden_by_other_test(self):
        result = self.report(tree(('Sample/testOne', 'Passed', ''), ('Other/testOther', 'Passed', '')))
        self.assertEqual(result['missing'], [self.expected[1]])
        self.assertEqual(result['status'], 'failed')

    def test_first_failure_is_retained_even_if_later_passes(self):
        result = self.report(tree(('Sample/testOne', 'Failed', ''), ('Sample/testOne', 'Passed', ''),
                                  ('Sample/testTwo', 'Passed', '')))
        self.assertEqual(result['status'], 'failed')
        self.assertEqual([a['status'] for a in result['attempts']], ['failed', 'passed', 'passed'])

    def test_skip_requires_explicit_category_exact_method_and_reason(self):
        rules = [{'test': 'Sample/testTwo', 'category': 'hardware', 'reason': 'real device'}]
        data = tree(('Sample/testOne', 'Passed', ''), ('Sample/testTwo', 'Skipped', 'requires real device'))
        self.assertEqual(self.report(data, skip_rules=rules)['status'], 'failed')
        good = self.report(data, skip_rules=rules, allowed_skips=['hardware'])
        self.assertEqual(good['status'], 'passed')
        self.assertEqual(good['counts'], {'passed': 1, 'skipped': 1})
        self.assertEqual(good['coverage_status'], 'incomplete')
        for test, reason in [('Sample/testTwo', 'unexpected permission failure'), ('Sample/testOne', 'real device')]:
            bad = self.report(tree((test, 'Skipped', reason)), skip_rules=rules, allowed_skips=['hardware'])
            self.assertEqual(bad['status'], 'failed')

    def test_all_allowed_skips_still_fails_zero_execution(self):
        rules = [{'test': t, 'category': 'time', 'reason': 'late'} for t in self.expected]
        result = self.report(tree(*[(t, 'Skipped', 'late') for t in self.expected]),
                             skip_rules=rules, allowed_skips=['time'])
        self.assertIn('zero_executed', result['errors'])

    def test_badselector_parsererror_and_nonzero_exit_fail(self):
        data = tree(*[(t, 'Passed', '') for t in self.expected])
        for kwargs in ({'raw_log': 'badselector'}, {'raw_log': 'ParserError: invalid'},
                       {'raw_log': 'No matching test cases were run'}, {'exit_code': 65}):
            self.assertEqual(self.report(data, **kwargs)['status'], 'failed')

    def test_xctest_and_swift_testing_logs_not_aggregate_counts(self):
        text = """Test Case '-[OneLogicTests.Legacy testOne]' passed (0.1 seconds).
◇ Test modern() started.
✔ Test modern() passed after 0.001 seconds.
✘ Test failedModern() failed after 0.001 seconds with 1 issue.
↷ Test skippedModern() skipped: disabled
Executed 999 tests, with 0 failures
✔ Test run with 999 tests passed after 0.002 seconds.
"""
        attempts = c.log_attempts(text)
        self.assertEqual([a['status'] for a in attempts], ['passed', 'passed', 'failed', 'skipped'])
        self.assertEqual(attempts[0]['test'], 'TodayTests/Legacy/testOne')
        result = c.report(['TodayTests/New/modern'], attempts[1:2])
        self.assertEqual(result['status'], 'passed')

    def test_discovery_swift_testing_attributes_extensions_and_xctest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'Both.swift').write_text('''import Testing
struct NewSuite {
 @Test("a descriptive name", arguments: [1, 2])
 func accepts(value: Int) {}
 func helper() {}
}
extension NewSuite {
 @Test func another() async throws {}
}
final class Legacy: XCTestCase {
 func testExisting() {}
 // func testFiction() {}
}
''')
            suites = c.discover(root, root)
        self.assertEqual({s['suite']: [m['name'] for m in s['methods']] for s in suites},
                         {'NewSuite': ['accepts', 'another'], 'Legacy': ['testExisting']})
        self.assertEqual(suites[0]['methods'][0]['framework'], 'SwiftTesting')

    def test_all_manifest_groups_reference_actual_sources(self):
        source = c.inventory()
        for group in ('unit', 'integration', 'ui', 'core', 'snapshot', 'accessibility', 'release'):
            result = c.plan([group], source)
            self.assertTrue(any(result['selectors'].values()))
        self.assertFalse(c.plan(['accessibility'])['pending'])
        original = c.load_manifest()['migration']['original_inventory']
        self.assertTrue(set(c.available(original, 'ui')) <= set(c.available(source, 'ui')))
        with self.assertRaises(ValueError):
            c.expand(['OneUITests/NoSuite/testMissing'], source, 'ui')

    def test_cli_parser_errors_are_machine_readable_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'invalid.json'
            path.write_text('{broken')
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/testing/test-contract.py'),
                'report', '--group', 'core', '--lane', 'ui', '--xcresult-json', str(path)],
                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['errors'], ['parser_error'])



class CurrentBatchAuthority(unittest.TestCase):
    @staticmethod
    def source(*entries):
        return {'logic': [{'target': target, 'suite': suite,
                           'methods': [{'name': method, 'framework': 'SwiftTesting'}
                                       for method in methods]}
                          for target, suite, methods in entries]}

    def test_native_host_target_suite_collision_and_explicit_wrong_targets(self):
        for lane in ('unit', 'integration', 'snapshot', 'ui'):
            target = c.lane_settings(lane)['target']
            expected = target + '/SceneRegistryTests/check'
            attempts = c.xcresult_attempts(tree(('SceneRegistryTests/check()', 'Passed', '')), lane)
            self.assertEqual(attempts[0]['test'], expected)
            for wrong in ('TodayUITests/SceneRegistryTests/check',
                          'SceneRegistryTests/SceneRegistryTests/check'):
                if wrong == expected:
                    continue
                result = c.report([expected], c.xcresult_attempts(tree((wrong, 'Passed', '')), lane))
                self.assertIn('missing_tests', result['errors'])
        self.assertEqual(c.canonical('TodayUITests/check()', 'unit'), 'TodayUITests/check')

    def test_swift_testing_suite_batches_use_authoritative_host_inventory(self):
        source = self.source(('TodayTests', 'First', ['same']), ('SceneRegistryTests', 'Second', ['same']))
        text = """◇ Suite First started.
◇ Test same() started.
✔ Test same() passed after 0.1 seconds.
✔ Suite First passed after 0.1 seconds.
◇ Suite Second started.
◇ Test same() started.
✔ Test same() passed after 0.1 seconds.
✔ Suite Second passed after 0.1 seconds.
"""
        attempts = c.log_attempts(text, source=source)
        self.assertEqual([a['test'] for a in attempts], ['TodayTests/First/same', 'SceneRegistryTests/Second/same'])
        self.assertEqual(c.report(c.available(source, 'logic'), attempts)['status'], 'passed')

    def test_concurrent_distinct_methods_resolve_without_latest_suite_guess(self):
        source = self.source(('TodayTests', 'First', ['one']), ('SceneRegistryTests', 'Second', ['two']))
        text = """◇ Suite First started.
◇ Test one() started.
◇ Suite Second started.
◇ Test two() started.
✔ Test one() passed after 0.1 seconds.
✔ Suite First passed after 0.1 seconds.
✔ Test two() passed after 0.1 seconds.
"""
        self.assertEqual(c.report(c.available(source, 'logic'), c.log_attempts(text, source=source))['status'], 'passed')

    def test_ambiguous_unknown_and_wrong_suite_cannot_be_rescued_by_unique_method(self):
        cases = [
            (self.source(('TodayTests', 'Same', ['check']), ('SceneRegistryTests', 'Same', ['check'])),
             '◇ Suite Same started.\n✔ Test check() passed after 0.1 seconds.'),
            (self.source(('TodayTests', 'First', ['check']), ('TodayTests', 'Second', ['check'])),
             '◇ Suite First started.\n◇ Suite Second started.\n✔ Test check() passed after 0.1 seconds.'),
            (self.source(('TodayTests', 'Real', ['check'])),
             '◇ Suite Fake started.\n✔ Test check() passed after 0.1 seconds.'),
            (self.source(('TodayTests', 'Real', ['check'])),
             '◇ Suite Real started.\n◇ Suite Fake started.\n✔ Test check() passed after 0.1 seconds.'),
            (self.source(('TodayTests', 'Real', ['check'])),
             '◇ Suite Real started.\n✔ Test unknown() passed after 0.1 seconds.'),
        ]
        for source, text in cases:
            with self.subTest(text=text):
                result = c.report(c.available(source, 'logic'), c.log_attempts(text, source=source))
                self.assertEqual(result['status'], 'failed')
                self.assertIn('parser_error', result['errors'])
        source = self.source(('TodayTests', 'Real', ['check']))
        for identifier in ('TodayUITests/Real/check()', 'TodayUITests/check()',
                           '-[TodayUITests.Real check]'):
            terminal = ("Test Case '" + identifier + "' passed (0.1 seconds)." if identifier.startswith('-[')
                        else '✔ Test ' + identifier + ' passed after 0.1 seconds.')
            result = c.report(c.available(source, 'logic'), c.log_attempts(
                '◇ Suite Real started.\n' + terminal, source=source))
            self.assertIn('missing_tests', result['errors'])

    def test_concurrent_same_method_and_first_failure_remain_failures(self):
        source = self.source(('TodayTests', 'First', ['check']), ('SceneRegistryTests', 'Second', ['check']))
        text = """◇ Suite First started.
◇ Test check() started.
◇ Suite Second started.
◇ Test check() started.
✘ Test check() failed after 0.1 seconds.
✔ Test check() passed after 0.1 seconds.
"""
        result = c.report(c.available(source, 'logic'), c.log_attempts(text, source=source))
        self.assertIn('parser_error', result['errors'])
        self.assertIn('test_failure', result['errors'])
        self.assertEqual([a['status'] for a in result['attempts']], ['failed', 'passed'])
        source = self.source(('SceneRegistryTests', 'First', ['check']))
        text = '◇ Suite First started.\n✘ Test check() failed after 0.1 seconds.\n✔ Test check() passed after 0.1 seconds.'
        result = c.report(c.available(source, 'logic'), c.log_attempts(text, source=source))
        self.assertIn('test_failure', result['errors'])
        self.assertEqual(result['missing'], [])

    def test_xctest_skip_reasons_are_exact_and_consumed_per_attempt(self):
        text = """Test Case '-[TodayTests.Real testOne]' started.
/path/Test.swift:12: -[TodayTests.Other testOne] : Test skipped - unrelated
/path/Test.swift:13: -[TodayTests.Real testOne] : Test skipped - set OPT_IN=1
Test Case '-[TodayTests.Real testOne]' skipped (0.001 seconds).
Test Case '-[TodayTests.Real testOne]' passed (0.001 seconds).
Test Case '-[TodayTests.Real testOne]' skipped (0.001 seconds).
"""
        attempts = c.log_attempts(text)
        self.assertEqual([a['reason'] for a in attempts], ['set OPT_IN=1', '', ''])
        self.assertEqual(len(attempts), 3)
        self.assertEqual(c.log_attempts('↷ Test skippedModern() skipped: disabled')[0]['reason'], 'disabled')


class RunnerIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('runner_contract_test', ROOT / 'ios/Eval/run-e2e.py')
        cls.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.runner)

    def test_legacy_selectors_translate_target_and_keep_project_contract(self):
        r = self.runner
        args = r.parser().parse_args(['--only', 'OneUITests/JourneyTests/testJ3_completeAndUndo'])
        selectors = r.selectors(args, r.inventory())
        self.assertEqual(selectors, ['TodayUITests/JourneyTests/testJ3_completeAndUndo'])
        command = r.ui_command(selectors, 'owned', Path('/cache'), Path('/evidence'))
        self.assertEqual(command[command.index('-project') + 1], 'Today.xcodeproj')
        self.assertEqual(command[command.index('-scheme') + 1], 'TodayMock')
        self.assertIn('-only-testing:TodayUITests/JourneyTests/testJ3_completeAndUndo', command)
        self.assertNotIn('-retry-tests-on-failure', command)
        self.assertNotIn('-test-iterations', command)

    def test_unit_plan_never_schedules_a_simulator(self):
        r = self.runner
        with patch.object(r.subprocess, 'run', side_effect=AssertionError('platform runner')), \
             patch.object(r.subprocess, 'check_output', side_effect=AssertionError('platform probe')), \
             contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(r.main(['--group', 'unit', '--dry-run']), 0)
        self.assertEqual(json.loads(out.getvalue())['commands'], [['swift', 'test', '--jobs', '2']])

    def test_structured_outputs_and_skip_details_are_retained(self):
        r = self.runner
        class Journal:
            def action(self, command, function, **kwargs):
                kind = command[4]
                data = {'summary': {'passedTests': 1, 'skippedTests': 1},
                        'tests': tree(('Sample/testOne', 'Passed', ''), ('Sample/testTwo', 'Skipped', '')),
                        'test-details': {'testIdentifier': 'Sample/testTwo', 'skipReason': 'real device'}}[kind]
                json.dump(data, kwargs['stdout'])
                return subprocess.CompletedProcess(command, 0)
            def record(self, *args, **kwargs):
                pass
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(r.subprocess, 'run', side_effect=AssertionError('platform runner')):
            output = Path(tmp)
            (output / 'ui.xcresult').mkdir()
            attempts = r.read_xcresult(output, Journal())
            self.assertIn('real device', attempts[1]['reason'])
            self.assertTrue((output / 'xcresult-tests.json').exists())
            self.assertTrue((output / 'xcresult-test-details-1.json').exists())

    def test_successful_process_with_missing_bundle_fails(self):
        r = self.runner
        with tempfile.TemporaryDirectory() as tmp:
            real_journal = r.Journal
            output = Path(tmp) / 'evidence'
            with patch.object(r, 'Journal', side_effect=lambda: real_journal(Path(tmp) / 'qa.sqlite')), \
                 patch.object(r, 'capture', return_value='host-fixture-head'), \
                 patch.object(r, 'select_simulator', return_value='owned-id'), \
                 patch.object(r, 'run_logged', return_value=0), \
                 patch.object(r.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(r.main(['--group', 'core', '--output', str(output)]), 1)
            summary = json.loads((output / 'summary.json').read_text())
            self.assertEqual(summary['reports']['ui']['errors'], ['parser_error'])
            self.assertEqual(summary['status'], 'failed')

    def test_wrong_suite_cannot_satisfy_key_method(self):
        result = c.report(['TodayUITests/Key/testOne'], [
            {'test': 'TodayUITests/Other/testOne', 'status': 'passed'}])
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['missing'], ['TodayUITests/Key/testOne'])


class DiscoveryRegression(unittest.TestCase):
    def test_strings_cannot_end_suite_or_inject_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'Strings.swift').write_text('''final class Real: XCTestCase {
 let json = "} https://example.com/{ class Fake: XCTestCase {"
 func testAfterJSON() {}
}
@Test func topLevel() {}
''')
            source = c.discover(root, root)
        self.assertEqual({s['suite']: [m['name'] for m in s['methods']] for s in source},
                         {'Real': ['testAfterJSON'], '': ['topLevel']})
        self.assertEqual(c.canonical('NewSuite/parameterized(_:)'), 'TodayUITests/NewSuite/parameterized')

    def test_original_logic_inventory_has_no_disappearing_methods(self):
        original = c.load_manifest()['migration']['original_inventory']
        self.assertTrue(set(c.available(original, 'logic')) <= set(c.available(c.inventory(), 'logic')))

    def test_failed_log_attempt_survives_final_structured_pass(self):
        attempts = c.xcresult_attempts(tree(('Sample/testOne', 'Passed', '')))
        result = c.report(['TodayUITests/Sample/testOne'], attempts,
            raw_log="Test Case '-[OneUITests.Sample testOne]' failed (0.1 seconds).")
        self.assertIn('log_failure', result['errors'])


class LaneAuthority(unittest.TestCase):
    def test_real_authorities_select_executable_methods(self):
        source = c.inventory()
        integration = c.plan(['integration'], source)
        self.assertIn('TodayTests/StoreUpgradeTests/oldStoreOpensWithCurrentSchema',
                      integration['selectors']['integration'])
        self.assertCountEqual(integration['selectors']['integration'], c.available(source, 'integration'))
        self.assertFalse(integration['selectors']['ui'])
        snapshots = c.plan(['snapshot'], source)
        self.assertIn('TodaySnapshotTests/NativeSnapshotTests/testHealthDataPerturbationChangesPixels',
                      snapshots['selectors']['snapshot'])
        self.assertIn('TodaySnapshotTests/NativeSnapshotTests/testStopwatchRunningDigitalDark',
                      snapshots['expected_by_target']['snapshot']['TodaySnapshotTests'])
        self.assertFalse(snapshots['selectors']['ui'])
        self.assertEqual(c.plan(['accessibility'], source)['selectors']['ui'], [
            'TodayUITests/AccessibilityAuditTests/testCoreTabsAudit',
            'TodayUITests/AccessibilityAuditTests/testHealthDetailRangeAndDismissAudit',
            'TodayUITests/AccessibilityAuditTests/testStopwatchLargeTypeActionsAudit'])

    def test_host_and_ios_unit_target_membership_stays_separate(self):
        host = c.plan(['unit'])
        ios = c.plan(['ios-unit', 'integration'])
        method = 'SceneRegistryTests/persistedAutomationHandlesStayAvailable'
        self.assertIn('SceneRegistryTests/' + method, host['selectors']['logic'])
        self.assertIn('TodayTests/' + method, ios['selectors']['unit'])
        self.assertFalse(host['selectors']['integration'])
        self.assertFalse(any('StoreUpgradeTests/' in t for t in host['selectors']['logic']))
        self.assertEqual(set(ios['expected_by_target']['integration']), {'TodayTests'})
        self.assertEqual(host['lanes']['logic']['runner'], 'swiftpm')
        self.assertEqual(ios['lanes']['integration']['runner'], 'xcodebuild')

    def test_each_baseline_id_survives_in_host_and_ios_authorities(self):
        original = c.load_manifest()['migration']['original_inventory']
        source = c.inventory()
        for old_lane, new_lanes in [('logic', ['logic', 'unit']), ('ui', ['ui'])]:
            for lane in new_lanes:
                self.assertFalse(set(c.available(original, old_lane)) - set(c.available(source, lane)))

    def test_named_lane_parser_preserves_targets_and_rejects_wrong_target(self):
        for lane, identifier in [
            ('integration', 'TodayTests/StoreUpgradeTests/oldStoreOpensWithCurrentSchema'),
            ('snapshot', 'TodaySnapshotTests/NativeSnapshotTests/testHealthStepsLight'),
            ('logic', 'SceneRegistryTests/SceneRegistryTests/persistedAutomationHandlesStayAvailable')]:
            attempts = c.xcresult_attempts(tree((identifier + '()', 'Passed', '')), lane)
            self.assertEqual(c.report([identifier], attempts)['status'], 'passed')
            wrong = identifier.replace(identifier.split('/')[0], 'TodayUITests', 1)
            bad = c.xcresult_attempts(tree((wrong + '()', 'Passed', '')), lane)
            self.assertIn('missing_tests', c.report([identifier], bad)['errors'])
        self.assertEqual(c.canonical('SceneRegistryTests/persistedAutomationHandlesStayAvailable', 'logic'),
                         'SceneRegistryTests/SceneRegistryTests/persistedAutomationHandlesStayAvailable')

    def test_missing_sources_unknown_lanes_empty_and_cycles_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
            c.inventory(Path(tmp))
        with self.assertRaises(ValueError):
            c.canonical('Suite/method', 'nonexistent')
        with self.assertRaises(ValueError):
            c.canonical('Suite/method:invalid')
        source = {lane: [] for lane in c.SETTINGS['lanes']}
        with self.assertRaises(ValueError):
            c.plan(['unit'], source)
        for groups in [[], ['missing']]:
            with self.assertRaises(ValueError):
                c.plan(groups, source)
        for group in [{'includes': ['cycle']}, {'typo': ['*']}]:
            with self.assertRaises(ValueError):
                c.plan(['cycle'], source, {'groups': {'cycle': group}})
        self.assertIn('zero_expected', c.report([], [])['errors'])

    def test_unexpected_and_malformed_attempts_fail_instead_of_claiming_coverage(self):
        expected = ['TodaySnapshotTests/NativeSnapshotTests/testHealthStepsLight']
        for attempts in [[{'test': expected[0], 'status': 'unknown'}], [{}],
                         [{'test': None, 'status': []}]]:
            self.assertIn('parser_error', c.report(expected, attempts)['errors'])
        attempts = c.xcresult_attempts(tree((expected[0], 'Passed', ''),
            ('TodayUITests/Other/testUnexpected', 'Passed', '')), 'snapshot')
        self.assertIn('unexpected_tests', c.report(expected, attempts)['errors'])

    def test_discovery_ignores_helper_test_names_and_does_not_leak_top_level_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'Mixed.swift').write_text("""struct Helper {
 func testNotAnXCTest() {}
}
@Test func first() {}
func testTopLevelHelper() {}
@Test func second() {}
final class Actual: XCTestCase {
 func testReal() {
   func testLocalHelper() {}
 }
}
""")
            suites = c.discover(root, root)
            self.assertEqual({s['suite']: [m['name'] for m in s['methods']] for s in suites},
                             {'': ['first', 'second'], 'Actual': ['testReal']})
            (root / 'Broken.swift').write_text('struct Broken { @Test func missing() {')
            with self.assertRaises(ValueError):
                c.discover(root, root)


if __name__ == '__main__':
    unittest.main()
