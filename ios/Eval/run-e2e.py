#!/usr/bin/env python3
"""Serial simulator QA with retained evidence; help/dry-run/inventory never probe devices."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import uuid

IOS = Path(__file__).resolve().parents[1]
ROOT = IOS.parent
sys.path.insert(0, str(ROOT / "tests/qa"))
from journal import Journal, results_root, is_ui_operation

sys.path.insert(0, str(ROOT / "scripts/testing"))
import contract

sys.path.insert(0, str(ROOT))
from scripts.devtools.core import (ci_test_scheme, derived_data, ensure_test_products, native_test_options,
                                   fingerprint, provenance, mock_ui_product, mock_app_identity)
from scripts.devtools.commands import execute
from scripts.devtools.process import PhaseDiagnostics

CASE = re.compile(r"Test Case '(.*?)' (passed|failed|skipped)")


def inventory():
    """Source declarations, not XCTest discovery or a claim that tests ran."""
    return contract.inventory()


def parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--group", action="append", choices=list(contract.load_manifest()["groups"]), help="authoritative test group; repeat to combine")
    mode.add_argument("--full", action="store_true", help="run all OneUITests once; explicit owner authorization required")
    mode.add_argument("--only", action="append", metavar="SUITE[/METHOD]", help="narrow selection; repeat for related tests")
    mode.add_argument("--inventory", action="store_true", help="print current UI and logic source inventory as JSON; no tools run")
    p.add_argument("--allow-skip", action="append", default=[], choices=["hardware", "screenshot", "time"], help="explicit opt-in: exact manifest test AND reason must match; skipped work remains visible")
    p.add_argument("--logic", action="store_true", help="first run swift test --jobs 2 (includes capture eval)")
    p.add_argument("--dry-run", action="store_true", help="print plan only; no subprocesses, devices, locks or files")
    p.add_argument("--simulator-name", default="Today-QA", help="owned simulator name; must start with Today-")
    p.add_argument("--simulator-id", help="reuse only if its name matches --simulator-name")
    p.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max")
    p.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-27-0")
    p.add_argument("--derived-data", type=Path, help="incremental cache; default ios/.build/<simulator-name>")
    p.add_argument("--test-products", type=Path, help="lane-owned relocated .xctestrun; test without compiling")
    p.add_argument("--appearance", choices=["light", "dark"], help="simulator system appearance")
    p.add_argument("--content-size", help="simctl ui content_size category, e.g. extra-extra-extra-large")
    p.add_argument("--output", type=Path, help="new evidence directory; must not exist")
    return p


def selectors(args, source):
    if args.group:
        return contract.plan(args.group, source)["selectors"]["ui"]
    if args.full:
        return [contract.TARGET]
    return contract.expand(args.only, source, "ui")


def grant_preconnected_access(selected, simulator, journal):
    # This journey skips Settings; match the hosted smoke's real EventKit grants.
    method = "TodayUITests/TodayReminderCompletionTests/testPreconnectedImportedTimelineStaysResponsive"
    if method in selected:
        for service in ("reminders", "calendar"):
            journal.action(["xcrun", "simctl", "privacy", simulator, "grant", service,
                            "com.luworks.today"], subprocess.run, check=True)


def ui_command(selected, simulator, derived, output, test_products=None):
    # Preserve project signing, including simulated App Group entitlements for Share.
    target = (["test-without-building", "-xctestrun", str(test_products)] if test_products else
              ["test", "-project", contract.SETTINGS["project"], "-scheme", contract.SETTINGS["scheme"]])
    selected = [value.replace("OneUITests", "TodayUITests", 1) if value.startswith("OneUITests") else value for value in selected]
    return ["xcodebuild", *target, "-jobs", "2",
            "-destination", f"platform=iOS Simulator,id={simulator}",
            "-derivedDataPath", str(derived), "-resultBundlePath", str(output / "ui.xcresult"),
            "-collect-test-diagnostics", "never",
            "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
            "-maximum-parallel-testing-workers", "1",
            *native_test_options(), "-showBuildTimingSummary",
            *["-only-testing:" + value for value in selected]]


def run_logged(command, logfile, progress, attempts, journal=None):
    diagnostics = PhaseDiagnostics(command)
    command_id = uuid.uuid4().hex
    if journal:
        journal.record("qa.command.started", shlex.join(command), status="started", subject=command_id)
    print("+ " + shlex.join(command), flush=True)
    with logfile.open("w") as log:
        process = subprocess.Popen(command, cwd=IOS, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, bufsize=1, start_new_session=True)
        diagnostics.pid = process.pid
        try:
            diagnostics.emit('started')
            current_test = None
            for line in process.stdout:
                log.write(line)
                log.flush()
                diagnostics.observe(line)
                started_case = re.search(r"Test Case '(.*?)' started", line)
                if started_case:
                    current_test = started_case[1]
                    if journal:
                        journal.record("qa.test", line.rstrip(), status="started", subject=current_test)
                if journal and is_ui_operation(line):
                    journal.record("qa.ui.operation", line.rstrip(), subject=current_test)
                match = CASE.search(line)
                if match:
                    entry = {"test": match[1], "status": match[2]}
                    attempts.append(entry)
                    if journal:
                        journal.record("qa.test", line.rstrip(), status=match[2], subject=match[1])
                    current_test = None
                    with progress.open("a") as stream:
                        stream.write(json.dumps({"time": datetime.now(timezone.utc).isoformat(), **entry}) + "\n")
                    print(f"[{len(attempts)} completed] {line.strip()}", flush=True)
                elif any(token in line for token in ("Test Suite '", "Test Case '", "Executed ", "CAPTURE ", "error:", "** TEST")):
                    print(line.rstrip(), flush=True)
            return process.wait()
        finally:
            # Stop the whole runner group before shutting down its simulator.
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            process.stdout.close()
            diagnostics.emit('reaped', exit=process.returncode)
            if journal:
                journal.record("qa.command.completed", shlex.join(command), status="completed",
                               subject=command_id, props={"exit_code": process.returncode})


class RunJournal:
    """Journal errors are reported separately and never replace a test exit code."""
    def __init__(self, session, errors):
        self.session, self.errors, self.store = session, errors, None
        try:
            self.store = Journal()
        except Exception as error:
            self.error(error)

    def error(self, error):
        self.errors.append(str(error))
        print(f"QA journal error: {error}", file=sys.stderr)

    def record(self, kind, text, **kwargs):
        if self.store:
            try:
                return self.store.record(self.session, kind, text, **kwargs)
            except Exception as error:
                self.error(error)

    def action(self, command, function, **kwargs):
        subject = uuid.uuid4().hex
        self.record("qa.command.started", shlex.join(command), status="started", subject=subject)
        started = time.monotonic()
        try:
            value = function(command, **kwargs)
            print(json.dumps({"qa_command": command[:3], "seconds": round(time.monotonic() - started, 3),
                              "exit": getattr(value, "returncode", 0)}), flush=True)
            self.record("qa.command.completed", shlex.join(command), status="completed", subject=subject,
                        props={"exit_code": getattr(value, "returncode", 0)})
            return value
        except BaseException as error:
            self.record("qa.command.failed", str(error), status="failed", subject=subject)
            raise

    def finish(self, output, summary):
        self.record("qa.run.result", json.dumps(summary), status=summary["status"])
        if self.store:
            try:
                # Immutable indexed report; summary.json may later include journal errors.
                retained = output / "summary-retained.json"
                retained.write_text(json.dumps(summary, indent=2) + "\n")
                if not output.resolve().is_relative_to(results_root().resolve()):
                    self.store.archive_files(output, self.session)
                else:
                    for path in sorted(output.rglob("*")):
                        if path.is_file() and not path.is_symlink() and path.name != "summary.json":
                            self.store.artifact(self.session, path)
            except Exception as error:
                self.error(error)
            finally:
                self.store.close()



def capture(command):
    return subprocess.check_output(command, cwd=IOS, text=True).strip()


def select_simulator(args, journal=None):
    read = (lambda command: journal.action(command, capture)) if journal else capture
    devices = json.loads(read(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    all_devices = [dict(d, runtime=runtime) for runtime, group in devices["devices"].items() for d in group]
    if args.simulator_id:
        matches = [d for d in all_devices if d["udid"].lower() == args.simulator_id.lower()]
        if len(matches) != 1 or matches[0]["name"] != args.simulator_name:
            raise ValueError("Simulator ID must identify the exact owned --simulator-name")
    else:
        matches = [d for d in all_devices if d["name"] == args.simulator_name]
    if len(matches) > 1:
        raise ValueError("Multiple simulators have this name; select the owned one with --simulator-id")
    if matches:
        actual = matches[0]
        if actual.get("deviceTypeIdentifier") != args.device_type or actual["runtime"] != args.runtime:
            raise ValueError("Owned simulator model/runtime differs from requested configuration")
        if matches[0]["state"] != "Shutdown":
            raise ValueError("Owned simulator is already active; wait for its runner and shut it down first")
        return matches[0]["udid"]
    return read(["xcrun", "simctl", "create", args.simulator_name, args.device_type, args.runtime])


def read_xcresult(output, journal):
    """Retain raw structured outputs before interpreting them; never retry a test."""
    bundle = output / "ui.xcresult"
    if not bundle.exists():
        raise ValueError("Missing authoritative ui.xcresult")
    def read(kind, extra=(), suffix=""):
        dest = output / ("xcresult-" + kind + suffix + ".json")
        with dest.open("w") as stream, dest.with_suffix(".log").open("w") as errors:
            result = journal.action(["xcrun", "xcresulttool", "get", "test-results", kind,
                "--path", str(bundle), *extra], subprocess.run, stdout=stream, stderr=errors)
        if result.returncode:
            raise ValueError("xcresulttool " + kind + " exit " + str(result.returncode))
        return json.loads(dest.read_text())
    totals = read("summary")
    attempts = contract.xcresult_attempts(read("tests"))
    if totals.get("failedTests", 0) and not any(a["status"] == "failed" for a in attempts):
        raise ValueError("xcresult summary reports failures absent from execution tree")
    for index, attempt in enumerate(attempts):
        if attempt["status"] == "skipped" and not attempt["reason"]:
            # Test-details carries skip reasons absent from the modern tree.
            details = read("test-details", ("--test-id", attempt.get("result_id", attempt["test"].split("/", 1)[1])), "-" + str(index))
            attempt["reason"] = json.dumps(details, sort_keys=True)
        journal.record("qa.test.structured", json.dumps(attempt), status=attempt["status"], subject=attempt["test"])
    return attempts


def main(argv=None):
    p = parser()
    args = p.parse_args(argv)
    source = inventory()
    if args.inventory:
        print(json.dumps(source, indent=2))
        return 0
    if not re.fullmatch(r"Today-[A-Za-z0-9_-]+", args.simulator_name):
        p.error("--simulator-name must be Today- followed by letters, digits, underscores or hyphens")
    try:
        selected = selectors(args, source)
    except ValueError as error:
        p.error(str(error))
    group_plan = contract.plan(args.group, source) if args.group else None
    run_logic = args.logic or bool(group_plan and group_plan["selectors"]["logic"])
    expected_ui = contract.available(source, "ui") if args.full else selected
    expected_logic = contract.available(source, "logic") if run_logic else []
    derived = (args.derived_data or IOS / ".build" / args.simulator_name).resolve()
    output = (args.output or results_root() / "runs" /
              ("today-qa-" + datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])).resolve()
    planned = [ui_command(selected, args.simulator_id or "<owned-simulator-udid>", derived, output, args.test_products)] if selected else []
    if run_logic:
        planned.insert(0, ["swift", "test", "--jobs", "2"])
    if args.dry_run:
        print(json.dumps({"cwd": str(IOS), "simulator_name": args.simulator_name,
                          "derived_data": str(derived), "output": str(output), "commands": planned, "plan": group_plan, "expected": {"logic": expected_logic, "ui": expected_ui},
                          "lifecycle": "lock name and cache; select/create owned shutdown simulator; boot; test; finally shutdown"}, indent=2))
        return 0
    # Locks cover separate checkouts using the same name or absolute cache path.
    locks = []
    simulator = None
    boot_started = False
    evidence_created = False
    journal = None
    started = time.monotonic()
    summary = {"started_at": datetime.now(timezone.utc).isoformat(), "selection": selected,
               "derived_data": str(derived), "simulator_name": args.simulator_name,
               "status": "incomplete", "stages": {}, "attempts": {}, "reports": {},
               "groups": args.group or [], "pending": group_plan["pending"] if group_plan else [],
               "allowed_skip_categories": args.allow_skip}
    try:
        for key in sorted(["name:" + args.simulator_name, "cache:" + str(derived)]):
            lock = open(Path(tempfile.gettempdir()) / ("today-qa-lock-" + hashlib.sha256(key.encode()).hexdigest()), "a")
            locks.append(lock)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        output.mkdir(parents=True, exist_ok=False)
        evidence_created = True
        summary["run_id"] = output.name + "-" + uuid.uuid4().hex[:8]
        journal = RunJournal(summary["run_id"], summary.setdefault("journal_errors", []))
        journal.record("qa.run", str(output), status="running")
        summary["head"] = journal.action(["git", "rev-parse", "HEAD"], capture)
        summary["working_tree"] = journal.action(["git", "status", "--short"], capture)
        summary["timezone"] = time.tzname
        summary["environment"] = {k: v for k, v in os.environ.items()
                                  if "SHOTS" in k or k == "ACTIVITY_BENCH_ROWS"}
        (output / "inventory.json").write_text(json.dumps(source, indent=2) + "\n")
        print(f"Evidence: {output}", flush=True)
        summary["commands"] = []
        if run_logic:
            command = ["swift", "test", "--jobs", "2"]
            summary["commands"].append(command)
            summary["attempts"]["logic"] = []
            code = run_logged(command, output / "logic.log", output / "progress.jsonl", summary["attempts"]["logic"], journal)
            summary["stages"]["logic"] = code
            logical = contract.log_attempts((output / "logic.log").read_text(), "logic", source=source)
            summary["reports"]["logic"] = contract.report(expected_logic, logical, code,
                args.allow_skip, contract.load_manifest()["skip_rules"],
                (output / "logic.log").read_text())
            summary["attempts"]["logic"] = logical
            if summary["reports"]["logic"]["status"] != "passed":
                summary["status"] = "failed"
                return code or 1
        if not selected:
            summary["status"] = "passed"
            return 0
        journal.record("qa.ui.operation", "Select owned simulator " + args.simulator_name, status="started")
        simulator = select_simulator(args, journal)
        summary["simulator_id"] = simulator
        summary["device_type"] = args.device_type
        summary["runtime"] = args.runtime
        if not args.test_products:
            # One trusted build, using the same product/provenance authority as
            # native tests. Keep cold simulator startup out of native compilation.
            if derived != derived_data(ROOT).resolve():
                raise ValueError("UI build reuse requires the canonical owned derived data")
            from scripts.devtools.resolve import locked_arguments

            validation_started = time.monotonic()

            def build(command):
                # Inventory and compilation finish before boot loads the host.
                summary["prebuild_validation_seconds"] = round(time.monotonic() - validation_started, 3)
                command = list(command)
                command[command.index("-project") + 1] = str(IOS / "Today.xcodeproj")
                summary["commands"].append(command)
                before = time.monotonic()
                # Use the existing owned-process deadline, leaving time for the
                # runner to close its logs and simulator before the outer limit.
                try:
                    result = execute(ROOT, command, timeout=600)
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    log = getattr(error, "process_log", None)
                    if log and Path(log).is_file():
                        (output / "build.log").write_bytes(Path(log).read_bytes())
                    summary["stages"]["build"] = 1
                    summary["build_reason"] = "process_error"
                    summary["build_seconds"] = round(time.monotonic() - before, 3)
                    raise
                (output / "build.log").write_bytes(result.log.read_bytes())
                summary["stages"]["build"] = result.returncode
                summary["build_reason"] = result.reason
                summary["build_seconds"] = round(time.monotonic() - before, 3)
                return result

            args.test_products = ensure_test_products(ROOT, ci_test_scheme("TodayMock"), build, flags=locked_arguments(ROOT))
        if not boot_started:
            boot_started = True
            journal.action(["xcrun", "simctl", "boot", simulator], subprocess.run, check=True)
        # UI app launch requires a ready destination, including routine CI.
        # A boot request alone can leave the first XCTest launch waiting until timeout.
        journal.action(["xcrun", "simctl", "bootstatus", simulator, "-b"], subprocess.run, check=True)
        if args.test_products:
            summary["test_products"] = str(args.test_products.resolve())
            summary["test_products_sha256"] = hashlib.sha256(args.test_products.read_bytes()).hexdigest()
        for setting, value in (("appearance", args.appearance), ("content_size", args.content_size)):
            if value:
                journal.action(["xcrun", "simctl", "ui", simulator, setting, value], subprocess.run, check=True)
        summary["display_settings"] = {"appearance": args.appearance, "content_size": args.content_size}
        identity = fingerprint(ROOT, scheme=ci_test_scheme("TodayMock"), architecture="arm64")
        receipt = provenance(ROOT, identity, kind="build-for-testing", xctestrun=args.test_products)
        if not receipt["valid"]:
            raise ValueError("UI product provenance rejected: " + receipt["reason"])
        mock = mock_ui_product(ROOT, args.test_products)
        if mock is None:
            raise ValueError("Missing explicit Mock UI product")
        journal.action(["xcrun", "simctl", "install", simulator, mock["app"]], subprocess.run, check=True)
        installed = journal.action(
            ["xcrun", "simctl", "get_app_container", simulator, "com.luworks.today", "app"], capture).strip()
        if mock_app_identity(installed) != mock["identity"]:
            raise ValueError("Installed UI product differs from verified TodayMock")
        summary["mock_product"] = {**mock, "installed_app": installed,
                                   "source_fingerprint": identity["sha256"]}
        (output / "mock-product.json").write_text(json.dumps(summary["mock_product"], indent=2) + "\n")
        grant_preconnected_access(selected, simulator, journal)
        command = ui_command(selected, simulator, derived, output, args.test_products)
        summary["commands"].append(command)
        summary["attempts"]["ui"] = []
        code = run_logged(command, output / "ui.log", output / "progress.jsonl", summary["attempts"]["ui"], journal)
        summary["stages"]["ui"] = code
        # Log events are progress only. The completed xcresult tree is authoritative.
        try:
            actual = read_xcresult(output, journal)
            summary["attempts"]["ui_log"] = summary["attempts"]["ui"]
            summary["attempts"]["ui"] = actual
            summary["reports"]["ui"] = contract.report(expected_ui, actual, code,
                args.allow_skip, contract.load_manifest()["skip_rules"],
                (output / "ui.log").read_text() if (output / "ui.log").exists() else "",
                summary["pending"])
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            summary["reports"]["ui"] = {"status": "failed", "errors": ["parser_error"], "detail": str(error)}
        summary["status"] = summary["reports"]["ui"]["status"]
        return code or (0 if summary["status"] == "passed" else 1)

    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        summary["error"] = str(error)
        summary["status"] = "failed"
        print(f"QA failed: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        summary["status"] = "interrupted"
        return 130
    finally:
        if simulator and boot_started:
            try:
                summary["stages"]["shutdown"] = journal.action(["xcrun", "simctl", "shutdown", simulator], subprocess.run).returncode
            except OSError as error:
                summary["shutdown_error"] = str(error)
        elif simulator:
            # Inventory failed before this owned, initially shutdown device booted.
            summary["stages"]["shutdown"] = 0
            summary["shutdown_reason"] = "not_booted"
        summary["elapsed_seconds"] = round(time.monotonic() - started, 3)
        summary["counts"] = {lane: dict(Counter(a["status"] for a in attempts))
                             for lane, attempts in summary["attempts"].items()}
        # Never overwrite evidence from a pre-existing output directory.
        if evidence_created:
            (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            if journal:
                journal.finish(output, summary)
                (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            print(f"{summary['status']}: {summary['counts']}; evidence: {output}", flush=True)
        for lock in locks:
            lock.close()


if __name__ == "__main__":
    # SIGTERM follows the same cleanup path as Ctrl-C.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    sys.exit(main())
