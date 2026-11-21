import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// Reordering a row of pills (Reminders smart lists and pinned lists): drag, Move Left / Move Right, hidden entries
/// and the stored form.
final class PillOrderTests: XCTestCase {
  private enum Kind: String, CaseIterable, Hashable {
    case today, scheduled, all, flagged, completed
  }

  func testMoveFromTo() {
    XCTAssertEqual(PillOrder.move([1, 2, 3, 4], from: 0, to: 2), [2, 3, 1, 4])
    XCTAssertEqual(PillOrder.move([1, 2, 3, 4], from: 3, to: 0), [4, 1, 2, 3])
    XCTAssertEqual(PillOrder.move([1, 2, 3], from: 1, to: 1), [1, 2, 3])
  }

  func testMoveClampsAndIgnoresBadIndexes() {
    XCTAssertEqual(PillOrder.move([1, 2, 3], from: 0, to: 99), [2, 3, 1])
    XCTAssertEqual(PillOrder.move([1, 2, 3], from: 2, to: -5), [3, 1, 2])
    XCTAssertEqual(PillOrder.move([1, 2, 3], from: 7, to: 0), [1, 2, 3])
    XCTAssertEqual(PillOrder.move([Int](), from: 0, to: 0), [])
  }

  func testMoveByOffsetStopsAtTheEnds() {
    XCTAssertEqual(PillOrder.move(["a", "b", "c"], "a", by: 1), ["b", "a", "c"])
    XCTAssertEqual(PillOrder.move(["a", "b", "c"], "c", by: -1), ["a", "c", "b"])
    XCTAssertEqual(
      PillOrder.move(["a", "b", "c"], "a", by: -1), ["a", "b", "c"],
      "Move Left on the first pill does nothing")
    XCTAssertEqual(
      PillOrder.move(["a", "b", "c"], "c", by: 1), ["a", "b", "c"],
      "Move Right on the last pill does nothing")
    XCTAssertEqual(PillOrder.move(["a", "b", "c"], "z", by: 1), ["a", "b", "c"])
  }

  func testDropTakesTheTargetsPlace() {
    XCTAssertEqual(
      PillOrder.move(["a", "b", "c", "d"], "a", onto: "c"), ["b", "c", "a", "d"],
      "dragging right lands after the target")
    XCTAssertEqual(
      PillOrder.move(["a", "b", "c", "d"], "d", onto: "b"), ["a", "d", "b", "c"],
      "dragging left lands before the target")
    XCTAssertEqual(PillOrder.move(["a", "b", "c"], "b", onto: "b"), ["a", "b", "c"])
    XCTAssertEqual(PillOrder.move(["a", "b", "c"], "b", onto: "zzz"), ["a", "b", "c"])
  }

  func testReorderingTheShownPillsKeepsHiddenOnesInPlace() {
    // Stored order today, scheduled, all, flagged, completed; scheduled and flagged are hidden.
    let full: [Kind] = [.today, .scheduled, .all, .flagged, .completed]
    let shown = full.filter { $0 != .scheduled && $0 != .flagged }
    let moved = PillOrder.move(shown, .completed, by: -2)  // completed, today, all
    XCTAssertEqual(moved, [.completed, .today, .all])
    XCTAssertEqual(
      PillOrder.merge(visible: moved, into: full), [.completed, .scheduled, .today, .flagged, .all])
    XCTAssertEqual(PillOrder.merge(visible: shown, into: full), full, "no change in, no change out")
  }

  func testDecodeDropsUnknownAndRepeatedAndAppendsNewCases() {
    XCTAssertEqual(PillOrder.decode("", all: Kind.allCases), Kind.allCases)
    XCTAssertEqual(
      PillOrder.decode("all,bogus,all,today", all: Kind.allCases),
      [.all, .today, .scheduled, .flagged, .completed])
  }
}
