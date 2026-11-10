"""Behavioral coverage using temporary worktrees and small Python children."""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.devtools import core  # noqa: E402 - standalone test import bootstrap
from scripts.devtools.cli import main  # noqa: E402 - standalone test import bootstrap
from scripts.devtools.process import Evidence, Redactor, run_process  # noqa: E402 - standalone test import bootstrap


class FoundationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='today dev space ')
        self.root = Path(self.temp.name).resolve()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / 'ios').mkdir()
        (self.root / 'ios/Input.swift').write_text('first')
        (self.root / 'ios/Package.resolved').write_text('lock 1')
        (self.root / 'package-lock.json').write_text('root lock')
        (self.root / 'tests').mkdir()
        (self.root / 'tests/qa').mkdir()
        for name in ('journal.py', 'activity-v1.sql'):
            shutil.copyfile(ROOT / 'tests/qa' / name, self.root / 'tests/qa' / name)

    def tearDown(self):
        self.temp.cleanup()

    def fp(self, **kwargs):
        return core.fingerprint(self.root, tools={'xcode': 'fake', 'sdk': 'fake'}, **kwargs)

    def test_readonly_commands_make_no_files(self):
        before = {p.relative_to(self.root) for p in self.root.rglob('*')}
        # No journal, build, simulator, arbitrary process, or writable lock access.
        probes = []
        real = core.probe
        def read_probe(argv, cwd=None):
            probes.append(argv)
            self.assertIn(argv[:2], [['git', 'ls-files'], ['git', 'rev-parse']])
            return real(argv, cwd)
        with patch('scripts.devtools.doctor.inspect', return_value={'ok': False, 'checks': {}, 'read_only': True}), \
             patch('scripts.devtools.core.toolchain', return_value={'xcode': None, 'sdks': []}), \
             patch('scripts.devtools.cli.toolchain', return_value={'xcode': None, 'sdks': []}), \
             patch('scripts.devtools.core.probe', side_effect=read_probe), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(['help'], self.root), 0)
            self.assertEqual(main(['inventory'], self.root), 0)
            self.assertEqual(main(['doctor'], self.root), 1)
            self.assertEqual(main(['plan'], self.root), 0)
        self.assertTrue(probes)
        self.assertEqual(before, {p.relative_to(self.root) for p in self.root.rglob('*')})

    def test_unknown_command_fails_without_execution(self):
        with contextlib.redirect_stderr(io.StringIO()) as output, self.assertRaises(SystemExit) as caught:
            main(['nonexistent'], self.root)
        self.assertEqual(caught.exception.code, 2)
        self.assertIn('invalid choice', output.getvalue())

    def test_build_failure_reaches_caller(self):
        with patch('scripts.devtools.commands.build', return_value=65) as build:
            self.assertEqual(main(['build', 'Release'], self.root), 65)
        build.assert_called_once_with(self.root, 'Release', scheme='Today')

    def test_invalid_test_group_cannot_start_a_runner(self):
        with patch('scripts.devtools.commands.test', side_effect=AssertionError('runner started')), \
             contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            main(['test', 'nonexistent'], self.root)
        self.assertEqual(caught.exception.code, 2)

    def test_explicit_final_timeout_reaches_runner_and_nonpositive_is_rejected(self):
        with patch('scripts.devtools.commands.test', return_value=65) as runner:
            self.assertEqual(main(['test', 'release', '--full', '--timeout', '14400'], self.root), 65)
            runner.assert_called_once_with(self.root, 'release', only=[], full=True, timeout=14400)
        with patch('scripts.devtools.commands.test') as runner, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(['test', 'unit', '--timeout', '0'], self.root), 1)
            runner.assert_not_called()

    def test_worktree_and_spaces_have_distinct_dd(self):
        other = self.root / 'other worktree'
        other.mkdir()
        gitdir = self.root / '.git/worktrees/other'
        gitdir.mkdir(parents=True)
        (gitdir / 'commondir').write_text('../..')
        (other / '.git').write_text('gitdir: ' + str(gitdir))
        self.assertEqual(core.canonical_root(other), self.root)
        self.assertNotEqual(core.derived_data(self.root), core.derived_data(other))
        self.assertEqual(core.state_root(other), core.state_root(self.root))

    def test_fingerprint_changes_for_source_lock_toolchain_and_options(self):
        original = self.fp()
        self.assertEqual(original, self.fp())
        for name in ['ios/Input.swift', 'ios/Package.resolved', 'package-lock.json']:
            path = self.root / name
            previous = path.read_text()
            path.write_text(previous + ' changed')
            self.assertNotEqual(original, self.fp())
            path.write_text(previous)
        for kwargs in [{'sdk': 'iphoneos'}, {'architecture': 'other'}, {'configuration': 'Release'}]:
            self.assertNotEqual(original, self.fp(**kwargs))
        self.assertNotEqual(original, core.fingerprint(self.root, tools={'xcode': 'different'}))

    def test_provenance_rejects_failed_stale_and_modified_products(self):
        product = core.derived_data(self.root) / 'built app'
        product.parent.mkdir(parents=True)
        product.write_text('binary')
        current = self.fp()
        self.assertFalse(core.provenance(self.root, current)['valid'])
        with self.assertRaises(ValueError):
            core.record_build(self.root, current, [product], returncode=1)
        with self.assertRaises(ValueError):
            core.record_build(self.root, current, [self.root / 'ios/Input.swift'], returncode=0)
        with core.dd_lock(self.root):
            core.record_build(self.root, current, [product], returncode=0)
        self.assertTrue(core.provenance(self.root, current)['valid'])
        (self.root / 'ios/Input.swift').write_text('changed')
        self.assertFalse(core.provenance(self.root, self.fp())['valid'])
        product.write_text('modified')
        self.assertFalse(core.provenance(self.root, current)['valid'])

    def test_lock_contends_and_retains_inode(self):
        path = core.state_root(self.root) / 'locks/host-heavy.lock'
        with core.host_lock(self.root):
            inode = path.stat().st_ino
            self.assertTrue(core.inspect_lock(path)['held'])
            child = subprocess.run([sys.executable, '-B', '-c',
                'import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); '
                'from scripts.devtools.core import ResourceLock, ResourceBusy; '
                '\ntry:\n with ResourceLock(sys.argv[2], "child"): pass\n'
                'except ResourceBusy: sys.exit(7)', str(ROOT), str(path)], capture_output=True)
            self.assertEqual(child.returncode, 7, child.stderr)
        self.assertFalse(core.inspect_lock(path)['held'])
        # Stale metadata, even a currently live PID, never substitutes for flock.
        path.write_text(json.dumps({'pid': os.getpid(), 'owner': 'stale'}))
        with core.host_lock(self.root):
            self.assertEqual(inode, path.stat().st_ino)
            self.assertEqual(core.inspect_lock(path)['metadata']['owner'], str(self.root))

    def execute(self, script, **kwargs):
        evidence = Evidence(self.root, 'fake-child', Redactor({'API_TOKEN': 'top secret value'}))
        try:
            result = run_process([sys.executable, '-B', '-c', script], cwd=self.root,
                                 evidence=evidence, **kwargs)
            rows = evidence.journal.query('fake-child')
            self.assertTrue(any(row['kind'] == 'qa.artifact' for row in rows))
            return result, rows
        finally:
            evidence.close()

    def test_child_spaces_exit_and_journal_redaction(self):
        result, rows = self.execute('import os; print(os.getcwd()); print("top secret value"); '
                                    'print("password=hidden"); raise SystemExit(9)')
        self.assertEqual(result.returncode, 9)
        log = result.log.read_text()
        self.assertIn(str(self.root), log)
        self.assertNotIn('top secret value', log + json.dumps(rows))
        self.assertNotIn('hidden', log + json.dumps(rows))
        self.assertIn('[REDACTED]', log)

    def test_timeout_kills_owned_descendant_and_leaves_unrelated_child(self):
        outside = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(20)'])
        pidfile = self.root / 'descendant pid'
        script = ('import subprocess,sys,time; p=subprocess.Popen([sys.executable,"-c",'
                  '"import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(20)"]); '
                  f'open({str(pidfile)!r},"w").write(str(p.pid)); time.sleep(20)')
        try:
            result, _ = self.execute(script, timeout=0.4, grace=0.1)
            self.assertEqual((result.returncode, result.reason), (124, 'timeout'))
            self.assertLess(result.seconds, 3)
            self.assertIsNone(outside.poll())
            pid = int(pidfile.read_text())
            # A zombie is terminated too; ps is a read-only probe, no kill by discovered PID.
            state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
            self.assertTrue(not state or state.startswith('Z'), state)
        finally:
            outside.terminate()
            outside.wait()

    def test_cancel_and_signal_handlers_restored(self):
        cancel = threading.Event()
        timer = threading.Timer(0.2, cancel.set)
        previous = signal.getsignal(signal.SIGINT)
        timer.start()
        try:
            result, _ = self.execute('import time; time.sleep(20)', cancel=cancel, grace=0.05)
            self.assertEqual((result.returncode, result.reason), (130, 'cancelled'))
            self.assertEqual(signal.getsignal(signal.SIGINT), previous)
        finally:
            timer.join()

    def test_injected_environment_and_sensitive_flag_are_redacted_from_output(self):
        evidence = Evidence(self.root, 'credentials', Redactor({}))
        try:
            env = dict(os.environ, API_TOKEN='injected-value')
            result = run_process([sys.executable, '-c',
                'import os,sys; print(os.environ["API_TOKEN"]); print(sys.argv[2])',
                '--password', 'flag-value'], cwd=self.root, evidence=evidence, env=env)
            all_text = result.log.read_text() + json.dumps(evidence.journal.query('credentials'))
            self.assertNotIn('injected-value', all_text)
            self.assertNotIn('flag-value', all_text)
        finally:
            evidence.close()

    def test_real_sigint_cancels_child_and_restores_handler(self):
        old = signal.getsignal(signal.SIGINT)
        thread = threading.Thread(target=lambda: (time.sleep(0.2), os.kill(os.getpid(), signal.SIGINT)))
        thread.start()
        try:
            result, _ = self.execute('import time; time.sleep(20)', grace=0.05)
            self.assertEqual(result.returncode, 130)
            self.assertEqual(signal.getsignal(signal.SIGINT), old)
        finally:
            thread.join()

    def test_spawn_failure_is_recorded_and_handler_restored(self):
        evidence = Evidence(self.root, 'missing', Redactor({}))
        previous = signal.getsignal(signal.SIGTERM)
        try:
            with self.assertRaises(FileNotFoundError):
                run_process([str(self.root / 'no executable')], cwd=self.root, evidence=evidence)
            self.assertEqual(signal.getsignal(signal.SIGTERM), previous)
            rows = evidence.journal.query('missing')
            self.assertTrue(any('failed' in row['props'] for row in rows))
            self.assertTrue(any(row['kind'] == 'qa.artifact' for row in rows))
        finally:
            evidence.close()

    def test_group_permission_failure_retains_syscall_log_and_reaps_owned_child(self):
        from scripts.devtools import process
        evidence = Evidence(self.root, 'permission', Redactor({}))
        previous = signal.getsignal(signal.SIGTERM)
        real_popen = subprocess.Popen
        children = []

        def spawn(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            children.append(child)
            return child

        try:
            with patch.object(process.subprocess, 'Popen', side_effect=spawn), \
                    patch.object(process.os, 'killpg', side_effect=PermissionError(1, 'Operation not permitted')):
                with self.assertRaises(PermissionError) as caught:
                    run_process([sys.executable, '-c', 'import time; print("partial", flush=True); time.sleep(20)'],
                                cwd=self.root, evidence=evidence, timeout=0.2, grace=0.05)
            self.assertIsNotNone(children[0].returncode)
            self.assertEqual(signal.getsignal(signal.SIGTERM), previous)
            self.assertEqual(caught.exception.process_log, evidence.path)
            text = evidence.path.read_text()
            self.assertIn('partial', text)
            self.assertIn('os.killpg(pgid=', text)
            self.assertIn('PermissionError', text)
            self.assertTrue(any(row['kind'] == 'qa.artifact' for row in evidence.journal.query('permission')))
        finally:
            evidence.close()

    def test_redactor_covers_tokens_credentials_and_explicit_secrets(self):
        redact = Redactor({'API_KEY': 'env secret'}, secrets=['literal secret'])
        self.assertEqual(redact.arguments(['tool', '--password', 'unknown secret', '--api-key=abc']),
                         ['tool', '--password', '[REDACTED]', '--api-key=[REDACTED]'])
        text = 'env secret literal secret token=abc Bearer opaque https://user:pass@example.com'
        self.assertEqual(redact(text), '[REDACTED] [REDACTED] token=[REDACTED] Bearer [REDACTED] https://[REDACTED]@example.com')


if __name__ == '__main__':
    unittest.main()
