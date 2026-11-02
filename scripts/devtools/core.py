"""Read-only discovery, cross-process ownership, and build provenance."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import time
import uuid


def probe(argv, cwd=None, *, timeout=None):
    """Run only explicit read probes; never invoke a shell or xcrun."""
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0')
    # Cold checkout enumeration can exceed five seconds on a loaded hosted Mac.
    timeout = timeout if timeout is not None else (30 if argv and argv[0] == 'git' else 5)
    started = time.monotonic()
    with subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE) as child:
        try:
            output, stderr = child.communicate(timeout=timeout)
            if child.returncode:
                raise subprocess.CalledProcessError(child.returncode, argv, output, stderr)
        except subprocess.TimeoutExpired as error:
            child.kill()  # Only the direct read-probe child belongs to us.
            output, error.stderr = child.communicate()
            error.output = output
            error.pid = child.pid
            error.seconds = time.monotonic() - started
            raise
    return output.decode().strip()


def canonical_root(root):
    root = Path(root).resolve()
    dotgit = root / '.git'
    if dotgit.is_file():
        gitdir = (root / dotgit.read_text().split(':', 1)[1].strip()).resolve()
        common = gitdir / 'commondir'
        gitdir = (gitdir / common.read_text().strip()).resolve() if common.exists() else gitdir
        return gitdir.parent if gitdir.name == '.git' else root
    return root


def worktree_id(root):
    return hashlib.sha256(os.fsencode(Path(root).resolve())).hexdigest()[:20]


def state_root(root):
    return canonical_root(root) / 'tests/results/devtools'


def derived_data(root):
    return state_root(root) / 'derived-data' / worktree_id(root)


def read_json(path):
    try:
        data = json.loads(Path(path).read_text())
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def atomic_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with temporary.open('x') as stream:
            json.dump(data, stream, sort_keys=True, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def inspect_lock(path):
    """Kernel lock is authoritative; old PID metadata never authorizes a kill."""
    path = Path(path)
    try:
        with path.open('r') as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                held = True
            else:
                held = False
                fcntl.flock(stream, fcntl.LOCK_UN)
            try:
                metadata = json.load(stream)
            except ValueError:
                metadata = None
            return {'held': held, 'metadata': metadata}
    except FileNotFoundError:
        return {'held': False, 'metadata': None}


class ResourceBusy(RuntimeError):
    pass


class ResourceLock:
    """Persistent inode, nonblocking flock; never unlink a shared lock file."""
    def __init__(self, path, owner):
        self.path, self.owner, self.stream = Path(path), owner, None

    def __enter__(self):
        if self.stream is not None:
            raise RuntimeError('Lock instance is already acquired')
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.stream = self.path.open('a+')
        try:
            fcntl.flock(self.stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.stream.close()
            self.stream = None
            raise ResourceBusy(f'Resource locked: {self.path}') from None
        try:
            self.stream.seek(0)
            self.stream.truncate()
            json.dump({'pid': os.getpid(), 'host': platform.node(), 'owner': self.owner,
                       'token': uuid.uuid4().hex, 'acquired': time.time()}, self.stream)
            self.stream.flush()
            os.fsync(self.stream.fileno())
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def __exit__(self, *exc):
        if self.stream:
            fcntl.flock(self.stream, fcntl.LOCK_UN)
            self.stream.close()
            self.stream = None


def host_lock(root):
    # One conservative host-heavy slot shared by every worktree of this project.
    return ResourceLock(state_root(root) / 'locks/host-heavy.lock', str(Path(root).resolve()))


def dd_lock(root):
    return ResourceLock(state_root(root) / 'locks' / (worktree_id(root) + '.lock'),
                        str(Path(root).resolve()))


def toolchain():
    developer = os.environ.get('DEVELOPER_DIR')
    if not developer:
        try:
            developer = probe(['/usr/bin/xcode-select', '-p'])
        except (OSError, subprocess.SubprocessError):
            developer = ''
    developer = Path(developer).resolve() if developer else None
    version = None
    if developer:
        try:
            with (developer.parent / 'version.plist').open('rb') as stream:
                version = plistlib.load(stream)
        except (OSError, ValueError, plistlib.InvalidFileException):
            pass
    sdks = []
    if developer:
        for path in sorted({p.resolve() for p in developer.glob('Platforms/*.platform/Developer/SDKs/*.sdk')}):
            settings = path / 'SDKSettings.plist'
            sdks.append({'path': str(path.resolve()), 'settings_sha256':
                         hashlib.sha256(settings.read_bytes()).hexdigest() if settings.is_file() else None})
    return {'developer_dir': str(developer) if developer else None, 'xcode': version, 'sdks': sdks}


def ci_test_scheme(default):
    """Only the explicit synthetic batch uses the common product provenance."""
    if os.environ.get('TODAY_CI_SYNTHETIC') == '1' and os.environ.get('TODAY_CI_NATIVE_BATCH') == '1':
        return 'TodayMock' if os.environ.get('TODAY_CI_UI_ONLY') == '1' else 'TodayCI'
    return default


def native_test_options():
    """Routine synthetic CI needs test results, not IDE indexing or coverage.

    Explicit extended/release collections retain their scheme coverage settings.
    These options are part of build provenance so products cannot cross modes.
    """
    if (os.environ.get('TODAY_CI_SYNTHETIC') == '1'
            and (os.environ.get('TODAY_LANE') in ('integration', 'snapshots', 'core-ui')
                 or (os.environ.get('TODAY_LANE') == 'build'
                     and os.environ.get('TODAY_CI_NATIVE_BATCH') == '1'))):
        # Hosted cold test builds expand XCTest/XCUIAutomation SDK interfaces
        # under explicit scheduling. Measure the supported implicit compiler
        # path with identical sources/tests; keep diagnostics and debug symbols.
        return ['-enableCodeCoverage', 'NO', 'COMPILER_INDEX_STORE_ENABLE=NO',
                'SWIFT_ENABLE_EXPLICIT_MODULES=NO']
    return []


# These directories were already excluded from input identity. Tell Git before
# traversal, rather than walking their generated/dependency trees then filtering.
GENERATED_INPUT_DIRS = ('.build', '__pycache__', 'DerivedData')


def repository_files(root, *, paths=()):
    """Fresh Git inventory; tracked deletions and real untracked inputs survive.

    No cached manifest or untracked-cache extension is trusted. Git prunes ignored
    directories itself; explicit excludes also cover newly generated build trees
    before an enclosing .gitignore exists. --cached still includes tracked paths.
    """
    # Index enumeration never needs a worktree walk. Keep it separate so a slow
    # untracked traversal has an unambiguous operation in the failure evidence.
    names = []
    for mode in ('--cached', '--others'):
        command = ['git', 'ls-files', '-z', mode]
        if mode == '--others':
            command += ['--exclude-standard', '--exclude=/tests/results/', '--exclude=/tests/shots/',
                        *('--exclude=' + name + '/' for name in GENERATED_INPUT_DIRS)]
        command += ['--', *paths] if paths and mode == '--others' else []
        started = time.monotonic()
        try:
            names.extend(probe(command, root).split('\0'))
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
            from .process import Redactor
            detail = Redactor()((error.stderr or b'').decode(errors='replace')
                                if isinstance(error.stderr, bytes) else (error.stderr or ''))
            reason = ('timeout after ' + str(error.timeout) + 's; child killed and reaped'
                      if isinstance(error, subprocess.TimeoutExpired) else 'exit=' + str(error.returncode))
            context = f'; operation={mode}; pid={getattr(error, "pid", "unknown")}; seconds={time.monotonic() - started:.3f}; cwd={Path(root).resolve()}'
            raise RuntimeError(Redactor()('Git source inventory failed: ' + reason + context + '; command=' +
                               ' '.join(command) + '; stderr=' + (detail[:2000] or '<empty>'))) from None
    return sorted({name for name in names if name and not any(
        part in GENERATED_INPUT_DIRS for part in Path(name).parts)})


# Versioned build/test/tool inputs live in these roots. Root configuration names
# are literal pathspecs: a recursive basename glob would walk unrelated caches.
SOURCE_ROOTS = ('ios', 'scripts', 'tests', '.github')
SOURCE_CONFIGS = ('dev', 'Package.resolved', 'package-lock.json', 'yarn.lock',
                  'pnpm-lock.yaml', 'uv.lock', 'requirements.txt', 'Gemfile.lock', 'Gemfile',
                  'mise.lock', '.mise.toml', '.swift-format', '.swiftlint.yml', 'ruff.toml',
                  'tool-pins.json', '.gitignore', '.gitattributes')


def fingerprint(root, *, sdk='iphonesimulator', architecture=None, configuration='Debug', tools=None, scheme='Today'):
    """Hash current source bytes (including dirty/untracked inputs), not just HEAD."""
    root = Path(root).resolve()
    names = repository_files(root, paths=(*SOURCE_ROOTS, *SOURCE_CONFIGS))
    files = {}
    for name in sorted(set(names)):
        if not (name.startswith(tuple(folder + '/' for folder in SOURCE_ROOTS))
                or Path(name).name in SOURCE_CONFIGS):
            continue
        path = root / name
        if path.is_symlink():
            # Include linked content as well as link identity in cache invalidation.
            files[name] = {'link': os.readlink(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        elif path.is_file():
            files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        else:
            files[name] = None  # Tracked deletion invalidates provenance as well.
    if not files:
        raise ValueError('No repository source inputs; provenance rejected')
    if not isinstance(scheme, str) or not scheme.strip():
        raise ValueError('Explicit nonempty scheme required')
    data = {'schema': 2, 'scheme': scheme, 'worktree': str(root), 'source_and_locks': files,
            'toolchain': toolchain() if tools is None else tools, 'sdk': sdk,
            'architecture': architecture or platform.machine(), 'configuration': configuration, 'test_options': native_test_options()}
    return {'sha256': hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest(), 'inputs': data}


def _provenance_path(root, current, kind):
    inputs = current.get('inputs', {})
    if (inputs.get('schema') != 2 or inputs.get('worktree') != str(Path(root).resolve())
            or not inputs.get('scheme') or kind not in ('build', 'build-for-testing')):
        raise ValueError('Scheme-aware fingerprint and supported build kind required')
    digest = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    if current.get('sha256') != digest:
        raise ValueError('Invalid fingerprint digest')
    key = hashlib.sha256((inputs['scheme'] + ':' + kind).encode()).hexdigest()[:20]
    return derived_data(root) / ('dev-provenance-' + key + '.json')


def compiler_module_cache(root, current):
    """Transport only compiler module leaves, never reusable test products.

    Xcode always builds products after a source mismatch. Its implicit compiler
    validates imported modules against the current headers/options. Partition
    transport by the full toolchain/SDK/scheme/options and all non-Swift inputs;
    Package.swift remains a configuration input. Source bytes select the exact
    entry; only Swift edits may fall back to a compatible module-only entry.
    """
    inputs = current['inputs']
    scheme = {'integration': 'TodayTests', 'snapshots': 'TodaySnapshotTests',
              'core-ui': 'TodayMock'}.get(os.environ.get('TODAY_LANE'))
    scheme = ci_test_scheme(scheme)
    if (not scheme or inputs.get('scheme') != scheme
            or inputs.get('configuration') != 'Debug' or inputs.get('sdk') != 'iphonesimulator'
            or inputs.get('architecture') != 'arm64'
            or inputs.get('test_options') != native_test_options() or not native_test_options()):
        return None
    # Validate the canonical source fingerprint before deriving a transport key.
    _provenance_path(root, current, 'build-for-testing')
    partition = dict(inputs)
    partition['source_and_locks'] = {
        k: v for k, v in inputs['source_and_locks'].items()
        if not k.endswith('.swift') or Path(k).name == 'Package.swift'}
    digest = hashlib.sha256(json.dumps(partition, sort_keys=True).encode()).hexdigest()
    prefix = 'today-compiler-modules-v1-' + digest + '-'
    # A linked worktree's DD belongs to the primary checkout. Cache supports
    # absolute paths; do not assume canonical results are inside this worktree.
    path = derived_data(root) / 'ModuleCache.noindex'
    return {'prefix': prefix, 'key': prefix + current['sha256'], 'path': str(path)}


def _product_identity(root, product):
    """Hash complete bundles, resources and signatures; never follow foreign links."""
    owned = derived_data(root).absolute()
    if any(p.is_symlink() for p in (owned, *owned.parents)):
        raise ValueError('Symlink derived-data ancestry is unsafe')
    base = owned.resolve()
    path = Path(product).absolute()
    if not path.resolve().is_relative_to(base) or path.resolve() == base:
        raise ValueError('Build products must belong to this worktree derived-data directory')
    if any(p.is_symlink() for p in (path, *path.parents) if p != base and p.is_relative_to(base)):
        raise ValueError('Symlink build product is unsafe')
    if path.is_file():
        return {'file': hashlib.sha256(path.read_bytes()).hexdigest()}
    if not path.is_dir():
        raise ValueError('Missing build product: ' + str(path))
    files = {}
    for entry in sorted(path.rglob('*')):
        if entry.is_symlink():
            raise ValueError('Symlink in build product: ' + str(entry))
        if entry.is_file():
            files[str(entry.relative_to(path))] = hashlib.sha256(entry.read_bytes()).hexdigest()
    if not files:
        raise ValueError('Empty build product: ' + str(path))
    return {'files': files}


def mock_app_identity(app):
    """Verify the actual Mock executable/module/composition, not its shared bundle ID alone."""
    app = Path(app)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleExecutable') != 'TodayMock' or info.get('CFBundleIdentifier') != 'com.luworks.today':
        raise ValueError('Expected TodayMock executable and bundle identity')
    executable = app / 'TodayMock'
    payload = app / 'TodayMock.debug.dylib'
    payload = payload if payload.exists() else executable
    if executable.is_symlink() or payload.is_symlink():
        raise ValueError('Symlinked Mock binary')
    code = payload.read_bytes()
    if b'TodayMockApp' not in code or b'MockAppComposition' not in code:
        raise ValueError('Missing TodayMockApp module / Mock composition')
    return {'executable': 'TodayMock', 'module': 'TodayMockApp', 'mock_composition_linked': True,
            'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
            'payload_sha256': hashlib.sha256(code).hexdigest()}


def mock_ui_product(root, path, *, normalize=False):
    """Constrain only the known UI target's installation closure; production still builds."""
    path = Path(path)
    data = plistlib.loads(path.read_bytes())
    configs = data.get('TestConfigurations')
    targets = ([target for config in configs for target in config['TestTargets']]
               if configs is not None else [v for k, v in data.items() if not k.startswith('__')])
    ui = [t for t in targets if isinstance(t, dict) and t.get('IsUITestBundle')]
    if not ui:
        return None
    if len(ui) != 1 or ui[0].get('BlueprintName') != 'TodayUITests':
        raise ValueError('Ambiguous UI application target')
    target = ui[0]
    prefix = '__TESTROOT__/'
    value = target.get('UITargetAppPath', '')
    if not value.startswith(prefix) or Path(value).name != 'TodayMock.app':
        raise ValueError('UI target must explicitly select TodayMock.app')
    relative = Path(value[len(prefix):])
    if len(relative.parts) != 2 or relative.parts[0] not in ('Debug-iphonesimulator', 'Release-iphonesimulator'):
        raise ValueError('Unexpected Mock product path')
    app = derived_data(root) / 'Build/Products' / relative
    if app.is_symlink():
        raise ValueError('Symlinked Mock application')
    configuration = relative.parts[0].split('-')[0]
    config = Path(root) / ('ios/Config/TodayMock-' + configuration + '.xcconfig')
    config_bytes = config.read_bytes()
    if not re.search(rb'^SWIFT_ACTIVE_COMPILATION_CONDITIONS\s*=.*\bTODAY_MOCK\b', config_bytes, re.M):
        raise ValueError('Missing TODAY_MOCK compilation condition')
    if not re.search(rb'^PRODUCT_MODULE_NAME\s*=\s*TodayMockApp\s*$', config_bytes, re.M):
        raise ValueError('Unexpected Mock product module')
    expected_host = str(Path(value).parent / 'OneUITests-Runner.app')
    if target.get('TestHostPath') != expected_host:
        raise ValueError('Unexpected UI test runner host')
    products = derived_data(root) / 'Build/Products'

    def product_path(dependency):
        if not isinstance(dependency, str) or not dependency:
            raise ValueError('Malformed UI dependency path')
        expanded = dependency.replace('__TESTROOT__', str(products)).replace(
            '__TESTHOST__', str(products / Path(expected_host[len(prefix):])))
        if re.search(r'__[A-Z][A-Z0-9_]*__', expanded) or not Path(expanded).is_absolute():
            raise ValueError('Unresolved UI dependency path')
        resolved = Path(expanded).resolve()
        if not resolved.is_relative_to(products.resolve()) or resolved == products.resolve():
            raise ValueError('Foreign UI dependency path')
        # Canonical spelling does not authorize symlinked or missing products.
        _product_identity(root, Path(expanded))
        return resolved

    live = str(Path(value).parent / 'One.app')
    dependencies = target.get('DependentProductPaths', [])
    if not isinstance(dependencies, list):
        raise ValueError('Malformed UI dependencies')
    allowed_apps = {product_path(value), product_path(expected_host)}
    # TodayCI repeats the aggregate installation closure in every test target.
    # Admit the isolated host only when a known native target declares it.
    native_host = str(Path(value).parent / 'TodayTestHost.app')
    for native in targets:
        if (native.get('BlueprintName') in ('TodayTests', 'TodaySnapshotTests')
                and not native.get('IsUITestBundle') and native.get('TestHostPath') == native_host):
            host = product_path(native_host)
            info = plistlib.loads((host / 'Info.plist').read_bytes())
            if (info.get('CFBundleExecutable') != 'TodayTestHost'
                    or info.get('CFBundleIdentifier') != 'com.luworks.today.development.todaytesthost'):
                raise ValueError('Unexpected native test host identity')
            allowed_apps.add(host)
    live_path = (products / Path(live[len(prefix):])).resolve()
    selected = []
    for dependency in dependencies:
        resolved = product_path(dependency)
        if resolved == live_path and normalize:
            continue
        if resolved.suffix == '.app' and resolved not in allowed_apps:
            raise ValueError('Ambiguous Live/UI installation dependency')
        canonical = prefix + str(resolved.relative_to(products.resolve()))
        if canonical not in selected:
            selected.append(canonical)
    identity = mock_app_identity(app)
    if normalize and selected != dependencies:
        target['DependentProductPaths'] = selected
        temporary = path.with_suffix('.normalizing')
        temporary.write_bytes(plistlib.dumps(data))
        temporary.replace(path)
    return {'app': str(app), 'identity': identity, 'test_host': expected_host,
            'ui_target_app': value, 'compilation_condition': 'TODAY_MOCK',
            'configuration_sha256': hashlib.sha256(config_bytes).hexdigest()}


def xctestrun_products(root, path, *, identities=None):
    """Resolve both Xcode plist formats into exact local test/host product roots."""
    path = Path(path).absolute()
    products = (derived_data(root) / 'Build/Products').resolve()
    if path.suffix != '.xctestrun' or path.parent.resolve() != products:
        raise ValueError('xctestrun must belong to this worktree Build/Products')
    # Share byte reads only inside this synchronous validation. Every later
    # dispatch starts with an empty map and rehashes the live products.
    identities = {} if identities is None else identities

    def inspect(product):
        key = str(Path(product).absolute())
        if key not in identities:
            identities[key] = _product_identity(root, product)

    inspect(path)
    with path.open('rb') as stream:
        data = plistlib.load(stream)
    if not isinstance(data, dict):
        raise ValueError('Malformed xctestrun')
    if 'TestConfigurations' in data:
        configs = data['TestConfigurations']
        if not isinstance(configs, list) or not configs:
            raise ValueError('Missing test configurations')
        targets = []
        for config in configs:
            if not isinstance(config, dict) or not isinstance(config.get('TestTargets'), list):
                raise ValueError('Malformed test targets')
            targets.extend(config['TestTargets'])
    else:
        targets = [value for key, value in data.items() if not key.startswith('__')]
    if not targets:
        raise ValueError('Missing xctestrun targets')
    found = {str(path)}

    def resolve(value, host=None):
        if not isinstance(value, str) or not value:
            raise ValueError('Missing xctestrun product path')
        value = value.replace('__TESTROOT__', str(products))
        if host is not None:
            value = value.replace('__TESTHOST__', str(host))
        if re.search(r'__[A-Z][A-Z0-9_]*__', value) or not Path(value).is_absolute():
            raise ValueError('Unresolved xctestrun product path: ' + value)
        resolved = Path(value).resolve()
        if not resolved.is_relative_to(products):
            raise ValueError('Foreign xctestrun product: ' + value)
        inspect(Path(value))
        found.add(str(Path(value).absolute()))
        return resolved

    mock_ui_product(root, path)
    for target in targets:
        if not isinstance(target, dict):
            raise ValueError('Malformed xctestrun target')
        host = resolve(target['TestHostPath']) if target.get('TestHostPath') else None
        resolve(target.get('TestBundlePath'), host)
        if target.get('UITargetAppPath'):
            resolve(target['UITargetAppPath'], host)
        dependencies = target.get('DependentProductPaths', [])
        if not isinstance(dependencies, list):
            raise ValueError('Malformed dependent products')
        for dependency in dependencies:
            resolve(dependency, host)
    return sorted(found)


def record_build(root, current, products, *, returncode, kind='build', xctestrun=None):
    """Record only a completed successful build while the caller holds dd_lock.

    Pass whole app directories for ordinary builds, and the actual xctestrun for
    build-for-testing. The latter discovers and hashes every referenced product.
    """
    destination = _provenance_path(root, current, kind)
    if returncode != 0 or not products:
        raise ValueError('Successful build and explicit products required')
    inputs = current['inputs']
    if fingerprint(root, scheme=inputs['scheme'], sdk=inputs['sdk'], architecture=inputs['architecture'],
                   configuration=inputs['configuration'], tools=inputs['toolchain']) != current:
        raise ValueError('Source changed before provenance publication')
    products = list(products)
    artifacts = {}
    if kind == 'build-for-testing':
        if xctestrun is None or not Path(xctestrun).name.startswith(current['inputs']['scheme'] + '_'):
            raise ValueError('Exact scheme xctestrun required')
        products.extend(xctestrun_products(root, xctestrun, identities=artifacts))
    elif xctestrun is not None:
        raise ValueError('xctestrun requires build-for-testing provenance')
    for product in products:
        key = str(Path(product).absolute())
        if key not in artifacts:
            artifacts[key] = _product_identity(root, product)
    atomic_json(destination, {'schema': 2, 'kind': kind, 'worktree': str(Path(root).resolve()),
                             'fingerprint': current, 'products': artifacts,
                             'xctestrun': str(Path(xctestrun).absolute()) if xctestrun else None})


def provenance(root, current, *, kind='build', xctestrun=None):
    """Invalid, legacy, missing or unreadable provenance always means no reuse."""
    try:
        stored = read_json(_provenance_path(root, current, kind))
        if not stored:
            return {'valid': False, 'reason': 'missing provenance'}
        if (stored.get('schema') != 2 or stored.get('kind') != kind
                or stored.get('worktree') != str(Path(root).resolve()) or stored.get('fingerprint') != current):
            return {'valid': False, 'reason': 'stale source, toolchain, scheme, options or worktree'}
        products = stored.get('products', {})
        if not isinstance(products, dict) or not products:
            raise ValueError('Missing products')
        identities = {}
        if kind == 'build-for-testing':
            actual = stored.get('xctestrun')
            if not actual or (xctestrun is not None and str(Path(xctestrun).absolute()) != actual):
                raise ValueError('xctestrun identity mismatch')
            if not Path(actual).name.startswith(current['inputs']['scheme'] + '_'):
                raise ValueError('xctestrun scheme mismatch')
            if set(xctestrun_products(root, actual, identities=identities)) - set(products):
                raise ValueError('Unrecorded xctestrun products')
        for name, digest in products.items():
            actual_digest = identities[name] if name in identities else _product_identity(root, name)
            if actual_digest != digest:
                raise ValueError('Missing or modified product')
        return {'valid': True, 'reason': 'fingerprint and products match', 'xctestrun': stored.get('xctestrun')}
    except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException) as error:
        return {'valid': False, 'reason': str(error)}


class NativeBuildError(RuntimeError):
    def __init__(self, result):
        self.returncode = result.returncode
        super().__init__('Native build failed; exit=' + str(result.returncode) + '; log=' + str(result.log))


def ensure_test_products(root, scheme, invoke, *, configuration='Debug', sdk='iphonesimulator',
                         architecture='arm64', flags=()):
    """Caller owns host/DD locks; invoke returns an authoritative ProcessResult.

    No test command is executed here. A cache miss rebuilds once; a failed,
    cancelled or changing-source build never publishes reusable provenance.
    """
    options = dict(scheme=scheme, configuration=configuration, sdk=sdk, architecture=architecture)
    current = fingerprint(root, **options)
    cached = provenance(root, current, kind='build-for-testing')
    if cached['valid']:
        return Path(cached['xctestrun'])
    result = invoke(['xcodebuild', 'build-for-testing', '-project', 'ios/Today.xcodeproj',
                     '-scheme', scheme, '-configuration', configuration, '-sdk', sdk,
                     '-destination', 'generic/platform=iOS Simulator',
                     '-derivedDataPath', str(derived_data(root)), '-jobs', '2',
                     'ARCHS=' + architecture, *native_test_options(), '-showBuildTimingSummary', *flags])
    if result.returncode:
        raise NativeBuildError(result)
    if getattr(result, 'reason', 'exited') != 'exited':
        raise ValueError('Interrupted build cannot publish provenance')
    # record_build freshly validates source/options before publication. Avoid a
    # duplicate Git walk here while still rejecting a changed live toolchain.
    if toolchain() != current['inputs']['toolchain']:
        raise ValueError('Toolchain changed during build; provenance rejected')
    candidates = [p for p in (derived_data(root) / 'Build/Products').glob('*.xctestrun')
                  if p.name.startswith(scheme + '_')]
    if len(candidates) != 1:
        raise ValueError('Expected exactly one scheme xctestrun; rebuild in a fresh owned cache')
    path = candidates[0]
    mock_ui_product(root, path, normalize=True)
    record_build(root, current, [path], returncode=0, kind='build-for-testing', xctestrun=path)
    # record_build just rehashed live source before publishing. Reuse that
    # identity for product validation; the caller checks again before dispatch.
    if not provenance(root, current, kind='build-for-testing', xctestrun=path)['valid']:
        raise ValueError('Build products changed before test dispatch')
    return path
