"""Preconnected EventKit journey setup must be explicit and fail closed."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location(
    "preconnected_e2e", Path(__file__).resolve().parents[2] / "ios/Eval/run-e2e.py")
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)


class PreconnectedAccessTests(unittest.TestCase):
    def test_preconnected_journey_requires_both_real_grants_and_propagates_failure(self):
        journal = Mock()
        method = "TodayUITests/TodayReminderCompletionTests/testPreconnectedImportedTimelineStaysResponsive"
        e2e.grant_preconnected_access([method], "owned-id", journal)
        self.assertEqual([call.args[0] for call in journal.action.call_args_list], [
            ["xcrun", "simctl", "privacy", "owned-id", "grant", service, "com.luworks.today"]
            for service in ("reminders", "calendar")])
        self.assertTrue(all(call.kwargs["check"] for call in journal.action.call_args_list))
        journal.reset_mock()
        e2e.grant_preconnected_access(["TodayUITests/JourneyTests/testTabs"], "owned-id", journal)
        journal.action.assert_not_called()
        journal.action.side_effect = subprocess.CalledProcessError(1, "privacy")
        with self.assertRaises(subprocess.CalledProcessError):
            e2e.grant_preconnected_access([method], "owned-id", journal)

