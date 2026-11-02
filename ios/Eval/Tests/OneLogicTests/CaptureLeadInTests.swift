import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// "帮我增加一个 reminder 吧：我需要…" is an instruction to the app; the title is what the user wrote after it.
final class CaptureLeadInTests: XCTestCase {
  var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return c
  }()

  func title(_ s: String) -> String { CaptureParser.parse(s, now: .now, calendar: cal).title }

  // MARK: The reported line

  func testReportedLineKeepsTheUsersWordsAfterTheColon() {
    let line = "今天晚上 10 点帮我增加一个 reminder 吧：我需要去扩充我们这个 token factory 工厂的 token"
    XCTAssertEqual(title(line), "我需要去扩充我们这个 token factory 工厂的 token")
    let c = CaptureParser.parse(line, now: .now, calendar: cal)
    XCTAssertEqual(c.hour, 22)
    XCTAssertEqual(c.kind, .task)
  }

  // MARK: Chinese lead-ins

  func testChineseLeadInsWithPunctuationAndParticles() {
    let cases: [(String, String)] = [
      ("帮我增加一个 reminder 吧：我需要去扩充 token", "我需要去扩充 token"),
      ("帮我增加一个reminder吧: 买牛奶", "买牛奶"),
      ("帮我加个提醒：交报销单", "交报销单"),
      ("帮我加个提醒，交报销单", "交报销单"),
      ("帮我加一个提醒呀，交报销单", "交报销单"),
      ("增加一个提醒，交报销单", "交报销单"),
      ("请帮我添加一条提醒啊：交报销单", "交报销单"),
      ("帮我新建一个待办：写周报", "写周报"),
      ("提醒我：交报销单", "交报销单"),
      ("提醒我，交报销单", "交报销单"),
      ("请提醒我：我要去开会", "我要去开会"),
      ("增加提醒：交报销单", "交报销单"),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(CaptureLeadIn.strip(input), expected, input)
    }
  }

  func testWordingAfterTheLeadInIsKept() {
    // The user's own "我需要" / "我要" stays; only the lead-in goes.
    XCTAssertEqual(title("帮我加个提醒：我要去银行"), "我要去银行")
    XCTAssertEqual(title("提醒我：我需要买牛奶"), "我需要买牛奶")
  }

  func testChineseLeadInWithoutPunctuationWhenItNamesTheThing() {
    XCTAssertEqual(CaptureLeadIn.strip("帮我加个提醒交报销单"), "交报销单")
  }

  // MARK: English lead-ins

  func testEnglishLeadIns() {
    let cases: [(String, String)] = [
      ("add a reminder to call mom", "call mom"),
      ("Add a reminder: call mom", "call mom"),
      ("please add a reminder to call mom", "call mom"),
      ("can you please set a reminder for the dentist", "the dentist"),
      ("create a new reminder, buy milk", "buy milk"),
      ("make a to-do that I need to pay rent", "I need to pay rent"),
      ("reminder: call mom", "call mom"),
      ("todo: call mom", "call mom"),
      ("please remind me: call mom", "call mom"),
      ("remind me, call mom", "call mom"),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(CaptureLeadIn.strip(input), expected, input)
    }
  }

  func testPlainRemindMeStillWorksThroughTheOrdinaryFillers() {
    XCTAssertEqual(title("please remind me to call mom tomorrow at 9am"), "call mom")
    XCTAssertEqual(title("add a reminder to call mom tomorrow at 9am"), "call mom")
    XCTAssertEqual(title("提醒我给妈妈打电话"), "给妈妈打电话")
  }

  // MARK: Titles that only look similar stay as they are

  func testNormalTitlesAreNotDamaged() {
    for s in [
      "增加库存提醒", "加个餐", "提醒事项整理", "设置闹钟的方法", "新建文件夹", "add a task force meeting",
      "Reminder system design review", "task list cleanup", "todo app launch plan",
      "remind me later page",
    ] {
      XCTAssertNil(CaptureLeadIn.strip(s), s)
    }
    XCTAssertEqual(title("增加库存提醒"), "增加库存提醒")
    XCTAssertEqual(title("Reminder system design review"), "Reminder system design review")
  }

  func testNothingLeftKeepsTheOriginal() {
    XCTAssertNil(CaptureLeadIn.strip("帮我加个提醒："))
    XCTAssertNil(CaptureLeadIn.strip("add a reminder"))
  }

  // MARK: The model's title

}
