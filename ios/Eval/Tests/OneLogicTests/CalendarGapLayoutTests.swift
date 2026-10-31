import XCTest

@testable import TodayCore

final class CalendarGapLayoutTests: XCTestCase {
  private typealias Gap = CalendarGapLayout.Interval
  private typealias Day = CalendarGapLayout.Day

  private func layout(_ days: [Day], expanded: Set<Gap> = []) -> CalendarGapLayout {
    CalendarGapLayout(
      days: days, pointsPerHour: 60, minimumGapMinutes: 60,
      compressedGapHeight: 20, expandedGaps: expanded)
  }

  func testCommonGapsUseUnionOfClippedOverlappingAndAdjacentEvents() {
    let axis = layout([
      Day(intervals: [
        Gap(start: -30, end: 90), Gap(start: 120, end: 240),
        Gap(start: 220, end: 300), Gap(start: 1400, end: 1500),
      ]),
      Day(intervals: [
        Gap(start: 300, end: 360), Gap(start: 720, end: 780),
        Gap(start: 900, end: 850),
      ]),
    ])
    XCTAssertEqual(axis.gaps, [Gap(start: 360, end: 720), Gap(start: 780, end: 1380)])
    XCTAssertEqual(axis.height(from: 120, to: 360), 240, accuracy: 0.0001)
  }

  func testMarksOccupyTheirHourAndMidnightIsOutsideTheDay() {
    let axis = layout([Day(marks: [0, 60, 120, 120, 1439, 1440, -1, 1441])])
    XCTAssertEqual(axis.gaps, [Gap(start: 180, end: 1380)])
    XCTAssertEqual(axis.height(from: 1380, to: 1440), 60, accuracy: 0.0001)
    XCTAssertEqual(layout([Day(marks: [1440])]).gaps, [Gap(start: 0, end: 1440)])
  }

  func testTouchedHoursAndHalfOpenEndBoundaries() {
    let axis = layout([
      Day(intervals: [
        Gap(start: 61, end: 120), Gap(start: 180, end: 180.01),
        Gap(start: 300, end: 360), Gap(start: 420, end: 420),
      ])
    ])
    XCTAssertEqual(
      axis.gaps,
      [
        Gap(start: 0, end: 60), Gap(start: 120, end: 180),
        Gap(start: 240, end: 300), Gap(start: 360, end: 1440),
      ])
  }

  func testMinimumDurationFiltersWholeHourRuns() {
    let axis = CalendarGapLayout(
      days: [Day(intervals: [Gap(start: 60, end: 120), Gap(start: 240, end: 1440)])],
      pointsPerHour: 60, minimumGapMinutes: 120, compressedGapHeight: 20)
    XCTAssertEqual(axis.gaps, [Gap(start: 120, end: 240)])
  }

  func testNoDaysAndFullyBusyDayAreNotCompressed() {
    for axis in [layout([]), layout([Day(intervals: [Gap(start: 0, end: 1440)])])] {
      XCTAssertTrue(axis.gaps.isEmpty)
      XCTAssertEqual(axis.height, 1440, accuracy: 0.0001)
      XCTAssertEqual(axis.y(forMinute: 600), 600, accuracy: 0.0001)
    }
    XCTAssertEqual(layout([Day()]).gaps, [Gap(start: 0, end: 1440)])
  }

  func testMappingDurationsBoundariesAndNowRoundTrip() {
    let axis = layout([Day(intervals: [Gap(start: 120, end: 180), Gap(start: 300, end: 1440)])])
    XCTAssertEqual(axis.gaps, [Gap(start: 0, end: 120), Gap(start: 180, end: 300)])
    XCTAssertEqual(axis.height, 1240, accuracy: 0.0001)
    XCTAssertEqual(axis.y(forMinute: 120), 20, accuracy: 0.0001)
    XCTAssertEqual(axis.y(forMinute: 180), 80, accuracy: 0.0001)
    XCTAssertEqual(axis.y(forMinute: 240), 90, accuracy: 0.0001)  // now inside a gap
    XCTAssertEqual(axis.height(from: 60, to: 240), 80, accuracy: 0.0001)
    XCTAssertEqual(axis.height(from: 300, to: 120), 0, accuracy: 0.0001)
    for minute in [0.0, 60, 120, 150, 180, 240, 300, 1440] {
      XCTAssertEqual(axis.minute(atY: axis.y(forMinute: minute)), minute, accuracy: 0.0001)
    }
    XCTAssertEqual(axis.y(forMinute: -1), 0, accuracy: 0.0001)
    XCTAssertEqual(axis.y(forMinute: 1500), axis.height, accuracy: 0.0001)
    XCTAssertEqual(axis.minute(atY: -1), 0, accuracy: 0.0001)
    XCTAssertEqual(axis.minute(atY: axis.height + 1), 1440, accuracy: 0.0001)
  }

  func testExpandingOneGapKeepsIdentitiesAndRestoresItsFullHeight() {
    let day = Day(intervals: [Gap(start: 120, end: 180), Gap(start: 300, end: 1440)])
    let collapsed = layout([day])
    let expanded = layout([day], expanded: [Gap(start: 0, end: 120)])
    XCTAssertEqual(expanded.gaps, collapsed.gaps)
    XCTAssertEqual(expanded.height - collapsed.height, 100, accuracy: 0.0001)
    XCTAssertEqual(expanded.y(forMinute: 60), 60, accuracy: 0.0001)
    XCTAssertEqual(expanded.y(forMinute: 240), 190, accuracy: 0.0001)
    XCTAssertEqual(expanded.minute(atY: 190), 240, accuracy: 0.0001)
  }

  func testCompressionNeverMakesAGapTaller() {
    let axis = CalendarGapLayout(
      days: [Day()], pointsPerHour: 1, minimumGapMinutes: 60, compressedGapHeight: 30)
    XCTAssertEqual(axis.height, 24, accuracy: 0.0001)
    XCTAssertEqual(axis.minute(atY: 12), 720, accuracy: 0.0001)
  }
  func testGapLabelAndCenterFollowCompressedAxis() {
    let axis = CalendarGapLayout(
      days: [Day(intervals: [Gap(start: 480, end: 900)])], pointsPerHour: 48,
      minimumGapMinutes: 120, compressedGapHeight: 44)
    let gap = Gap(start: 0, end: 480)
    XCTAssertEqual(CalendarGapPresentation.rangeLabel(start: gap.start, end: gap.end), "00–08")
    XCTAssertEqual(CalendarGapPresentation.rangeLabel(start: 900, end: 1440), "15–24")
    XCTAssertEqual(CalendarGapPresentation.centerY(axis: axis, gap: gap), 22, accuracy: 0.001)
    XCTAssertEqual(axis.y(forMinute: gap.end), 44, accuracy: 0.001)
  }

}
