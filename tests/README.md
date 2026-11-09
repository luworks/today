# Test assets and evidence

Keep reusable datasets in `tests/fixtures/` and QA journal fixtures/tools in
[`tests/qa/`](qa/README.md). Test evidence must persist under the primary checkout's
`tests/results/`; the SQLite Activity journal and raw/large outputs are Git-ignored.
Commit selected human-readable evidence summaries under `tests/qa/evidence/`.

Older `/tmp` runs can be checkpoint-imported while active and archived
only after completion; see [the journal CLI and schema contract](qa/README.md).
No test/development journal writes to the application's Activity database.
