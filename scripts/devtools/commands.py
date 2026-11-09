"""Real local adapters. The preview and test contracts retain orchestration ownership."""
import json
from pathlib import Path
import shutil
import sys
import time
import uuid

from .bootstrap import bootstrap as bootstrap_tools, BootstrapError
from .core import (atomic_json, dd_lock, derived_data, fingerprint, host_lock,
                   record_build, probe, state_root)
from .process import Evidence, Redactor, run_process


def execute(root, command, *, timeout=600, heavy=False, env=None, grace=1):
    evidence = Evidence(root, 'dev-' + time.strftime('%Y%m%d-%H%M%S'), Redactor())
    try:
        if heavy:
            with host_lock(root), dd_lock(root):
                result = run_process(command, cwd=root, evidence=evidence, timeout=timeout, env=env, grace=grace)
        else:
            result = run_process(command, cwd=root, evidence=evidence, timeout=timeout, env=env, grace=grace)
        print(json.dumps({'exit': result.returncode, 'reason': result.reason,
                          'seconds': result.seconds, 'log': str(result.log)}))
        return result
    finally:
        evidence.close()


def bootstrap(root, *, tools=None, timeout=600):
    result = bootstrap_tools(root, tools=tools, timeout=timeout)
    if tools is None:
        from .runtimes import install
        code = install(root, timeout=timeout)
        if code:
            raise BootstrapError('Locked runtime bootstrap failed with exit ' + str(code))
    return result


def tool(root, name):
    planned = bootstrap_tools(root, tools=[name], plan=True)['tools'][0]
    if planned.get('executable'):
        return planned['executable']
    if name == 'swift-format':
        # Read-only selection; bootstrap separately authenticates the exact host build and binary.
        from .core import toolchain
        developer = toolchain()['developer_dir']
        if developer:
            path = Path(developer) / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-format'
            if path.is_file():
                return str(path)
    raise BootstrapError('Missing verified ' + name + '; run ./dev bootstrap')


def generate(root, timeout=600, *, _locked=False):
    if not _locked:
        with host_lock(root), dd_lock(root):
            return generate(root, timeout, _locked=True)
    result = execute(root, [tool(root, 'xcodegen'), 'generate', '--spec', 'ios/project.yml'], timeout=timeout)
    if result.returncode:
        return result.returncode
    lock = root / 'ios/Dependencies/Package.resolved'
    if lock.is_file():
        destination = root / 'ios/Today.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(lock, destination)
    return 0


def build(root, configuration='Debug', *, scheme='Today', timeout=600, testing=False, device=None,
          install=False, provisioning_updates=False, main_run=None):
    if (device and (scheme != 'Today' or testing or configuration != 'Debug')) or (
            (install or provisioning_updates) and not device) or (main_run and not install):
        raise ValueError('Device install requires Debug Live Today and a device; a CI run ID only with --install')
    if timeout <= 0:
        raise ValueError('Positive build timeout required')
    sdk = 'iphoneos' if device else 'iphonesimulator'
    destination = 'platform=iOS,id=' + device if device else 'generic/platform=iOS Simulator'
    operation = 'build-for-testing' if testing else 'build'
    command = ['xcodebuild', operation, '-project', 'ios/Today.xcodeproj', '-scheme', scheme,
               '-configuration', configuration, '-destination', destination,
               '-derivedDataPath', str(derived_data(root)), '-jobs', '2', 'ARCHS=arm64',
               '-showBuildTimingSummary']
    if provisioning_updates:
        command.append('-allowProvisioningUpdates')
    with host_lock(root), dd_lock(root):
        if device:
            from scripts.release.release import check_git
            source = probe(['git', 'rev-parse', 'HEAD'], root)
            check_git(root, source)
            tree = probe(['git', 'rev-parse', 'HEAD^{tree}'], root)
        code = generate(root, timeout, _locked=True)
        if code:
            return code
        from .resolve import locked_arguments
        if testing:
            from .core import NativeBuildError, ensure_test_products
            try:
                path = ensure_test_products(
                    root, scheme, lambda argv: execute(root, argv, timeout=timeout),
                    configuration=configuration, flags=locked_arguments(root))
            except NativeBuildError as error:
                return error.returncode
            print(json.dumps({'test_products': str(path), 'tests_executed': 0}))
            return 0
        current = fingerprint(root, configuration=configuration, scheme=scheme, architecture='arm64', sdk=sdk)
        command += locked_arguments(root)
        maps = None
        if configuration == 'Release' and scheme == 'Today':
            maps = derived_data(root) / 'ReleaseMaps' / uuid.uuid4().hex
            maps.mkdir(parents=True)
            command += ['LD_GENERATE_MAP_FILE=YES', 'LD_MAP_FILE_PATH=' + str(maps / '$(TARGET_NAME)-$(PRODUCT_NAME).map')]
        result = execute(root, command, timeout=timeout)
        if result.returncode:
            return result.returncode
        product = {'Today': 'One', 'TodayMock': 'TodayMock', 'TodayWorkbench': 'TodayWorkbench'}[scheme]
        executable = derived_data(root) / f'Build/Products/{configuration}-{sdk}/{product}.app'
        if not executable.is_dir() or fingerprint(root, configuration=configuration, scheme=scheme, architecture='arm64', sdk=sdk) != current:
            raise ValueError('Missing executable or source changed during build; provenance rejected')
        products = [executable]
        if maps is not None:
            from scripts.release import release
            release.validate_resources(root, executable)
            release.bind_product_link_maps(root, executable, maps, result.log)
            release.validate_product_link_maps(root, executable, maps, target_names=True)
            products += sorted(path for path in maps.iterdir() if path.is_file())
            print(json.dumps({'release_maps': str(maps), 'exclusion': 'actual_simulator_products', 'signing': 'not_checked'}))
        record_build(root, current, products, returncode=result.returncode)
        if device:
            from scripts.ci.main_gate import check_install, product_identity, tool_identity
            from scripts.release.release import check_git, run
            from types import SimpleNamespace
            check_git(root, source)
            receipt = state_root(root) / 'device-builds' / (uuid.uuid4().hex + '.json')
            atomic_json(receipt, {'source': source, 'tree': tree, 'source_after': probe(['git', 'rev-parse', 'HEAD'], root),
                                  'dirty_after': probe(['git', 'status', '--porcelain', '--untracked-files=all'], root),
                                  'exit': result.returncode, 'toolchain': tool_identity(), 'signing_changes': False,
                                  'automatic_provisioning_updates': provisioning_updates, 'device': device,
                                  'app': str(executable.absolute()), 'product_identity': product_identity(executable),
                                  'build_log': str(result.log)})
            print(json.dumps({'device_build_receipt': str(receipt)}))
            if install:
                args = SimpleNamespace(commit=source, main_run=main_run,
                                       build_receipt=receipt, allow_provisioning_updates=provisioning_updates)
                check_install(root, args, run)
                return execute(root, ['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device,
                                      str(executable)], timeout=timeout).returncode
    return 0


def testing_contract(root):
    import importlib.util
    path = Path(root) / 'scripts/testing/contract.py'
    spec = importlib.util.spec_from_file_location('devtools_testing_contract', path)
    contract = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(contract)
    return contract


def test(root, group, *, only=(), timeout=600, full=False, _locked=False):
    from . import xcode_tests
    if full and (group != 'release' or only):
        raise ValueError('--full requires release without --only')
    if group == 'release':
        if not full:
            raise ValueError('release collection requires explicit --full')
        # One host-heavy owner for the whole frozen final collection. Never retry.
        with host_lock(root), dd_lock(root):
            generated = generate(root, timeout, _locked=True)
            if generated:
                return generated
            first = test(root, 'unit', timeout=timeout, _locked=True)
            code = xcode_tests.run(root, testing_contract(root), ['ios-unit', 'integration', 'snapshot'],
                                   timeout=timeout, locked=True, reuse=True)
            return first or code
    if group == 'qa':
        if only:
            raise ValueError('qa runs the bounded host QA helper collection')
        return execute(root, [sys.executable, '-m', 'unittest', 'discover',
                              '-s', 'tests/qa', '-p', 'test_*.py', '-v'], timeout=timeout, heavy=False).returncode
    if group == 'helpers':
        if only:
            raise ValueError('helpers runs the complete bounded CI policy collection')
        return execute(root, [sys.executable, '-m', 'unittest', 'discover',
                              '-s', 'tests/ci', '-p', 'test_*.py', '-v'], timeout=timeout).returncode
    contract = testing_contract(root)
    if group in ('ios-unit', 'integration', 'snapshot'):
        if not _locked:
            with host_lock(root), dd_lock(root):
                return test(root, group, only=only, timeout=timeout, _locked=True)
        generated = generate(root, timeout, _locked=True)
        if generated:
            return generated
        return xcode_tests.run(root, contract, [group], only=only, timeout=timeout, locked=True, reuse=True)
    if group == 'unit':
        source = contract.inventory(root)
        plan = contract.plan(['unit'], source)
        expected = plan['selectors']['logic']
        command = ['swift', 'test', '--package-path', 'ios', '--jobs', '2']
        if only:
            expected = contract.expand(only, source, 'logic')
            command += ['--filter', '|'.join('/'.join(x.split('/')[1:]) for x in expected)]
        result = execute(root, command, timeout=timeout, heavy=not _locked)
        raw = result.log.read_text()
        report = contract.report(expected, contract.log_attempts(raw, 'logic', source=source), result.returncode,
                                 raw_log=raw, allowed_skips=['benchmark', 'export'],
                                 skip_rules=contract.load_manifest()['skip_rules'])
        path = result.log.with_suffix('.report.json')
        atomic_json(path, report)
        evidence = Evidence(root, 'dev-unit-report-' + path.stem, Redactor())
        try:
            evidence.journal.artifact(evidence.session, path)
        finally:
            evidence.close()
        print(json.dumps({'report': str(path), 'status': report['status'],
                          'executed': report['executed_count'], 'missing': len(report['missing'])}))
        return result.returncode or (0 if report['status'] == 'passed' else 1)
    raise ValueError('Unknown test group: ' + group)


def format_sources(root, *, check=False, timeout=600):
    from .core import repository_files
    paths = sorted({name for name in repository_files(root)
        if name.startswith('ios/') and name.endswith('.swift') and (root / name).is_file()})
    command = [tool(root, 'swift-format'), 'lint' if check else 'format', '--recursive']
    command += ['--strict'] if check else ['--in-place']
    return execute(root, [*command, *paths], timeout=timeout).returncode


def lint(root, timeout=600):
    commands = [[tool(root, 'swiftlint'), 'lint', '--strict', '--config', '.swiftlint.yml'],
                [tool(root, 'ruff'), 'check', '--config', 'ruff.toml', 'scripts/devtools',
                 'scripts/ci', 'scripts/testing', 'scripts/release', 'tests/devtools', 'tests/ci', 'tests/testing', 'tests/release',
                 'tests/qa/retention.py', 'tests/qa/test_retention.py']]
    if (root / '.github/workflows').is_dir():
        commands.append([tool(root, 'actionlint'), '-shellcheck=', '-pyflakes='])
    for command in commands:
        result = execute(root, command, timeout=timeout)
        if result.returncode:
            return result.returncode
    return 0


def release(root, action, options=(), timeout=600):
    if action in ('preflight', 'validate', 'preflight-local', 'validate-local'):
        return execute(root, [sys.executable, 'scripts/release/release.py', action, *options], timeout=timeout).returncode
    if action not in ('archive', 'archive-local'):
        raise ValueError('Distribution requires separate explicit authorization and is not a default dev action')
    from .runtimes import command, environment
    return execute(root, command(root, ['bundle', '_4.0.16_', 'exec', 'fastlane', 'ios', 'archive_local' if action == 'archive-local' else 'archive', *options]), env=environment(root), timeout=timeout, heavy=True).returncode
