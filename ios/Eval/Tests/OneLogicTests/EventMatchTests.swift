import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// Finding the Apple Calendar occurrence that was tapped (Delete This Event Only, Apple's editor) and a re-keyed copy.
final class EventMatchTests: XCTestCase {
  private let day = 86_400.0
  private let today = Date(timeIntervalSince1970: 1_792_000_000)

  /// A daily series shares one identifier: the tapped day's occurrence is picked, not the first one.
  func testPicksTheTappedOccurrenceNotTheFirst() {
    let series = [(-1.0, "A"), (0, "A"), (1, "A")].map {
      (id: Optional($0.1), start: today.addingTimeInterval($0.0 * day))
    }
    XCTAssertEqual(EventMatch.occurrence("A", at: today, in: series), 1)
    XCTAssertEqual(EventMatch.occurrence("A", at: today.addingTimeInterval(day), in: series), 2)
  }

  func testOtherEventAtTheSameTimeIsNotIt() {
    let found = [(id: Optional("B"), start: today), (id: Optional("A"), start: today)]
    XCTAssertEqual(EventMatch.occurrence("A", at: today, in: found), 1)
    XCTAssertNil(EventMatch.occurrence("C", at: today, in: found))
  }

  func testWithinAMinuteCounts() {
    XCTAssertTrue(EventMatch.sameStart(today, today.addingTimeInterval(59)))
    XCTAssertTrue(EventMatch.sameStart(today, today.addingTimeInterval(-59)))
    XCTAssertFalse(EventMatch.sameStart(today, today.addingTimeInterval(60)))
    XCTAssertNil(
      EventMatch.occurrence("A", at: today, in: [(id: "A", start: today.addingTimeInterval(3600))]))
  }

  func testReKeyedCopyIsFoundByTitleAndStart() {
    let found = [
      (title: Optional("Lunch"), start: today.addingTimeInterval(3600)),
      (title: Optional("Standup"), start: today.addingTimeInterval(20)),
      (title: Optional("Lunch"), start: today.addingTimeInterval(10)),
    ]
    XCTAssertEqual(EventMatch.copy(titled: "Lunch", at: today, in: found), 2)
    XCTAssertNil(EventMatch.copy(titled: "Dinner", at: today, in: found))
    XCTAssertNil(EventMatch.copy(titled: "Lunch", at: today, in: [(title: nil, start: today)]))
  }

}
