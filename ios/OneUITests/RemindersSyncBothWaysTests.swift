import XCTest

/// Apple Reminders sync, both directions: complete, rename, delete and repeat, on each side, read back from both sides.
/// The app changes Apple Reminders and its own data through debug launch arguments (`-uiTestingAppleOp`,
/// `-uiTestingAppOp`, see `RemindersSync`), so nothing is typed, and reads both sides from hidden labels
/// (`-uiTestingSyncDump`). Needs Reminders access on the simulator (allowed on the first run, or
/// `xcrun simctl privacy <udid> grant reminders com.luworks.today`).
@MainActor
final class RemindersSyncBothWaysTests: XCTestCase {
  private let stamp = Int(Date.now.timeIntervalSince1970) % 100000

  private func day(_ offset: Int) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Calendar.current.date(byAdding: .day, value: offset, to: .now)!)
      + " 09:00"
  }

  private func launch(
    prefix: String, store: String? = nil, apple: [[String]] = [], app ops: [[String]] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    var args = ["-uiTesting", "-uiTestingRemindersSync", "-uiTestingSyncDump", prefix]
    if let store { args += ["-uiTestingStore", store] }
    for op in apple { args += ["-uiTestingAppleOp"] + op }
    for op in ops { args += ["-uiTestingAppOp"] + op }
    app.launchArguments = args
    app.launch()
    return app
  }

  /// Turns on Apple Reminders in Settings once (it stays on across launches).
  private func connect() {
    let app = launch(prefix: "none")
    app.openSidebar()
    app.buttons["Settings"].firstMatch.tap()
    let sync = app.switches["Apple Reminders"]
    XCTAssertTrue(sync.waitForExistence(timeout: 5))
    if (sync.value as? String) != "1" {
      sync.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      for name in ["Allow Full Access", "Allow"] {
        let allow = springboard.buttons[name]
        if allow.waitForExistence(timeout: 5) {
          allow.tap()
          break
        }
      }
    }
    let on = NSPredicate(format: "value == '1'")
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation(for: on, evaluatedWith: sync)], timeout: 8), .completed,
      "sync is on")
    app.terminate()
  }

  /// Waits until a side's dump satisfies `check`; fails with the last value seen.
  private func waitDump(
    _ app: XCUIApplication, _ side: String, timeout: TimeInterval = 25,
    _ what: String, _ check: (String) -> Bool
  ) {
    let label = app.staticTexts["syncDump.\(side)"]
    let end = Date.now.addingTimeInterval(timeout)
    var last = ""
    while Date.now < end {
      if label.exists {
        last = label.label
        if check(last) { return }
      }
      Thread.sleep(forTimeInterval: 1)
    }
    XCTFail("\(side): \(what). Last dump: \(last)")
  }

  func testAppChangesReachAppleReminders() {
    connect()
    let p = "SA\(stamp) "
    let app = launch(
      prefix: p,
      apple: [
        ["add", p + "done", "_"], ["add", p + "edit", "_"], ["add", p + "gone", "_"],
        ["add", p + "plain", "_"],
      ],
      app: [
        ["complete", p + "done", "_"], ["rename", p + "edit", p + "edited"],
        ["delete", p + "gone", "_"], ["repeat", p + "plain", "daily"],
      ])
    let due = day(1)
    let expected = [
      "\(p)done|done|\(due)|-", "\(p)edited|open|\(due)|-", "\(p)plain|open|\(due)|daily",
    ].joined(separator: ";")
    waitDump(app, "apple", "complete, rename, delete and repeat reach Apple") { $0 == expected }
    waitDump(app, "app", "the app agrees") { $0 == expected }
  }

  func testAppleChangesReachTheApp() {
    connect()
    let p = "SB\(stamp) "
    let store = "sync-\(stamp)"
    var app = launch(
      prefix: p, store: store,
      apple: [
        ["add", p + "done", "_"], ["add", p + "edit", "_"], ["add", p + "gone", "_"],
        ["add", p + "plain", "_"],
      ])
    waitDump(app, "app", "the app pulls four reminders") {
      $0.components(separatedBy: ";").count == 4
    }
    app.terminate()

    // Same local store, so this is an edit of linked reminders, not a fresh pull.
    app = launch(
      prefix: p, store: store,
      apple: [
        ["complete", p + "done", "_"], ["rename", p + "edit", p + "edited"],
        ["delete", p + "gone", "_"],
      ])
    let due = day(1)
    let expected = [
      "\(p)done|done|\(due)|-", "\(p)edited|open|\(due)|-", "\(p)plain|open|\(due)|-",
    ].joined(separator: ";")
    waitDump(app, "app", "Apple's complete, rename and delete reach the app") { $0 == expected }
  }

  /// Completing a repeating reminder in the app rolls the same Apple reminder forward, like Apple Reminders does,
  /// and the app ends with exactly one open copy at the next date.
  func testCompletingARepeatingReminderInTheAppRollsItForward() {
    connect()
    let p = "SC\(stamp) "
    let app = launch(
      prefix: p, apple: [["add", p + "daily", "daily"]], app: [["complete", p + "daily", "_"]])
    let next = "\(p)daily|open|\(day(2))|daily"
    waitDump(app, "apple", "Apple has the next occurrence open") { $0.contains(next) }
    waitDump(app, "app", "the app has exactly one open copy, at the next date") { dump in
      dump.contains(next)
        && dump.components(separatedBy: ";").filter { $0.contains("|open|") }.count == 1
    }
  }

  func testCompletingARepeatingReminderInAppleRollsItForwardInTheApp() {
    connect()
    let p = "SD\(stamp) "
    let store = "sync-d-\(stamp)"
    var app = launch(prefix: p, store: store, apple: [["add", p + "daily", "daily"]])
    waitDump(app, "app", "the app pulls it") { $0.contains("\(p)daily|open|\(self.day(1))|daily") }
    app.terminate()
    app = launch(prefix: p, store: store, apple: [["complete", p + "daily", "_"]])
    let next = "\(p)daily|open|\(day(2))|daily"
    waitDump(app, "app", "the app has exactly one open copy, at the next date") { dump in
      dump.contains(next)
        && dump.components(separatedBy: ";").filter { $0.contains("|open|") }.count == 1
    }
  }
}
