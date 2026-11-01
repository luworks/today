import TodayTestSupport
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

  func testDefaultsAreWhatTheAppDidBefore() {
    XCTAssertTrue(Preferences.dimPastDays, "past days were dimmed")
    XCTAssertEqual(Preferences.firstWeekday, .system, "weeks followed the device")
    XCTAssertFalse(Preferences.weekNumbers)
    XCTAssertEqual(
      Preferences.calendarStart, .lastUsed, "Calendar reopened in the view it was left in")
    XCTAssertTrue(Preferences.showFreeTime)
    XCTAssertEqual(Preferences.newReminderList, "", "Auto: nothing was filed by a chosen list")
    XCTAssertEqual(Preferences.newAlarmSnooze, 9, "Clock's nine minutes")
    XCTAssertEqual(Preferences.newAlarmSound, "", "the system alarm sound")
    XCTAssertTrue(Preferences.askSuggestions)
    XCTAssertFalse(Preferences.weatherSummary)
  }

  func testCompressEmptyHoursDefaultsOnAndPreservesExplicitChoice() {
    let d = freshDefaults()
    XCTAssertTrue(
      d.object(forKey: Preferences.compressEmptyHoursKey) as? Bool
        ?? Preferences.compressEmptyHours)
    d.set(false, forKey: Preferences.compressEmptyHoursKey)
    LaunchTestConfiguration.applyPreferenceOverrides(arguments: [], defaults: d)
    XCTAssertEqual(d.object(forKey: Preferences.compressEmptyHoursKey) as? Bool, false)
    LaunchTestConfiguration.applyPreferenceOverrides(
      arguments: ["-uiTesting", "-uiTestingKeepPreferences"], defaults: d)
    XCTAssertEqual(d.object(forKey: Preferences.compressEmptyHoursKey) as? Bool, false)
  }

  func testEmptyDefaultsReadAsTheDefaults() {
    let d = freshDefaults()
    XCTAssertEqual(Preferences.firstWeekdayChoice(d), .system)
    XCTAssertEqual(Preferences.calendarStartChoice(d), .lastUsed)
    XCTAssertNil(Preferences.newReminderList(existing: ["Inbox", "Work"], d))
    XCTAssertEqual(Preferences.newAlarmSnoozeMinutes(d), 9)
    XCTAssertEqual(Preferences.newAlarmSoundName(d), "")
  }

  func testFocusVisibilityDefaultsAndExplicitPreferencesSurviveRelaunch() {
    let d = freshDefaults()
    XCTAssertEqual(
      d.object(forKey: Preferences.showSettleKey) as? Bool ?? Preferences.showSettle, true)
    d.set(false, forKey: Preferences.showSettleKey)
    LaunchTestConfiguration.applyPreferenceOverrides(arguments: [], defaults: d)
    XCTAssertEqual(d.object(forKey: Preferences.showSettleKey) as? Bool, false)
    LaunchTestConfiguration.applyPreferenceOverrides(
      arguments: ["-uiTesting", "-uiTestingKeepPreferences"], defaults: d)
    XCTAssertEqual(d.object(forKey: Preferences.showSettleKey) as? Bool, false)
    LaunchTestConfiguration.applyPreferenceOverrides(
      arguments: ["-uiTesting", "-uiTestingPrefs", "showSettle=1"], defaults: d)
    XCTAssertEqual(d.object(forKey: Preferences.showSettleKey) as? Bool, true)
  }

  func testEveryKeyIsListedOnceAndSharesThePrefix() {
    XCTAssertEqual(Set(Preferences.allKeys).count, Preferences.allKeys.count)
    XCTAssertTrue(Preferences.allKeys.allSatisfy { $0.hasPrefix("today.setting.") })
  }

  // MARK: First day of the week

  func testSystemLeavesTheCalendarAlone() {
    var monday = cal
    monday.firstWeekday = 2
    XCTAssertEqual(Preferences.FirstWeekday.system.calendar(base: monday).firstWeekday, 2)
    XCTAssertEqual(
      Preferences.FirstWeekday.system.calendar(base: cal).firstWeekday, cal.firstWeekday)
  }

  func testSundayAndMondayOverrideTheSystemWeek() {
    XCTAssertEqual(Preferences.FirstWeekday.sunday.calendar(base: cal).firstWeekday, 1)
    XCTAssertEqual(Preferences.FirstWeekday.monday.calendar(base: cal).firstWeekday, 2)
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
      monday.component(.day, from: CalendarMath.weekStart(of: oct, calendar: monday)), 12)
    XCTAssertEqual(
      sunday.component(.day, from: CalendarMath.weekStart(of: oct, calendar: sunday)), 11)
    XCTAssertEqual(CalendarMath.weekdayLetters(calendar: monday).first, "M")
    XCTAssertEqual(CalendarMath.weekdayLetters(calendar: sunday).first, "S")
  }

  func testWeekNumberFollowsTheCalendar() {
    let monday = Preferences.FirstWeekday.monday.calendar(base: cal)
    XCTAssertEqual(
      CalendarMath.weekNumber(of: date(14, 12), calendar: monday),
      monday.component(.weekOfYear, from: date(14, 12)))
    XCTAssertEqual(
      CalendarMath.weekNumber(of: date(12, 12), calendar: monday),
      CalendarMath.weekNumber(of: date(18, 12), calendar: monday),
      "every day of one row has the same number")
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

  // MARK: UI test launch

  func testUITestingStartsFromTheDefaultsAndAppliesRequestedValues() {
    let d = freshDefaults()
    d.set(false, forKey: Preferences.dimPastDaysKey)
    d.set("monday", forKey: Preferences.firstWeekdayKey)
    LaunchTestConfiguration.applyPreferenceOverrides(
      arguments: [
        "-uiTesting", "-uiTestingPrefs", "weekNumbers=1,firstWeekday=sunday,bogus=1",
      ], defaults: d)
    XCTAssertNil(d.object(forKey: Preferences.dimPastDaysKey), "reset")
    XCTAssertEqual(d.bool(forKey: Preferences.weekNumbersKey), true)
    XCTAssertEqual(d.string(forKey: Preferences.firstWeekdayKey), "sunday")
    XCTAssertNil(d.object(forKey: "today.setting.bogus"), "unknown keys are ignored")
  }

  func testARealLaunchLeavesThePreferencesAlone() {
    let d = freshDefaults()
    d.set(false, forKey: Preferences.dimPastDaysKey)
    LaunchTestConfiguration.applyPreferenceOverrides(arguments: [], defaults: d)
    XCTAssertEqual(d.bool(forKey: Preferences.dimPastDaysKey), false)
    LaunchTestConfiguration.applyPreferenceOverrides(
      arguments: ["-uiTesting", "-uiTestingKeepPreferences"], defaults: d)
    XCTAssertEqual(
      d.bool(forKey: Preferences.dimPastDaysKey), false,
      "the relaunch check keeps what the first launch saved")
  }
}
