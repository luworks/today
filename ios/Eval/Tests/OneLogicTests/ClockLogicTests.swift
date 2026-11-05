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

  func testOffsets() {
    let la = tz("America/Los_Angeles")
    XCTAssertEqual(
      WorldClock.offsetText(zone: tz("America/New_York"), local: la, at: noonUTC), "+3 hrs")
    XCTAssertEqual(WorldClock.offsetText(zone: la, local: la, at: noonUTC), "+0 hrs")
    XCTAssertEqual(
      WorldClock.offsetText(zone: tz("America/Denver"), local: la, at: noonUTC), "+1 hr")
    XCTAssertEqual(
      WorldClock.offsetText(zone: la, local: tz("America/New_York"), at: noonUTC), "-3 hrs")
    XCTAssertEqual(
      WorldClock.offsetText(zone: tz("Asia/Kolkata"), local: tz("Europe/London"), at: noonUTC),
      "+4:30 hrs", "London is on BST in October")
    XCTAssertEqual(
      WorldClock.offsetText(zone: tz("Asia/Kathmandu"), local: tz("UTC"), at: noonUTC), "+5:45 hrs")
    XCTAssertEqual(
      WorldClock.offsetText(zone: tz("America/St_Johns"), local: tz("UTC"), at: noonUTC),
      "-2:30 hrs", "Newfoundland daylight time")
  }

  func testOffsetFollowsDaylightSavingAtThatMoment() {
    // 2026-01-15 12:00 UTC: London on GMT, so New York is -5.
    let january = Date(timeIntervalSince1970: 1_768_478_400)
    XCTAssertEqual(
      WorldClock.offsetText(zone: tz("America/New_York"), local: tz("Europe/London"), at: january),
      "-5 hrs")
    XCTAssertEqual(
      WorldClock.offsetText(zone: tz("America/New_York"), local: tz("Europe/London"), at: noonUTC),
      "-5 hrs")
    // Between Europe's and America's switch (2026-03-20 12:00 UTC): the US moved on Mar 8, Europe moves on Mar 29.
    let march = Date(timeIntervalSince1970: 1_774_008_000)
    XCTAssertEqual(
      WorldClock.offsetText(zone: tz("America/New_York"), local: tz("Europe/London"), at: march),
      "-4 hrs")
  }

  func testDayLabelsAcrossTheDateLine() {
    // 2026-10-17 20:00 in Los Angeles = 23:00 in New York (same day), 12:00 next day in Tokyo.
    let evening = Date(timeIntervalSince1970: 1_792_292_400)
    let la = tz("America/Los_Angeles")
    XCTAssertEqual(
      WorldClock.subtitle(zone: tz("America/New_York"), local: la, at: evening), "Today, +3 hrs")
    XCTAssertEqual(
      WorldClock.subtitle(zone: tz("Asia/Tokyo"), local: la, at: evening), "Tomorrow, +16 hrs")
    // Tokyo at 08:00 on Oct 18 (Oct 17 23:00 UTC): Honolulu is still at 13:00 on Oct 17.
    let tokyoMorning = Date(timeIntervalSince1970: 1_792_278_000)
    XCTAssertEqual(
      WorldClock.subtitle(zone: tz("Pacific/Honolulu"), local: tz("Asia/Tokyo"), at: tokyoMorning),
      "Yesterday, -19 hrs")
    // New Year's Eve: across a year boundary.
    let newYear = Date(timeIntervalSince1970: 1_798_768_800)  // 2027-01-01 02:00 UTC
    XCTAssertEqual(
      WorldClock.dayLabel(zone: tz("Europe/London"), local: tz("America/Los_Angeles"), at: newYear),
      "Tomorrow")
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

  func testScrubMovesByMinutesAndClamps() {
    typealias S = WorldClock.Scrub
    XCTAssertEqual(S.offset(start: 0, dragWidth: 0), 0)
    XCTAssertEqual(S.offset(start: 60, dragWidth: 0), 60, "no movement keeps the current offset")
    for width in [-9.0, 9.0] {
      XCTAssertEqual(S.offset(start: 0, dragWidth: width), 0, "less than a step does nothing")
    }
    XCTAssertEqual(S.offset(start: 0, dragWidth: 10), -1, "drag right = past")
    XCTAssertEqual(S.offset(start: 0, dragWidth: -10), 1, "drag left = future")
    XCTAssertEqual(S.offset(start: 0, dragWidth: 125), -12)
    XCTAssertEqual(S.offset(start: 60, dragWidth: -20), 62, "advances from where the drag began")
    XCTAssertEqual(S.offset(start: 60, dragWidth: 20), 58)
    XCTAssertEqual(S.offset(start: 0, dragWidth: 100_000), -24 * 60, "a day at most")
    XCTAssertEqual(S.offset(start: 0, dragWidth: -100_000), 24 * 60)
    XCTAssertEqual(S.offset(start: S.limitMinutes, dragWidth: 10), S.limitMinutes - 1)
    XCTAssertEqual(S.offset(start: -S.limitMinutes, dragWidth: -10), -S.limitMinutes + 1)
    let firstDrag = S.offset(start: 0, dragWidth: -10)
    let secondDrag = S.offset(start: firstDrag, dragWidth: -20)
    XCTAssertEqual(secondDrag, 3, "successive gestures accumulate minute offsets")
    XCTAssertEqual(S.offset(start: secondDrag, dragWidth: 10), 2)
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

  func testMinuteScrubCrossesMidnight() {
    let midnight = noonUTC.addingTimeInterval(12 * 3600)
    let beforeMidnight = midnight.addingTimeInterval(-60)
    let forward = WorldClock.Scrub.offset(start: 0, dragWidth: -10)
    let backward = WorldClock.Scrub.offset(start: 0, dragWidth: 10)
    XCTAssertEqual(WorldClock.Scrub.date(now: beforeMidnight, offset: forward), midnight)
    XCTAssertEqual(WorldClock.Scrub.date(now: midnight, offset: backward), beforeMidnight)
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

  func testRubberBand() {
    typealias S = WorldClock.Scrub
    XCTAssertEqual(S.rubberBand(0), 0)
    XCTAssertEqual(S.rubberBand(-5), 0)
    XCTAssertEqual(S.rubberBand(5), 5, accuracy: 0.3, "the first points follow the finger")
    XCTAssertLessThan(S.rubberBand(10_000), 56.0001, "and it never goes further than the maximum")
    XCTAssertGreaterThan(S.rubberBand(200), S.rubberBand(100))
    XCTAssertEqual(S.excess(start: 0, dragWidth: -100), 0, "inside the scale there is no stretch")
    XCTAssertEqual(S.excess(start: 24 * 60, dragWidth: -50), 50, "50 points past the end")
    XCTAssertEqual(S.excess(start: -24 * 60, dragWidth: 30), 30, "either end")
    XCTAssertEqual(
      S.excess(start: S.limitMinutes, dragWidth: 50), 0, "moving inward does not stretch")
    XCTAssertEqual(S.excess(start: -S.limitMinutes, dragWidth: -30), 0)
  }

  func testDayBands() {
    typealias B = WorldClock.DayBand
    XCTAssertEqual(B(hour: 0), .night)
    XCTAssertEqual(B(hour: 5), .night)
    XCTAssertEqual(B(hour: 6), .morning)
    XCTAssertEqual(B(hour: 8), .morning)
    XCTAssertEqual(B(hour: 9), .work)
    XCTAssertEqual(B(hour: 17), .work)
    XCTAssertEqual(B(hour: 18), .evening)
    XCTAssertEqual(B(hour: 21), .evening)
    XCTAssertEqual(B(hour: 22), .night)
    XCTAssertEqual(B(zone: tz("Asia/Kolkata"), at: noonUTC), .work, "17:30 in Kolkata")
    XCTAssertEqual(B(zone: tz("America/Los_Angeles"), at: noonUTC), .night, "05:00 in Los Angeles")
  }

  func testOverlapSameDay() {
    // Home Los Angeles (PDT): 9–18 = 16:00–01:00 UTC; New York 13:00–22:00 UTC; London (BST) 08:00–17:00 UTC.
    let laNoon = Date(timeIntervalSince1970: 1_792_263_600)  // Oct 17 12:00 in LA
    let window = WorldClock.overlap(
      [tz("America/New_York"), tz("Europe/London")], home: tz("America/Los_Angeles"), on: laNoon)
    XCTAssertEqual(window.count, 1)
    XCTAssertEqual(
      window.first?.start, Date(timeIntervalSince1970: 1_792_252_800), "16:00 UTC = 09:00 in LA")
    XCTAssertEqual(window.first?.duration, 3600)
    let sentence = WorldClock.overlapSentence(
      cities: ["New York", "London"], home: "Los Angeles", homeZone: tz("America/Los_Angeles"),
      overlap: window, locale: Locale(identifier: "en_GB"))
    XCTAssertEqual(sentence, "Overlap for New York and London when it's 09:00 in Los Angeles")
  }

  func testOverlapAcrossTheDateLine() {
    // Home Tokyo, Oct 18: Los Angeles works Oct 17 16:00 – Oct 18 01:00 UTC; Tokyo Oct 18 00:00–09:00 UTC.
    let tokyoNoon = Date(timeIntervalSince1970: 1_792_292_400)
    let window = WorldClock.overlap(
      [tz("America/Los_Angeles")], home: tz("Asia/Tokyo"), on: tokyoNoon)
    XCTAssertEqual(window.count, 1)
    XCTAssertEqual(
      window.first?.start, Date(timeIntervalSince1970: 1_792_281_600),
      "09:00 in Tokyo, still Oct 17 in LA")
    XCTAssertEqual(window.first?.duration, 3600)
  }

  func testNoOverlap() {
    // London 08–17 UTC; Sydney (AEDT) 22:00–07:00 UTC.
    let window = WorldClock.overlap(
      [tz("Australia/Sydney")], home: tz("Europe/London"), on: noonUTC)
    XCTAssertTrue(window.isEmpty)
    XCTAssertEqual(
      WorldClock.overlapSentence(
        cities: ["Sydney"], home: "London", homeZone: tz("Europe/London"), overlap: window),
      "No working hours overlap for Sydney today")
  }

  func testOverlapWithHomeOnlyIsTheWorkday() {
    let window = WorldClock.overlap([], home: tz("Europe/London"), on: noonUTC)
    XCTAssertEqual(window.first?.duration, 9 * 3600)
  }

  func testHomeDayAndOverlapAcrossBothDSTTransitions() throws {
    let home = tz("America/Los_Angeles")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = home
    for (month, day, hours) in [(3, 8, 23.0), (11, 1, 25.0)] {
      let noon = try XCTUnwrap(
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)))
      let window = WorldClock.day(containing: noon, in: home)
      XCTAssertEqual(window.duration, hours * 3600)
      let overlap = try XCTUnwrap(WorldClock.overlap([], home: home, on: noon).first)
      XCTAssertEqual(overlap.duration, 9 * 3600)
      XCTAssertEqual(WorldClock.hourMinute(zone: home, at: overlap.start).hour, 9)
      XCTAssertEqual(WorldClock.hourMinute(zone: home, at: overlap.end).hour, 18)
    }
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
