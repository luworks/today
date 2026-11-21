import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// The Year view's marks: holidays computed from rules, what counts as "load", and which days are unusually busy.
final class YearMarksTests: XCTestCase {
  private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()

  private func day(_ y: Int, _ m: Int, _ d: Int) -> DayKey { DayKey(year: y, month: m, day: d) }
  private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
  }

  // MARK: Holidays

  func testUnitedStatesHolidaysFollowTheirRules() {
    let h = Holidays.days(inYear: 2026, sets: [.unitedStates])
    XCTAssertEqual(h[day(2026, 1, 19)], ["Martin Luther King Jr. Day"], "third Monday of January")
    XCTAssertEqual(h[day(2026, 2, 16)], ["Presidents' Day"], "third Monday of February")
    XCTAssertEqual(h[day(2026, 5, 25)], ["Memorial Day"], "last Monday of May")
    XCTAssertEqual(h[day(2026, 9, 7)], ["Labor Day"], "first Monday of September")
    XCTAssertEqual(h[day(2026, 11, 26)], ["Thanksgiving"], "fourth Thursday of November")
    XCTAssertEqual(h[day(2027, 11, 25)] ?? [], [], "2027 is another year")
    XCTAssertEqual(
      Holidays.days(inYear: 2027, sets: [.unitedStates])[day(2027, 11, 25)], ["Thanksgiving"])
    XCTAssertEqual(Holidays.days(inYear: 2026, sets: [.unitedStates]).count, 11)
  }

  func testMemorialDayWhenMayEndsOnAMonday() {
    // May 31, 2027 is a Monday: the last Monday is the 31st, not the 24th.
    XCTAssertEqual(Holidays.last(weekday: 2, month: 5, year: 2027), day(2027, 5, 31))
  }

  func testInternationalFestivals() {
    let h = Holidays.days(inYear: 2026, sets: [.international])
    XCTAssertEqual(h[day(2026, 4, 5)], ["Easter Sunday"])
    XCTAssertEqual(h[day(2026, 5, 10)], ["Mother's Day"], "second Sunday of May")
    XCTAssertEqual(h[day(2026, 6, 21)], ["Father's Day"], "third Sunday of June")
    XCTAssertEqual(h[day(2026, 10, 31)], ["Halloween"])
    XCTAssertEqual(h[day(2026, 12, 25)], ["Christmas Day"])
    XCTAssertEqual(Holidays.easter(year: 2027), day(2027, 3, 28))
    XCTAssertEqual(Holidays.easter(year: 2024), day(2024, 3, 31))
  }

  func testChineseFestivalsComeFromTheChineseCalendar() {
    let h26 = Holidays.days(inYear: 2026, sets: [.china])
    XCTAssertEqual(h26[day(2026, 2, 17)], ["Spring Festival"])
    XCTAssertEqual(h26[day(2026, 2, 16)], ["Chinese New Year's Eve"])
    XCTAssertEqual(h26[day(2026, 3, 3)], ["Lantern Festival"])
    XCTAssertEqual(h26[day(2026, 4, 5)], ["Qingming"])
    XCTAssertEqual(h26[day(2026, 6, 19)], ["Dragon Boat Festival"])
    XCTAssertEqual(h26[day(2026, 9, 25)], ["Mid-Autumn Festival"])
    XCTAssertEqual(h26[day(2026, 10, 1)], ["National Day"])
    // The next year moves: Spring Festival 2027 is Feb 6, not Feb 17.
    let h27 = Holidays.days(inYear: 2027, sets: [.china])
    XCTAssertEqual(h27[day(2027, 2, 6)], ["Spring Festival"])
    XCTAssertEqual(h27[day(2027, 9, 15)], ["Mid-Autumn Festival"])
    XCTAssertEqual(h27[day(2027, 6, 9)], ["Dragon Boat Festival"])
  }

  func testQingmingIsAprilFourthOrFifth() {
    XCTAssertEqual(
      [2024, 2025, 2026, 2027, 2028].map { Holidays.qingming(year: $0)?.day }, [4, 4, 5, 5, 4])
    XCTAssertNil(Holidays.qingming(year: 1999), "the formula is only valid for 2001-2100")
  }

  func testTwoNamesOnOneDayAndNoDuplicates() {
    let h = Holidays.days(inYear: 2026, sets: Set(HolidaySet.allCases))
    XCTAssertEqual(Set(h[day(2026, 4, 5)] ?? []), ["Easter Sunday", "Qingming"])
    XCTAssertEqual(
      h[day(2026, 12, 25)], ["Christmas Day"], "the same holiday in two sets shows once")
  }

  func testNoSetsMarkNothing() {
    XCTAssertTrue(Holidays.days(inYear: 2026, sets: []).isEmpty)
  }

  func testSettingsFollowTheRegionUntilChosen() {
    XCTAssertEqual(HolidaySet.resolve("auto", region: "US"), [.unitedStates, .international])
    XCTAssertEqual(HolidaySet.resolve("auto", region: "CN"), [.china, .international])
    XCTAssertEqual(HolidaySet.resolve("", region: "DE"), [.international])
    XCTAssertEqual(HolidaySet.resolve("none", region: "US"), [])
    XCTAssertEqual(HolidaySet.resolve("china", region: "US"), [.china])
    XCTAssertEqual(HolidaySet.store([.international, .unitedStates]), "unitedStates,international")
    XCTAssertEqual(HolidaySet.store([]), "none")
    XCTAssertEqual(
      HolidaySet.resolve(HolidaySet.store([.china, .unitedStates]), region: "DE"),
      [.china, .unitedStates])
  }

  // MARK: Load

  private func item(
    _ start: Date, _ end: Date, allDay: Bool = false, repeats: Bool = false,
    background: Bool = false
  ) -> YearLoadItem {
    YearLoadItem(
      start: start, end: end, isAllDay: allDay, repeats: repeats, isBackground: background)
  }

  private var october: DateInterval {
    DateInterval(start: date(2026, 10, 1), end: date(2026, 11, 1))
  }

  func testOnlyYourOwnOneOffItemsCount() {
    let items = [
      item(date(2026, 10, 5, 9), date(2026, 10, 5, 10)),  // a meeting: counts
      item(date(2026, 10, 5, 14), date(2026, 10, 5, 15)),  // another: counts
      // the daily standup: no
      item(date(2026, 10, 5, 9, 45), date(2026, 10, 5, 10), repeats: true),
      // a holiday calendar: no
      item(date(2026, 10, 5), date(2026, 10, 6), allDay: true, background: true),
      item(date(2026, 10, 6), date(2026, 10, 6, 1), repeats: true),
      item(date(2026, 10, 7), date(2026, 10, 8), allDay: true),  // a one-day all-day event: counts
    ]
    let counts = YearLoad.counts(items, in: october, calendar: cal)
    XCTAssertEqual(counts[date(2026, 10, 5)], 2)
    XCTAssertNil(counts[date(2026, 10, 6)], "a repeating item alone leaves the day empty")
    XCTAssertEqual(counts[date(2026, 10, 7)], 1)
  }

  func testATripIsASpanNotALoad() {
    let trip = item(date(2026, 10, 21), date(2026, 10, 23), allDay: true)  // Oct 21-22
    XCTAssertTrue(YearLoad.counts([trip], in: october, calendar: cal).isEmpty)
  }

  func testAnOvernightEventCountsOnBothDays() {
    let counts = YearLoad.counts(
      [item(date(2026, 10, 9, 22), date(2026, 10, 10, 2))], in: october, calendar: cal)
    XCTAssertEqual(counts[date(2026, 10, 9)], 1)
    XCTAssertEqual(counts[date(2026, 10, 10)], 1)
  }

  func testItemsOutsideTheRangeAreClipped() {
    let counts = YearLoad.counts(
      [item(date(2026, 9, 30, 22), date(2026, 10, 1, 1))], in: october, calendar: cal)
    XCTAssertEqual(counts.keys.sorted(), [date(2026, 10, 1)])
  }

  func testBackgroundCalendars() {
    XCTAssertTrue(
      YearLoad.isBackgroundCalendar(
        isSubscription: true, isBirthday: false, title: "Premier League"))
    XCTAssertTrue(
      YearLoad.isBackgroundCalendar(isSubscription: false, isBirthday: true, title: "Birthdays"))
    XCTAssertTrue(
      YearLoad.isBackgroundCalendar(
        isSubscription: false, isBirthday: false, title: "Holidays in United States"))
    XCTAssertTrue(
      YearLoad.isBackgroundCalendar(isSubscription: false, isBirthday: false, title: "中国节假日"))
    XCTAssertFalse(
      YearLoad.isBackgroundCalendar(isSubscription: false, isBirthday: false, title: "Work"))
  }

  // MARK: Busy days

  private func loads(_ groups: [(count: Int, load: Int)]) -> [Int: Int] {
    var result: [Int: Int] = [:]
    var id = 0
    for g in groups {
      for _ in 0..<g.count {
        result[id] = g.load
        id += 1
      }
    }
    return result
  }

  func testAnEmptyYearMarksNothing() {
    XCTAssertTrue(YearBusy.days(loads: [Int: Int]()).isEmpty)
    XCTAssertTrue(YearBusy.days(loads: loads([(100, 0)])).isEmpty)
  }

  func testTheTopTenthOfActiveDaysIsMarked() {
    // 80 days with one item, 10 with two, 5 with three, 5 with four: the line is 3.
    let l = loads([(80, 1), (10, 2), (5, 3), (5, 4)])
    let busy = YearBusy.days(loads: l)
    XCTAssertEqual(busy.count, 10)
    XCTAssertTrue(busy.allSatisfy { (l[$0] ?? 0) >= 3 })
  }

  func testOrdinaryDaysAreNeverBusyEvenIfTheyAreTheBusiestYouHave() {
    // The best you have is two items: nothing is "unusually busy" (the floor is three).
    XCTAssertTrue(YearBusy.days(loads: loads([(90, 1), (10, 2)])).isEmpty)
  }

  func testAYearWhereEveryDayIsEquallyFullMarksNothing() {
    XCTAssertTrue(YearBusy.days(loads: loads([(100, 3)])).isEmpty)
    XCTAssertTrue(
      YearBusy.days(loads: loads([(50, 3), (50, 5)])).isEmpty,
      "more than 15 percent share the top: nothing stands out")
  }

  func testTiesAreBrokenUpwardsToStayUnderTheCap() {
    // 10 days with three and 10 with four would be 20 percent: only the fours stand out.
    let l = loads([(80, 1), (10, 3), (10, 4)])
    let busy = YearBusy.days(loads: l)
    XCTAssertEqual(busy.count, 10)
    XCTAssertTrue(busy.allSatisfy { l[$0] == 4 })
  }

  func testAFewActiveDaysStillNeedThreeItems() {
    XCTAssertEqual(YearBusy.days(loads: ["a": 1, "b": 2, "c": 3]), ["c"])
    XCTAssertTrue(YearBusy.days(loads: ["a": 1, "b": 2]).isEmpty)
  }
}

extension YearMarksTests {
  func testChineseLanguageAddsChinaWithoutDiscardingRegionOrExplicitChoice() {
    XCTAssertEqual(
      HolidaySet.resolve("auto", region: "US", language: "zh-Hans-US"),
      [.unitedStates, .china, .international])
    XCTAssertEqual(
      HolidaySet.resolve("auto", region: "GB", language: "zh-Hant"), [.china, .international])
    XCTAssertEqual(
      HolidaySet.resolve("auto", region: "US", language: "en-US"), [.unitedStates, .international])
    XCTAssertEqual(HolidaySet.resolve("none", region: "US", language: "zh-Hans"), [])
    XCTAssertEqual(
      HolidaySet.resolve("international", region: "CN", language: "zh-Hans"), [.international])
  }

  func testBirthdayClassificationForLocalAndSystemEvents() {
    XCTAssertTrue(YearEventMarks.isBirthday(title: "Mia's birthday", calendarTitle: "Local"))
    XCTAssertTrue(YearEventMarks.isBirthday(title: "妈妈生日", calendarTitle: "Local"))
    XCTAssertTrue(
      YearEventMarks.isBirthday(title: "Mia", calendarTitle: "Contacts", isBirthdayCalendar: true))
    XCTAssertTrue(YearEventMarks.isBirthday(title: "Mia", calendarTitle: "Birthdays"))
    XCTAssertFalse(YearEventMarks.isBirthday(title: "Conference", calendarTitle: "Work"))
  }

  func testSystemHolidayCandidatesAndExclusiveEndClassification() {
    XCTAssertTrue(YearEventMarks.isHolidayCalendar(isSubscription: true, title: "Regional dates"))
    XCTAssertTrue(YearEventMarks.isHolidayCalendar(isSubscription: false, title: "US HOLIDAYS"))
    XCTAssertTrue(YearEventMarks.isHolidayCalendar(isSubscription: false, title: "中国节假日"))
    XCTAssertFalse(YearEventMarks.isHolidayCalendar(isSubscription: false, title: "Work"))
    XCTAssertTrue(
      YearEventMarks.isSingleDayHoliday(
        start: date(2026, 10, 1), end: date(2026, 10, 2), isAllDay: true, calendar: cal))
    XCTAssertFalse(
      YearEventMarks.isSingleDayHoliday(
        start: date(2026, 10, 1), end: date(2026, 10, 3), isAllDay: true, calendar: cal))
    XCTAssertFalse(
      YearEventMarks.isSingleDayHoliday(
        start: date(2026, 10, 1, 10), end: date(2026, 10, 1, 11), isAllDay: false, calendar: cal))
    XCTAssertFalse(
      YearEventMarks.isSingleDayHoliday(
        start: date(2026, 10, 1), end: date(2026, 10, 1), isAllDay: true, calendar: cal))
  }

  func testTripBandsSplitAtWeekAndMonthBoundariesWithExclusiveEnds() {
    let weeks: [[Date?]] = [
      [nil, nil, nil, nil, date(2026, 10, 1), date(2026, 10, 2), date(2026, 10, 3)],
      (4...10).map { date(2026, 10, $0) },
      (11...17).map { date(2026, 10, $0) },
    ]
    XCTAssertEqual(
      YearEventMarks.segments(
        start: date(2026, 9, 30), end: date(2026, 10, 6), weeks: weeks, calendar: cal),
      [
        YearBandSegment(week: 0, firstColumn: 4, lastColumn: 6),
        YearBandSegment(week: 1, firstColumn: 0, lastColumn: 1),
      ])
    XCTAssertTrue(
      YearEventMarks.segments(
        start: date(2026, 9, 28), end: date(2026, 10, 1), weeks: weeks, calendar: cal
      ).isEmpty)
    XCTAssertFalse(
      YearEventMarks.isTrip(
        start: date(2026, 10, 1, 22), end: date(2026, 10, 3, 2), isAllDay: false, calendar: cal))
  }

  func testSingleAllDayDatesAcrossDSTAreNotTrips() {
    var local = cal
    local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    for components in [(2026, 3, 8), (2026, 11, 1)] {
      let start = local.date(
        from: DateComponents(year: components.0, month: components.1, day: components.2))!
      let next = local.date(byAdding: .day, value: 1, to: start)!
      let end = local.date(byAdding: .day, value: 2, to: start)!
      XCTAssertFalse(
        YearEventMarks.isTrip(start: start, end: next, isAllDay: true, calendar: local))
      XCTAssertTrue(YearEventMarks.isTrip(start: start, end: end, isAllDay: true, calendar: local))
      XCTAssertEqual(
        YearEventMarks.segments(
          start: start, end: end, weeks: [[start, next, end, nil, nil, nil, nil]], calendar: local),
        [
          YearBandSegment(week: 0, firstColumn: 0, lastColumn: 1)
        ])
    }
  }
}

extension YearMarksTests {
  func testPersistedLocalAllDayDurationsAcrossDST() {
    var local = cal
    local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    for (month, day) in [(3, 8), (11, 1)] {
      let start = local.date(from: DateComponents(year: 2026, month: month, day: day))!
      let next = local.date(byAdding: .day, value: 1, to: start)!
      let after = local.date(byAdding: .day, value: 2, to: start)!
      for minutes in [1440, 2880] {
        let end = YearEventMarks.localEnd(
          start: start, durationMinutes: minutes, isAllDay: true, calendar: local)
        XCTAssertEqual(end, minutes == 1440 ? next : after)
        XCTAssertEqual(
          YearEventMarks.isTrip(start: start, end: end, isAllDay: true, calendar: local),
          minutes == 2880)
        XCTAssertEqual(
          YearEventMarks.segments(
            start: start, end: end,
            weeks: [[start, next, after, nil, nil, nil, nil]], calendar: local),
          [
            YearBandSegment(week: 0, firstColumn: 0, lastColumn: minutes == 1440 ? 0 : 1)
          ])
        let counts = YearLoad.counts(
          [item(start, end, allDay: true)],
          in: DateInterval(start: start, end: after), calendar: local)
        XCTAssertEqual(counts, minutes == 1440 ? [start: 1] : [:])
      }
    }
  }

  func testMirroredElapsedAllDayDurationsAndTimedDurationsStayIntact() {
    var local = cal
    local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    for (month, day, minutes) in [(3, 8, 1380), (11, 1, 1500), (3, 8, 2820), (11, 1, 2940)] {
      let start = local.date(from: DateComponents(year: 2026, month: month, day: day))!
      let end = YearEventMarks.localEnd(
        start: start, durationMinutes: minutes, isAllDay: true, calendar: local)
      XCTAssertEqual(end, start.addingTimeInterval(TimeInterval(minutes * 60)))
      XCTAssertEqual(local.component(.hour, from: end), 0)
      XCTAssertEqual(
        YearEventMarks.isTrip(start: start, end: end, isAllDay: true, calendar: local),
        minutes > 1500)
      XCTAssertEqual(
        YearEventMarks.localEnd(
          start: start, durationMinutes: 1440, isAllDay: false, calendar: local),
        start.addingTimeInterval(86400))
    }
  }
}
