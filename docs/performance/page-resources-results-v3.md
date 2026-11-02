# Page resource results v3

## Decision and context

A new resource baseline is established for eight page states, plus a separate native Year scrolling memory test. It is not a measured memory improvement and does not complete every-page resource coverage. Production reference `5767d81c767ffec43e328aeaa6d974b3507e3c30`, measurement `64a3de9`, optimized Debug `-O`, Xcode27.1, iPhone18ProMax/iOS27.0 simulator, same Today-Performance/derived-optimized cache, jobs2/parallelNO. Dataset today-dataset.json SHA256 `e91a99f1a16eabdad31b2f8c7e3bff7bf20f058713945964f8fdc684a9ba31c7`, in-memory store,09:41, Health samples; first cycle plus two ordered revisits in each method, one process per method. Exact commands, host load/hardware/process snapshots and frozen source manifest remain canonical.

Build once and Year native method PASS39.554s. Reused Products/test-without-building: Clock PASS100.206s, Health PASS88.859s. No retries or physical-device operations. Simulator shutdown and Device-panel close completed; booted/heavy executable readback empty. Resources then handed directly to the queued reminder-completion worker; Settings is not silently added.

## Sampled whole-app memory while each page is visible

The values are app-wide `TASK_VM_INFO.phys_footprint`, not exclusive bytes allocated by a page. Each visit value is the median of the fixed1s post-layout window sampled about100ms on a separate queue. Three ordered visits are descriptive first/revisit states, not independent identical cold samples. Sampled operation maximum may miss short peaks; it is distinct from the native peak below. Confidence is moderate for these simulator windows, low for extrapolation to device budgets or the feasibility of a51% reduction. No p95 is estimated.

| Page state | Visit1 /2 /3 window medians MiB | Visit3 sampled operation max MiB | Visit1→3 MiB | Proposed visit3 goal MiB (−51%) | Remaining MiB |
|---|---|---:|---:|---:|---:|
|clock.alarms|96.28 / 96.54 / 97.55|97.60|+1.27|47.80|49.75|
|clock.cityPicker|86.10 / 90.60 / 90.25|90.44|+4.16|44.22|46.03|
|clock.stopwatch|86.85 / 89.91 / 90.03|90.16|+3.19|44.12|45.92|
|clock.timer|89.08 / 90.66 / 90.83|90.83|+1.75|44.51|46.32|
|clock.worldClock|82.58 / 90.72 / 89.70|89.78|+7.12|43.95|45.75|
|health|85.80 / 95.06 / 96.31|96.35|+10.52|47.19|49.12|
|health.detail|94.67 / 97.33 / 97.78|98.10|+3.11|47.91|49.87|
|health.picker|98.46 / 99.52 / 99.31|99.71|+0.86|48.66|50.65|

All26 captured windows were valid (including two one-off launch windows);24 windows form eight complete same-PID three-visit page groups. Negative growth would be retained; observed positive changes are not proof of leakage, and no equivalent returning-anchor retention window was measured. VM failures/truncated responses would be explicit missing data, not zero. Final timer callbacks after the window deadline are retained raw and excluded from window statistics.

## Native Year metrics and missing hitch provider

Native XCTest metrics target the app, not the runner. Three measured fast-upward gestures follow one discarded warmup; downward reset occurs after stopMeasuring. The original units and negative physical delta remain unchanged. MiB conversions below explicitly assume the printed kB is decimal1000 bytes. This is a small fixture/gesture baseline, not dense data, long-session retention, FPS or energy evidence.

| Native metric | Raw n3 kB | Median kB | Derived median MiB | Proposed positive-value goal kB (−51%) |
|---|---|---:|---:|---:|
|physical_delta|-19103.744, -1949.696, -13631.488|-13631.488|-13.000|not applicable to negative growth|
|absolute_physical|218991.280, 208767.664, 215108.272|215108.272|205.143|105403.053|
|peak_physical|249744.048, 221334.192, 237783.728|237783.728|226.768|116514.027|

`XCTHitchMetric(application:app)` was requested, but **no hitch metric was returned** in either the raw log or closed xcresult metrics export. Actual returned IDs were only physical delta, absolute physical and peak physical. Hitch count/time/ratio and frame rate remain **missing, not zero**. SDK API availability does not identify why this provider omitted metrics. No equivalent rerun was made and no scroll duration or display-link spacing is substituted for hitch data. Apple’s [render-loop guidance](https://developer.apple.com/videos/play/tech-talks/10855/) treats below5 hitch ms/s as good,5–10 as needing investigation and above10 as materially disruptive. This is a platform reference, not a measured top-app competitor; the missing provider means the current gap to that target cannot be quantified.

## Gaps and next actions

- P1: Year native peak median226.768MiB is the highest measured app-state resource value in this batch; a51% target is111.116MiB, not an achieved or proven feasible reduction. Source diagnosis should identify a removable allocation/lifetime cost before an optimization. Risk is retained state/render correctness; acceptance needs matched fixture/gesture/config and unchanged functional assertions. Do not compare it as the exclusive cost of Year against the different Health/Clock processes.
- P1: Health/Clock revisit increases are measurable but allocation/lifetime attribution is absent. Complete Settings/Activity and shared root-anchor windows using the same protocol before choosing a retention candidate. Expected benefit is closing coverage/attribution gaps, not promised byte savings. Reuse the existing build; one narrow resource batch, no broad suite.
- P2: Native hitch provider is missing. Preserve the capability gap; no FPS/real-device/real-touch or battery claim and no phone work assigned to the owner. An alternative simulator instrument must prove actual frame/hitch semantics before being used.
- The AI source/CPU diagnosis covered the old AI pipeline, which P4 (2026-11-01) removed; its report is in git history. Existing accepted full-layout gain remains2.024x, below3x, independent of this resource cohort.

## Reproduction and evidence

Follow [protocol v3](page-resources-protocol-v3.md). Canonical primary root: `tests/results/runs/performance-pages-ai-20261018/`. Raw logs `page-resources-year-v3-41d456a6.log` and `page-resources-health-clock-v3-d0712990.log`; exact `*-command.json`; closed `page-resources-{year,health-clock}-v3/ui.xcresult`; `staged-source-page-resources-v3/manifest.json`; native metrics/provider JSON and closed metrics export; sampled summary `page-resources-health-clock-v3-summary.json`. The raw payloads preserve byte values, timestamps, sample gaps, counts and errors. Six meaningful reducer checks passed; functional method success alone is not enough for a usable resource group. QA journal records/indexes this batch separately from app user Activity.
