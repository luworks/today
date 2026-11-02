# Every-page and AI performance baseline protocol v2

Production baseline is root-selected current main `b1fc12b62e796ac6c232da5e524235a59edba945`.
Historical `fc683a7`/`3db91dd` measurements stay historical; they are not current AI results.
This branch carries measurement-only differences. Production size/audio/Year/Activity candidates
from the earlier climb are not silently included. Exact source and measurement diff are frozen
before building; later main changes form a different cohort.

## Coverage and acceptance

The scope is every reachable page, meaningful modal/subpage and common operation, not merely
four top-level tabs. The source inventory is [page-coverage-v2.md](page-coverage-v2.md).
Each row progresses through inventoried, instrumented, executed, valid baseline, candidate,
matched comparison and accepted/rejected. A page visited by a test is not automatically measured.
Unexecuted, failed, unsupported and not instrumented are distinct states, never zero latency.
Avoid destructive data/permission flows; their safe simulator fixture path remains explicitly pending.

Each valid cohort retains configuration, optimization, SDK/runtime, model/device/UDID, actual
source/instrumentation SHA, fixture hashes, clock, backend, cold/warm state, host load/processes,
method, repetitions and raw artifact paths/hashes. Use optimized Debug `-O`, normal DEBUG fixture
guards, pinned09:41, Today-Performance and its existing DD. App/host/Release-size tracks remain
separate. No PERFORMANCE flag, signing setting change, phone work or user-data deletion.

Latency required target is baseline/3, stretch baseline/10. Memory/bytes required target is
49% of baseline. Start with n3 meaningful repetitions (up to5 where useful), median/range/raw;
no small-n p95. Keep first-use and repeated-use samples distinguishable. The initial page methods retain one first cycle plus two revisits in order; report this fixed mixed sequence explicitly rather than calling it a homogeneous warm-cache cohort. AI methods use three fresh process launches with fixed per-journey history. A failed functional
journey cannot provide accepted performance evidence. Do not move endpoints, omit required work,
change backend or remove features to manufacture gains. Recheck correctness after each candidate.

The immediate priority is user latency: AI feedback/response, page transitions, create/complete,
search, open and explicit Add/Apply. Record scroll/render work and app memory separately where
available; automation duration is not FPS/hitch rate. Memory delta alone is not a leak test.

## AI stages

The AI source audit covered the old pipeline (removed in P4, 2026-11-01; see git history). Track send→feedback layout, response ready→layout,
and full turn→response/card layout independently with monotonic per-turn tokens. Superseded or
cancelled turns do not complete successful samples. Explicit capture, clarification, conversation,
plan preview and confirmed Add/Apply have different cohorts. Preserve title/type/day/time, no-write
before confirmation, isolation, Undo and persisted state behavior.

Current one-shot code does not stream visible tokens. The first displayed answer and full answer
therefore share an emission; a separate time-to-first-token value is unavailable, not zero.
Backend labels distinguish rules, unavailable-model fallback and model-available/outcome-unknown.
An available model flag does not prove inference succeeded when APIs hide timeout/fallback outcome.
Simulator fallback measurements never establish Apple Intelligence generation latency.

Apple recommends discrete interaction work under100ms and main-thread screen-update work around5ms;
these are platform guidance, not competitor measurements. Feedback≤100ms is an initial product goal.
Full AI generation has no invented Apple-guaranteed duration; relative3x/10x targets require the
same backend, prompt/history and result semantics. Profiling identifies the next candidate; potential
streaming, session reuse or prewarming stays a hypothesis until a measurable supported backend exists.

## Execution and evidence

Prepare source, command and named-device/DD ownership before obtaining a fresh approximately10min
quiet window from compatibility. No design work consumes a granted slot. Build once with jobs2,
then run only selected methods serially without building, split into bounded batches. Keep the named
simulator warm only within a related batch. Stop producers, retain complete closed artifacts, shut
down the owned simulator and explicitly release to root/compatibility before another lane runs.
Do not retry the previous failed Year profiler diagnosis as part of this new page/AI baseline.

Canonical evidence root is primary `tests/results/runs/performance-pages-ai-20261018/`; the separate
QA SQLite is indexed through `tests/qa/journal.py`. Version protocols, fixtures, reducers and compact
summaries; retain raw logs/xcresults/manifests in canonical evidence. Required inputs are versioned,
never solely temporary. Frozen source archive plus explicit measurement path allowlist prevents
unrelated production optimizations from entering the baseline.

## Official guidance checked 2026-10-18

- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- [Optimizing key-value caching in language model sessions](https://developer.apple.com/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions)
- [Improving your app's performance](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance)

No authorized same-protocol competitor run exists. Top-app numeric gap remains unknown; platform
budgets and owner stretch goals are labeled separately from actual measurements.
