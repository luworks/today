import UIKit
import XCTest

/// The Settings choices added with `Preferences`: Dim past days, no weekend shading, first day of the week, week numbers,
/// where Calendar opens, the Today choices (free time), and new-item defaults.
/// `-uiTesting` starts every launch from the defaults; `-uiTestingPrefs key=value,...` sets what a test needs up front,
/// and the tests that say "in Settings" flip the real switches.
@MainActor
final class SettingsChoicesTests: XCTestCase {
  private var app: XCUIApplication!
  private let cal = Calendar.current

  private func launch(prefs: String? = nil, now: String? = nil) {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = TestData.launchArguments
    if let prefs { app.launchArguments += ["-uiTestingPrefs", prefs] }
    if let now { app.launchArguments += ["-uiTestingNow", now] }
    app.launch()
  }

  private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

  // MARK: Settings navigation

  private func openSettings() {
    app.openSidebar()
    app.buttons["Settings"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
  }

  private func closeSettings() {
    app.buttons["Done"].tap()
    app.closeSidebar()
  }

  /// Scrolls the Settings form until the row is on screen (rows below the fold are not in the hierarchy yet).
  @discardableResult
  private func reveal(_ element: XCUIElement) -> XCUIElement {
    for _ in 0..<14 where !(element.exists && element.isHittable) { app.swipeUp() }
    XCTAssertTrue(element.exists && element.isHittable, "\(element) is on screen in Settings")
    // Near the bottom edge a tap can land on the home indicator: bring the row up into the middle.
    if element.frame.midY > app.frame.height * 0.7 { app.swipeUp(velocity: .slow) }
    return element
  }

  // MARK: Calendar helpers

  private func showMonth() {
    app.buttons["Calendar"].firstMatch.tap()
    let month = app.buttons["calendar.mode.month"]
    XCTAssertTrue(month.waitForExistence(timeout: 5))
    month.tap()
    XCTAssertTrue(element("calendar.monthPager").waitForExistence(timeout: 5))
  }

  private func dayID(_ date: Date) -> String {
    let c = cal.dateComponents([.year, .month, .day], from: date)
    return String(format: "day.%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }

  private func dayCell(_ date: Date) -> XCUIElement { element(dayID(date)) }

  /// A day of this month with the given weekday (1 = Sunday), between the 5th and the 25th so it is a full week away
  /// from the edges of the month.
  private func dayInMonth(weekday: Int) -> Date {
    let today = Date.now
    for d in 5...25 {
      var c = cal.dateComponents([.year, .month], from: today)
      c.day = d
      let date = cal.date(from: c)!
      if cal.component(.weekday, from: date) == weekday { return date }
    }
    fatalError("every weekday occurs between the 5th and the 25th")
  }

  // MARK: Pixels (XCUITest cannot read colors, so look at the screen)

  @MainActor
  private struct Pixels {
    let image: CGImage
    let scale: CGFloat

    init() {
      let shot = XCUIScreen.main.screenshot().image
      image = shot.cgImage!
      scale = shot.scale
    }

    private func luma(x: Int, y: Int) -> Int {
      var px = [UInt8](repeating: 0, count: 4)
      let space = CGColorSpaceCreateDeviceRGB()
      let ctx = CGContext(
        data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(
        image,
        in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
      return (Int(px[0]) * 299 + Int(px[1]) * 587 + Int(px[2]) * 114) / 1000
    }

    /// Brightness (0...255) of the screen at a point (in points).
    func luma(at p: CGPoint) -> Int { luma(x: Int(p.x * scale), y: Int(p.y * scale)) }

    /// How far the darkest or brightest pixel in `frame` is from the background at its top-left corner.
    func contrast(in frame: CGRect) -> Int {
      let bg = luma(at: CGPoint(x: frame.minX + 3, y: frame.minY + 4))
      var best = 0
      var y = frame.minY + 4
      while y < frame.maxY - 4 {
        var x = frame.minX + 4
        while x < frame.maxX - 4 {
          best = max(best, abs(luma(at: CGPoint(x: x, y: y)) - bg))
          x += 1
        }
        y += 1
      }
      return best
    }
  }

  // MARK: Dim past days

  func testDimPastDaysSettingTurnsTheDimmingOffAndOn() throws {
    launch()
    let yesterday = cal.date(byAdding: .day, value: -1, to: .now)!
    let tomorrow = cal.date(byAdding: .day, value: 1, to: .now)!
    try XCTSkipUnless(
      cal.isDate(yesterday, equalTo: .now, toGranularity: .month)
        && cal.isDate(tomorrow, equalTo: .now, toGranularity: .month),
      "needs yesterday and tomorrow on this month's page")
    showMonth()
    let past = dayCell(yesterday)
    let future = dayCell(tomorrow)
    XCTAssertTrue(past.waitForExistence(timeout: 5))
    let dimmedPast = Pixels().contrast(in: past.frame)
    let futureBefore = Pixels().contrast(in: future.frame)
    XCTAssertLessThan(
      dimmedPast, futureBefore, "by default a day that is over is lighter than a coming one")

    // Settings > Calendar > Dim past days: off.
    openSettings()
    let toggle = reveal(app.switches["Dim past days"])
    XCTAssertEqual(toggle.value as? String, "1", "on by default")
    toggle.toggleSwitch()
    closeSettings()
    XCTAssertTrue(past.waitForExistence(timeout: 5))
    let undimmedPast = Pixels().contrast(in: past.frame)
    XCTAssertGreaterThan(
      undimmedPast, dimmedPast + 20, "with the switch off a past day looks like any other day")
    XCTAssertEqual(
      undimmedPast, Pixels().contrast(in: future.frame), accuracy: 12,
      "...the same as a day to come")

    // And back on.
    openSettings()
    reveal(app.switches["Dim past days"]).toggleSwitch()
    closeSettings()
    XCTAssertTrue(past.waitForExistence(timeout: 5))
    XCTAssertEqual(
      Pixels().contrast(in: past.frame), dimmedPast, accuracy: 12, "switching it on dims again")
  }

  func testDimPastDaysOffAlsoStopsFadingEventsThatAreOver() throws {
    // The selected day's list fades an all-day event on a day that is over; with the setting off it reads normally.
    launch(prefs: "dimPastDays=0")
    showMonth()
    let yesterday = cal.date(byAdding: .day, value: -1, to: .now)!
    try XCTSkipUnless(cal.isDate(yesterday, equalTo: .now, toGranularity: .month))
    let past = dayCell(yesterday)
    XCTAssertTrue(past.waitForExistence(timeout: 5))
    let off = Pixels().contrast(in: past.frame)
    let today = Pixels().contrast(in: dayCell(.now).frame)
    XCTAssertGreaterThan(
      off, 100, "a past day number is full strength with the setting off (today: \(today))")
  }

  // MARK: No weekend shading

  func testWeekendsLookLikeAnyOtherDayInMonth() {
    launch()
    showMonth()
    let saturday = dayCell(dayInMonth(weekday: 7))
    let sunday = dayCell(dayInMonth(weekday: 1))
    let wednesday = dayCell(dayInMonth(weekday: 4))
    XCTAssertTrue(wednesday.waitForExistence(timeout: 5))
    let px = Pixels()
    func background(_ e: XCUIElement) -> Int {
      px.luma(at: CGPoint(x: e.frame.minX + 3, y: e.frame.minY + 4))
    }
    XCTAssertEqual(
      background(saturday), background(wednesday), accuracy: 1, "no grey behind Saturday")
    XCTAssertEqual(background(sunday), background(wednesday), accuracy: 1, "no grey behind Sunday")
  }

  func testWeekendColumnsAreNotShadedInTwoDay() throws {
    launch()
    app.buttons["Calendar"].firstMatch.tap()
    let grid = element("calendar.dayGrid")
    XCTAssertTrue(grid.waitForExistence(timeout: 5))
    // Swipe a day at a time until a Saturday is one of the two columns.
    let saturday = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Saturday'"))
      .firstMatch
    for _ in 0..<6 where !saturday.isFullyVisible(in: app.frame) {
      grid.swipeLeft()
      sleep(1)
    }
    XCTAssertTrue(saturday.isFullyVisible(in: app.frame), "a Saturday is on screen")
    // Early morning is empty on every day: scroll the grid up to it and compare the two columns.
    for _ in 0..<3 { grid.swipeDown() }
    let frame = grid.frame
    let colW = (frame.width - 44) / 2
    let y = frame.minY + 10 + 2.5 * 48  // between the 2:00 and 3:00 lines
    let px = Pixels()
    let lumas = (0..<2).map {
      px.luma(at: CGPoint(x: frame.minX + 44 + colW * (CGFloat($0) + 0.5), y: y))
    }
    XCTAssertEqual(
      Set(lumas).count, 1, "every column has the same background, weekend or not: \(lumas)")
  }

  // MARK: First day of the week

  func testFirstDayOfTheWeekSettingMovesTheMonthColumns() {
    launch()
    showMonth()
    let sunday = dayInMonth(weekday: 1)
    let monday = cal.date(byAdding: .day, value: 1, to: sunday)!
    XCTAssertTrue(dayCell(sunday).waitForExistence(timeout: 5))

    openSettings()
    reveal(app.buttons["settings.firstWeekday.sunday"]).tap()
    closeSettings()
    XCTAssertLessThan(
      dayCell(sunday).frame.minX, dayCell(monday).frame.minX,
      "Sunday first: Sunday is the leftmost column")
    XCTAssertLessThan(dayCell(sunday).frame.minX, 30)

    openSettings()
    reveal(app.buttons["settings.firstWeekday.monday"]).tap()
    closeSettings()
    XCTAssertLessThan(
      dayCell(monday).frame.minX, dayCell(sunday).frame.minX,
      "Monday first: Monday is left of Sunday")
    XCTAssertLessThan(dayCell(monday).frame.minX, 30)
  }

  // MARK: Week numbers

  func testWeekNumbersAppearInMonthAndTwoDayWhenSwitchedOn() {
    launch()
    showMonth()
    XCTAssertFalse(
      app.staticTexts.matching(identifier: "calendar.weekNumber").firstMatch.exists,
      "off by default")
    openSettings()
    reveal(app.switches["Show week numbers"]).toggleSwitch()
    closeSettings()
    let numbers = app.staticTexts.matching(identifier: "calendar.weekNumber")
    XCTAssertTrue(
      numbers.firstMatch.waitForExistence(timeout: 5), "a number for each row of the month")
    XCTAssertGreaterThanOrEqual(numbers.count, 4)
    let week = cal.component(.weekOfYear, from: dayInMonth(weekday: 4))
    XCTAssertTrue(
      numbers.allElementsBoundByIndex.map({ $0.label }).contains("Week \(week)"),
      "the row of the 5th-11th shows its week number")

    app.buttons["calendar.mode.twoday"].tap()
    let header = element("calendar.weekNumber")
    XCTAssertTrue(header.waitForExistence(timeout: 5), "the 2 Day grid shows its number too")
    XCTAssertEqual(
      header.label, "Week \(cal.component(.weekOfYear, from: .now))",
      "the week of the first column, today")
  }

  // MARK: Calendar opens on

  func testCalendarOpensOnTheChosenView() {
    launch(prefs: "calendarStart=month")
    app.buttons["Calendar"].firstMatch.tap()
    XCTAssertTrue(app.buttons["calendar.mode.month"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["calendar.mode.month"].isSelected, "Month, not the default 2 Day")
  }

  /// "Open Calendar on: 3 Day" from before 2 Day replaced it is Last used now, which opens on 2 Day the first time.
  func testCalendarOpensOnTwoDayForARetiredThreeDayChoice() {
    launch(prefs: "calendarStart=threeDay")
    app.buttons["Calendar"].firstMatch.tap()
    XCTAssertTrue(app.buttons["calendar.mode.twoday"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["calendar.mode.twoday"].isSelected)
    XCTAssertTrue(element("calendar.dayGrid").waitForExistence(timeout: 5))
  }

  func testCalendarStartPillsAreInSettings() {
    launch()
    openSettings()
    let year = reveal(app.buttons["settings.calendarStart.year"])
    year.tap()
    XCTAssertTrue(year.isSelected)
    XCTAssertTrue(app.buttons["settings.calendarStart.lastUsed"].exists)
    XCTAssertFalse(app.buttons["settings.calendarStart.lastUsed"].isSelected)
  }

  // MARK: Today

  func testFreeTimeRowsCanBeSwitchedOff() {
    launch(now: "09:41")
    let free = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH 'Free '")
    ).firstMatch
    XCTAssertTrue(free.waitForExistence(timeout: 5), "free time shows by default")
    openSettings()
    reveal(app.switches["Show free time"]).toggleSwitch()
    closeSettings()
    XCTAssertTrue(app.weekStripDay(.now).waitForExistence(timeout: 5))
    XCTAssertFalse(free.waitForExistence(timeout: 2), "no Free rows with the setting off")
  }

  // MARK: Reminders, alarms, AI

  func testNewReminderListAndAlarmDefaultsAreInSettings() {
    launch()
    openSettings()
    XCTAssertTrue(reveal(element("settings.newReminderList")).exists)
    XCTAssertTrue(reveal(element("settings.newAlarmSnooze")).exists)
    XCTAssertTrue(reveal(element("settings.newAlarmSound")).exists)
  }

  func testDefaultReminderListChosenInSettingsContainsTheSavedQuickAdd() {
    launch()
    openSettings()
    reveal(element("settings.newReminderList")).tap()
    let workOption = app.buttons["Work"]
    XCTAssertTrue(workOption.waitForExistence(timeout: 3))
    workOption.tap()
    closeSettings()

    // Add from the Reminders home, without choosing a list in the draft.
    app.buttons["Reminders"].firstMatch.tap()
    app.addNew("New reminder")
    XCTAssertTrue(element("quick.title").waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.buttons["List, Work"].waitForExistence(timeout: 3),
      "the quick add inherits the list selected through Settings")
    let title =
      app.textFields["quick.title"].exists
      ? app.textFields["quick.title"] : app.textViews["quick.title"]
    title.typeText("Check the handoff checklist")
    app.buttons["quick.save"].tap()
    XCTAssertTrue(app.buttons["quick.save"].waitForNonExistence(timeout: 5))

    reveal(element("list.Work")).tap()
    let saved = app.staticTexts["Check the handoff checklist"]
    reveal(saved)
    XCTAssertTrue(saved.waitForExistence(timeout: 5), "the saved reminder actually belongs to Work")
    saved.tap()
    XCTAssertTrue(
      app.textFields["task.title"].waitForExistence(timeout: 5),
      "the saved reminder can be reopened from the selected list")
    XCTAssertEqual(app.textFields["task.title"].value as? String, "Check the handoff checklist")
  }

  func testDefaultAlarmSoundChosenInSettingsSurvivesSaveAndReopen() {
    launch()
    openSettings()
    reveal(element("settings.newAlarmSound")).tap()
    let chimes = app.buttons["Chimes"]
    XCTAssertTrue(chimes.waitForExistence(timeout: 3))
    chimes.tap()
    closeSettings()

    app.buttons["Clock"].firstMatch.tap()
    app.addNew("New alarm")
    XCTAssertTrue(app.staticTexts["Add Alarm"].waitForExistence(timeout: 5))
    let sound = element("alarm.sound")
    reveal(sound)
    let hasChimes = NSPredicate(format: "label CONTAINS %@", "Chimes")
    let initialSound = XCTNSPredicateExpectation(predicate: hasChimes, object: sound)
    XCTAssertEqual(
      XCTWaiter.wait(for: [initialSound], timeout: 5), .completed,
      "the new alarm starts with the sound selected through Settings")
    let label = app.textFields["alarm.label"]
    label.tap()
    label.typeText("Handoff sound check")
    app.buttons["alarm.save"].tap()
    XCTAssertTrue(app.buttons["alarm.save"].waitForNonExistence(timeout: 5))

    // Change the default before reopening: the saved alarm must keep its own sound.
    openSettings()
    reveal(element("settings.newAlarmSound")).tap()
    let glass = app.buttons["Glass"]
    XCTAssertTrue(glass.waitForExistence(timeout: 3))
    glass.tap()
    closeSettings()

    let saved = app.buttons.matching(
      NSPredicate(
        format: "identifier == 'alarm.row' AND label CONTAINS %@", "Handoff sound check"
      )
    ).firstMatch
    reveal(saved)
    saved.tap()
    XCTAssertTrue(app.staticTexts["Edit Alarm"].waitForExistence(timeout: 5))
    reveal(sound)
    let savedSound = XCTNSPredicateExpectation(predicate: hasChimes, object: sound)
    XCTAssertEqual(
      XCTWaiter.wait(for: [savedSound], timeout: 5), .completed,
      "save and reopen keeps Chimes even after the default changes to Glass")
    sound.tap()
    XCTAssertTrue(app.navigationBars["Sound"].waitForExistence(timeout: 5))
    XCTAssertTrue(chimes.waitForExistence(timeout: 3))
    XCTAssertTrue(chimes.isSelected, "the saved tone is selected in the sound picker")
    XCTAssertFalse(
      app.buttons["Glass"].isSelected, "the new default does not replace the saved tone")
  }

  func testNewAlarmStartsWithTheChosenSnoozeLength() {
    launch(prefs: "newAlarmSnooze=15")
    app.buttons["Clock"].firstMatch.tap()
    app.addNew("New alarm")
    let duration = element("alarm.snoozeDuration")
    XCTAssertTrue(duration.waitForExistence(timeout: 5))
    XCTAssertTrue(
      duration.label.contains("15") || (duration.value as? String)?.contains("15") == true,
      "snooze duration starts at 15 min: \(duration.label) / \(String(describing: duration.value))")
  }
}
