import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// Add Alarm's quick picks and the defaults every new alarm starts with (Add Alarm, the chat and Siri share them).
final class AlarmQuickPicksTests: XCTestCase {
  private typealias Time = AlarmQuickPicks.Time

  func testNoHistoryOffersTheMorningFallbacks() {
    XCTAssertEqual(AlarmQuickPicks.times(history: []), AlarmQuickPicks.fallbackTimes)
  }

  func testMostUsedTimesComeFirstAndFallbacksFillTheRest() {
    let history = [
      Time(hour: 6, minute: 45), Time(hour: 22, minute: 0), Time(hour: 6, minute: 45),
    ]
    XCTAssertEqual(
      AlarmQuickPicks.times(history: history),
      [Time(hour: 6, minute: 45), Time(hour: 22, minute: 0), Time(hour: 6, minute: 30)])
  }

  func testATieGoesToTheEarlierTimeAndFallbacksAreNotRepeated() {
    let history = [Time(hour: 7, minute: 30), Time(hour: 7, minute: 0)]
    XCTAssertEqual(
      AlarmQuickPicks.times(history: history),
      [Time(hour: 7, minute: 0), Time(hour: 7, minute: 30), Time(hour: 6, minute: 30)])
  }

  func testLabelsAreMostUsedTrimmedAndSkipBlankAndDefault() {
    let history = ["起床", " Gym ", "", "Alarm", "gym", "吃药", "起床", "起床"]
    XCTAssertEqual(AlarmQuickPicks.labels(history: history), ["起床", "Gym", "吃药"])
    XCTAssertEqual(AlarmQuickPicks.labels(history: ["", "Alarm", "  "]), [])
  }

  func testInMinutesCrossesMidnight() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23, minute: 50))!
    XCTAssertEqual(
      AlarmQuickPicks.time(inMinutes: 20, from: now, calendar: cal), Time(hour: 0, minute: 10))
  }

  func testRepeatPresetsMatchClockWording() {
    XCTAssertEqual(AlarmQuickPicks.RepeatPreset.weekdays.title, "Weekdays")
    XCTAssertEqual(AlarmQuickPicks.RepeatPreset.weekends.title, "Weekends")
    XCTAssertEqual(AlarmQuickPicks.RepeatPreset.everyDay.title, "Every day")
    XCTAssertEqual(AlarmQuickPicks.RepeatPreset.matching([2, 3, 4, 5, 6]), .weekdays)
    XCTAssertNil(AlarmQuickPicks.RepeatPreset.matching([2, 3]))
  }

  func testNewAlarmDefaultsFollowSettings() {
    let name = "AlarmQuickPicksTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    XCTAssertEqual(
      AlarmPlan.newAlarmDefaults(defaults),
      .init(snooze: true, snoozeMinutes: AlarmPlan.defaultSnoozeMinutes, sound: ""))
    defaults.set(15, forKey: Preferences.newAlarmSnoozeKey)
    defaults.set("Daybreak", forKey: Preferences.newAlarmSoundKey)
    XCTAssertEqual(
      AlarmPlan.newAlarmDefaults(defaults),
      .init(snooze: true, snoozeMinutes: 15, sound: "Daybreak")
    )
  }

  func testAChangedSoundIsRememberedForTheNextNewAlarm() {
    let name = "AlarmQuickPicksTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }

    AlarmPlan.rememberSound(saved: "Marimba", opened: "", defaults)
    XCTAssertEqual(AlarmPlan.newAlarmDefaults(defaults).sound, "Marimba")

    AlarmPlan.rememberSound(saved: "", opened: "Marimba", defaults)
    XCTAssertEqual(AlarmPlan.newAlarmDefaults(defaults).sound, "", "Default is a choice too")
    XCTAssertNotNil(defaults.string(forKey: Preferences.newAlarmSoundKey))
  }

  func testSavingAnUntouchedSoundKeepsTheRememberedOne() {
    let name = "AlarmQuickPicksTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("Daybreak", forKey: Preferences.newAlarmSoundKey)

    AlarmPlan.rememberSound(saved: "Marimba", opened: "Marimba", defaults)

    XCTAssertEqual(
      AlarmPlan.newAlarmDefaults(defaults).sound, "Daybreak",
      "editing an old alarm's time must not make its sound the default")
  }
}
