# Calendar and Today second time zone

The second display zone defaults off. Settings > Today, Settings > Calendar and Calendar's globe button open the same choice. Local times and saved event dates remain unchanged. Selected city identity and enablement are included in preference reset and backup validation.

Today places the remote time beside the local time for timed reminders, events, alarms and Now. Calendar 2 Day widens its hour gutter; when the two visible days differ around DST, L/R labels identify their conversions. Missing local hours show a dash; repeated hours show both conversions. Cross-date labels carry +1 or −1. City selection adds a World Clock entry once, with Undo for a new addition. World Clock offers Show/Hide in Calendar and marks the active city. Turning display off retains the city; deleting that city disables display, and deletion Undo restores it.

## Validation

- `./dev test unit --only TodayTests/CalendarTimeZoneTests --only TodayTests/CalendarDayAxisTests`: 11 passed. Report: `tests/results/devtools/logs/b860329033744095b4beaee860a77a4f.report.json` in the primary checkout.
- Unit test inputs are small inline dates/cities in `ios/Eval/Tests/OneLogicTests/CalendarTimeZoneTests.swift` and `CalendarDayAxisTests.swift`.
- `./dev format` and `./dev lint` passed. Simulator builds through `./dev ui prepare --runtime com.apple.CoreSimulator.SimRuntime.iOS-27-2` passed.
- Device panel on owned Today-Dev-3be3fe6a, iOS 27.2: default off, select London, Today paired rows/Now and Calendar paired hours/+1, automatic World Clock city/badge, Hide from Calendar retaining city and returning Today to a single time column observed.
- A screenshot found the remote Now date suffix wrapping; repaired with single-line adaptive fitting. No functional assertions were weakened.
- Fixture: `tests/fixtures/today-dataset.json`. Mock `-uiTesting` intentionally clears World Clock cities at each launch even when `-uiTestingKeepPreferences` retains display preferences; do not mistake this fixture reset for Live persistence behavior.
- No automated UI suite exists on this revision. Simulator interactions do not establish physical-device interaction acceptance. Physical installation is owned by the root delivery task after merge and main CI.

Raw evidence and development/UI actions are retained under the primary checkout's `tests/results/` and journal session `calendar-dual-zone-20261115`. PR: https://github.com/luworks/today/pull/385.
