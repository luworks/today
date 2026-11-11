# Calendar browsed-period header

Owner's November 11 instruction supersedes PR #215's current-device-month rule for Calendar. The clean worker baseline `79b8922bc06c29289dd31cc9389c1d5232b22aad` was fast-forwarded to fetched `origin/main` at `8953465679fdab5fabfa0fded40f03cd0c5466f7` before editing.

The existing top-right label now consumes Calendar's visible range. Month names the committed vertical page, independently of the selected date. Its existing landing-day selection and loading behavior remain. 2 Day names the first visible column's month/year, including a two-column span across December/January. Year publishes the top visible section through native scroll-position tracking and names that year. Its visible anchor survives tab switches without rewriting the selected day. A Year day/month tap still opens the matching Month page. Today opens the actual current day and resets Calendar's anchor. Other tabs keep the current-device-month rule.

The short localized month/year label, full VoiceOver month/year, pill space reservation and Dynamic Type cap remain. Month observes the displayed date rather than only its numeric offset so a changed calendar/time zone/base date republishes its actual page. Existing shell time/foreground refresh remains. No new toolbar, duplicated large Month title or setting was added.

## Verification

- Inspected all three owner screenshots: Apple November 2026, Apple January 2027, and Today with a mismatched November 2026 label.
- Added pure regression coverage in `MonthLabelTests`: December 2026 → January 2027 → December with unchanged selection/clock; full accessible month/year; 2 Day's first-column rule; browsed Year; other tabs; Today reset input; Year-to-Month input. Existing local-time rollover/time-zone and Japanese month formatting coverage remains.
- `./dev format` and final `./dev format --check` passed; `git diff --check` passed. Logs are in the primary checkout's `tests/results/devtools/logs/`, indexed by the QA journal.
- One focused source review checked page publication, tab recreation, Year-to-Month selection, Today reset, initial range publication and retained loading/selection behavior. Initial Month/2 Day publication now uses the restored page rather than briefly publishing the default current page.
- CI-first: no local builds/tests, simulator interaction, phone installation or signing changes. Native scrolling, visual layout and VoiceOver interaction are not empirically verified. The historical axe workflow is explicitly unsupported by the current linked graph; no preview capture is claimed.
- Required GitHub ruleset: `checks` and `today-required`, no required approving reviews. CI result and merge state belong to the PR; this source note does not predeclare them.
