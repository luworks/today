import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('compare_settings', ROOT / 'scripts/engineering/compare_settings.py')
settings = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(settings)


class EquivalenceTests(unittest.TestCase):
    def test_only_developer_names_and_build_paths_may_change(self):
        old = [{'target': 'One', 'buildSettings': {'PRODUCT_MODULE_NAME': 'One',
                'PRODUCT_BUNDLE_IDENTIFIER': 'com.luworks.today', 'TARGET_NAME': 'One',
                'TARGET_TEMP_DIR': '/build/One.build/Debug/One.build'}}]
        new = [{'target': 'Today', 'buildSettings': {'PRODUCT_MODULE_NAME': 'One',
                'PRODUCT_BUNDLE_IDENTIFIER': 'com.luworks.today', 'TARGET_NAME': 'Today',
                'TARGET_TEMP_DIR': '/build/Today.build/Debug/Today.build'}}]
        self.assertTrue(settings.compare(old, new)['equivalent'])
        for key, wrong in [('PRODUCT_MODULE_NAME', 'Today'),
                           ('PRODUCT_BUNDLE_IDENTIFIER', 'com.luworks.other')]:
            new[0]['buildSettings'][key] = wrong
            self.assertFalse(settings.compare(old, new)['equivalent'])
            new[0]['buildSettings'][key] = old[0]['buildSettings'][key]

    def test_missing_target_and_signing_changes_fail(self):
        old = [{'target': 'TodayWidgets', 'buildSettings': {'CODE_SIGN_ENTITLEMENTS': 'TodayWidgets.entitlements'}}]
        self.assertFalse(settings.compare(old, [])['equivalent'])
        new = [{'target': 'TodayWidgets', 'buildSettings': {'CODE_SIGN_ENTITLEMENTS': 'Wrong.entitlements'}}]
        self.assertFalse(settings.compare(old, new)['equivalent'])


if __name__ == '__main__':
    unittest.main()
