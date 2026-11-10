import TodayCore
import XCTest

final class TimelineNowCenteringTests: XCTestCase {
  private let today = Date(timeIntervalSince1970: 1_800_000_000)
  private let short: [CGFloat] = [400, 700]
  private let tall: [CGFloat] = [900, 700]

  func testHoldsOnlyOnTodayWithScrollToNowOn() {
    var centering = TimelineNowCentering()
    XCTAssertFalse(centering.isHolding)
    centering.arm(on: today, isToday: true, jumpsToNow: false, explicit: true)
    XCTAssertFalse(centering.isHolding)
    centering.arm(on: today.addingTimeInterval(86400), isToday: false, jumpsToNow: true)
    XCTAssertFalse(centering.isHolding)
    centering.arm(on: today, isToday: true, jumpsToNow: true, explicit: true)
    XCTAssertTrue(centering.isHolding)
  }

  func testLateRowsRecenterUntilTheFirstTouch() {
    var centering = TimelineNowCentering()
    XCTAssertFalse(centering.recenters(from: short, to: tall, isDragging: false), "not armed")
    centering.arm(on: today, isToday: true, jumpsToNow: true)
    XCTAssertTrue(centering.recenters(from: short, to: tall, isDragging: false))
    XCTAssertFalse(centering.recenters(from: tall, to: tall, isDragging: false), "no change")
    XCTAssertFalse(centering.recenters(from: short, to: tall, isDragging: true), "mid drag")
    centering.touched()
    XCTAssertFalse(centering.recenters(from: short, to: tall, isDragging: false))
  }

  func testLeavingTodayEndsTheHoldAndComingBackStartsIt() {
    var centering = TimelineNowCentering()
    centering.arm(on: today, isToday: true, jumpsToNow: true)
    centering.arm(on: today.addingTimeInterval(86400), isToday: false, jumpsToNow: true)
    XCTAssertFalse(centering.recenters(from: short, to: tall, isDragging: false))
    centering.arm(on: today, isToday: true, jumpsToNow: true)
    XCTAssertTrue(centering.recenters(from: short, to: tall, isDragging: false))
  }

  func testMutationAndReappearanceCannotReviveDismissedNavigation() {
    var centering = TimelineNowCentering()
    XCTAssertTrue(centering.arm(on: today, isToday: true, jumpsToNow: true))
    centering.touched()
    XCTAssertFalse(centering.arm(on: today, isToday: true, jumpsToNow: true))
    XCTAssertFalse(centering.recenters(from: tall, to: short, isDragging: false))
    XCTAssertFalse(centering.recenters(from: short, to: tall, isDragging: false))
    XCTAssertTrue(centering.arm(on: today, isToday: true, jumpsToNow: true, explicit: true))
    XCTAssertTrue(centering.recenters(from: short, to: tall, isDragging: false))
  }

}
