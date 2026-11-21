import XCTest

@testable import TodayShared

/// The Lock Screen rectangular widget: one item, a time line, an optional "+N", and the empty state.
final class LockScreenNextTests: XCTestCase {
  var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()

  func date(_ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: min))!
  }
  /// Friday 2026-10-16, 19:35
  lazy var now = date(16, 19, 35)

  func hhmm(_ d: Date) -> String {
    let c = cal.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour!, c.minute!)
  }

  func item(
    _ title: String, _ start: Date, end: Date? = nil, allDay: Bool = false,
    kind: WidgetItem.Kind = .reminder,
    leaveBy: Date? = nil
  ) -> WidgetItem {
    WidgetItem(
      id: title, title: title, start: start, end: end, isAllDay: allDay, kind: kind,
      travelMinutes: leaveBy == nil ? nil : 10, leaveBy: leaveBy)
  }

  func make(_ items: [WidgetItem], at: Date? = nil) -> LockScreenNext {
    LockScreenNext.make(items: items, now: at ?? now, calendar: cal, time: hhmm)
  }

  func testUpcomingWithinAnHourCountsDown() {
    let m = make([item("Qina piano class", date(16, 20))])
    XCTAssertEqual(m.headline, "20:00")
    XCTAssertEqual(m.lead, .countdown(to: date(16, 20)))
    XCTAssertEqual(m.title, "Qina piano class")
    XCTAssertNil(m.more)
    XCTAssertFalse(m.showsAlarmSymbol)
    XCTAssertEqual(m.accessibilityLabel, "Next: Qina piano class at 20:00, in 25 minutes.")
  }

  func testFurtherThanAnHourAwayShowsOnlyTheTime() {
    let m = make([item("Dinner", date(16, 20, 36))])
    XCTAssertEqual(m.headline, "20:36")
    XCTAssertEqual(m.lead, .none)
    // Exactly an hour is still inside the window (the timeline has an entry there).
    XCTAssertEqual(make([item("Dinner", date(16, 20, 35))]).lead, .countdown(to: date(16, 20, 35)))
  }

  func testSpokenCountdown() {
    XCTAssertEqual(
      LockScreenNext.spokenCountdown(from: now, to: now.addingTimeInterval(30)),
      "in less than a minute")
    XCTAssertEqual(
      LockScreenNext.spokenCountdown(from: now, to: now.addingTimeInterval(90)), "in 1 minute")
    XCTAssertEqual(
      LockScreenNext.spokenCountdown(from: now, to: now.addingTimeInterval(3600)), "in 1 hour")
  }

  func testEventInProgressSaysNowUntilItEnds() {
    let m = make([
      item("Concert", date(16, 19), end: date(16, 21), kind: .event),
      item("Bed", date(16, 22), kind: .alarm),
    ])
    XCTAssertEqual(m.headline, "Now")
    XCTAssertEqual(m.lead, .text("until 21:00"))
    XCTAssertEqual(m.more, "+1")
    XCTAssertEqual(m.accessibilityLabel, "Now: Concert, until 21:00. 1 more today.")
  }

  func testAllDayItemsSayAllDayAndNeverGetATime() {
    let m = make([
      item("Holiday", date(16), allDay: true, kind: .event), item("Dinner", date(16, 20)),
    ])
    XCTAssertEqual(m.headline, "All day")
    XCTAssertEqual(m.lead, .none)
    XCTAssertEqual(m.more, "+1")
    XCTAssertEqual(m.accessibilityLabel, "Next: Holiday, all day. 1 more today.")
  }

  func testAlarmGetsTheAlarmSymbol() {
    let m = make([item("Wake up", date(16, 20), kind: .alarm)])
    XCTAssertTrue(m.showsAlarmSymbol)
    XCTAssertEqual(m.headline, "20:00")
    XCTAssertEqual(m.accessibilityLabel, "Next alarm: Wake up at 20:00, in 25 minutes.")
  }

  func testLeaveByReplacesTheCountdown() {
    let e = item(
      "Dentist", date(16, 20, 30), end: date(16, 21), kind: .event, leaveBy: date(16, 20, 15))
    let m = make([e])
    XCTAssertEqual(m.headline, "20:30")
    XCTAssertEqual(m.lead, .text("Leave 20:15"))
    XCTAssertEqual(m.accessibilityLabel, "Next: Dentist at 20:30, leave by 20:15.")
    // Past the leave-by time and before the start: "Leave now".
    let late = make([e], at: date(16, 20, 20))
    XCTAssertEqual(late.lead, .text("Leave now"))
    XCTAssertEqual(late.accessibilityLabel, "Next: Dentist at 20:30, leave now.")
    // Once it has started the travel hint is gone.
    XCTAssertEqual(make([e], at: date(16, 20, 31)).lead, .text("until 21:00"))
  }

  func testItemsStartingTogetherAreGrouped() {
    // The Lock Screen screenshot: three reminders at 20:00. The time is already in the headline, so just "+2".
    let items = [
      item("Qina 或 Yuan 钢琴课", date(16, 20)), item("添加 给唐建…", date(16, 20)),
      item("添加提交 40…", date(16, 20)),
    ]
    let m = make(items)
    XCTAssertEqual(m.headline, "20:00")
    XCTAssertEqual(m.more, "+2")
    XCTAssertEqual(
      m.accessibilityLabel, "Next: Qina 或 Yuan 钢琴课 at 20:00, in 25 minutes. 2 more at 20:00.")
  }

  func testGroupedItemsNameTheTimeWhereTheHeadlineDoesNot() {
    // An event under way since 19:00 with two more that started at 19:00: "Now" doesn't say 19:00.
    let items = [
      item("Concert", date(16, 19), end: date(16, 21), kind: .event),
      item("Foyer", date(16, 19), end: date(16, 20), kind: .event),
      item("Bar", date(16, 19), end: date(16, 20), kind: .event),
    ]
    let m = make(items)
    XCTAssertEqual(m.headline, "Now")
    XCTAssertEqual(m.more, "+2 at 19:00")
    // Leave-by also hides the start in the lead; the headline still has it.
    let leave = make([
      item("A", date(16, 20, 30), kind: .event, leaveBy: date(16, 20, 15)),
      item("B", date(16, 20, 30)),
    ])
    XCTAssertEqual(leave.more, "+1")
  }

  func testMixedStartsAreNotGrouped() {
    let m = make([item("A", date(16, 20)), item("B", date(16, 20)), item("C", date(16, 22))])
    XCTAssertEqual(m.more, "+2")
    XCTAssertEqual(m.accessibilityLabel, "Next: A at 20:00, in 25 minutes. 2 more today.")
  }

  func testEmptyStateShowsTomorrowsFirstItem() {
    let m = make([item("Morning run", date(17, 7), kind: .alarm), item("Past", date(16, 8))])
    XCTAssertTrue(m.isEmpty)
    XCTAssertEqual(m.headline, "Nothing else today")
    XCTAssertEqual(m.title, "Tomorrow 07:00 · Morning run")
    XCTAssertNil(m.more)
    XCTAssertEqual(m.lead, .none)
    XCTAssertEqual(m.accessibilityLabel, "Nothing else today. Tomorrow: Morning run at 07:00.")
    XCTAssertEqual(
      make([item("Holiday", date(17), allDay: true, kind: .event)]).title,
      "Tomorrow, all day · Holiday")
  }

  func testEmptyStateWithNothingTomorrow() {
    let m = make([])
    XCTAssertTrue(m.isEmpty)
    XCTAssertEqual(m.title, "")
    XCTAssertEqual(m.accessibilityLabel, "Nothing else today.")
  }

  func testTimelineGetsAnEntryWhereTheCountdownStarts() {
    let items = [item("Dinner", date(16, 22))]
    XCTAssertEqual(
      NextItems.timelineDates(
        for: items, now: now, countdownLead: LockScreenNext.countdownWindow, calendar: cal),
      [now, date(16, 21), date(16, 22), date(17)])
    // Without it (the other callers) nothing changes.
    XCTAssertEqual(
      NextItems.timelineDates(for: items, now: now, calendar: cal), [now, date(16, 22), date(17)])
  }
}
