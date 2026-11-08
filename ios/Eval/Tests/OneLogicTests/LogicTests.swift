import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class RepeatRuleTests: XCTestCase {
  var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()

  func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
  }

  func testDailyKeepsTime() {
    XCTAssertEqual(
      RepeatRule.daily.next(after: date(2026, 10, 12, 15), calendar: cal), date(2026, 10, 13, 15))
  }

  func testWeekdaysSkipsWeekend() {
    // Fri Oct 16 → Mon Oct 19
    XCTAssertEqual(
      RepeatRule.weekdays.next(after: date(2026, 10, 16), calendar: cal), date(2026, 10, 19))
  }

  func testMonthlyClampsToMonthEnd() {
    XCTAssertEqual(
      RepeatRule.monthly.next(after: date(2026, 1, 31), calendar: cal), date(2026, 2, 28))
  }

  func testWeekly() {
    XCTAssertEqual(
      RepeatRule.weekly.next(after: date(2026, 10, 12), calendar: cal), date(2026, 10, 19))
  }
}

final class RecurrenceTests: XCTestCase {
  let cal = Calendar(identifier: .gregorian)

  func testWeeklyOccurrencesInAMonth() {
    let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 10))!
    let month = DateInterval(
      start: cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!,
      end: cal.date(from: DateComponents(year: 2026, month: 11, day: 1))!)
    let dates = Recurrence.occurrences(
      start: start, duration: 3600, rule: .weekly, in: month, calendar: cal)
    XCTAssertEqual(dates.map { cal.component(.day, from: $0) }, [5, 12, 19, 26])
  }

  func testOneOffOnlyWhenOverlapping() {
    let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 23))!
    let nextDay = DateInterval(
      start: cal.date(from: DateComponents(year: 2026, month: 10, day: 6))!, duration: 86400)
    // 2-hour event crosses midnight, so it shows on the next day too.
    XCTAssertEqual(
      Recurrence.occurrences(start: start, duration: 7200, rule: nil, in: nextDay, calendar: cal)
        .count, 1)
    XCTAssertEqual(
      Recurrence.occurrences(start: start, duration: 1800, rule: nil, in: nextDay, calendar: cal)
        .count, 0)
  }
}

final class ReminderPlanTests: XCTestCase {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  func testSnoozePresets() {
    XCTAssertEqual(ReminderPlan.snoozed("SNOOZE_10", now: t0), t0.addingTimeInterval(600))
    XCTAssertEqual(ReminderPlan.snoozed("SNOOZE_60", now: t0), t0.addingTimeInterval(3600))
    XCTAssertNil(ReminderPlan.snoozed("DONE", now: t0))
  }
}

final class DayScheduleTests: XCTestCase {
  var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()
  func at(_ h: Int, _ m: Int = 0, day: Int = 12) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
  }

  func testFreeGapsFromNowSkipShortOnes() {
    // Now 09:41; Standup 09:45–10:00, a suggestion 10:05–10:30, lunch 12:15–13:00, a long afternoon until 21:00.
    let busy = [
      DateInterval(start: at(9, 45), end: at(10)), DateInterval(start: at(10, 5), end: at(10, 30)),
      DateInterval(start: at(12, 15), end: at(13)), DateInterval(start: at(13), end: at(21)),
    ]
    let gaps = DaySchedule.freeGaps(busy: busy, day: at(0), now: at(9, 41), calendar: cal)
    // 09:41–09:45 and 10:00–10:05 are too short; 10:30–12:15 is the one free stretch.
    XCTAssertEqual(gaps, [DateInterval(start: at(10, 30), end: at(12, 15))])
    XCTAssertEqual(DaySchedule.freeLabel(gaps[0].duration), "Free 1 h 45 min")
    XCTAssertEqual(DaySchedule.freeLabel(45 * 60), "Free 45 min")
    XCTAssertEqual(DaySchedule.freeLabel(2 * 3600), "Free 2 h")
  }

  func testNoGapsLateOrOnPastDays() {
    XCTAssertEqual(DaySchedule.freeGaps(busy: [], day: at(0), now: at(21, 5), calendar: cal), [])
    XCTAssertEqual(
      DaySchedule.freeGaps(busy: [], day: at(0, day: 11), now: at(9), calendar: cal), [])
  }
}

final class ListNameTests: XCTestCase {
  func testStripsOrderingNumber() {
    XCTAssertEqual(ListName.display("01 Work"), "Work")
    XCTAssertEqual(ListName.display("00 收件箱"), "收件箱")
    XCTAssertEqual(ListName.display("Home"), "Home")
    XCTAssertEqual(ListName.display("2026 plans"), "2026 plans")
  }
}

final class AlarmPlanTests: XCTestCase {
  private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    c.locale = Locale(identifier: "en_US")
    return c
  }
  /// Oct 12 2026 is a Monday.
  private func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
  }

  func testNextFiveMinutes() {
    XCTAssertEqual(AlarmPlan.nextFiveMinutes(after: at(12, 10, 56), calendar: cal), at(12, 11, 0))
    XCTAssertEqual(AlarmPlan.nextFiveMinutes(after: at(12, 10, 41), calendar: cal), at(12, 10, 45))
    XCTAssertEqual(AlarmPlan.nextFiveMinutes(after: at(12, 10, 52), calendar: cal), at(12, 10, 55))
    XCTAssertEqual(
      AlarmPlan.nextFiveMinutes(after: at(12, 10, 50), calendar: cal), at(12, 10, 55),
      "on a mark, the next one")
    XCTAssertEqual(AlarmPlan.nextFiveMinutes(after: at(12, 10, 0), calendar: cal), at(12, 10, 5))
    XCTAssertEqual(AlarmPlan.nextFiveMinutes(after: at(12, 23, 55), calendar: cal), at(13, 0, 0))
    XCTAssertEqual(AlarmPlan.nextFiveMinutes(after: at(12, 23, 58), calendar: cal), at(13, 0, 0))
  }

  func testAlarmMinuteStep() {
    XCTAssertEqual(AlarmPlan.minuteStep(forAlarmMinute: nil), 5, "a new alarm: 00, 05 … 55")
    XCTAssertEqual(AlarmPlan.minuteStep(forAlarmMinute: 0), 5)
    XCTAssertEqual(AlarmPlan.minuteStep(forAlarmMinute: 35), 5)
    XCTAssertEqual(
      AlarmPlan.minuteStep(forAlarmMinute: 42), 1, "off the grid: every minute, so 42 stays")
    XCTAssertEqual(AlarmPlan.minuteStep(forAlarmMinute: 7), 1)
  }

  func testSnoozeChoicesAreTheShortList() {
    XCTAssertEqual(AlarmPlan.snoozeChoices, [5, 9, 10, 15, 30])
    XCTAssertEqual(AlarmPlan.defaultSnoozeMinutes, 9)
    XCTAssertTrue(AlarmPlan.snoozeChoices.contains(AlarmPlan.defaultSnoozeMinutes))
  }

  func testSnoozeMinutesMapToNearestAllowed_tiesGoDown() {
    for m in AlarmPlan.snoozeChoices { XCTAssertEqual(AlarmPlan.snoozeMinutes(nearest: m), m) }
    XCTAssertEqual(AlarmPlan.snoozeMinutes(nearest: 1), 5)
    XCTAssertEqual(AlarmPlan.snoozeMinutes(nearest: 3), 5)
    XCTAssertEqual(AlarmPlan.snoozeMinutes(nearest: 7), 5, "7 is 2 from both 5 and 9; ties go down")
    XCTAssertEqual(AlarmPlan.snoozeMinutes(nearest: 8), 9)
    XCTAssertEqual(AlarmPlan.snoozeMinutes(nearest: 20), 15)
    XCTAssertEqual(AlarmPlan.snoozeMinutes(nearest: 23), 30)
    XCTAssertEqual(AlarmPlan.snoozeMinutes(nearest: 60), 30)
    XCTAssertEqual(AlarmPlan.snoozeMinutes(nearest: 0), 5)
    XCTAssertEqual(AlarmPlan.snoozeMinutes(nearest: -4), 5)
  }

  func testOneTimeAlarmRingsTodayIfStillAhead_elseTomorrow() {
    XCTAssertEqual(
      AlarmPlan.nextFire(hour: 18, minute: 0, weekdays: [], after: at(12, 9, 41), calendar: cal),
      at(12, 18, 0))
    XCTAssertEqual(
      AlarmPlan.nextFire(hour: 7, minute: 0, weekdays: [], after: at(12, 9, 41), calendar: cal),
      at(13, 7, 0))
  }

  func testWeekdayAlarmSkipsTheWeekend() {
    // Friday 9:41 → 7:00 alarm on weekdays next rings Monday.
    XCTAssertEqual(
      AlarmPlan.nextFire(
        hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6], after: at(16, 9, 41), calendar: cal),
      at(19, 7, 0))
  }

  func testClockRepeatWording() {
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [], calendar: cal), "Never")
    XCTAssertEqual(
      AlarmPlan.repeatValue(weekdays: [1, 2, 3, 4, 5, 6, 7], calendar: cal), "Every day")
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [2, 3, 4, 5, 6], calendar: cal), "Weekdays")
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [1, 7], calendar: cal), "Weekends")
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [2], calendar: cal), "Every Monday")
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [4, 2], calendar: cal), "Mon, Wed")
    // Sunday-first calendar (US): Sunday leads, so Sun + Mon reads "Sun, Mon".
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [2, 1], calendar: cal), "Sun, Mon")
    XCTAssertEqual(AlarmPlan.orderedWeekdays(calendar: cal), [1, 2, 3, 4, 5, 6, 7])
    var monday = cal
    monday.firstWeekday = 2
    XCTAssertEqual(AlarmPlan.orderedWeekdays(calendar: monday), [2, 3, 4, 5, 6, 7, 1])
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [2, 1], calendar: monday), "Mon, Sun")
  }

  func testRepeatValueMakesRangesOfConsecutiveDays() {
    // Three or more days in a row become a range; "Every" only starts one day, a daily or a weekday alarm.
    XCTAssertEqual(
      AlarmPlan.repeatValue(weekdays: [1, 2, 3, 4, 5], calendar: cal), "Sun\u{2013}Thu")
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [2, 3, 4], calendar: cal), "Mon\u{2013}Wed")
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [2, 4, 6], calendar: cal), "Mon, Wed, Fri")
    XCTAssertEqual(
      AlarmPlan.repeatValue(weekdays: [2, 3, 4, 6], calendar: cal), "Mon\u{2013}Wed, Fri")
    XCTAssertEqual(
      AlarmPlan.repeatValue(weekdays: [2, 3, 5, 6, 7], calendar: cal), "Mon, Tue, Thu\u{2013}Sat")
    XCTAssertEqual(
      AlarmPlan.repeatValue(weekdays: [2, 3, 4, 5, 6, 7], calendar: cal), "Mon\u{2013}Sat")
    XCTAssertEqual(
      AlarmPlan.repeatValue(weekdays: [1, 2, 3, 4, 5, 6], calendar: cal), "Sun\u{2013}Fri")
    XCTAssertEqual(
      AlarmPlan.repeatValue(weekdays: [2, 3, 4, 5, 6, 7, 1], calendar: cal), "Every day")
    // Monday-first calendar: the week reads Mon…Sun, so Fri + Sat + Sun is one run.
    var monday = cal
    monday.firstWeekday = 2
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [6, 7, 1], calendar: monday), "Fri\u{2013}Sun")
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [2, 3, 4, 5, 6], calendar: monday), "Weekdays")
    XCTAssertEqual(AlarmPlan.repeatValue(weekdays: [7, 1], calendar: monday), "Weekends")
    XCTAssertEqual(
      AlarmPlan.rowSubtitle(label: "Work", weekdays: [1, 2, 3, 4, 5], calendar: cal),
      "Work, Sun\u{2013}Thu")
  }

  func testRowSubtitle() {
    XCTAssertEqual(AlarmPlan.rowSubtitle(label: "", weekdays: [], calendar: cal), "Alarm")
    XCTAssertEqual(
      AlarmPlan.rowSubtitle(label: "  ", weekdays: [1, 2, 3, 4, 5, 6, 7], calendar: cal),
      "Alarm, Every day")
    XCTAssertEqual(
      AlarmPlan.rowSubtitle(label: "Gym", weekdays: [2, 3, 4, 5, 6], calendar: cal), "Gym, Weekdays"
    )
    XCTAssertEqual(AlarmPlan.rowSubtitle(label: "Gym", weekdays: [], calendar: cal), "Gym")
  }

  func testTimePartsFollowTheClockSetting() {
    let us = Locale(identifier: "en_US")
    XCTAssertEqual(AlarmPlan.timeParts(hour: 7, minute: 5, locale: us).time, "7:05")
    XCTAssertEqual(AlarmPlan.timeParts(hour: 7, minute: 5, locale: us).suffix, "AM")
    XCTAssertEqual(AlarmPlan.timeParts(hour: 0, minute: 0, locale: us).time, "12:00")
    XCTAssertEqual(AlarmPlan.timeParts(hour: 12, minute: 30, locale: us).suffix, "PM")
    XCTAssertEqual(AlarmPlan.timeParts(hour: 19, minute: 45, locale: us).time, "7:45")
    let de = Locale(identifier: "de_DE")
    XCTAssertEqual(AlarmPlan.timeParts(hour: 7, minute: 5, locale: de).time, "07:05")
    XCTAssertNil(AlarmPlan.timeParts(hour: 19, minute: 45, locale: de).suffix)
    XCTAssertEqual(AlarmPlan.timeParts(hour: 19, minute: 45, locale: de).time, "19:45")
  }

  func testNextRing() {
    let now = at(12, 9, 41)  // Monday
    // One-time alarm switched on at 9:00 for 18:00 rings today; for 7:00 it rings tomorrow.
    XCTAssertEqual(
      AlarmPlan.nextRing(
        hour: 18, minute: 0, weekdays: [], switchedOn: at(12, 9, 0), now: now, calendar: cal),
      at(12, 18, 0))
    XCTAssertEqual(
      AlarmPlan.nextRing(
        hour: 7, minute: 0, weekdays: [], switchedOn: at(12, 9, 0), now: now, calendar: cal),
      at(13, 7, 0))
    // A one-time alarm that already rang (switched on yesterday for 7:00) has nothing next.
    XCTAssertNil(
      AlarmPlan.nextRing(
        hour: 7, minute: 0, weekdays: [], switchedOn: at(11, 20, 0), now: now, calendar: cal))
    // Repeating alarms count from now.
    XCTAssertEqual(
      AlarmPlan.nextRing(
        hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6], switchedOn: at(1, 0, 0), now: at(16, 9, 41),
        calendar: cal), at(19, 7, 0))
  }

  func testNextAlarmText() {
    let now = at(12, 9, 41)
    XCTAssertEqual(
      AlarmPlan.nextAlarmText(rings: [at(12, 16, 53)], now: now), "Next alarm in 7 hr 12 min")
    XCTAssertEqual(
      AlarmPlan.nextAlarmText(rings: [at(13, 7, 0), at(12, 10, 41)], now: now), "Next alarm in 1 hr"
    )
    XCTAssertEqual(
      AlarmPlan.nextAlarmText(rings: [at(12, 9, 53)], now: now), "Next alarm in 12 min")
    XCTAssertEqual(
      AlarmPlan.nextAlarmText(rings: [now.addingTimeInterval(20)], now: now), "Next alarm in 1 min")
    XCTAssertEqual(
      AlarmPlan.nextAlarmText(rings: [at(14, 12, 41)], now: now), "Next alarm in 2 days 3 hr")
    XCTAssertEqual(AlarmPlan.nextAlarmText(rings: [at(13, 9, 41)], now: now), "Next alarm in 1 day")
    XCTAssertNil(AlarmPlan.nextAlarmText(rings: [], now: now))
    XCTAssertNil(
      AlarmPlan.nextAlarmText(rings: [at(12, 8, 0)], now: now), "an alarm in the past is not next")
  }

  func testFireOnDay() {
    let now = at(12, 9, 41)
    XCTAssertEqual(
      AlarmPlan.fire(on: at(12, 0, 0), hour: 18, minute: 0, weekdays: [], now: now, calendar: cal),
      at(12, 18, 0))
    XCTAssertNil(
      AlarmPlan.fire(on: at(13, 0, 0), hour: 18, minute: 0, weekdays: [], now: now, calendar: cal),
      "once rings only on its next day")
    XCTAssertEqual(
      AlarmPlan.fire(on: at(14, 0, 0), hour: 7, minute: 0, weekdays: [4], now: now, calendar: cal),
      at(14, 7, 0))
    XCTAssertNil(
      AlarmPlan.fire(on: at(15, 0, 0), hour: 7, minute: 0, weekdays: [4], now: now, calendar: cal))
  }
}

final class CalendarMathTests: XCTestCase {
  private func calendar(firstWeekday: Int) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    c.locale = Locale(identifier: "en_US")
    c.firstWeekday = firstWeekday
    return c
  }
  private func at(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
  }

  /// October 2026 starts on a Thursday and has 31 days.
  func testMonthGridSundayFirst() {
    let cal = calendar(firstWeekday: 1)
    let weeks = CalendarMath.monthWeeks(of: at(cal, 2026, 10, 15), calendar: cal)
    XCTAssertEqual(weeks.count, 5)
    XCTAssertTrue(weeks.allSatisfy { $0.count == 7 })
    XCTAssertEqual(
      weeks[0].map { $0 == nil }, [true, true, true, true, false, false, false],
      "1st sits under Thursday")
    XCTAssertEqual(cal.component(.day, from: weeks[0][4]!), 1)
    XCTAssertEqual(cal.component(.day, from: weeks[4][6]!), 31)
    XCTAssertEqual(weeks.flatMap { $0 }.compactMap { $0 }.count, 31)
  }

  func testRowCountDependsOnTheFirstWeekday() {
    // August 2026 starts on a Saturday: six rows either way.
    XCTAssertEqual(
      CalendarMath.monthWeeks(
        of: at(calendar(firstWeekday: 1), 2026, 8, 10), calendar: calendar(firstWeekday: 1)
      ).count, 6)
    // February 2026 starts on a Sunday and has 28 days: four rows Sunday-first, five Monday-first.
    XCTAssertEqual(
      CalendarMath.monthWeeks(
        of: at(calendar(firstWeekday: 1), 2026, 2, 10), calendar: calendar(firstWeekday: 1)
      ).count, 4)
    XCTAssertEqual(
      CalendarMath.monthWeeks(
        of: at(calendar(firstWeekday: 2), 2026, 2, 10), calendar: calendar(firstWeekday: 2)
      ).count, 5)
  }

  func testFebruaryOfALeapYear() {
    let cal = calendar(firstWeekday: 1)
    let days = CalendarMath.monthWeeks(of: at(cal, 2028, 2, 1), calendar: cal).flatMap { $0 }
      .compactMap { $0 }
    XCTAssertEqual(days.count, 29)
  }

  func testMonthOffsets() {
    let cal = calendar(firstWeekday: 1)
    let ref = at(cal, 2026, 10, 15)
    XCTAssertEqual(CalendarMath.monthOffset(of: at(cal, 2027, 1, 3), from: ref, calendar: cal), 3)
    XCTAssertEqual(
      CalendarMath.monthOffset(of: at(cal, 2025, 12, 31), from: ref, calendar: cal), -10)
    XCTAssertEqual(CalendarMath.monthOffset(of: ref, from: ref, calendar: cal), 0)
    let start = CalendarMath.monthStart(offset: 3, from: ref, calendar: cal)
    XCTAssertEqual(
      cal.dateComponents([.year, .month, .day], from: start),
      DateComponents(year: 2027, month: 1, day: 1))
  }

  func testWeekdayLetters() {
    let sun = calendar(firstWeekday: 1)
    let mon = calendar(firstWeekday: 2)
    XCTAssertEqual(CalendarMath.weekdayLetters(calendar: sun), ["S", "M", "T", "W", "T", "F", "S"])
    XCTAssertEqual(CalendarMath.weekdayLetters(calendar: mon).first, "M")
    XCTAssertEqual(CalendarMath.weekdayLetters(calendar: mon).last, "S")
  }

  func testLandingDay() {
    let cal = calendar(firstWeekday: 1)
    let today = at(cal, 2026, 10, 15)
    XCTAssertEqual(
      cal.component(
        .day,
        from: CalendarMath.landingDay(inMonthOf: at(cal, 2026, 10, 3), today: today, calendar: cal)),
      15,
      "landing on the current month selects today")
    XCTAssertEqual(
      cal.component(
        .day,
        from: CalendarMath.landingDay(inMonthOf: at(cal, 2026, 11, 20), today: today, calendar: cal)
      ), 1)
  }
}

final class CalendarLayoutTests: XCTestCase {
  // timedDay works in points; at 60pt an hour, y is the minute of the day.
  private func day(
    blocks: [(y: Double, height: Double)] = [], marks: [Double] = [], width: Double = 100
  ) -> CalendarLayout.TimedDay {
    CalendarLayout.timedDay(blocks: blocks, marks: marks, columnWidth: width)
  }

  func testChipsStackAtTheirTimeAndFoldWhenCrowded() {
    // Four reminders at 10:00: two chips fit near their time, the rest fold into the "+N" of the second.
    let d = day(marks: [600, 600, 600, 600, 700])
    XCTAssertEqual(d.marks[0]?.minY, 600)
    XCTAssertEqual(d.marks[1]?.minY, 619, "the next chip sits just under the one above")
    XCTAssertNil(d.marks[2])
    XCTAssertNil(d.marks[3])
    XCTAssertEqual(d.folded[1], [2, 3])
    XCTAssertEqual(d.marks[4]?.minY, 700, "a later reminder keeps its own time")
    XCTAssertEqual(d.folded[4], [])
    XCTAssertEqual(d.marks[0]?.width, 98, "a chip with no event beside it takes the full width")
  }

  func testEventsThatStartTogetherShareTheWidth() {
    let d = day(blocks: [(540, 60), (540, 60)])
    XCTAssertEqual(d.depths, [0, 0])
    XCTAssertEqual(d.blocks[0].minX, 1)
    XCTAssertEqual(d.blocks[0].width, 48)
    XCTAssertEqual(d.blocks[1].minX, 50)
    XCTAssertLessThan(d.blocks[0].maxX, d.blocks[1].minX)
  }

  func testLaterOverlappingEventIsStaggeredOnTop() {
    // 9-11 and 9:30-10:30: the later one is indented and drawn on top, both stay wide enough to read.
    let d = day(blocks: [(540, 120), (570, 60)])
    XCTAssertEqual(d.depths, [0, 1])
    XCTAssertEqual(d.blocks[0].width, 97, "the first event keeps the full width")
    XCTAssertGreaterThan(d.blocks[1].minX, d.blocks[0].minX + 30)
    XCTAssertGreaterThan(d.blocks[1].width, 50)
    XCTAssertEqual(d.blocks[1].maxX, d.blocks[0].maxX, accuracy: 1.01)
  }

  func testBackToBackEventsAreNotStaggered() {
    let d = day(blocks: [(540, 60), (600, 60)])
    XCTAssertEqual(d.depths, [0, 0])
    XCTAssertEqual(d.blocks[1].minX, 1)
  }

  func testThreeWayOverlapStaggersOnlyTheLaterStart() {
    // 9-11 and 9:10-10 start together; 9:20 starts later, over both.
    let d = day(blocks: [(540, 120), (550, 50), (560, 20)])
    XCTAssertEqual(d.depths, [0, 0, 1])
    XCTAssertGreaterThan(d.blocks[2].minX, 1)
  }

  func testChipBesideAnEventTakesTheRightHalf() {
    // An alarm at 9:20 during a 9-10 event; a reminder at 11:40 has the column to itself.
    let d = day(blocks: [(540, 60)], marks: [560, 700])
    guard let beside = d.marks[0], let alone = d.marks[1] else { return XCTFail("both chips show") }
    XCTAssertLessThan(d.blocks[0].maxX, beside.minX, "the event keeps the left half")
    XCTAssertEqual(beside.maxX, 99, accuracy: 0.001)
    XCTAssertFalse(d.blocks[0].contains(x: beside.midX, y: beside.midY))
    XCTAssertEqual(alone.minX, 1)
    XCTAssertEqual(alone.width, 98)
  }

  func testDenseSimultaneousEventsStayLeftOfTheChip() {
    // Eight events at 9:00 and an alarm at 9:30, from narrow to roomy columns.
    for width in [56.0, 116, 170] {
      let d = day(blocks: Array(repeating: (540, 60), count: 8), marks: [570], width: width)
      guard let chip = d.marks[0] else { return XCTFail("the chip shows") }
      let sorted = d.blocks.sorted { $0.minX < $1.minX }
      for b in sorted {
        XCTAssertGreaterThan(b.width, 0)
        XCTAssertLessThanOrEqual(b.maxX, chip.minX, "width \(width): \(b) yields to \(chip)")
      }
      for (l, r) in zip(sorted, sorted.dropFirst()) {
        XCTAssertLessThanOrEqual(l.maxX, r.minX + 0.0001)
      }
    }
  }

  func testEmptyDayHasNothingToPlace() {
    let d = day()
    XCTAssertTrue(d.blocks.isEmpty && d.depths.isEmpty && d.marks.isEmpty && d.folded.isEmpty)
  }

  func testAllDayLanesStackOverlappingBanners() {
    // Mon-Wed, Tue-Thu overlap; Fri does not.
    let lanes = CalendarLayout.lanes(for: [(1, 3), (2, 4), (5, 5)])
    XCTAssertEqual(lanes, [0, 1, 0])
  }

  func testAllDayLanesPutTheLongerBannerFirst() {
    let lanes = CalendarLayout.lanes(for: [(0, 0), (0, 6)])
    XCTAssertEqual(lanes, [1, 0], "the week-long banner takes the top lane")
  }

  func testAllDayLanesReuseFreedLane() {
    let lanes = CalendarLayout.lanes(for: [(0, 1), (0, 0), (1, 1), (2, 3)])
    XCTAssertEqual(lanes[0], 0)
    XCTAssertEqual(lanes[3], 0, "a lane is reused once its banner ended")
    XCTAssertNotEqual(lanes[1], lanes[0])
  }

  func testLongPressSlotSnapsDownToQuarterHours() {
    // Gutter 44, columns 50 wide, 48pt hours: x 44+2*50+10 is the third day; y 18h + 20 min is 18:15.
    let s = CalendarLayout.slot(
      x: 154, y: 18 * 48 + 16, gutter: 44, columnWidth: 50, hourHeight: 48, dayCount: 7)
    XCTAssertEqual(s.day, 2)
    XCTAssertEqual(s.minute, 18 * 60 + 15)
  }

  func testLongPressSlotStaysInsideTheGrid() {
    let early = CalendarLayout.slot(
      x: 10, y: -5, gutter: 44, columnWidth: 50, hourHeight: 48, dayCount: 7)
    XCTAssertEqual(early.day, 0, "the hour labels count as the first day")
    XCTAssertEqual(early.minute, 0)
    let late = CalendarLayout.slot(
      x: 2000, y: 24 * 48 + 30, gutter: 44, columnWidth: 50, hourHeight: 48, dayCount: 7)
    XCTAssertEqual(late.day, 6)
    XCTAssertEqual(late.minute, 23 * 60 + 45, "starts no later than 23:45")
  }

  func testPinchZoomStaysInRange() {
    XCTAssertEqual(CalendarLayout.zoomedHourHeight(48, scale: 2), 96)
    XCTAssertEqual(
      CalendarLayout.zoomedHourHeight(48, scale: 10), 120, "no taller than 120pt an hour")
    XCTAssertEqual(
      CalendarLayout.zoomedHourHeight(48, scale: 0.1), 28, "no shorter than 28pt an hour")
  }

  func testRestoredHourHeightStaysInTheZoomRange() {
    XCTAssertEqual(CalendarLayout.restoredHourHeight(72), 72, "a saved zoom reopens as it was")
    XCTAssertEqual(CalendarLayout.restoredHourHeight(500), 120)
    XCTAssertEqual(CalendarLayout.restoredHourHeight(5), 28)
    XCTAssertEqual(CalendarLayout.restoredHourHeight(0), 48, "nothing saved")
    XCTAssertEqual(CalendarLayout.restoredHourHeight(.nan), 48)
    XCTAssertEqual(CalendarLayout.restoredHourHeight(.infinity), 48)
  }
}

final class SearchMatchTests: XCTestCase {
  func testAllWordsMustMatchAnywhere() {
    XCTAssertTrue(SearchMatch.matches("milk home", in: ["Buy milk", "Home"]))
    XCTAssertFalse(SearchMatch.matches("milk work", in: ["Buy milk", "Home"]))
  }

  func testIgnoresCaseAndAccents() {
    XCTAssertTrue(SearchMatch.matches("CAFE", in: ["Café with Priya"]))
  }

  func testWorksForChinese() {
    XCTAssertTrue(SearchMatch.matches("牙医", in: ["下午 牙医 复诊"]))
    XCTAssertFalse(SearchMatch.matches("牙医", in: ["开会"]))
  }

  func testEmptyQueryMatchesNothing() {
    XCTAssertFalse(SearchMatch.matches("  ", in: ["Buy milk"]))
  }
}
