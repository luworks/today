# Performance tools

Read the [PosterBoard recovery and evidence impact](../../docs/performance/posterboard-recovery-20261018.md) before running any simulator command. This directory contains measurement tools, not a background scheduler.

`compare_app.py` compares deduplicated app-side samples under an identical declared context. `extract_xct_metrics.py` reads XCTest physical-memory and scroll metrics when a method emits them; scroll duration is not FPS or hitch rate. `freeze_source.py` freezes a source revision against an explicit `--paths-file`. Use `with_owned_runner.py`, `simulator_policy.py` and `record_command.py` for owned simulators and journalled commands. Index closed raw logs and complete xcresults through `tests/qa/journal.py`.

`page-metrics-v2.json` is the historical metric inventory for the removed page and AI baseline methods.

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

Keep all generated outputs under primary `tests/results/` and index closed evidence through the existing QA journal.
