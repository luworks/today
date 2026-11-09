"""Checksummed, worktree-local tool installation; no CLI or global configuration.

``bootstrap(root, plan=True)`` is read-only. Consumers use returned executable
paths, including the original Xcode-bundled formatter (never a tag substitute).
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import struct
import tarfile
import tempfile
import time
import zipfile

from .core import ResourceLock, atomic_json, read_json, toolchain
from .process import Evidence, Redactor, run_process

TOOLS = ('xcodegen', 'swiftlint', 'mise', 'ruff', 'actionlint', 'swift-format')


class BootstrapError(RuntimeError):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def _contained(path, root):
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise BootstrapError(f'Unsafe path: {path}')
    # Refuse even links which point back inside the root.
    for parent in (path, *path.parents):
        if parent == root.parent:
            break
        if parent.is_symlink():
            raise BootstrapError(f'Symlink path: {parent}')
    return path


def _member(name, root):
    pure = PurePosixPath(name)
    if (not name or '\\' in name or pure.is_absolute() or '..' in pure.parts
            or not pure.parts or ':' in pure.parts[0]):
        raise BootstrapError(f'Unsafe archive member: {name}')
    return _contained(root.joinpath(*pure.parts), root)


def _extract(archive, destination, check):
    """Validate every member before writing; never use extract/extractall."""
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as source:
            members = []
            for item in source.infolist():
                target = _member(item.filename, destination)
                mode = item.external_attr >> 16
                if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                    raise BootstrapError(f'Unsupported ZIP member: {item.filename}')
                members.append((item, target, item.is_dir(), mode))
            _write_members(members, source.open, check)
    else:
        with tarfile.open(archive, 'r:*') as source:
            members = []
            for item in source.getmembers():
                target = _member(item.name, destination)
                if not (item.isfile() or item.isdir()):
                    raise BootstrapError(f'Unsupported tar member: {item.name}')
                members.append((item, target, item.isdir(), item.mode))
            _write_members(members, source.extractfile, check)


def _write_members(members, opener, check):
    seen = set()
    for item, target, directory, mode in members:
        check()
        if target in seen:
            raise BootstrapError(f'Duplicate archive member: {target}')
        seen.add(target)
        if directory:
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with opener(item) as src, target.open('xb') as dst:
                while block := src.read(1024 * 1024):
                    check()
                    dst.write(block)
            target.chmod(0o755 if mode & 0o111 else 0o644)


def _arm64(path):
    """Check Mach-O CPU headers before ever executing downloaded code."""
    with Path(path).open('rb') as stream:
        data = stream.read(8)
        if len(data) != 8:
            return False
        magic = data[:4]
        if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf'):
            endian = '<' if magic[0] == 0xcf else '>'
            return struct.unpack(endian + 'I', data[4:8])[0] == 0x0100000c
        if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf',
                     b'\xbe\xba\xfe\xca', b'\xbf\xba\xfe\xca'):
            endian = '>' if magic[0] == 0xca else '<'
            count = struct.unpack(endian + 'I', data[4:8])[0]
            width = 32 if magic in (b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca') else 20
            if not 0 < count <= 64:
                return False
            headers = stream.read(count * width)
            return len(headers) == count * width and any(
                struct.unpack_from(endian + 'I', headers, i * width)[0] == 0x0100000c
                for i in range(count))
    return False


def _files(root):
    result = {}
    for path in sorted(root.rglob('*')):
        _contained(path, root)
        if path.name == 'receipt.json' and path.parent == root:
            continue
        if path.is_file():
            result[str(path.relative_to(root))] = {'sha256': sha256(path),
                                                  'mode': stat.S_IMODE(path.stat().st_mode)}
        elif not path.is_dir():
            raise BootstrapError(f'Unsupported installed path: {path}')
    return result


def _ready(destination, pin):
    _contained(destination, destination.parent.parent)
    _contained(destination / 'receipt.json', destination.parent.parent)
    receipt = read_json(destination / 'receipt.json')
    if not receipt or receipt.get('pin') != pin:
        return None
    try:
        executable = _member(receipt['executable'], destination)
        if (_files(destination) != receipt['files'] or not executable.is_file()
                or not os.access(executable, os.X_OK) or not _arm64(executable)):
            return None
    except (OSError, KeyError, BootstrapError):
        return None
    return executable


def bootstrap(root, *, tools=None, plan=False, timeout=120, cancel=None,
              developer_dir=None, session='devtools-bootstrap'):
    """Install selected pinned tools or return a read-only plan.

    Existing mismatched installations fail closed; remove/repair is an explicit
    caller action. Each tool is atomic, not the whole multi-tool transaction.
    ``timeout`` bounds each tool, including its curl process and extraction.
    ``cancel`` may be a threading.Event. Only macOS arm64 execution is supported.
    """
    root = Path(root).resolve(strict=True)
    manifest = json.loads((root / 'docs/engineering/tool-pins.json').read_text())
    if manifest.get('schema_version') != 1 or timeout <= 0:
        raise BootstrapError('Unsupported manifest or nonpositive timeout')
    selected = list(TOOLS if tools is None else tools)
    if len(set(selected)) != len(selected) or any(t not in TOOLS for t in selected):
        raise BootstrapError('Unknown or duplicate tool selection')
    base = _contained(root / '.dev-tools', root)
    entries = []
    for name in selected:
        entry = manifest['tools'].get(name)
        if not isinstance(entry, dict):
            raise BootstrapError(f'Missing tool pin: {name}')
        if name == 'swift-format':
            pin = entry.get('preferred_pin', {})
            if pin.get('kind') != 'xcode-bundled' or pin.get('xcode_build') != '27B52':
                raise BootstrapError('Exact Xcode 27B52 formatter required')
            entries.append({'tool': name, 'kind': 'xcode-bundled', 'xcode_build': '27B52',
                            'upstream_tag_mapping': 'unverified'})
            continue
        artifact = entry.get('artifact', {})
        version = entry.get('version', '')
        if (not re.fullmatch(r'[A-Za-z0-9._-]+', version) or version in ('.', '..')
                or not re.fullmatch(r'[a-f0-9]{64}', artifact.get('sha256', ''))
                or not artifact.get('url', '').startswith('https://github.com/')):
            raise BootstrapError(f'Missing exact release pin: {name}')
        destination = _contained(base / name / version, root)
        pin = {'version': version, 'url': artifact['url'], 'sha256': artifact['sha256']}
        ready = _ready(destination, pin)
        entries.append({'tool': name, 'pin': pin, 'destination': str(destination),
                        'status': 'ready' if ready else 'conflict' if destination.exists() else 'missing',
                        'executable': str(ready) if ready else None})
    if plan:
        return {'plan': True, 'tools': entries}
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise BootstrapError('Bootstrap requires macOS arm64')
    base.mkdir(exist_ok=True)
    with ResourceLock(_contained(base / 'bootstrap.lock', root), str(root)):
        for item in entries:
            started = time.monotonic()
            def check():
                if cancel is not None and cancel.is_set():
                    raise BootstrapError('Bootstrap cancelled')
                if time.monotonic() - started >= timeout:
                    raise BootstrapError('Bootstrap timeout')
            def run(argv):
                check()
                evidence = Evidence(root, session, Redactor())
                try:
                    result = run_process(argv, cwd=root, evidence=evidence,
                                         timeout=max(0.001, timeout - (time.monotonic() - started)),
                                         cancel=cancel)
                    if result.returncode:
                        raise BootstrapError(f'{item["tool"]}: {result.reason}; exit={result.returncode}; log={result.log}')
                    return result.log.read_text().strip()
                finally:
                    evidence.close()
            check()
            if item['tool'] == 'swift-format':
                chain = toolchain()
                developer = Path(developer_dir or chain['developer_dir'] or '')
                import plistlib
                with (developer.parent / 'version.plist').open('rb') as stream:
                    version = plistlib.load(stream)
                if version.get('ProductBuildVersion') != item['xcode_build']:
                    raise BootstrapError('swift-format requires Xcode build 27B52')
                executable = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-format'
                if not executable.is_file() or not os.access(executable, os.X_OK):
                    raise BootstrapError('Missing Xcode-bundled swift-format')
                item.update(executable=str(executable.resolve()), sha256=sha256(executable),
                            version_output=run([str(executable), '--version']))
                atomic_json(base / 'swift-format.json', item)
                continue
            destination, pin = Path(item['destination']), item['pin']
            ready = _ready(destination, pin)
            if ready:
                item.update(status='ready', executable=str(ready))
                continue
            if destination.exists():
                raise BootstrapError(f'Installation conflict: {destination}')
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix='.bootstrap-', dir=base) as temporary:
                temporary = Path(temporary)
                archive, stage = temporary / 'download', temporary / 'install'
                stage.mkdir()
                run(['/usr/bin/curl', '--fail', '--location', '--silent', '--show-error',
                     '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', '15',
                     '--max-time', str(timeout), '--output', str(archive), pin['url']])
                check()
                if sha256(archive) != pin['sha256']:
                    raise BootstrapError(f'Checksum mismatch: {item["tool"]}')
                payload = stage / 'payload'
                payload.mkdir()
                _extract(archive, payload, check)
                candidates = [p for p in payload.rglob(item['tool']) if p.is_file()]
                if len(candidates) != 1 or not _arm64(candidates[0]):
                    raise BootstrapError(f'Missing or ambiguous arm64 executable: {item["tool"]}')
                executable = candidates[0]
                # Keep the original resource layout, and provide a stable regular-file bin.
                shutil.copytree(executable.parent, stage / 'bin')
                (stage / 'bin' / item['tool']).chmod(0o755)
                receipt = {'pin': pin, 'executable': 'bin/' + item['tool'], 'files': _files(stage)}
                atomic_json(stage / 'receipt.json', receipt)
                check()
                stage.rename(destination)
                item.update(status='installed', executable=str(destination / receipt['executable']))
    return {'plan': False, 'tools': entries}
