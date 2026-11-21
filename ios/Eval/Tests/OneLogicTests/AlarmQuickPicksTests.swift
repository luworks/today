import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// Add Alarm's quick picks and the defaults every new alarm starts with (Add Alarm, the chat and Siri share them).
final class AlarmQuickPicksTests: XCTestCase {
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
