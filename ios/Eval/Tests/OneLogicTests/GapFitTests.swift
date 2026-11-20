import XCTest

@testable import TodayCore

final class GapFitTests: XCTestCase {
  private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()

  private func at(_ hour: Int, _ minute: Int = 0, second: Int = 0, day: Int = 16) -> Date {
    cal.date(
      from: DateComponents(
        year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
  }

  private func gap(_ from: Int, _ to: Int, day: Int = 16) -> DateInterval {
    DateInterval(start: at(from, day: day), end: at(to, day: day))
  }

  private func reminder(
    _ minutes: Int = GapFit.unstatedMinutes, due: Date? = nil, timed: Bool = true,
    repeats: Bool = false, flagged: Bool = false
  ) -> GapFit.Reminder {
    GapFit.Reminder(
      minutes: minutes, due: due, dueHasTime: due != nil && timed, repeats: repeats,
      flagged: flagged)
  }

  func testStartRoundsNowUpToTheNextMinuteInsideTheGap() {
    let free = DateInterval(start: at(10, 42, second: 17), end: at(12))
    XCTAssertEqual(GapFit.start(of: free, now: at(10, 42, second: 17), calendar: cal), at(10, 43))
    XCTAssertEqual(GapFit.start(of: gap(11, 12), now: at(9), calendar: cal), at(11))
    XCTAssertNil(GapFit.start(of: gap(11, 12), now: at(12), calendar: cal))
  }

  func testStatedLengthFitsOrCountsAsTooLong() throws {
    let result = try XCTUnwrap(
      GapFit.candidates(
        for: gap(9, 10), reminders: [reminder(90), reminder(45), reminder()], now: at(8),
        calendar: cal))
    XCTAssertEqual(
      result.candidates,
      [GapFit.Candidate(index: 1, fit: .fits), GapFit.Candidate(index: 2, fit: .unknown)])
    XCTAssertEqual(result.tooLong, 1)
    XCTAssertEqual(result.start, at(9))
  }

  func testDefaultLengthIsUnknownNotAFit() {
    XCTAssertNil(reminder().statedMinutes)
    XCTAssertEqual(reminder(90).statedMinutes, 90)
  }

  func testRepeatingRemindersAreNeverOffered() throws {
    let result = try XCTUnwrap(
      GapFit.candidates(
        for: gap(9, 10), reminders: [reminder(repeats: true)], now: at(8), calendar: cal))
    XCTAssertTrue(result.candidates.isEmpty)
  }

  func testGapAfterADeadlineIsNotOffered() throws {
    let result = try XCTUnwrap(
      GapFit.candidates(
        for: gap(14, 16),
        reminders: [
          reminder(due: at(13)), reminder(due: at(18)), reminder(60, due: at(14, 30)),
          reminder(due: at(0, day: 16), timed: false),
        ],
        now: at(13, 30), calendar: cal))
    XCTAssertEqual(
      result.candidates.map(\.index), [0, 3, 1],
      "Overdue first, then nearest deadline; a 60 min block cannot finish before 14:30")
  }

  func testOrderPutsStatedFitsFirstThenOverdueThenDueThenUndatedFlagged() throws {
    let result = try XCTUnwrap(
      GapFit.candidates(
        for: gap(9, 12),
        reminders: [
          reminder(), reminder(flagged: true), reminder(due: at(18, day: 17)),
          reminder(due: at(9, day: 15)), reminder(60),
        ],
        now: at(8), calendar: cal))
    XCTAssertEqual(result.candidates.map(\.index), [4, 3, 2, 1, 0])
  }

  func testFarFutureDeadlinesAndItemsAlreadyAtTheStartAreSkipped() throws {
    let result = try XCTUnwrap(
      GapFit.candidates(
        for: gap(9, 12),
        reminders: [
          reminder(due: at(9)), reminder(due: at(9, day: 30)), reminder(due: at(9, day: 20)),
        ],
        now: at(8), calendar: cal))
    XCTAssertEqual(result.candidates.map(\.index), [2])
  }

  func testConclusionNamesTheNextOpeningForAStatedLength() throws {
    let reminders = [reminder(due: at(0), timed: false), reminder(90, due: at(0), timed: false)]
    let gaps = [gap(10, 11), gap(14, 16)]
    let c = try XCTUnwrap(
      GapFit.conclusion(reminders: reminders, gaps: gaps, now: at(9), calendar: cal))
    XCTAssertEqual(c.kind, .fits(index: 1, minutes: 90))
    XCTAssertEqual(c.opening, gaps[1])
    XCTAssertEqual(
      c.text(title: { ["A", "Proposal"][$0] }, time: { $0 == at(14) ? "14:00" : "?" }),
      "“Proposal” needs 1 h 30 min · fits at 14:00")
  }

  func testConclusionSaysWhenNoOpeningIsLongEnough() throws {
    let c = try XCTUnwrap(
      GapFit.conclusion(
        reminders: [reminder(120, due: at(0), timed: false)], gaps: [gap(10, 11)], now: at(9),
        calendar: cal))
    XCTAssertEqual(c.kind, .tooLong(index: 0, minutes: 120))
    XCTAssertNil(c.opening)
    XCTAssertEqual(
      c.text(title: { _ in "Report" }, time: { _ in "" }),
      "“Report” needs 2 h · no opening that long left today")
  }

  func testConclusionWithUnknownLengthsCountsFreeTime() throws {
    let reminders = [reminder(due: at(0), timed: false), reminder(due: at(0), timed: false)]
    let c = try XCTUnwrap(
      GapFit.conclusion(
        reminders: reminders, gaps: [gap(10, 11), gap(14, 15, day: 16)], now: at(9),
        calendar: cal))
    XCTAssertEqual(c.kind, .due(count: 2, freeMinutes: 120))
    XCTAssertEqual(
      c.text(title: { _ in "" }, time: { _ in "10:00" }), "2 due today · 2 h free, next at 10:00")
    let none = try XCTUnwrap(
      GapFit.conclusion(reminders: reminders, gaps: [], now: at(9), calendar: cal))
    XCTAssertEqual(
      none.text(title: { _ in "" }, time: { _ in "" }), "2 due today · no free time left today")
  }

  func testConclusionIgnoresTimedAndPlacedReminders() {
    XCTAssertNil(
      GapFit.conclusion(
        reminders: [reminder(90, due: at(14)), reminder(due: at(0, day: 17), timed: false)],
        gaps: [gap(10, 11)], now: at(9), calendar: cal),
      "A reminder placed in a gap has a time and must not warn about itself")
  }
}
