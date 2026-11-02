"""Docs-only pull request scope. No network."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.ci.scope import app_changed  # noqa: E402


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


if __name__ == '__main__':
    unittest.main()
