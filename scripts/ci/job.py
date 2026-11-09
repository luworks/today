#!/usr/bin/env python3
"""Merge-gate CI steps with failure-only evidence.

`--command <argv>...` runs one `./dev` step (the `checks` job). `--build` is `today-required`:
one TodayCI build-for-testing and an identity check of the three production products. `--release`
compiles the app, widget and share extension for a device in Release, unsigned.
Standard library only; prints elapsed seconds per step for timing.
"""
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.ci import mtimes  # noqa: E402 - direct script execution from any cwd
from scripts.ci.failure import FailureEvidence  # noqa: E402 - direct script execution from any cwd

EVIDENCE = None
TEMP = Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'today-ci'
DD = TEMP / 'dd'
PRODUCTS = {'One.app': 'com.luworks.today',
            'One.app/PlugIns/TodayWidgets.appex': 'com.luworks.today.widgets',
            'One.app/PlugIns/ShareExtension.appex': 'com.luworks.today.share'}
FLAGS = ['-derivedDataPath', str(DD), '-disableAutomaticPackageResolution',
         '-onlyUsePackageVersionsFromResolvedFile', '-skipPackageUpdates',
         'COMPILER_INDEX_STORE_ENABLE=NO', 'SWIFT_ENABLE_EXPLICIT_MODULES=NO']
STARTED = time.monotonic()


def step(name):
    print(f'::notice::ci +{time.monotonic() - STARTED:.0f}s {name}', flush=True)


def run(*argv, capture=False):
    return EVIDENCE.run(*argv, capture=capture)


def generate():
    TEMP.mkdir(parents=True, exist_ok=True)
    run('./dev', 'bootstrap', '--tool', 'xcodegen')
    run('./dev', 'generate')
    lock = ROOT / 'ios/Today.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    lock.parent.mkdir(parents=True, exist_ok=True)
    lock.write_bytes((ROOT / 'ios/Dependencies/Package.resolved').read_bytes())


def release():
    generate()
    step('project generated')
    run('xcodebuild', 'build', '-quiet', '-project', 'ios/Today.xcodeproj', '-scheme', 'Today',
        '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-jobs', '3',
        'CODE_SIGNING_ALLOWED=NO', *FLAGS)
    step('built App, Widget and Share for a device in Release')
    return 0


def build():
    generate()
    # A restored DerivedData is only reusable if unchanged inputs look unchanged: same content, same
    # mtime, and XCBuild must not treat the new volume and inodes as changes.
    mtimes.stamp(ROOT)
    run('defaults', 'write', 'com.apple.dt.XCBuild', 'IgnoreFileSystemDeviceInodeChanges', '-bool', 'YES')
    step('project generated')
    run('xcodebuild', 'build-for-testing', '-quiet', '-project', 'ios/Today.xcodeproj', '-scheme', 'TodayCI',
        '-configuration', 'Debug', '-destination', 'generic/platform=iOS Simulator', '-jobs', '3',
        'ARCHS=arm64', *FLAGS)
    step('built App, Widget, Share, Mock and test bundles')
    products = DD / 'Build/Products/Debug-iphonesimulator'
    for path, identifier in PRODUCTS.items():
        info = plistlib.loads((products / path / 'Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != identifier or not (products / path / info['CFBundleExecutable']).is_file():
            raise SystemExit('Missing production product: ' + path)
        EVIDENCE.data['products'][path].update(
            status='verified', bundle_id=info['CFBundleIdentifier'],
            executable_sha256=hashlib.sha256((products / path / info['CFBundleExecutable']).read_bytes()).hexdigest(),
            info_sha256=hashlib.sha256((products / path / 'Info.plist').read_bytes()).hexdigest())
        EVIDENCE.write()
    return 0


def entry(argv):
    global EVIDENCE
    command = argv[1:] if argv[:1] == ['--command'] else None
    if command is None and argv not in (['--build'], ['--release']):
        raise SystemExit('usage: job.py --build | --release | --command <argv>...')
    if command == []:
        raise SystemExit('command required')
    EVIDENCE = FailureEvidence(ROOT, TEMP, PRODUCTS, lane='checks' if command else 'build')
    code = 1
    try:
        code = EVIDENCE.run(*command) if command else release() if argv == ['--release'] else build()
    except subprocess.CalledProcessError as error:
        code = error.returncode
    except SystemExit as error:
        EVIDENCE.data['error'] = EVIDENCE.redact(str(error))
        code = error.code if isinstance(error.code, int) else 1
        print(EVIDENCE.redact(str(error)), file=sys.stderr)
    except Exception as error:
        EVIDENCE.data['error'] = EVIDENCE.redact(repr(error))
        print(EVIDENCE.redact(repr(error)), file=sys.stderr)
    finally:
        # A later failure must not erase the first command exit.
        if EVIDENCE.first_failure:
            code = EVIDENCE.first_failure['exit']
        try:
            EVIDENCE.finish(code)
        except Exception as error:
            print('Evidence finalization failed: ' + EVIDENCE.redact(repr(error)), file=sys.stderr)
            code = code or 1
    return code


if __name__ == '__main__':
    sys.exit(entry(sys.argv[1:]))
