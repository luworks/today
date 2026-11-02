import XCTest

/// The Alarms section of the Clock tab, a copy of Clock's Alarms tab: add, edit (time, repeat, label), switch, delete.
/// Run against a fresh in-memory store (no alarms to start with). The simulator denies AlarmKit,
/// so these check the list and the editor, not the ringing.
@MainActor
final class AlarmsTabTests: XCTestCase {
  var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments = ["-uiTesting"]
      app.launch()
      let alarms = app.buttons["Clock"].firstMatch
      XCTAssertTrue(alarms.waitForExistence(timeout: 5))
      alarms.tap()
      XCTAssertTrue(
        app.buttons["New"].waitForExistence(timeout: 5), "the app-wide + is there to add an alarm")
    }
  }

  /// Set TEST_RUNNER_ALARM_SHOTS=<folder> to save screenshots of each step (for design review).
  private func shot(_ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["ALARM_SHOTS"] else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? XCUIScreen.main.screenshot().pngRepresentation.write(
      to: URL(fileURLWithPath: dir + "/" + name + ".png"))
  }

  private var rows: XCUIElementQuery { app.buttons.matching(identifier: "alarm.row") }
  private var toggles: XCUIElementQuery { app.switches.matching(identifier: "alarm.toggle") }

  /// Opens Add Alarm, optionally sets the repeat days, and saves.
  @discardableResult
  private func addAlarm(days: [String] = []) -> XCUIElement {
    let before = rows.count
    app.addNew("New alarm")
    XCTAssertTrue(
      app.staticTexts["Add Alarm"].waitForExistence(timeout: 5), "the editor is titled Add Alarm")
    if !days.isEmpty {
      for day in days { app.buttons["Every " + day].tap() }
    }
    app.buttons["alarm.save"].tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
    let expected = before + 1
    for _ in 0..<20 where rows.count < expected {
      _ = app.buttons["New"].waitForExistence(timeout: 0.25)
    }
    XCTAssertEqual(rows.count, expected, "the saved alarm is listed")
    return rows.element(boundBy: before)
  }

  func testEmptyStateAndAddAlarm() {
    XCTAssertTrue(
      app.descendants(matching: .any)["alarms.empty"].waitForExistence(timeout: 3),
      "empty state like Clock")
    shot("1-empty")
    let row = addAlarm()
    XCTAssertTrue(
      row.label.hasSuffix(", Alarm"),
      "a new alarm with no label and no repeat reads just 'Alarm': \(row.label)")
    XCTAssertFalse(app.descendants(matching: .any)["alarms.empty"].exists)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Next alarm in'")).firstMatch
        .waitForExistence(timeout: 3),
      "the next-alarm hint shows while an alarm is on")
    shot("2-one-alarm")
  }

  func testToggleSwitchesAlarmOffAndHidesNextHint() {
    addAlarm()
    let toggle = toggles.firstMatch
    XCTAssertEqual(toggle.value as? String, "1", "a new alarm is on")
    toggle.toggleSwitch()
    XCTAssertEqual(toggle.value as? String, "0")
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Next alarm in'")).firstMatch
        .waitForNonExistence(timeout: 3),
      "no hint when every alarm is off")
    shot("3-off")
    toggle.toggleSwitch()
    XCTAssertEqual(toggle.value as? String, "1")
  }

  func testRepeatDaysShowClockWording() {
    let row = addAlarm(days: ["Monday", "Wednesday"])
    XCTAssertTrue(row.label.hasSuffix(", Alarm, Mon, Wed"), row.label)
    // The editor shows the same value, and the check marks stick.
    row.tap()
    XCTAssertTrue(app.staticTexts["Edit Alarm"].waitForExistence(timeout: 5))
    let repeatRow = app.descendants(matching: .any)["alarm.repeat"]
    XCTAssertEqual(repeatRow.label, "Repeat, Mon, Wed")
    shot("4-edit")
    XCTAssertTrue(app.buttons["Every Monday"].isSelected, "Monday is on")
    XCTAssertFalse(app.buttons["Every Tuesday"].isSelected)
    app.buttons["Every Monday"].tap()
    app.buttons["Every Wednesday"].tap()
    XCTAssertEqual(repeatRow.label, "Repeat, Never", "no days means Never")
    app.buttons["Cancel"].tap()
    XCTAssertTrue(
      rows.firstMatch.label.hasSuffix(", Alarm, Mon, Wed"), "Cancel keeps the alarm as it was")
  }

  /// Add Alarm like Clock: the wheel, Weekdays and a typed label, then ✓.
  func testAddAlarmSavesWheelRepeatAndLabel() {
    let first = addAlarm()
    first.tap()
    XCTAssertTrue(app.staticTexts["Edit Alarm"].waitForExistence(timeout: 5))
    let field = app.textFields["alarm.label"]
    field.tap()
    field.typeText("Wake up\n")
    app.buttons["alarm.save"].tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))

    app.addNew("New alarm")
    XCTAssertTrue(app.staticTexts["Add Alarm"].waitForExistence(timeout: 5))
    app.setAlarmMinutes("00")
    app.buttons["alarm.repeat.weekdays"].tap()
    XCTAssertEqual(app.descendants(matching: .any)["alarm.repeat"].label, "Repeat, Weekdays")
    field.tap()
    field.typeText("Wake up")
    XCTAssertEqual(field.value as? String, "Wake up")
    app.buttons["alarm.save"].tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
    let saved = rows.matching(NSPredicate(format: "label ENDSWITH %@", ", Wake up, Weekdays"))
    XCTAssertTrue(saved.firstMatch.waitForExistence(timeout: 5), "the picks were saved")
  }

  func testEditTimeAndLabel() {
    addAlarm()
    rows.firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Edit Alarm"].waitForExistence(timeout: 5))
    // The simulator may be on a 12- or 24-hour clock: set only the minutes, which read the same on both.
    app.setAlarmMinutes("30")
    let field = app.textFields["alarm.label"]
    field.tap()
    field.typeText("Gym")
    app.buttons["alarm.save"].tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
    let row = rows.firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    XCTAssertTrue(row.label.contains(":30"), row.label)
    XCTAssertTrue(row.label.hasSuffix(", Gym"), row.label)
    shot("6-edited")
  }

  func testSwipeLeftDeletes() {
    addAlarm()
    let row = rows.firstMatch
    // A full swipe across the row deletes, like Clock.
    let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
    start.press(
      forDuration: 0.05,
      thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: -0.3, dy: 0.5)))
    for _ in 0..<20 where rows.count > 0 { _ = app.buttons["New"].waitForExistence(timeout: 0.25) }
    // A full swipe deletes at once; a shorter one (or the simulator's synthetic drag) leaves the Delete button open.
    let delete = app.buttons["Delete"]
    if delete.waitForExistence(timeout: 1) { delete.tap() }
    XCTAssertEqual(rows.count, 0, "swipe left deletes the alarm")
    XCTAssertTrue(app.descendants(matching: .any)["alarms.empty"].waitForExistence(timeout: 3))
  }

  func testDeleteAlarmFromEditor() {
    addAlarm()
    rows.firstMatch.tap()
    XCTAssertTrue(
      app.buttons["alarm.delete"].waitForExistence(timeout: 5),
      "Edit Alarm has a red Delete Alarm button")
    app.buttons["alarm.delete"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["alarms.empty"].waitForExistence(timeout: 5))
  }

  /// Sound opens a list of the app's tones (the system sound, then ours); a choice sticks after saving.
  func testChoosingATone() {
    app.addNew("New alarm")
    XCTAssertTrue(app.staticTexts["Add Alarm"].waitForExistence(timeout: 5))
    XCTAssertEqual(
      app.switches["alarm.snooze"].value as? String, "1", "Snooze is on by default, like Clock")
    XCTAssertTrue(
      app.buttons["alarm.snoozeDuration"].exists, "Snooze Duration shows while Snooze is on")
    shot("8-add")
    app.buttons["alarm.sound"].tap()
    XCTAssertTrue(app.navigationBars["Sound"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Default"].isSelected, "the system sound is the default")
    for name in [
      "Daybreak", "Chimes", "Marimba", "Glass", "Ripple", "Morning Piano", "Beacon", "Crystal",
    ] {
      XCTAssertTrue(app.buttons[name].exists, "tone \(name)")
    }
    shot("9-sounds")
    app.buttons["Daybreak"].tap()
    XCTAssertTrue(app.buttons["Daybreak"].isSelected)
    app.navigationBars["Sound"].buttons.firstMatch.tap()  // Back
    XCTAssertTrue(
      app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Daybreak'"))
        .firstMatch.waitForExistence(timeout: 3),
      "the row shows the chosen tone")
    app.buttons["alarm.save"].tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
    rows.firstMatch.tap()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Daybreak'"))
        .firstMatch.waitForExistence(timeout: 5),
      "it is still chosen when the alarm is opened again")
  }

  /// Missing permissions are one slim row above the list, not two big cards. (The simulator denies AlarmKit.)
  func testPermissionIsOneSlimRow() {
    app.launchArguments.append("-uiTestingAlarmDenied")
    app.launch()
    app.buttons["Clock"].firstMatch.tap()
    let row = app.descendants(matching: .any)["alarms.permissionRow"]
    XCTAssertTrue(
      row.waitForExistence(timeout: 3), "the denied fixture must expose permission guidance")
    XCTAssertLessThanOrEqual(row.frame.height, 60, "a slim row, not a card")
    XCTAssertTrue(
      row.label.contains("off")
        || app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' off'")).count > 0)
    XCTAssertFalse(app.staticTexts["Alarms Are Off"].exists)
    XCTAssertFalse(app.staticTexts["Notifications Are Off"].exists)
    XCTAssertLessThan(row.frame.maxY, app.frame.height / 3, "above the list")
    shot("10-permission")
  }

  func testSnoozeOffHidesDuration() {
    app.addNew("New alarm")
    XCTAssertTrue(app.staticTexts["Add Alarm"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.buttons["alarm.snoozeDuration"].exists, "Snooze Duration shows while Snooze is on")
    app.switches["alarm.snooze"].toggleSwitch()
    XCTAssertTrue(app.buttons["alarm.snoozeDuration"].waitForNonExistence(timeout: 3))
  }
}

/// Add Alarm opens on the next five-minute mark of Today's clock (pinned to 10:52, so 10:55), not on a whole hour.
@MainActor
final class AlarmDefaultTimeTests: XCTestCase {
  func testAddAlarmOpensOnTheNextFiveMinuteMark() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-uiTestingNow", "10:52"]
    app.launch()
    app.buttons["Clock"].firstMatch.tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
    app.addNew("New alarm")
    XCTAssertTrue(app.staticTexts["Add Alarm"].waitForExistence(timeout: 5))
    let hours = app.descendants(matching: .any)["wheelLab.hours"].firstMatch
    let minutes = app.descendants(matching: .any)["wheelLab.minutes"].firstMatch
    XCTAssertTrue(hours.waitForExistence(timeout: 5))
    // 12- or 24-hour clock: the hour reads "10" on both, the minutes "55".
    XCTAssertEqual(hours.value as? String, "10")
    XCTAssertEqual(minutes.value as? String, "55")
  }
}

/// Saves made while Add Alarm is open (sync, widgets, another device) must not re-render the shell under the sheet:
/// each re-render cost frames while the wheel was spinning, so the minute column stuttered on a phone.
@MainActor
final class AlarmWheelStoreChurnTests: XCTestCase {
  func testSavesUnderAddAlarmLeaveTheShellAlone() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-uiTestingNow", "10:56", "-uiTestingStoreChurn"]
    app.launch()
    app.buttons["Clock"].firstMatch.tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
    app.buttons["New"].tap()
    XCTAssertTrue(app.staticTexts["Add Alarm"].waitForExistence(timeout: 5))
    let minutes = app.descendants(matching: .any)["wheelLab.minutes"].firstMatch
    XCTAssertTrue(minutes.waitForExistence(timeout: 5))
    let report = app.staticTexts["storeChurn.report"]
    let before = Self.parse(report.label)
    for step in 0..<4 {
      let (from, to) = step.isMultiple(of: 2) ? (0.85, 0.15) : (0.15, 0.85)
      minutes.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from)).press(
        forDuration: 0.02,
        thenDragTo: minutes.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
        withVelocity: .default, thenHoldForDuration: 0.1)
    }
    let after = Self.parse(report.label)
    XCTAssertGreaterThanOrEqual(after.saves - before.saves, 5, "saves kept coming: \(report.label)")
    XCTAssertLessThanOrEqual(
      after.shell - before.shell, 1, "the shell re-rendered on saves: \(before) → \(after)")
  }

  private static func parse(_ label: String) -> (saves: Int, shell: Int) {
    let values = label.split(separator: " ").map { Int($0.split(separator: "=").last ?? "") ?? 0 }
    return (values.first ?? 0, values.count > 1 ? values[1] : 0)
  }
}

/// The one-time "Set your alarms in Today" card and alarms a Shortcut brought over from the Clock app.
@MainActor
final class AlarmIntroTests: XCTestCase {
  func testIntroShowsOnceAndStagedClockAlarmsAreAddedByTap() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "-uiTesting", "-uiTestingAlarmIntro",
      "-uiTestingStagedClockAlarms", "07:00|Wake up|Weekdays;22:30||Never",
    ]
    app.launch()
    app.buttons["Clock"].firstMatch.tap()
    let intro = app.descendants(matching: .any)["alarms.intro"]
    XCTAssertTrue(intro.waitForExistence(timeout: 5), "the card shows the first time")
    app.buttons["alarms.intro.import"].tap()
    XCTAssertTrue(app.buttons["alarms.intro.shortcuts"].waitForExistence(timeout: 3))
    app.buttons["alarms.intro.done"].tap()
    XCTAssertTrue(intro.waitForNonExistence(timeout: 3))

    let staged = app.descendants(matching: .any).matching(identifier: "alarms.import.row")
    XCTAssertEqual(staged.count, 2, "both Clock alarms wait for a tap; none is set yet")
    XCTAssertFalse(app.buttons["alarm.row"].exists)
    app.buttons["alarms.import.addAll"].tap()
    XCTAssertTrue(staged.firstMatch.waitForNonExistence(timeout: 5))
    let rows = app.buttons.matching(identifier: "alarm.row")
    XCTAssertEqual(rows.count, 2)
    XCTAssertTrue(
      rows.matching(NSPredicate(format: "label ENDSWITH %@", ", Wake up, Weekdays")).firstMatch
        .exists)
  }
}
