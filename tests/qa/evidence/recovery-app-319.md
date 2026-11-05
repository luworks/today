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
