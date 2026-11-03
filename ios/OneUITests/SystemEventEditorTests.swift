import XCTest

/// Full system options for an existing event expose one Delete Event and
/// the start / end / all-day / alert rows are there to change. Uses the simulator's own calendar (never a real one).
/// Set TEST_RUNNER_EVENT_SHOTS=<folder> to save screenshots.
@MainActor
final class SystemEventEditorTests: XCTestCase {
  private func shot(_ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["EVENT_SHOTS"] else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? XCUIScreen.main.screenshot().pngRepresentation.write(
      to: URL(fileURLWithPath: dir + "/" + name + ".png"))
  }

  func testOpeningASystemEventShowsTheEditorWithOneDelete() throws {
    try XCTSkipIf(
      Calendar.current.component(.hour, from: .now) >= 23, "the default event time is tomorrow")
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-uiTestingCalendarSync"]
    app.launch()
    addUIInterruptionMonitor(withDescription: "Calendar access") { alert in
      for label in ["Allow Full Access", "Allow", "OK"] where alert.buttons[label].exists {
        alert.buttons[label].tap()
        return true
      }
      return false
    }
    app.openSidebar()
    app.buttons["Settings"].firstMatch.tap()
    let toggle = app.switches["Apple Calendar"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if (toggle.value as? String) != "1" {
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    for label in ["Allow Full Access", "Allow"] {
      let b = springboard.buttons[label]
      if b.waitForExistence(timeout: 3) {
        b.tap()
        break
      }
    }
    sleep(1)
    app.buttons["Done"].tap()

    let title = "Editor check \(Int(Date.now.timeIntervalSince1970) % 10000)"
    app.closeSidebar()
    sleep(1)
    app.buttons["Calendar"].firstMatch.tap()
    sleep(1)
    app.addNew("New event")
    let field = app.textFields["Title"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.typeText(title)
    app.buttons["Done"].tap()

    // Fresh start: the event is now a system event. Month view lists it under the selected day.
    app.terminate()
    app.launch()
    app.buttons["Calendar"].firstMatch.tap()
    app.buttons["calendar.mode.month"].tap()
    let row = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'agenda.row' AND label BEGINSWITH %@", title)
    ).firstMatch
    // The list is lazy and earlier runs leave events in the simulator's calendar: scroll until the row is built.
    var found = row.waitForExistence(timeout: 10)
    for _ in 0..<6 where !found {
      app.swipeUp()
      found = row.waitForExistence(timeout: 1)
    }
    shot("0-list")
    XCTAssertTrue(found, "the new event is listed")
    row.tap()
    let navTitle = app.staticTexts["Edit Event"]
    XCTAssertTrue(navTitle.waitForExistence(timeout: 10), "Apple's Edit Event opens straight away")
    XCTAssertTrue(
      app.buttons["alert-cell"].waitForExistence(timeout: 20), "the full system editor is ready")
    shot("1-opened")
    XCTAssertFalse(app.buttons["Edit"].exists, "no Edit to tap before changing full system options")
    XCTAssertTrue(
      app.textFields[title].exists || app.textViews[title].exists || app.staticTexts[title].exists,
      "the title is editable here")
    for name in ["Alert", "Calendar", "Travel Time"] {
      XCTAssertTrue(
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name))
          .firstMatch.exists,
        "the editor has a \(name) row")
    }
    let alerts = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH 'Alert, '"))
    XCTAssertEqual(
      alerts.count, 1,
      "one Alert row until one is set: \(alerts.allElementsBoundByIndex.map({ $0.label }))")
    let deletes = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Delete Event'"))
    XCTAssertEqual(
      deletes.count, 1,
      "exactly one Delete Event: \(deletes.allElementsBoundByIndex.map({ $0.label }))")
    // Close without changing anything. (The event stays in the simulator's own calendar, never a real one.)
    // Like Apple Calendar, the unchanged editor's Done is disabled; Cancel closes it.
    let nativeBar = app.navigationBars.containing(
      NSPredicate(
        format: "elementType == %ld AND label == 'Done' AND enabled == false",
        Int(XCUIElement.ElementType.button.rawValue))
    ).firstMatch
    XCTAssertTrue(
      nativeBar.waitForExistence(timeout: 5), "the native navigation bar is identifiable")
    nativeBar.buttons["Cancel"].tap()
    XCTAssertTrue(navTitle.waitForNonExistence(timeout: 8))
  }
}
