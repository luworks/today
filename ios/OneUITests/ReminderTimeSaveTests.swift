import XCTest

/// Uses the real editor DatePicker and a fresh EventKit reader, including relaunch.
@MainActor
final class ReminderTimeSaveTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    if let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_REMINDER_SHOTS"] {
      try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try? app.screenshot().pngRepresentation.write(
        to: URL(fileURLWithPath: directory).appending(path: name + ".png"))
    }
  }

  private func wait(_ element: XCUIElement, contains value: String) {
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          expectation(
            for: NSPredicate(format: "label CONTAINS %@", value),
            evaluatedWith: element)
        ], timeout: 25), .completed, element.debugDescription)
  }

  func testDeadlineTimeRoundTripsThroughAppleWithoutChangingPlanOrMetadata() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-uiTestingRemindersSync"]
    app.launch()
    app.openSidebar()
    app.buttons["Settings"].firstMatch.tap()
    let sync = app.switches["Apple Reminders"]
    XCTAssertTrue(sync.waitForExistence(timeout: 5))
    if sync.value as? String != "1" {
      sync.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      for label in ["Allow Full Access", "Allow"]
      where springboard.buttons[label].waitForExistence(timeout: 3) {
        springboard.buttons[label].tap()
        break
      }
    }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          expectation(
            for: NSPredicate(format: "value == '1'"),
            evaluatedWith: sync)
        ], timeout: 8), .completed)
    app.terminate()
    let data = try Data(
      contentsOf: URL(fileURLWithPath: TestData.fixturePath("reminder-time-save.json")))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let baseTitle = try XCTUnwrap(
      (fixture["reminders"] as? [[String: Any]])?.first?["title"] as? String)
    let title = "TS\(UUID().uuidString.prefix(8)) " + baseTitle
    let store = "time-save-\(UUID().uuidString)"
    let args = [
      "-uiTesting", "-uiTestingRemindersSync", "-uiTestingStore", store,
      "-uiTestingSyncDump", title, "-uiTestingNow", "12:00",
    ]
    app.launchArguments =
      args + [
        "-uiTestingExternalNoteAfterTimeSave", "-uiTestingReminderEditMetadata",
        "-uiTestingAppleOp", "addToday", title, "_",
      ]
    app.launch()
    wait(app.staticTexts["syncDump.apple"], contains: "14:00")
    let metadata = app.staticTexts["syncDump.metadata"]
    wait(metadata, contains: "priority=5")
    let originalMetadata = metadata.label
    XCTAssertTrue(originalMetadata.contains("repeat=1:2"))
    XCTAssertTrue(originalMetadata.contains("relative:-600"))
    app.staticTexts[title].firstMatch.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["task.title"].firstMatch.waitForExistence(timeout: 5))
    if app.buttons["task.more"].exists { app.buttons["task.more"].tap() }
    XCTAssertEqual(app.switches["Deadline"].value as? String, "1")
    shot(app, "time-save-before-14-00")
    let picker = app.datePickers.firstMatch
    let time = picker.buttons.matching(NSPredicate(format: "label CONTAINS ':'")).firstMatch
    XCTAssertTrue(time.waitForExistence(timeout: 5), app.debugDescription)
    time.tap()
    let hours = app.pickerWheels.element(boundBy: 0)
    let minutes = app.pickerWheels.element(boundBy: 1)
    XCTAssertTrue(minutes.waitForExistence(timeout: 5), app.debugDescription)
    let rawHour = hours.value as? String ?? ""
    hours.adjust(toPickerWheelValue: rawHour.contains("14") ? "13" : "1")
    minutes.adjust(toPickerWheelValue: "10")
    // Tap outside the native popover without hitting a different field.
    app.navigationBars["Reminder"].staticTexts["Reminder"].tap()
    shot(app, "time-save-draft-13-10")
    if app.buttons["task.save"].exists {
      app.buttons["task.save"].tap()
    } else {
      app.navigationBars["Reminder"].buttons["Done"].tap()
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["task.title"].firstMatch.waitForNonExistence(timeout: 5))
    for side in ["apple", "app", "persisted"] {
      wait(app.staticTexts["syncDump.\(side)"], contains: "13:10")
    }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    let day = f.string(from: .now)
    let expectedMetadata =
      originalMetadata
      .replacingOccurrences(of: "due=\(day) 14:00", with: "due=\(day) 13:10")
      .replacingOccurrences(of: "alarms=\(day) 14:00", with: "alarms=\(day) 13:10")
      .replacingOccurrences(
        of: "note=Preserve the native note.",
        with: "note=Preserve the native note. External note edit.")
    XCTAssertEqual(
      metadata.label, expectedMetadata,
      "same Apple ID/list, timezone, native recurrence, notes, URL, priority and both alerts survive"
    )
    app.staticTexts[title].firstMatch.tap()
    if app.buttons["task.more"].exists { app.buttons["task.more"].tap() }
    let savedTime = app.datePickers.firstMatch.buttons.matching(
      NSPredicate(format: "label CONTAINS ':'")
    ).firstMatch
    XCTAssertTrue(savedTime.label.contains("13:10") || savedTime.label.contains("1:10"))
    shot(app, "time-save-after-reopen-13-10")
    app.buttons["Cancel"].tap()
    XCUIDevice.shared.press(.home)
    app.activate()
    for side in ["apple", "app", "persisted"] {
      wait(app.staticTexts["syncDump.\(side)"], contains: "13:10")
    }
    app.terminate()
    app.launchArguments = args
    app.launch()
    for side in ["apple", "app", "persisted"] {
      wait(app.staticTexts["syncDump.\(side)"], contains: "13:10")
    }
    XCTAssertEqual(metadata.label, expectedMetadata)
    app.staticTexts[title].firstMatch.tap()
    if app.buttons["task.more"].exists { app.buttons["task.more"].tap() }
    shot(app, "time-save-after-relaunch-13-10")
  }
}
