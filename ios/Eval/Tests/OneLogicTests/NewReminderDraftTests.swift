import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class NewReminderDraftTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()
  // Friday 16 Oct 2026, 22:17
  lazy var now = cal.date(
    from: DateComponents(year: 2026, month: 10, day: 16, hour: 22, minute: 17))!

  private func parts(_ d: Date?) -> DateComponents? {
    d.map { cal.dateComponents([.month, .day, .hour, .minute], from: $0) }
  }

  func testTomorrowWithoutADateStartsAtTheNextQuarterHour() {
    var d = NewReminderDraft(title: "Call mom")
    d.choose(.tomorrow, now: now, calendar: cal)
    XCTAssertEqual(parts(d.due), DateComponents(month: 10, day: 17, hour: 22, minute: 30))
  }

  func testChoosingADayKeepsTheChosenTime() {
    var d = NewReminderDraft(
      title: "Run",
      due: cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 7, minute: 45)))
    d.choose(.weekend, now: now, calendar: cal)
    XCTAssertEqual(
      parts(d.due), DateComponents(month: 10, day: 17, hour: 7, minute: 45),
      "This Weekend = the coming Saturday")
    d.choose(.nextWeek, now: now, calendar: cal)
    XCTAssertEqual(
      parts(d.due), DateComponents(month: 10, day: 19, hour: 7, minute: 45),
      "Next Week = next Monday")
  }

  func testRepeatNeedsADateAndClearingTheDateDropsIt() {
    var d = NewReminderDraft(title: "Water plants")
    XCTAssertFalse(d.canRepeat)
    d.choose(.today, now: now, calendar: cal)
    d.repeatRule = .weekly
    XCTAssertTrue(d.canRepeat)
    d.clearDate()
    XCTAssertNil(d.due)
    XCTAssertNil(d.repeatRule)
  }

  func testSuggestionFillsTitleAndDateWhenItHasOne() {
    var d = NewReminderDraft()
    d.apply(.init(title: "Gym", when: nil))
    XCTAssertEqual(d.title, "Gym")
    XCTAssertNil(d.due, "a suggestion without a usual time adds no date")
    let at = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 8, minute: 0))!
    d.apply(.init(title: "Stand-up", when: at))
    XCTAssertEqual(d.title, "Stand-up")
    XCTAssertEqual(d.due, at)
  }
}
