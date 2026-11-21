import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// The length limits and `RunningTimer` (pause, resume, storage). The kitchen-timer dial was replaced by Apple's wheel picker.
final class TimerDialTests: XCTestCase {
  func testRunningTimerPauseAndResume() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let id = UUID()
    var timer = RunningTimer.start(id: id, seconds: 300, now: t0)
    XCTAssertEqual(timer.remaining(now: t0.addingTimeInterval(60)), 240)
    timer = timer.paused(now: t0.addingTimeInterval(100))
    XCTAssertTrue(timer.isPaused)
    XCTAssertEqual(
      timer.remaining(now: t0.addingTimeInterval(1000)), 200, "paused time does not run")
    timer = timer.resumed(now: t0.addingTimeInterval(1000))
    XCTAssertFalse(timer.isPaused)
    XCTAssertEqual(timer.endsAt, t0.addingTimeInterval(1200))
    XCTAssertEqual(timer.remaining(now: t0.addingTimeInterval(5000)), 0, "never negative")
  }
}
