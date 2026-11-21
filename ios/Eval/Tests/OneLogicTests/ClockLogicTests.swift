import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class WorldClockTests: XCTestCase {
  private func tz(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

  /// 2026-10-17 12:00 UTC (no DST change nearby).
  private let noonUTC = Date(timeIntervalSince1970: 1_792_238_400)

  func testCityNames() {
    XCTAssertEqual(WorldClock.cityName(fromIdentifier: "America/New_York"), "New York")
    XCTAssertEqual(
      WorldClock.cityName(fromIdentifier: "America/Argentina/Buenos_Aires"), "Buenos Aires")
    XCTAssertEqual(WorldClock.cityName(fromIdentifier: "Europe/London"), "London")
    XCTAssertEqual(WorldClock.cityName(fromIdentifier: "Asia/Kolkata"), "Kolkata")
    XCTAssertNil(WorldClock.cityName(fromIdentifier: "UTC"))
    XCTAssertNil(WorldClock.cityName(fromIdentifier: "GMT"))
    XCTAssertNil(WorldClock.cityName(fromIdentifier: "Etc/GMT+5"))
    XCTAssertNil(WorldClock.cityName(fromIdentifier: "US/Pacific"))
  }

  func testHourMinuteInZone() {
    let (h, m) = WorldClock.hourMinute(zone: tz("Asia/Kolkata"), at: noonUTC)
    XCTAssertEqual(h, 17)
    XCTAssertEqual(m, 30)
  }

  func testSavedList() {
    var list = WorldClock.adding("Europe/London", to: [])
    list = WorldClock.adding("Asia/Tokyo", to: list)
    list = WorldClock.adding("Europe/London", to: list)
    XCTAssertEqual(list, ["Europe/London", "Asia/Tokyo"], "no duplicates")
    list = WorldClock.adding("America/New_York", to: list)
    XCTAssertEqual(
      WorldClock.moving(list, from: [2], to: 0),
      ["America/New_York", "Europe/London", "Asia/Tokyo"])
    XCTAssertEqual(
      WorldClock.moving(list, from: [0], to: 3),
      ["Asia/Tokyo", "America/New_York", "Europe/London"])
    XCTAssertEqual(
      WorldClock.moving(list, from: [0], to: 1), list, "moving onto itself changes nothing")
  }
}

final class OverlapTests: XCTestCase {
  private func tz(_ id: String) -> TimeZone { TimeZone(identifier: id)! }
  private let noonUTC = Date(timeIntervalSince1970: 1_792_238_400)  // 2026-10-17 12:00 UTC

  /// A slow drag from `start`, as one finger movement, in the old pointwise scale: 10 points per minute.
  private func slowDrag(start: Int, width: Double) -> Int {
    var motion = WorldClock.Scrub.Motion(offset: start)
    motion.drag(points: width, speed: 50)
    return motion.offset
  }

  func testSlowDragMovesByMinutesAndClamps() {
    typealias S = WorldClock.Scrub
    XCTAssertEqual(slowDrag(start: 0, width: 0), 0)
    XCTAssertEqual(slowDrag(start: 60, width: 0), 60, "no movement keeps the current offset")
    for width in [-9.0, 9.0] {
      XCTAssertEqual(slowDrag(start: 0, width: width), 0, "less than a step does nothing")
    }
    XCTAssertEqual(slowDrag(start: 0, width: 10), -1, "drag right = past")
    XCTAssertEqual(slowDrag(start: 0, width: -10), 1, "drag left = future")
    XCTAssertEqual(slowDrag(start: 0, width: 125), -12)
    XCTAssertEqual(slowDrag(start: 60, width: -20), 62, "advances from where the drag began")
    XCTAssertEqual(slowDrag(start: 60, width: 20), 58)
    XCTAssertEqual(slowDrag(start: S.limitMinutes, width: -100), S.limitMinutes, "the end holds")
    XCTAssertEqual(slowDrag(start: -S.limitMinutes, width: 100), -S.limitMinutes)
    XCTAssertEqual(slowDrag(start: S.limitMinutes, width: 10), S.limitMinutes - 1)
    XCTAssertEqual(slowDrag(start: -S.limitMinutes, width: -10), -S.limitMinutes + 1)
    let firstDrag = slowDrag(start: 0, width: -10)
    let secondDrag = slowDrag(start: firstDrag, width: -20)
    XCTAssertEqual(secondDrag, 3, "successive gestures accumulate minute offsets")
    XCTAssertEqual(slowDrag(start: secondDrag, width: 10), 2)
  }

  func testScrubbedDateKeepsTheMinutes() {
    let now = Date(timeIntervalSince1970: 1_792_238_400 + 50 * 60)  // 12:50:00 UTC
    XCTAssertEqual(WorldClock.Scrub.date(now: now, offset: 0), now, "not scrubbed: the real time")
    XCTAssertEqual(
      WorldClock.Scrub.date(now: now, offset: 15), now.addingTimeInterval(15 * 60), "13:05")
    XCTAssertEqual(
      WorldClock.Scrub.date(now: now, offset: -15 * 60), now.addingTimeInterval(-15 * 3600),
      "21:50 the day before: minutes stay")
  }

  func testScrubPill() {
    typealias S = WorldClock.Scrub
    XCTAssertEqual(S.pillText(0), "NOW")
    XCTAssertEqual(S.pillText(-15 * 60), "15 HOURS BEFORE NOW")
    XCTAssertEqual(S.pillText(180), "3 HOURS AFTER NOW")
    XCTAssertEqual(S.pillText(60), "1 HOUR AFTER NOW")
    XCTAssertEqual(S.pillText(1), "1 MIN AFTER NOW")
    XCTAssertEqual(S.pillText(-1), "1 MIN BEFORE NOW")
    XCTAssertEqual(S.pillText(61), "1 HOUR 1 MIN AFTER NOW")
    XCTAssertEqual(S.pillText(45), "45 MIN AFTER NOW")
    XCTAssertEqual(S.pillText(-75), "1 HOUR 15 MIN BEFORE NOW")
    XCTAssertEqual(S.pillParts(-60).lead, "1 HOUR BEFORE ")
    XCTAssertEqual(S.pillParts(-60).keyword, "NOW", "the keyword is shown bold")
    XCTAssertEqual(S.pillParts(0).lead, "")
  }

  func testNamesDatesAndHome() {
    XCTAssertEqual(WorldClock.nameList(["Dallas"]), "Dallas")
    XCTAssertEqual(WorldClock.nameList(["Dallas", "Boston"]), "Dallas and Boston")
    XCTAssertEqual(
      WorldClock.nameList(["Dallas", "Boston", "Austin"]), "Dallas, Boston and 1 more")
    XCTAssertEqual(
      WorldClock.offsetBadge(
        zone: tz("America/Chicago"), home: tz("America/Los_Angeles"), at: noonUTC), "+2")
    XCTAssertEqual(
      WorldClock.offsetBadge(
        zone: tz("Asia/Shanghai"), home: tz("America/Los_Angeles"), at: noonUTC), "+15")
    XCTAssertEqual(
      WorldClock.offsetBadge(zone: tz("Asia/Kolkata"), home: tz("Europe/London"), at: noonUTC),
      "+4:30")
    XCTAssertEqual(
      WorldClock.offsetBadge(zone: tz("America/Los_Angeles"), home: tz("Asia/Tokyo"), at: noonUTC),
      "-16")
    XCTAssertEqual(
      WorldClock.offsetBadge(zone: tz("America/St_Johns"), home: tz("UTC"), at: noonUTC), "-2:30")
    XCTAssertEqual(
      WorldClock.offsetBadge(zone: tz("Asia/Tokyo"), home: tz("Asia/Tokyo"), at: noonUTC), "+0")
    XCTAssertEqual(
      WorldClock.longDate(
        zone: tz("Asia/Shanghai"), at: Date(timeIntervalSince1970: 1_792_292_400),
        locale: Locale(identifier: "en_US")),
      "SUNDAY, OCTOBER 18", "next day over there (LA Saturday evening)")
    XCTAssertEqual(
      WorldClock.longDate(
        zone: tz("America/Los_Angeles"), at: Date(timeIntervalSince1970: 1_792_292_400),
        locale: Locale(identifier: "en_US")),
      "SATURDAY, OCTOBER 17")
    XCTAssertEqual(
      WorldClock.dateText(
        zone: tz("Asia/Tokyo"), at: Date(timeIntervalSince1970: 1_792_292_400),
        locale: Locale(identifier: "en_US")),
      "Sun, Oct 18")
    XCTAssertEqual(
      WorldClock.others(["Europe/London", "America/Los_Angeles"], home: "America/Los_Angeles"),
      ["Europe/London"])
  }
}

final class StopwatchTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_000_000)

  func testStartStopAccumulates() {
    var s = StopwatchState()
    XCTAssertFalse(s.hasTime)
    s.start(at: t0)
    XCTAssertTrue(s.isRunning)
    XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(5)), 5, accuracy: 0.0001)
    s.stop(at: t0.addingTimeInterval(5))
    XCTAssertFalse(s.isRunning)
    XCTAssertTrue(s.hasTime, "stopped with time: the left button reads Reset")
    XCTAssertEqual(
      s.elapsed(at: t0.addingTimeInterval(100)), 5, accuracy: 0.0001, "no time passes while stopped"
    )
    s.start(at: t0.addingTimeInterval(100))
    XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(102.5)), 7.5, accuracy: 0.0001)
    s.start(at: t0.addingTimeInterval(200))  // ignored while running
    XCTAssertEqual(s.elapsed(at: t0.addingTimeInterval(102.5)), 7.5, accuracy: 0.0001)
  }

  func testLapsAndCurrentLap() {
    var s = StopwatchState()
    s.lap(at: t0)
    XCTAssertTrue(s.laps.isEmpty, "Lap does nothing while stopped")
    s.start(at: t0)
    s.lap(at: t0.addingTimeInterval(3))
    s.lap(at: t0.addingTimeInterval(10))
    XCTAssertEqual(s.laps, [3, 7])
    XCTAssertEqual(s.currentLap(at: t0.addingTimeInterval(12)), 2, accuracy: 0.0001)
    s.stop(at: t0.addingTimeInterval(12))
    XCTAssertEqual(s.currentLap(at: t0.addingTimeInterval(50)), 2, accuracy: 0.0001)
    s.reset()
    XCTAssertEqual(s, StopwatchState())
  }

  func testBestAndWorstNeedTwoDifferentLaps() {
    var s = StopwatchState()
    XCTAssertNil(s.bestLapIndex)
    s.laps = [4]
    XCTAssertNil(s.bestLapIndex, "one lap: nothing to compare")
    XCTAssertNil(s.worstLapIndex)
    s.laps = [4, 4]
    XCTAssertNil(s.bestLapIndex, "equal laps are neither best nor worst")
    s.laps = [4, 2.5, 9, 3]
    XCTAssertEqual(s.bestLapIndex, 1)
    XCTAssertEqual(s.worstLapIndex, 2)
  }

  func testFormat() {
    XCTAssertEqual(StopwatchState.format(0), "00:00.00")
    XCTAssertEqual(StopwatchState.format(1.239), "00:01.23", "truncates, never rounds up")
    XCTAssertEqual(StopwatchState.format(65.5), "01:05.50")
    XCTAssertEqual(StopwatchState.format(3599.999), "59:59.99")
    XCTAssertEqual(StopwatchState.format(3723.45), "1:02:03.45")
    XCTAssertEqual(StopwatchState.format(-3), "00:00.00")
    XCTAssertEqual(
      StopwatchState.format(5.75 + 4.2 + 6.5 + 5.1 - (4.2 + 6.5 + 5.1)), "00:05.75",
      "float noise must not drop a hundredth")
  }

  func testPersistenceKeepsRunningAcrossRelaunch() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "StopwatchTests-\(UUID())"))
    var s = StopwatchState()
    s.start(at: t0)
    s.lap(at: t0.addingTimeInterval(4))
    s.save(to: defaults)
    // "Relaunch": a fresh load an hour later still counts from the saved start date.
    let loaded = StopwatchState.load(from: defaults)
    XCTAssertEqual(loaded, s)
    XCTAssertTrue(loaded.isRunning)
    XCTAssertEqual(loaded.elapsed(at: t0.addingTimeInterval(3600)), 3600, accuracy: 0.0001)
    XCTAssertEqual(loaded.laps, [4])
    // Reset clears the saved state.
    var cleared = loaded
    cleared.reset()
    cleared.save(to: defaults)
    XCTAssertNil(defaults.data(forKey: StopwatchState.defaultsKey))
    XCTAssertEqual(StopwatchState.load(from: defaults), StopwatchState())
  }

  func testCorruptSavedDataStartsClean() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "StopwatchTests-\(UUID())"))
    defaults.set(Data("not json".utf8), forKey: StopwatchState.defaultsKey)
    XCTAssertEqual(StopwatchState.load(from: defaults), StopwatchState())
  }

  func testPausedRelaunchPreservesUnfinishedLapAndResumesWithoutCountingPause() throws {
    let suite = "StopwatchPaused-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var state = StopwatchState()
    state.start(at: t0)
    state.lap(at: t0.addingTimeInterval(3))
    state.stop(at: t0.addingTimeInterval(5))
    state.save(to: defaults)

    var loaded = StopwatchState.load(from: defaults)
    let resumedAt = t0.addingTimeInterval(3600)
    XCTAssertFalse(loaded.isRunning)
    XCTAssertEqual(loaded.elapsed(at: resumedAt), 5)
    XCTAssertEqual(loaded.currentLap(at: resumedAt), 2)
    loaded.start(at: resumedAt)
    loaded.lap(at: resumedAt.addingTimeInterval(4))
    XCTAssertEqual(loaded.laps, [3, 6])
    XCTAssertEqual(loaded.bestLapIndex, 0)
    XCTAssertEqual(loaded.worstLapIndex, 1)
    XCTAssertEqual(loaded.elapsed(at: resumedAt.addingTimeInterval(4)), 9)
  }
}
