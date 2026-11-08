import Foundation
import Testing

@testable import TodayCore

struct TimelineDragTimeTests {
  let calendar = Calendar(identifier: .gregorian)
  var day: Date { Date(timeIntervalSince1970: 1_800_000_000) }
  var midnight: Date { calendar.startOfDay(for: day) }

  @Test func theFullDurationStaysInTheDay() throws {
    let drag = try #require(
      TimelineDragTime(
        original: midnight.addingTimeInterval(12 * 3600), day: day, duration: 3600,
        calendar: calendar))
    #expect(drag.earliest == midnight)
    #expect(drag.latest == midnight.addingTimeInterval(23 * 3600))
    #expect(
      TimelineDragTime(
        original: midnight.addingTimeInterval(12 * 3600), day: day, duration: 90000,
        calendar: calendar) == nil)
  }

  @Test func daylightSavingUsesTheActualDay() throws {
    var cal = calendar
    cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let date = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
    let drag = try #require(
      TimelineDragTime(original: date, day: date, duration: 3600, calendar: cal))
    #expect(drag.latest.timeIntervalSince(drag.earliest) == 24 * 3600)
  }

  @Test func aSourceWindowNarrowsTheDay() throws {
    let lower = midnight.addingTimeInterval(10 * 3600 + 60)
    let upper = midnight.addingTimeInterval(14 * 3600 + 120)
    let drag = try #require(
      TimelineDragTime(
        original: midnight.addingTimeInterval(11 * 3600), day: day, calendar: calendar,
        minimumStart: lower, maximumStart: upper))
    #expect(drag.earliest == lower)
    #expect(drag.latest == upper)
  }
}

struct TimelineDropPlanTests {
  let calendar = Calendar(identifier: .gregorian)
  var day: Date { Date(timeIntervalSince1970: 1_800_000_000) }
  var midnight: Date { calendar.startOfDay(for: day) }

  func at(_ hour: Int, _ minute: Int = 0) -> Date {
    midnight.addingTimeInterval(Double(hour * 3600 + minute * 60))
  }

  func anchor(_ start: Date, ends end: Date? = nil) -> TimelineDropAnchor {
    TimelineDropAnchor(start: start, end: end)
  }

  /// A reminder from none of these places, so every place is worked out.
  func stops(
    _ anchors: [TimelineDropAnchor], duration: TimeInterval = 0, earliest: Date? = nil,
    latest: Date? = nil, boundaries: DayPart.Boundaries = .standard
  ) throws -> [TimelineDropStop] {
    let timing = try #require(
      TimelineDragTime(
        original: at(23, 50), day: day, duration: duration, calendar: calendar,
        minimumStart: earliest ?? midnight.addingTimeInterval(60), maximumStart: latest))
    return TimelineDropPlan.stops(
      anchors: anchors, originalIndex: -1, timing: timing, day: day, calendar: calendar,
      boundaries: boundaries)
  }

  func target(_ stops: [TimelineDropStop], part: DayPart, index: Int) -> Date? {
    stops.first { $0.part == part && $0.index == index }?.target
  }

  @Test func aNormalGapUsesItsRoundedMiddle() throws {
    let plan = try stops([anchor(at(10, 21)), anchor(at(11, 16))])
    #expect(target(plan, part: .morning, index: 1) == at(10, 50))
  }

  @Test func aPreviousEventCountsFromItsEnd() throws {
    let plan = try stops([anchor(at(14), ends: at(14, 50)), anchor(at(15, 30))])
    #expect(target(plan, part: .afternoon, index: 1) == at(15, 10))
  }

  @Test func aSmallGapIsPreviousPlusOneMinute() throws {
    let plan = try stops([anchor(at(11, 16)), anchor(at(11, 20))])
    #expect(target(plan, part: .morning, index: 1) == at(11, 17))
  }

  @Test func aMiddleRoundedOntoANeighbourFallsBackToOneMinute() throws {
    let plan = try stops([anchor(at(10, 10)), anchor(at(10, 15))])
    #expect(target(plan, part: .morning, index: 1) == at(10, 11))
  }

  @Test func theNowLineIsANeighbour() throws {
    let plan = try stops([anchor(at(10, 17, seconds: 30)), anchor(at(10, 21))])
    #expect(target(plan, part: .morning, index: 1) == at(10, 18))
    #expect(target(plan, part: .morning, index: 0) == at(9, 45))
  }

  @Test func firstAndLastSitHalfAnHourFromTheirNeighbour() throws {
    let plan = try stops([anchor(at(7, 36)), anchor(at(20, 12))])
    #expect(target(plan, part: .morning, index: 0) == at(7, 5))
    #expect(target(plan, part: .evening, index: 2) == at(20, 40))
  }

  @Test func theLastPlaceNeverCrossesTheDay() throws {
    let plan = try stops([anchor(at(23, 58))])
    let last = try #require(target(plan, part: .evening, index: 1))
    #expect(last > at(23, 58))
    #expect(calendar.isDate(last, inSameDayAs: day))
  }

  @Test func movedBoundariesDecideTheCardADropStaysIn() throws {
    let plan = try stops(
      [anchor(at(13)), anchor(at(15))], boundaries: DayPart.Boundaries(afternoon: 14, evening: 20))
    #expect(target(plan, part: .morning, index: 1) == at(13, 30))
    #expect(target(plan, part: .afternoon, index: 1) == at(14, 30))
  }

  @Test func anEmptyPartStaysInsideMovedBoundaries() throws {
    let plan = try stops([], boundaries: DayPart.Boundaries(afternoon: 8, evening: 20))
    #expect(target(plan, part: .morning, index: 0) == at(7))
    #expect(target(plan, part: .afternoon, index: 0) == at(14))
    #expect(target(plan, part: .evening, index: 0) == at(20))
  }

  @Test func anEmptyPartOffersItsUsualTime() throws {
    let plan = try stops([anchor(at(7, 36))])
    #expect(target(plan, part: .afternoon, index: 1) == at(14))
    #expect(target(plan, part: .evening, index: 1) == at(19))
    let none = try stops([])
    #expect(target(none, part: .morning, index: 0) == at(9))
  }

  @Test func theTopAndBottomOfACardStayInThatPart() throws {
    let plan = try stops([anchor(at(10)), anchor(at(13)), anchor(at(19))])
    #expect(target(plan, part: .morning, index: 1) == at(11))
    #expect(target(plan, part: .afternoon, index: 1) == at(12, 30))
    #expect(target(plan, part: .afternoon, index: 2) == at(15, 30))
    #expect(target(plan, part: .evening, index: 2) == at(18, 30))
  }

  @Test func firstInTheDayAtACardTopDoesNotLeaveTheCard() throws {
    let plan = try stops([anchor(at(12, 10))])
    #expect(target(plan, part: .afternoon, index: 0) == at(12, 5))
  }

  @Test func anEventRunningIntoTheNextPartLeavesNoRoomAtItsCardBottom() throws {
    let plan = try stops([anchor(at(11), ends: at(13))])
    #expect(target(plan, part: .morning, index: 1) == nil)
    #expect(target(plan, part: .afternoon, index: 1) == at(14))
  }

  @Test func anEventThatFitsIsCentred() throws {
    let plan = try stops([anchor(at(9)), anchor(at(11))], duration: 3600)
    #expect(target(plan, part: .morning, index: 1) == at(9, 30))
  }

  @Test func anEventThatDoesNotFitStartsAtThePreviousEnd() throws {
    let plan = try stops(
      [anchor(at(9), ends: at(10)), anchor(at(10, 20))], duration: 3600)
    #expect(target(plan, part: .morning, index: 1) == at(10))
  }

  @Test func identicalNeighboursGiveTheSameTime() throws {
    let plan = try stops([anchor(at(11)), anchor(at(11))])
    #expect(target(plan, part: .morning, index: 1) == at(11))
  }

  @Test func aOneOffAlarmCannotLandAboveNow() throws {
    let plan = try stops(
      [anchor(at(8)), anchor(at(10, 17)), anchor(at(11))], earliest: at(10, 18), latest: at(23, 55))
    #expect(target(plan, part: .morning, index: 1) == nil)
    #expect(target(plan, part: .morning, index: 2) == at(10, 40))
    let reminder = try stops([anchor(at(8)), anchor(at(10, 17)), anchor(at(11))])
    #expect(target(reminder, part: .morning, index: 1) != nil)
  }

  @Test func aReminderNeverBecomesDateOnlyMidnight() throws {
    let plan = try stops([anchor(at(0, 2))])
    #expect(target(plan, part: .morning, index: 0) == at(0, 1))
  }

  @Test func theOriginalPlaceKeepsTheOriginalTime() throws {
    let original = at(10, 33)
    let timing = try #require(TimelineDragTime(original: original, day: day, calendar: calendar))
    let plan = TimelineDropPlan.stops(
      anchors: [anchor(at(10)), anchor(at(11))], originalIndex: 1, timing: timing, day: day,
      calendar: calendar)
    #expect(target(plan, part: .morning, index: 1) == original)
    #expect(plan.count == 5)
  }

  func at(_ hour: Int, _ minute: Int, seconds: Int) -> Date {
    at(hour, minute).addingTimeInterval(Double(seconds))
  }
}
