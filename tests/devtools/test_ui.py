"""Mock platform boundaries only: no Swift, Xcode, or simulator processes."""
from contextlib import contextmanager
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.devtools import ui  # noqa: E402
from scripts.devtools.core import ResourceBusy, ResourceLock  # noqa: E402
from scripts.gallery.adapter import Manifest  # noqa: E402

UDID = '11111111-1111-1111-1111-111111111111'


@contextmanager
def no_locks(root):
    yield


class UITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='native path with spaces ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'ios').mkdir()
        (self.root / 'ios/real.swift').write_text('real source')
        self.inputs = {'sources': ['ios/real.swift'], 'locks': []}
        self.manifest = Manifest.parse({'schema': 1, 'locks': [], 'scenes': [
            {'id': 'clock.world', 'scenarios': ['normal'], 'sources': self.inputs['sources']}]}, self.root)
        self.calls = []
        self.container = self.root / 'app data'
        self.container.mkdir()
        self.app = ui.derived_data(self.root) / 'Build/Products/Debug-iphonesimulator/TodayWorkbench.app'
        self.app.mkdir(parents=True)
        self.receipt_status = 'ready'
        self.mismatch = False
        self.mutate = False
        self.cancel_on_launch = None
        # Versioned inline synthetic PNG, only a mock simctl output.
        from tests.gallery.test_gallery import png
        self.png = png()

    def fake_run(self, native, argv):
        native.check()
        self.calls.append(list(map(str, argv)))
        if argv[1:5] == ['simctl', 'list', 'devices', '--json']:
            return json.dumps({'devices': {ui.RUNTIME: [self.device()]}})
        if argv[1:3] == ['simctl', 'launch']:
            if self.cancel_on_launch is not None:
                self.cancel_on_launch.set()
            receipt = argv[argv.index('-sceneReceipt') + 1]
            directory = self.container / 'Library/Caches/TodayWorkbench'
            directory.mkdir(parents=True, exist_ok=True)
            (directory / (receipt + '.json')).write_text(json.dumps({
                'scene': 'wrong' if self.mismatch else 'clock.world', 'scenario': 'normal', 'status': self.receipt_status}))
        if argv[1:3] == ['simctl', 'get_app_container']:
            return str(self.container)
        if argv[1:3] == ['simctl', 'io']:
            Path(argv[-1]).write_bytes(self.png)
            if self.mutate:
                (self.root / 'ios/real.swift').write_text('changed source')
        return ''

    def device(self, state='Shutdown'):
        return {'name': ui.simulator_name(self.root), 'udid': UDID, 'state': state,
                'deviceTypeIdentifier': ui.DEVICE, 'isAvailable': True}

    def perform(self, output=None, **kwargs):
        before = ui._snapshot(self.root, self.inputs)
        with patch('scripts.devtools.commands.generate', return_value=0), \
                patch.object(ui, 'fingerprint', return_value={'sha256': 'synthetic-source'}), \
                patch.object(ui, 'record_build'), \
                patch('scripts.devtools.resolve.locked_arguments', return_value=['-disableAutomaticPackageResolution']), patch.object(ui, '_locks', no_locks), patch.object(ui, '_export', return_value=(
                self.manifest, self.inputs, before)), patch.object(ui, '_inputs', return_value=self.inputs), \
                patch.object(ui.Native, 'run', self.fake_run_bound()), patch.object(ui, 'Evidence'):
            if output is None:
                return ui.open_scene(self.root, 'clock.world', 'normal', **kwargs)
            return ui.capture(self.root, 'clock.world', 'normal', output, **kwargs)

    def fake_run_bound(self):
        return lambda native, argv: self.fake_run(native, argv)

    def test_prepare_installs_mock_without_launching_or_capturing(self):
        runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-27-2'
        with patch('scripts.devtools.commands.build', return_value=0) as build, \
                patch.object(ui, '_locks', no_locks), \
                patch.object(ui, '_device', return_value=(UDID, False, self.root / 'lease.json')) as device, \
                patch.object(ui.Native, 'run', self.fake_run_bound()):
            result = ui.prepare(self.root, runtime)
        build.assert_called_once_with(self.root, scheme='TodayMock')
        device.assert_called_once()
        self.assertEqual(device.call_args.kwargs['runtime'], runtime)
        self.assertEqual(result['deviceId'], UDID)
        verbs = [call[2] for call in self.calls]
        self.assertEqual(verbs, ['boot', 'bootstatus', 'install'])
        self.assertTrue(json.loads((self.root / 'lease.json').read_text())['warm'])

    def test_prepare_rejects_runtime_before_build(self):
        with patch('scripts.devtools.commands.build') as build, self.assertRaises(ValueError):
            ui.prepare(self.root, 'invalid')
        build.assert_not_called()

    def test_real_capture_argv_new_output_identity_and_shutdown(self):
        output = self.root / 'capture with spaces.png'
        identity = self.perform(output, appearance='dark', type_size='accessibility3', locale='zh_CN')
        self.assertEqual(output.read_bytes(), self.png)
        self.assertEqual(json.loads(output.with_suffix('.json').read_text()), {'device': identity.device, 'os': identity.os})
        build = self.calls[0]
        self.assertEqual(build[:2], ['xcodebuild', 'build'])
        self.assertIn('TodayWorkbench', build)
        self.assertIn('ARCHS=arm64', build)
        launch = next(c for c in self.calls if 'launch' in c)
        self.assertIn(ui.APP_ID, launch)
        self.assertEqual(launch[launch.index('-sceneTypeSize') + 1], 'accessibility3')
        self.assertEqual(self.calls[-1], ['xcrun', 'simctl', 'shutdown', UDID])
        count = len(self.calls)
        with self.assertRaises(ValueError):
            self.perform(output)
        self.assertEqual(len(self.calls), count)

    def test_failure_and_mismatch_never_screenshot(self):
        for status, mismatch in [('failed', False), ('ready', True)]:
            with self.subTest(status=status, mismatch=mismatch):
                self.receipt_status, self.mismatch = status, mismatch
                self.calls.clear()
                output = self.root / 'failed.png'
                with self.assertRaises(ValueError):
                    self.perform(output)
                self.assertFalse(output.exists())
                self.assertFalse(output.with_suffix('.json').exists())
                self.assertFalse(any('screenshot' in c for c in self.calls))
                self.assertEqual(self.calls[-1][-2:], ['shutdown', UDID])

    def test_mid_capture_edit_rejects_success_receipt(self):
        self.mutate = True
        output = self.root / 'stale.png'
        with self.assertRaisesRegex(ValueError, 'changed'):
            self.perform(output)
        self.assertFalse(output.with_suffix('.json').exists())

    def test_open_leases_warm_device_but_rejects_unowned_booted(self):
        self.perform()
        lease_path = ui.state_root(self.root) / 'ui' / ui.worktree_id(self.root) / 'device.json'
        self.assertTrue(json.loads(lease_path.read_text())['warm'])
        self.assertFalse(any('shutdown' in c for c in self.calls))
        native = Mock(root=self.root)
        native.run.return_value = json.dumps({'devices': {ui.RUNTIME: [self.device('Booted')]}})
        self.assertEqual(ui._device(native)[0], UDID)
        lease_path.unlink()
        with self.assertRaisesRegex(ValueError, 'lease'):
            ui._device(native)

    def test_name_ambiguity_wrong_runtime_and_quarantine_fail_before_boot(self):
        native = Mock(root=self.root)
        for values in [
                {ui.RUNTIME: [self.device(), self.device()]},
                {'old-runtime': [self.device()]},
                {ui.RUNTIME: [{**self.device(), 'udid': '3243BEDB-1111-1111-1111-111111111111'}]}]:
            native.run.reset_mock()
            native.run.return_value = json.dumps({'devices': values})
            with self.assertRaises(ValueError):
                ui._device(native)
            self.assertEqual(native.run.call_count, 1)

    def test_receipt_timeout_cancel_symlink_and_mismatched_path(self):
        cancel = threading.Event()
        native = ui.Native(self.root, 0.01, cancel)
        receipt = str(uuid.uuid4()).upper()
        with self.assertRaises(TimeoutError):
            ui._wait_receipt(native, self.container, receipt, 'clock.world', 'normal')
        cancel.set()
        with self.assertRaisesRegex(RuntimeError, 'cancelled'):
            ui._wait_receipt(native, self.container, receipt, 'clock.world', 'normal')
        native = ui.Native(self.root, 1, threading.Event())
        directory = self.container / 'Library/Caches/TodayWorkbench'
        directory.mkdir(parents=True)
        (directory / (receipt + '.json')).symlink_to(self.root / 'foreign.json')
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            ui._wait_receipt(native, self.container, receipt, 'clock.world', 'normal')

    def test_cancel_after_launch_shuts_down_only_owned_device(self):
        cancel = threading.Event()
        self.cancel_on_launch = cancel
        output = self.root / 'cancelled.png'
        with self.assertRaisesRegex(RuntimeError, 'cancelled'):
            self.perform(output, cancel=cancel)
        self.assertEqual(self.calls[-1], ['xcrun', 'simctl', 'shutdown', UDID])
        self.assertFalse(any('screenshot' in c for c in self.calls))
        self.assertFalse(output.with_suffix('.json').exists())

    def test_old_receipt_is_ignored_and_source_mtime_invalidates(self):
        directory = self.container / 'Library/Caches/TodayWorkbench'
        directory.mkdir(parents=True)
        (directory / (str(uuid.uuid4()).upper() + '.json')).write_text(json.dumps({
            'scene': 'clock.world', 'scenario': 'normal', 'status': 'ready'}))
        with self.assertRaises(TimeoutError):
            ui._wait_receipt(ui.Native(self.root, 0.01, None), self.container,
                             str(uuid.uuid4()).upper(), 'clock.world', 'normal')
        import os
        before = ui._snapshot(self.root, self.inputs)
        path = self.root / self.inputs['sources'][0]
        stat = path.stat()
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000))
        self.assertNotEqual(ui._snapshot(self.root, self.inputs), before)

    def test_allowlist_options_and_unknown_scene(self):
        for scene, scenario, appearance, size, locale in [
                ('../escape', 'normal', 'light', 'large', 'en_US'),
                ('clock.world', 'normal', 'bad', 'large', 'en_US'),
                ('clock.world', 'normal', 'light', 'bad', 'en_US'),
                ('clock.world', 'normal', 'light', 'large', '-injected')]:
            with self.assertRaises(ValueError):
                ui._options(scene, scenario, appearance, size, locale)
        with self.assertRaises(ValueError):
            self.manifest.scene('unregistered', 'normal')

    def test_registry_export_builds_only_product_then_runs_executable(self):
        calls = []
        native = Mock(root=self.root)
        data = {'schema': 1, 'locks': [], 'scenes': [
            {'id': 'clock.world', 'scenarios': ['normal'], 'sources': self.inputs['sources']}]}
        def run(argv):
            calls.append(argv)
            return json.dumps(data) if '--sources-json' in argv else ''
        native.run.side_effect = run
        with patch.object(ui, '_inputs', return_value=self.inputs):
            self.assertEqual(ui._export(native)[0], self.manifest)
        self.assertEqual(calls[0], ['swift', 'build', '--package-path', 'ios', '--product', 'today-scenes', '--jobs', '2'])
        self.assertEqual(calls[1][0], str(self.root / 'ios/.build/debug/today-scenes'))
        self.assertEqual(json.loads(Path(calls[1][2]).read_text()), self.inputs)
        data['scenes'][0]['sources'] = ['../../escape']
        with patch.object(ui, '_inputs', return_value=self.inputs), self.assertRaises(ValueError):
            ui._export(native)

    def test_gallery_uses_registry_and_existing_server_and_closes(self):
        instance, server = Mock(), Mock(url='http://127.0.0.1:12345/#test')
        server.serve_forever.side_effect = KeyboardInterrupt
        with patch.object(ui, 'export_manifest', return_value=self.manifest) as export, \
                patch('scripts.gallery.adapter.Gallery', return_value=instance) as factory, \
                patch('scripts.gallery.server.GalleryServer', return_value=server) as serve, patch('builtins.print'):
            self.assertEqual(ui.gallery(self.root, watch=False, port=0), 0)
        export.assert_called_once_with(self.root)
        factory.assert_called_once_with(self.root, self.manifest)
        serve.assert_called_once_with(instance, port=0, watch=False)
        server.server_close.assert_called_once()
        instance.close.assert_called_once()

    def test_host_lock_blocks_before_any_tool_and_cancel_forwarding(self):
        path = self.root / 'held.lock'
        with ResourceLock(path, 'other'), patch.object(ui, 'host_lock', return_value=ResourceLock(path, 'ui')):
            with patch.object(ui.Native, 'run') as run, self.assertRaises(ResourceBusy):
                ui.export_manifest(self.root)
            run.assert_not_called()
        cancel = threading.Event()
        evidence = Mock(path=self.root / 'log')
        result = Mock(returncode=130, reason='cancelled', log=evidence.path)
        with patch.object(ui, 'Evidence', return_value=evidence), patch.object(ui, 'run_process', return_value=result) as run:
            with self.assertRaisesRegex(RuntimeError, 'cancelled'):
                ui.Native(self.root, 5, cancel).run(['fixed', 'argv'])
        self.assertIs(run.call_args.kwargs['cancel'], cancel)
        self.assertTrue(cancel.is_set())
        evidence.close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
