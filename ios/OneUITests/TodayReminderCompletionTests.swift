import XCTest

/// Real simulator EventKit, actual Today circle, fresh EventKit and SwiftData readback across launches.
@MainActor
final class TodayReminderCompletionTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private func launch(
    title: String, store: String, seed: Bool = false, fail: Bool = false,
    extra: [String] = []
  )
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments = [
      "-uiTesting", "-uiTestingRemindersSync", "-uiTestingStore", store,
      "-uiTestingSyncDump", title, "-uiTestingNow", "12:00",
    ]
    app.launchArguments += extra
    if seed { app.launchArguments += ["-uiTestingAppleOp", "addToday", title, "_"] }
    if fail { app.launchArguments += ["-uiTestingFailReminderCompletion"] }
    app.launch()
    return app
  }

  private func connect(includeCalendar: Bool = false) {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-uiTestingRemindersSync"]
    if includeCalendar {
      app.launchArguments += ["-uiTestingCalendarSync"]
      // This owned-simulator fixture must not inherit a cancelled/denied Calendar prompt from another run.
      app.resetAuthorizationStatus(for: .calendar)
      // Revoking authorization must also reset the saved toggle before exercising first-time connection.
      app.launchArguments += ["-today.calendarSync.enabled", "NO"]
    }
    app.launch()
    app.openSidebar()
    app.buttons["Settings"].firstMatch.tap()
    let sync = app.switches["Apple Reminders"]
    XCTAssertTrue(sync.waitForExistence(timeout: 5))
    if sync.value as? String != "1" {
      sync.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      for name in ["Allow Full Access", "Allow"] {
        if springboard.buttons[name].waitForExistence(timeout: 3) {
          springboard.buttons[name].tap()
          break
        }
      }
    }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: sync)],
        timeout: 8), .completed)
    if includeCalendar {
      app.buttons["Done"].tap()
      app.closeSidebar()
      enableCalendarSync(app)
      // Reopening Settings reads the adapter state, not the toggle's optimistic local value.
      app.openSidebar()
      app.buttons["Settings"].firstMatch.tap()
      XCTAssertEqual(app.switches["Apple Calendar"].value as? String, "1")
      app.buttons["Done"].tap()
      app.closeSidebar()
    }
    app.terminate()
  }

  private func assertState(
    _ app: XCUIApplication, done: Bool, file: StaticString = #filePath, line: UInt = #line
  ) {
    for side in ["apple", "app", "persisted"] {
      let probe = app.staticTexts["syncDump.\(side)"]
      let check = NSPredicate(format: "label CONTAINS %@", done ? "|done|" : "|open|")
      XCTAssertEqual(
        XCTWaiter.wait(for: [expectation(for: check, evaluatedWith: probe)], timeout: 20),
        .completed,
        "\(side): \(probe.exists ? probe.label : "missing")", file: file, line: line)
    }
  }

  private func fixtureTitle() throws -> String {
    let data = try Data(
      contentsOf: URL(fileURLWithPath: TestData.fixturePath("today-reminder-completion.json")))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try XCTUnwrap((object["reminders"] as? [[String: Any]])?.first?["title"] as? String)
  }

  /// Actual simulator EventKit imports exercise the production adapters, not empty/local-only Mock rows.
  func testImportedTimelineNavigationAndCancelledEditorsStayResponsive() throws {
    connect(includeCalendar: true)
    try assertImportedTimelineJourney()
  }

  private func assertImportedTimelineJourney() throws {
    let data = try Data(
      contentsOf: URL(fileURLWithPath: TestData.fixturePath("phone-freeze-navigation.json")))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    let suffix = String(UUID().uuidString.prefix(8))
    let title = try XCTUnwrap(fixture["reminderTitle"]) + " " + suffix
    let eventTitle = try XCTUnwrap(fixture["eventTitle"]) + " " + suffix
    let app = launch(
      title: title, store: "freeze-navigation-" + suffix, seed: true,
      extra: ["-uiTestingCalendarSync", "-debugCreateSystemEvent", eventTitle])
    assertState(app, done: false)
    XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 8))
    let event = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH %@", eventTitle)
    ).firstMatch
    XCTAssertTrue(event.waitForExistence(timeout: 8), "native Calendar import is rendered")
    // Resolve each target while it is ready, before measuring its touch-to-state response.
    // XCUIElement.tap resolves the AX tree again before synthesizing a touch (8.34s across
    // these two targets in CI run 39466973063); that is not time after a user's touch.
    let journeyStarted = ProcessInfo.processInfo.systemUptime
    let open = readyCoordinate(app.staticTexts[title].firstMatch, in: app)
    let started = ProcessInfo.processInfo.systemUptime
    open.tap()
    XCTAssertTrue(app.textFields["task.title"].waitForExistence(timeout: 5))
    let opened = ProcessInfo.processInfo.systemUptime
    let cancel = readyCoordinate(app.buttons["task.cancel"].firstMatch, in: app)
    let cancelStarted = ProcessInfo.processInfo.systemUptime
    cancel.tap()
    XCTAssertTrue(app.textFields["task.title"].waitForNonExistence(timeout: 5))
    let returned = ProcessInfo.processInfo.systemUptime
    let response = (opened - started) + (returned - cancelStarted)
    print(
      "SMOKE_EDITOR open_prepare_s=\(started - journeyStarted) open_response_s=\(opened - started) "
        + "cancel_prepare_s=\(cancelStarted - opened) cancel_response_s=\(returned - cancelStarted) "
        + "response_s=\(response) wall_s=\(returned - journeyStarted)")
    XCTAssertLessThan(
      response, 10,
      "editor opens and cancels without a scene watchdog stall")
    for tab in ["Calendar", "Reminders", "Clock", "Today"] {
      app.buttons[tab].firstMatch.tap()
      let destination: XCUIElement
      switch tab {
      case "Calendar": destination = app.descendants(matching: .any)["calendar.dayGrid"]
      case "Reminders": destination = app.staticTexts["My Lists"]
      case "Clock": destination = app.buttons["World Clock"]
      default: destination = app.weekStripDay(.now)
      }
      XCTAssertTrue(destination.waitForExistence(timeout: 5), "the tap presents " + tab)
    }
    XCTAssertTrue(app.weekStripDay(.now).waitForExistence(timeout: 5))
    app.buttons["Ask AI or add anything"].firstMatch.tap()
    try assertChatDraftAndClose(in: app, draft: XCTUnwrap(fixture["chatDraft"]))
    XCTAssertTrue(app.weekStripDay(.now).waitForExistence(timeout: 5))
    assertState(app, done: false)
  }

  /// Coordinates come from the current hittable element, never a fixed screen location.
  /// The timed interval still includes event synthesis, app execution, idling and AX state checks.
  private func readyCoordinate(_ element: XCUIElement, in app: XCUIApplication)
    -> XCUICoordinate
  {
    XCTAssertTrue(element.isHittable, "The measured control must be ready for a user touch")
    let frame = element.frame
    let appFrame = app.frame
    XCTAssertFalse(frame.isEmpty)
    XCTAssertTrue(appFrame.contains(frame), "The measured control must be visible")
    return app.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: frame.midX - appFrame.minX, dy: frame.midY - appFrame.minY))
  }

  /// Isolates keyboard synchronization from the native-import journey without replacing that regression.
  func testChatDraftAndCloseRemainResponsive() throws {
    let data = try Data(
      contentsOf: URL(fileURLWithPath: TestData.fixturePath("phone-freeze-navigation.json")))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    let draft = try XCTUnwrap(fixture["chatDraft"])
    let app = XCUIApplication()
    app.launchArguments = TestData.launchArguments
    app.launch()
    XCTAssertTrue(app.buttons["Ask AI or add anything"].firstMatch.waitForExistence(timeout: 5))
    app.buttons["Ask AI or add anything"].firstMatch.tap()
    try assertChatDraftAndClose(in: app, draft: draft)
    XCTAssertTrue(app.buttons["Today"].firstMatch.isSelected)
    XCTAssertTrue(app.buttons["Ask AI or add anything"].firstMatch.isHittable)
  }

  private func assertChatDraftAndClose(in app: XCUIApplication, draft: String) throws {
    let field = app.textViews["Ask AI or add anything"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    field.typeText(draft)
    // A vertical TextField loses its placeholder after entry; XCTest disagrees on its native type.
    let entered = app.descendants(matching: .any).matching(
      NSPredicate(format: "value == %@", draft)
    ).firstMatch
    XCTAssertTrue(
      entered.waitForExistence(timeout: 5), "Native keyboard input remains an unsent draft")
    XCTAssertEqual(entered.value as? String, draft)
    XCTAssertTrue(app.buttons["ask-send"].exists)
    XCTAssertFalse(app.staticTexts[draft].exists, "Typing alone does not send the draft")
    app.buttons["chat.close"].tap()
    let closed = XCTAttachment(screenshot: app.screenshot())
    closed.name = "Imported timeline after Chat Close"
    closed.lifetime = .keepAlways
    add(closed)
    XCTAssertTrue(entered.waitForNonExistence(timeout: 5))
    XCTAssertFalse(app.textViews["ask-input"].exists, "Close removes the editor from accessibility")
    let chat = app.buttons["Ask AI or add anything"].firstMatch
    XCTAssertTrue(chat.isHittable, "The underlying page is usable after Close")
    chat.tap()
    let reopened = app.textViews["ask-input"].firstMatch
    XCTAssertTrue(reopened.waitForExistence(timeout: 5))
    XCTAssertNotEqual(
      reopened.value as? String, draft, "Each tap starts a new chat; the unsent draft is dropped")
    XCTAssertFalse(app.staticTexts[draft].exists, "Reopening does not submit the draft")
    app.buttons["chat.close"].tap()
    XCTAssertTrue(reopened.waitForNonExistence(timeout: 5))
  }

  func testCompactEditorEditAndDeleteFailuresRetryAcrossInFlightSync() throws {
    connect()
    let title = "TX\(UUID().uuidString.prefix(8)) Editor commit"
    let store = "editor-write-\(UUID().uuidString)"
    let control = title + " control"
    var app = launch(
      title: title, store: store, seed: true,
      extra: [
        "-uiTestingReminderEditMetadata", "-uiTestingFailReminderEditOnce",
        "-uiTestingFailReminderDeleteOnce",
        "-uiTestingDelayReminderFetchAfterFirst",
        "-uiTestingAppleOp", "addToday", control, "_",
      ])
    func wait(_ element: XCUIElement, _ format: String, _ value: String, timeout: TimeInterval = 25)
    {
      XCTAssertEqual(
        XCTWaiter.wait(
          for: [
            expectation(
              for: NSPredicate(format: format, value),
              evaluatedWith: element)
          ], timeout: timeout), .completed, element.debugDescription)
    }
    func assertTime(_ minutes: Int) {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyy-MM-dd"
      let expected = "\(title)|open|\(f.string(from: .now)) 14:\(String(format: "%02d", minutes))|-"
      for side in ["apple", "app", "persisted"] {
        wait(app.staticTexts["syncDump.\(side)"], "label CONTAINS %@", expected)
      }
    }
    assertTime(0)
    app.staticTexts[title].firstMatch.tap()
    app.buttons["+10 min"].tap()
    app.buttons["task.save"].tap()
    XCTAssertTrue(app.alerts["Couldn’t Update Reminder"].waitForExistence(timeout: 5))
    app.alerts.buttons["OK"].tap()
    XCTAssertTrue(app.textFields["task.title"].exists)
    XCTAssertTrue(app.buttons["task.save"].isEnabled, "the failed draft remains retryable")
    app.buttons["task.save"].tap()
    XCTAssertTrue(app.textFields["task.title"].waitForNonExistence(timeout: 5))
    assertTime(10)
    app.staticTexts[title].firstMatch.tap()
    XCUIDevice.shared.press(.home)
    app.activate()
    wait(app.staticTexts["syncDump.fetch"], "label == %@", "fetching")
    app.buttons["+10 min"].tap()
    app.buttons["task.save"].tap()
    XCTAssertTrue(app.textFields["task.title"].waitForNonExistence(timeout: 5))
    wait(app.staticTexts["syncDump.rejected"], "label != %@", "0")
    assertTime(20)
    let metadata = app.staticTexts["syncDump.metadata"].label.components(separatedBy: ";").first {
      $0.contains("14:20")
    }
    XCTAssertNotNil(metadata)
    app.staticTexts[title].firstMatch.tap()
    app.buttons["Delete task"].tap()
    XCTAssertTrue(app.alerts["Couldn’t Update Reminder"].waitForExistence(timeout: 5))
    app.alerts.buttons["OK"].tap()
    XCTAssertTrue(
      app.textFields["task.title"].exists,
      "a refused system delete leaves the editor and local object intact")
    app.buttons["Delete task"].tap()
    XCTAssertTrue(app.textFields["task.title"].waitForNonExistence(timeout: 5))
    app.buttons["Undo"].tap()
    assertTime(20)
    let restored = app.staticTexts["syncDump.metadata"].label.components(separatedBy: ";").first {
      $0.contains("14:20")
    }
    XCTAssertEqual(
      restored?.components(separatedBy: "|").dropFirst(),
      metadata?.components(separatedBy: "|").dropFirst(),
      "Undo preserves the native reminder payload, with a new system identity")
    app.staticTexts[title].firstMatch.tap()
    app.buttons["Delete task"].tap()
    XCTAssertTrue(app.textFields["task.title"].waitForNonExistence(timeout: 5))
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    let remaining = "\(control)|open|\(f.string(from: .now)) 14:00|-"
    for side in ["apple", "app", "persisted"] {
      wait(app.staticTexts["syncDump.\(side)"], "label == %@", remaining)
    }
    app.terminate()
    app = launch(title: title, store: store)
    for side in ["apple", "app", "persisted"] {
      wait(app.staticTexts["syncDump.\(side)"], "label == %@", remaining)
    }
    XCTAssertFalse(
      app.staticTexts[title].exists,
      "a confirmed deletion does not reappear after refresh and relaunch")
  }

  func testCompactEditorCompletionFailureRetryWritebackAndUndo() throws {
    connect()
    let unique = UUID().uuidString.prefix(8)
    let title = "TE\(unique) " + (try fixtureTitle())
    let store = "editor-completion-\(unique)"
    var app = launch(title: title, store: store, seed: true, fail: true)
    assertState(app, done: false)
    app.staticTexts[title].firstMatch.tap()
    XCTAssertTrue(app.textFields["task.title"].waitForExistence(timeout: 5))
    app.buttons["Mark done"].tap()
    XCTAssertTrue(app.alerts["Couldn’t Update Reminder"].waitForExistence(timeout: 5))
    app.alerts.buttons["OK"].tap()
    XCTAssertTrue(app.textFields["task.title"].exists, "failure keeps the editor for retry")
    app.buttons["Cancel"].tap()
    assertState(app, done: false)
    app.terminate()
    app = launch(title: title, store: store)
    assertState(app, done: false)
    app.staticTexts[title].firstMatch.tap()
    app.buttons["Mark done"].tap()
    XCTAssertTrue(app.textFields["task.title"].waitForNonExistence(timeout: 5))
    assertState(app, done: true)
    app.buttons["Undo"].tap()
    assertState(app, done: false)
    app.terminate()
    app = launch(title: title, store: store)
    assertState(app, done: false)
  }

  func testTodayCompletionCommitsToAppleAndSurvivesRefreshAndRelaunch() throws {
    connect()
    let unique = UUID().uuidString.prefix(8)
    let title = "TC\(unique) " + (try fixtureTitle())
    let store = "today-completion-\(unique)"
    var app = launch(title: title, store: store, seed: true)
    assertState(app, done: false)
    let circle = app.buttons["Complete \(title)"].firstMatch
    XCTAssertTrue(circle.waitForExistence(timeout: 8))
    circle.tap()
    assertState(app, done: true)
    XCTAssertFalse(app.buttons["Complete \(title)"].exists)
    // After post-completion reconciliation, return to the foreground and restart the same file-backed store.
    XCUIDevice.shared.press(.home)
    app.activate()
    assertState(app, done: true)
    app.terminate()
    app = launch(title: title, store: store)
    assertState(app, done: true)
    XCTAssertFalse(app.buttons["Complete \(title)"].exists)
  }

  func testFailedCompletionKeepsAppleAndLocalOpenAndCanRetry() throws {
    connect()
    let unique = UUID().uuidString.prefix(8)
    let title = "TF\(unique) " + (try fixtureTitle())
    let store = "today-failed-completion-\(unique)"
    var app = launch(title: title, store: store, seed: true, fail: true)
    assertState(app, done: false)
    let circle = app.buttons["Complete \(title)"].firstMatch
    XCTAssertTrue(circle.waitForExistence(timeout: 8))
    circle.tap()
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Couldn’t update Apple Reminders")
      ).firstMatch.waitForExistence(timeout: 3))
    XCTAssertTrue(circle.exists)
    assertState(app, done: false)
    app.terminate()
    app = launch(title: title, store: store)
    assertState(app, done: false)
    app.buttons["Complete \(title)"].firstMatch.tap()
    assertState(app, done: true)
  }
}
