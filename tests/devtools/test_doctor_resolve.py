"""Host-only behavioral checks. No Xcode, Swift, simulator or runtime installation."""
from contextlib import nullcontext
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from scripts.devtools import commands, doctor, resolve
from scripts.devtools.core import ResourceBusy

ROOT = Path(__file__).resolve().parents[2]


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='doctor resolve paths with spaces ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        for name in ['docs/engineering/tool-pins.json', 'scripts/release/tool-lock.json',
                     'ios/project.yml', resolve.AUTHORITY, '.mise.toml', 'mise.lock', 'Gemfile', 'Gemfile.lock']:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        self.workspace = self.root / resolve.WORKSPACE
        self.workspace.parent.mkdir(parents=True)
        self.workspace.write_bytes((self.root / resolve.AUTHORITY).read_bytes())
        (self.root / 'ios/Today.xcodeproj/project.pbxproj').write_text('generated')

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}


class ResolveTests(Fixture):
    def run_mock(self, callback=None, code=0, scheme='Today'):
        def execute(root, argv, **options):
            self.assertEqual(root, self.root)
            self.assertEqual(argv[:2], ['xcodebuild', '-resolvePackageDependencies'])
            self.assertEqual(argv[argv.index('-scheme') + 1], scheme)
            self.assertIn(str(resolve.derived_data(self.root)), argv)
            self.assertTrue(set(resolve.FLAGS).issubset(argv))
            self.assertEqual(self.workspace.read_bytes(), (self.root / resolve.AUTHORITY).read_bytes())
            if callback:
                callback()
            return SimpleNamespace(returncode=code)
        with patch.object(resolve, 'host_lock', return_value=nullcontext()) as host, \
                patch.object(resolve, 'dd_lock', return_value=nullcontext()) as dd, \
                patch.object(commands, 'execute', side_effect=execute) as process:
            result = resolve.run(self.root, scheme)
            host.assert_called_once_with(self.root)
            dd.assert_called_once_with(self.root)
            process.assert_called_once()
            return result

    def test_readonly_build_gate_and_flags(self):
        before = self.snapshot()
        self.assertEqual(resolve.locked_arguments(self.root), list(resolve.FLAGS))
        self.assertEqual(before, self.snapshot())

    def test_default_resolution_never_rewrites_authority(self):
        original = (self.root / resolve.AUTHORITY).read_bytes()
        def reformat():
            self.workspace.write_text(json.dumps(json.loads(original), separators=(',', ':')))
        self.assertEqual(self.run_mock(reformat), 0)
        self.assertEqual((self.root / resolve.AUTHORITY).read_bytes(), original)
        self.assertEqual(self.workspace.read_bytes(), original)

    def test_dirty_ignored_workspace_is_restored_before_resolution(self):
        self.workspace.write_text('dirty ignored state')
        self.assertEqual(self.run_mock(), 0)

    def test_drifted_identity_revision_version_and_missing_pin_fail_closed(self):
        for field in ('identity', 'revision', 'version', 'missing'):
            with self.subTest(field=field):
                def drift():
                    data = json.loads(self.workspace.read_text())
                    if field == 'identity':
                        data['pins'][0]['identity'] = 'injected-package'
                    elif field == 'missing':
                        data['pins'].pop()
                    else:
                        data['pins'][0]['state'][field] = 'f' * 40 if field == 'revision' else '99.0.0'
                    self.workspace.write_text(json.dumps(data))
                with self.assertRaisesRegex(ValueError, 'drifted'):
                    self.run_mock(drift)
                self.assertEqual(resolve.locked_arguments(self.root), list(resolve.FLAGS))

    def test_command_failure_is_preserved_and_workspace_recovered(self):
        self.assertEqual(self.run_mock(lambda: self.workspace.write_text('broken'), code=74), 74)
        resolve.locked_arguments(self.root)

    def test_process_exception_recovers_workspace(self):
        def interrupted():
            self.workspace.write_text('broken')
            raise subprocess.TimeoutExpired('mock', 10)
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_mock(interrupted)
        resolve.locked_arguments(self.root)

    def test_missing_authority_fails_without_process_or_generation(self):
        (self.root / resolve.AUTHORITY).unlink()
        before = self.snapshot()
        with patch.object(commands, 'execute') as process, patch.object(commands, 'generate') as generate:
            with self.assertRaisesRegex(ValueError, 'Missing versioned'):
                resolve.run(self.root)
            process.assert_not_called()
            generate.assert_not_called()
        self.assertEqual(before, self.snapshot())

    def test_unknown_scheme_fails_before_state_write(self):
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'Unsupported'):
            resolve.run(self.root, 'UntrustedScheme')
        self.assertEqual(before, self.snapshot())

    def test_supported_source_schemes(self):
        for scheme in resolve.SCHEMES:
            with self.subTest(scheme=scheme):
                self.assertEqual(self.run_mock(scheme=scheme), 0)

    def test_missing_project_uses_existing_generator(self):
        (self.root / 'ios/Today.xcodeproj/project.pbxproj').unlink()
        with patch.object(commands, 'generate', return_value=0) as generate:
            self.assertEqual(self.run_mock(), 0)
            generate.assert_called_once_with(self.root, timeout=600, _locked=True)

    def test_normal_build_gate_rejects_missing_or_dirty_workspace(self):
        for contents in (None, '{}'):
            if contents is None:
                self.workspace.unlink()
            else:
                self.workspace.write_text(contents)
            with self.assertRaises(ValueError):
                resolve.locked_arguments(self.root)

    def test_source_pin_drift_rejected_before_resolution(self):
        path = self.root / 'ios/project.yml'
        source = json.loads(path.read_text())
        source['packages']['SnapshotTesting']['exactVersion'] = '99.0.0'
        path.write_text(json.dumps(source))
        with self.assertRaisesRegex(ValueError, 'disagree'):
            resolve.run(self.root)

    def test_origin_hash_drift_blocks_normal_build(self):
        data = json.loads(self.workspace.read_text())
        data['originHash'] = 'wrong graph'
        self.workspace.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'drifted'):
            resolve.locked_arguments(self.root)

    def test_busy_host_never_generates_or_resolves(self):
        before = self.snapshot()
        with patch.object(resolve, 'host_lock', side_effect=ResourceBusy('owned')), \
                patch.object(commands, 'execute') as execute, patch.object(commands, 'generate') as generate:
            with self.assertRaises(ResourceBusy):
                resolve.run(self.root)
            execute.assert_not_called()
            generate.assert_not_called()
        self.assertEqual(before, self.snapshot())

    def test_duplicate_dependency_is_invalid(self):
        data = json.loads(self.workspace.read_text())
        data['pins'].append(data['pins'][0])
        self.workspace.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            resolve.locked_arguments(self.root)


class DoctorTests(Fixture):
    def setUp(self):
        super().setUp()
        self.developer = self.root / 'Xcode with spaces.app/Contents/Developer'
        self.chain = {'developer_dir': str(self.developer), 'xcode': {
            'CFBundleShortVersionString': '27.2', 'ProductBuildVersion': '27B52'}}
        for platform in ('iPhoneOS', 'iPhoneSimulator'):
            settings = self.developer / ('Platforms/' + platform + '.platform/Developer/SDKs/' + platform + '.sdk/SDKSettings.plist')
            settings.parent.mkdir(parents=True)
            settings.write_bytes(plistlib.dumps({'Version': '27.2', 'CanonicalName': platform.lower() + '27.2'}))
        bin_dir = self.developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin'
        for name in ('swiftc', 'swift-format'):
            self.executable(bin_dir / name)
        runtime = self.root / '.dev-tools/runtime/installs'
        self.executable(runtime / 'ruby/3.3.12/bin/ruby')
        self.executable(runtime / 'python/3.14.8/bin/python3')
        for path in [runtime / 'ruby/3.3.12/lib/ruby/gems/3.3.0/gems/bundler-4.0.16/exe/bundle',
                     self.root / '.dev-tools/bundle/ruby/3.3.0/gems/fastlane-2.241.2/bin/fastlane']:
            self.executable(path)

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('mock executable; must never run')
        path.chmod(0o755)

    def probe(self, argv, root, env=None):
        self.assertTrue(Path(argv[0]).is_absolute())
        self.assertNotIn('mise', [Path(a).name for a in argv])
        self.assertEqual(argv[-1], '--version')
        if len(argv) == 3:
            return 'Bundler version 4.0.16' if Path(argv[1]).name == 'bundle' else 'fastlane 2.241.2'
        return {'swiftc': 'Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9)',
                'swift-format': '6.4.4', 'ruby': 'ruby 3.3.12', 'python3': 'Python 3.14.8'}[Path(argv[0]).name]

    def inspect_mock(self):
        with patch.object(doctor, 'toolchain', return_value=self.chain), \
                patch.object(doctor, '_version', side_effect=self.probe):
            return doctor.inspect(self.root)

    def test_missing_tools_precisely_fail_and_doctor_is_readonly(self):
        before = self.snapshot()
        result = self.inspect_mock()
        self.assertFalse(result['ok'])
        for name in ('xcodegen', 'swiftlint', 'ruff', 'actionlint'):
            self.assertEqual(result['checks'][name + '_installation']['actual'], 'missing')
            self.assertTrue(result['checks'][name + '_installation']['required'])
        self.assertFalse(result['checks']['mise_installation']['required'])
        self.assertEqual(result['checks']['offline_readiness']['status'], 'unverified')
        self.assertEqual(result['checks']['swift-format_binary_hash']['status'], 'unverified')
        self.assertEqual(before, self.snapshot())

    def test_verified_tools_get_version_probes_but_mise_never_executes(self):
        manifest = json.loads((self.root / 'docs/engineering/tool-pins.json').read_text())
        def plan(root, tools, plan):
            name = tools[0]
            path = self.root / '.dev-tools' / name / manifest['tools'][name]['version'] / 'bin' / name
            return {'tools': [dict(status='ready', destination=str(path.parent), executable=str(path))]}
        for name in ('xcodegen', 'swiftlint', 'mise', 'ruff', 'actionlint'):
            self.executable(self.root / '.dev-tools' / name / manifest['tools'][name]['version'] / 'bin' / name)
        def probe(argv, root, env=None):
            name = Path(argv[0]).name
            return manifest['tools'][name]['version'] if name in manifest['tools'] and name != 'swift-format' else self.probe(argv, root, env)
        with patch.object(doctor, 'bootstrap', side_effect=plan), \
                patch.object(doctor, 'toolchain', return_value=self.chain), \
                patch.object(doctor, '_version', side_effect=probe) as calls:
            result = doctor.inspect(self.root)
        self.assertTrue(result['ok'], result)
        self.assertFalse(any(Path(call.args[0][0]).name == 'mise' for call in calls.call_args_list))

    def test_wrong_xcode_is_not_a_truthy_pass(self):
        self.chain['xcode']['ProductBuildVersion'] = 'WrongBuild'
        self.assertEqual(self.inspect_mock()['checks']['xcode']['status'], 'fail')

    def test_wrong_sdk_metadata_is_rejected(self):
        settings = next(self.developer.glob('Platforms/iPhoneSimulator.platform/Developer/SDKs/*/SDKSettings.plist'))
        settings.write_bytes(plistlib.dumps({'Version': '26.0', 'CanonicalName': 'iphonesimulator26.0'}))
        self.assertEqual(self.inspect_mock()['checks']['iPhoneSimulator_sdk']['status'], 'fail')

    def test_runtime_missing_and_lock_drift_are_independent_failures(self):
        (self.root / '.dev-tools/runtime/installs/ruby/3.3.12/bin/ruby').unlink()
        path = self.root / '.mise.toml'
        path.write_text(path.read_text().replace('3.3.12', '3.3.11'))
        checks = self.inspect_mock()['checks']
        self.assertEqual(checks['ruby_lock']['status'], 'fail')
        self.assertEqual(checks['ruby']['status'], 'fail')
        self.assertIn('Missing executable', checks['ruby']['detail'])

    def test_bad_binary_hash_is_optional_failure_not_pass(self):
        path = self.root / '.dev-tools/swift-format.json'
        path.write_text(json.dumps({'sha256': '0' * 64, 'xcode_build': '27B52'}))
        check = self.inspect_mock()['checks']['swift-format_binary_hash']
        self.assertEqual(check['status'], 'fail')
        self.assertFalse(check['required'])

    def test_probe_uses_clean_environment_and_no_shell(self):
        with patch.dict('os.environ', {'RUBYOPT': 'injected hook', 'PYTHONPATH': '/injected',
                                       'FASTLANE_PASSWORD': 'private-value'}), \
                patch.object(doctor.subprocess, 'check_output', return_value=b'ruby 3.3.12') as process:
            doctor._version([self.root / 'ruby with spaces', '--version'], self.root)
        argv = process.call_args.args[0]
        options = process.call_args.kwargs
        self.assertEqual(argv, [str(self.root / 'ruby with spaces'), '--version'])
        self.assertNotIn('shell', options)
        for key in ('RUBYOPT', 'PYTHONPATH', 'FASTLANE_PASSWORD'):
            self.assertNotIn(key, options['env'])
        self.assertEqual(options['env']['FASTLANE_SKIP_UPDATE_CHECK'], '1')

    def test_version_failure_does_not_echo_stderr_secrets(self):
        with patch.object(doctor, 'toolchain', return_value=self.chain), \
                patch.object(doctor, '_version', side_effect=subprocess.CalledProcessError(1, 'mock', stderr=b'secret')):
            result = doctor.inspect(self.root)
        self.assertEqual(result['checks']['swift']['status'], 'fail')
        self.assertNotIn('secret', json.dumps(result))


if __name__ == '__main__':
    unittest.main()
