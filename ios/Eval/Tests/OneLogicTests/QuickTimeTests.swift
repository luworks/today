import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class QuickTimeTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()
  // Friday 16 Oct 2026, 22:17
  lazy var now = cal.date(
    from: DateComponents(year: 2026, month: 10, day: 16, hour: 22, minute: 17))!

  private func parts(_ d: Date) -> DateComponents {
    cal.dateComponents([.month, .day, .hour, .minute], from: d)
  }

  func testStartsAtTheNextQuarterHour() {
    XCTAssertEqual(
      parts(QuickTime.start(now: now, calendar: cal)),
      DateComponents(month: 10, day: 16, hour: 22, minute: 30))
  }

  func testPresetDefaultsAreTheShippedFour() {
    for stored in [nil, "", "570,720", "570,720,1110,1320,60", "570,720,1110,1440", "a,b,c,d"] {
      XCTAssertEqual(QuickTime.presetMinutes(stored: stored), [570, 720, 1110, 1320])
    }
  }

  func testChosenPresetsShowEarliestFirst() {
    let shown = QuickTime.presets(stored: "1320,450,720,1110")
    XCTAssertEqual(shown.map(\.hour), [7, 12, 18, 22])
    XCTAssertEqual(shown.map(\.minute), [30, 0, 30, 0])
  }

  func testPresetsRoundTripThroughStorage() {
    let minutes = [1320, 450, 720, 1110]
    XCTAssertEqual(QuickTime.presetMinutes(stored: QuickTime.storedPresets(minutes)), minutes)
  }

  func testAPastPresetMovesToTomorrow() {
    XCTAssertEqual(
      parts(QuickTime.preset(hour: 9, minute: 30, on: now, now: now, calendar: cal)),
      DateComponents(month: 10, day: 17, hour: 9, minute: 30))
    XCTAssertEqual(
      parts(QuickTime.preset(hour: 22, minute: 0, on: now, now: now, calendar: cal)),
      DateComponents(month: 10, day: 17, hour: 22, minute: 0))
    let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
    XCTAssertEqual(
      parts(QuickTime.preset(hour: 12, minute: 0, on: tomorrow, now: now, calendar: cal)),
      DateComponents(month: 10, day: 17, hour: 12, minute: 0), "a future day keeps the preset as is"
    )
  }

  func testDuePresetRetainsSelectedDayEvenWhenPast() {
    XCTAssertEqual(
      parts(QuickTime.presetOnSelectedDay(hour: 9, minute: 30, on: now, calendar: cal)),
      DateComponents(month: 10, day: 16, hour: 9, minute: 30))
    let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
    XCTAssertEqual(
      parts(QuickTime.presetOnSelectedDay(hour: 12, minute: 0, on: yesterday, calendar: cal)),
      DateComponents(month: 10, day: 15, hour: 12, minute: 0))
  }

  func testRepeatLabelsFollowSelectedDate() {
    let locale = Locale(identifier: "en_US")
    XCTAssertEqual(
      QuickTime.repeatLabel(.daily, date: now, calendar: cal, locale: locale), "Daily 22:17")
    XCTAssertEqual(
      QuickTime.repeatLabel(.weekly, date: now, calendar: cal, locale: locale), "Fridays 22:17")
    XCTAssertEqual(
      QuickTime.repeatLabel(.monthly, date: now, calendar: cal, locale: locale),
      "16th each month at 22:17")
    XCTAssertEqual(
      QuickTime.repeatLabel(.yearly, date: now, calendar: cal, locale: locale),
      "Every Oct 16 at 22:17")
  }

  func testNudges() {
    XCTAssertEqual(
      parts(QuickTime.nudge(now, minutes: 10, calendar: cal)),
      DateComponents(month: 10, day: 16, hour: 22, minute: 27))
    XCTAssertEqual(
      parts(QuickTime.nudge(now, minutes: -1440, calendar: cal)),
      DateComponents(month: 10, day: 15, hour: 22, minute: 17))
    XCTAssertEqual(QuickTime.nudgeLabel(180), "+3 hr")
    XCTAssertEqual(QuickTime.nudgeLabel(-10), "−10 min")
    XCTAssertEqual(QuickTime.nudgeLabel(1440), "+1 day")
  }

  func testDayNudgesKeepWallTimeAcrossDSTAndMinuteNudgesCrossMidnight() {
    var local = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    for day in [
      DateComponents(year: 2026, month: 3, day: 7, hour: 12),
      DateComponents(year: 2026, month: 10, day: 31, hour: 12),
    ] {
      let before = local.date(from: day)!
      let after = QuickTime.nudge(before, minutes: 1440, calendar: local)
      XCTAssertEqual(local.component(.hour, from: after), 12)
      XCTAssertEqual(local.dateComponents([.day], from: before, to: after).day, 1)
      XCTAssertEqual(QuickTime.nudge(after, minutes: -1440, calendar: local), before)
    }
    let late = cal.date(bySettingHour: 23, minute: 55, second: 0, of: now)!
    XCTAssertEqual(
      parts(QuickTime.nudge(late, minutes: 10, calendar: cal)),
      DateComponents(month: 10, day: 17, hour: 0, minute: 5))
  }

  func testDaysKeepTheTime() {
    let nine = cal.date(bySettingHour: 9, minute: 30, second: 0, of: now)!
    XCTAssertEqual(
      parts(QuickTime.move(nine, to: .tomorrow, now: now, calendar: cal)),
      DateComponents(month: 10, day: 17, hour: 9, minute: 30))
    XCTAssertEqual(
      parts(QuickTime.move(nine, to: .weekend, now: now, calendar: cal)),
      DateComponents(month: 10, day: 17, hour: 9, minute: 30),
      "Friday: the weekend starts tomorrow")
    XCTAssertEqual(
      parts(QuickTime.move(nine, to: .nextWeek, now: now, calendar: cal)),
      DateComponents(month: 10, day: 19, hour: 9, minute: 30))
  }

  func testRelativeText() {
    XCTAssertEqual(QuickTime.relative(now, now: now), "Now")
    XCTAssertEqual(QuickTime.relative(now.addingTimeInterval(25 * 60), now: now), "in 25 min")
    XCTAssertEqual(QuickTime.relative(now.addingTimeInterval(150 * 60), now: now), "in 2 hr 30 min")
    XCTAssertEqual(QuickTime.relative(now.addingTimeInterval(-10 * 60), now: now), "10 min ago")
    XCTAssertEqual(QuickTime.relative(now.addingTimeInterval(3 * 86_400), now: now), "in 3 days")
  }
}
