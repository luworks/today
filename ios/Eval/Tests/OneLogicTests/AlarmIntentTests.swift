import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// Siri's "Set Alarm": it reads the time like the chat does, and Siri's repeat rules map to the alarm's weekdays.
final class AlarmIntentTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()
  /// Friday 2026-10-16, 22:12
  lazy var now = cal.date(
    from: DateComponents(year: 2026, month: 10, day: 16, hour: 22, minute: 12))!

  func testAPlainTimeIsAnAlarm() throws {
    let c = try XCTUnwrap(IntentAlarm.capture(text: "7am tomorrow", now: now, calendar: cal))
    XCTAssertTrue(c.ringsAsAlarm)
    XCTAssertEqual(c.kind, .task)
    XCTAssertEqual(c.hour, 7)
    XCTAssertEqual(c.minute, 0)
  }

  func testSiriAndTheChatReadTheSameSentenceTheSameWay() throws {
    for text in ["wake me at 6:30", "alarm in 20 minutes", "明早7点叫醒我"] {
      let siri = try XCTUnwrap(IntentAlarm.capture(text: text, now: now, calendar: cal), text)
      // The chat's rule path for an alarm request (`FastLane.localPreview`): the parse, then the alarm kind.
      var chat = CaptureConversation.parse(text, now: now, calendar: cal)
      chat.kind = .task
      chat.ringsAsAlarm = true
      XCTAssertEqual(siri.hour, chat.hour, text)
      XCTAssertEqual(siri.minute, chat.minute, text)
      XCTAssertEqual(siri.title, chat.title, text)
      XCTAssertEqual(siri.repeatRule, chat.repeatRule, text)
    }
  }

  func testAGivenLabelWinsAndNoTimeIsNothing() throws {
    let c = try XCTUnwrap(
      IntentAlarm.capture(text: "7am", label: " Gym ", now: now, calendar: cal))
    XCTAssertEqual(c.title, "Gym")
    XCTAssertNil(IntentAlarm.capture(text: "   ", now: now, calendar: cal))
  }

  func testWhatSiriSaysBack() {
    let en = Locale(identifier: "en_US")
    XCTAssertEqual(
      IntentAlarm.confirmation(
        label: "", hour: 7, minute: 0, weekdays: [], now: now, calendar: cal, locale: en),
      "Alarm set for 7:00 AM tomorrow.")
    XCTAssertEqual(
      IntentAlarm.confirmation(
        label: "Read", hour: 23, minute: 0, weekdays: [], now: now, calendar: cal, locale: en),
      "Read set for 11:00 PM today.")
    XCTAssertEqual(
      IntentAlarm.confirmation(
        label: "Wake up", hour: 6, minute: 30, weekdays: [2, 3, 4, 5, 6], now: now, calendar: cal,
        locale: en),
      "Wake up set for 6:30 AM, Weekdays.")
  }

  func testRepeatRulesRoundTrip() throws {
    guard #available(macOS 15, iOS 18, *) else { throw XCTSkip("Calendar.RecurrenceRule") }
    XCTAssertEqual(AlarmPlan.weekdays(from: nil), [])
    XCTAssertEqual(AlarmPlan.weekdays(from: .daily(calendar: cal)), Array(1...7))
    for days in [[2, 3, 4, 5, 6], [1, 7], [4], Array(1...7)] {
      let rule = AlarmPlan.recurrenceRule(weekdays: days, calendar: cal)
      XCTAssertEqual(AlarmPlan.weekdays(from: rule), days, "\(days)")
    }
    XCTAssertNil(AlarmPlan.recurrenceRule(weekdays: [], calendar: cal))
  }
}
