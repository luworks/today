"""Behavioral bootstrap coverage; synthetic archives never execute fake binaries."""
import hashlib
import io
import json
from pathlib import Path
import plistlib
import struct
import sys
import tarfile
import tempfile
import threading
import types
import unittest
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.devtools import bootstrap as subject  # noqa: E402 - standalone test import bootstrap

ARM = b'\xcf\xfa\xed\xfe' + struct.pack('<I', 0x0100000c) + b'fixture'
X86 = b'\xcf\xfa\xed\xfe' + struct.pack('<I', 0x01000007) + b'fixture'


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bootstrap paths with spaces ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'docs/engineering').mkdir(parents=True)
        self.archive = self.root / 'asset.tar.gz'
        self.make_tar([('release/actionlint', ARM, 'file')])
        self.manifest = {'schema_version': 1, 'tools': {'actionlint': {
            'version': '1.7.12', 'artifact': {
                'url': 'https://github.com/example/releases/download/v1/asset.tar.gz',
                'sha256': subject.sha256(self.archive)}}}}
        self.write_pins()
        self.calls = []
        self.addCleanup(patch.stopall)
        patch.object(subject.platform, 'system', return_value='Darwin').start()
        patch.object(subject.platform, 'machine', return_value='arm64').start()
        patch.object(subject, 'Evidence', side_effect=lambda *a: types.SimpleNamespace(close=lambda: None)).start()
        patch.object(subject, 'run_process', side_effect=self.download).start()

    def write_pins(self):
        (self.root / 'docs/engineering/tool-pins.json').write_text(json.dumps(self.manifest))

    def make_tar(self, members):
        with tarfile.open(self.archive, 'w:gz') as archive:
            for name, data, kind in members:
                item = tarfile.TarInfo(name)
                item.mode = 0o755
                if kind in ('symlink', 'hardlink'):
                    item.type = tarfile.SYMTYPE if kind == 'symlink' else tarfile.LNKTYPE
                    item.linkname = '../outside'
                    archive.addfile(item)
                else:
                    item.size = len(data)
                    archive.addfile(item, io.BytesIO(data))

    def repin(self):
        self.manifest['tools']['actionlint']['artifact']['sha256'] = subject.sha256(self.archive)
        self.write_pins()

    def download(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        self.assertIsInstance(argv, list)
        if argv[0] == '/usr/bin/curl':
            Path(argv[argv.index('--output') + 1]).write_bytes(self.archive.read_bytes())
        log = self.root / f'process-{len(self.calls)}.log'
        log.write_text('main\n')
        return types.SimpleNamespace(returncode=0, reason='exited', log=log)

    def install(self, **kwargs):
        return subject.bootstrap(self.root, tools=['actionlint'], **kwargs)

    def assert_unpublished(self):
        self.assertFalse((self.root / '.dev-tools/actionlint/1.7.12').exists())
        self.assertFalse(list((self.root / '.dev-tools').glob('.bootstrap-*')))

    def test_plan_readonly_missing_tools_and_spaces(self):
        before = set(self.root.rglob('*'))
        result = self.install(plan=True)
        self.assertEqual(result['tools'][0]['status'], 'missing')
        self.assertEqual(before, set(self.root.rglob('*')))
        self.assertEqual(self.calls, [])
        with self.assertRaises(subject.BootstrapError):
            subject.bootstrap(self.root, tools=['ruff'], plan=True)
        with self.assertRaises(subject.BootstrapError):
            subject.bootstrap(self.root, tools=['fastlane'], plan=True)

    def test_idempotent_exact_files_and_tampering(self):
        result = self.install()
        executable = Path(result['tools'][0]['executable'])
        self.assertEqual(executable.read_bytes(), ARM)
        self.assertEqual(self.install()['tools'][0]['status'], 'ready')
        self.assertEqual(len(self.calls), 1)
        executable.write_bytes(ARM + b'tampered')
        self.assertEqual(self.install(plan=True)['tools'][0]['status'], 'conflict')
        with self.assertRaisesRegex(subject.BootstrapError, 'conflict'):
            self.install()
        self.assertEqual(len(self.calls), 1)

    def test_checksum_before_extraction(self):
        self.archive.write_bytes(b'not even an archive')
        with patch.object(subject, '_extract') as extract:
            with self.assertRaisesRegex(subject.BootstrapError, 'Checksum'):
                self.install()
            extract.assert_not_called()
        self.assert_unpublished()

    def test_tar_traversal_links_and_absolute_paths(self):
        for name, kind in [('../outside', 'file'), ('/absolute', 'file'),
                           ('release/link', 'symlink'), ('release/link', 'hardlink')]:
            with self.subTest(name=name, kind=kind):
                self.make_tar([('release/actionlint', ARM, 'file'), (name, b'bad', kind)])
                self.repin()
                with self.assertRaises(subject.BootstrapError):
                    self.install()
                self.assert_unpublished()
        self.assertFalse((self.root / 'outside').exists())

    def test_zip_traversal_symlink_and_valid_payload(self):
        for unsafe in ('../outside', '/outside', 'a\\outside', 'link'):
            with zipfile.ZipFile(self.archive, 'w') as archive:
                archive.writestr('bin/actionlint', ARM)
                item = zipfile.ZipInfo(unsafe)
                if unsafe == 'link':
                    item.create_system = 3
                    item.external_attr = (0o120777 << 16)
                archive.writestr(item, '../outside')
            self.repin()
            with self.assertRaises(subject.BootstrapError):
                self.install()
            self.assert_unpublished()
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('release/actionlint', ARM)
        self.repin()
        self.assertEqual(self.install()['tools'][0]['status'], 'installed')

    def test_wrong_arch_and_missing_executable(self):
        for name, data in [('actionlint', X86), ('another-tool', ARM)]:
            self.make_tar([(name, data, 'file')])
            self.repin()
            with self.assertRaisesRegex(subject.BootstrapError, 'arm64 executable'):
                self.install()
            self.assert_unpublished()
        with patch.object(subject.platform, 'machine', return_value='x86_64'):
            with self.assertRaisesRegex(subject.BootstrapError, 'macOS arm64'):
                self.install()

    def test_existing_symlink_outside_root_refused(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.root / '.dev-tools').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(subject.BootstrapError):
            self.install()
        self.assertEqual(list(outside.iterdir()), [])

    def test_nested_symlink_and_lock_symlink_refused(self):
        base = self.root / '.dev-tools'
        base.mkdir()
        outside = self.root / 'outside'
        outside.mkdir()
        for path in [base / 'actionlint', base / 'bootstrap.lock']:
            path.symlink_to(outside)
            with self.assertRaises(subject.BootstrapError):
                self.install()
            path.unlink()
        self.assertEqual(list(outside.iterdir()), [])

    def test_cancel_timeout_and_failed_download_never_publish(self):
        cancel = threading.Event()
        cancel.set()
        with self.assertRaisesRegex(subject.BootstrapError, 'cancelled'):
            self.install(cancel=cancel)
        with patch.object(subject, 'run_process', return_value=types.SimpleNamespace(
                returncode=124, reason='timeout', log=self.root / 'log')):
            with self.assertRaisesRegex(subject.BootstrapError, 'timeout'):
                self.install()
        with patch.object(subject, 'run_process', side_effect=OSError('missing curl')):
            with self.assertRaises(OSError):
                self.install()
        self.assert_unpublished()

    def test_atomic_publish_failure_leaves_no_installation(self):
        original = Path.rename
        def fail_publish(path, destination):
            if path.name == 'install':
                raise OSError('injected publish failure')
            return original(path, destination)
        with patch.object(Path, 'rename', fail_publish):
            with self.assertRaisesRegex(OSError, 'publish failure'):
                self.install()
        self.assert_unpublished()

    def test_formatter_uses_exact_xcode_and_observed_main(self):
        developer = self.root / 'Xcode with spaces.app/Contents/Developer'
        executable = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-format'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(ARM)
        executable.chmod(0o755)
        version = developer.parent / 'version.plist'
        version.write_bytes(plistlib.dumps({'ProductBuildVersion': '27B52'}))
        self.manifest['tools']['swift-format'] = {'version': '604.0.0', 'preferred_pin': {
            'kind': 'xcode-bundled', 'xcode_build': '27B52'}}
        self.write_pins()
        with patch.object(subject, 'toolchain', return_value={'developer_dir': str(developer)}):
            result = subject.bootstrap(self.root, tools=['swift-format'])['tools'][0]
            self.assertEqual(result['version_output'], 'main')
            self.assertEqual(result['sha256'], hashlib.sha256(ARM).hexdigest())
            self.assertEqual(result['executable'], str(executable))
            version.write_bytes(plistlib.dumps({'ProductBuildVersion': 'wrong'}))
            with self.assertRaisesRegex(subject.BootstrapError, '27B52'):
                subject.bootstrap(self.root, tools=['swift-format'])


if __name__ == '__main__':
    unittest.main()
