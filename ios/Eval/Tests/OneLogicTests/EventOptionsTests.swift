import XCTest

@testable import TodayCore

/// New events: alert words, which calendar they go to, and the two Settings choices.
final class EventOptionsTests: XCTestCase {
  private func freshDefaults() -> UserDefaults {
    let name = "EventOptionsTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  // MARK: Alerts

  func testAlertsReadLikeAppleCalendar() {
    let offsets: [TimeInterval] = [0, -300, -600, -3600, -7200, -86400, -604_800]
    XCTAssertEqual(
      offsets.map { EventAlert.label($0) },
      [
        "At time of event", "5 minutes before", "10 minutes before", "1 hour before",
        "2 hours before", "1 day before", "1 week before",
      ])
    XCTAssertEqual(EventAlert.label(-90 * 60), "90 minutes before")
    XCTAssertEqual(EventAlert.label(600), "10 minutes after")
  }

  // MARK: Which calendar

  private let calendars = [
    EventCalendarChoice.Candidate(id: "home", title: "Home"),
    EventCalendarChoice.Candidate(id: "work", title: "Work"),
    EventCalendarChoice.Candidate(id: "family", title: "Family"),
    EventCalendarChoice.Candidate(id: "jia", title: "家庭"),
    EventCalendarChoice.Candidate(id: "holidays", title: "US Holidays", writable: false),
  ]

  func testExplicitThenPreferredThenSystemDefault() {
    XCTAssertEqual(
      EventCalendarChoice.resolve(explicit: "work", preferred: "home", calendars: calendars),
      "work")
    XCTAssertEqual(
      EventCalendarChoice.resolve(explicit: nil, preferred: "home", calendars: calendars), "home")
    XCTAssertNil(
      EventCalendarChoice.resolve(explicit: nil, preferred: nil, calendars: calendars),
      "nil = the system default calendar")
    XCTAssertEqual(
      EventCalendarChoice.resolve(explicit: "gone", preferred: "home", calendars: calendars),
      "home", "a calendar that no longer exists falls through")
    XCTAssertNil(
      EventCalendarChoice.resolve(explicit: "holidays", preferred: nil, calendars: calendars),
      "a read-only calendar is never written to")
  }

  func testWordsNameACalendarOnlyWhenClear() {
    XCTAssertEqual(
      EventCalendarChoice.named(in: "Family dinner Friday 7pm", calendars: calendars), "family")
    XCTAssertEqual(EventCalendarChoice.named(in: "周五家庭聚餐", calendars: calendars), "jia")
    XCTAssertNil(
      EventCalendarChoice.named(in: "Finish homework at 5", calendars: calendars),
      "a name inside another word is not a match")
    XCTAssertNil(
      EventCalendarChoice.named(in: "Work trip home", calendars: calendars),
      "two calendars named: ambiguous, use the default")
    XCTAssertNil(EventCalendarChoice.named(in: "Dentist at 3", calendars: calendars))
    XCTAssertNil(
      EventCalendarChoice.named(in: "US Holidays party", calendars: calendars),
      "read-only calendars are not candidates")
  }

  // MARK: Settings

  func testNewEventDefaultsAreWhatTodayDidBefore() {
    let d = freshDefaults()
    XCTAssertEqual(Preferences.newEventCalendar, "", "Auto")
    XCTAssertNil(Preferences.newEventCalendar(writable: ["home", "work"], d))
    XCTAssertEqual(Preferences.newEventAlertMinutes(d), 10, "Today always added 10 minutes before")
  }

  func testNewEventChoicesApplyWhileTheyStillExist() {
    let d = freshDefaults()
    d.set("work", forKey: Preferences.newEventCalendarKey)
    XCTAssertEqual(Preferences.newEventCalendar(writable: ["home", "work"], d), "work")
    XCTAssertNil(
      Preferences.newEventCalendar(writable: ["home"], d), "a deleted calendar falls back to Auto")
    d.set(Preferences.noEventAlert, forKey: Preferences.newEventAlertKey)
    XCTAssertNil(Preferences.newEventAlertMinutes(d))
    d.set(30, forKey: Preferences.newEventAlertKey)
    XCTAssertEqual(Preferences.newEventAlertMinutes(d), 30)
    d.set(7, forKey: Preferences.newEventAlertKey)
    XCTAssertEqual(Preferences.newEventAlertMinutes(d), 10, "an unknown value reads as the default")
    XCTAssertEqual(Preferences.newEventAlertLabel(Preferences.noEventAlert), "None")
    XCTAssertEqual(Preferences.newEventAlertLabel(60), "1 hour before")
  }

  // MARK: Cards

  func testEventCardsKeepTheirCalendarAndAlert() throws {
    var c = Capture(title: "Family dinner", day: Date(timeIntervalSince1970: 0), hasDay: true)
    c.kind = .event
    let old = try JSONDecoder().decode(Capture.self, from: JSONEncoder().encode(c))
    XCTAssertNil(old.calendarID, "cards saved before calendars decode as the default")
    XCTAssertNil(old.alertMinutes)
    c.calendarID = "family"
    c.calendarTitle = "Family"
    c.alertMinutes = Preferences.noEventAlert
    XCTAssertEqual(try JSONDecoder().decode(Capture.self, from: JSONEncoder().encode(c)), c)
  }
}
