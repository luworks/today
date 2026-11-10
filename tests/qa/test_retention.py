"""Host-only destructive-path regression tests with isolated disposable trees."""
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import retention  # noqa: E402 - standalone host test bootstrap
from journal import Journal  # noqa: E402 - standalone host test bootstrap
from scripts.devtools.core import worktree_id  # noqa: E402 - standalone host test bootstrap


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / '.git').mkdir()
        (self.root / 'tests/qa').mkdir(parents=True)
        self.results = self.root / 'tests/results'
        self.results.mkdir()
        self.config = {'schema': 2, 'max_generated_bytes': 20000000000, 'retain_references': True, 'automatic': True, 'passed_days': 7, 'failed_days': 30,
                       'cache_days': 1, 'pins': []}
        self.save_policy()
        self.owner = self.root / 'removed-owner'
        self.identity = worktree_id(self.owner)
        self.cache = self.results / 'devtools/derived-data' / self.identity
        self.path = self.cache / 'ModuleCache.noindex'
        self.path.mkdir(parents=True)
        self.file = self.path / 'module.pcm'
        self.file.write_bytes(b'reproducible compiler data')
        old = time.time() - 3 * 86400
        os.utime(self.file, (old, old))
        self.lock = self.results / 'devtools/locks' / (self.identity + '.lock')
        self.lock.parent.mkdir(parents=True)
        self.lock.write_text(json.dumps({'owner': str(self.owner), 'pid': 999999999}))
        for item in (self.path, self.lock):
            os.utime(item, (old, old))
        self.addCleanup(patch.stopall)
        patch.object(retention, 'probe', return_value='worktree ' + str(self.root)).start()
        patch.object(retention, 'references', return_value='').start()
        patch.object(retention.subprocess, 'run', return_value=retention.subprocess.CompletedProcess([], 1, '', '')).start()

    def save_policy(self):
        (self.root / 'tests/qa/retention.json').write_text(json.dumps(self.config))

    def test_dry_run_does_not_write_or_open_journal(self):
        before = sorted(str(p) for p in self.root.rglob('*'))
        with patch.object(retention, 'Journal', side_effect=AssertionError('dry-run opened DB')):
            result = retention.run(self.root)
        self.assertEqual(len(result['eligible']), 1)
        self.assertEqual(sorted(str(p) for p in self.root.rglob('*')), before)
        self.assertTrue(self.file.exists())

    def test_apply_hashes_tombstones_and_preserves_journal_and_young_products(self):
        product = self.cache / 'Build/Products/Today.app/data'
        product.parent.mkdir(parents=True)
        product.write_bytes(b'phone rollback')
        original_lock = self.lock.read_bytes()
        journal = Journal(self.results / 'activity.sqlite')
        uid = journal.record('earlier', 'qa.development', 'immutable earlier evidence')
        journal.close()
        result = retention.run(self.root, apply=True)
        self.assertEqual(result['freed_bytes'], len(b'reproducible compiler data'))
        self.assertFalse(self.file.exists())
        self.assertEqual(product.read_bytes(), b'phone rollback')
        self.assertEqual(self.lock.read_bytes(), original_lock)
        with sqlite3.connect(self.results / 'activity.sqlite') as db:
            self.assertEqual(db.execute('pragma integrity_check').fetchone()[0], 'ok')
            self.assertEqual(db.execute('select count(*) from event where uid=?', (uid,)).fetchone()[0], 1)
            kinds = [x[0] for x in db.execute("select kind from event where kind like 'qa.retention.%' order by id")]
            self.assertEqual(kinds, ['qa.retention.planned', 'qa.retention.deleted'])
        manifests = [json.loads(p.read_text()) for p in Path(result['audit']).glob('*.json') if p.name != 'result.json']
        regular = next(x for x in manifests[0]['files'] if x['kind'] == 'file')
        self.assertEqual(regular['sha256'], retention.hashlib.sha256(b'reproducible compiler data').hexdigest())

    def test_pins_references_age_and_idle_existing_owner(self):
        self.config['pins'] = ['devtools/derived-data/**']
        self.save_policy()
        self.assertEqual(retention.run(self.root)['eligible'], [])
        self.config['pins'] = []
        self.save_policy()
        with patch.object(retention, 'references', return_value=str(self.path)):
            self.assertEqual(retention.run(self.root)['eligible'], [])
        self.owner.mkdir()
        self.assertEqual(retention.run(self.root)['eligible'], [])
        self.owner.rmdir()
        os.utime(self.file, None)
        self.assertEqual(retention.run(self.root)['eligible'], [])

    def test_live_lock_or_pid_never_deleted(self):
        with self.lock.open('r') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(retention.run(self.root, apply=True)['eligible'], [])
        self.lock.write_text(json.dumps({'owner': str(self.owner), 'pid': os.getpid()}))
        self.assertEqual(retention.run(self.root, apply=True)['eligible'], [])
        self.assertTrue(self.file.exists())

    def test_generated_links_databases_and_unsafe_control_paths(self):
        outside = self.root / 'outside'
        outside.write_text('valuable')
        (self.path / 'escape').symlink_to(outside)
        old = time.time() - 3 * 86400
        os.utime(self.path, (old, old))
        os.utime(self.path / 'escape', (old, old), follow_symlinks=False)
        retention.run(self.root, apply=True)
        self.assertEqual(outside.read_text(), 'valuable')
        self.assertFalse((self.path / 'escape').is_symlink())
        self.path.mkdir()
        (self.path / 'activity.sqlite').write_text('generated cache DB')
        for item in (self.path, self.path / 'activity.sqlite'):
            os.utime(item, (old, old))
        retention.run(self.root, apply=True)
        self.assertFalse((self.path / 'activity.sqlite').exists())
        with self.assertRaises(ValueError):
            retention.contained(self.results, self.results / '../outside')
        with self.assertRaises(ValueError):
            retention.contained(self.results, self.results)
        (self.results / 'alias').symlink_to(self.path, target_is_directory=True)
        with self.assertRaises(ValueError):
            retention.contained(self.results, self.results / 'alias/module.pcm')

    def test_changed_files_open_files_and_failed_journal_stop_deletion(self):
        def change(*args, **kwargs):
            self.file.write_bytes(b'new live bytes')
            return retention.subprocess.CompletedProcess([], 1, '', '')
        with patch.object(retention.subprocess, 'run', side_effect=change):
            with self.assertRaises(ValueError):
                retention.run(self.root, apply=True)
        self.assertTrue(self.file.exists())
        old = time.time() - 3 * 86400
        os.utime(self.file, (old, old))
        with patch.object(retention.subprocess, 'run', return_value=retention.subprocess.CompletedProcess([], 0, 'writer', '')):
            with self.assertRaises(ValueError):
                retention.run(self.root, apply=True)
        with patch.object(Journal, 'record', side_effect=sqlite3.OperationalError('journal unavailable')):
            with self.assertRaises(sqlite3.OperationalError):
                retention.run(self.root, apply=True)
        self.assertTrue(self.file.exists())

    def raw(self, name, age, status='passed', archive=True, closed=True):
        path = self.results / 'runs' / name
        path.mkdir(parents=True)
        data = {'run_id': name, 'status': status, 'selection': ['TodayTests/Example/testAction'],
                'derived_data': str(self.cache), 'simulator_name': 'owned-test-device'}
        (path / 'summary-retained.json').write_text(json.dumps(data))
        (path / 'ui.xcresult').mkdir()
        (path / 'ui.xcresult/raw').write_bytes(b'complete result')
        journal = Journal(self.results / 'activity.sqlite')
        if closed:
            journal.record(name, 'qa.run.result', json.dumps(data), status=status)
        if archive:
            journal.archive_files(path, name)
        journal.close()
        for file in [path, *path.rglob('*')]:
            os.utime(file, (age, age))
        return path

    def test_closed_raw_expires_without_archive_or_latest_lane_exemption(self):
        self.file.unlink()
        self.path.rmdir()  # Isolate raw behavior without inventing an active owner.
        old = time.time() - 40 * 86400
        archived = self.raw('archived', old)
        missing = self.raw('missing-closure', old + 1, closed=False)
        unarchived = self.raw('no-archive', old + 2, archive=False)
        latest = self.raw('latest', old + 3)
        result = retention.run(self.root)
        self.assertEqual(set(x['path'] for x in result['eligible']), {str(archived), str(unarchived), str(latest)})
        result = retention.run(self.root, apply=True)
        self.assertFalse((archived / 'ui.xcresult/raw').exists())
        self.assertTrue(next((self.results / 'archives/archived').glob('*/ui.xcresult/raw')).exists())
        self.assertTrue((missing / 'ui.xcresult/raw').exists())
        for path in (unarchived, latest):
            self.assertFalse((path / 'ui.xcresult/raw').exists())

    def test_failed_raw_keeps_thirty_days_and_uncertain_metadata(self):
        self.file.unlink()
        self.path.rmdir()
        old = time.time() - 10 * 86400
        failed = self.raw('failed', old, status='failed')
        self.raw('latest', time.time())
        items = retention.run(self.root)
        self.assertEqual(items['eligible'], [])
        self.assertEqual(next(x['reason'] for x in items['protected'] if x['path'] == str(failed)), 'young')
        (failed / 'summary-retained.json').write_text('{invalid')
        self.assertEqual(retention.run(self.root, apply=True)['eligible'], [])

    def test_automatic_hook_respects_disable_and_does_not_replace_test_failure(self):
        self.config['automatic'] = False
        self.save_policy()
        with patch.object(retention, 'run') as run:
            retention.after_run(self.root)
            run.assert_not_called()
        self.config['automatic'] = True
        self.save_policy()
        with patch.object(retention, 'run', side_effect=RuntimeError('busy')):
            retention.after_run(self.root)
        self.assertTrue(self.file.exists())

    def test_generic_pin_scope_and_explicit_identity_reference(self):
        self.config['pins'] = ['*phone*']
        self.save_policy()
        receipt = self.path / 'phone-rollback904.log'
        receipt.write_text('proof')
        old = time.time() - 3 * 86400
        os.utime(receipt, (old, old))
        os.utime(self.path, (old, old))
        self.assertEqual(len(retention.run(self.root)['eligible']), 1)
        self.config['pins'] = [str(receipt.relative_to(self.results))]
        self.save_policy()
        self.assertEqual(retention.run(self.root)['eligible'], [])
        receipt.unlink()
        os.utime(self.path, (old, old))
        self.config['pins'] = []
        self.save_policy()
        with patch.object(retention, 'references', return_value=str(self.cache)):
            self.assertEqual(retention.run(self.root)['eligible'], [])
        # The same identity's preserved Products are a sibling, not compiler cache evidence.
        with patch.object(retention, 'references', return_value=str(self.cache / 'Build/Products/Today.app')):
            self.assertEqual(len(retention.run(self.root)['eligible']), 1)

    def test_policy_and_journal_lifecycle_revalidated_under_lock(self):
        calls = []
        def update_policy(root):
            calls.append(1)
            if len(calls) == 2:
                self.config['cache_days'] = 100
                self.save_policy()
            return ''
        with patch.object(retention, 'references', side_effect=update_policy):
            with self.assertRaisesRegex(ValueError, 'eligibility changed'):
                retention.run(self.root, apply=True)
        self.assertTrue(self.file.exists())
        self.file.unlink()
        self.path.rmdir()
        self.lock.write_text(json.dumps({'owner': str(self.owner), 'pid': 999999999}))
        old = time.time() - 40 * 86400
        live = self.raw('resumed', old)
        self.raw('latest', old + 1)
        journal = Journal(self.results / 'activity.sqlite')
        journal.record('resumed', 'qa.run', str(live), status='running')
        journal.close()
        self.assertNotIn(str(live), [x['path'] for x in retention.run(self.root)['eligible']])

    def test_control_symlinks_and_ancestor_swap_cannot_escape(self):
        outside = self.root / 'outside'
        outside.write_text('valuable')
        db = self.results / 'activity.sqlite'
        db.symlink_to(outside)
        with self.assertRaises(ValueError):
            retention.run(self.root, apply=True)
        self.assertEqual(outside.read_text(), 'valuable')
        db.unlink()
        host = self.results / 'devtools/locks/host-heavy.lock'
        host.symlink_to(outside)
        with self.assertRaises(OSError):
            retention.run(self.root, apply=True)
        self.assertEqual(outside.read_text(), 'valuable')
        host.unlink()
        original_erase = retention.erase
        def swap(path, files, results):
            foreign = self.root / 'moved-outside-results'
            self.cache.rename(foreign)
            self.cache.symlink_to(foreign, target_is_directory=True)
            return original_erase(path, files, results)
        with patch.object(retention, 'erase', side_effect=swap):
            with self.assertRaises(OSError):
                retention.run(self.root, apply=True)
        self.assertTrue((self.root / 'moved-outside-results/ModuleCache.noindex/module.pcm').exists())

    def test_dev_cli_runs_maintenance_after_qa_authority_returns_and_keeps_exit(self):
        from scripts.devtools import cli, commands
        steps = []
        def completed(*args, **kwargs):
            steps.append('completed-and-unlocked')
            return 65
        with patch.object(commands, 'test', side_effect=completed), patch.object(
                retention, 'after_run', side_effect=lambda root: steps.append('retention')):
            self.assertEqual(cli.main(['test', 'release', '--full'], root=self.root, maintenance=True), 65)
        self.assertEqual(steps, ['retention', 'completed-and-unlocked', 'retention'])


    def test_sdk_names_do_not_pin_compiler_cache_but_explicit_paths_do(self):
        self.config['pins'] = ['*phone*', '*release*']
        self.save_policy()
        sdk = self.path / 'Debug-iphonesimulator/CMHeadphoneMotionManager.h'
        sdk.parent.mkdir()
        sdk.write_text('compiler index')
        header = self.path / 'NSAutoreleasePool.h'
        header.write_text('compiler index')
        old = time.time() - 4 * 86400
        for entry in (sdk, header, sdk.parent, self.path):
            os.utime(entry, (old, old))
        self.assertEqual(len(retention.run(self.root)['eligible']), 1)
        self.config['pins'] = [str(sdk.relative_to(self.results))]
        self.save_policy()
        self.assertEqual(retention.run(self.root)['eligible'], [])

    def test_budget_evicts_oldest_idle_young_cache_without_overriding_pin_or_live_owner(self):
        other = self.cache / 'Index.noindex'
        other.mkdir()
        file = other / 'index'
        file.write_bytes(b'second reusable cache')
        now = time.time()
        for entry in (self.file, self.path):
            os.utime(entry, (now - 1800, now - 1800))
        for entry in (file, other):
            os.utime(entry, (now - 60, now - 60))
        self.config['max_generated_bytes'] = file.stat().st_blocks * 512
        self.config['retain_references'] = False
        self.save_policy()
        result = retention.run(self.root, apply=True)
        self.assertFalse(self.file.exists())
        self.assertTrue(file.exists())
        self.assertTrue(result['eligible'][0]['budget_eviction'])
        self.assertEqual(result['over_budget_bytes'], 0)
        self.config['max_generated_bytes'] = 1
        self.config['pins'] = [str(other.relative_to(self.results))]
        self.save_policy()
        result = retention.run(self.root, apply=True)
        self.assertTrue(file.exists())
        self.assertGreater(result['over_budget_bytes'], 0)
        self.lock.write_text(json.dumps({'owner': str(self.owner), 'pid': os.getpid()}))
        result = retention.run(self.root, apply=True)
        self.assertTrue(result['unmeasured_active_paths'])
        self.assertTrue(file.exists())

    def test_old_cli_log_expires_independently_of_current_open_sibling(self):
        self.file.unlink()
        logs = self.results / 'devtools/logs'
        logs.mkdir()
        old = logs / 'old.log'
        old.write_text('old command')
        live = logs / 'new.log'
        live.write_text('current command')
        journal = Journal(self.results / 'activity.sqlite')
        journal.artifact('completed-log', old)
        journal.record('completed-log', 'qa.command.devtools', 'closed command', status='passed',
                       props={'owner': str(self.owner), 'worktree_id': self.identity, 'pid': 999999999})
        journal.close()
        stamp = time.time() - 5 * 86400
        os.utime(old, (stamp, stamp))
        with live.open('a'):
            retention.run(self.root, apply=True)
        self.assertFalse(old.exists())
        self.assertEqual(live.read_text(), 'current command')

    def test_historical_lexical_owner_hash_survives_repository_alias_rename(self):
        current = self.root / 'today'
        current.mkdir()
        historical = self.root / 'one-app'
        historical.symlink_to(current, target_is_directory=True)
        identity = retention.hashlib.sha256(os.fsencode(historical)).hexdigest()[:20]
        self.cache.rename(self.cache.with_name(identity))
        self.lock.rename(self.lock.with_name(identity + '.lock'))
        lock = self.lock.with_name(identity + '.lock')
        lock.write_text(json.dumps({'owner': str(historical), 'pid': 999999999}))
        old = time.time() - 4 * 86400
        os.utime(lock, (old, old))
        self.assertNotEqual(worktree_id(historical), identity)
        result = retention.run(self.root, apply=True)
        self.assertEqual(result['eligible'], [])
        self.assertTrue((self.cache.with_name(identity) / 'ModuleCache.noindex/module.pcm').exists())
        self.assertTrue(current.exists())
        current.rmdir()  # The dangling historical alias still resolves to the new spelling.
        result = retention.run(self.root, apply=True)
        self.assertEqual(len(result['eligible']), 1)
        self.assertFalse((self.cache.with_name(identity) / 'ModuleCache.noindex').exists())

    def test_source_remote_proof_is_lazy_and_component_apply_is_not_quadratic(self):
        sources = self.cache / 'SourcePackages'
        sources.mkdir()
        (sources / 'workspace-state.json').write_text('young and not selected')
        self.config['retain_references'] = False
        self.save_policy()
        with patch.object(retention, 'source_packages_reason', side_effect=AssertionError('young source queried')):
            self.assertEqual(len(retention.run(self.root)['eligible']), 1)
        sources.rename(self.cache / 'not-a-managed-component')
        other = self.cache / 'Index.noindex'
        other.mkdir()
        (other / 'index').write_text('old index')
        old = time.time() - 4 * 86400
        for item in (other, other / 'index'):
            os.utime(item, (old, old))
        with patch.object(retention, 'candidates', wraps=retention.candidates) as scans:
            result = retention.run(self.root, apply=True)
        self.assertEqual(len(result['eligible']), 2)
        self.assertEqual(scans.call_count, 2)  # Plan + one host-locked snapshot, independent of component count.

    def test_budget_newly_selected_sources_still_require_remote_proof(self):
        self.file.unlink()
        sources = self.cache / 'SourcePackages'
        sources.mkdir()
        (sources / 'workspace-state.json').write_text('not controlled source')
        owner = self.root / 'second-owner'
        identity = worktree_id(owner)
        second = self.cache.parent / identity / 'SourcePackages'
        second.mkdir(parents=True)
        (second / 'workspace-state.json').write_text('also not controlled')
        (self.lock.parent / (identity + '.lock')).write_text(json.dumps({'owner': str(owner), 'pid': 999999999}))
        self.config['max_generated_bytes'] = 1
        self.config['retain_references'] = False
        self.save_policy()
        with patch.object(retention, 'source_packages_reason', return_value='unknown-source') as proof:
            result = retention.run(self.root, apply=True)
        self.assertEqual(proof.call_count, 2)
        self.assertEqual(result['eligible'], [])
        self.assertTrue(sources.exists())
        self.assertTrue(second.exists())

    def test_remote_dependency_git_edits_and_unique_mirror_refs_are_preserved(self):
        patch.stopall()  # This test uses real isolated Git repositories, not process stubs.
        patch.dict(os.environ, {'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_SYSTEM': '/dev/null'}).start()
        import subprocess
        from scripts.devtools.core import probe as real_probe
        package = self.cache / 'SourcePackages'
        checkout = package / 'checkouts/dependency'
        original = self.root / 'upstream'
        remote = self.root / 'remote.git'
        original.mkdir()
        def git(*args):
            return subprocess.check_output(['git', *map(str, args)], text=True).strip()
        git('init', '-q', original)
        git('-C', original, 'config', 'user.name', 'Synthetic Test')
        git('-C', original, 'config', 'user.email', 'synthetic@example.invalid')
        (original / 'Package.swift').write_text('synthetic dependency')
        git('-C', original, 'add', 'Package.swift')
        git('-C', original, 'commit', '-qm', 'Synthetic source')
        revision = git('-C', original, 'rev-parse', 'HEAD')
        git('clone', '-q', '--bare', original, remote)
        checkout.parent.mkdir(parents=True)
        git('clone', '-q', remote, checkout)
        git('-C', checkout, 'checkout', '-q', '--detach', revision)
        url = 'https://github.com/synthetic/dependency'
        git('-C', checkout, 'remote', 'set-url', 'origin', url)
        (self.root / 'ios/Dependencies').mkdir(parents=True)
        (self.root / 'ios/Dependencies/Package.resolved').write_text(json.dumps({'pins': [
            {'kind': 'remoteSourceControl', 'location': url, 'state': {'revision': revision}}]}))
        (package / 'workspace-state.json').write_text(json.dumps({'object': {'dependencies': [
            {'subpath': 'dependency', 'packageRef': {'location': url},
             'state': {'checkoutState': {'revision': revision}}}]}}))
        mirror = package / 'repositories/dependency.git'
        mirror.parent.mkdir()
        git('clone', '-q', '--bare', remote, mirror)
        git('-C', mirror, 'remote', 'set-url', 'origin', url)
        remote_calls = []
        def read(argv, **kwargs):
            if argv[:2] == ['git', 'ls-remote']:
                remote_calls.append(argv[-1])
                argv = [*argv[:-1], str(remote)]
            return real_probe(argv, **kwargs)
        index = checkout / '.git/index'
        before_index = (index.stat().st_mtime_ns, index.stat().st_ctime_ns, index.stat().st_size)
        with patch.object(retention, 'probe', side_effect=read):
            remote_cache = {}
            self.assertIsNone(retention.source_packages_reason(self.root, package, remote_cache))
            self.assertIsNone(retention.source_packages_reason(self.root, package, remote_cache))
            self.assertEqual(remote_calls, [url])
            self.assertEqual((index.stat().st_mtime_ns, index.stat().st_ctime_ns, index.stat().st_size), before_index)
            outside = self.root / 'outside-dependency-patch'
            git('-C', mirror, 'worktree', 'add', '-q', '--detach', outside, revision)
            self.assertEqual(retention.source_packages_reason(self.root, package), 'shared-source-git')
            self.assertTrue((outside / 'Package.swift').exists())
            git('-C', mirror, 'worktree', 'remove', outside)
            (checkout / 'Package.swift').write_text('uncommitted real source')
            self.assertEqual(retention.source_packages_reason(self.root, package), 'modified-source')
            git('-C', checkout, 'checkout', '--', 'Package.swift')
            (original / 'Package.swift').write_text('unpublished source')
            git('-C', original, 'commit', '-qam', 'Unpublished source')
            unique = git('-C', original, 'rev-parse', 'HEAD')
            git('-C', mirror, 'fetch', '-q', original, unique)
            git('-C', mirror, 'update-ref', 'refs/heads/private-change', unique)
            self.assertEqual(retention.source_packages_reason(self.root, package), 'local-source-refs')
            state = json.loads((package / 'workspace-state.json').read_text())
            state['object']['dependencies'][0]['packageRef']['location'] = 'https://secret@github.com/synthetic/dependency'
            (package / 'workspace-state.json').write_text(json.dumps(state))
            count = len(remote_calls)
            self.assertEqual(retention.source_packages_reason(self.root, package), 'unknown-source')
            self.assertEqual(len(remote_calls), count)
        self.assertTrue((checkout / 'Package.swift').exists())


    def test_import_failure_and_bad_policy_cannot_replace_authority_exit(self):
        import contextlib
        import io
        from scripts.devtools import cli, commands
        with patch.object(commands, 'build', return_value=65), patch.dict(sys.modules, {'retention': None}), \
                contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(cli.main(['build'], root=self.root, maintenance=True), 65)
        self.assertIn('QA retention skipped:', error.getvalue())
        self.config['schema'] = 999
        self.save_policy()
        with patch.object(commands, 'build', return_value=65), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(cli.main(['build'], root=self.root, maintenance=True), 65)
        self.assertIn('QA retention skipped:', output.getvalue())

    def test_imported_cli_default_root_never_implicitly_runs_maintenance(self):
        from scripts.devtools import cli, commands
        with patch.object(commands, 'test', return_value=0), patch.object(
                cli, 'maintain', side_effect=AssertionError('default-root maintenance escaped')) as maintenance:
            self.assertEqual(cli.main(['test', 'ios-unit', '--only', 'Synthetic']), 0)
        maintenance.assert_not_called()

    def test_queued_existing_owner_protects_cache_raw_and_ownerless_logs(self):
        self.owner.mkdir()  # Queued/nonterminal workspaces survive without a PID or held lock.
        self.config['max_generated_bytes'] = 1
        self.config['retain_references'] = False
        self.save_policy()
        raw = self.raw('queued-proof', time.time() - 40 * 86400)
        logs = self.results / 'devtools/logs'
        logs.mkdir()
        old_log = logs / 'ownerless.log'
        old_log.write_text('queued task may still cite this old log')
        stamp = time.time() - 40 * 86400
        os.utime(old_log, (stamp, stamp))
        with patch.object(retention, 'erase', side_effect=AssertionError('queued data deletion')):
            result = retention.run(self.root, apply=True)
        self.assertEqual(result['eligible'], [])
        self.assertTrue(self.file.exists())
        self.assertTrue((raw / 'ui.xcresult/raw').exists())
        self.assertTrue(old_log.exists())

    def test_empty_app_resources_and_internal_hardlinks_are_fully_removed(self):
        products = self.cache / 'Build/Products'
        empty = products / 'Today.app/Frameworks/Feature.framework/Resources/Empty'
        empty.mkdir(parents=True)
        binary = products / 'Today.app/Today'
        binary.write_bytes(b'synthetic executable')
        linked = products / 'Today.app/Frameworks/shared'
        linked.hardlink_to(binary)
        stamp = time.time() - 4 * 86400
        for item in [products, *products.rglob('*')]:
            os.utime(item, (stamp, stamp))
        result = retention.run(self.root, apply=True)
        self.assertFalse(products.exists())
        self.assertFalse(self.path.exists())
        self.assertEqual(result['freed_bytes'], len(b'reproducible compiler data') + 2 * len(b'synthetic executable'))
        with sqlite3.connect(self.results / 'activity.sqlite') as db:
            self.assertEqual(db.execute("select count(*) from event where kind='qa.retention.partial'").fetchone()[0], 0)

    def test_unknown_known_namespace_children_are_reported_without_walking_or_deleting(self):
        import contextlib
        import io
        unknown = [self.results / 'runs/no-summary', self.results / 'archives/unindexed/revision',
                   self.cache.parent / 'unmatched-id', self.cache / 'Build/UnknownProducts',
                   self.results / 'devtools/logs/unknown-format', self.results / 'devtools/unknown-namespace',
                   self.results / 'manual-proof']
        for path in unknown:
            (path / 'deep/private').mkdir(parents=True)
            (path / 'deep/private/keep').write_text('unclassified output')
        original = Path.iterdir
        walk = os.walk

        def shallow(path):
            if any(path == item or item in path.parents for item in unknown):
                self.fail('unknown content was enumerated: ' + str(path))
            return original(path)

        def known_walk(path, *args, **kwargs):
            if any(path == item or item in Path(path).parents for item in unknown):
                self.fail('unknown content was walked: ' + str(path))
            return walk(path, *args, **kwargs)

        with patch.object(Path, 'iterdir', shallow), patch.object(os, 'walk', known_walk):
            result = retention.run(self.root)
        self.assertEqual(set(result['unmanaged_paths']), set(map(str, unknown)))
        with patch.object(retention, 'run', return_value=result), contextlib.redirect_stdout(io.StringIO()) as output:
            retention.after_run(self.root)
        self.assertEqual(set(json.loads(output.getvalue())['retention']['unmanaged_paths']), set(map(str, unknown)))
        self.assertTrue(all((path / 'deep/private/keep').exists() for path in unknown))


if __name__ == '__main__':
    unittest.main()
