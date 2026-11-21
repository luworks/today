import XCTest

@testable import TodayCore
@testable import TodayData

/// The choices added to Settings: every default is what the app did before the choice existed, and each choice maps to its effect.
final class PreferencesTests: XCTestCase {
  private func freshDefaults() -> UserDefaults {
    let name = "PreferencesTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    c.locale = Locale(identifier: "en_US")
    return c
  }()

  private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
  }

  // MARK: Defaults = the old behaviour

  func testFreeRowMinutesDefaultsAndFallbacks() {
    XCTAssertEqual(Preferences.freeRowMinutes, 30, "Today's Free rows started at 30 minutes")
    XCTAssertEqual(Preferences.freeRowMinutes(stored: 15), 15)
    XCTAssertEqual(Preferences.freeRowMinutes(stored: 60), 60)
    XCTAssertEqual(Preferences.freeRowMinutes(stored: 45), 30, "a retired value is the default")
  }

  func testNewEventLengthDefaultsAndFallbacks() {
    let d = freshDefaults()
    XCTAssertEqual(Preferences.newEventMinutes(d), 60, "a new event lasted an hour")
    for minutes in Preferences.newEventMinutesChoices {
      d.set(minutes, forKey: Preferences.newEventMinutesKey)
      XCTAssertEqual(Preferences.newEventMinutes(d), minutes)
    }
    d.set(50, forKey: Preferences.newEventMinutesKey)
    XCTAssertEqual(Preferences.newEventMinutes(d), 60, "a retired value is the default")
    XCTAssertEqual(Preferences.newEventMinutesLabel(90), "1.5 hours")
    XCTAssertEqual(Preferences.newEventMinutesLabel(15), "15 minutes")
  }

  // MARK: First day of the week

  func testSystemLeavesTheCalendarAlone() {
    var monday = cal
    monday.firstWeekday = 2
    XCTAssertEqual(Preferences.FirstWeekday.system.calendar(base: monday).firstWeekday, 2)
    XCTAssertEqual(
      Preferences.FirstWeekday.system.calendar(base: cal).firstWeekday, cal.firstWeekday)
  }

  func testMondayStartMovesTheMonthGridAndTheWeekStart() {
    let monday = Preferences.FirstWeekday.monday.calendar(base: cal)
    let sunday = Preferences.FirstWeekday.sunday.calendar(base: cal)
    // October 2026 starts on a Thursday: three blanks when the week starts Monday, four when it starts Sunday.
    let oct = date(14, 12)
    XCTAssertEqual(
      CalendarMath.monthWeeks(of: oct, calendar: monday)[0].prefix(while: { $0 == nil }).count, 3)
    XCTAssertEqual(
      CalendarMath.monthWeeks(of: oct, calendar: sunday)[0].prefix(while: { $0 == nil }).count, 4)
    // Wednesday the 14th: its week starts Monday the 12th, or Sunday the 11th.
    XCTAssertEqual(
      monday.component(.day, from: monday.dateInterval(of: .weekOfYear, for: oct)!.start), 12)
    XCTAssertEqual(
      sunday.component(.day, from: sunday.dateInterval(of: .weekOfYear, for: oct)!.start), 11)
    XCTAssertEqual(CalendarMath.weekdayLetters(calendar: monday).first, "M")
    XCTAssertEqual(CalendarMath.weekdayLetters(calendar: sunday).first, "S")
  }

  // MARK: Calendar start

  func testCalendarStartPicksAViewOrTheLastUsedOne() {
    XCTAssertEqual(Preferences.CalendarStart.lastUsed.view(lastUsed: "Month"), "Month")
    XCTAssertEqual(
      Preferences.CalendarStart.lastUsed.view(lastUsed: nil), "TwoDay",
      "2 Day the very first time")
    XCTAssertEqual(Preferences.CalendarStart.year.view(lastUsed: "Month"), "Year")
    XCTAssertEqual(Preferences.CalendarStart.twoDay.view(lastUsed: "Year"), "TwoDay")
    XCTAssertEqual(
      Preferences.CalendarStart(stored: "garbage"), .lastUsed,
      "an unknown value falls back to the default")
  }

  /// The 7-day Week and then 3 Day grids became 2 Day: an install that chose one of them is back on Last used.
  func testRetiredGridChoicesFallBackToLastUsed() {
    let d = freshDefaults()
    for retired in ["week", "threeDay"] {
      d.set(retired, forKey: Preferences.calendarStartKey)
      XCTAssertEqual(Preferences.calendarStartChoice(d), .lastUsed, retired)
    }
    XCTAssertEqual(Preferences.CalendarStart(stored: "month"), .month)
    XCTAssertEqual(
      Preferences.CalendarStart.allCases.map(\.title), ["Last used", "2 Day", "Month", "Year"])
  }

  // MARK: Default list

  func testDefaultListIsUsedOnlyWhileItExists() {
    let d = freshDefaults()
    d.set("Work", forKey: Preferences.newReminderListKey)
    XCTAssertEqual(Preferences.newReminderList(existing: ["Inbox", "Work"], d), "Work")
    XCTAssertNil(
      Preferences.newReminderList(existing: ["Inbox"], d), "a deleted list falls back to Auto")
    d.set("", forKey: Preferences.newReminderListKey)
    XCTAssertNil(Preferences.newReminderList(existing: ["Inbox", "Work"], d), "Auto")
  }

  // MARK: Alarms

  func testNewAlarmDefaultsAreChosenOrSnapped() {
    let d = freshDefaults()
    d.set(15, forKey: Preferences.newAlarmSnoozeKey)
    d.set("Marimba", forKey: Preferences.newAlarmSoundKey)
    XCTAssertEqual(Preferences.newAlarmSnoozeMinutes(d), 15)
    XCTAssertEqual(Preferences.newAlarmSoundName(d), "Marimba")
    d.set(20, forKey: Preferences.newAlarmSnoozeKey)
    XCTAssertEqual(
      Preferences.newAlarmSnoozeMinutes(d), 15,
      "a length that is not offered snaps to the nearest one")
  }

  func testNotificationSoundFollowsKindThenOwnThenSettings() {
    let d = freshDefaults()
    XCTAssertEqual(Preferences.notificationSoundName(isEvent: true, own: nil, d), "")
    XCTAssertEqual(Preferences.notificationSoundName(isEvent: false, own: nil, d), "")
    d.set("Heads Up", forKey: Preferences.eventSoundKey)
    d.set("Ping", forKey: Preferences.reminderSoundKey)
    XCTAssertEqual(Preferences.notificationSoundName(isEvent: true, own: "Pluck", d), "Heads Up")
    XCTAssertEqual(Preferences.notificationSoundName(isEvent: false, own: nil, d), "Ping")
    XCTAssertEqual(Preferences.notificationSoundName(isEvent: false, own: "", d), "Ping")
    XCTAssertEqual(Preferences.notificationSoundName(isEvent: false, own: "Pluck", d), "Pluck")
  }

  func testReminderInterruptionDefaultsAndFallbacks() {
    XCTAssertEqual(Preferences.reminderInterruption(stored: nil), .breakThroughFocus)
    XCTAssertEqual(Preferences.reminderInterruption(stored: "retired"), .breakThroughFocus)
    XCTAssertEqual(Preferences.reminderInterruption(stored: "standard"), .standard)
    XCTAssertEqual(Preferences.reminderInterruption(stored: "off"), .off)
    XCTAssertEqual(
      Preferences.reminderInterruption(stored: Preferences.reminderInterruption),
      .breakThroughFocus)
  }

  func testReminderDeliveryFollowsTheChoiceExceptTheAlarmFallback() {
    XCTAssertEqual(
      ReminderPlan.delivery(.breakThroughFocus, isAlarmFallback: false), .timeSensitive)
    XCTAssertEqual(ReminderPlan.delivery(.standard, isAlarmFallback: false), .active)
    XCTAssertEqual(ReminderPlan.delivery(.off, isAlarmFallback: false), .skip)
    for choice in Preferences.ReminderInterruption.allCases {
      XCTAssertEqual(ReminderPlan.delivery(choice, isAlarmFallback: true), .timeSensitive)
    }
  }

  func testAIChangesDefaultsAndFallbacks() {
    XCTAssertEqual(Preferences.aiChanges(stored: nil), .applyDirectly)
    XCTAssertEqual(Preferences.aiChanges(stored: "retired"), .applyDirectly)
    XCTAssertEqual(Preferences.aiChanges(stored: Preferences.aiChanges), .applyDirectly)
    XCTAssertEqual(Preferences.aiChanges(stored: "previewFirst"), .previewFirst)
  }
}
