"""App configuration a Debug simulator build cannot catch. No network."""
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / 'ios'
GROUP = 'group.com.luworks.today'
ENTITLEMENTS = ('One', 'TodayWidgets', 'ShareExtension')
USAGE_KEYS = ('NSCalendarsFullAccessUsageDescription', 'NSRemindersFullAccessUsageDescription',
              'NSHealthShareUsageDescription', 'NSMicrophoneUsageDescription',
              'NSSpeechRecognitionUsageDescription')


def settings(name):
    text = (IOS / 'Config' / f'{name}.xcconfig').read_text()
    return dict(re.findall(r'^\s*([A-Z_a-z]+)\s*=\s*(.+?)\s*$', text, re.M))


def entitlements(name):
    return plistlib.loads((IOS / f'{name}.entitlements').read_bytes())


class ConfigTests(unittest.TestCase):
    def test_app_and_extensions_share_the_app_group_the_code_uses(self):
        for name in ENTITLEMENTS:
            with self.subTest(name=name):
                self.assertEqual(entitlements(name)['com.apple.security.application-groups'], [GROUP])
        self.assertIn(f'appGroup = "{GROUP}"', (IOS / 'Sources/TodayShared/WidgetSnapshot.swift').read_text())

    def test_the_app_keeps_healthkit(self):
        self.assertIs(entitlements('One')['com.apple.developer.healthkit'], True)

    def test_every_configuration_signs_with_an_existing_entitlements_file(self):
        for target, name in (('Today', 'One'), ('TodayWidgets', 'TodayWidgets'), ('TodayShare', 'ShareExtension')):
            for configuration in ('Debug', 'Release'):
                with self.subTest(target=target, configuration=configuration):
                    entry = settings(f'{target}-{configuration}')['CODE_SIGN_ENTITLEMENTS']
                    self.assertEqual(entry, f'{name}.entitlements')
                    self.assertTrue((IOS / entry).is_file())

    def test_release_app_declares_every_permission_prompt(self):
        release = settings('Today-Release')
        for key in USAGE_KEYS:
            with self.subTest(key=key):
                self.assertTrue(release.get('INFOPLIST_KEY_' + key), 'iOS kills the app when this prompt is missing')

    def test_release_app_cannot_write_health_data(self):
        self.assertNotIn('INFOPLIST_KEY_NSHealthUpdateUsageDescription', settings('Today-Release'))


if __name__ == '__main__':
    unittest.main()
