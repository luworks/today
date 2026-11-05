# Past-day Activity facts (#320)

Baseline: 5a8edfeae47508346829238aab48833016e211e9.

Past days project retained Activity observations without consulting current source titles, due dates or completion state. Completed, reopened and undone actions remain separate facts; configuration changes are collapsed. Each row opens read-only recorded details even after its source is deleted. Completion writes retain the due date and new ledger writes retain observation time in additive props. Existing retention, pause and clear paths remain authoritative; no schema or backup changes.

Validation: `./dev test unit --only OneLogicTests/DayHistoryTests`: 12 passed. Durable log: `/Users/yuanlu/code/today/tests/results/devtools/logs/7bbacb22984845f99cadf6c895fc820d.log`. `./dev format` passed. No simulator interaction or physical-device acceptance.

Remaining acceptance: daily scheduled-event/alarm observation snapshots are not yet captured. Past days deliberately omit live schedules with no retained observation, so missing history cannot be reconstructed from current sources. Deleted calendar events retain the existing scheduled-interval evidence; that is not attendance. Details show individual before/after records; cross-day source-status and complete occurrence chains need further work. Do not treat this change as full acceptance of the requested history enhancement or close the Issue yet.
