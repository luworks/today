import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// Edit or capture? An edit is only read when the sentence points at an item that exists; otherwise the message is a new item.
/// Regression: "请把我可以卖的东西都放到车库去，然后今天下午 3 点的时候提醒我移动一下" matched an event only because it
/// starts at 15:00, and the clarification "…今天下午 3 点提醒我吧" then became a ChangeCard for an existing item.
final class EditRoutingTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()
  /// Saturday 2026-10-17, 09:00
  lazy var now = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9))!

  private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
  }

  private lazy var items: [EditItem] = [
    EditItem(
      id: "e1", type: "event", title: "Product sync", start: at(17, 15), minutes: 30, attendees: 3),
    EditItem(
      id: "e2", type: "event", title: "Dentist", start: at(18, 10), minutes: 60, attendees: 0),
    EditItem(
      id: "t1", type: "task", title: "Buy milk", start: at(17, 16, 30), minutes: 15, attendees: 0),
    EditItem(
      id: "t2", type: "task", title: "Marketplace pickup", start: nil, minutes: 30, attendees: 0),
  ]

  private func isEdit(_ text: String) -> Bool {
    FastLane.looksLikeEdit(text, items: items, now: now, calendar: cal)
  }

  // MARK: The reported conversation

  let first = "请把我可以卖的东西都放到车库去，然后今天下午 3 点的时候提醒我移动一下"
  let clarification = "哦，我想卖家里的一些东西，然后去 Marketplace。今天下午 3 点提醒我吧"

  func testFirstSentenceIsNotAnEditEvenThoughAnEventStartsAt3pm() {
    XCTAssertFalse(isEdit(first))
    XCTAssertEqual(
      Editing.decide(text: first, plan: nil, items: items, now: now, calendar: cal).op, .none)
  }

  func testClarificationIsNotAnEdit() {
    XCTAssertFalse(isEdit(clarification))
    XCTAssertEqual(
      Editing.decide(text: clarification, plan: nil, items: items, now: now, calendar: cal).op,
      .none)
  }

  func testClarificationIsNotAnAnswerToWhichOne() {
    // "Marketplace" is also a word in one option's title: the old loose match took the reply as picking that option.
    let titles = items.map(\.title)
    XCTAssertEqual(
      Dialogue.pick(clarification, from: titles), 3, "the loose match that caused the bug")
    XCTAssertNil(Dialogue.answerToWhichOne(clarification, from: titles))
    // Even without "提醒我", telling a story ("我想 ...") does not pick an option by one overlapping word.
    XCTAssertNil(Dialogue.answerToWhichOne("我想把东西拿去 Marketplace 卖掉", from: titles))
  }

  func testClarificationBecomesAReminderToday3pm() {
    let c = CaptureParser.parse(clarification, now: now, calendar: cal)
    XCTAssertEqual(c.hour, 15)
    XCTAssertEqual(c.minute, 0)
    XCTAssertTrue(c.hasDay)
    XCTAssertEqual(c.day, cal.startOfDay(for: now))
    XCTAssertEqual(c.kind, .task)
    XCTAssertFalse(c.ringsAsAlarm)
    XCTAssertTrue(c.title.contains("Marketplace"), "the title keeps what to do: \(c.title)")
    XCTAssertFalse(c.title.contains("下午"), "the time is not in the title: \(c.title)")
  }

  // MARK: A clock time alone names no item

  func testPlacementWithATimeIsNotAnEdit() {
    XCTAssertFalse(isEdit("把东西放到车库，下午3点"))
    XCTAssertFalse(isEdit("Put the boxes in the garage at 3pm"))
  }

  func testRemindMeAtAnItemsTimeIsNew() {
    XCTAssertFalse(isEdit("Remind me to call Sam at 3pm"))
    XCTAssertFalse(isEdit("下午3点提醒我给妈妈打电话"))
    XCTAssertFalse(
      isEdit("Remind me to move the car at 3pm"), "\"move\" is part of the new reminder")
    XCTAssertFalse(isEdit("提醒我明天把车挪一下"))
  }

  // MARK: Real edits still work

  func testWordsThatNameAnItemStillEdit() {
    XCTAssertTrue(isEdit("取消 Buy milk"))
    XCTAssertTrue(isEdit("把牙医推迟一小时"))
    XCTAssertTrue(isEdit("Move the dentist to 4pm"))
    XCTAssertTrue(isEdit("Delete Buy milk"))
  }

  func testPronounAndEverythingStillEdit() {
    XCTAssertTrue(isEdit("Move it to 5pm"))
    XCTAssertTrue(isEdit("把它推迟半小时"))
    XCTAssertTrue(isEdit("Push everything back an hour"))
  }

  func testMeetingWordStillEdits() {
    XCTAssertTrue(isEdit("Move the meeting back an hour"))
    XCTAssertTrue(isEdit("把会议推迟一小时"))
  }

  func testAnItemNamedByItsTimeStillEdits() {
    XCTAssertTrue(isEdit("三点那个改到四点半"), "the time before the destination names the item")
    XCTAssertTrue(isEdit("Move the 3pm one to 4"))
    XCTAssertTrue(isEdit("move the 3pm to 4pm"))
    let d = Editing.decide(text: "三点那个改到四点半", plan: nil, items: items, now: now, calendar: cal)
    XCTAssertEqual(d.op, .move)
    XCTAssertEqual(d.target, "e1")
    XCTAssertEqual(d.newStart, at(17, 16, 30))
  }

  func testNamingAnItemInAReminderRequestIsStillAnEdit() {
    // The words name "Dentist": that is a reschedule, not a new reminder.
    XCTAssertTrue(isEdit("Remind me to move the dentist to 4pm"))
    XCTAssertTrue(isEdit("把牙医改到下午4点，提醒我"))
  }

  /// New items whose wording contains an edit-like verb (change, update, move, 安排在, 开会): the same bug class.
  func testNewItemsWithEditLikeVerbsAreCaptures() {
    for s in [
      "Remind me to change the oil on Saturday",
      "Don't forget to update the slides",
      "提醒我周五把合同改一下",
      "Move the car at 3pm",
      "把车挪一下，下午3点",
      "Schedule a meeting with Alex on Friday at 2pm",
      "安排在周五下午3点开会",
    ] {
      XCTAssertFalse(isEdit(s), s)
    }
  }

  func testQuestionsAreNeverEdits() {
    XCTAssertFalse(isEdit("What's at 3pm?"))
    XCTAssertFalse(isEdit("下午3点有什么？"))
  }

  // MARK: Answering "which one?" still works

  func testRealAnswersStillPick() {
    let t = ["Product sync", "Design review", "Lunch with Priya"]
    XCTAssertEqual(Dialogue.answerToWhichOne("the first one", from: t), 0)
    XCTAssertEqual(Dialogue.answerToWhichOne("第二个", from: t), 1)
    XCTAssertEqual(Dialogue.answerToWhichOne("lunch", from: t), 2)
    XCTAssertEqual(Dialogue.answerToWhichOne("I want the second one", from: t), 1)
    XCTAssertEqual(Dialogue.answerToWhichOne("我想要 Design review", from: t), 1)
    XCTAssertNil(
      Dialogue.answerToWhichOne("remind me about lunch tomorrow", from: t), "a new request")
  }

  func testStartsNewItem() {
    for s in [
      "Remind me to pay rent", "提醒我明天交报告", "别忘了带伞", "Don't forget the keys",
      "add a reminder for Friday", "新建一个待办",
    ] {
      XCTAssertTrue(Dialogue.startsNewItem(s), s)
    }
    for s in ["Move it to 5pm", "取消 Buy milk", "第二个", "把会议推迟一小时"] {
      XCTAssertFalse(Dialogue.startsNewItem(s), s)
    }
  }
}
