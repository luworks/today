#!/usr/bin/env python3
"""One bounded current-Year Allocations diagnosis, never speed acceptance.

Caller holds the active owned performance simulator, shows its Booted simulator, and has built the
current products for testing once. No build, boot, manual install, settings,
app termination or retries. The parent owns the journey and device release.
Only the first app PID after the exact method start may be attached. Producer
success does not establish stage coverage: inspect actual exported evidence.
"""
import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time


from simulator_policy import ACTIVE_NAME, ACTIVE_UDID

SIMULATOR = ACTIVE_UDID
ROOT = Path('/Users/yuanlu/code/one-app/tests/results/runs')
DD = ROOT / 'performance-climb-20261018/derived-optimized'
PROJECT = ROOT / 'performance-pages-ai-20261018/build-source/ios/One.xcodeproj'
PRODUCT = DD / 'Build/Products/Debug-iphonesimulator/One.app'
TEST_BUNDLE = DD / 'Build/Products/Debug-iphonesimulator/OneUITests-Runner.app/PlugIns/OneUITests.xctest'
SELECTOR = 'OneUITests/PerformanceClimbTests/testYearEntryAllocationDiagnostic'
METHOD_START = "Test Case '-[OneUITests.PerformanceClimbTests testYearEntryAllocationDiagnostic]' started."
UUID_PATTERN = re.compile(r'^UUID:\s+([A-Fa-f0-9-]{36})\s+\(([^)]+)\)', re.MULTILINE)


def exact_processes(text):
    """Use executable comm, never process arguments or runner-name guesses."""
    found = []
    for line in text.splitlines():
        parts = line.strip().split(maxsplit=1)
        if (len(parts) == 2 and parts[0].isdigit()
                and f'/Devices/{SIMULATOR}/data/Containers/Bundle/Application/' in parts[1]
                and parts[1].endswith('/One.app/One')):
            found.append((int(parts[0]), parts[1]))
    return found


def owned_booted_device(inventory):
    matches = [(runtime, dev) for runtime, devices in inventory['devices'].items()
               for dev in devices if dev.get('udid') == SIMULATOR]
    if len(matches) != 1:
        raise RuntimeError('Exactly one owned simulator required')
    runtime, dev = matches[0]
    if (not runtime.startswith('com.apple.CoreSimulator.SimRuntime.iOS-')
            or dev.get('name') != ACTIVE_NAME
            or dev.get('state') != 'Booted' or dev.get('isAvailable') is not True):
        raise RuntimeError('Available Booted active performance simulator required; caller owns visibility')
    return dev


def binary_uuids(text):
    values = sorted((uuid.upper(), arch) for uuid, arch in UUID_PATTERN.findall(text))
    if not values or len(values) != len(set(values)):
        raise RuntimeError('Missing or duplicate Mach-O UUID evidence')
    return values


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--reference-app', required=True, type=Path,
                        help='Existing preserved current One.app; never an old hardcoded reference')
    parser.add_argument('--wall-limit', type=float, default=150,
                        help='Total seconds including ten seconds for cleanup (30..180)')
    args = parser.parse_args(argv)
    if not math.isfinite(args.wall_limit) or not 30 <= args.wall_limit <= 180:
        parser.error('--wall-limit must be finite and 30..180 including 10s cleanup')
    start = time.monotonic()
    deadline, active_end = start + args.wall_limit, start + args.wall_limit - 10
    out = args.output.expanduser().resolve()
    if not out.is_relative_to(ROOT.resolve()) or out == ROOT.resolve():
        parser.error('--output must be a NEW directory under canonical tests/results/runs')
    try:
        out.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        parser.error('Output exists; evidence must never be overwritten')
    children, streams, locks = [], [], []
    status = {'status': 'running', 'classification': 'diagnosis only; no speed acceptance',
              'stage_coverage': 'unverified until actual export and analysis',
              'caller_preconditions': 'explicit resource holder, visible Booted owned simulator, built-for-testing once',
              'wall_limit': args.wall_limit, 'cleanup_reserve': 10, 'commands': [],
              'binary_evidence': {}, 'selector': SELECTOR}
    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    def save():
        (out / 'status.json').write_text(json.dumps(status, indent=2) + '\n')

    def remaining():
        value = active_end - time.monotonic()
        if value <= 0:
            raise TimeoutError('Active budget exhausted; preserving partial evidence')
        return value

    def pause(until=active_end):
        delay = min(0.25, remaining(), max(0, until - time.monotonic()))
        time.sleep(delay)

    def digest(path):
        value = hashlib.sha256()
        with path.open('rb') as stream:
            while True:
                remaining()
                block = stream.read(1024 * 1024)
                if not block:
                    return value.hexdigest()
                value.update(block)

    def launch(label, command):
        remaining()
        entry = {'label': label, 'argv': command, 'monotonic_before': time.monotonic()}
        status['commands'].append(entry)
        save()
        stdout = (out / (label + '.stdout')).open('xb')
        stderr = (out / (label + '.stderr')).open('xb')
        streams.extend((stdout, stderr))
        child = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
        children.append((label, child))
        entry['pid'] = child.pid
        save()
        return child

    def read(label, command, timeout=5):
        child = launch(label, command)
        until = min(active_end, time.monotonic() + timeout)
        while child.poll() is None:
            if time.monotonic() >= until:
                raise TimeoutError(f'{label} exceeded bounded timeout; no retry')
            pause(until)
        status['commands'][-1]['exit_code'] = child.returncode
        save()
        if child.returncode:
            raise RuntimeError(f'{label} exit {child.returncode}; inspect raw evidence')
        return (out / (label + '.stdout')).read_text(errors='replace')

    def processes(label, until=active_end):
        timeout = min(2, until - time.monotonic())
        if timeout <= 0:
            raise TimeoutError('PID discovery deadline exhausted')
        return exact_processes(read(label, ['ps', '-axo', 'pid=,comm='], timeout))

    def verify_binaries(reference, installed):
        for name in ('One', 'One.debug.dylib'):
            paths = {'reference': reference / name, 'product': PRODUCT / name,
                     'installed': installed / name}
            evidence = status['binary_evidence'][name] = {
                role: {'path': str(path), 'present': path.is_file()} for role, path in paths.items()}
            save()
            present = [path.is_file() for path in paths.values()]
            if name == 'One.debug.dylib' and not any(present):
                continue
            if not all(present):
                raise RuntimeError(f'{name}: reference/product/installed presence mismatch')
            for role, path in paths.items():
                evidence[role]['sha256'] = digest(path)
                save()
                raw = read(f'uuid-{name}-{role}', ['xcrun', 'dwarfdump', '--uuid', str(path)])
                evidence[role]['uuids'] = binary_uuids(raw)
                save()
            if (len({item['sha256'] for item in evidence.values()}) != 1
                    or any(item['uuids'] != evidence['reference']['uuids'] for item in evidence.values())):
                raise RuntimeError(f'{name}: SHA256/UUID mismatch; no attach or install fallback')

    signal.signal(signal.SIGTERM, interrupted)
    save()
    try:
        status['script_sha256'] = digest(Path(__file__))
        save()
        # Share the established nonblocking name/DD lock namespace with other profilers.
        for key in sorted(['name:' + ACTIVE_NAME, 'cache:' + str(DD.resolve(strict=True))]):
            path = Path(tempfile.gettempdir()) / ('today-qa-lock-' + hashlib.sha256(key.encode()).hexdigest())
            lock = path.open('a')
            locks.append(lock)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        reference = args.reference_app.expanduser().resolve(strict=True)
        status['reference_app'] = str(reference)
        if reference.name != 'One.app' or not reference.is_dir():
            raise RuntimeError('Existing preserved One.app reference required')
        if not PROJECT.is_dir() or not TEST_BUNDLE.is_dir() or not PRODUCT.is_dir():
            raise RuntimeError('Existing project and built-for-testing products required')
        status['test_bundle'] = str(TEST_BUNDLE)
        status['device'] = owned_booted_device(json.loads(read(
            'inventory', ['xcrun', 'simctl', 'list', 'devices', '-j'])))
        if processes('initial-processes'):
            raise RuntimeError('Owned app PID already exists; caller must stop it; no automatic termination')
        # Do not validate the old installed app: the UI runner installs current products.
        command = ['xcodebuild', 'test-without-building', '-project', str(PROJECT), '-scheme', 'One',
                   '-configuration', 'Debug', '-derivedDataPath', str(DD),
                   '-destination', 'id=' + SIMULATOR, '-only-testing:' + SELECTOR,
                   '-parallel-testing-enabled', 'NO', '-jobs', '2', 'SWIFT_OPTIMIZATION_LEVEL=-O',
                   '-resultBundlePath', str(out / 'ui.xcresult')]
        (out / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
        status['command_sha256'] = digest(out / 'command.json')
        runner = launch('ui-runner', command)
        method_deadline = min(active_end, time.monotonic() + 60)
        while not any(METHOD_START in (out / ('ui-runner.' + suffix)).read_text(errors='replace')
                      for suffix in ('stdout', 'stderr')):
            if runner.poll() is not None:
                raise RuntimeError('Runner exited before exact method start; no attach')
            if time.monotonic() >= method_deadline:
                raise TimeoutError('Exact method start not observed within 60s')
            pause(method_deadline)
        if time.monotonic() >= method_deadline:
            raise TimeoutError('Exact method start observed after its deadline')
        status['method_start_observed_monotonic'] = time.monotonic()
        save()
        pid_deadline, iteration = min(active_end, time.monotonic() + 45), 0
        while True:
            if runner.poll() is not None:
                raise RuntimeError('Runner exited before first new app PID discovery')
            if time.monotonic() >= pid_deadline:
                raise TimeoutError('First new app PID not discovered within 45s after method start')
            found = processes(f'pid-{iteration}', pid_deadline)
            iteration += 1
            if time.monotonic() >= pid_deadline:
                raise TimeoutError('PID discovery completed after its deadline')
            if len(found) > 1:
                raise RuntimeError('Ambiguous exact app PIDs; no guessed attach')
            if found:
                target, executable = found[0]
                break
            pause(pid_deadline)
        status.update(first_pid=target, executable=executable,
                      pid_discovered_monotonic=time.monotonic())
        save()
        installed = Path(read('target-container', ['xcrun', 'simctl', 'get_app_container',
                              SIMULATOR, 'com.luworks.today', 'app']).strip()).resolve(strict=True)
        if Path(executable).resolve(strict=True) != (installed / 'One').resolve(strict=True):
            raise RuntimeError('New PID executable does not correspond to installed container')
        verify_binaries(reference, installed)
        if processes('verified-processes') != [(target, executable)] or runner.poll() is not None:
            raise RuntimeError('First PID or live runner changed during verification; no alternate attach')
        status['pid_verified_monotonic'] = time.monotonic()
        if remaining() < 26:
            raise TimeoutError('Insufficient active budget for one 25s capture')
        trace = out / 'year-allocations.trace'
        profiler = launch('profiler', ['xcrun', 'xctrace', 'record', '--device', SIMULATOR,
                         '--template', 'Allocations', '--instrument', 'os_signpost',
                         '--attach', str(target), '--time-limit', '25s', '--output', str(trace)])
        while runner.poll() is None or profiler.poll() is None:
            for label, child in [('runner', runner), ('profiler', profiler)]:
                if child.poll() is not None and child.returncode != 0:
                    raise RuntimeError(f'{label} exit {child.returncode}; no retry')
            pause()
        status.update(runner_exit_code=runner.returncode, profiler_exit_code=profiler.returncode)
        save()
        if runner.returncode != 0 or profiler.returncode != 0 or not trace.is_dir():
            raise RuntimeError('Both producers must exit zero and leave a trace')
        if active_end - time.monotonic() > 15.5:
            read('toc-export', ['xcrun', 'xctrace', 'export', '--input', str(trace),
                               '--toc', '--output', str(out / 'toc.xml')], 15)
        else:
            status['toc_skipped'] = 'Insufficient budget after producers closed'
        status['status'] = 'recorded; actual stage coverage remains unverified'
    except (OSError, ValueError, KeyError, RuntimeError, TimeoutError) as error:
        status.update(status='failed', error=str(error))
    except KeyboardInterrupt:
        status.update(status='interrupted', error='Caller interrupted')
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        # Signal owned groups even if their leaders exited; descendants can remain.
        cleanup_end = min(deadline, time.monotonic() + 10)
        for sig, seconds in [(signal.SIGINT, 6), (signal.SIGTERM, 2), (signal.SIGKILL, 1)]:
            for _, child in children:
                try:
                    os.killpg(child.pid, sig)
                except ProcessLookupError:
                    pass
            until = min(cleanup_end, time.monotonic() + seconds)
            while time.monotonic() < until:
                live_groups = False
                for _, child in children:
                    child.poll()
                    try:
                        os.killpg(child.pid, 0)
                        live_groups = True
                    except ProcessLookupError:
                        pass
                if not live_groups:
                    break
                time.sleep(min(0.25, max(0, until - time.monotonic())))
        status['process_exit_codes'] = {label: child.poll() for label, child in children}
        status['remaining_process_groups'] = []
        for label, child in children:
            try:
                os.killpg(child.pid, 0)
                status['remaining_process_groups'].append({'label': label, 'pgid': child.pid})
            except ProcessLookupError:
                pass
        for stream in streams:
            stream.close()
        for lock in reversed(locks):
            lock.close()
        status['elapsed_seconds'] = time.monotonic() - start
        save()
        signal.signal(signal.SIGTERM, previous_sigterm)
    print(json.dumps({'output': str(out), 'status': status['status'], 'error': status.get('error')}))
    return 0 if status['status'].startswith('recorded;') and not status['remaining_process_groups'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
