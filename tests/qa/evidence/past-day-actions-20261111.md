# Past-day actual-action history

Issue: https://github.com/luworks/today/issues/378

Baseline: clean prepared worktree safely fast-forwarded to `8953465679fdab5fabfa0fded40f03cd0c5466f7` before edits.

Owner contract: past-day Today history is a record of actions, not scheduled appointments. This supersedes the earlier retained-plan primary-row contract.

- `DayHistory.facts` contains only the viewed day's recorded actions, at `ActivityEvent.date`, preserving each UID/title/actor/channel. Completion, Stop, reopen and Undo are primary; other actions stay under Changes.
- Bare observations and deleted-event intervals never create rows, including all-day/anytime plans and late observations. A plan-only day says "No recorded actions".
- Each action retains separate occurrence context through explicit subject/anchor/move/Undo links. Later outcomes annotate the original fact without removing it or collapsing other actions. Missing occurrence evidence stays unknown.
- The DayAgenda live-model history fallback was unreachable behind the past-day early return; it is removed. Today/future planning retains its prior behavior, including alarm occurrence construction. Calendar schedule code, PR376 scrolling/dragging and PR377 files are untouched.
- Activity storage, observations, pause/retention/Clear/backup and write authorization are unchanged. Legacy context summaries remain available; they do not supply rendered actions or emptiness.

Validation: `./dev format` and `git diff --check` passed. Updated existing occurrence/detail tests and added production `DayHistory.load` regressions for cross-day postponement, later move/delete/reopen/Undo, repeats, actor/channel preservation, deleted-calendar attendance uncertainty, deleted alarms with and without occurrence anchors, and empty days. Existing CI runs the logic collection plus app/test-bundle builds. Local builds/tests were not run under CI-first policy. No simulator, screenshot parity, installation or physical-device acceptance is claimed.
