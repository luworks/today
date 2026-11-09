"""Serial Xcode test authorities with completed leaf evidence and no build cache bypass."""
from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import tempfile
import time
import uuid

from .core import (NativeBuildError, ResourceLock, atomic_json, ci_test_scheme, dd_lock, derived_data,
                   ensure_test_products, fingerprint, host_lock, native_test_options, provenance)
from .process import Evidence, Redactor, run_process

SCHEMES = {'unit': 'TodayTests', 'integration': 'TodayTests', 'snapshot': 'TodaySnapshotTests'}
DEVICE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'


def test_scheme(lane):
    return ci_test_scheme(SCHEMES[lane])


def simulator_name(root):
    return 'Today-Dev-' + derived_data(root).name[:8]


def execution_selectors(contract, root, expected):
    """Swift Testing function identifiers include parentheses; XCTest selectors do not."""
    frameworks = {}
    for suites in contract.inventory(root).values():
        for suite in suites:
            for method in suite['methods']:
                identifier = '/'.join(filter(None, (suite['target'], suite['suite'], method['name'])))
                frameworks[identifier] = method['framework']
    result = []
    for identifier in expected:
        framework = frameworks.get(identifier)
        if framework not in ('SwiftTesting', 'XCTest'):
            raise ValueError('Missing execution framework: ' + identifier)
        result.append(identifier + ('()' if framework == 'SwiftTesting' else ''))
    return result


def selected(contract, root, groups, only=()):
    source = contract.inventory(root)
    plan = contract.plan(list(groups), source)
    lanes = {lane: values for lane, values in plan['selectors'].items() if values}
    if not lanes or set(lanes) - set(SCHEMES):
        raise ValueError('Xcode adapter requires only iOS unit, integration or snapshot lanes')
    if only:
        narrowed = {lane: [] for lane in lanes}
        for value in only:
            matches = {}
            for lane in lanes:
                try:
                    matches[lane] = contract.expand([value], source, lane)
                except ValueError:
                    continue
            if not matches:
                raise ValueError('Unknown selection: ' + value)
            for lane, ids in matches.items():
                if set(ids) - set(lanes[lane]):
                    raise ValueError('Selection outside requested group: ' + value)
                narrowed[lane].extend(ids)
        lanes = {lane: list(dict.fromkeys(ids)) for lane, ids in narrowed.items() if ids}
    return lanes


def completed_report(contract, expected, lane, data, exit_code, raw_log, parser_error=None):
    attempts = []
    try:
        if parser_error:
            raise ValueError(parser_error)
        attempts = contract.xcresult_attempts(data, lane)
    except (ValueError, TypeError, KeyError) as error:
        parser_error = str(error)
    reasons = {a['test']: a['reason'] for a in contract.log_attempts(raw_log, lane)
               if a['status'] == 'skipped' and a['reason']}
    for attempt in attempts:
        if attempt['status'] == 'skipped' and not attempt.get('reason'):
            attempt['reason'] = reasons.get(attempt['test'], '')
    report = contract.report(expected, attempts, exit_code=exit_code, raw_log=raw_log,
                             allowed_skips=['benchmark', 'export'] if lane == 'unit' else [],
                             skip_rules=contract.load_manifest()['skip_rules'])
    if parser_error:
        report['status'] = 'failed'
        report['coverage_status'] = 'incomplete'
        report['errors'] = list(dict.fromkeys([*report['errors'], 'parser_error']))
        report['parser_detail'] = parser_error
    return report


def run(root, contract, groups, *, only=(), timeout=600, locked=False, reuse=False):
    """Caller may hold the shared host/DD locks across a final serial collection."""
    lanes = selected(contract, root, groups, only)
    if not lanes or any(not ids for ids in lanes.values()):
        raise ValueError('At least one expected test per lane required')
    batches = {}
    for lane, ids in lanes.items():
        batch = batches.setdefault(test_scheme(lane), {'lane': lane, 'expected': []})
        batch['expected'].extend(ids)
    first_failure = 0
    with ExitStack() as stack:
        if not locked:
            stack.enter_context(host_lock(root))
            stack.enter_context(dd_lock(root))
        # Exclusive simulator-name and DerivedData locks.
        for key in sorted(['name:' + simulator_name(root), 'cache:' + str(derived_data(root).resolve())]):
            path = Path(tempfile.gettempdir()) / ('today-qa-lock-' + hashlib.sha256(key.encode()).hexdigest())
            stack.enter_context(ResourceLock(path, str(root)))
        evidence = Evidence(root, 'dev-xcode-' + uuid.uuid4().hex, Redactor())
        stack.callback(evidence.close)
        output = evidence.path.parent / (evidence.path.stem + '-xcode')
        output.mkdir()

        def invoke(command):
            # Each process owns a unique raw log, indexed by the existing QA helper.
            evidence.path = output / (uuid.uuid4().hex + '.log')
            started = time.monotonic()
            result = run_process(command, cwd=root, evidence=evidence, timeout=timeout)
            print(json.dumps({'native_command': command[:2], 'seconds': round(time.monotonic() - started, 3),
                              'exit': result.returncode, 'log': str(result.log)}))
            return result

        def capture(command):
            result = invoke(command)
            if result.returncode:
                raise ValueError('Command failed: ' + str(command) + '; log=' + str(result.log))
            return result.log.read_text()

        simulator = None
        owned = False
        try:
            devices = json.loads(capture(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
            matches = [dict(device, runtime=runtime) for runtime, values in devices['devices'].items()
                       for device in values if device['name'] == simulator_name(root)]
            if len(matches) > 1:
                raise ValueError('Ambiguous owned simulator name')
            if matches:
                device = matches[0]
                if (device.get('deviceTypeIdentifier') != DEVICE or device['runtime'] != RUNTIME
                        or device['state'] != 'Shutdown'):
                    raise ValueError('Owned simulator must be shutdown with the canonical model/runtime')
                simulator = device['udid']
            else:
                simulator = capture(['xcrun', 'simctl', 'create', simulator_name(root), DEVICE, RUNTIME]).strip()
            # Validate before passing a captured identifier back into platform commands.
            uuid.UUID(simulator)
            for scheme, batch in batches.items():
                bundle = output / (scheme + '.xcresult')
                expected = list(dict.fromkeys(batch['expected']))
                from .resolve import locked_arguments
                flags = locked_arguments(root)
                identity = None
                if reuse:
                    started = time.monotonic()
                    try:
                        test_run = ensure_test_products(root, scheme, invoke, flags=flags)
                    except NativeBuildError as exc:
                        first_failure = first_failure or exc.returncode
                        # A failed build has no xcresult test leaves. Retain a
                        # failed receipt and its owned logs instead of hiding
                        # the first failure behind a missing-receipt error.
                        report = completed_report(contract, expected, batch['lane'], None,
                                                  exc.returncode, '', 'build_for_testing_failed')
                        report['errors'].append('native_build_exit:' + str(exc.returncode))
                        report['build_error'] = str(exc)
                        path = output / (scheme + '.report.json')
                        atomic_json(path, report)
                        evidence.journal.artifact(evidence.session, path)
                        print(json.dumps({'report': str(path), 'status': report['status']}))
                        continue
                    print(json.dumps({'native_phase': 'ensure_test_products',
                                      'seconds': round(time.monotonic() - started, 3)}))
                    started = time.monotonic()
                    identity = fingerprint(root, scheme=scheme, architecture='arm64')
                    if not provenance(root, identity, kind='build-for-testing', xctestrun=test_run)['valid']:
                        raise ValueError('Test products changed before dispatch')
                    print(json.dumps({'native_phase': 'validate_before_dispatch',
                                      'seconds': round(time.monotonic() - started, 3)}))
                    command = ['xcodebuild', 'test-without-building', '-xctestrun', str(test_run)]
                else:
                    # Legacy direct test always builds; it never consumes cached provenance.
                    command = ['xcodebuild', 'test', '-project', 'ios/Today.xcodeproj', '-scheme', scheme,
                               '-configuration', 'Debug', '-sdk', 'iphonesimulator']
                # A cold simulator can saturate small hosted runners. Complete
                # the trusted build before boot, then require test readiness.
                if not owned:
                    owned = True
                    capture(['xcrun', 'simctl', 'boot', simulator])
                # Routine CI's separate readiness process returned "already
                # booted" after ~118s. XCTest owns destination readiness and
                # must still produce every fresh selected leaf before passing.
                if not native_test_options():
                    capture(['xcrun', 'simctl', 'bootstatus', simulator, '-b'])
                result = invoke([*command,
                                 '-destination', 'platform=iOS Simulator,id=' + simulator,
                                 '-derivedDataPath', str(derived_data(root)), '-resultBundlePath', str(bundle),
                                 '-jobs', '2', '-collect-test-diagnostics', 'never', '-parallel-testing-enabled', 'NO',
                                 '-maximum-concurrent-test-simulator-destinations', '1',
                                 '-maximum-parallel-testing-workers', '1',
                                 *native_test_options(), '-showBuildTimingSummary', *flags, *['-only-testing:' + value for value in execution_selectors(contract, root, expected)]])
                raw = result.log.read_text()
                data, error, summary = None, None, None
                try:
                    if not bundle.is_dir():
                        raise ValueError('Missing completed xcresult bundle')
                    summary = json.loads(capture(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                                  '--path', str(bundle), '--format', 'json']))
                    if not isinstance(summary, dict):
                        raise ValueError('Malformed xcresult summary')
                    data = json.loads(capture(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
                                               '--path', str(bundle), '--format', 'json']))
                except (OSError, ValueError, TypeError) as exc:
                    error = str(exc)
                report = completed_report(contract, expected, batch['lane'], data, result.returncode, raw, error)
                if summary and summary.get('failedTests', 0) and not any(
                        attempt['status'] == 'failed' for attempt in report['attempts']):
                    report['status'] = 'failed'
                    report['coverage_status'] = 'incomplete'
                    report['errors'].append('xcresult_summary_failure')
                if identity is not None and fingerprint(root, scheme=scheme, architecture='arm64') != identity:
                    report['status'] = 'failed'
                    report['coverage_status'] = 'incomplete'
                    report['errors'].append('source_changed_during_test')
                path = output / (scheme + '.report.json')
                atomic_json(path, report)
                evidence.journal.artifact(evidence.session, path)
                # Only index a completed bundle after the owned xcodebuild has exited.
                if bundle.is_dir():
                    for artifact in sorted(bundle.rglob('*')):
                        if artifact.is_file() and not artifact.is_symlink():
                            evidence.journal.artifact(evidence.session, artifact)
                evidence.record(json.dumps({'scheme': scheme, 'report': str(path), 'status': report['status']}),
                                report['status'])
                print(json.dumps({'report': str(path), 'status': report['status']}))
                first_failure = first_failure or result.returncode or (report['status'] != 'passed')
        finally:
            if owned:
                shutdown = invoke(['xcrun', 'simctl', 'shutdown', simulator])
                first_failure = first_failure or shutdown.returncode
    return int(first_failure)
