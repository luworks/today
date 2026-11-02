import XCTest

@MainActor
extension XCUIApplication {
  /// + is one menu on every page; open it and pick `choice` ("New alarm", "New reminder", "New event", "Add city").
  func addNew(_ choice: String, file: StaticString = #filePath, line: UInt = #line) {
    buttons["New"].firstMatch.tap()
    let item = buttons[choice].firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 3), "+ offers \(choice)", file: file, line: line)
    item.tap()
  }

  /// There is no avatar button: the sidebar opens with a swipe from the left edge, like in ChatGPT or Claude.
  func openSidebar() {
    let start = coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
    let end = coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: end)
  }

  /// Smart lists and pinned lists share one horizontal row. Search both ways because its offset survives navigation
  /// and its order can change. Drag within that row so the app's tab swipe gesture is not used.
  func revealReminderPill(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line)
  {
    func visible(_ pill: XCUIElement) -> Bool {
      pill.isFullyVisible(in: frame) && pill.isHittable
    }
    if visible(target) { return }
    let pills = descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'smart.' OR identifier BEGINSWITH 'pinned.'"))
    let startsTowardsEnd = !target.exists || target.frame.minX >= frame.minX
    for towardsEnd in [startsTowardsEnd, !startsTowardsEnd] {
      for _ in 0..<12 {
        if visible(target) { return }
        guard let anchor = pills.allElementsBoundByIndex.first(where: { visible($0) }) else {
          XCTFail("No visible reminder pill to scroll", file: file, line: line)
          return
        }
        let y = anchor.frame.midY - frame.minY
        let from = coordinate(withNormalizedOffset: .zero).withOffset(
          CGVector(dx: frame.width * (towardsEnd ? 0.85 : 0.15), dy: y))
        let to = coordinate(withNormalizedOffset: .zero).withOffset(
          CGVector(dx: frame.width * (towardsEnd ? 0.15 : 0.85), dy: y))
        from.press(forDuration: 0.05, thenDragTo: to)
      }
    }
    XCTAssertTrue(
      visible(target), "Reminder pill is on screen and hittable: \(target)", file: file, line: line)
  }

  /// The Timer screen exposes one native CollectionView, including when the picker has scrolled out of view.
  private var timerList: XCUIElement { collectionViews["timer.list"].firstMatch }

  var timerViewport: CGRect {
    guard timerList.exists else { return .null }
    let bounds = timerList.frame.intersection(frame)
    let composer = buttons["Ask AI or add anything"].firstMatch
    let bottom = composer.exists ? min(bounds.maxY, composer.frame.minY) : bounds.maxY
    return CGRect(
      x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, bottom - bounds.minY))
  }

  /// Require the complete control above the floating composer, not just existence in the lazy List.
  func revealTimerControl(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line)
  {
    func visible() -> Bool {
      target.isFullyVisible(in: timerViewport)
        && (target.elementType == .staticText || target.isHittable)
    }
    for searchUp in [true, false] {
      for _ in 0..<8 {
        if visible() { return }
        var up = searchUp
        if target.exists {
          let bounds = target.frame
          if bounds.isFiniteAndNonempty {
            if bounds.minY < timerViewport.minY {
              up = false
            } else if bounds.maxY > timerViewport.maxY {
              up = true
            }
          }
        }
        if !scrollTimerList(up: up, file: file, line: line) { break }
      }
    }
    XCTAssertTrue(
      visible(),
      "Timer content is fully visible; controls remain hittable: \(target); frame: \(target.frame); viewport: \(timerViewport)",
      file: file, line: line)
  }

  /// Drag inside the native List, below the actual full-width UIPickerView, and stop at a content boundary.
  @discardableResult
  private func scrollTimerList(up: Bool, file: StaticString, line: UInt) -> Bool {
    var region = timerViewport.insetBy(dx: 12, dy: 12)
    let picker = descendants(matching: .any)["timer.wheel"].firstMatch
    if picker.exists, picker.frame.isFiniteAndNonempty, picker.frame.intersects(region) {
      let above = CGRect(
        x: region.minX, y: region.minY, width: region.width,
        height: max(0, picker.frame.minY - 12 - region.minY))
      let belowTop = min(region.maxY, picker.frame.maxY + 12)
      let below = CGRect(
        x: region.minX, y: belowTop, width: region.width, height: region.maxY - belowTop)
      region = below.height >= above.height ? below : above
    }
    guard region.isFiniteAndNonempty, region.height >= 60 else {
      XCTFail("No Timer List drag region outside the picker: \(region)", file: file, line: line)
      return false
    }
    let recentCell = timerList.cells.containing(.button, identifier: "timer.recent.start")
      .firstMatch
    let marker = recentCell.exists ? recentCell : timerList.cells.firstMatch
    let before = marker.exists ? marker.frame : .null
    let wheels = pickerWheels.allElementsBoundByIndex.map { $0.value as? String }
    // The middle of a visible Recent cell is inside the List, rather than its right-edge scroll indicator.
    let recentCells = timerList.cells.containing(.button, identifier: "timer.recent.start")
      .allElementsBoundByIndex
    let candidates = recentCells.map { $0.frame.intersection(region) }.filter {
      $0.isFiniteAndNonempty && $0.height >= 40
    }
    let anchor = up ? candidates.last : candidates.first
    let startY = anchor?.midY ?? (up ? region.maxY - 8 : region.minY + 8)
    let distance = min(240, region.height * 0.6)
    let endY = up ? max(region.minY, startY - distance) : min(region.maxY, startY + distance)
    let origin = coordinate(withNormalizedOffset: .zero)
    let start = origin.withOffset(CGVector(dx: region.midX - frame.minX, dy: startY - frame.minY))
    let end = origin.withOffset(CGVector(dx: region.midX - frame.minX, dy: endY - frame.minY))
    start.press(forDuration: 0.05, thenDragTo: end)
    let afterWheels = pickerWheels.allElementsBoundByIndex.map { $0.value as? String }
    if wheels.count == 3 && afterWheels.count == 3 {
      XCTAssertEqual(
        afterWheels, wheels, "Scrolling the List must not turn hours, minutes or seconds",
        file: file, line: line)
    }
    let after = marker.exists ? marker.frame : .null
    return before != after
  }

  func scrollTimerToTop(file: StaticString = #filePath, line: UInt = #line) {
    let top = descendants(matching: .any)["timer.picker"].firstMatch
    for _ in 0..<8 {
      if top.isFullyVisible(in: timerViewport) && top.isHittable { return }
      if !scrollTimerList(up: false, file: file, line: line) { break }
    }
    XCTAssertTrue(
      top.isFullyVisible(in: timerViewport) && top.isHittable,
      "The wheel is visible after scrolling to the top", file: file, line: line)
  }

  /// The Form can extend behind its navigation bar and home indicator. Only accept rows inside its usable viewport.
  var settingsRowViewport: CGRect {
    let screen = frame
    let form = collectionViews.allElementsBoundByIndex.last(where: { $0.isFullyVisible(in: screen) }
    )
    var viewport = form?.frame.intersection(screen) ?? screen
    let navigation = navigationBars["Settings"]
    let top = navigation.exists ? max(viewport.minY, navigation.frame.maxY + 8) : viewport.minY
    let bottom = min(viewport.maxY, screen.maxY - 44)
    viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, bottom - top))
    return viewport
  }

  /// SwiftUI Form rows are lazy: scroll before requiring an off-screen control to exist or be hittable.
  func revealSettingsRow(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line)
  {
    func visible() -> Bool {
      element.isFullyVisible(in: settingsRowViewport) && element.isHittable
    }
    for _ in 0..<12 {
      if visible() { return }
      let viewport = settingsRowViewport
      let towardsTop = element.exists && element.frame.minY < viewport.minY
      let origin = coordinate(withNormalizedOffset: .zero)
      let start = origin.withOffset(
        CGVector(
          dx: viewport.midX - frame.minX,
          dy: viewport.minY - frame.minY + viewport.height * (towardsTop ? 0.35 : 0.8)))
      let end = origin.withOffset(
        CGVector(
          dx: viewport.midX - frame.minX,
          dy: viewport.minY - frame.minY + viewport.height * (towardsTop ? 0.8 : 0.35)))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    XCTAssertTrue(
      visible(), "Settings row is fully visible and hittable: \(element)", file: file, line: line)
  }

  /// The sidebar is a full screen with no Today row, and Settings opens over it, so after Settings the sidebar is still open.
  func closeSidebar() {
    let close = buttons["Close sidebar"]
    // A tap while the sidebar is still sliding open can be lost: tap again if it is still open.
    for _ in 0..<2 where close.waitForExistence(timeout: 3) {
      close.tap()
      if close.waitForNonExistence(timeout: 2) { break }
    }
    // The page slides back for a moment after the tap; a tap on it meanwhile is lost. Wait until it is back in place
    // (its menu button at the left edge again).
    let menu = buttons["Open menu"]
    let deadline = Date().addingTimeInterval(3)
    while menu.exists, menu.frame.minX > 30, Date() < deadline { usleep(100_000) }
  }
}

extension CGRect {
  fileprivate var isFiniteAndNonempty: Bool {
    !isNull && !isEmpty && [minX, minY, maxX, maxY].allSatisfy { $0.isFinite }
  }
}

@MainActor
extension XCUIApplication {
  /// The Today tab's week strip button for a day ("weekStrip.2026-10-26"); it is selected while Today shows that day.
  func weekStripDay(_ date: Date) -> XCUIElement {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return buttons[String(format: "weekStrip.%04d-%02d-%02d", c.year!, c.month!, c.day!)]
  }

  /// Taps the bottom bar's Today button and waits until Today shows today itself.
  func returnToToday(file: StaticString = #filePath, line: UInt = #line) {
    buttons["Today"].firstMatch.tap()
    XCTAssertTrue(
      weekStripDay(.now).waitForSelected(), "the Today button shows today", file: file, line: line)
  }
}

@MainActor
extension XCUIElement {
  /// Waits for the selected trait, e.g. the week strip day Today is showing.
  func waitForSelected(timeout: TimeInterval = 5) -> Bool {
    let selected = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isSelected == true"), object: self)
    return XCTWaiter().wait(for: [selected], timeout: timeout) == .completed
  }

  /// Check geometry before isHittable: XCTest can throw while deriving an off-screen element's activation point.
  func isFullyVisible(in viewport: CGRect) -> Bool {
    guard exists else { return false }
    let bounds = frame
    guard !bounds.isNull, !bounds.isEmpty, !viewport.isNull, !viewport.isEmpty,
      [
        bounds.minX, bounds.minY, bounds.maxX, bounds.maxY,
        viewport.minX, viewport.minY, viewport.maxX, viewport.maxY,
      ].allSatisfy({ $0.isFinite })
    else { return false }
    return viewport.contains(bounds)
  }

  /// Flips a switch by tapping its knob (a tap on the middle of a labeled switch can land on the label and do nothing)
  /// and waits for the new value, so the next line sees it.
  func toggleSwitch(file: StaticString = #filePath, line: UInt = #line) {
    let before = value as? String
    coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    let changed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != %@", before ?? ""), object: self)
    XCTAssertEqual(
      XCTWaiter().wait(for: [changed], timeout: 3), .completed, "the switch flipped", file: file,
      line: line)
  }
}

/// Versioned UI datasets in tests/fixtures, resolved from this source file's repository root.
enum TestData {
  static func fixturePath(_ name: String) -> String {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "tests/fixtures")
      .appending(path: name).path
  }

  /// Launch arguments for a fresh in-memory store filled from a named fixture.
  static func fixtureArguments(_ name: String) -> [String] {
    ["-uiTesting", "-dataset", fixturePath(name)]
  }

  static let path = fixturePath("today-dataset.json")
  static var launchArguments: [String] { fixtureArguments("today-dataset.json") }
}

@MainActor
extension XCTestCase {
  /// Turns on Apple Calendar in Settings (sidebar > Settings), answering the access prompt the first time. Does nothing
  /// when it is already on. Leaves the sidebar closed.
  func enableCalendarSync(_ app: XCUIApplication) {
    let monitor = addUIInterruptionMonitor(withDescription: "Calendar access") { alert in
      for label in ["Allow Full Access", "Allow", "OK"] where alert.buttons[label].exists {
        alert.buttons[label].tap()
        return true
      }
      return false
    }
    defer { removeUIInterruptionMonitor(monitor) }
    app.openSidebar()
    app.buttons["Settings"].firstMatch.tap()
    let toggle = app.switches["Apple Calendar"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if (toggle.value as? String) != "1" {
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
      // Wait for the alert itself: the toggle's optimistic value does not mean authorization finished.
      // System alerts invoke the monitor on an interaction, not an existence query.
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      _ = springboard.alerts.firstMatch.waitForExistence(timeout: 5)
      app.tap()
    }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)],
        timeout: 8), .completed)
    app.buttons["Done"].tap()
    app.closeSidebar()
  }

  /// The Month grid's identifier for a day cell.
  func calendarDayID(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "day.%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
}

extension XCUIApplication {
  /// The alarm editor's minute wheel (five-minute steps, or every minute for an off-grid alarm): a slow drag moves it
  /// one row, so drag until it reads `target` ("00", "30"). The wheel wraps, so a full turn is at most 60 drags.
  @MainActor
  func setAlarmMinutes(_ target: String, file: StaticString = #filePath, line: UInt = #line) {
    let minutes = descendants(matching: .any)["wheelLab.minutes"].firstMatch
    XCTAssertTrue(minutes.waitForExistence(timeout: 5), "the minute wheel", file: file, line: line)
    for _ in 0..<60 {
      if (minutes.value as? String) == target { return }
      let from = minutes.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      from.withOffset(CGVector(dx: 0, dy: 0)).press(
        forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -40)),
        withVelocity: .slow, thenHoldForDuration: 0.3)
    }
    XCTAssertEqual(minutes.value as? String, target, "the minute wheel", file: file, line: line)
  }
}
