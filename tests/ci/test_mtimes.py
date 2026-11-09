"""Content-derived modification times. No network."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.ci import mtimes  # noqa: E402


class StampTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        subprocess.run(['git', 'init', '-q'], cwd=self.root, check=True)
        (self.root / 'ios/Today.xcodeproj').mkdir(parents=True)
        (self.root / 'ios/View.swift').write_text('a')
        (self.root / 'ios/Today.xcodeproj/project.pbxproj').write_text('p')
        (self.root / 'ignored.log').write_text('x')
        subprocess.run(['git', 'add', 'ios/View.swift'], cwd=self.root, check=True)

    def mtime(self, name):
        return os.stat(self.root / name).st_mtime

    def test_same_content_same_time_and_generated_project_included(self):
        mtimes.stamp(self.root)
        first = self.mtime('ios/View.swift'), self.mtime('ios/Today.xcodeproj/project.pbxproj')
        os.utime(self.root / 'ios/View.swift')
        mtimes.stamp(self.root)
        self.assertEqual(first, (self.mtime('ios/View.swift'), self.mtime('ios/Today.xcodeproj/project.pbxproj')))

    def test_changed_content_changes_the_time(self):
        mtimes.stamp(self.root)
        before = self.mtime('ios/View.swift')
        (self.root / 'ios/View.swift').write_text('b')
        mtimes.stamp(self.root)
        self.assertNotEqual(before, self.mtime('ios/View.swift'))

    def test_folders_are_fixed_and_times_are_in_the_past(self):
        mtimes.stamp(self.root)
        self.assertEqual(self.mtime('ios'), mtimes.EPOCH)
        self.assertLessEqual(self.mtime('ios/View.swift'), mtimes.EPOCH)

    def test_untracked_files_are_left_alone(self):
        os.utime(self.root / 'ignored.log', (1000, 1000))
        mtimes.stamp(self.root)
        self.assertEqual(self.mtime('ignored.log'), 1000)


if __name__ == '__main__':
    unittest.main()
