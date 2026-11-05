# PR319 application integration evidence

Implemented Settings folder selection, bookmark persistence, automatic debounced
SQLite snapshots, conflict pause, explicit next-launch restore and shared preopen
activation in OneStore. Merged main 5a8edfe; Live remains free of SampleData.

Native local integration: BackupRoundtripTests/productDatabaseHistoryAndPreferencesSurviveTwoOpens
passed (one test). Calls the product payload exporter; includes reminder title,
note and source identifier, chat title, Activity history and a preference, restored
to a new directory and opened twice. Also rejects empty/unacknowledged publication
and corrupt current archive. It does not exercise a real file provider or EventKit.
Report and full xcresult:
`/Users/yuanlu/code/today/tests/results/devtools/logs/f7c18b0510fc4deb8d159ffa8819dc1d-xcode/`.
The test build initially failed on a missing inner `try` in a Testing macro; fixed.
An earlier attempt was refused because device_open had booted the owned simulator;
closed/shut down that owned session before the successful run. No foreign lock removed.

Live app build passed. Installed and launched on owned Today-Dev-b740a08d via
agent-device. System Health permission UI blocked navigation. AX snapshots first
reported remote-content-boundary, then circuit-disabled after one screenshot-guided
swipe; stopped device driving per tool policy. Settings/picker UI acceptance is
UNKNOWN. This is no phone interaction, iCloud upload or uninstall/reinstall evidence.

Remaining acceptance: directory grant/save/status UI, full staged activation journey,
source reconcile without recreation, and offline/quota/account-transition behavior.
Keep PR draft and Issue317 open. Reinstall requires reselecting the same folder.

## Focused review fixes (2026-11-04)

All three blocking findings from the single focused review are addressed:
- ActivityCenter.clear synchronously invalidates staged restore metadata before
  clearing, including Ledger.clearAll and DataReset.run callers. A session hook
  cancels queued backup work even while publication is suspended. Existing local
  stores and immutable remote generations are retained; local Clear does not
  promise removal of cloud backup history.
- Staging persists generation, account and bookmark binding. Preopen activation
  requires the same binding/current head and byte-identical validated candidate,
  opens both databases and strictly validates preference object/key types before
  changing preferences or active path. Only successful activation acknowledges G.
  A fresh controller reloads the acknowledgment; Retry can resume publication.
  Pending preparation remains a publication pause even when Retry is used.
- First publication includes lists, Activity and explicitly persisted allowlisted
  preferences (including world-clock cities); registered defaults do not count.
  An empty store and an unacknowledged existing head remain protected.

Final focused native integration command:
`./dev test integration --only TodayTests/BackupRoundtripTests/controllerRestoreLifecycle --timeout 600`
Result: passed, one sequential product test with history/list/preference/empty
cases, real controller select/stage/activation/Retry and SQLite databases; includes
Clear History, DataReset, restored reminder edit/new head, changed-head refusal,
and invalid preference type refusal. Uses isolated defaults/domain, restore root,
identity and a package-local folder transport seam; no production user data.
Final report, raw logs and complete xcresult (automatically journal indexed):
`/Users/yuanlu/code/today/tests/results/devtools/logs/4fa23b7f9a1d40f88337dc77d3856702-xcode/`.
`./dev format` and `git diff --check` passed. Native build used local Xcode 27.2
(27B52), whereas repository pins are 27.1; hosted native CI remains authoritative.
Earlier evidence includes an invalid selector, zero-test selection, a meaningful
failure repaired in the defaults/binding seams, and a behavior pass rejected by
source_changed_during_test; none is substituted for the final passing report.

No additional independent review, full UI suite, Health retry, phone/account/
signing operation, or payload-only roundtrip rerun was performed. Real file
provider/bookmark behavior, EventKit reconciliation, physical reinstall/iCloud,
background final-write completion and app/intent runtime acceptance remain
UNKNOWN. The new-head regression invokes Retry after editing the restored store;
it does not establish background debounce completion under suspension. PR remains
draft and Issue317 open; root must check exact pushed-head CI before any merge.
