# Current-main page and AI performance tools

Read the [PosterBoard recovery and evidence impact](../../docs/performance/posterboard-recovery-20261018.md) before running any simulator command. The original Today-Performance device is quarantined; use the explicit selection in `simulator_policy.py`. This is a new device context, with boot-only evidence and no Today acceptance yet.

Read [protocol v2](../../docs/performance/pages-ai-protocol-v2.md) and
[complete source inventory](../../docs/performance/page-coverage-v2.md). The old AI
response-stage audit was removed with the old AI pipeline (P4, 2026-11-01).

Production source is frozen `b1fc12b`; measurement revision for the first batch is
`83b4fb8`. Historical package/performance experiments are on separate branches.
This directory contains measurement tools, not a background scheduler.

Freeze before obtaining a quiet window, choosing a new canonical directory:

```sh
python3 tests/performance/freeze_source.py \
  --base b1fc12b62e796ac6c232da5e524235a59edba945 --revision 83b4fb8 \
  --paths-file tests/performance/measurement-paths-v2.json \
  --output /Users/yuanlu/code/one-app/tests/results/runs/performance-pages-ai-20261018/new-frozen
```

The explicit path allowlist rejects unrelated iOS production changes. The
archive, patch and SHA256 manifest are retained beside the frozen source. Never
modify an indexed frozen source/patch to repair a failure; create new evidence.

Obtain the explicit host-holder handoff before boot/build/UI. Reuse only
the active owned simulator from `simulator_policy.py` and the fixed owned DD:
`/Users/yuanlu/code/one-app/tests/results/runs/performance-climb-20261018/derived-optimized`.
Use `with_owned_runner.py` named/cache locks, `record_command.py --session
performance-pages-ai-20261018`, xcodebuild jobs2/parallelNO/Debug -O and the frozen
project path. Build once, then `test-without-building` on the same products for
later methods. A lock does not grant a global quiet slot. Bound each batch to its
agreed deadline, stop producers, shut down and explicitly release the slot.

Initial methods are three page/AI baseline groups, not the full app suite:

- `AIResponsePerformanceTests/testConversationFreshLaunchN3`
- `PagePerformanceTests/testHealthListDetailAndPickerEndpoints`
- `PagePerformanceTests/testClockModesAndCityPickerEndpoints`

Later focused methods on the same compiled revision:

- `AIResponsePerformanceTests/testCaptureFollowupConfirmationFreshLaunchN3`
- `AIResponsePerformanceTests/testPlanConfirmationFreshLaunchN3`
- `PagePerformanceTests/testSettingsSubpageAndActivityEndpoints`
- `PagePerformanceTests/testSearchQuickReminderAndReminderDetailEndpoints`

Do not rerun passing methods without a changed source, failure or concrete gap.
These methods expose only some inventory rows. A completed method does not mark
all pages measured; actual provider, save-success, frame/hitch and memory classes
remain separate pending metrics in `page-metrics-v2.json`.

`summarize_pages.py <closed.log> --output <new.json>` keeps raw samples by method,
name and backend, deduplicates repeated app/test stdout, reports n/median/range
and leaves p95 unknown. Incomplete/failed functional methods cannot produce an
accepted baseline. Read context and raw ordered samples: the initial page
sequence is first cycle plus two revisits; AI uses three fresh process launches.
Never compare rules/fallback with model generation or typing-inclusive XCTest
elapsed time with app-side intervals. Goals baseline/3 and baseline/10 are not gains.

`compare_app.py` retains the earlier same-context app-proxy comparison; use
`extract_xct_metrics.py` only when a method actually emits XCTest physical-memory
or scroll metrics. Scroll duration is not FPS/hitch rate; in-memory save UI is
not disk persistence. After producers exit, index closed raw logs, contexts,
source manifests and complete xcresults through `tests/qa/journal.py`.

Focused pure-tool validation:

```sh
python3 -m unittest discover -s tests/performance -p 'test_*.py' -v
```


## Historical first baseline utilities

The original [protocol](../../docs/performance/protocol.md), [static inventory](../../docs/performance/static-audit.md) and [2026-10-18 report](../../docs/performance/baseline-2026-10-18.md) retain their original source/configuration and automation-inclusive limitations. They are historical evidence, not replacement current-main measurements; use the v2 protocol/results above for page/AI comparisons.

- `inventory.py`: file categories/top contributors and local ZIP estimate for a built app.
- `launch_probe.py`: simulator process launch probe; do not equate its duration to usable content.
- `memory_sample.py`: simulator memory sampling proxy.
- `summarize.py`: original automation log reducer, separate from monotonic app-side reducers.
- `ios/OneUITests/PerformanceBaselineTests.swift`: original authored baseline journeys. Their historical results do not establish new merged-main runtime acceptance.

Keep all generated outputs under primary `tests/results/` and index closed evidence through the existing QA journal. No new build or repeated passing UI run is required for this documentation merge.
