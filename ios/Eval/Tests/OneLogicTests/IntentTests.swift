import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData
@testable import TodayShared

/// Siri / Shortcuts: what "Add Reminder" saves, the timer's minute range, and what "What's next" says.
final class IntentTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()
  /// Friday 2026-10-16, 09:41
  lazy var now = date(16, 9, 41)

  func date(_ d: Int, _ h: Int = 0, _ m: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
  }

  // MARK: Add Reminder

  func testOneSentenceIsParsed() throws {
    let c = try XCTUnwrap(
      IntentReminder.capture(text: "Call Mom tomorrow at 6pm", date: nil, now: now, calendar: cal))
    XCTAssertEqual(c.title, "Call Mom")
    XCTAssertEqual(c.day, date(17))
    XCTAssertTrue(c.hasDay)
    XCTAssertEqual(c.hour, 18)
    XCTAssertEqual(c.kind, .task)
  }

  func testChineseSentenceIsParsed() throws {
    let c = try XCTUnwrap(
      IntentReminder.capture(text: "明天下午3点交报告", date: nil, now: now, calendar: cal))
    XCTAssertEqual(c.day, date(17))
    XCTAssertEqual(c.hour, 15)
    XCTAssertFalse(c.title.contains("明天"))
  }

  func testPlainTitleHasNoDate() throws {
    let c = try XCTUnwrap(
      IntentReminder.capture(text: "  Buy milk ", date: nil, now: now, calendar: cal))
    XCTAssertEqual(c.title, "Buy milk")
    XCTAssertFalse(c.hasDay)
    XCTAssertNil(c.hour)
  }

  func testEmptyTextAddsNothing() {
    XCTAssertNil(IntentReminder.capture(text: "   ", date: nil, now: now, calendar: cal))
  }

  func testGivenDateAndTimeWin() throws {
    let c = try XCTUnwrap(
      IntentReminder.capture(
        text: "Pay rent tomorrow at 6pm", date: date(20, 8, 30), now: now, calendar: cal))
    XCTAssertEqual(c.day, date(20))
    XCTAssertEqual(c.hour, 8)
    XCTAssertEqual(c.minute, 30)
  }

  func testGivenDayOnlyKeepsTheSentencesTime() throws {
    let c = try XCTUnwrap(
      IntentReminder.capture(text: "Pay rent at 6pm", date: date(20), now: now, calendar: cal))
    XCTAssertEqual(c.day, date(20))
    XCTAssertEqual(c.hour, 18)
    let dayOnly = try XCTUnwrap(
      IntentReminder.capture(text: "Pay rent", date: date(20), now: now, calendar: cal))
    XCTAssertTrue(dayOnly.hasDay)
    XCTAssertNil(dayOnly.hour)
  }

  func testAlwaysAReminderNeverAnEventOrAlarm() throws {
    let meeting = try XCTUnwrap(
      IntentReminder.capture(text: "Meeting with Alex 3-4pm", date: nil, now: now, calendar: cal))
    XCTAssertEqual(meeting.kind, .task)
    let alarm = try XCTUnwrap(
      IntentReminder.capture(text: "Set an alarm for 7am", date: nil, now: now, calendar: cal))
    XCTAssertFalse(alarm.ringsAsAlarm)
    XCTAssertEqual(alarm.kind, .task)
  }

  // MARK: What's next

  private func item(
    _ title: String, _ start: Date, end: Date? = nil, allDay: Bool = false,
    kind: WidgetItem.Kind = .event
  ) -> WidgetItem {
    WidgetItem(id: title, title: title, start: start, end: end, isAllDay: allDay, kind: kind)
  }

  private func hm(_ d: Date) -> String {
    let c = cal.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
  }

  private func say(_ items: [WidgetItem]) -> String {
    NextUpSpeech.line(NextItems.select(from: items, now: now, calendar: cal), now: now, time: hm)
  }

  func testNextThreeThenACount() {
    let items = [
      item("Offsite", date(16), allDay: true),
      item("Standup", date(16, 9, 30), end: date(16, 10)),
      item("Call Alex", date(16, 11), kind: .reminder),
      item("Dentist", date(16, 15), end: date(16, 16)),
      item("Gym", date(16, 18), kind: .alarm),
    ]
    XCTAssertEqual(
      say(items), "Next today: Offsite, all day, Standup, now and Call Alex at 11:00. Then 2 more.")
  }

  func testOneOrTwoItems() {
    XCTAssertEqual(
      say([item("Dentist", date(16, 15), end: date(16, 16))]), "Next today: Dentist at 15:00.")
    XCTAssertEqual(
      say([item("Dentist", date(16, 15)), item("Gym", date(16, 18), kind: .alarm)]),
      "Next today: Dentist at 15:00 and Gym at 18:00.")
  }

  func testTomorrowWhenTodayIsDone() {
    let items = [
      item("Breakfast", date(16, 8), kind: .reminder),
      item("Weekly review", date(17, 10), end: date(17, 11)),
    ]
    XCTAssertEqual(say(items), "Nothing left today. Tomorrow starts with Weekly review at 10:00.")
    XCTAssertEqual(say([]), "Nothing left today.")
  }
}
