import XCTest

@testable import TodayCore
@testable import TodayData
@testable import TodayShared

final class UpNextLiveTests: XCTestCase {
  private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()

  private func at(_ hour: Int, _ minute: Int = 0, day: Int = 8) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
  }

  private func item(
    _ title: String, _ start: Date, allDay: Bool = false, kind: WidgetItem.Kind = .event
  ) -> WidgetItem {
    WidgetItem(id: title, title: title, start: start, isAllDay: allDay, kind: kind)
  }

  private func titles(_ items: [WidgetItem], now: Date) -> [String] {
    UpNextLive.rows(from: items, now: now).map(\.title)
  }

  // MARK: Selection

  func testRowCounts() {
    let now = at(9)
    XCTAssertEqual(titles([], now: now), [])
    XCTAssertEqual(titles([item("a", at(10))], now: now), ["a"])
    let three = [item("a", at(10)), item("b", at(11)), item("c", at(12))]
    XCTAssertEqual(titles(three, now: now), ["a", "b", "c"])
    XCTAssertEqual(
      titles(three + [item("d", at(11, 30)), item("e", at(11, 45))], now: now), ["a", "b", "d"])
  }

  func testExactWindowBoundaries() {
    let now = at(9)
    XCTAssertEqual(titles([item("at now", now)], now: now), [], "already started")
    XCTAssertEqual(titles([item("just after", now.addingTimeInterval(1))], now: now), ["just after"])
    XCTAssertEqual(titles([item("edge", at(12))], now: now), ["edge"], "now + 3h is included")
    XCTAssertEqual(titles([item("past", at(12).addingTimeInterval(1))], now: now), [])
  }

  func testCrossesMidnight() {
    XCTAssertEqual(titles([item("late", at(0, 30, day: 9))], now: at(23)), ["late"])
    XCTAssertEqual(titles([item("too far", at(2, 30, day: 9))], now: at(23)), [])
  }

  func testExcludesAllDayOverdueAndStarted() {
    let now = at(9)
    XCTAssertEqual(
      titles(
        [item("all day", at(10), allDay: true), item("overdue", at(8)), item("started", at(9))],
        now: now), [])
  }

  func testAlarmsAndRemindersCount() {
    let now = at(9)
    XCTAssertEqual(
      titles([item("r", at(10), kind: .reminder), item("al", at(11), kind: .alarm)], now: now),
      ["r", "al"])
  }

  func testSortsByTimeAndKeepsTiesInOrder() {
    let now = at(9)
    XCTAssertEqual(
      titles([item("later", at(11)), item("z tie", at(10)), item("a tie", at(10))], now: now),
      ["z tie", "a tie", "later"])
  }

  func testLongTitleFitsTheActivityPayload() {
    let row = UpNextLive.rows(
      from: [item(String(repeating: "x", count: 5000), at(10))], now: at(9))[0]
    XCTAssertEqual(row.title.count, UpNextLive.maxTitleLength)
  }

  func testMultiDayEventsLaterRowHasNotStarted() {
    let days = [at(0, day: 8), at(0, day: 9)]
    let rows = WidgetItem.eventRows(
      id: "trip", title: "trip", start: at(20), end: at(2, day: 9), isAllDay: false,
      externalID: nil, days: days, calendar: calendar)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.map(\.startedEarlier), [nil, true])
    XCTAssertEqual(UpNextLive.rows(from: rows, now: at(23)), [], "midnight is not its start")
    let midnightStart = WidgetItem.eventRows(
      id: "m", title: "midnight", start: at(0, day: 9), end: at(1, day: 9), isAllDay: false,
      externalID: nil, days: days, calendar: calendar)
    XCTAssertEqual(titles(midnightStart, now: at(23)), ["midnight"], "a real 00:00 start counts")
  }

  func testTimedDueExcludesCompletedAndUntimed() {
    XCTAssertEqual(UpNextLive.timedDue(at(10), isDone: false, calendar: calendar), at(10))
    XCTAssertNil(UpNextLive.timedDue(at(10), isDone: true, calendar: calendar), "completed")
    XCTAssertNil(UpNextLive.timedDue(at(0), isDone: false, calendar: calendar), "no time of day")
    XCTAssertNil(UpNextLive.timedDue(nil, isDone: false, calendar: calendar))
  }

  // MARK: Lifecycle

  private let row = [UpNextRow(start: Date(timeIntervalSince1970: 1000), title: "a")]
  private let otherRow = [UpNextRow(start: Date(timeIntervalSince1970: 2000), title: "b")]

  private func action(
    rows: [UpNextRow], live: UpNextLifecycle.Live?, allowed: Bool = true, foreground: Bool = true,
    now: Date
  ) -> UpNextLifecycle.Action {
    UpNextLifecycle.action(
      rows: rows, live: live, allowed: allowed, isForeground: foreground, now: now)
  }

  func testStartsOnlyInForeground() {
    XCTAssertEqual(action(rows: row, live: nil, now: at(9)), .start)
    XCTAssertEqual(action(rows: row, live: nil, foreground: false, now: at(9)), .none)
  }

  func testNoRowsEndsAndShowsNoEmptyCard() {
    XCTAssertEqual(action(rows: [], live: nil, now: at(9)), .none)
    let live = UpNextLifecycle.Live(rows: row, requestedAt: at(8))
    XCTAssertEqual(action(rows: [], live: live, now: at(9)), .end)
    XCTAssertEqual(action(rows: [], live: live, foreground: false, now: at(9)), .end)
  }

  func testUpdatesOnlyWhenContentChanges() {
    let live = UpNextLifecycle.Live(rows: row, requestedAt: at(8))
    XCTAssertEqual(action(rows: row, live: live, now: at(9)), .none)
    XCTAssertEqual(action(rows: otherRow, live: live, now: at(9)), .update)
    XCTAssertEqual(action(rows: otherRow, live: live, foreground: false, now: at(9)), .update)
  }

  func testRestartsNearTheCapOnlyInForeground() {
    let live = UpNextLifecycle.Live(rows: row, requestedAt: at(2))
    XCTAssertEqual(action(rows: row, live: live, now: at(8, 59)), .none)
    XCTAssertEqual(action(rows: row, live: live, now: at(9)), .restart)
    XCTAssertEqual(action(rows: otherRow, live: live, foreground: false, now: at(9)), .update)
    XCTAssertEqual(action(rows: row, live: live, foreground: false, now: at(9)), .none)
  }

  func testEndedCardIsReplacedOnlyFromForeground() {
    let ended = UpNextLifecycle.Live(rows: row, requestedAt: at(1), isEnded: true)
    XCTAssertEqual(action(rows: otherRow, live: ended, now: at(9)), .restart)
    XCTAssertEqual(action(rows: otherRow, live: ended, foreground: false, now: at(9)), .none)
    XCTAssertEqual(action(rows: [], live: ended, now: at(9)), .end)
  }

  func testNotAllowedEndsTheCard() {
    let live = UpNextLifecycle.Live(rows: row, requestedAt: at(8))
    XCTAssertEqual(action(rows: row, live: live, allowed: false, now: at(9)), .end)
    XCTAssertEqual(action(rows: row, live: nil, allowed: false, now: at(9)), .none)
  }

  func testDismissalLastsTheCalendarDay() {
    func suppressed(_ now: Date) -> Bool {
      UpNextLifecycle.isSuppressed(dismissedAt: at(9), now: now, calendar: calendar)
    }
    XCTAssertTrue(suppressed(at(23, 59)))
    XCTAssertFalse(suppressed(at(0, 0, day: 9)))
    XCTAssertFalse(UpNextLifecycle.isSuppressed(dismissedAt: nil, now: at(9), calendar: calendar))
  }

  func testVanishedCardCountsAsDismissedOnlyBeforeTheCap() {
    XCTAssertTrue(UpNextLifecycle.vanishedByDismissal(requestedAt: at(2), now: at(9, 59)))
    XCTAssertFalse(UpNextLifecycle.vanishedByDismissal(requestedAt: at(2), now: at(10)))
    XCTAssertFalse(UpNextLifecycle.vanishedByDismissal(requestedAt: nil, now: at(10)))
  }

  func testUITestingNeverAllowsARealActivity() {
    XCTAssertFalse(UpNextLive.allowsRealActivity(arguments: ["app", "-uiTesting"]))
    XCTAssertTrue(UpNextLive.allowsRealActivity(arguments: ["app"]))
  }

  // MARK: Setting and events

  func testSettingDefaultsOnAndCanBeTurnedOff() throws {
    XCTAssertTrue(Preferences.upNextLiveActivity)
    let suite = "UpNextLiveTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(Preferences.upNextLiveActivityEnabled(defaults))
    defaults.set(false, forKey: Preferences.upNextLiveActivityKey)
    XCTAssertFalse(Preferences.upNextLiveActivityEnabled(defaults))
  }

  func testEventsCarryNoFreeText() {
    let setting = ActivityEvents.upNextSetting(on: false)
    XCTAssertEqual(setting.kind, ActivityKind.sysUpNextSetting)
    XCTAssertTrue(setting.props.contains("\"on\""))
    let dismissed = ActivityEvents.upNextDismissed()
    XCTAssertEqual(dismissed.kind, ActivityKind.sysUpNextDismissed)
    XCTAssertTrue(dismissed.props.contains("lockscreen"))
  }
}
