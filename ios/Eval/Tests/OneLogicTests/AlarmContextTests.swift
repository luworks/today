import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class AlarmContextTests: XCTestCase {
  private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }
  private var now: Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15, minute: 40))!
  }

  func testExactInitialMixedLanguageAlarm() {
    let text = "提醒 烘干衣服 45min 后 alarm"
    XCTAssertEqual(ChatRouting.intent(text), .capture)
    let c = CaptureConversation.parse(text, now: now, calendar: cal)
    XCTAssertEqual(c.title, "烘干衣服")
    XCTAssertEqual(c.hour, 16)
    XCTAssertEqual(c.minute, 25)
    XCTAssertTrue(c.ringsAsAlarm)
    XCTAssertTrue(c.isReadyToAdd)
  }

  func testClarificationAfterWrongAssistantRecoversOriginalSubject() throws {
    let context = ConversationContext(turns: [
      .init(isUser: true, text: "提醒 烘干衣服 45min 后 alarm", timestamp: now),
      .init(isUser: false, text: "Got it. What else would you like to plan or check?"),
    ])
    let c = try XCTUnwrap(
      CaptureConversation.resolve(
        "make a alarm", context: context, pending: nil, now: now, calendar: cal))
    XCTAssertEqual(c.title, "烘干衣服")
    XCTAssertEqual(c.hour, 16)
    XCTAssertEqual(c.minute, 25)
    XCTAssertTrue(c.ringsAsAlarm)
  }

  func testContextQuestionIsConversationAndNeverRecoversCapture() {
    let text = "... 你可以看到我上面的 context 吗"
    XCTAssertEqual(ChatRouting.intent(text), .conversation)
    let context = ConversationContext([(true, "提醒 烘干衣服 45min 后 alarm"), (false, "Got it.")])
    XCTAssertNil(
      CaptureConversation.resolve(text, context: context, pending: nil, now: now, calendar: cal))
    XCTAssertNil(
      ChatRouting.contextualTimeAnswer(text, hasTimeContext: true, now: now, calendar: cal))
  }
  func testOriginalTimestampSurvivesTimeAdvanceEncodingAndContextQuestion() throws {
    let original = ChatMessage(role: .user, text: "提醒 烘干衣服 45min 后 alarm", timestamp: now)
    let restored = try JSONDecoder().decode(
      [ChatMessage].self, from: JSONEncoder().encode([original]))
    var turns = restored.map {
      ConversationContext.Turn(isUser: $0.role == .user, text: $0.text, timestamp: $0.timestamp)
    }
    turns += [
      .init(isUser: false, text: "Got it."),
      .init(isUser: true, text: "make a alarm", timestamp: now.addingTimeInterval(120)),
      .init(isUser: false, text: "What time?"),
      .init(isUser: true, text: "... 你可以看到我上面的 context 吗", timestamp: now.addingTimeInterval(180)),
      .init(isUser: false, text: "Got it."),
    ]
    let context = ConversationContext(turns: turns)
    let generic = Capture(title: "Alarm", day: now, hasDay: false)
    let recovered = try XCTUnwrap(
      CaptureConversation.resolve(
        "make an alarm", context: context, pending: generic,
        now: now.addingTimeInterval(600), calendar: cal))
    XCTAssertEqual(recovered.title, "烘干衣服")
    XCTAssertEqual(recovered.hour, 16)
    XCTAssertEqual(recovered.minute, 25)
  }

  func testRelativeMidnightAndDSTUseElapsedMinutesFromOriginalTurn() throws {
    for components in [
      DateComponents(year: 2026, month: 10, day: 18, hour: 23, minute: 40),
      DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 40),
    ] {
      let anchor = try XCTUnwrap(cal.date(from: components))
      let context = ConversationContext(turns: [
        .init(isUser: true, text: "提醒 烘干衣服 45min 后 alarm", timestamp: anchor)
      ])
      let c = try XCTUnwrap(
        CaptureConversation.resolve(
          "make a alarm", context: context, pending: nil,
          now: anchor.addingTimeInterval(600), calendar: cal))
      let expected = anchor.addingTimeInterval(45 * 60)
      XCTAssertTrue(cal.isDate(c.day, inSameDayAs: expected))
      XCTAssertEqual(c.hour, cal.component(.hour, from: expected))
      XCTAssertEqual(c.minute, cal.component(.minute, from: expected))
    }
  }

  func testUnknownLegacyClockAndAssistantTextCannotSupplyCountdown() throws {
    let old = Data(
      "[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"role\":\"user\",\"text\":\"old chat\"}]"
        .utf8)
    XCTAssertNil(try JSONDecoder().decode([ChatMessage].self, from: old).first?.timestamp)
    for context in [
      ConversationContext([]), ConversationContext([(false, "提醒 烘干衣服 45min 后 alarm")]),
      ConversationContext([(true, "提醒 烘干衣服 45min 后 alarm")]),
    ] {
      let c = try XCTUnwrap(
        CaptureConversation.resolve(
          "make a alarm", context: context, pending: nil, now: now, calendar: cal))
      XCTAssertNil(c.hour)
      XCTAssertFalse(c.isReadyToAdd)
    }
    for text in [
      "她说提醒 烘干衣服 45min 后 alarm", "提醒的内容是什么？", "不要提醒 烘干衣服 45min 后 alarm",
      "Can you see the above context about setting an alarm?",
    ] {
      XCTAssertNotEqual(ChatRouting.intent(text), .capture, text)
    }
  }

  func testVersionedFullThreeTurnBilingualEvaluation() throws {
    struct Journey: Decodable {
      let name: String
      let steps: [Step]
    }
    struct Step: Decodable {
      let user: String
      let assistant: String
      let elapsedMinutes: Int
      let route: String
      let title: String
    }
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../../../tests/fixtures/ai-alarm-context-cases.json").standardized
    let journeys = try JSONDecoder().decode([Journey].self, from: Data(contentsOf: url))
    for journey in journeys {
      var turns: [ConversationContext.Turn] = []
      var preview: Capture?
      for step in journey.steps {
        let at = now.addingTimeInterval(Double(step.elapsedMinutes * 60))
        let context = ConversationContext(turns: turns)
        let old = preview
        if step.route == "conversation" {
          XCTAssertEqual(ChatRouting.intent(step.user), .conversation)
          XCTAssertNil(
            CaptureConversation.resolve(
              step.user, context: context, pending: preview, now: at, calendar: cal))
          XCTAssertEqual(preview, old)
        } else {
          preview =
            CaptureConversation.resolve(
              step.user, context: context, pending: nil, now: at, calendar: cal)
            ?? (ChatRouting.intent(step.user) == .capture
              ? CaptureConversation.parse(step.user, now: at, calendar: cal) : nil)
          let c = try XCTUnwrap(preview, journey.name)
          XCTAssertEqual(c.title, step.title, journey.name)
          XCTAssertEqual(c.hour, 16, journey.name)
          XCTAssertEqual(c.minute, 25, journey.name)
          XCTAssertTrue(c.ringsAsAlarm)
          XCTAssertTrue(c.isReadyToAdd)
        }
        turns += [
          .init(isUser: true, text: step.user, timestamp: at),
          .init(isUser: false, text: step.assistant, timestamp: at),
        ]
      }
    }
  }

  func testAssistantVerbosityCannotEvictOriginalRequestOrRemoveUserBarrier() throws {
    var turns = [
      ConversationContext.Turn(isUser: true, text: "提醒 烘干衣服 45min 后 alarm", timestamp: now)
    ]
    turns += (0..<12).map { _ in .init(isUser: false, text: String(repeating: "A", count: 400)) }
    var context = ConversationContext(turns: turns)
    XCTAssertEqual(context.turns.count, 4)
    XCTAssertTrue(
      try XCTUnwrap(
        CaptureConversation.resolve(
          "make a alarm", context: context, pending: nil, now: now.addingTimeInterval(600),
          calendar: cal)
      ).isReadyToAdd)
    turns.append(.init(isUser: true, text: "Let's talk about books", timestamp: now))
    context = ConversationContext(turns: turns)
    XCTAssertNil(
      CaptureConversation.resolve(
        "make a alarm", context: context, pending: nil, now: now, calendar: cal)?.hour)
  }

}
