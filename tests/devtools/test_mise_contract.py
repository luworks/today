"""Read-only runtime contract checks; never install tools or compile runtimes.

Run with MISE_BIN pointing to the receipt-verified bootstrap executable.
Python 3.9/3.10 needs tomli; Python 3.11+ uses the standard library.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

try:
    import tomllib
except ImportError:
    import tomli as tomllib

ROOT = Path(__file__).resolve().parents[2]
PINS = {'ruby': '3.3.12', 'python': '3.14.8'}


def read_toml(path):
    return tomllib.loads(path.read_text())


def require_project_pins(test, actual):
    for name, version in PINS.items():
        records = actual.get(name, [])
        test.assertEqual(len(records), 1, name)
        record = records[0]
        test.assertEqual(record['version'], version, name)
        test.assertEqual(record['requested_version'], version, name)
        test.assertEqual(Path(record['source']['path']).resolve(), ROOT / '.mise.toml', name)


class MiseContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = read_toml(ROOT / '.mise.toml')
        cls.lock = read_toml(ROOT / 'mise.lock')
        cls.mise = os.environ.get('MISE_BIN') or str(
            ROOT / '.dev-tools/mise/2026.10.14/bin/mise')

    def mise_json(self, *args, extra_env=None):
        if not Path(self.mise).is_file():
            self.fail('Receipt-verified mise is required; set MISE_BIN (no installation is attempted).')
        env = dict(os.environ, MISE_TRUSTED_CONFIG_PATHS=str(ROOT))
        env.update(extra_env or {})
        result = subprocess.run([self.mise, *args], cwd=ROOT, env=env,
                                text=True, capture_output=True, timeout=30, check=True)
        return json.loads(result.stdout)

    def test_runtime_and_existing_release_lock_agree(self):
        release = json.loads((ROOT / 'scripts/release/tool-lock.json').read_text())
        gems = (ROOT / 'Gemfile.lock').read_text()
        self.assertEqual(self.config['tools'], {'core:' + k: v for k, v in PINS.items()})
        self.assertEqual(release['ruby'], PINS['ruby'])
        self.assertIn('\n  ruby ' + release['ruby'] + '\n', gems)
        self.assertIn('\n  ' + release['bundler'] + '\n', gems)
        self.assertIn('\n    fastlane (' + release['fastlane'] + ')\n', gems)
        self.assertEqual(release['bundler'], '4.0.16')
        self.assertEqual(release['fastlane'], '2.241.2')

    def test_locked_precompiled_payloads_and_no_compile_fallback(self):
        self.assertTrue(self.config['settings']['lockfile'])
        self.assertEqual(set(self.lock['tools']), set(PINS))
        prefixes = {'ruby': 'https://github.com/jdx/ruby/releases/download/',
                    'python': 'https://github.com/astral-sh/python-build-standalone/releases/download/'}
        for name, version in PINS.items():
            self.assertIs(self.config['settings'][name]['compile'], False)
            entries = self.lock['tools'][name]
            self.assertEqual(len(entries), 1)
            entry = entries[0]
            self.assertEqual(entry['version'], version)
            self.assertEqual(entry['backend'], 'core:' + name)
            self.assertEqual(entry['specifiers'], [version])
            payload = entry['platforms.macos-arm64']
            self.assertTrue(payload['url'].startswith(prefixes[name]))
            self.assertIn(version, payload['url'])
            self.assertRegex(payload['checksum'], r'^sha256:[a-f0-9]{64}$')

    def test_bootstrap_tools_keep_one_installation_authority(self):
        manifest = json.loads((ROOT / 'docs/engineering/tool-pins.json').read_text())
        expected = ['{{config_root}}/.dev-tools/' + name + '/' +
                    manifest['tools'][name]['version'] + '/bin'
                    for name in ('xcodegen', 'swiftlint', 'mise', 'ruff', 'actionlint')]
        self.assertEqual(self.config['env']['_']['path'], expected)
        self.assertNotIn('tasks', self.config)
        self.assertNotIn('hooks', self.config)

    def test_host_effective_pins_and_supported_config_keys(self):
        require_project_pins(self, self.mise_json('ls', '--current', '--json'))
        schema = self.mise_json('config', 'explain', '--json')
        self.assertTrue(schema)
        self.assertEqual([x['key'] for x in schema if not x['known'] or x['deprecated']], [])

    def test_global_override_is_detected(self):
        # Real mise precedence, with a temporary global override; no user config is edited.
        with tempfile.TemporaryDirectory(prefix='mise override contract ') as directory:
            config = Path(directory)
            (config / 'config.override.toml').write_text('[tools]\n"core:ruby" = "3.3.11"\n')
            actual = self.mise_json('ls', '--current', '--json', extra_env={
                'MISE_CONFIG_DIR': directory,
                'MISE_TRUSTED_CONFIG_PATHS': str(ROOT) + ':' + directory})
            self.assertEqual(actual['ruby'][0]['version'], '3.3.11')
            with self.assertRaises(AssertionError):
                require_project_pins(self, actual)


if __name__ == '__main__':
    unittest.main()
