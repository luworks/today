import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class RowSubtitleTests: XCTestCase {
  func testDefaultListDetection() {
    XCTAssertTrue(RowSubtitle.isDefaultList(""))
    XCTAssertTrue(RowSubtitle.isDefaultList(" Reminders "))
    XCTAssertFalse(RowSubtitle.isDefaultList("Home"))
  }
}
