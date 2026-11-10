"""Bound generated QA storage without touching active writers or application data."""
from contextlib import ExitStack, contextmanager
import fcntl
import fnmatch
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import tempfile
import time
import uuid
from urllib.parse import urlsplit

from scripts.devtools.core import (atomic_json, canonical_root,
                                   inspect_lock, probe, worktree_id)
from journal import Journal, digest

CACHE_PARTS = ('Build/Intermediates.noindex', 'Build/Products', 'Logs', 'TestResults',
               'SourcePackages', 'ReleaseMaps', 'CompilationCache.noindex', 'Index.noindex',
               'ModuleCache.noindex', 'SDKExplicitPrecompiledModules', 'SDKStatCaches.noindex')
CLOSED = ('passed', 'failed', 'interrupted')


def contained(base, path):
    """Reject symlink components, traversal, and even an aliased results root."""
    base, path = Path(base).absolute(), Path(path).absolute()
    if '..' in path.parts or path == base or base not in path.parents:
        raise ValueError('Path is outside the allowlisted root: ' + str(path))
    for parent in (base, *reversed(path.relative_to(base).parents), path.relative_to(base)):
        item = parent if parent.is_absolute() else base / parent
        if item.is_symlink():
            raise ValueError('Symlink is protected: ' + str(item))
    if base.resolve() != base or path.resolve() != path:
        raise ValueError('Noncanonical storage path: ' + str(path))
    return path


def tree(path, hashes=False):
    """Inventory generated files and links without following a link outside the tree."""
    path = Path(path)
    files = []
    if path.is_dir():
        st = path.lstat()
        files.append({'path': '.', 'kind': 'directory', 'bytes': 0, 'allocated': 0,
                      'mtime_ns': st.st_mtime_ns, 'ctime_ns': st.st_ctime_ns,
                      'device': st.st_dev, 'inode': st.st_ino})
    groups = [(path.parent, [], [path.name])] if path.is_file() else os.walk(path, followlinks=False)
    for base, dirs, names in groups:
        for name in sorted(dirs + names):
            item = Path(base) / name
            st = item.lstat()
            if not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)):
                raise ValueError('Special file is protected: ' + str(item))
            entry = {'path': '.' if item == path else str(item.relative_to(path)),
                     'kind': 'directory' if stat.S_ISDIR(st.st_mode) else 'symlink' if stat.S_ISLNK(st.st_mode) else 'file',
                     'bytes': 0 if stat.S_ISDIR(st.st_mode) else st.st_size,
                     'allocated': 0 if stat.S_ISDIR(st.st_mode) else st.st_blocks * 512,
                     'mtime_ns': st.st_mtime_ns, 'ctime_ns': st.st_ctime_ns,
                     'device': st.st_dev, 'inode': st.st_ino}
            if entry['kind'] == 'symlink':
                entry['target'] = os.readlink(item)
            elif hashes and entry['kind'] == 'file':
                entry['sha256'] = digest(item)
                after = item.lstat()
                if (after.st_mtime_ns, after.st_ctime_ns, after.st_ino) != (
                        st.st_mtime_ns, st.st_ctime_ns, st.st_ino):
                    raise ValueError('File changed while hashing: ' + str(item))
            files.append(entry)
    return sorted(files, key=lambda x: x['path'])


def policy(root):
    value = json.loads((Path(root) / 'tests/qa/retention.json').read_text())
    if value.get('schema') != 2 or not isinstance(value.get('pins'), list):
        raise ValueError('Missing retention policy/pins')
    for key in ('passed_days', 'failed_days', 'cache_days'):
        if type(value[key]) is not int or value[key] < 1:
            raise ValueError('Retention days must be positive integers')
    if type(value.get('max_generated_bytes')) is not int or value['max_generated_bytes'] < 1:
        raise ValueError('Generated storage budget must be a positive integer')
    return value


def references(root):
    """Current tracked text plus all open Issue/PR bodies/comments; failure closes apply."""
    documents = []
    names = probe(['git', 'ls-files', '--', '*.md', '*.json'], cwd=root).splitlines()
    for name in names:
        path = Path(root) / name
        if path.is_file() and not path.is_symlink():
            documents.append(path.read_text(errors='replace'))
    for kind in ('issues', 'pulls'):
        data = json.loads(probe(['gh', 'api', '--paginate', '--slurp',
                                 f'repos/luworks/today/{kind}?state=open&per_page=100'], cwd=root, timeout=30))
        for page in data:
            for item in page:
                documents.append(item.get('body') or '')
                number = item['number']
                comments = probe(['gh', 'api', '--paginate', '--slurp',
                                  f'repos/luworks/today/issues/{number}/comments?per_page=100'],
                                 cwd=root, timeout=30)
                documents.append(comments)
                if kind == 'pulls':
                    documents.append(probe(['gh', 'api', '--paginate', '--slurp',
                                            f'repos/luworks/today/pulls/{number}/comments?per_page=100'],
                                           cwd=root, timeout=30))
                    documents.append(probe(['gh', 'api', '--paginate', '--slurp',
                                            f'repos/luworks/today/pulls/{number}/reviews?per_page=100'],
                                           cwd=root, timeout=30))
    return '\n'.join(documents)


@lru_cache(maxsize=2)
def reference_index(refs):
    # Index reference tokens once; avoid searching megabytes of Issue text for
    # every file in a compiler cache. Ancestors retain any cited descendant.
    tokens = set(re.findall(r'[A-Za-z0-9_.~/-]+', refs))
    prefixes = set(tokens)
    for token in tokens:
        if '/' in token:
            prefixes.update(str(p) for p in Path(token).parents)
    return tokens, prefixes


def protected(results, path, config, refs):
    rel = str(path.relative_to(results))
    # Generic evidence-name pins apply to candidate/ancestor names, not SDK/header
    # descendants such as iphonesimulator, CMHeadphone or NSAutoreleasePool.h.
    ancestors = [rel, *Path(rel).parts, *[str(p) for p in Path(rel).parents if str(p) != '.']]
    for pin in config['pins']:
        names = ancestors
        if '/' in pin:
            names = [rel] + [str(p.relative_to(results)) for p in path.rglob('*')] if path.is_dir() else [rel]
        if any(fnmatch.fnmatch(name, pin) or fnmatch.fnmatch(name + '/', pin) for name in names):
            return 'pinned'
    tokens, prefixes = reference_index(refs)
    if rel.startswith('devtools/derived-data/'):
        identity = path.relative_to(results).parts[2]
        # Root-only references protect all children. A Products-only reference
        # protects that sibling tree without making compiler caches evidence.
        if any(t.rstrip('/').split('/')[-1] == identity for t in tokens):
            return 'referenced'
    elif path.name in tokens:
        return 'referenced'
    return 'referenced' if str(path) in prefixes or rel in prefixes else None


def retired(root, results, identity, owned=False):
    lock = results / 'devtools/locks' / (identity + '.lock')
    contained(results, lock)
    status = inspect_lock(lock)
    metadata = status['metadata']
    if status['held'] and not owned:
        return False
    return owner_retired(root, metadata, identity)


def owner_retired(root, metadata, identity):
    """A surviving workspace may own queued/nonterminal work without a process."""
    if not metadata or not isinstance(metadata.get('owner'), str):
        return False
    owner = Path(metadata['owner'])
    # Resolve today's alias, but also accept the historical lexical owner hash
    # recorded before one-app became today. A surviving/registered worktree may
    # belong to a queued or awaiting-owner task even with no process today.
    lexical = hashlib.sha256(os.fsencode(owner.absolute())).hexdigest()[:20]
    if not owner.is_absolute() or '..' in owner.parts or identity not in (worktree_id(owner), lexical):
        return False
    alternatives = {owner, owner.resolve()}
    for old, new in (('one-app', 'today'), ('today', 'one-app')):
        alternatives.add(Path(*[new if part == old else part for part in owner.parts]))
    if any(path.exists() for path in alternatives):
        return False
    registered = probe(['git', 'worktree', 'list', '--porcelain'], cwd=root)
    resolved = {path.resolve() for path in alternatives}
    if any(Path(line.removeprefix('worktree ')).resolve() in resolved
           for line in registered.splitlines() if line.startswith('worktree ')):
        return False
    # A recycled PID can only cause conservative retention, never deletion.
    pid = metadata.get('pid')
    if type(pid) is not int or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def run_owner_reason(root, results, cache):
    if not isinstance(cache, str):
        return 'unknown-run-owner'
    path = Path(cache)
    identity = path.name
    if (not re.fullmatch('[0-9a-f]{20}', identity) or path.resolve() !=
            (results / 'devtools/derived-data' / identity).resolve()):
        return 'unknown-run-owner'
    return None if retired(root, results, identity) else 'active-or-unknown-owner'


def command_owners(results):
    """Reuse existing journal ownership; old ownerless command logs stay unknown."""
    with sqlite3.connect('file:' + str(results / 'activity.sqlite') + '?mode=ro', uri=True) as db:
        sessions = {path: session for path, session in db.execute(
            "SELECT c.after_txt,e.session FROM event e JOIN content c ON c.event_uid=e.uid WHERE e.kind='qa.artifact' ORDER BY e.id")}
        owners = {session: json.loads(props) for session, props in db.execute(
            "SELECT session,props FROM event WHERE kind='qa.command.devtools' ORDER BY id")}
    return {path: owners.get(session) for path, session in sessions.items()}


def command_owner_reason(root, results, path, owners=None):
    try:
        owners = command_owners(results) if owners is None else owners
        metadata = owners.get(str(path))
        if not metadata or metadata.get('status') not in CLOSED:
            return 'unknown-or-live-command'
        if not owner_retired(root, metadata, metadata.get('worktree_id')):
            return 'active-or-unknown-owner'
    except (OSError, ValueError, TypeError, sqlite3.Error):
        return 'unknown-command-owner'
    return None


def source_packages_reason(root, path, remote_cache=None):
    """Only controlled Package.resolved URLs/revisions authorize remote proof."""
    remote_cache = {} if remote_cache is None else remote_cache
    try:
        def normalized(url):
            parsed = urlsplit(url)
            if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
                    or parsed.query or parsed.fragment):
                raise ValueError('Untrusted dependency URL')
            return url.rstrip('/').removesuffix('.git')

        pins = json.loads((Path(root) / 'ios/Dependencies/Package.resolved').read_text())['pins']
        trusted = {normalized(pin['location']): pin for pin in pins if pin.get('kind') == 'remoteSourceControl'}
        state = json.loads((path / 'workspace-state.json').read_text())
        dependencies = [item for item in state['object']['dependencies']
                        if 'checkoutState' in item.get('state', {})]
        expected = {}
        urls = {}
        for item in dependencies:
            key = normalized(item['packageRef']['location'])
            pin = trusted.get(key)
            revision = item['state']['checkoutState']['revision']
            if not pin or pin['state']['revision'] != revision:
                return 'unmapped-source-revision'
            expected[item['subpath']] = revision
            urls[item['subpath']] = pin['location']
        if not expected:
            return 'unknown-source'

        def reproducible(repo, url=None, revision=None):
            common = Path(probe(['git', '-C', str(repo), 'rev-parse', '--git-common-dir']))
            if not common.is_absolute():
                common = repo / common
            if not common.resolve().is_relative_to(path.resolve()):
                return 'shared-source-git'
            linked = probe(['git', '-C', str(repo), 'worktree', 'list', '--porcelain'])
            if any(not Path(line.removeprefix('worktree ')).resolve().is_relative_to(path.resolve())
                   for line in linked.splitlines() if line.startswith('worktree ')):
                return 'shared-source-git'
            if url is None:
                origin = probe(['git', '-C', str(repo), 'config', '--get', 'remote.origin.url'])
                pin = trusted.get(normalized(origin))
                if not pin:
                    return 'unmapped-source-remote'
                url = pin['location']
            if url not in remote_cache:
                # probe always sets GIT_OPTIONAL_LOCKS=0. No cache-origin URL is
                # executed, and no fetch/index refresh changes the candidate.
                rows = probe(['git', 'ls-remote', '--refs', url], timeout=5).splitlines()
                remote_cache[url] = {name: sha for sha, name in (line.split() for line in rows)}
            remote_refs = remote_cache[url]
            for line in probe(['git', '-C', str(repo), 'for-each-ref', '--format=%(objectname) %(refname) %(symref)']).splitlines():
                fields = line.split()
                if len(fields) == 3:
                    continue  # A symbolic origin/HEAD is not unique source.
                sha, name = fields
                if name.startswith('refs/remotes/origin/'):
                    name = 'refs/heads/' + name.removeprefix('refs/remotes/origin/')
                if remote_refs.get(name) != sha:
                    return 'local-source-refs'
            head = probe(['git', '-C', str(repo), 'rev-parse', 'HEAD'])
            if head != revision and head not in expected.values() and head not in remote_refs.values():
                return 'unmapped-source-revision'
            return None

        checkouts = path / 'checkouts'
        if checkouts.is_symlink():
            return 'unmapped-source'
        for checkout in checkouts.iterdir():
            if checkout.is_symlink() or checkout.name not in expected:
                return 'unmapped-source'
            if probe(['git', '-C', str(checkout), 'status', '--porcelain', '--untracked-files=all']):
                return 'modified-source'
            if probe(['git', '-C', str(checkout), 'rev-parse', 'HEAD']) != expected[checkout.name]:
                return 'unmapped-source-revision'
            reason = reproducible(checkout, urls[checkout.name], expected[checkout.name])
            if reason:
                return reason
        repositories = path / 'repositories'
        if repositories.is_symlink():
            return 'unmapped-source-mirror'
        if repositories.exists():
            for repo in repositories.iterdir():
                if repo.is_symlink() or not repo.is_dir():
                    return 'unmapped-source-mirror'
                reason = reproducible(repo)
                if reason:
                    return reason
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return 'unknown-source'
    return None


def budget(items, config):
    """Evict oldest closed/idle generated copies first; never override safety or pins."""
    remaining = sum(f['allocated'] for item in items for f in item['files'])
    for item in sorted(items, key=lambda x: (x['newest'], x['path'])):
        if not item['reason']:
            remaining -= sum(f['allocated'] for f in item['files'])
    for item in sorted(items, key=lambda x: (x['newest'], x['path'])):
        if remaining <= config['max_generated_bytes']:
            break
        if item['reason'] == 'young':
            item['reason'] = None
            item['budget_eviction'] = True
            remaining -= sum(f['allocated'] for f in item['files'])
    return items


def candidates(root, config, refs='', now=None, owned_identity=None, remote_cache=None):
    now = time.time() if now is None else now
    results = canonical_root(root) / 'tests/results'
    if results.resolve() != results or results.is_symlink():
        raise ValueError('Results root must be canonical and not a symlink')
    controls_safe(results)
    items = []

    def add(path, kind, days, *, identity=None, simulator_name=None, reason=None, owner_mtime=0):
        try:
            path = contained(results, path)
            files = tree(path)
            if not any(entry['kind'] != 'directory' for entry in files):
                return
            newest = max([path.lstat().st_mtime, owner_mtime] + [f['mtime_ns'] / 1e9 for f in files])
            reason = reason or protected(results, path, config, refs)
            if newest > now - days * 86400:
                reason = reason or 'young'
            items.append({'path': str(path), 'kind': kind, 'identity': identity,
                          'simulator_name': simulator_name, 'reason': reason,
                          'newest': newest, 'files': files})
        except (OSError, ValueError):
            return

    cache = results / 'devtools/derived-data'
    if cache.exists():
        contained(results, cache)
        for directory in sorted(cache.iterdir()):
            if not re.fullmatch('[0-9a-f]{20}', directory.name):
                continue
            contained(results, directory)
            idle = retired(root, results, directory.name, owned=directory.name == owned_identity)
            # Report active/unknown ownership without walking a live build tree.
            if not idle:
                items.append({'path': str(directory), 'kind': 'cache', 'identity': directory.name,
                              'reason': 'active-or-unknown-owner', 'newest': now, 'files': [],
                              'unmeasured_active': True})
                continue
            lock = results / 'devtools/locks' / (directory.name + '.lock')
            for part in CACHE_PARTS:
                path = directory / part
                if path.is_dir():
                    add(path, 'cache', config['cache_days'], identity=directory.name, owner_mtime=lock.stat().st_mtime)

    # A closed run expires even when it is the latest lane or has no duplicate
    # archive. The live lifecycle, cache/name locks and open files still protect it.
    summaries = list((results / 'runs').glob('*/summary-retained.json'))
    summaries += list(results.glob('*/summary-retained.json'))
    if summaries:
        try:
            with sqlite3.connect('file:' + str(results / 'activity.sqlite') + '?mode=ro', uri=True) as db:
                for summary in summaries:
                    try:
                        contained(results, summary)
                        data = json.loads(summary.read_text())
                        if (data.get('status') not in CLOSED or not data.get('run_id') or
                                data.get('journal_errors') or data.get('shutdown_error')):
                            continue
                        closed = db.execute("SELECT props FROM event WHERE session=? AND kind IN ('qa.run','qa.run.result','qa.run.checkpoint') ORDER BY id DESC LIMIT 1",
                                            (data['run_id'],)).fetchone()
                        reason = None if closed and json.loads(closed[0]).get('status') == data['status'] else 'missing-journal-closure'
                        reason = reason or run_owner_reason(root, results, data.get('derived_data'))
                        if not data.get('simulator_name'):
                            reason = reason or 'unknown-run-owner'
                        days = config['passed_days'] if data['status'] == 'passed' else config['failed_days']
                        add(summary.parent, 'raw', days, identity=data.get('derived_data'),
                            simulator_name=data.get('simulator_name'), reason=reason)
                    except (OSError, ValueError, KeyError):
                        continue
        except sqlite3.Error:
            pass
    # Journal archives are disposable generated copies too. Their qa.archive
    # event is committed only after every file has been copied successfully.
    if (results / 'activity.sqlite').is_file():
        with sqlite3.connect('file:' + str(results / 'activity.sqlite') + '?mode=ro', uri=True) as db:
            for row in db.execute("SELECT c.after_txt,e.props FROM event e JOIN content c ON c.event_uid=e.uid WHERE e.kind='qa.archive'"):
                path = Path(row[0])
                if path.is_dir() and results / 'archives' in path.parents:
                    props = json.loads(row[1])
                    reason = run_owner_reason(root, results, props.get('derived_data'))
                    if not props.get('simulator_name'):
                        reason = reason or 'unknown-archive-owner'
                    add(path, 'archive', config['cache_days'], reason=reason,
                        identity=props.get('derived_data'), simulator_name=props.get('simulator_name'))
    # Keep per-file cleanup receipts for a bounded month, not forever. Current
    # maintenance holds retention.lock, and young/incomplete receipts cannot be
    # budget-evicted while they may still be needed to diagnose a partial run.
    for path in (results / 'retention').glob('storage-retention-*'):
        if re.fullmatch('storage-retention-[0-9a-f]{32}', path.name) and path.is_dir():
            before = len(items)
            add(path, 'audit', 30)
            if len(items) > before and items[-1]['reason'] == 'young':
                items[-1]['reason'] = 'young-audit'
    # These exact namespaces are generated by the CLI. Each old immutable log or
    # receipt can expire independently, so a new open log cannot pin its siblings.
    try:
        owners = command_owners(results)
    except (OSError, ValueError, TypeError, sqlite3.Error):
        owners = {}
    for relative in ('devtools/logs', 'devtools/runs', 'devtools/device-builds'):
        directory = results / relative
        if directory.is_dir():
            for path in sorted(directory.iterdir()):
                if path.is_file() and not path.is_symlink() and path.suffix in ('.log', '.json'):
                    add(path, 'receipt', config['cache_days'],
                        reason=command_owner_reason(root, results, path, owners))
    unique = {item['path']: item for item in items}
    selected = budget(list(unique.values()), config)
    checked = set()
    while True:
        pending = [item for item in selected if item['kind'] == 'cache'
                   and Path(item['path']).name == 'SourcePackages' and not item['reason']
                   and item['path'] not in checked]
        if not pending:
            return selected
        for item in pending:
            checked.add(item['path'])
            item['reason'] = source_packages_reason(root, Path(item['path']), remote_cache)
        selected = budget(selected, config)


def erase(path, manifest, results):
    """Remove exact inventoried entries, including empty directories, without following links.

    One descriptor per depth avoids exhausting the host's descriptor limit on
    large SourcePackages trees. Named directory identities are rechecked before
    each unlink/rmdir; unknown/new entries cause a visible partial failure.
    """
    expected = {entry['path']: entry for entry in manifest}
    if len(expected) != len(manifest) or '.' not in expected:
        raise ValueError('Invalid deletion manifest')
    children = {}
    for relative in expected:
        value = Path(relative)
        if value.is_absolute() or '..' in value.parts:
            raise ValueError('Invalid manifest traversal')
        if relative != '.':
            parent = str(value.parent)
            if expected.get(parent, {}).get('kind') != 'directory':
                raise ValueError('Missing directory identity')
            children.setdefault(parent, []).append(relative)
    own_ctimes = {}
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW

    def identity(st):
        return st.st_dev, st.st_ino

    with directory_fd(path.parent) as parent_fd:
        parent_identity = identity(os.fstat(parent_fd))

        def parent_unchanged():
            with directory_fd(path.parent) as current:
                if identity(os.fstat(current)) != parent_identity:
                    raise ValueError('Deletion parent was replaced')

        def remove(parent, name, relative, parent_check):
            entry = expected[relative]
            parent_check()
            st = os.stat(name, dir_fd=parent, follow_symlinks=False)
            key = entry['device'], entry['inode']
            wanted_ctime = own_ctimes.get(key, entry['ctime_ns'])
            if (identity(st) != key or st.st_mtime_ns != entry['mtime_ns'] or st.st_ctime_ns != wanted_ctime):
                raise ValueError('Manifest entry changed: ' + relative)
            if entry['kind'] == 'directory':
                fd = os.open(name, flags, dir_fd=parent)
                try:
                    if identity(os.fstat(fd)) != key:
                        raise ValueError('Directory was replaced: ' + relative)

                    def unchanged():
                        parent_check()
                        current = os.stat(name, dir_fd=parent, follow_symlinks=False)
                        if not stat.S_ISDIR(current.st_mode) or identity(current) != key:
                            raise ValueError('Named directory was replaced: ' + relative)

                    known = children.get(relative, [])
                    if set(os.listdir(fd)) != {Path(child).name for child in known}:
                        raise ValueError('Directory entries changed: ' + relative)
                    for child in sorted(known):
                        remove(fd, Path(child).name, child, unchanged)
                    unchanged()
                    if os.listdir(fd):
                        raise ValueError('New entries appeared: ' + relative)
                    os.rmdir(name, dir_fd=parent)
                finally:
                    os.close(fd)
            elif entry['kind'] == 'symlink':
                if not stat.S_ISLNK(st.st_mode) or os.readlink(name, dir_fd=parent) != entry['target']:
                    raise ValueError('Symlink changed: ' + relative)
                parent_check()
                os.unlink(name, dir_fd=parent)
            else:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
                try:
                    opened = os.fstat(fd)
                    if (not stat.S_ISREG(opened.st_mode) or identity(opened) != key
                            or opened.st_size != entry['bytes'] or opened.st_mtime_ns != entry['mtime_ns']
                            or opened.st_ctime_ns != wanted_ctime):
                        raise ValueError('File changed: ' + relative)
                    parent_check()
                    if identity(os.stat(name, dir_fd=parent, follow_symlinks=False)) != key:
                        raise ValueError('File name was replaced: ' + relative)
                    os.unlink(name, dir_fd=parent)
                    # Unlinking one manifest hardlink changes the same inode's
                    # ctime for its remaining names. Record only our own update.
                    own_ctimes[key] = os.fstat(fd).st_ctime_ns
                finally:
                    os.close(fd)

        remove(parent_fd, path.name, '.', parent_unchanged)


def unmanaged_paths(results, items):
    """Report fixed namespace levels without walking unknown or active content."""
    known = {Path(item['path']) for item in items}
    unknown = set()

    def children(path):
        if path.is_symlink():
            unknown.add(path)
            return []
        try:
            return list(path.iterdir())
        except (FileNotFoundError, NotADirectoryError):
            return []

    def covered(path):
        return any(path == candidate or candidate in path.parents for candidate in known)

    def report(path):
        if not covered(path):
            unknown.add(path)

    for path in children(results):
        if path.is_dir() and path.name not in ('devtools', 'runs', 'archives', 'retention'):
            report(path)
    for namespace in ('runs', 'retention'):
        for path in children(results / namespace):
            report(path)
    for session in children(results / 'archives'):
        revisions = children(session)
        if not revisions:
            report(session)
        for revision in revisions:
            report(revision)
    for namespace in ('logs', 'runs', 'device-builds'):
        for path in children(results / 'devtools' / namespace):
            report(path)
    for path in children(results / 'devtools'):
        if path.name not in ('derived-data', 'logs', 'runs', 'device-builds', 'locks'):
            report(path)
    for cache in children(results / 'devtools/derived-data'):
        if covered(cache):  # Existing/queued owner: never enumerate its build tree.
            continue
        if not any(cache in candidate.parents for candidate in known):
            report(cache)
            continue
        for part in children(cache):
            if part.name == 'Build' and not part.is_symlink():
                for component in children(part):
                    report(component)
            else:
                report(part)
    return sorted(map(str, unknown))


def run(root, apply=False, now=None):
    root = Path(root).resolve()
    config = policy(root)
    remote_cache = {}
    items = candidates(root, config, now=now, remote_cache=remote_cache)
    # No remote work needed when age/ownership metadata already protects everything.
    if config.get('retain_references', False) and any(not item['reason'] for item in items):
        refs = references(root)
        items = candidates(root, config, refs, now=now, remote_cache=remote_cache)
    else:
        refs = ''
    result = {'schema': 2, 'apply': apply, 'eligible': [], 'protected': [], 'freed_bytes': 0, 'freed_allocated': 0}
    for item in items:
        compact = {k: v for k, v in item.items() if k != 'files'}
        compact.update(bytes=sum(f['bytes'] for f in item['files']),
                       files=sum(f['kind'] != 'directory' for f in item['files']),
                       directories=sum(f['kind'] == 'directory' for f in item['files']))
        result['protected' if item['reason'] else 'eligible'].append(compact)
    measured = sum(f['allocated'] for item in items for f in item['files'])
    unmanaged = unmanaged_paths(canonical_root(root) / 'tests/results', items)
    result.update(budget_bytes=config['max_generated_bytes'], unmanaged_paths=unmanaged, measured_generated_bytes=measured,
                  over_budget_bytes=max(0, measured - config['max_generated_bytes']),
                  unmeasured_active_paths=[x['path'] for x in items if x.get('unmeasured_active')],
                  oldest_candidate_unix=min((x['newest'] for x in items if x['files']), default=None))
    if not apply or not result['eligible']:
        return result
    results = canonical_root(root) / 'tests/results'
    session = 'storage-retention-' + uuid.uuid4().hex
    audit = contained(results, results / 'retention' / session)
    controls_safe(results)
    with safe_lock(results / 'devtools/locks/host-heavy.lock'), safe_lock(results / 'devtools/locks/retention.lock'), ExitStack() as stack:
        stack.enter_context(directory_fd(results))
        controls_safe(results)
        if policy(root) != config:
            raise ValueError('Artifact eligibility changed under locks')
        # One fresh budget/manifest snapshot under the host lock, not one global
        # scan per component. Deletions below only revalidate their own item.
        fresh = candidates(root, config, refs, now=now, remote_cache=remote_cache)
        by_path = {x['path']: x for x in fresh if not x['reason']}
        for item in items:
            if not item['reason'] and (item['path'] not in by_path or by_path[item['path']]['files'] != item['files']):
                raise ValueError('Artifact eligibility changed under locks')
        journal = Journal(results / 'activity.sqlite')
        stack.callback(journal.close)
        controls_safe(results)
        with directory_fd(audit, create=True):
            pass
        for item in items:
            if item['reason']:
                continue
            with ExitStack() as owned:
                apply_item(root, results, item, config, refs, session, audit, journal, result, owned)
        atomic_json(audit / 'result.json', result)
        journal.artifact(session, audit / 'result.json')
    result['audit'] = str(audit)
    result['remaining_measured_generated_bytes'] = max(0, measured - result['freed_allocated'])
    result['over_budget_bytes'] = max(0, result['remaining_measured_generated_bytes'] - config['max_generated_bytes'])
    return result


@contextmanager
def directory_fd(path, create=False):
    """Anchor every ancestor with no-follow opens, starting at the filesystem root."""
    path = Path(path).absolute()
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with ExitStack() as stack:
        fd = os.open('/', flags)
        stack.callback(os.close, fd)
        for part in path.parts[1:]:
            if part in ('.', '..'):
                raise ValueError('Traversal is protected')
            if create:
                try:
                    os.mkdir(part, dir_fd=fd)
                except FileExistsError:
                    pass
            fd = os.open(part, flags, dir_fd=fd)
            stack.callback(os.close, fd)
        yield fd


@contextmanager
def safe_lock(path):
    """Preserve lock metadata and use its stable no-follow inode for mutual exclusion."""
    path = Path(path)
    with directory_fd(path.parent, create=True) as parent:
        fd = os.open(path.name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                raise ValueError('Aliased/nonregular lock is protected')
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            if (named.st_dev, named.st_ino) != (st.st_dev, st.st_ino):
                raise ValueError('Lock inode was replaced')
            yield
        finally:
            os.close(fd)


def controls_safe(results):
    """Never pass a linked database or sidecar to SQLite's path-based API."""
    for name in ('activity.sqlite', 'activity.sqlite-wal', 'activity.sqlite-shm', 'activity.sqlite-journal'):
        path = contained(results, results / name)
        if path.exists():
            st = path.lstat()
            if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                raise ValueError('Aliased/nonregular QA database is protected')
    with directory_fd(results):
        pass


def apply_item(root, results, item, config, refs, session, audit, journal, result, stack):
    path = contained(results, Path(item['path']))
    identity = item['identity']
    if item['kind'] == 'cache':
        if not retired(root, results, identity):
            raise ValueError('Cache ownership changed')
        stack.enter_context(safe_lock(results / 'devtools/locks' / (identity + '.lock')))
        cache = results / 'devtools/derived-data' / identity
    elif item['kind'] in ('raw', 'archive'):
        if not identity or not item['simulator_name']:
            raise ValueError('Missing raw-run ownership')
        cache = Path(identity)
        stack.enter_context(safe_lock(Path(tempfile.gettempdir()).resolve() / ('today-qa-lock-' + hashlib.sha256(
            ('name:' + item['simulator_name']).encode()).hexdigest())))
    else:
        cache = path
    key = 'cache:' + str(cache)
    stack.enter_context(safe_lock(Path(tempfile.gettempdir()).resolve() / ('today-qa-lock-' + hashlib.sha256(key.encode()).hexdigest())))
    # The host lock owns the shared budget snapshot. Revalidate only this
    # candidate's policy, lifecycle and manifest; unrelated trees need no rescan.
    fresh_refs = references(root) if config.get('retain_references', False) else ''
    if policy(root) != config or protected(results, path, config, fresh_refs):
        raise ValueError('Artifact eligibility changed under locks')
    controls_safe(results)
    if item['kind'] in ('raw', 'archive'):
        if run_owner_reason(root, results, item['identity']):
            raise ValueError('Run owner changed under locks')
    if item['kind'] == 'receipt' and command_owner_reason(root, results, path):
        raise ValueError('Command owner changed under locks')
    if item['kind'] == 'raw':
        data = json.loads((path / 'summary-retained.json').read_text())
        with sqlite3.connect('file:' + str(results / 'activity.sqlite') + '?mode=ro', uri=True) as db:
            closed = db.execute("SELECT props FROM event WHERE session=? AND kind IN ('qa.run','qa.run.result','qa.run.checkpoint') ORDER BY id DESC LIMIT 1",
                                (data['run_id'],)).fetchone()
            if not closed or json.loads(closed[0]).get('status') != data['status'] or data['status'] not in CLOSED:
                raise ValueError('Run lifecycle changed under locks')
    current = tree(path)
    if current != item['files']:
        raise ValueError('Artifact changed since plan')
    # lsof errors other than its documented no-match exit fail closed.
    opened = subprocess.run(['lsof', '-nP', *(['+D'] if path.is_dir() else []), str(path)], capture_output=True, text=True, timeout=30)
    if opened.returncode != 1 or opened.stdout or opened.stderr:
        raise ValueError('Open files or uncertain lsof result: ' + str(path))
    hashed = tree(path, hashes=True)
    if [{k: v for k, v in x.items() if k != 'sha256'} for x in hashed] != current:
        raise ValueError('Artifact changed during manifest')
    manifest = audit / (uuid.uuid4().hex + '.json')
    atomic_json(manifest, {**{k: v for k, v in item.items() if k != 'files'}, 'files': hashed})
    journal.artifact(session, manifest)
    journal.record(session, 'qa.retention.planned', str(path), snapshot={'manifest': str(manifest),
                   'sha256': digest(manifest), 'bytes': sum(f['bytes'] for f in hashed)})
    # Every destructive operation is preceded by a committed tombstone.
    try:
        if tree(path) != current:
            raise ValueError('Artifact changed immediately before deletion')
        erase(path, hashed, results)
    except BaseException:
        journal.record(session, 'qa.retention.partial', str(path), status='failed')
        raise
    result['freed_bytes'] += sum(f['bytes'] for f in hashed)
    result['freed_allocated'] += sum(f['allocated'] for f in hashed)
    journal.record(session, 'qa.retention.deleted', str(path), status='completed',
                   props={'bytes': sum(f['bytes'] for f in hashed)}, snapshot={'manifest': str(manifest)})

def after_run(root):
    """Best effort after final indexing; never changes the QA run's outcome."""
    try:
        if policy(root).get('automatic'):
            result = run(root, apply=True)
            print(json.dumps({'retention': {
                'eligible': len(result['eligible']), 'protected': len(result['protected']),
                'freed_bytes': result['freed_bytes'], 'budget_bytes': result['budget_bytes'],
                'over_budget_bytes': result['over_budget_bytes'], 'unmeasured_active_paths': result['unmeasured_active_paths'],
                'unmanaged_paths': result['unmanaged_paths'],
                'oldest_candidate_unix': result['oldest_candidate_unix'], 'audit': result.get('audit')}}), flush=True)
    except Exception as error:
        print('QA retention skipped: ' + str(error), flush=True)
