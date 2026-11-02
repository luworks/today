"""Device CLI and install gate orchestration without a device or native build."""
import contextlib
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from scripts.devtools import commands
from scripts.devtools.cli import main


class DeviceBuildTests(unittest.TestCase):
    def test_cli_routes_authorization_and_run_ids(self):
        with patch.object(commands, 'build', return_value=0) as build:
            self.assertEqual(main(['build', '--device', 'phone', '--install', '--allow-provisioning-updates',
                                   '--main-run', '42', '--smoke-run', '43'], Path('.')), 0)
        self.assertTrue(build.call_args.kwargs['provisioning_updates'])
        self.assertEqual(build.call_args.kwargs['smoke_run'], '43')

    def test_invalid_device_options_stop_before_build(self):
        for options in ({'device': 'phone', 'scheme': 'TodayMock'}, {'device': 'phone', 'testing': True},
                        {'install': True}, {'device': 'phone', 'main_run': '42'},
                        {'device': 'phone', 'smoke_run': '43'}, {'provisioning_updates': True}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                commands.build(Path('.'), **options)

    def test_failed_gate_never_installs(self):
        result = SimpleNamespace(returncode=0, log=Path('/tmp/build.log'))
        with (patch.object(commands, 'host_lock', return_value=contextlib.nullcontext()),
              patch.object(commands, 'dd_lock', return_value=contextlib.nullcontext()),
              patch.object(commands, 'generate', return_value=0),
              patch.object(commands, 'probe', side_effect=lambda argv, root: 'a' * 40 if 'status' not in argv else ''),
              patch.object(commands, 'fingerprint', return_value={}),
              patch.object(commands, 'derived_data', return_value=Path('/tmp')),
              patch.object(Path, 'is_dir', return_value=True),
              patch.object(commands, 'record_build'), patch.object(commands, 'atomic_json') as receipt,
              patch.object(commands, 'execute', return_value=result) as execute,
              patch('scripts.devtools.resolve.locked_arguments', return_value=[]),
              patch('scripts.release.release.check_git'),
              patch('scripts.ci.main_gate.tool_identity', return_value={}),
              patch('scripts.ci.main_gate.product_identity', return_value={}),
              patch('scripts.ci.main_gate.check_install', side_effect=ValueError('blocked')) as gate):
            with self.assertRaisesRegex(ValueError, 'blocked'):
                commands.build(Path('.'), device='phone', install=True, provisioning_updates=True,
                               main_run='42', smoke_run='43')
            self.assertEqual(execute.call_count, 1)
            gate.side_effect = None
            self.assertEqual(commands.build(Path('.'), device='phone', install=True, provisioning_updates=True,
                                            main_run='42', smoke_run='43'), 0)
            self.assertEqual(execute.call_args.args[1][:5], ['xcrun', 'devicectl', 'device', 'install', 'app'])
        self.assertTrue(receipt.call_args.args[1]['automatic_provisioning_updates'])
        self.assertIn('-allowProvisioningUpdates', execute.call_args_list[0].args[1])
