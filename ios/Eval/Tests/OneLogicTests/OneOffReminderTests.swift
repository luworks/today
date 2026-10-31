import XCTest

@testable import TodayCore

final class OneOffReminderTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }
  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9, minute: 11))!
  }
  private let utterance = "11点去 costco 加油 买 粒粒"

  func testScreenshotRoutesToReminderWithExactDeadline() {
    XCTAssertEqual(FastLane.intent(utterance), .capture)
    let capture = FastLane.parse(utterance, now: now, calendar: calendar)
    XCTAssertEqual(capture.kind, .task)
    XCTAssertEqual(capture.title, "去 costco 加油 买 粒粒")
    XCTAssertEqual(capture.hour, 11)
    XCTAssertEqual(capture.minute, 0)
    XCTAssertNil(capture.repeatRule)
    XCTAssertEqual(
      capture.taskTiming(calendar: calendar).due,
      calendar.date(bySettingHour: 11, minute: 0, second: 0, of: now))
  }

  func testChineseMixedReminderRequestAndFollowUpPreserveSlots() throws {
    let text = "增加一个 reminder，今天下午两点吧，我需要去学这个八段锦"
    XCTAssertEqual(FastLane.intent(text), .capture)
    let capture = try XCTUnwrap(FastLane.oneOffReminder(text, now: now, calendar: calendar))
    XCTAssertEqual(capture.title, "我需要去学这个八段锦")
    XCTAssertEqual(capture.kind, .task)
    XCTAssertEqual(capture.day, calendar.startOfDay(for: now))
    XCTAssertEqual(capture.hour, 14)
    XCTAssertEqual(capture.minute, 0)
    XCTAssertNil(capture.repeatRule)
    let context = ConversationContext(turns: [.init(isUser: true, text: text, timestamp: now)])
    let recovered = try XCTUnwrap(
      FastLane.resolve(
        "增加提醒", context: context, pending: nil, now: now, calendar: calendar))
    XCTAssertEqual(recovered, capture)
  }

  func testExplicitRemindersKeepTheirKindAndTimeAcrossLanguages() throws {
    let cases: [(String, Int, Int)] = [
      ("明天早上8点提醒我参加会议", 8, 1),
      ("增加一个 reminder，明天早上8点，交报告", 8, 1),
      ("周五下午两点提醒我买牛奶", 14, 3),
      ("Add a reminder to call Alex tomorrow at 9am", 9, 1),
    ]
    for (text, hour, dayOffset) in cases {
      let capture = try XCTUnwrap(
        FastLane.oneOffReminder(text, now: now, calendar: calendar), text)
      XCTAssertEqual(capture.kind, .task, text)
      XCTAssertEqual(capture.hour, hour, text)
      XCTAssertEqual(
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: capture.day).day,
        dayOffset, text)
    }
    XCTAssertNil(FastLane.oneOffReminder("每周五下午两点提醒我买牛奶", now: now, calendar: calendar))
    XCTAssertNil(FastLane.oneOffReminder("增加一个闹钟，明天早上8点", now: now, calendar: calendar))
    XCTAssertNil(FastLane.oneOffReminder("今天还剩什么", now: now, calendar: calendar))
    XCTAssertTrue(ChatRouting.isAgendaQuestion("今天还剩什么"))
  }

  func testMixedLanguageFollowupsKeepOriginalSubjectAndTime() throws {
    var turns: [ConversationContext.Turn] = [.init(isUser: true, text: utterance, timestamp: now)]
    for text in ["setting reminder", "one off"] {
      let capture = try XCTUnwrap(
        FastLane.resolve(
          text,
          context: ConversationContext(turns: turns), pending: nil, now: now, calendar: calendar))
      XCTAssertEqual(capture.title, "去 costco 加油 买 粒粒")
      XCTAssertEqual(capture.hour, 11)
      XCTAssertEqual(capture.kind, .task)
      XCTAssertNil(capture.repeatRule)
      turns.append(.init(isUser: true, text: text, timestamp: now))
    }
  }

  func testGeneratedChineseReminderWrapperIsNotTheActionTitle() {
    let capture = FastLane.parse("设置11点去costco加油买粒粒的提醒", now: now, calendar: calendar)
    XCTAssertEqual(capture.title, "去costco加油买粒粒")
    XCTAssertEqual(capture.hour, 11)
  }
  func testDirectAuthorityDefaultsToOnceButExcludesRecurrenceAndChat() throws {
    for text in [utterance, "Buy milk", "Remind me to call Alex tomorrow at 11am"] {
      let capture = try XCTUnwrap(
        FastLane.oneOffReminder(text, now: now, calendar: calendar), text)
      XCTAssertNil(capture.repeatRule)
      XCTAssertEqual(capture.kind, .task)
    }
    for text in [
      "11点去 costco 加油可以买什么？", "我已经11点去costco加油了", "不要设置提醒",
      "What happens if I set a reminder?", "Buy what?", "买什么？",
      "明年8月 预约医生做 annual check", "Next August book a doctor for an annual check",
      "tomorrow at 11am", "setting reminder", "one off", "Remind me", "new task", "提醒我",
      "Remind me to buy milk every Monday", "每天11点提醒我买奶", "11点还是12点买奶",
      "Set an alarm for 11am", "Set an alarm", "Wake me up", "设置闹钟",
      "Lunch with Alex tomorrow at 11am", "增加库存", "增加提醒了吗？",
    ] {
      XCTAssertNil(FastLane.oneOffReminder(text, now: now, calendar: calendar), text)
    }
  }

  func testClockRollover() throws {
    let late = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
    let capture = try XCTUnwrap(
      FastLane.oneOffReminder(utterance, now: late, calendar: calendar))
    XCTAssertEqual(
      capture.day, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
    XCTAssertEqual(capture.hour, 11)
    let working = FastLane.parse(
      "Work on the report tomorrow at 11am for 2 hours", now: now, calendar: calendar)
    XCTAssertNotNil(working.taskTiming(calendar: calendar).due)
  }

  func testFailedDraftRoundTripsAndContinuationOnlyMatchesSameAction() throws {
    let capture = try XCTUnwrap(
      FastLane.oneOffReminder(utterance, now: now, calendar: calendar))
    let card = StoredCard(
      id: UUID(), anchor: UUID(), batch: UUID(), batchSize: 1,
      capture: capture, status: .open, retainsDraft: true,
      pendingExternalID: "synthetic-accepted-id")
    XCTAssertEqual(StoredCard.restore(StoredCard.encode([card])), [card])
    XCTAssertTrue(FastLane.sameOneOff(card.capture, capture))
    var other = capture
    other.hour = 12
    XCTAssertFalse(FastLane.sameOneOff(other, capture))
    let context = ConversationContext(turns: [
      .init(isUser: true, text: "每天11点提醒我买奶", timestamp: now)
    ])
    XCTAssertNil(
      FastLane.resolve(
        "one off", context: context, pending: nil, now: now, calendar: calendar))
  }

  func testLocalSaveFailureCompensatesAndFailedCompensationRetainsIdentity() throws {
    enum Failure: Error { case local, system }
    var identity: String? = "synthetic-accepted-id"
    var operations: [String] = []
    XCTAssertThrowsError(
      try ReminderCreationCommit.persist(
        save: {
          operations.append("save")
          throw Failure.local
        },
        compensate: {
          operations.append("compensate")
          identity = nil
        }))
    XCTAssertEqual(operations, ["save", "compensate"])
    XCTAssertNil(identity)
    identity = "synthetic-accepted-id"
    XCTAssertThrowsError(
      try ReminderCreationCommit.persist(
        save: { throw Failure.local },
        compensate: { throw Failure.system })
    ) { error in
      XCTAssertTrue(error is ReminderCreationCommit.CompensationFailure)
    }
    XCTAssertEqual(identity, "synthetic-accepted-id")
    operations = []
    try ReminderCreationCommit.persist(
      save: { operations.append("save") },
      compensate: {
        XCTFail("A successful local save must not remove the system reminder")
      })
    XCTAssertEqual(operations, ["save"])
  }

}
