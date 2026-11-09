# Today test contract

`groups.json` is the authoritative group-to-selection manifest for `./dev` and CI. `scripts/testing/contract.py` implements the same
source inventory, expansion, identity normalization and fail-closed reporting.
No production, package, Xcode generation, CI or `./dev` configuration is changed
by this lane. Integration must wire those entrypoints to this contract.

## Integration API

From repository root, these operations are host-only and read-only:

```sh
python3 scripts/testing/test-contract.py inventory
python3 scripts/testing/test-contract.py plan --group snapshot
python3 scripts/testing/test-contract.py plan --group release
```

The plan is JSON schema version 1: `project`, `selectors` by lane, `pending`, and `inventory_is_execution=false`.
Selections contain every expected method, not aggregate suite counts.
`--group` repeats to form a deduplicated union. Unknown groups/selectors fail.
The plan is an execution contract, not a claim that a named `.xctestplan` exists.
Do not maintain another group table in `./dev` or CI. A Python consumer may import
`contract.plan`, `contract.inventory`, `contract.xcresult_attempts`,
`contract.log_attempts`, and `contract.report` from `scripts/testing`.

`migration.original_inventory` preserves the base's original suite/method/path/line
names (75 logic suites / 661 methods). The baseline
is `bc32cee41e5b87386df571fd7f6caa61671bbe7d`. Source additions naturally join
wildcard groups; compact groups reference exact existing methods. Source scanning
handles XCTest and Swift Testing declarations, attributes, extensions and top-level
`@Test` functions. This is source inventory, not compiler/runtime discovery; unsupported
conditional or generated declarations must remain a missing coverage failure until
explicitly resolved. Do not silently reduce the expected set to observed tests.

## Groups and acceptance gaps

- `unit`: all current pure-logic tests, XCTest or Swift Testing.
- `integration`: existing Calendar, Reminders and event-save UI boundaries.
- `snapshot`: three existing screenshot journeys. Image-reference comparison is pending.
- `release`: union of unit/ios-unit/integration/snapshot; pending physical-device gates
  remain visible. Only parent integration may execute the authorized full suite,
  once at its final frozen revision. A group definition grants no run authorization.

`pending` is an acceptance gap, not a fictional executable test. A passing report
with `coverage_status=pending` does not establish snapshot, accessibility, device
or release acceptance.

## Reports and evidence

The runner retains raw stdout, completed xcresult bundles, `xcresult-summary.json`,
`xcresult-tests.json`, and per-skip `xcresult-test-details-*.json` with stderr logs.
UI log records are progress only; completed structured xcresult leaves decide UI
execution. Modern `test-results tests` JSON and legacy typed leaf JSON are parsed;
Swift Testing and XCTest identities normalize to the selected target. SwiftPM
console outcomes use individual XCTest/Swift Testing records, never summary counts.
Suite-free Swift Testing names resolve only when unique in expected methods.
A failed first attempt stays failed even if a later attempt passes. There is one
xcodebuild test iteration, no runner retry or automatic narrowed rerun.

For externally owned CI execution, retain the original files and pass them here:

```sh
python3 scripts/testing/test-contract.py report --group core --lane ui \
  --xcresult-json /retained/xcresult-tests.json --log /retained/ui.log --exit-code 0
python3 scripts/testing/test-contract.py report --group unit --lane logic \
  --log /retained/logic.log --exit-code 0
```

Standalone reports are read-only: the caller owns canonical evidence/journal import.
Use the integrated runner to automatically record commands, structured results,
raw evidence paths/hashes and completed external-output archives through the
existing QA journal. Canonical storage remains the primary checkout's
`tests/results/`, never the app's user database. Never archive a live xcresult.

Reports include `status`, `errors`, expected/executed counts, `missing`,
`counts`, every `attempt`, `allowed_skips`, `unexpected_skips`, `pending` and
`coverage_status`. Process failure, missing methods (including all missing), zero
executed cases, parser errors, selector diagnostics, failures and unexpected skips
return nonzero. Aggregate success and source inventory cannot turn these green.
The original nonzero runner exit code is preserved; contract violations use 1.

Skip permission requires **both** explicit `--allow-skip hardware|screenshot|time`
and the manifest's exact method + reason match. It never excludes the method from
selection. Allowed skips stay skipped and coverage remains incomplete. All-skipped
runs still fail. Screenshot environment variables remain explicit caller setup;
no screenshots, clocks or app assertions are changed by the tooling. Network,
permission, benchmark and unknown skips fail unless a deliberate narrowly scoped
manifest policy is added; no blanket skip allowance exists.

Synthetic inputs in `test_contract.py` remain versioned inline with their tests:
modern/legacy xcresult trees, XCTest/Swift Testing logs, zero/failure/skip cases,
missing selectors, first-attempt failure, malformed JSON and declaration strings.
They prove the host contract, not an Xcode build, SwiftPM run or simulator behavior.

```sh
python3 -m unittest discover -s tests/testing -p 'test_*.py'
python3 -m unittest discover -s ios/Eval -p test_e2e_runner.py
```
