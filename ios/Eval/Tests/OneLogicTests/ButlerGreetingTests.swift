import Foundation
import Testing
import TodayCore

@Suite struct ButlerGreetingTests {
  let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/London")!
    return c
  }()
  let locale = Locale(identifier: "en_GB")

  func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
  }

  func item(_ title: String, _ hour: Int, _ minute: Int = 0, day: Int = 20, allDay: Bool = false)
    -> ButlerGreeting.Item
  {
    ButlerGreeting.Item(title: title, start: at(hour, minute, day: day), isAllDay: allDay)
  }

  func clock(_ hour: Int, _ minute: Int = 0) -> String {
    at(hour, minute).formatted(
      Date.FormatStyle(
        date: .omitted, time: .shortened, locale: locale, calendar: calendar,
        timeZone: calendar.timeZone))
  }

  func text(_ day: ButlerGreeting.Day, _ now: Date) -> String {
    ButlerGreeting.text(day, now: now, calendar: calendar, locale: locale)
  }

  @Test func namesTheNextItemWithCounts() {
    let day = ButlerGreeting.Day(
      today: [item("Yuan – Alden上学", 8), item("Standup", 10), item("Lunch", 12)],
      anytime: 3, overdue: 1)
    #expect(
      text(day, at(7, 10))
        == "Good morning. Next is Yuan – Alden上学 at \(clock(8)); six things remain today, one overdue."
    )
  }

  @Test func inProgressEventIsNotNext() {
    let day = ButlerGreeting.Day(today: [item("Meeting", 8), item("Call", 9)])
    #expect(
      text(day, at(8, 30)) == "Good morning. Next is Call at \(clock(9)); two things remain today.")
  }

  @Test func lastItemOfTheDay() {
    let day = ButlerGreeting.Day(today: [item("Dinner", 19)], overdue: 2)
    #expect(
      text(day, at(18))
        == "Good evening. Next is Dinner at \(clock(19)), the last today; two overdue.")
  }

  @Test func nothingLeftFallsBackToTomorrow() {
    let day = ButlerGreeting.Day(
      tomorrow: [item("Holiday", 0, day: 21, allDay: true), item("刷牙", 7, 30, day: 21)])
    #expect(
      text(day, at(21))
        == "Good evening. Nothing further today. Tomorrow begins at \(clock(7, 30)) with 刷牙.")
  }

  @Test func allDayOnlyTomorrow() {
    let day = ButlerGreeting.Day(tomorrow: [item("Holiday", 0, day: 21, allDay: true)])
    #expect(
      text(day, at(21)) == "Good evening. Nothing further today. Tomorrow begins with Holiday.")
  }

  @Test func emptyDay() {
    #expect(text(ButlerGreeting.Day(), at(9)) == "Good morning. Your day is clear.")
    #expect(text(ButlerGreeting.Day(), at(14)) == "Good afternoon. Your day is clear.")
    #expect(text(ButlerGreeting.Day(), at(20)) == "Good evening. Nothing further today.")
  }

  @Test func overdueCounts() {
    #expect(
      text(ButlerGreeting.Day(overdue: 1), at(9))
        == "Good morning. Your day is clear, save one overdue item.")
    #expect(
      text(ButlerGreeting.Day(overdue: 14), at(9))
        == "Good morning. Your day is clear, save 14 overdue items.")
    #expect(
      text(ButlerGreeting.Day(overdue: 3), at(22))
        == "Good evening. Nothing further today; three overdue.")
  }

  @Test func onlyUntimedThingsRemain() {
    #expect(
      text(ButlerGreeting.Day(anytime: 1), at(15))
        == "Good afternoon. One thing remains today, at no set time.")
    #expect(
      text(
        ButlerGreeting.Day(today: [item("Holiday", 0, allDay: true)], anytime: 2, overdue: 1),
        at(15))
        == "Good afternoon. Three things remain today, none at a set time; one overdue.")
  }

  @Test func longTitlesAreTruncated() {
    let long = String(repeating: "Quarterly planning review ", count: 6)
    let day = ButlerGreeting.Day(today: [item(long, 10), item("x", 11)], overdue: 1)
    let line = text(day, at(9))
    #expect(line.count <= ButlerGreeting.maxLength)
    #expect(line.hasPrefix("Good morning. Next is Quarterly planning"))
    #expect(line.hasSuffix("… at \(clock(10)); two things remain today, one overdue."))

    let cjk = String(repeating: "整理房间", count: 30)
    let night = text(ButlerGreeting.Day(tomorrow: [item(cjk, 7, day: 21)]), at(21))
    #expect(night.count <= ButlerGreeting.maxLength)
    #expect(night.hasSuffix("….") && night.contains("整理房间"))
  }

  @Test func salutationBoundaries() {
    let s = { ButlerGreeting.salutation(at: $0, calendar: calendar) }
    #expect(s(at(0)) == "Good evening.")
    #expect(s(at(4, 59)) == "Good evening.")
    #expect(s(at(5)) == "Good morning.")
    #expect(s(at(11, 59)) == "Good morning.")
    #expect(s(at(12)) == "Good afternoon.")
    #expect(s(at(16, 59)) == "Good afternoon.")
    #expect(s(at(17)) == "Good evening.")
    #expect(s(at(23, 59)) == "Good evening.")
  }

  @Test func justAfterMidnightReadsTheNewDay() {
    let day = ButlerGreeting.Day(
      today: [item("Yesterday's call", 23, day: 20), item("Gym", 6, day: 21)])
    #expect(
      text(day, at(0, 0, day: 21)) == "Good evening. Next is Gym at \(clock(6)), the last today.")
  }

  @Test func incompleteDataSaysOnlyHello() {
    let day = ButlerGreeting.Day(isComplete: false)
    #expect(text(day, at(9)) == "Good morning.")
  }

  @Test func usesTheLocalesTimeFormat() {
    let day = ButlerGreeting.Day(today: [item("Call", 15, 30)])
    let us = ButlerGreeting.text(
      day, now: at(9), calendar: calendar, locale: Locale(identifier: "en_US"))
    #expect(us.contains("3:30"))
    #expect(us.contains("PM"))
  }
}
