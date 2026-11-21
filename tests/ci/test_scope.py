"""Docs-only pull request scope. No network."""
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.ci.scope import UI_PREFIXES, app_changed, logic_changed  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


class ScopeTests(unittest.TestCase):
    def test_prose_images_prototype_and_backend_skip(self):
        self.assertFalse(app_changed(['docs/qa/run.md', 'README.md', 'ios/README.md', 'docs/qa/a.png',
                                      'src/app.js', 'backend/luna/agent-v1.mjs']))

    def test_anything_read_by_checks_runs(self):
        for path in ('ios/Sources/TodayCore/Logic.swift', 'docs/engineering/tool-pins.json', 'scripts/build.py',
                     '.github/workflows/today.yml', 'tests/fixtures/today-dataset.json', 'dev', 'docs/x.py'):
            with self.subTest(path=path):
                self.assertTrue(app_changed(['docs/a.md', path]))

    def test_unknown_or_truncated_lists_run_everything(self):
        self.assertTrue(app_changed([]))
        self.assertTrue(app_changed(['docs/a.md'] * 300))


class LogicScopeTests(unittest.TestCase):
    VIEW = 'ios/Sources/Features/FeatureToday/DayAgenda.swift'

    def test_view_edits_skip_logic_but_not_the_app(self):
        self.assertTrue(app_changed([self.VIEW]))
        self.assertFalse(logic_changed([self.VIEW, 'docs/a.md', 'ios/Sources/TodayShell/RootView.swift']))

    def test_anything_a_logic_test_can_see_runs_logic(self):
        for path in ('ios/Sources/TodayCore/Logic.swift', 'ios/Sources/One/WidgetFeed.swift',
                     'ios/Sources/TodayShared/WidgetSnapshot.swift', 'ios/TodayWidgets/Next.swift',
                     'ios/ShareExtension/Share.swift', 'ios/Package.swift', 'ios/project.yml',
                     'ios/App/OneApp.swift', 'ios/Eval/Tests/OneLogicTests/A.swift',
                     'ios/Sources/Features/FeatureToday/data.json'):
            with self.subTest(path=path):
                self.assertTrue(logic_changed([self.VIEW, path]))

    def test_unknown_or_truncated_lists_run_logic(self):
        self.assertTrue(logic_changed([]))
        self.assertTrue(logic_changed([self.VIEW] * 300))

    def test_no_swiftpm_test_target_depends_on_a_ui_module(self):
        text = (ROOT / 'ios/Package.swift').read_text()
        opening = r'\.(target|testTarget|executableTarget)\('
        parts = re.split(opening, text)[1:]
        targets = {}
        for kind, body in zip(parts[::2], parts[1::2]):
            name = re.search(r'name:\s*"(\w+)"', body).group(1)
            listed = re.search(r'dependencies:\s*\[(.*?)\]', body, re.S)
            path = re.search(r'\bpath:\s*"([^"]+)"', body)
            targets[name] = (kind, re.findall(r'"(\w+)"', listed.group(1)) if listed else [],
                             path.group(1) if path else f'Sources/{name}')
        self.assertEqual(len(targets), len(re.findall(opening, text)))
        seen, stack = set(), [name for name, target in targets.items() if target[0] == 'testTarget']
        self.assertTrue(stack)
        while stack:
            name = stack.pop()
            self.assertIn(name, targets)
            if name not in seen:
                seen.add(name)
                stack.extend(targets[name][1])
        for name in seen:
            with self.subTest(target=name):
                self.assertFalse(f'ios/{targets[name][2]}/'.startswith(UI_PREFIXES),
                                 'a test target can see this module; update UI_PREFIXES')

    def test_no_test_reads_a_ui_source(self):
        pattern = re.compile(r'Sources/(?:Features|TodayDesignSystem|TodayPlannerUI|TodayShell)/[\w./]+\.swift')
        read = set()
        for base in ('ios/Eval/Tests', 'ios/SceneRegistryTests', 'tests/ci', 'tests/qa'):
            for path in (ROOT / base).rglob('*'):
                if path.suffix in ('.swift', '.py') and path.name != 'test_scope.py':
                    read |= {'ios/' + hit for hit in pattern.findall(path.read_text())}
        self.assertEqual(read, set())


if __name__ == '__main__':
    unittest.main()
