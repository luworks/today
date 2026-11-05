import XCTest

/// The actual production TaskEditor over a synthetic list. No screenshot-only rendering path.
@MainActor
final class ReminderEditorTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    await MainActor.run {
      continueAfterFailure = false
      app = XCUIApplication()
      app.launchArguments =
        TestData.fixtureArguments("reminder-compact-editor.json")
        + ["-uiTestingNow", "10:32"]
      app.launch()
      app.buttons["Reminders"].firstMatch.tap()
      let list = app.descendants(matching: .any)["list.Home"].firstMatch
      XCTAssertTrue(list.waitForExistence(timeout: 5))
      list.tap()
    }
  }

  private func open(_ title: String) {
    let row = app.staticTexts[title].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["task.title"].firstMatch.waitForExistence(timeout: 5))
  }

  private func shot(_ name: String) {
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

  private func dateLabel(day: Int, hour: Int, minute: Int) -> String {
    let cal = Calendar.current
    let day = cal.date(byAdding: .day, value: day, to: .now)!
    let date = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
  }

  func testLongMultilingualTitleWrapsAndSaves() {
    open("Read the article")
    let title = app.descendants(matching: .any)["task.title"].firstMatch
    let singleLineHeight = title.frame.height
    let longTitle = String(repeating: " Review 牛奶采购清单 and the delivery details.", count: 12)
    title.tap()
    title.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    title.typeText(longTitle)
    XCTAssertTrue(title.frame.height > singleLineHeight * 4, "Title grows beyond four lines")
    let savedTitle = "Read the article" + longTitle
    XCTAssertEqual(title.value as? String, savedTitle, "The entire multilingual title is editable")
    let preset = app.buttons["18:30"]
    for _ in 0..<8 where !preset.isHittable { app.swipeUp() }
    XCTAssertTrue(preset.isHittable, "Time controls remain reachable with a long title")
    preset.tap()
    app.buttons["task.save"].tap()
    XCTAssertTrue(app.buttons["task.save"].waitForNonExistence(timeout: 5))
    open(savedTitle)
    XCTAssertEqual(title.value as? String, savedTitle)
    app.buttons["task.more"].tap()
    XCTAssertEqual(title.value as? String, savedTitle)
    app.buttons["Cancel"].tap()
  }

  func testPresetsSaveAndCancel() {
    open("Prepare the demo")
    XCTAssertFalse(app.buttons["task.save"].isEnabled)
    let when = app.buttons["task.when"]
    XCTAssertTrue(when.label.contains(dateLabel(day: 1, hour: 17, minute: 0)))
    app.buttons["+1 hr"].tap()
    app.buttons["−10 min"].tap()
    XCTAssertTrue(when.label.contains(dateLabel(day: 1, hour: 17, minute: 50)))
    app.buttons["task.save"].tap()
    XCTAssertTrue(app.buttons["task.save"].waitForNonExistence(timeout: 5))
    open("Prepare the demo")
    XCTAssertTrue(when.label.contains(dateLabel(day: 1, hour: 17, minute: 50)))
    app.buttons["+1 day"].tap()
    app.buttons["Cancel"].tap()
    open("Prepare the demo")
    XCTAssertTrue(
      when.label.contains(dateLabel(day: 1, hour: 17, minute: 50)), "Cancel discards the extra day")
  }

  func testReferencePanelAndAdvancedDraftCancel() {
    open("test")
    XCTAssertFalse(app.buttons["task.save"].isEnabled)
    for title in [
      "09:30", "12:00", "18:30", "22:00", "+10 min", "+1 hr", "+3 hr", "+1 day", "−10 min", "−1 hr",
      "−3 hr", "−1 day",
    ] {
      XCTAssertTrue(app.buttons[title].isHittable, title)
      XCTAssertGreaterThanOrEqual(app.buttons[title].frame.height, 44)
    }
    shot("compact-reference")
    app.buttons["task.more"].tap()
    XCTAssertEqual(app.switches["Deadline"].value as? String, "1")
    XCTAssertEqual(
      app.descendants(matching: .any)["task.note"].firstMatch.value as? String, "Around the park.")
    let notes = app.descendants(matching: .any)["task.note"].firstMatch
    notes.tap()
    notes.typeText(" Draft only")
    shot("advanced-draft-keyboard")
    app.buttons["Cancel"].tap()
    open("test")
    app.buttons["task.more"].tap()
    XCTAssertEqual(
      app.descendants(matching: .any)["task.note"].firstMatch.value as? String, "Around the park.")
    let list = app.descendants(matching: .any)["task.list"].firstMatch
    for _ in 0..<4 where !list.isHittable { app.swipeUp() }
    XCTAssertTrue(list.isHittable, "existing list and advanced options remain reachable")
    XCTAssertTrue(list.label.contains("Home"), list.debugDescription)
    let flag = app.switches["Flag"]
    for _ in 0..<3 where !flag.isHittable { app.swipeUp() }
    XCTAssertTrue(flag.isHittable, "the advanced Flag option is reachable after scrolling")
    shot("advanced-options")
  }

  func testUndatedOpeningDoesNotEnableDatesAndKeyboardSaveWorks() {
    open("Read the article")
    XCTAssertTrue(app.buttons["task.when"].label.contains("No date"))
    XCTAssertFalse(app.buttons["task.save"].isEnabled)
    app.buttons["task.more"].tap()
    XCTAssertEqual(app.switches["Deadline"].value as? String, "0")
    app.buttons["Quick edit"].tap()
    let title = app.descendants(matching: .any)["task.title"].firstMatch
    title.tap()
    title.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    title.typeText(" tonight\n")
    app.buttons["18:30"].tap()
    XCTAssertTrue(app.buttons["task.when"].label.contains(dateLabel(day: 0, hour: 18, minute: 30)))
    shot("preset-and-keyboard-save")
    app.buttons["task.save"].tap()
    open("Read the article tonight")
    XCTAssertTrue(app.buttons["task.when"].label.contains(dateLabel(day: 0, hour: 18, minute: 30)))
    app.buttons["task.more"].tap()
    XCTAssertEqual(app.switches["Deadline"].value as? String, "1")
  }
}
