import XCTest

@testable import TodayCore

final class AskRouterTests: XCTestCase {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }
  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))!
  }
  private func plan(_ text: String, agentOpen: Bool = false, timeContext: Bool = false)
    -> AskRouter.Plan
  {
    AskRouter.plan(
      text, context: ConversationContext(turns: []), pending: nil, savedDraft: false,
      agentHasOpenCards: agentOpen, hasLocalTimeContext: timeContext, editItems: { [] },
      now: now, calendar: calendar)
  }

  func testClearReminderRemainsDirectEvenWithAgentCards() {
    for open in [false, true] {
      let route = plan("明天上午9点提醒我倒垃圾", agentOpen: open)
      guard case .directReminder(let capture) = route.decision else {
        return XCTFail("A clear submitted reminder must remain direct")
      }
      XCTAssertEqual(capture.title, "倒垃圾")
      XCTAssertEqual(capture.hour, 9)
      XCTAssertNil(capture.repeatRule)
      XCTAssertFalse(route.useAgent)
      if open { XCTAssertNil(route.previewAnswer) }
    }
  }

  func testCorrectionClarifiesLocallyButBelongsToAnOpenAgentCard() {
    for open in [false, true] {
      var reads = 0
      let route = AskRouter.plan(
        "提醒我周四，不对，周五下午两点买面包", context: ConversationContext(turns: []),
        pending: nil, savedDraft: false, agentHasOpenCards: open, hasLocalTimeContext: true,
        editItems: {
          reads += 1
          return []
        }, now: now, calendar: calendar)
      XCTAssertEqual(route.decision, .clarifyCorrection)
      XCTAssertNil(route.previewAnswer)
      XCTAssertEqual(route.useAgent, open)
      XCTAssertEqual(reads, 0)
    }
  }

  func testQuestionTimeAnswerOnlyReachesLocalPreviewWithLocalContext() {
    XCTAssertNil(plan("How about 5pm?").previewAnswer)
    XCTAssertNotNil(plan("How about 5pm?", timeContext: true).previewAnswer)
    XCTAssertNil(plan("How about 5pm?", agentOpen: true, timeContext: true).previewAnswer)
  }

  func testConversationNeverBecomesAnAnswerOrDirectWrite() {
    for text in ["我明天有什么安排？", "I went hiking yesterday", "What alarms do I have?"] {
      let route = plan(text, timeContext: true)
      XCTAssertEqual(route.decision, .notFastLane, text)
      XCTAssertNil(route.previewAnswer, text)
      XCTAssertTrue(route.useAgent, text)
    }
  }

  func testEventAlarmAndRecurrenceNeverBecomeDirectWrites() {
    for text in ["下周三和 Alex 开会", "Set an alarm for 7am", "每周日下午5点提醒我丢垃圾"] {
      let route = plan(text)
      if case .directReminder = route.decision { XCTFail(text) }
      XCTAssertTrue(route.useAgent, text)
    }
  }
}
