"""Read-only offline prerequisite inspection; no installs, mise, locks or evidence writes."""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

from .bootstrap import bootstrap, sha256
from .core import toolchain
from .process import Redactor


def _version(argv, root, env=None):
    # A minimal environment prevents injected runtime hooks and user tool shims.
    environment = {k: v for k, v in os.environ.items() if k in ('HOME', 'TMPDIR', 'SYSTEMROOT')}
    environment.update(PATH='/usr/bin:/bin', LANG='en_US.UTF-8', PYTHONDONTWRITEBYTECODE='1',
                       FASTLANE_OPT_OUT_USAGE='1', FASTLANE_SKIP_UPDATE_CHECK='1',
                       FASTLANE_HIDE_CHANGELOG='1', FASTLANE_SKIP_DOCS='1',
                       BUNDLE_IGNORE_CONFIG='1', BUNDLE_FROZEN='true')
    environment.update(env or {})
    return subprocess.check_output(list(map(str, argv)), cwd=root, env=environment,
                                   stderr=subprocess.PIPE, timeout=10).decode().strip()


def _toml(path):
    try:
        import tomllib
    except ImportError:
        import tomli as tomllib
    return tomllib.loads(path.read_text())


def inspect(root):
    """Return structured checks. Only required failures affect ``ok``.

    Optional absent/unverified checks stay visible as such; offline package-cache,
    simulator, credentials, signing, profiles and network readiness are not probed.
    """
    root = Path(root).resolve()
    checks = {}

    def add(name, passed, expected, actual=None, *, required=True, detail=None):
        checks[name] = dict(status='pass' if passed else 'fail', required=required,
                            expected=expected, actual=actual, detail=detail)

    def version(name, argv, expected, *, env=None, required=True):
        if not all(Path(p).is_file() and os.access(p, os.X_OK) for p in [argv[0]]):
            add(name, False, expected, required=required, detail='Missing executable: ' + str(argv[0]))
            return
        try:
            output = _version(argv, root, env)
            matched = re.search(r'(?<![\d.])' + re.escape(expected) + r'(?![\d.])', output) is not None
            add(name, matched, expected, output, required=required)
        except (OSError, subprocess.SubprocessError):
            add(name, False, expected, required=required, detail='Read-only version probe failed: ' + str(argv[0]))

    try:
        manifest = json.loads((root / 'docs/engineering/tool-pins.json').read_text())
        add('tool_pins', manifest.get('schema_version') == 1, 'schema_version=1', manifest.get('schema_version'))
    except (OSError, ValueError):
        manifest = {'tools': {}}
        add('tool_pins', False, 'readable docs/engineering/tool-pins.json')
    try:
        chain = toolchain()
        xcode = chain.get('xcode') or {}
        add('xcode', xcode.get('CFBundleShortVersionString') == '27.2'
            and xcode.get('ProductBuildVersion') == '27B52', '27.2 / 27B52',
            {k: xcode.get(k) for k in ('CFBundleShortVersionString', 'ProductBuildVersion')})
        developer = Path(chain['developer_dir']) if chain.get('developer_dir') else None
        for platform in ('iPhoneOS', 'iPhoneSimulator'):
            found = []
            if developer:
                paths = developer.glob('Platforms/' + platform + '.platform/Developer/SDKs/*.sdk')
                for sdk in sorted({p.resolve() for p in paths}):
                    try:
                        with (sdk / 'SDKSettings.plist').open('rb') as stream:
                            settings = plistlib.load(stream)
                        found.append({'path': str(sdk), 'version': settings.get('Version'),
                                      'canonical_name': settings.get('CanonicalName')})
                    except (OSError, ValueError, plistlib.InvalidFileException):
                        continue
            add(platform + '_sdk', any(s['version'] == '27.2' and s['canonical_name'] ==
                platform.lower() + '27.2' for s in found), platform.lower() + '27.2', found)
        if developer:
            bin_dir = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin'
            version('swift', [bin_dir / 'swiftc', '--version'], '6.4.2')
            formatter = bin_dir / 'swift-format'
            version('swift-format', [formatter, '--version'], '6.4.4')
            receipt = root / '.dev-tools/swift-format.json'
            if receipt.is_file():
                stored = json.loads(receipt.read_text())
                add('swift-format_binary_hash', formatter.is_file() and
                    stored.get('xcode_build') == '27B52' and stored.get('sha256') == sha256(formatter),
                    'bootstrap receipt SHA-256 and Xcode build', required=False)
            else:
                checks['swift-format_binary_hash'] = dict(status='unverified', required=False,
                    expected='optional bootstrap binary SHA-256 receipt', actual=None)
        else:
            add('swift', False, '6.4.2', detail='Missing selected Xcode developer directory')
            add('swift-format', False, 'Xcode 27B52 bundled formatter')
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        add('toolchain', False, 'readable selected Xcode metadata', detail=type(error).__name__)

    # Bootstrap's plan validates every installed file hash/mode and executable
    # architecture against its receipt; it performs no network or state writes.
    for name in ('xcodegen', 'swiftlint', 'mise', 'ruff', 'actionlint'):
        try:
            item = bootstrap(root, tools=[name], plan=True)['tools'][0]
            required = name != 'mise'
            add(name + '_installation', item['status'] == 'ready', 'verified pinned bootstrap receipt',
                item['status'], required=required, detail=item['destination'])
            if item['status'] == 'ready' and name != 'mise':
                version(name, [item['executable'], '--version'], manifest['tools'][name]['version'])
        except (OSError, ValueError, RuntimeError, KeyError) as error:
            add(name + '_installation', False, 'verified pinned bootstrap receipt',
                required=name != 'mise', detail=type(error).__name__)

    try:
        config, lock = _toml(root / '.mise.toml'), _toml(root / 'mise.lock')
        release = json.loads((root / 'scripts/release/tool-lock.json').read_text())
        gems, gemfile = (root / 'Gemfile.lock').read_text(), (root / 'Gemfile').read_text()
        versions = {'ruby': '3.3.12', 'python': '3.14.8'}
        for name, expected in versions.items():
            entries = lock.get('tools', {}).get(name, [])
            entry = entries[0] if len(entries) == 1 else {}
            payload = entry.get('platforms.macos-arm64', {})
            good = (config.get('tools', {}).get('core:' + name) == expected
                    and entry.get('version') == expected and entry.get('backend') == 'core:' + name
                    and entry.get('specifiers') == [expected]
                    and re.fullmatch(r'sha256:[a-f0-9]{64}', payload.get('checksum', '')) is not None
                    and config.get('settings', {}).get(name, {}).get('compile') is False)
            if name == 'ruby':
                good = good and release.get('ruby') == expected and '\n  ruby ' + expected + '\n' in gems
                good = good and 'ruby "' + expected + '"' in gemfile
            add(name + '_lock', good, expected + ' consistent config/lock/checksum/no-compile')
        bundler, fastlane = '4.0.16', manifest['tools']['fastlane']['version']
        add('bundler_lock', release.get('bundler') == bundler and
            '\nBUNDLED WITH\n  ' + bundler + '\n' in gems, bundler)
        add('fastlane_lock', release.get('fastlane') == fastlane and
            '\n    fastlane (' + fastlane + ')\n' in gems and
            'gem "fastlane", "= ' + fastlane + '"' in gemfile, fastlane)
        runtime = root / '.dev-tools/runtime/installs'
        ruby = runtime / 'ruby/3.3.12/bin/ruby'
        python = runtime / 'python/3.14.8/bin/python3'
        version('ruby', [ruby, '--version'], '3.3.12')
        version('python', [python, '--version'], '3.14.8')
        ruby_gems = runtime / 'ruby/3.3.12/lib/ruby/gems/3.3.0'
        bundle_gems = root / '.dev-tools/bundle/ruby/3.3.0'
        env = dict(GEM_HOME=str(ruby_gems), GEM_PATH=os.pathsep.join(map(str, [ruby_gems, bundle_gems])),
                   PATH=str(ruby.parent) + ':/usr/bin:/bin')
        for name, path, expected in [
            ('bundler', ruby_gems / ('gems/bundler-' + bundler + '/exe/bundle'), bundler),
            ('fastlane', bundle_gems / ('gems/fastlane-' + fastlane + '/bin/fastlane'), fastlane)]:
            if not path.is_file():
                add(name, False, expected, detail='Missing locked gem entrypoint: ' + str(path))
            else:
                version(name, [ruby, path, '--version'], expected, env=env)
    except (ImportError, OSError, ValueError, KeyError) as error:
        add('runtime_locks', False, 'readable, consistent runtime and gem locks', detail=type(error).__name__)
        for name, expected in [('ruby', '3.3.12'), ('python', '3.14.8'),
                               ('bundler', '4.0.16'), ('fastlane', '2.241.1')]:
            if name not in checks:
                add(name, False, expected, detail='Not checked: runtime lock prerequisites failed')
    from .resolve import locked_arguments
    try:
        locked_arguments(root)
        add('package_locks', True, 'source pins and workspace match versioned authority')
    except (OSError, ValueError, KeyError) as error:
        add('package_locks', False, 'source pins and workspace match versioned authority', detail=str(error))
    checks['offline_readiness'] = dict(status='unverified', required=False,
        expected='not probed: package caches, simulator runtimes, network, signing or credentials')
    result = dict(ok=all(c['status'] == 'pass' for c in checks.values() if c['required']),
                  checks=checks, read_only=True)
    return json.loads(Redactor()(json.dumps(result)))
