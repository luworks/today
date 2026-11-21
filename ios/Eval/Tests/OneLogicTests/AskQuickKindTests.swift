import Foundation
import XCTest

@testable import TodayCore

final class AskQuickKindTests: XCTestCase {
  private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
  }
  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9))!
  }

  private func parse(_ kind: AskQuickKind, _ rest: String) -> Capture {
    CaptureConversation.parse(kind.skill + rest, now: now, calendar: calendar)
  }

  func testReminderPrefixMakesAReminder() {
    let text = AskQuickKind.reminder.skill + "buy milk at 5pm"
    XCTAssertEqual(ChatRouting.intent(text), .capture)
    let c = parse(.reminder, "buy milk at 5pm")
    XCTAssertEqual(c.kind, .task)
    XCTAssertFalse(c.ringsAsAlarm)
    XCTAssertEqual(c.hour, 17)
    XCTAssertEqual(c.title.lowercased(), "buy milk")
  }

  func testReminderPrefixKeepsAnEventWordAReminder() {
    let c = parse(.reminder, "book the dentist appointment tomorrow at 10am")
    XCTAssertEqual(c.kind, .task)
    XCTAssertFalse(c.ringsAsAlarm)
  }

  func testEventPrefixMakesAnEventAndLeavesTheTitleClean() {
    let text = AskQuickKind.event.skill + "Review tomorrow from 2pm to 3pm"
    XCTAssertEqual(ChatRouting.intent(text), .capture)
    XCTAssertNil(OneOffReminderRequest.capture(text, now: now, calendar: calendar))
    let c = parse(.event, "Review tomorrow from 2pm to 3pm")
    XCTAssertEqual(c.kind, .event)
    XCTAssertFalse(c.ringsAsAlarm)
    XCTAssertEqual(c.title, "Review")
    XCTAssertEqual(c.hour, 14)
    XCTAssertEqual(c.durationMinutes, 60)
  }

  func testAlarmPrefixMakesAnAlarm() {
    let text = AskQuickKind.alarm.skill + "7am"
    XCTAssertEqual(ChatRouting.intent(text), .capture)
    XCTAssertTrue(ChatRouting.requestsAlarm(text))
    XCTAssertNil(OneOffReminderRequest.capture(text, now: now, calendar: calendar))
    let c = parse(.alarm, "7am")
    XCTAssertTrue(c.ringsAsAlarm)
    XCTAssertEqual(c.hour, 7)
  }

  func testRequestAddsTheSkillOnceAndKeepsTypedText() {
    XCTAssertEqual(AskQuickKind.reminder.request("buy milk at 5pm"), "Remind me to buy milk at 5pm")
    XCTAssertEqual(
      AskQuickKind.reminder.request("  Remind me to call Mom "), "Remind me to call Mom")
    XCTAssertEqual(AskQuickKind.alarm.request("7am"), "Set an alarm for 7am")
    XCTAssertEqual(AskQuickKind.event.placeholder, "Add an event…")
  }
}
