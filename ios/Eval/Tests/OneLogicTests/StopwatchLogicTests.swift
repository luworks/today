import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// The stopwatch face's geometry and wording (no UI). The face is measured from Apple's Clock app: 240 ticks on the
/// ring (four a second), white every 5 s, a 30-minute counter with 60 ticks and white every 5 minutes.
final class StopwatchLogicTests: XCTestCase {
  // MARK: Ring

  func testTickKinds() {
    let kinds = (0..<StopwatchDial.tickCount).map(StopwatchDial.tick(at:))
    XCTAssertEqual(kinds.filter { $0 == .major }.count, 12, "white at 5, 10 … 60")
    XCTAssertEqual(kinds.filter { $0 == .second }.count, 48, "the other whole seconds")
    XCTAssertEqual(kinds.filter { $0 == .quarter }.count, 180)
    XCTAssertEqual(Array(kinds[0..<5]), [.major, .quarter, .quarter, .quarter, .second])
    XCTAssertEqual(StopwatchDial.tick(at: 20), .major, "5 seconds")
    XCTAssertEqual(StopwatchDial.tick(at: 60), .major, "15 seconds, at 3 o'clock")
    XCTAssertEqual(StopwatchDial.angle(ofTick: 60), 90, accuracy: 1e-9)
  }

  // MARK: Hands

  func testSecondsHandTurnsOnceAMinuteSmoothly() {
    XCTAssertEqual(StopwatchDial.secondsHandAngle(elapsed: 0), 0)
    XCTAssertEqual(
      StopwatchDial.secondsHandAngle(elapsed: 5.75), 34.5, accuracy: 1e-9, "the reference shot")
    XCTAssertEqual(StopwatchDial.secondsHandAngle(elapsed: 15), 90, accuracy: 1e-9)
    XCTAssertEqual(
      StopwatchDial.secondsHandAngle(elapsed: 30.5), 183, accuracy: 1e-9,
      "between ticks, not snapped")
    XCTAssertEqual(StopwatchDial.secondsHandAngle(elapsed: 60), 0, accuracy: 1e-9)
    XCTAssertEqual(
      StopwatchDial.secondsHandAngle(elapsed: 3730), 60, accuracy: 1e-9, "wraps every minute")
    XCTAssertEqual(StopwatchDial.secondsHandAngle(elapsed: -4), 0, "never negative")
  }

  func testMinutesHandTurnsOnceInThirtyMinutes() {
    XCTAssertEqual(StopwatchDial.minutesHandAngle(elapsed: 0), 0)
    XCTAssertEqual(StopwatchDial.minutesHandAngle(elapsed: 5.75), 5.75 / 1800 * 360, accuracy: 1e-9)
    XCTAssertEqual(
      StopwatchDial.minutesHandAngle(elapsed: 5 * 60), 60, accuracy: 1e-9, "5 minutes is at the 5")
    XCTAssertEqual(StopwatchDial.minutesHandAngle(elapsed: 15 * 60), 180, accuracy: 1e-9)
    XCTAssertEqual(StopwatchDial.minutesHandAngle(elapsed: 30 * 60), 0, accuracy: 1e-9)
    XCTAssertEqual(StopwatchDial.minutesHandAngle(elapsed: 35 * 60), 60, accuracy: 1e-9)
  }

  // MARK: Laps

  func testFastestAndSlowestMarks() {
    var s = StopwatchState()
    s.laps = [5.75]
    XCTAssertNil(s.mark(forLap: 0), "one lap: nothing to compare")
    s.laps = [5.75, 5.75]
    XCTAssertNil(s.mark(forLap: 0), "equal laps are neither")
    s.laps = [5.75, 3.2, 8.9, 4.1]
    XCTAssertEqual(s.mark(forLap: 1), .fastest)
    XCTAssertEqual(s.mark(forLap: 2), .slowest)
    XCTAssertNil(s.mark(forLap: 0))
    XCTAssertNil(s.mark(forLap: 3))
  }

  // MARK: Wording

  func testDigitalUsesTheLanguagesDecimalMark() {
    XCTAssertEqual(StopwatchState.digital(5.75, decimalSeparator: ","), "00:05,75")
    XCTAssertEqual(StopwatchState.digital(3723.45, decimalSeparator: ","), "1:02:03,45")
    XCTAssertEqual(StopwatchState.digital(0, decimalSeparator: ","), "00:00,00")
  }

  func testSpokenTimeWhenStopped() {
    XCTAssertEqual(StopwatchState.spoken(0, running: false), "Stopwatch, 0 seconds")
    XCTAssertEqual(StopwatchState.spoken(5.75, running: false), "Stopwatch, 5.75 seconds")
    XCTAssertEqual(StopwatchState.spoken(1, running: false), "Stopwatch, 1 second")
    XCTAssertEqual(StopwatchState.spoken(5.5, running: false), "Stopwatch, 5.5 seconds")
    XCTAssertEqual(StopwatchState.spoken(5.05, running: false), "Stopwatch, 5.05 seconds")
    XCTAssertEqual(StopwatchState.spoken(60, running: false), "Stopwatch, 1 minute")
    XCTAssertEqual(StopwatchState.spoken(125.5, running: false), "Stopwatch, 2 minutes 5.5 seconds")
    XCTAssertEqual(
      StopwatchState.spoken(3723.45, running: false), "Stopwatch, 1 hour 2 minutes 3.45 seconds")
  }

  func testSpokenTimeWhileRunningChangesOnlyOnceASecond() {
    XCTAssertEqual(StopwatchState.spoken(5.75, running: true), "Stopwatch, 5 seconds, running")
    XCTAssertEqual(
      StopwatchState.spoken(5.99, running: true), StopwatchState.spoken(5.01, running: true))
    XCTAssertEqual(StopwatchState.spoken(0.4, running: true), "Stopwatch, 0 seconds, running")
    XCTAssertEqual(
      StopwatchState.spoken(61.9, running: true), "Stopwatch, 1 minute 1 second, running")
  }

  func testSpokenLap() {
    XCTAssertEqual(StopwatchState.spokenLap(number: 1, time: 5.75, mark: nil), "Lap 1, 00:05.75")
    XCTAssertEqual(
      StopwatchState.spokenLap(number: 2, time: 3.2, mark: .fastest), "Lap 2, 00:03.20, fastest")
    XCTAssertEqual(
      StopwatchState.spokenLap(number: 3, time: 8.9, mark: .slowest), "Lap 3, 00:08.90, slowest")
  }
}
