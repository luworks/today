# Existing Calendar event save compatibility — issue #79

Status: superseded 2026-11-03. The owner asked for every Apple Calendar field
(calendar, alerts, travel time, invitees, …) without leaving Today; EventKit has
no API to write invitees or travel time, so existing events now open in Apple's
own Edit Event and the compatibility editor below was deleted. As in Apple
Calendar, its checkmark is grey until something changes; X closes an unchanged
event. The record below is kept as history.

Former status: fixed through the iOS 27 existing-event compatibility entry. Focused build
and simulator journeys passed; the underlying native More Options service is not
claimed repaired. No physical-device acceptance is claimed.

## Retained baseline investigation

- Clean inherited base: `edb7d737710cfae5603dd3ec462c4f04da8ac842`.
- Screenshot is the native EventKitUI editor, not the local SwiftUI `EventEditor`.
- `NativeEvents.edit` presents `EKEventEditViewController` directly; its retained
  delegate dismisses on saved, canceled and deleted completion. The public SDK
  documents unchanged Done as canceled completion. The separate existing-event
  watcher compensates only for deletion; it is not a save-success signal.
- Baseline `EventSaveTests/testExistingNativeEventUnchangedSaveCloses` failed:
  tapping Done left Edit Event visible after five seconds. The failure hierarchy
  includes the remote EventKitUI service and its Done button marked Disabled.
- One focused experiment set the edit delegate before assigning event/store and
  the presentation delegate after presentation. The same regression failed. This
  ineffective production edit was removed; it must not be presented as a fix.
- `EventSaveTests/testExistingLocalEventUnchangedSaveCloses` passed, including
  opening the same local daily event again after saving.
- The initial native changed-title check stopped before saving because its Title
  selector did not match the native field. The observed identifier is title-field;
  the corrected-selector run then timed out opening Edit Event before reaching
  the title edit. Changed-event saving/persistence remains unverified; these are
  harness/entry blockers, not evidence of a failed EventKit save.

The local editor separately uses `try? context.save()` and ignores a nil external
save result. This is a source finding, not a reproduced storage failure and not
an explanation of the screenshot. It was not changed speculatively in this PR.

Do not infer save success from elapsed time, a store-change notification or the
absence of an error alert. Do not dirty an unchanged event merely to enable a
system button, because that can write metadata or notify invitees. A safe next
implementation needs a public supported completion path or a deliberately scoped
editor fallback that preserves unedited EventKit fields and exposes actual save
errors. No signing, schema, migration or phone actions were taken.

Apple's forum has a related iOS 27 native editor report (FB23371618), including
repeat-event scope/cancel problems. It corroborates a platform risk, not the cause
of this app's failure: https://developer.apple.com/forums/thread/835780

## Reusable input and retained evidence

`tests/fixtures/event-save.json` and `ios/OneUITests/EventSaveTests.swift` contain
the versioned input/journeys. The tests use the existing simulator-only EventKit
hooks; they do not access a real user's calendar. All raw logs and complete
xcresult bundles are under the primary checkout:

`tests/results/runs/calendar-save-20261018/`

- `baseline/`: original implementation, native unchanged regression failure.
- `delegate-first/`: harness refused an already booted owned device; no UI test.
- `delegate-first-ui/`: initialization-order experiment, unchanged save failed.
- `changed-and-local/`: local unchanged passed; native title selector failed.
- `native-changed-selector/`: corrected native title-field check.

The QA Activity SQLite journal session is `calendar-save-20261018`; runner events
record commands, test results and indexed artifact paths/hashes. Only the named
Today-EventSave simulator and its independent fixed cache were used. No logic or
full UI suite was run. Physical iCloud/Family calendar save and server errors are
unverified.

## iOS 27 compatibility fallback

The public native editor exposes completion delegates and cancellation, but no
programmatic save/Done API. The original event belongs to the same store assigned
to the controller, and changing delegate initialization order did not help.
Rather than fabricate a change, existing events on iOS 27 now open a small
EventKit-backed form. New events retain the native editor. Earlier iOS versions
retain their existing path.

Done without edits closes without a write. Edited title, timed dates, location
and notes are applied only when changed, to the exact original EKEvent and store;
all other properties are retained. All-day dates show their inclusive calendar
range and remain editable through More Options, avoiding a second implementation
of EventKit all-day conversion. Recurring changes ask this occurrence or all
future events. An event that disappeared is not recreated. Read-only calendars
explain their restriction. EventKit save errors stay in the form with the draft;
failed pending changes on the EKEvent are reset, without dropping the draft.

More Options opens the original native editor by direct UIKit presentation,
retaining alerts, repeat, invitees, calendar, attachments and deletion. It is
available before editing, so unsaved drafts cannot silently be discarded. Native
saved/deleted completion closes the fallback too; cancellation returns to it.
The system's unchanged Done limitation still exists *inside More Options*; Cancel
returns to the working fallback Done. This is a compatibility fallback, not a
claim that the system service was repaired.

Apple API references:
- [Native completion delegate](https://developer.apple.com/documentation/eventkitui/ekeventeditviewdelegate/eventeditviewcontroller(_:didcompletewith:))
- [Explicit EventKit save and error handling](https://developer.apple.com/documentation/eventkit/ekeventstore/save(_:span:commit:))
- [Refresh and deleted-event detection](https://developer.apple.com/documentation/eventkit/ekobject/refresh())

Focused checks retain the original Calendar return/reopen assertions. Test-only
metadata seeds notes, a URL and two alerts to check preservation across relaunch.
A DEBUG-only save failure injection tests error/draft retention; it does not
represent an observed real server failure. Local unchanged save/reopen was already
green and is intentionally not rerun. Physical iCloud/Family behavior, invitations,
recurrence UI and More Options completion remain unverified unless recorded below.

### Focused candidate results

- Source `79df2a7`, `fallback-core/`: build succeeded. Both changed and unchanged
  system-event journeys closed the form, returned to Calendar and reopened the
  persisted event after relaunch. Their added alert assertion then failed because
  SwiftUI combined the LabeledContent accessibility children. The retained screen
  recording/frame visibly shows both alerts, notes and URL intact. This was a
  locator failure after the original completion assertions, not lost event data.
- Save failure/draft retention passed (41.294 s). This is an injected local error,
  not evidence of a real iCloud failure. It is not rerun without a related change.
- A single focused review found the all-day end-date presentation issue. The
  repair keeps all-day date editing in the full native options and shows the
  inclusive date range in the fallback, with a one-day completion regression.
- `fallback-focused-repair/` runs the two failed metadata checks using an explicit
  accessible Alerts value, plus the distinct all-day journey. Results are recorded below.

- Source `bf31d0e`, `fallback-focused-repair/`: build succeeded. Unchanged
  completion, Calendar return, persisted reopen, notes, URL and two alerts all
  passed (50.739 s). Changed test stopped before editing: the recording shows its
  row's center behind the Ask AI footer; tapping opened Ask AI. The final helper
  checks actual frames and scrolls the named day list before tapping.
- The all-day test failed its fixture expectation. Read-only inspection of the
  owned simulator's synthetic CalendarItem found floating start Oct 18 00:00 and
  inclusive stored end Oct 19 23:59:59: the seed created two days. The fallback
  correctly displayed two days. The fixture now converts the original same-day
  timed event with isAllDay, without resetting its end after conversion.
- Failed synthetic events previously survived early test exits. Teardown now
  deletes only each journey's unique title and its exact updated-title variant.
  Final validation is limited to changed save and the corrected all-day input;
  the passing unchanged/failure behavior is not rerun.

## Final regression evidence and delivery

- `0495fa4059e389730dff7b389fbbedd96d4e4629`, clean tree,
  `fallback-final-two/`: incremental build and both UI methods passed.
  Changed-title save closes, returns to Calendar, survives relaunch and reopens
  with notes, URL and both alerts intact (57.080 s). The corrected single-day
  all-day fixture displays only its actual day and completes/reopens with the
  same metadata intact (60.567 s). Teardown cleanup ran successfully.
- Existing timed event unchanged save/reopen plus notes/URL/two-alert preservation
  passed at `bf31d0e` (50.739 s). Later production changes were DEBUG test hooks;
  no unchanged save behavior changed, so this passing journey was not repeated.
- Injected failure keeps the editor, draft title and meaningful error at
  `79df2a7` (41.294 s). The later all-day display, accessibility and test-fixture
  changes do not change that error-handling path, so it was not repeated.
- Local daily unchanged save/reopen remains the earlier 23.458 s passing evidence.
  No logic suite, full UI suite, signing, migration or phone work was performed.
- Runner exit, UI/xcresult/shutdown stages were all 0 for the final batch. Named
  Today-EventSave was shut down and its panel closed at 13:25:22 PDT; actual
  booted/heavy inventories were empty and resources were released directly to
  the performance owner. The same independent cache was reused throughout.

PR81 contains the production fallback, fixtures, five reusable UI journeys and
this compact history. Original failed logs/recordings and complete xcresults are
retained, not overwritten. All evidence lives under the primary checkout's
`tests/results/runs/calendar-save-20261018/` and is indexed in the QA Activity
SQLite journal. iCloud/Family server behavior, invitee delivery, recurrence scope
UI, native advanced save and physical devices remain unverified.
