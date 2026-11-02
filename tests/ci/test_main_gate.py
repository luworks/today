"""Synthetic gate regressions. No network, native build, simulator or installation."""
import json
import importlib.util
import plistlib
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.ci import main_gate as gate  # noqa: E402


class MainInstallTests(unittest.TestCase):
    def setUp(self):
        self.sha, self.tree = 'a' * 40, 'b' * 40
        self.tools = {'xcode': {'ProductBuildVersion': '27A9275'}, 'sdks': {'iPhoneSimulator27.1.sdk': 'c' * 64}}
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.args = SimpleNamespace(commit=self.sha, main_run='42', build_receipt=self.root / 'build.json')
        self.product = {n: {'bundle_id': b, 'executable_sha256': 'd' * 64, 'info_sha256': 'e' * 64}
                        for n, b in gate.PRODUCTS.items()}
        self.build = {'source': self.sha, 'tree': self.tree, 'source_after': self.sha, 'dirty_after': '',
                      'exit': 0, 'toolchain': self.tools, 'signing_changes': False,
                      'automatic_provisioning_updates': False,
                      'app': str(self.root / 'Debug-iphoneos/One.app'), 'product_identity': self.product}
        app = Path(self.build['app'])
        app.mkdir(parents=True)
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleSupportedPlatforms': ['iPhoneOS']}))
        run = {'head_sha': self.sha, 'head_branch': 'main', 'path': '.github/workflows/today.yml',
               'status': 'completed', 'conclusion': 'success', 'run_attempt': 1}
        # The merge gate (main push run) and an unrelated dispatch run on the same SHA.
        self.runs = {'42': dict(run, id=42, event='push'), '43': dict(run, id=43, event='workflow_dispatch')}
        self.info = self.runs['42']
        self.main_sha = self.sha
        self.calls = []
        self.jobs = {'42': {'checks': 'success', 'today-required': 'success'},
                     '43': {'full': 'success'}}

    def github(self, argv, root):
        path = argv[-1]
        self.calls.append(path)
        if path.endswith('commits/main'):
            return json.dumps({'sha': self.main_sha}).encode()
        if 'actions/workflows/today.yml/runs?' in path:
            self.assertIn('head_sha=' + self.sha, path)
            self.assertIn('event=push', path)
            return json.dumps({'workflow_runs': list(self.runs.values())}).encode()
        run_id = path.split('actions/runs/')[-1].split('/')[0]
        if path.endswith('actions/runs/' + run_id):
            return json.dumps(self.runs[run_id]).encode()
        if '/attempts/' in path:
            return json.dumps({'jobs': [{'name': n, 'conclusion': c} for n, c in self.jobs[run_id].items()]}).encode()
        raise AssertionError(path)

    def check(self):
        self.args.build_receipt.write_text(json.dumps(self.build))
        with (patch.object(gate, 'probe', side_effect=lambda argv, root: '' if 'status' in argv else self.tree if 'HEAD^{tree}' in argv else self.sha),
              patch.object(gate, 'tool_identity', return_value=self.tools),
              patch.object(gate, 'product_identity', return_value=self.product)):
            return gate.check_install(self.root, self.args, self.github)

    def test_existing_preflight_install_mode_blocks_without_ci_and_does_not_invoke_archive_setup(self):
        spec = importlib.util.spec_from_file_location('gate_release', ROOT / 'scripts/release/release.py')
        release = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(release)
        self.args.for_install = True
        self.args.version, self.args.build = '1.0', '42'
        with (patch.object(release, 'check_git'), patch.object(release, 'check_tools') as archive_tools,
              patch.object(gate, 'check_install', side_effect=ValueError('offline'))):
            result = release.local_preflight(self.root, self.args).data
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual(result['checks']['main_usability']['status'], 'blocked')
        archive_tools.assert_not_called()

    def test_exact_main_positive_does_not_install_and_rechecks_main(self):
        self.assertEqual(self.check()['sha'], self.sha)
        self.assertEqual(sum(p.endswith('commits/main') for p in self.calls), 2)
        self.assertTrue(all(p.startswith('repos/luworks/today/') for p in self.calls))

    def test_branch_old_main_running_or_failed_run_blocks(self):
        for run_id in ('42',):
            for field, value in [('head_sha', 'f' * 40), ('event', 'pull_request'), ('head_branch', 'feature'),
                                 ('status', 'in_progress'), ('conclusion', 'failure'), ('path', 'other.yml')]:
                with self.subTest(run=run_id, field=field), patch.dict(self.runs[run_id], {field: value}), \
                        self.assertRaises(ValueError):
                    self.check()
        self.main_sha = 'f' * 40
        with self.assertRaisesRegex(ValueError, 'current_main_mismatch'):
            self.check()

    def test_dispatch_run_or_missing_run_cannot_authorize_install(self):
        self.args.main_run = '43'
        with self.assertRaisesRegex(ValueError, 'completed_main_run_required'):
            self.check()
        self.args.main_run, self.runs = '', {}
        with self.assertRaisesRegex(ValueError, 'run_required'):
            self.check()

    def test_omitted_run_id_is_the_newest_push_run_for_the_sha(self):
        self.args.main_run = ''
        self.assertEqual(self.check()['main_run'], '42')
        self.runs['44'] = dict(self.runs['42'], id=44)
        self.jobs['44'] = dict(self.jobs['42'])
        self.assertEqual(self.check()['main_run'], '44')
        # A failed newest push run is reported, never skipped for an older green one.
        self.runs['44']['conclusion'] = 'failure'
        with self.assertRaisesRegex(ValueError, 'completed_main_run_required'):
            self.check()

    def test_failed_skipped_or_missing_required_job_blocks(self):
        for run_id, name in (('42', 'checks'), ('42', 'today-required')):
            for conclusion in ('failure', 'skipped', 'cancelled', None):
                with self.subTest(name=name, conclusion=conclusion), \
                        patch.dict(self.jobs[run_id], {name: conclusion}), self.assertRaisesRegex(ValueError, 'jobs_missing'):
                    self.check()
        del self.jobs['42']['today-required']
        with self.assertRaisesRegex(ValueError, 'jobs_missing'):
            self.check()

    def test_rerun_started_while_reading_blocks(self):
        original = self.github
        def rerun(argv, root):
            data = original(argv, root)
            if argv[-1].endswith('commits/main') and len(self.calls) > 1:
                self.runs['42']['run_attempt'] = 2
            return data
        with patch.object(self, 'github', side_effect=rerun), self.assertRaisesRegex(ValueError, 'run_changed'):
            self.check()

    def test_device_source_toolchain_or_product_drift_blocks(self):
        for field, value in [('source', 'f' * 40), ('source_after', 'f' * 40), ('tree', 'f' * 40),
                             ('dirty_after', ' M source.swift'), ('exit', 124), ('toolchain', {}),
                             ('product_identity', {}), ('signing_changes', True), ('app', '/tmp/Debug-iphonesimulator/One.app')]:
            with self.subTest(field=field), patch.dict(self.build, {field: value}), self.assertRaises(ValueError):
                self.check()

    def test_provisioning_updates_require_explicit_matching_authorization(self):
        self.build['automatic_provisioning_updates'] = True
        with self.assertRaisesRegex(ValueError, 'provenance_mismatch'):
            self.check()
        self.args.allow_provisioning_updates = True
        self.assertEqual(self.check()['sha'], self.sha)
        self.build['automatic_provisioning_updates'] = False
        with self.assertRaisesRegex(ValueError, 'provenance_mismatch'):
            self.check()

    def test_offline_and_main_race_never_pass(self):
        with patch.object(self, 'github', side_effect=OSError('offline')), self.assertRaises(OSError):
            self.check()
        original = self.github
        def change_main(argv, root):
            data = original(argv, root)
            if '/jobs' in argv[-1]:
                self.main_sha = 'f' * 40
            return data
        with patch.object(self, 'github', side_effect=change_main), self.assertRaisesRegex(ValueError, 'current_main_mismatch'):
            self.check()


if __name__ == '__main__':
    unittest.main()
