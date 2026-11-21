import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// The remembered tab survives the Alarms → Clock rename.
final class TabMemoryLogicTests: XCTestCase {
  func testTheOldAlarmsValueOpensTheClockTab() {
    XCTAssertEqual(TabMemory.migrated("alarms"), "clock")
  }
}
