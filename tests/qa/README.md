# QA Activity journal

`journal.py` uses Python's standard library and the app's exact v1 SQLite migration,
checked against `ios/One/ActivityStore.swift` by a host test. This is a separate QA
file, never the app's database or real user data. WAL, foreign keys, transactions,
a 10-second busy timeout and `user_version` follow ActivityStore. A newer schema
is rejected. The SQL fixture must be updated deliberately with the source contract.

Default storage resolves `.git` and `commondir` without subprocesses to the primary
checkout: `tests/results/activity.sqlite`. Raw evidence and the DB are locally
persistent and Git-ignored; fixtures, code, schema, docs and selected readable
summaries belong in Git. Do not clean `tests/results` as disposable build output.
Back up the database through SQLite's backup API (or after closing writers), not
by copying a live SQLite file without its WAL.

```sh
python3 tests/qa/journal.py record dev-20261018 qa.development 'Read ActivityStore migrations'
python3 tests/qa/journal.py record dev-20261018 qa.command.started 'python3 -m unittest discover -s tests/qa'
python3 tests/qa/journal.py record dev-20261018 qa.ui.operation 'Tap Today tab'
python3 tests/qa/journal.py record dev-20261018 qa.link 'https://github.com/owner/repo/pull/123'
python3 tests/qa/journal.py import /tmp/today-overnight-20261018 --session overnight-20261018
# Only after the runner has stopped and its actual exit result is known:
python3 tests/qa/journal.py import /tmp/today-overnight-20261018 --session overnight-20261018 --status failed --archive
python3 tests/qa/journal.py query --session overnight-20261018
mkdir -p /Users/yuanlu/code/one-app/tests/results/exports
python3 tests/qa/journal.py export --session overnight-20261018 > /Users/yuanlu/code/one-app/tests/results/exports/overnight-events.jsonl
```

The archive command above is an example, not a declaration that the run failed.
Completion status is always explicit; neither success markers nor a partial
`summary.json` decide the run result. A checkpoint is `running`, only imports
newline-terminated test/UI records and command metadata, and never reads/copies
an active xcresult. Repeated identical lines at different byte offsets remain
separate attempts; the same source/offset/bytes import is idempotent. Changed bytes
produce another immutable record.
Imported events' `ts`, `tz` and `day` are the time of import, not historical
execution timestamps. A session-scoped `qa.import.provenance` event explicitly tags
`timestamp_basis=import_time` and `raw_log_timing=unparsed` (including previously
checkpointed events). Original timing is retained in verbatim raw logs; no
historical clock accuracy is claimed. This implementation does not parse log times. Reusing a manual UID with different data fails.

Final `--archive` copies every regular file (including files inside xcresult,
screenshots, raw logs and reports), checks SHA-256, indexes its path/hash/size,
and keeps prior revisions under `tests/results/archives/<session>/<manifest-hash>/<relative-path>`.
Every revision retains one coherent source tree, so an xcresult bundle stays together.
The manifest hashes relative paths, sizes and per-file SHA-256 values; the
`qa.archive` snapshot stores this manifest and its content identifies the revision
root. Files are enumerated before copying, archives live outside `runs/`, and
nested destinations are rejected. It never moves or deletes the live source. The caller must stop writers before
archiving. Symlinks are excluded. Large bytes stay outside SQLite; artifact metadata
is in `snapshot` and the file path is in `content`. Existing retained files are
hash-checked, never silently overwritten with changed bytes.

Events use `actor=agent:Codex`, `channel=qa`, a session and subject reference,
UTC milliseconds, local offset/day, immutable UID, tier 4 (the app maps unknown
`qa.*` kinds to system). Commands/actions/links/result detail live in `content`;
`props` contains only structured statuses, exit codes, byte counts and hashes.
`qa.run`, `qa.command.*`, `qa.test`, `qa.ui.operation`, `qa.artifact`,
`qa.development` and `qa.link` distinguish actions without another event schema.
Manual `record` accepts event text, status and optional idempotency UID; it does
not execute the command. Only explicitly supplied issue/PR links are recorded.

The runner writes live command starts/completions, test starts/results and XCTest
UI-operation lines. Its `finally` records shutdown/result and indexes finished
files; journal failures print separately and populate `summary.json.journal_errors`
without replacing a valid test failure exit code. Completed external `--output`
files are automatically copied to a coherent `archives/` revision via
`Journal.archive_files`, without reimporting live-recorded test events. Outputs
already inside canonical `tests/results/` are indexed in place without recopying.
The shared UI classifier includes Press, Drag, Pinch, Rotate and Click, and links
operations to the current test. Legacy checkpoint operation rows stay immutable;
additive `qa.ui.subject` rows associate their UID (content/props) with a test
subject reference without duplicating the original operation. An explicit runner `--output`
can be elsewhere, but its journal remains canonical. `--help`, `--inventory`, and
`--dry-run` open no DB, create no evidence and launch no subprocess.

Useful SQL (read with Python sqlite3 or `sqlite3 tests/results/activity.sqlite`):

```sql
PRAGMA integrity_check;
PRAGMA user_version;
SELECT session, kind, count(*) FROM event GROUP BY session,kind;
SELECT e.id,e.kind,e.subject_ref,json_extract(e.props,'$.status'),c.after_txt
FROM event e JOIN content c ON c.event_uid=e.uid
WHERE e.session='overnight-20261018' ORDER BY e.ts,e.id;
SELECT e.uid,s.data FROM event e JOIN snapshot s ON s.event_uid=e.uid
WHERE e.kind='qa.artifact';
```

Focused host checks (no Swift, Xcode or devices):

```sh
python3 -m unittest discover -s tests/qa -p 'test_*.py'
python3 -m unittest discover -s ios/Eval -p test_e2e_runner.py
```

## Generated-storage retention

The owner's 2026-11-09 cleanup decision makes retired closed QA output and build
caches disposable. This replaces the older archive-before-delete/latest-lane
policy. Code, reusable fixtures, app/user databases, source recovery bundles and
active work are outside this scope.

`./dev cleanup` is a read-only dry-run. `./dev cleanup --apply` rechecks the plan
under nonblocking host/cache/name locks, records per-file hashes and committed
journal tombstones, then unlinks only the inventoried paths through no-follow
file descriptors. Open files, changed manifests, live/reused PIDs, held locks,
unknown ownership, control aliases and uncertain source revisions fail closed.
No device, simulator, service, source worktree or app container is stopped or reset.

[`retention.json`](retention.json) sets:

- **3 days** for passed, failed/interrupted closed runs and retired derived-data
  components. New content and recent owner-lock activity count toward age.
  Existing owner directories, repository aliases and registered worktrees remain
  protected, including queued/nonterminal work without a PID or held lock. Automatic
  maintenance requires a missing, unregistered owner and an absent recorded PID;
  PID/lock inactivity alone cannot prove a surviving task finished. A separate
  authorized one-time cleanup may use actual platform task-state evidence.
- **20 GB** of inventoried retired closed generated files, measured by directory
  allocated bytes. If this soft budget is exceeded, remove the oldest safely
  retired copies first, including younger disposable copies. It is not a
  physical disk quota: APFS shared blocks can make actual reclamation smaller;
  active/existing-owner/unknown roots are reported without walking their build trees; explicit
  pins and source-revision uncertainty are never overridden by budget pressure.
- **30 days** for cleanup manifests; young audit records cannot be budget-evicted.
  Compact QA journal history and control locks remain. This QA database is separate
  from the application's user Activity database and is never pruned here.

Managed derived-data components include Intermediates, Products, Logs,
TestResults, SourcePackages, release maps, compiler/module/index/SDK caches.
SourcePackages must be unchanged dependency code at exact revisions from the
controlled `ios/Dependencies/Package.resolved`. Remote proof uses only its trusted
HTTPS URLs (no credentials, query or fragment), is delayed until a SourcePackages
candidate is actually selected, and is reused per URL for one cleanup pass.
Dirty checkouts, external worktrees/shared common Git directories, unrecognized
revisions/refs or unavailable proof preserve that
component and report why; they do not preserve its unrelated compiler siblings.
Git probes set `GIT_OPTIONAL_LOCKS=0` so a dry-run does not refresh vendor indexes.
Historical `one-app` owner paths retain their original lexical identity after the
repository alias became `today`.

Closed raw runs under `runs/` (or an explicitly journaled top-level generated run)
need a final summary, matching latest journal closure and retired owner. They do not need a second
large archive, and the latest selector lane is not exempt from expiry. Completed
journal archives, individual old devtools logs and invocation/device receipts with
closed journal ownership also expire independently after their owner retires.
Old ownerless records remain protected. Ad-hoc output without a closed summary/ownership record is
reported as unmanaged rather than guessed disposable; new scripts should use the
same run summary and journal protocol instead of inventing untracked output roots.
Unknown children inside the fixed `runs`, `archives` and `devtools` namespaces
(including unmatched derived-data identities) are also listed in `unmanaged_paths`.
This report enumerates only directory names at fixed levels and never walks unknown
content or changes its deletion eligibility.

Default pins are empty and historical document/Issue links do not retain generated
bytes indefinitely. Set `pins` deliberately for a particular future proof. Generic
name pins apply to candidate/ancestor names; they do not match SDK/header descendants
such as `Debug-iphonesimulator`, `CMHeadphone*` or `NSAutoreleasePool.h`. An anchored
path pin can still retain a particular descendant. `retain_references: true` opts
back into current document/open-Issue protection when a task explicitly needs it;
failed retrieval then stops cleanup. Protected/unmanaged paths, oldest candidate,
budget excess and reclaimed byte counters remain visible in cleanup results.

Automatic best-effort maintenance runs **before and after** normal `./dev build`,
`generate`, `resolve`, `test`, `check`, `benchmark`, `ui` and `release` commands. The
pre-hook can collect retired output from a previous invocation before this invocation
acquires its build locks; the post-hook runs after the authority releases locks.
A busy host, invalid policy, import failure or maintenance failure produces a skip
message and cannot replace the requested command's exit code. There is no daemon,
timer, extra T3 schedule or cleanup inside a running authority. `automatic: false`
disables these hooks; dry-run/apply remain explicit entry points.
The executable explicitly enables maintenance. Imported `cli.main()` defaults to
maintenance disabled, including when tests use its default source root; synthetic
hook tests must opt in with an isolated temporary root.

The policy starts working only when the invoking checkout contains this revision
of `./dev` and the retention module. Merging alone does not update another active
checkout. Adopt at a safe clean boundary; do not reset another owner's work.

`uv run --no-project python -m unittest discover -s tests/qa -p 'test_*.py'`
exercises the host QA collection using temporary synthetic trees
(no Swift build, simulator or user data). Retention regressions cover live locks,
PID reuse, source edits, source authority/URL validation, exact hardlink/symlink
boundaries, changed files, budget pressure, raw closure, alias identities, bounded
scan/remote-query counts, queued owners, complete empty app-directory removal,
default-root import isolation and both command hooks' failure propagation.
