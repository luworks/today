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
        self.config = {'schema': 1, 'automatic': True, 'passed_days': 7, 'failed_days': 30,
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

    def test_apply_hashes_tombstones_and_preserves_index_and_products(self):
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
        self.assertEqual(manifests[0]['files'][0]['sha256'], retention.hashlib.sha256(b'reproducible compiler data').hexdigest())

    def test_pins_references_age_and_existing_owner_protect(self):
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

    def test_symlinks_traversal_and_database_fail_closed(self):
        outside = self.root / 'outside'
        outside.write_text('valuable')
        (self.path / 'escape').symlink_to(outside)
        self.assertEqual(retention.run(self.root, apply=True)['eligible'], [])
        self.assertEqual(outside.read_text(), 'valuable')
        (self.path / 'escape').unlink()
        (self.path / 'activity.sqlite').write_text('index')
        self.assertEqual(retention.run(self.root, apply=True)['eligible'], [])
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
        for file in path.rglob('*'):
            os.utime(file, (age, age))
        return path

    def test_raw_requires_age_closure_archive_and_keeps_latest(self):
        self.owner.mkdir()  # Cache is protected, isolate raw behavior.
        old = time.time() - 40 * 86400
        archived = self.raw('archived', old)
        missing = self.raw('missing-closure', old + 1, closed=False)
        unarchived = self.raw('no-archive', old + 2, archive=False)
        latest = self.raw('latest', old + 3)
        result = retention.run(self.root)
        self.assertEqual([x['path'] for x in result['eligible']], [str(archived)])
        result = retention.run(self.root, apply=True)
        self.assertFalse((archived / 'ui.xcresult/raw').exists())
        self.assertTrue(next((self.results / 'archives/archived').glob('*/ui.xcresult/raw')).exists())
        for path in (missing, unarchived, latest):
            self.assertTrue((path / 'ui.xcresult/raw').exists())

    def test_failed_raw_keeps_thirty_days_and_uncertain_metadata(self):
        self.owner.mkdir()
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

    def test_nested_pin_and_identity_root_reference_protect_whole_candidate(self):
        self.config['pins'] = ['*phone*']
        self.save_policy()
        receipt = self.path / 'phone-rollback904.log'
        receipt.write_text('proof')
        old = time.time() - 3 * 86400
        os.utime(receipt, (old, old))
        self.assertEqual(retention.run(self.root)['eligible'], [])
        receipt.unlink()
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
        self.owner.mkdir()
        old = time.time() - 40 * 86400
        live = self.raw('resumed', old)
        self.raw('latest', old + 1)
        journal = Journal(self.results / 'activity.sqlite')
        journal.record('resumed', 'qa.run', str(live), status='running')
        journal.close()
        self.assertEqual(retention.run(self.root)['eligible'], [])

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
            self.assertEqual(cli.main(['test', 'release', '--full'], root=self.root), 65)
        self.assertEqual(steps, ['completed-and-unlocked', 'retention'])


if __name__ == '__main__':
    unittest.main()
