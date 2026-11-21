import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// The one-time import of the Clock app's alarms: the repeat text a Shortcut hands over, and the staging list the
/// Clock tab reads (nothing is set until the user taps Add).
final class AlarmImportTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite = ""

  override func setUp() {
    suite = "AlarmImportTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
  }

  func testRepeatTextInEnglishAndChinese() {
    let cases: [(String?, [Int])] = [
      (nil, []), ("Never", []), ("永不", []),
      ("Every Day", Array(1...7)), ("每天", Array(1...7)),
      ("Weekdays", [2, 3, 4, 5, 6]), ("工作日", [2, 3, 4, 5, 6]),
      ("Weekends", [1, 7]), ("周末", [1, 7]),
      ("Every Monday", [2]), ("Mon, Wed, Fri", [2, 4, 6]), ("Tuesday Thursday", [3, 5]),
      ("周一、周三", [2, 4]), ("星期天", [1]), ("something else", []),
    ]
    for (text, days) in cases {
      XCTAssertEqual(AlarmImport.weekdays(fromRepeat: text), days, text ?? "nil")
    }
  }

  func testStagingSkipsRepeatsAndRemoves() {
    let wake = AlarmImport.Staged(hour: 7, minute: 0, label: "Wake", weekdays: [2, 3], isOn: true)
    XCTAssertTrue(AlarmImport.stage(wake, defaults))
    let again = AlarmImport.Staged(
      hour: 7, minute: 0, label: "Other", weekdays: [3, 2], isOn: false)
    XCTAssertFalse(
      AlarmImport.stage(again, defaults), "same time and days: running twice is harmless")
    let nap = AlarmImport.Staged(hour: 13, minute: 30, label: "", weekdays: [], isOn: true)
    XCTAssertTrue(AlarmImport.stage(nap, defaults))
    XCTAssertEqual(AlarmImport.staged(defaults), [wake, nap])
    AlarmImport.remove([wake.id], defaults)
    XCTAssertEqual(AlarmImport.staged(defaults), [nap])
    AlarmImport.save([], defaults)
    XCTAssertEqual(AlarmImport.staged(defaults), [])
    XCTAssertNil(defaults.data(forKey: AlarmImport.stagedKey), "Skip leaves nothing behind")
  }

  func testStagingStopsAtTheLimit() {
    for i in 0..<(AlarmImport.limit + 5) {
      AlarmImport.stage(
        .init(hour: i / 60, minute: i % 60, label: "", weekdays: [], isOn: true), defaults)
    }
    XCTAssertEqual(AlarmImport.staged(defaults).count, AlarmImport.limit)
  }
}
