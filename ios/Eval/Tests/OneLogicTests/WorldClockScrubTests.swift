import XCTest

@testable import TodayCore

/// The hand feel of the World Clock scrub as numbers: exact when slow, far when fast, and calendar-right when jumping.
final class WorldClockScrubTests: XCTestCase {
  private typealias S = WorldClock.Scrub
  private let la = TimeZone(identifier: "America/Los_Angeles")!

  private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

  private var laCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = la
    return c
  }

  /// A leftward swipe at constant speed, sampled at 120 Hz, released at that speed (or lifted at rest), run to rest.
  private func swipe(points: Double, seconds: Double, flick: Bool) -> S.Motion {
    var motion = S.Motion()
    motion.touchDown()
    let frames = max(1, Int(seconds * 120))
    for _ in 0..<frames {
      motion.drag(points: -points / Double(frames), speed: points / seconds)
    }
    motion.release(velocity: flick ? -points / seconds : 0)
    var t = 0.0
    while motion.isCoasting {
      t += 1.0 / 60
      motion.advance(elapsed: t)
    }
    return motion
  }

  // MARK: Gain

  func testSlowStaysOneToOne() {
    for speed in [0.0, 50, 100, S.fineSpeed] {
      XCTAssertEqual(S.minutesPerPoint(speed: speed), 0.1, accuracy: 1e-12, "at \(speed) pt/s")
    }
    var motion = S.Motion()
    for _ in 0..<10 { motion.drag(points: -10, speed: 80) }
    XCTAssertEqual(motion.offset, 10, "100 points slowly is 10 minutes, as before")
  }

  func testFastMultipliesAndIsMonotonic() {
    XCTAssertGreaterThan(S.minutesPerPoint(speed: 1000), 10 * S.minutesPerPoint(speed: 100))
    XCTAssertGreaterThan(S.minutesPerPoint(speed: 3000), S.minutesPerPoint(speed: 1000))
    var previous = 0.0
    for speed in stride(from: 0.0, through: 6000, by: 25) {
      let gain = S.minutesPerPoint(speed: speed)
      XCTAssertGreaterThanOrEqual(gain, previous, "at \(speed) pt/s")
      previous = gain
    }
    XCTAssertEqual(previous, S.maxMinutesPerPoint, "the gain has a ceiling")
  }

  // MARK: Targets

  func testGestureDistances() {
    XCTAssertEqual(swipe(points: 11, seconds: 0.2, flick: false).offset, 1, "one step is easy")
    XCTAssertEqual(swipe(points: 100, seconds: 1, flick: false).offset, 10)
    XCTAssertEqual(swipe(points: 280, seconds: 0.25, flick: true).offset, 750, "normal: 12.5 h")
    XCTAssertEqual(swipe(points: 300, seconds: 0.1, flick: true).offset, 2640, "fast: 44 h")
  }

  func testThreeFlicksCoverDays() {
    var motion = S.Motion()
    for _ in 0..<3 {
      motion.touchDown()
      for _ in 0..<12 { motion.drag(points: -25, speed: 3000) }
      motion.release(velocity: -3000)
      var t = 0.0
      while motion.isCoasting {
        t += 1.0 / 60
        motion.advance(elapsed: t)
      }
    }
    XCTAssertGreaterThan(motion.offset, 4 * 24 * 60)
    XCTAssertLessThan(motion.offset, 7 * 24 * 60)
  }

  // MARK: Inertia

  func testSlowReleaseDoesNotCoast() {
    var motion = S.Motion()
    motion.drag(points: -100, speed: 200)
    let there = motion.offset
    motion.release(velocity: -S.flickSpeed)
    XCTAssertFalse(motion.isCoasting)
    XCTAssertEqual(motion.offset, there)
  }

  func testCoastIsMonotonicAndSettlesOnAQuarterHour() throws {
    var motion = S.Motion(offset: 7)
    motion.release(velocity: -2000)
    let target = try XCTUnwrap(motion.coast).target
    var previous = motion.offset
    var t = 0.0
    while motion.isCoasting {
      t += 1.0 / 120
      motion.advance(elapsed: t)
      XCTAssertGreaterThanOrEqual(motion.offset, previous)
      previous = motion.offset
      XCTAssertLessThan(t, 5, "a coast ends")
    }
    XCTAssertEqual(motion.offset, target)
    XCTAssertEqual(motion.offset % S.coastStepMinutes, 0, "lands on a step")
    XCTAssertFalse(motion.isFast, "at rest the cards animate again")
  }

  func testCoastNeverLandsBehindTheRelease() throws {
    var motion = S.Motion(offset: 14)
    motion.release(velocity: -(S.flickSpeed + 1))
    XCTAssertGreaterThan(try XCTUnwrap(motion.coast).target, 14)
    var back = S.Motion(offset: -16)
    back.release(velocity: S.flickSpeed + 1)
    XCTAssertLessThan(try XCTUnwrap(back.coast).target, -16)
  }

  func testTouchDownStopsACoastWhereItIs() {
    var motion = S.Motion()
    motion.release(velocity: -2000)
    motion.advance(elapsed: 0.1)
    let there = motion.offset
    XCTAssertTrue(motion.isCoasting)
    motion.touchDown()
    XCTAssertFalse(motion.isCoasting)
    XCTAssertFalse(motion.isFast)
    motion.advance(elapsed: 1)
    XCTAssertEqual(motion.offset, there, "a stopped coast no longer moves")
  }

  func testCoastAndDragStopAtTheEndOfTheScale() throws {
    var motion = S.Motion(offset: S.limitMinutes - 10)
    motion.release(velocity: -3000)
    XCTAssertEqual(try XCTUnwrap(motion.coast).target, S.limitMinutes)
    var atEnd = S.Motion(offset: S.limitMinutes)
    atEnd.release(velocity: -3000)
    XCTAssertFalse(atEnd.isCoasting, "nowhere to go")
    atEnd.drag(points: -5000, speed: 3000)
    XCTAssertEqual(atEnd.offset, S.limitMinutes)
    atEnd.drag(points: 10, speed: 50)
    XCTAssertEqual(atEnd.offset, S.limitMinutes - 1, "turning back answers at once")
  }

  func testJumpEndsMotionAndStaysInRange() {
    var motion = S.Motion()
    motion.release(velocity: -2000)
    motion.jump(to: 0)
    XCTAssertFalse(motion.isCoasting)
    XCTAssertEqual(motion.offset, 0)
    motion.jump(to: S.limitMinutes * 2)
    XCTAssertEqual(motion.offset, S.limitMinutes)
  }

  // MARK: Picking a date

  func testPickingADayKeepsTheTimeOfDay() {
    let now = date("2026-11-09T16:45:00Z")  // 08:45 in Los Angeles
    let picked = date("2026-12-25T20:00:00Z")
    let offset = S.offset(picking: picked, shown: now, now: now, calendar: laCalendar)
    XCTAssertEqual(S.date(now: now, offset: offset), date("2026-12-25T16:45:00Z"))
  }

  func testPickingAcrossTheAutumnChangeKeepsTheClock() {
    let now = date("2026-10-31T17:30:00Z")  // 10:30 PDT, Saturday
    let sunday = S.offset(
      picking: date("2026-11-01T20:00:00Z"), shown: now, now: now, calendar: laCalendar)
    XCTAssertEqual(sunday, 25 * 60, "the 25-hour day, still 10:30 on the clock")
    XCTAssertEqual(S.date(now: now, offset: sunday), date("2026-11-01T18:30:00Z"))
  }

  func testPickingAcrossTheSpringChangeKeepsTheClock() {
    let now = date("2026-03-07T18:30:00Z")  // 10:30 PST, Saturday
    let sunday = S.offset(
      picking: date("2026-03-08T20:00:00Z"), shown: now, now: now, calendar: laCalendar)
    XCTAssertEqual(sunday, 23 * 60, "the 23-hour day")
  }

  func testPickingATimeTheDayDoesNotHaveMovesLater() {
    let now = date("2026-03-07T10:30:00Z")  // 02:30 PST, and the next day has no 02:30
    let offset = S.offset(
      picking: date("2026-03-08T20:00:00Z"), shown: now, now: now, calendar: laCalendar)
    let c = laCalendar.dateComponents(
      [.month, .day, .hour], from: S.date(now: now, offset: offset))
    XCTAssertEqual(c.month, 3)
    XCTAssertEqual(c.day, 8)
    XCTAssertEqual(c.hour, 3)
  }

  func testPickingARepeatedTimeTakesTheFirst() {
    let now = date("2026-10-31T08:30:00Z")  // 01:30 PDT
    let offset = S.offset(
      picking: date("2026-11-01T20:00:00Z"), shown: now, now: now, calendar: laCalendar)
    XCTAssertEqual(S.date(now: now, offset: offset), date("2026-11-01T08:30:00Z"))
  }

  func testEveryDayTheCalendarOffersIsReachable() {
    let now = date("2026-11-09T16:45:00Z")
    let range = S.pickableRange(now: now)
    for day in [range.lowerBound, range.upperBound] {
      let offset = S.offset(picking: day, shown: now, now: now, calendar: laCalendar)
      XCTAssertLessThan(abs(offset), S.limitMinutes, "not clamped at the end of the scale")
    }
  }

  // MARK: Long-range text

  func testPillNamesDaysAndYears() {
    XCTAssertEqual(S.pillText(23 * 60 + 59), "23 HOURS 59 MIN AFTER NOW")
    XCTAssertEqual(S.pillText(24 * 60), "1 DAY AFTER NOW")
    XCTAssertEqual(S.pillText(-(25 * 60)), "1 DAY 1 HOUR BEFORE NOW")
    XCTAssertEqual(S.pillText(3 * 24 * 60 + 4 * 60 + 15), "3 DAYS 4 HOURS AFTER NOW")
    XCTAssertEqual(S.pillText(20 * 24 * 60 + 7 * 60), "20 DAYS AFTER NOW")
    XCTAssertEqual(S.pillText(-(370 * 24 * 60)), "1 YEAR 5 DAYS BEFORE NOW")
    XCTAssertEqual(S.pillText(S.limitMinutes), "10 YEARS AFTER NOW")
  }

  // MARK: Cached texts

  func testCachedTextsMatchTheDirectOnes() {
    let texts = WorldClock.CardTexts()
    for id in ["en_US", "en_GB", "zh_CN", "de_DE"] {
      let locale = Locale(identifier: id)
      for iso in ["2026-11-09T16:45:00Z", "2026-11-10T07:59:00Z", "2026-03-08T10:30:00Z"] {
        let at = date(iso)
        for zone in [la, TimeZone(identifier: "Asia/Shanghai")!] {
          let direct = WorldClock.longDate(zone: zone, at: at, locale: locale)
          XCTAssertEqual(texts.longDate(zone: zone, at: at, locale: locale), direct)
          XCTAssertEqual(texts.longDate(zone: zone, at: at, locale: locale), direct, "cached")
          let hm = WorldClock.hourMinute(zone: zone, at: at)
          let a = texts.timeParts(hour: hm.hour, minute: hm.minute, locale: locale)
          let b = AlarmPlan.timeParts(hour: hm.hour, minute: hm.minute, locale: locale)
          XCTAssertEqual(a.time, b.time)
          XCTAssertEqual(a.suffix, b.suffix)
        }
      }
    }
  }

  func testHourMinuteMatchesTheCalendar() {
    let zones = ["America/Los_Angeles", "Asia/Kolkata", "Asia/Kathmandu", "Pacific/Apia", "UTC"]
    for id in zones {
      let zone = TimeZone(identifier: id)!
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = zone
      for step in stride(from: -40_000.0, through: 40_000, by: 3517) {
        let at = date("2026-03-08T10:00:00Z").addingTimeInterval(step)
        let c = calendar.dateComponents([.hour, .minute], from: at)
        let hm = WorldClock.hourMinute(zone: zone, at: at)
        XCTAssertEqual(hm.hour, c.hour, "\(id) at \(at)")
        XCTAssertEqual(hm.minute, c.minute, "\(id) at \(at)")
      }
    }
  }
}
