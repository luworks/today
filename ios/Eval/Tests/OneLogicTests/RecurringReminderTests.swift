import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class RecurringReminderTests: XCTestCase {
  private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }
  private var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9))! }

  func testExactOwnerRequestsPreserveTitleTimeAndAllWeekdays() throws {
    for (text, days) in [
      ("每周日下午5点提醒我丢垃圾", [1]),
      ("添加一个reminder：每周五、每周日下午5点提醒我丢垃圾", [1, 6]),
      ("每周五和周日下午五点提醒我丢垃圾", [1, 6]),
      ("添加一个 reminder：每周五、每周日下午 5 点提醒我丢垃圾", [1, 6]),
      ("Every Friday and Sunday at 5pm remind me to take out trash", [1, 6]),
    ] {
      XCTAssertEqual(ChatRouting.intent(text), .capture, text)
      let c = CaptureConversation.parse(text, now: now, calendar: cal)
      XCTAssertEqual(c.title, text.contains("每") ? "丢垃圾" : "take out trash", text)
      XCTAssertEqual(c.kind, .task, text)
      XCTAssertFalse(c.ringsAsAlarm, text)
      XCTAssertEqual(c.hour, 17, text)
      XCTAssertEqual(c.minute, 0, text)
      XCTAssertEqual(c.repeatRule, RepeatRule.weeklyOn(days).rawValue, text)
      XCTAssertEqual(cal.component(.weekday, from: c.day), 1, text)
      let restored = try JSONDecoder().decode(Capture.self, from: JSONEncoder().encode(c))
      XCTAssertEqual(restored, c, "Stored chat must retain the entire recurrence")
    }
  }

  func testWeekdaysWeekendAndPassedOccurrenceStayInTheirSets() {
    let weekday = CaptureConversation.parse("每个工作日中午12点提醒我带午饭", now: now, calendar: cal)
    XCTAssertEqual(ChatRouting.intent("每个工作日中午12点提醒我带午饭"), .capture)
    XCTAssertEqual(weekday.kind, .task)
    XCTAssertEqual(weekday.title, "带午饭")
    XCTAssertEqual(cal.component(.weekday, from: weekday.day), 2)
    XCTAssertEqual(weekday.repeatRule, "weekdays")
    let weekend = CaptureParser.parse(
      "Remind me every weekend at 10am to water plants", now: now, calendar: cal)
    XCTAssertEqual(weekend.repeatRule, "weekly:1,7")
    XCTAssertEqual(weekend.title, "water plants")
    let later = now.addingTimeInterval(10 * 3600)
    let passed = CaptureParser.parse("每周五、每周日下午5点提醒我丢垃圾", now: later, calendar: cal)
    XCTAssertEqual(cal.component(.weekday, from: passed.day), 6)
    XCTAssertEqual(passed.hour, 17)
  }

  func testAddingRecurrenceAndCorrectingTimeKeepUntouchedFields() throws {
    let initial = CaptureConversation.parse(
      "Remind me to brush the dog today at 4pm", now: now, calendar: cal)
    guard
      case .updated(let repeated) = Dialogue.refine(
        initial, with: "Make that repeat every Thursday and Sunday, keeping 4pm.", now: now,
        calendar: cal)
    else {
      return XCTFail("Adding recurrence should update the open preview")
    }
    XCTAssertEqual(repeated.title, initial.title)
    XCTAssertEqual(repeated.repeatRule, "weekly:1,5")
    XCTAssertEqual(repeated.hour, 16)
    guard
      case .updated(let corrected) = Dialogue.refine(
        repeated, with: "Actually, 6pm.", now: now, calendar: cal)
    else {
      return XCTFail("Time correction should update the open preview")
    }
    XCTAssertEqual(corrected.title, initial.title)
    XCTAssertEqual(corrected.repeatRule, repeated.repeatRule)
    XCTAssertEqual(corrected.day, repeated.day)
    XCTAssertEqual(corrected.hour, 18)
  }

  func testDiscussionQuotesReportsAndDeclinesStayConversation() {
    for text in [
      "不要创建每周六上午十点洗车的提醒，我只是拿这个当例子。",
      "为什么每周日下午五点倒垃圾比每天倒一次更合适？我只是想聊聊这个安排。",
      "我昨天已经设置了每周五和周日下午五点丢垃圾的提醒，今天只是告诉你这个安排。",
      "Can you explain the sentence \"Remind me every Friday and Sunday at 5pm to take out the trash\"?",
      "Every Sunday at 5pm I already set a reminder to take out trash.",
      "Every Sunday at 5pm don't create a reminder.",
    ] { XCTAssertEqual(ChatRouting.intent(text), .conversation, text) }
    let c = CaptureConversation.parse(
      "Remind me every Friday and Sunday at 5pm not to eat peanuts", now: now, calendar: cal)
    XCTAssertTrue(c.title.lowercased().contains("not"))
    XCTAssertTrue(c.title.lowercased().contains("peanuts"))
    XCTAssertEqual(c.repeatRule, "weekly:1,6")
  }

  private func developmentInputs(_ id: String) throws -> [String] {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<4 { root.deleteLastPathComponent() }
    let data = try Data(
      contentsOf: root.appendingPathComponent(
        "tests/fixtures/ai-title-rewrite-recurring-cases.json"))
    let suite = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cases = try XCTUnwrap(suite["cases"] as? [[String: Any]])
    let entry = try XCTUnwrap(
      cases.first { $0["id"] as? String == id && $0["split"] as? String == "development" })
    let turns = try XCTUnwrap(entry["turns"] as? [[String: Any]])
    return try turns.map { try XCTUnwrap($0["input"] as? String) }
  }

  func testObservedColloquialRecurringRequest() throws {
    let input = try XCTUnwrap(developmentInputs("recurring-rephrase-recycling-zh").first)
    XCTAssertEqual(ChatRouting.intent(input), .capture)
    let c = CaptureConversation.parse(input, now: now, calendar: cal)
    XCTAssertTrue(c.title.contains("把回收桶推到路边"))
    XCTAssertFalse(c.title.contains("的提醒"))
    XCTAssertTrue(c.notes?.contains("周六清晨会来收") == true)
    XCTAssertEqual(c.repeatRule, "weekly:6")
    XCTAssertEqual(c.kind, .task)
    XCTAssertEqual(c.hour, 18)
    XCTAssertEqual(cal.component(.weekday, from: c.day), 6)
    XCTAssertEqual(ChatRouting.intent("不要" + input), .conversation)
  }

  func testObservedChineseCorrectionRetainsBothWeekdays() throws {
    let inputs = try developmentInputs("recurring-time-correction-zh")
    let initial = CaptureConversation.parse(inputs[0], now: now, calendar: cal)
    guard case .updated(let c) = Dialogue.refine(initial, with: inputs[1], now: now, calendar: cal)
    else {
      return XCTFail("The replacement clock must win over the rejected clock")
    }
    XCTAssertEqual(c.title, initial.title)
    XCTAssertEqual(c.notes, initial.notes)
    XCTAssertEqual(c.day, initial.day)
    XCTAssertEqual(c.repeatRule, "weekly:1,6")
    XCTAssertEqual(c.hour, 18)
    XCTAssertEqual(c.kind, .task)
    XCTAssertEqual(
      Dialogue.refine(initial, with: "改成下午六点，周二和周四都保留。", now: now, calendar: cal), .notARefinement,
      "A mismatched keep-days constraint must not silently drop the user's specified days")
  }

  func testObservedExplicitNoteUsesExistingContentSeam() throws {
    let input = try XCTUnwrap(developmentInputs("recurring-mixed-backup").first)
    let c = CaptureConversation.parse(input, now: now, calendar: cal)
    XCTAssertEqual(c.title, "备份 NAS")
    XCTAssertEqual(c.notes, "run before firmware update")
    XCTAssertEqual(c.repeatRule, "weekly:3,6")
    XCTAssertEqual(c.hour, 20)
    XCTAssertEqual(c.kind, .task)
    XCTAssertEqual(
      CaptureTitleRefinement.fallback(c, source: input), c, "Repeated fallback must be idempotent")
    var existing = c
    existing.notes = "Keep the original server name"
    let merged = CaptureTitleRefinement.fallback(existing, source: input)
    XCTAssertEqual(merged.notes, "Keep the original server name\nrun before firmware update")
    XCTAssertEqual(CaptureTitleRefinement.fallback(merged, source: input), merged)
    let quoted = Capture(title: "Archive, note: Mercury", day: now, hasDay: false)
    XCTAssertEqual(
      CaptureTitleRefinement.fallback(
        quoted, source: "Use the exact title \"Archive, note: Mercury\""), quoted,
      "A note label inside an explicitly quoted name belongs to that name")
  }

  func testOneOffWeekendDoesNotGainRecurrence() {
    for text in ["Pick up dry cleaning this weekend", "Pick up dry cleaning next weekend"] {
      XCTAssertNil(CaptureParser.parse(text, now: now, calendar: cal).repeatRule, text)
    }
  }

}
