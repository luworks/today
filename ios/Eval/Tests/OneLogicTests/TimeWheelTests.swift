import XCTest

@testable import TodayCore

/// The custom time wheel of the alarm wheel lab (variants B and C), driven by synthetic touch sequences at real
/// timestamps. What these cannot show is how the wheel feels under a finger: that needs an iPhone.
final class TimeWheelTests: XCTestCase {
  /// A finger on one column: events at `rate` per second, a display frame (`step`) before each event.
  private struct Finger {
    var wheel: TimeWheelColumn
    var time = 100.0
    var y = 400.0
    var outputs: [TimeWheelOutput] = []

    init(_ wheel: TimeWheelColumn) { self.wheel = wheel }

    var ticks: Int { outputs.filter { $0.contains(.tick) }.count }
    var reversals: Int { outputs.filter { $0.contains(.reversal) }.count }

    mutating func down(after gap: Double = 0) {
      frames(gap)
      outputs.append(wheel.touchDown(y: y, at: time))
    }

    /// Moves `dy` points (negative = up = later values) evenly over `duration`.
    mutating func move(_ dy: Double, over duration: Double, rate: Double = 120) {
      let n = max(Int((duration * rate).rounded()), 1)
      for _ in 0..<n {
        time += 1 / rate
        y += dy / Double(n)
        outputs.append(wheel.step(at: time))
        outputs.append(wheel.touchMove(y: y, at: time))
      }
    }

    /// Display frames with no touch events (a finger held still, or no finger).
    mutating func frames(_ duration: Double) {
      let n = Int((duration * 120).rounded())
      for _ in 0..<n {
        time += 1.0 / 120
        outputs.append(wheel.step(at: time))
      }
    }

    mutating func up(after gap: Double = 1.0 / 120) {
      time += gap
      outputs.append(wheel.touchUp(y: y, at: time))
    }

    /// Runs frames until the wheel rests (at most 5 s).
    mutating func settle() {
      var guardFrames = 600
      while wheel.isMoving && guardFrames > 0 {
        frames(1.0 / 120)
        guardFrames -= 1
      }
    }
  }

  private func minutes(_ value: Int, adaptive: Bool) -> Finger {
    Finger(TimeWheelColumn(count: 60, value: value, adaptive: adaptive))
  }

  private var row: Double { TimeWheelTuning.standard.finePointsPerUnit }

  // MARK: Near and exact

  func testOneRowSlowlyMovesOneMinute() {
    for adaptive in [false, true] {
      var f = minutes(30, adaptive: adaptive)
      f.down()
      f.move(-row, over: 0.3)
      f.up()
      f.settle()
      XCTAssertEqual(f.wheel.value, 31, "07:30 → 07:31 (adaptive \(adaptive))")
      XCTAssertEqual(f.wheel.position, 31, accuracy: 1e-9)
      XCTAssertEqual(f.ticks, 1, "one tick for one minute crossed")
    }
  }

  func testThreeRowsBackSlowly() {
    for adaptive in [false, true] {
      var f = minutes(32, adaptive: adaptive)
      f.down()
      f.move(3 * row, over: 0.7)
      f.up()
      f.settle()
      XCTAssertEqual(f.wheel.value, 29, "07:32 → 07:29 (adaptive \(adaptive))")
      XCTAssertEqual(f.ticks, 3)
    }
  }

  /// A slow release snaps to the nearest minute, never to a multiple of five: 17, 32 and 47 are all reachable.
  func testSlowReleaseLandsOnTheNearestMinuteNotAMultipleOfFive() {
    for (start, rows, expected) in [(0, 17.3, 17), (50, -17.8, 32), (10, 37.4, 47)] {
      var f = minutes(start, adaptive: true)
      f.down()
      f.move(-rows * row, over: rows.magnitude * 0.25)
      XCTAssertEqual(f.wheel.scale, 0, accuracy: 0.01, "slow drags stay at fine spacing")
      f.up()
      f.settle()
      XCTAssertEqual(f.wheel.value, expected)
    }
  }

  // MARK: Far

  func testFlickCoastsForwardAndRestsOnAWholeMinute() {
    for adaptive in [false, true] {
      var f = minutes(10, adaptive: adaptive)
      f.down()
      f.move(-200, over: 0.1)
      f.up()
      XCTAssertEqual(f.wheel.phase, .settling, "a quick release coasts")
      let resting = f.wheel.restingValue
      f.settle()
      XCTAssertEqual(f.wheel.value, resting, "it rests where it said it would")
      XCTAssertEqual(f.wheel.position, Double(f.wheel.rounded), accuracy: 1e-9)
      XCTAssertGreaterThan(f.wheel.rounded - 10, 15, "a flick goes a long way")
    }
  }

  /// The same finger travel covers more minutes in C, because only C compresses at speed.
  func testSpeedCompressionCoversMoreMinutesForTheSameTravel() {
    var b = minutes(0, adaptive: false)
    var c = minutes(0, adaptive: true)
    for i in [0, 1] {
      var f = i == 0 ? b : c
      f.down()
      f.move(-300, over: 0.15)
      if i == 0 { b = f } else { c = f }
    }
    XCTAssertGreaterThan(c.wheel.scale, 0.3, "fast drags compress the minute spacing in C")
    XCTAssertEqual(b.wheel.scale, 0, "B never compresses")
    XCTAssertGreaterThan(c.wheel.position, b.wheel.position + 1)
  }

  func testFastThenSlowStillReachesAnExactMinuteInC() {
    var f = minutes(10, adaptive: true)
    f.down()
    f.move(-300, over: 0.15)
    f.frames(1.2)  // finger held still: the spacing opens around the selection
    XCTAssertLessThan(f.wheel.scale, 0.01)
    let need = 47 - f.wheel.position
    f.move(-need * f.wheel.pointsPerUnit, over: need.magnitude * 0.25)
    f.up()
    f.settle()
    XCTAssertEqual(f.wheel.value, 47, "07:10 → 07:47 with one fast and one fine stroke")
  }

  // MARK: Scale never moves the value

  func testSpacingChangeNeverChangesTheValueOrTicks() {
    var f = minutes(31, adaptive: true)
    f.down()
    f.move(-300, over: 0.15)
    let highScale = f.wheel.scale
    XCTAssertGreaterThan(highScale, 0.3)
    let value = f.wheel.value
    let position = f.wheel.position
    let ticksBefore = f.ticks
    var values = Set<Int>()
    for _ in 0..<120 {
      f.frames(1.0 / 120)
      values.insert(f.wheel.value)
      XCTAssertEqual(f.wheel.position, position, "the spacing is drawn around the position")
    }
    XCTAssertLessThan(f.wheel.scale, 0.05, "holding still opens the spacing again")
    XCTAssertEqual(values, [value], "07:31 stays 07:31 while the spacing changes")
    XCTAssertEqual(f.ticks, ticksBefore, "a pure spacing change plays no tick")
  }

  // MARK: Reversal

  func testReversalClearsSpeedAndGoesFine() {
    var f = minutes(20, adaptive: true)
    f.down()
    f.move(-300, over: 0.15)
    XCTAssertGreaterThan(f.wheel.scale, 0.3)
    f.move(12, over: 0.05)
    XCTAssertEqual(f.reversals, 1)
    XCTAssertLessThan(f.wheel.scale, 0.05, "turning back restores fine spacing at once")
    XCTAssertLessThan(f.wheel.speed, TimeWheelTuning.standard.coarseFrom)
  }

  func testTremorIsNotAReversal() {
    var f = minutes(20, adaptive: true)
    f.down()
    f.move(-60, over: 0.3)
    for _ in 0..<10 {
      f.move(2, over: 1.0 / 60)
      f.move(-2, over: 1.0 / 60)
    }
    XCTAssertEqual(f.reversals, 0, "2 pt of shake is not a turn back")
  }

  /// Already at 07:35, back to 07:32.
  func testOvershootRecovery() {
    for adaptive in [false, true] {
      var f = minutes(30, adaptive: adaptive)
      f.down()
      f.move(-5 * row, over: 0.5)
      XCTAssertEqual(f.wheel.value, 35)
      f.move(3 * row, over: 0.5)
      f.up()
      f.settle()
      XCTAssertEqual(f.wheel.value, 32)
      XCTAssertEqual(f.reversals, 1)
    }
  }

  // MARK: Grab and pause

  func testTouchStopsACoastWhereItIsAndStaysFine() {
    var f = minutes(0, adaptive: true)
    f.down()
    f.move(-200, over: 0.1)
    f.up()
    f.frames(0.1)
    XCTAssertEqual(f.wheel.phase, .settling)
    // Touch between two frames: the wheel stops where the coast is at that instant.
    var expected = f.wheel
    _ = expected.step(at: f.time + 0.004)
    f.time += 0.004
    f.outputs.append(f.wheel.touchDown(y: f.y, at: f.time))
    XCTAssertTrue(f.outputs.last?.contains(.grab) ?? false)
    XCTAssertEqual(f.wheel.position, expected.position, accuracy: 1e-9)
    XCTAssertEqual(f.wheel.phase, .dragging)
    XCTAssertEqual(f.wheel.scale, 0, "the grabbing gesture is fine")
    // Even a fast stroke during the grabbing gesture stays fine, so it cannot overshoot again.
    f.move(-80, over: 0.04)
    XCTAssertEqual(f.wheel.scale, 0)
    XCTAssertEqual(f.wheel.pointsPerUnit, row)
  }

  func testGrabThenFineCorrectionLandsWithoutCoasting() {
    var f = minutes(0, adaptive: true)
    f.down()
    f.move(-200, over: 0.1)
    f.up()
    f.frames(0.1)
    f.down()
    let grabbedAt = f.wheel.position
    f.move(-2 * row, over: 0.5)
    f.up()
    let expected = Int((grabbedAt + 2.5).rounded(.down))
    XCTAssertEqual(f.wheel.restingValue, TimeWheelColumn.wrap(expected, 60))
    f.settle()
    XCTAssertEqual(Double(f.wheel.rounded), (grabbedAt + 2 + 0.5).rounded(.down))
  }

  /// The regression trace: fast drag → finger held still about 700 ms → about 2 px more the same way → lift at once.
  /// The wheel lands by that last small move and does not regain the old speed.
  func testHoldAfterFastDragThenTinyMoveDoesNotFling() {
    for adaptive in [false, true] {
      for jitter in [false, true] {
        var f = minutes(10, adaptive: adaptive)
        f.down()
        f.move(-300, over: 0.15)
        if jitter {
          // Some screens report sub-point drift while a finger rests.
          for i in 0..<42 { f.move(i.isMultiple(of: 2) ? 0.3 : -0.3, over: 1.0 / 60, rate: 60) }
        } else {
          f.frames(0.7)
        }
        f.move(-2, over: 1.0 / 120)
        let released = f.wheel.position
        f.up()
        f.settle()
        let label = "adaptive \(adaptive), jitter \(jitter)"
        XCTAssertEqual(f.wheel.rounded, Int((released + 0.5).rounded(.down)), label)
        XCTAssertLessThanOrEqual(abs(f.wheel.position - released), 0.5, label)
      }
    }
  }

  func testNudgeAfterRestDoesNotInheritOldInertia() {
    var f = minutes(10, adaptive: true)
    f.down()
    f.move(-200, over: 0.1)
    f.up()
    f.settle()
    let rest = f.wheel.position
    f.down(after: 0.2)
    f.move(-3, over: 1.0 / 60)
    f.up()
    f.settle()
    XCTAssertEqual(f.wheel.position, rest, accuracy: 1e-9, "3 pt is less than half a row")
  }

  // MARK: Interruption

  func testCancelSnapsWithoutDrift() {
    var f = minutes(10, adaptive: true)
    f.down()
    f.move(-200, over: 0.1)
    let at = f.wheel.position
    f.time += 1.0 / 120
    f.outputs.append(f.wheel.touchCancel(at: f.time))
    f.settle()
    XCTAssertEqual(f.wheel.rounded, Int((at + 0.5).rounded(.down)))
    XCTAssertLessThanOrEqual(abs(f.wheel.position - at), 0.5)
  }

  func testStopEndsACoastOnTheShownValue() {
    var f = minutes(10, adaptive: true)
    f.down()
    f.move(-200, over: 0.1)
    f.up()
    f.frames(0.05)
    let shown = f.wheel.value
    f.wheel.stop()
    XCTAssertEqual(f.wheel.phase, .idle)
    XCTAssertEqual(f.wheel.value, shown, "what was shown is what stays")
    XCTAssertEqual(f.wheel.scale, 0)
    let position = f.wheel.position
    f.frames(0.5)
    XCTAssertEqual(f.wheel.position, position, "no drift after stop")
    XCTAssertEqual(f.wheel.touchUp(y: 0, at: f.time), [], "a late lift is ignored")
  }

  func testSetAndNudgeStopAndNeverTick() {
    var wheel = TimeWheelColumn(count: 60, value: 5, adaptive: true)
    _ = wheel.touchDown(y: 0, at: 0)
    _ = wheel.touchMove(y: -100, at: 0.05)
    wheel.set(value: 47)
    XCTAssertEqual(wheel.value, 47)
    XCTAssertEqual(wheel.phase, .idle)
    wheel.nudge(by: 13)
    XCTAssertEqual(wheel.value, 0, "VoiceOver increments wrap like the wheel")
    wheel.nudge(by: -1)
    XCTAssertEqual(wheel.value, 59)
  }

  // MARK: Boundaries

  func testMinuteAndHourWrap() {
    var f = minutes(59, adaptive: false)
    f.down()
    f.move(-row, over: 0.3)
    f.up()
    f.settle()
    XCTAssertEqual(f.wheel.value, 0, "59 → 00")
    f.down(after: 0.1)
    f.move(row, over: 0.3)
    f.up()
    f.settle()
    XCTAssertEqual(f.wheel.value, 59, "00 → 59")

    var h = Finger(TimeWheelColumn(count: 24, value: 23))
    h.down()
    h.move(-row, over: 0.3)
    h.up()
    h.settle()
    XCTAssertEqual(h.wheel.value, 0, "11 PM → 12 AM")
    h.wheel.set(value: 11)
    h.down(after: 0.1)
    h.move(-row, over: 0.3)
    h.up()
    h.settle()
    XCTAssertEqual(h.wheel.value, 12, "11 AM → 12 PM: the hour column carries AM/PM")
  }

  /// The alarm editor's five-minute column: 12 rows (00, 05 … 55), one slow row is one step, and it wraps.
  func testFiveMinuteColumnStepsOneRowAndWraps() {
    let rows = 60 / AlarmPlan.wheelMinuteStep
    XCTAssertEqual(rows, 12)
    var f = Finger(TimeWheelColumn(count: rows, value: 6))
    f.down()
    f.move(-row, over: 0.3)
    f.up()
    f.settle()
    XCTAssertEqual(f.wheel.value * AlarmPlan.wheelMinuteStep, 35, "30 → 35")
    f.wheel.set(value: rows - 1)
    f.down(after: 0.1)
    f.move(-row, over: 0.3)
    f.up()
    f.settle()
    XCTAssertEqual(f.wheel.value, 0, "55 → 00")
  }

  func testFixedColumnNeverCompresses() {
    var h = Finger(TimeWheelColumn(count: 24, value: 7, adaptive: false))
    h.down()
    h.move(-400, over: 0.1)
    XCTAssertEqual(h.wheel.scale, 0)
    XCTAssertEqual(h.wheel.pointsPerUnit, TimeWheelTuning.standard.finePointsPerUnit)
  }

  // MARK: Velocity and haptics

  func testReleaseVelocityUsesRealTimeNotFrameCount() {
    var slowRate = minutes(0, adaptive: false)
    var fastRate = minutes(0, adaptive: false)
    slowRate.down()
    slowRate.move(-200, over: 0.1, rate: 60)
    slowRate.up(after: 1.0 / 60)
    fastRate.down()
    fastRate.move(-200, over: 0.1, rate: 120)
    fastRate.up(after: 1.0 / 120)
    XCTAssertEqual(slowRate.wheel.restingValue, fastRate.wheel.restingValue)
  }

  func testTicksAreMergedAtSpeed() {
    var f = minutes(0, adaptive: false)
    f.down()
    f.move(-3000, over: 1.0)
    let crossed = Int(3000 / row)
    XCTAssertLessThan(f.ticks, crossed / 3, "fast crossings are merged, not queued")
    let gate = 1 / TimeWheelTuning.standard.minTickInterval + 1
    XCTAssertLessThanOrEqual(Double(f.ticks), gate, "never denser than the gate")
    XCTAssertGreaterThan(f.ticks, 0)
  }

  func testNumbersThinOutWhenCompressedWithHysteresis() {
    XCTAssertEqual(TimeWheelColumn.labelStep(current: 1, pointsPerUnit: 34, gap: 28), 1)
    XCTAssertEqual(TimeWheelColumn.labelStep(current: 1, pointsPerUnit: 7, gap: 28), 5)
    XCTAssertEqual(TimeWheelColumn.labelStep(current: 1, pointsPerUnit: 1.5, gap: 28), 15)
    XCTAssertEqual(
      TimeWheelColumn.labelStep(current: 5, pointsPerUnit: 29, gap: 28), 5,
      "just above the threshold the coarser step holds")
    XCTAssertEqual(TimeWheelColumn.labelStep(current: 5, pointsPerUnit: 33, gap: 28), 1)
  }

  func testValueShownConfirmedAndSpokenAgree() {
    var f = minutes(58, adaptive: true)
    f.down()
    f.move(-250, over: 0.12)
    f.up()
    f.frames(0.08)
    XCTAssertEqual(f.wheel.value, TimeWheelColumn.wrap(f.wheel.rounded, 60))
    f.settle()
    XCTAssertEqual(f.wheel.value, f.wheel.restingValue)
    XCTAssertTrue((0..<60).contains(f.wheel.value))
  }
}
