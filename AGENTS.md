# Working rules

Read `CLAUDE.md` and `ios/README.md` before changing the app. Their product principles remain hard constraints. Reply to Yuan in Chinese; keep code, UI copy, comments and commit messages in English.

## Dev hosts

- The GitHub repo is `luworks/today` (renamed from `luworks/one-app`); the Mac checkout is `/Users/yuanlu/code/today`.
- Agents work on the MacBook Pro: edit code, open PRs, watch CI, run simulator checks, and perform signed device builds and phone installs there.

## Testing: CI owns it

- Do not run builds or tests locally by default. Push the branch, open the PR and let CI (`.github/workflows/today.yml`: `checks` and `today-required`) verify it; merge when both are green.
- Still update the tests a change breaks and add tests for real new behavior. Avoid tests that mirror implementation or check documentation/cosmetic changes. Preserve the behavior being asserted; do not weaken assertions to get green results.
- Run something locally only when the owner asks, when CI cannot do it (phone install, signing), or to reproduce a CI failure its logs do not explain; then run just the failing method with `./dev test ui --only TodayUITests/<Suite>/<Method>` or `./dev test unit`.
- Report what CI ran and what it does not cover (the merge gate does not run the UI journeys).

## Delivery coordination

For authorized multi-task Today iOS coordination, follow [Zhugeliang](docs/operations/agents/zhugeliang.md), including its delegation, optional-role and root-only schedule links. Loading the policy does not activate workers or timers.

## Efficient execution

- Use agents for independent implementation, diagnosis or review when that shortens delivery. Keep ownership clear and avoid multiple agents editing the same files.
- Use one UI simulator runner at a time. Reuse its named simulator and derived-data directory; keep it warm during a short related batch and shut it down when the batch finishes.
- Reuse incremental build caches. Do not run duplicate builds or cold-boot extra simulators merely to increase parallelism. Limit concurrent build/test runners to what the Mac can sustain.
- Diagnose selectors, accessibility types, actual frames and elapsed-time assertions before repeatedly scrolling, retrying or changing product behavior.
- Do not add approval steps for routine reversible work. Ask before force-pushes, branch deletion or signing changes, as required by the owner.

- For supported UI layout, text and color tweaks, prefer the [axe visual feedback workflow](docs/swiftui-preview-workflow.md) when suitable; fall back to the full Simulator if support fails. Do not restructure production logic for axe. Testing follows "Testing: CI owns it" above; coordinate shared resources directly with the performance owner.

## Durable test data and action history

- Keep reusable UI datasets in corresponding files under `tests/fixtures/`. Package-bound resources and small inline inputs remain versioned with their tests; document their locations in the fixture catalog. Never leave a required test input solely in `/tmp`.
- Record development/test actions through the Activity-style QA SQLite journal in `tests/qa/journal.py`. The E2E runner records commands, test outcomes and UI actions automatically; explicitly record additional development actions and Issue/PR links through the same entry point.
- Store generated history and evidence in the primary checkout's `tests/results/`, including when working from a temporary worktree. This local database is separate from the app's user Activity database and must not be pruned or deleted during worktree cleanup.
- Keep raw logs, screenshots, videos and complete `xcresult` bundles as files indexed by SQLite paths and hashes. Archive completed runs coherently; do not move or finalize a live bundle. Imported historical timestamps describe import time; original execution timing remains in the raw logs.
- Version code, fixtures and compact evidence summaries in Git. Runtime SQLite files and large artifacts stay in the persistent results directory. Use `./dev`'s durable default output (the UI adapter retains `ios/Eval/run-e2e.py` as its underlying authority), and retain any explicitly selected temporary output before claiming completion.

### Authorized generated-storage retention

The owner's 2026-10-20 storage-cleanup scope permits the bounded exceptions in
[QA retention](tests/qa/README.md#generated-storage-retention): retired compiler
cache components, and aged, closed raw copies only when a complete hash-verified
journal archive remains. This is not permission to sweep `tests/results`, delete
the journal, remove fixtures/source, prune devices/worktrees, or retire referenced,
pinned, active or uncertain evidence. Use `./dev cleanup` to review and
`./dev cleanup --apply` to apply the same fail-closed policy.
