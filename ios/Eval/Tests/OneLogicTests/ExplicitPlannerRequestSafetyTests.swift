import Foundation
import XCTest

@testable import TodayCore

final class ExplicitPlannerRequestSafetyTests: XCTestCase {
  private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
  }
  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9))!
  }

  func testAmbiguousDatedEditHasNoNewReminderAuthorityOrLocalPreview() {
    let items = [15, 16].map { hour in
      EditItem(
        id: "dentist-\(hour)", type: "task", title: "visit [QA] dentist",
        start: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now),
        minutes: 30, attendees: 0)
    }
    let request = "Move [QA] dentist to 5pm"
    XCTAssertEqual(FastLane.intent(request), .unsure)
    XCTAssertNil(FastLane.oneOffReminder(request, now: now, calendar: calendar))
    XCTAssertTrue(FastLane.looksLikeEdit(request, items: items, now: now, calendar: calendar))
    // Without the agent, an edit never becomes a new-item preview either (§4.7 #3).
    XCTAssertNil(FastLane.localPreview(request, items: items, now: now, calendar: calendar))
  }

  func testLeadingEditsDoNotAcquireCreationAuthorityWithoutAStoredCandidate() {
    for request in [
      "Move dentist to 5pm", "Please reschedule dentist to tomorrow at 3pm",
      "Postpone meeting to 5pm", "Delete dentist tomorrow at 3pm",
    ] {
      XCTAssertNil(FastLane.oneOffReminder(request, now: now, calendar: calendar), request)
    }
    XCTAssertNotNil(
      FastLane.oneOffReminder(
        "Remind me to move the boxes at 5pm", now: now, calendar: calendar))
  }

  func testExplicitCalendarEventReachesAnEventPreviewWithItsOriginalTimeRange() {
    let request = "Create a calendar event [QA] project review tomorrow from 2pm to 3pm"
    XCTAssertEqual(FastLane.intent(request), .capture)
    XCTAssertNil(FastLane.oneOffReminder(request, now: now, calendar: calendar))
    let draft = FastLane.parse(request, now: now, calendar: calendar)
    XCTAssertEqual(draft.kind, .event)
    XCTAssertEqual(draft.title, "[QA] project review")
    XCTAssertEqual(draft.hour, 14)
    XCTAssertEqual(draft.minute, 0)
    XCTAssertEqual(draft.durationMinutes, 60)
    XCTAssertEqual(
      draft.day, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
    XCTAssertFalse(draft.ringsAsAlarm)
  }

  func testEventTypeCannotAuthorizeAReminderWhenNoTimeRangeWasGiven() {
    for request in ["Create a calendar event Review tomorrow at 2pm", "Please add an event Review"]
    {
      XCTAssertEqual(FastLane.intent(request), .capture, request)
      XCTAssertNil(FastLane.oneOffReminder(request, now: now, calendar: calendar), request)
      XCTAssertEqual(FastLane.parse(request, now: now, calendar: calendar).kind, .event)
    }
  }

  func testQuotedReportedAndDeclinedEventRequestsRemainUnprivileged() {
    for request in [
      "\"Create a calendar event Review tomorrow at 2pm\"",
      "You said create a calendar event Review tomorrow at 2pm",
      "I already created a calendar event Review tomorrow at 2pm",
      "Don't create a calendar event Review tomorrow at 2pm",
      "What happens if I create a calendar event Review tomorrow at 2pm?",
    ] {
      XCTAssertFalse(FastLane.requestsEvent(request), request)
      XCTAssertNotEqual(FastLane.intent(request), .capture, request)
      XCTAssertNil(FastLane.oneOffReminder(request, now: now, calendar: calendar), request)
    }
  }
}
