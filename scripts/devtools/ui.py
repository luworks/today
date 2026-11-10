"""Native Workbench launch/capture, with registry allowlists and owned resources."""
from contextlib import ExitStack, contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import tempfile
import threading
import time
import uuid

from .core import (ResourceLock, atomic_json, dd_lock, derived_data, host_lock,
                   repository_files, read_json, state_root, worktree_id, fingerprint, record_build)
from .process import Evidence, Redactor, run_process
from .xcode_tests import DEVICE, RUNTIME, simulator_name
from scripts.gallery.adapter import CaptureIdentity, Manifest, identifier, validate_png

APP_ID = 'com.luworks.today.workbench'
TYPE_SIZES = ('xSmall', 'small', 'medium', 'large', 'xLarge', 'xxLarge', 'xxxLarge',
              'accessibility1', 'accessibility2', 'accessibility3', 'accessibility4', 'accessibility5')
QUARANTINE_PREFIX = '3243BEDB'


@contextmanager
def _locks(root):
    with ExitStack() as stack:
        stack.enter_context(host_lock(root))
        stack.enter_context(dd_lock(root))
        # Same protocol as the existing Xcode/UI authority, not a second device lane.
        for key in sorted(['name:' + simulator_name(root), 'cache:' + str(derived_data(root).resolve())]):
            path = Path(tempfile.gettempdir()) / ('today-qa-lock-' + hashlib.sha256(key.encode()).hexdigest())
            stack.enter_context(ResourceLock(path, str(root)))
        yield


@contextmanager
def _cancellation(cancel):
    previous = {}
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous[sig] = signal.signal(sig, lambda signum, frame: cancel.set())
    try:
        yield
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


class Native:
    def __init__(self, root, timeout, cancel):
        if timeout <= 0:
            raise ValueError('Positive timeout required')
        self.root = Path(root).resolve()
        self.deadline = time.monotonic() + timeout
        self.cancel = cancel if cancel is not None else threading.Event()

    def check(self):
        if self.cancel.is_set():
            raise RuntimeError('Native operation cancelled')
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Native operation timed out')
        return remaining

    def run(self, argv):
        remaining = self.check()
        evidence = Evidence(self.root, 'dev-ui-' + uuid.uuid4().hex, Redactor())
        try:
            result = run_process(argv, cwd=self.root, evidence=evidence, timeout=remaining, cancel=self.cancel)
            if result.reason == 'cancelled':
                self.cancel.set()
            if result.returncode:
                raise RuntimeError(f'Native command {result.reason}; exit={result.returncode}; log={result.log}')
            return result.log.read_text()
        finally:
            evidence.close()


def _inputs(root):
    # Enumerate actual repository files, including untracked inputs and tracked deletions.
    names = repository_files(root)
    sources, locks = [], []
    for name in sorted(set(names)):
        if not name or any(p in ('.build', 'DerivedData', '__pycache__') for p in Path(name).parts):
            continue
        if Path(name).name in ('Package.resolved', 'mise.lock', 'package-lock.json', 'tool-pins.json'):
            locks.append(name)
        elif name.startswith(('ios/', 'tests/fixtures/')):
            sources.append(name)
    if not sources:
        raise ValueError('No repository source inputs')
    return {'sources': sources, 'locks': locks}


def _snapshot(root, inputs):
    result = {}
    for name in inputs['sources'] + inputs['locks']:
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root) or not path.is_file():
            raise ValueError('Missing or unsafe source input: ' + name)
        result[name] = (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mtime_ns)
    return result


def _export(native):
    root = native.root
    inputs = _inputs(root)
    before = _snapshot(root, inputs)
    directory = state_root(root) / 'ui' / worktree_id(root)
    directory.mkdir(parents=True, exist_ok=True)
    source_file = directory / (uuid.uuid4().hex + '-sources.json')
    atomic_json(source_file, inputs)
    native.run(['swift', 'build', '--package-path', 'ios', '--product', 'today-scenes', '--jobs', '2'])
    # SwiftPM's normal debug product link resolves to the host triple's actual executable.
    executable = root / 'ios/.build/debug/today-scenes'
    data = json.loads(native.run([str(executable), '--sources-json', str(source_file)]))
    manifest = Manifest.parse(data, root)
    expected = set(inputs['sources'])
    if set(manifest.locks) != set(inputs['locks']) or any(set(s.sources) != expected for s in manifest.scenes):
        raise ValueError('Registry export changed declared dependencies')
    if _inputs(root) != inputs or _snapshot(root, inputs) != before:
        raise ValueError('Source inputs changed during registry export')
    return manifest, inputs, before


def export_manifest(root, *, timeout=600, cancel=None):
    """Export actual TodayScenes; never parse Swift IDs or maintain a second catalog."""
    native = Native(root, timeout, cancel)
    with _cancellation(native.cancel), _locks(native.root):
        return _export(native)[0]


def _device(native, runtime=RUNTIME):
    root = native.root
    # Inspect names across all runtimes before creating or booting anything.
    listing = json.loads(native.run(['xcrun', 'simctl', 'list', 'devices', '--json']))
    matches = [dict(device, runtime=found_runtime) for found_runtime, devices in listing['devices'].items()
               for device in devices if device.get('name') == simulator_name(root)]
    if len(matches) > 1:
        raise ValueError('Ambiguous owned simulator name')
    lease_path = state_root(root) / 'ui' / worktree_id(root) / 'device.json'
    lease = read_json(lease_path)
    if matches:
        device = matches[0]
        udid = device['udid']
        uuid.UUID(udid)
        if (udid.upper().startswith(QUARANTINE_PREFIX) or device.get('deviceTypeIdentifier') != DEVICE
                or device['runtime'] != runtime or not device.get('isAvailable', False)):
            raise ValueError('Owned simulator has wrong model/runtime or is quarantined/unavailable')
        owned = lease == {'root': str(root), 'udid': udid, 'name': simulator_name(root),
                          'model': DEVICE, 'runtime': runtime, 'warm': True}
        if device.get('state') != 'Shutdown' and not (device.get('state') == 'Booted' and owned):
            raise ValueError('Booted simulator lacks an explicit matching warm lease')
    else:
        udid = native.run(['xcrun', 'simctl', 'create', simulator_name(root), DEVICE, runtime]).strip()
        uuid.UUID(udid)
        if udid.upper().startswith(QUARANTINE_PREFIX):
            raise ValueError('Quarantined simulator')
        device = {'state': 'Shutdown'}
    # The exact lease is persisted before boot, so interrupted boot never grants warm reuse.
    atomic_json(lease_path, {'root': str(root), 'udid': udid, 'name': simulator_name(root),
                             'model': DEVICE, 'runtime': runtime, 'warm': False})
    return udid, device['state'] == 'Booted', lease_path


def _retain(evidence, root, path):
    """Keep app-container and caller-selected temporary evidence in primary results."""
    path = Path(path)
    if not path.resolve().is_relative_to(state_root(root).parent.resolve()):
        directory = state_root(root) / 'ui' / worktree_id(root) / 'evidence'
        directory.mkdir(parents=True, exist_ok=True)
        retained = directory / (uuid.uuid4().hex + path.suffix)
        with retained.open('xb') as stream:
            stream.write(path.read_bytes())
        path = retained
    evidence.journal.artifact(evidence.session, path)


def _wait_receipt(native, container, receipt, scene, scenario):
    directory = container / 'Library/Caches/TodayWorkbench'
    path = directory / (receipt + '.json')
    while True:
        native.check()
        if directory.is_symlink() or path.is_symlink() or not path.resolve().is_relative_to(container):
            raise ValueError('Unsafe scene receipt path')
        if path.exists():
            data = json.loads(path.read_text())
            if (not isinstance(data, dict) or set(data) != {'scene', 'scenario', 'status'}
                    or data['scene'] != scene or data['scenario'] != scenario):
                raise ValueError('Scene receipt configuration mismatch')
            if data['status'] != 'ready':
                raise ValueError('Workbench scene failed readiness')
            return path
        native.cancel.wait(min(0.05, native.check()))


def _options(scene, scenario, appearance, type_size, locale):
    identifier(scene)
    identifier(scenario)
    if appearance not in ('light', 'dark', 'system') or type_size not in TYPE_SIZES:
        raise ValueError('Unsupported appearance or Dynamic Type size')
    if not isinstance(locale, str) or not re.fullmatch(r'[A-Za-z]{2,3}(?:[_-][A-Za-z0-9]{2,8}){0,3}', locale):
        raise ValueError('Invalid locale identifier')


def _perform(root, scene, scenario, output, appearance, type_size, locale, timeout, cancel, keep_warm):
    _options(scene, scenario, appearance, type_size, locale)
    native = Native(root, timeout, cancel)
    root = native.root
    if output is not None:
        output = Path(output).absolute()
        receipt_output = output.with_suffix('.json')
        if output.suffix.lower() != '.png' or any(p.exists() or p.is_symlink() for p in (output, receipt_output)):
            raise ValueError('Capture output must be a new PNG with a new adjacent JSON receipt')
        output.parent.mkdir(parents=True, exist_ok=True)
    with _cancellation(native.cancel), _locks(root):
        from . import commands
        generated = commands.generate(root, timeout=native.check(), _locked=True)
        if generated:
            raise RuntimeError('Workbench project generation failed')
        native.check()
        identity = fingerprint(root, scheme='TodayWorkbench', architecture='arm64')
        manifest, inputs, before = _export(native)
        manifest.scene(scene, scenario)
        from .resolve import locked_arguments
        flags = locked_arguments(root)
        native.run(['xcodebuild', 'build', '-project', 'ios/Today.xcodeproj', '-scheme', 'TodayWorkbench',
                    '-configuration', 'Debug', '-destination', 'generic/platform=iOS Simulator',
                    '-derivedDataPath', str(derived_data(root)), '-jobs', '2', 'ARCHS=arm64', *flags])
        app = derived_data(root) / 'Build/Products/Debug-iphonesimulator/TodayWorkbench.app'
        if not app.is_dir():
            raise ValueError('TodayWorkbench build product is missing')
        if fingerprint(root, scheme='TodayWorkbench', architecture='arm64') != identity:
            raise ValueError('Workbench source or toolchain changed during build')
        record_build(root, identity, [app], returncode=0)
        udid, booted, lease_path = _device(native)
        success = False
        temporary = None
        try:
            if not booted:
                native.run(['xcrun', 'simctl', 'boot', udid])
            native.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'])
            native.run(['xcrun', 'simctl', 'install', udid, str(app)])
            receipt = str(uuid.uuid4()).upper()
            native.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', udid, APP_ID,
                        '-scene', scene, '-scenario', scenario, '-sceneAppearance', appearance,
                        '-sceneTypeSize', type_size, '-sceneLocale', locale, '-sceneReceipt', receipt])
            raw = native.run(['xcrun', 'simctl', 'get_app_container', udid, APP_ID, 'data']).strip()
            container = Path(raw)
            if not container.is_absolute() or not container.is_dir() or container.is_symlink():
                raise ValueError('Invalid owned app data container')
            ready = _wait_receipt(native, container, receipt, scene, scenario)
            identity = CaptureIdentity(device=f'{simulator_name(root)} / iPhone 18 Pro Max / {udid}', os='iOS 27.0')
            if output is not None:
                # Screenshot to a unique new file; exclusive publication never overwrites a prior image.
                temporary = output.parent / (uuid.uuid4().hex + '.png')
                native.run(['xcrun', 'simctl', 'io', udid, 'screenshot', '--type=png', str(temporary)])
                if temporary.is_symlink() or not temporary.is_file():
                    raise ValueError('Missing native screenshot')
                validate_png(temporary.read_bytes())
                if _inputs(root) != inputs or _snapshot(root, inputs) != before:
                    raise ValueError('Source inputs changed during native capture')
                os.link(temporary, output)
                temporary.unlink()
            if _inputs(root) != inputs or _snapshot(root, inputs) != before:
                raise ValueError('Source inputs changed during native operation')
            native.check()
            if output is not None:
                with receipt_output.open('x') as stream:
                    json.dump({'device': identity.device, 'os': identity.os}, stream)
            evidence = Evidence(root, 'dev-ui-ready-' + receipt, Redactor())
            try:
                _retain(evidence, root, ready)
                if output is not None:
                    _retain(evidence, root, output)
                    _retain(evidence, root, receipt_output)
            finally:
                evidence.close()
            success = True
            return identity
        finally:
            if success and keep_warm:
                atomic_json(lease_path, {'root': str(root), 'udid': udid, 'name': simulator_name(root),
                                         'model': DEVICE, 'runtime': RUNTIME, 'warm': True})
            else:
                # Cancellation must not skip owned device cleanup; use an independent bounded process.
                cleanup = Native(root, 30, threading.Event())
                cleanup.run(['xcrun', 'simctl', 'shutdown', udid])
            if temporary is not None and temporary.is_file() and not temporary.is_symlink():
                evidence = Evidence(root, 'dev-ui-partial-' + uuid.uuid4().hex, Redactor())
                try:
                    _retain(evidence, root, temporary)
                finally:
                    evidence.close()


def open_scene(root, scene, scenario, appearance='light', type_size='large', locale='en_US', *, timeout=600, cancel=None):
    """Keep the exact leased simulator warm for interaction in the Device panel."""
    return _perform(root, scene, scenario, None, appearance, type_size, locale, timeout, cancel, True)


def capture(root, scene, scenario, output, appearance='light', type_size='large', locale='en_US', *,
            timeout=600, cancel=None, keep_warm=False):
    """Capture only after app-owned readiness; failures never emit a success receipt."""
    return _perform(root, scene, scenario, output, appearance, type_size, locale, timeout, cancel, keep_warm)


def gallery(root, watch, port=0):
    """Serve the existing Gallery; NativeCommands retains the narrow ./dev boundary."""
    from scripts.gallery.adapter import Gallery
    from scripts.gallery.server import GalleryServer
    instance = Gallery(Path(root).resolve(), export_manifest(root))
    server, previous = None, {}
    def stop(signum, frame):
        instance.native.cancel.set()
        raise KeyboardInterrupt
    try:
        server = GalleryServer(instance, port=port, watch=watch)
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous[sig] = signal.signal(sig, stop)
        print('Gallery: ' + server.url, flush=True)
        print('Evidence: ' + str(instance.directory), flush=True)
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        if server:
            server.server_close()
        instance.close()
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return 0


def prepare(root, runtime):
    """Install Mock without launching; the Device panel owns all interaction."""
    if not re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9]+-[0-9]+', runtime):
        raise ValueError('Expected an explicit iOS simulator runtime identifier')
    from . import commands
    code = commands.build(root, scheme='TodayMock')
    if code:
        raise RuntimeError('Mock build failed')
    native = Native(root, 120, None)
    with _locks(root):
        udid, booted, lease_path = _device(native, runtime=runtime)
        if not booted:
            native.run(['xcrun', 'simctl', 'boot', udid])
        native.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'])
        app = derived_data(root) / 'Build/Products/Debug-iphonesimulator/TodayMock.app'
        native.run(['xcrun', 'simctl', 'install', udid, str(app)])
        atomic_json(lease_path, {'root': str(Path(root).resolve()), 'udid': udid,
                                 'name': simulator_name(root), 'model': DEVICE,
                                 'runtime': runtime, 'warm': True})
        return {'hostId': 'local', 'deviceId': udid, 'app': 'com.luworks.today'}
