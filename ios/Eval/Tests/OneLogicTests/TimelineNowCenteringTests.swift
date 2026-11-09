import TodayCore
import XCTest

final class TimelineNowCenteringTests: XCTestCase {
  private let short: [CGFloat] = [400, 700]
  private let tall: [CGFloat] = [900, 700]

  func testHoldsOnlyOnTodayWithScrollToNowOn() {
    var centering = TimelineNowCentering()
    XCTAssertFalse(centering.isHolding)
    centering.arm(isToday: true, jumpsToNow: false)
    XCTAssertFalse(centering.isHolding)
    centering.arm(isToday: false, jumpsToNow: true)
    XCTAssertFalse(centering.isHolding)
    centering.arm(isToday: true, jumpsToNow: true)
    XCTAssertTrue(centering.isHolding)
  }

  func testLateRowsRecenterUntilTheFirstTouch() {
    var centering = TimelineNowCentering()
    XCTAssertFalse(centering.recenters(from: short, to: tall, isDragging: false), "not armed")
    centering.arm(isToday: true, jumpsToNow: true)
    XCTAssertTrue(centering.recenters(from: short, to: tall, isDragging: false))
    XCTAssertFalse(centering.recenters(from: tall, to: tall, isDragging: false), "no change")
    XCTAssertFalse(centering.recenters(from: short, to: tall, isDragging: true), "mid drag")
    centering.touched()
    XCTAssertFalse(centering.recenters(from: short, to: tall, isDragging: false))
  }

  func testLeavingTodayEndsTheHoldAndComingBackStartsIt() {
    var centering = TimelineNowCentering()
    centering.arm(isToday: true, jumpsToNow: true)
    centering.arm(isToday: false, jumpsToNow: true)
    XCTAssertFalse(centering.recenters(from: short, to: tall, isDragging: false))
    centering.arm(isToday: true, jumpsToNow: true)
    XCTAssertTrue(centering.recenters(from: short, to: tall, isDragging: false))
  }
}
