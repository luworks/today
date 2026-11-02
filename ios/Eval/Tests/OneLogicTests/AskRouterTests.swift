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

  func testLocalPreviewFollowUpChangesKindWithoutLosingTitleOrTime() throws {
    let draft = try XCTUnwrap(
      FastLane.localPreview(
        "Call Alex tomorrow at 3pm every week", items: [], now: now, calendar: calendar))
    let route = AskRouter.plan(
      "make it an alarm", context: ConversationContext(turns: []), pending: draft,
      savedDraft: false, agentHasOpenCards: false, hasLocalTimeContext: true,
      editItems: { [] }, now: now, calendar: calendar)
    guard case .continuation(let alarm, let direct) = route.decision else {
      return XCTFail("The router must resolve the existing preview as a continuation")
    }
    XCTAssertFalse(direct)
    XCTAssertFalse(route.useAgent)
    XCTAssertNil(route.previewAnswer)
    XCTAssertTrue(alarm.ringsAsAlarm)
    XCTAssertEqual(alarm.kindLabel, "New alarm")
    XCTAssertTrue(alarm.summary.hasPrefix("Alarm "))
    XCTAssertEqual(alarm.title, draft.title)
    XCTAssertEqual(alarm.clockTime, draft.clockTime)
  }

  /// Matches AskView: try the router's local answer before dispatching its fallback.
  private func refined(_ draft: Capture, answer text: String) throws -> Capture {
    let route = AskRouter.plan(
      text, context: ConversationContext(turns: []), pending: draft, savedDraft: false,
      agentHasOpenCards: false, hasLocalTimeContext: true, editItems: { [] },
      now: now, calendar: calendar)
    if case .continuation(let result, let direct) = route.decision {
      XCTAssertFalse(direct, text)
      XCTAssertFalse(route.useAgent, text)
      return result
    }
    let answer = try XCTUnwrap(route.previewAnswer, text)
    guard
      case .updated(let result) = FastLane.refine(
        draft, with: answer, now: now, calendar: calendar)
    else { throw NSError(domain: "Expected preview refinement: " + text, code: 1) }
    return result
  }

  func testMigratedFiveCaptureSentences() throws {
    let cases: [(String, String, String?, Bool, Int?)] = [
      ("Call Alex tomorrow at 3pm", "Call Alex", "New reminder", true, 15),
      ("周五晚上7点和朋友聚餐", "和朋友聚餐", nil, false, 19),
      ("明早7点叫我起床", "Alarm", "New alarm", false, 7),
      ("提醒我下周一交报销单", "交报销单", "New reminder", true, nil),
      ("30分钟后关烤箱", "关烤箱", "New reminder", true, 9),
    ]
    for (text, title, kind, direct, hour) in cases {
      let route = plan(text)
      let capture: Capture
      if case .directReminder(let value) = route.decision {
        XCTAssertTrue(direct, text)
        XCTAssertFalse(route.useAgent, text)
        capture = value
      } else {
        XCTAssertFalse(direct, text)
        XCTAssertTrue(route.useAgent, text)
        capture = try XCTUnwrap(
          FastLane.localPreview(text, items: [], now: now, calendar: calendar))
      }
      XCTAssertTrue(capture.title.contains(title), text)
      if let kind { XCTAssertEqual(capture.kindLabel, kind, text) }
      XCTAssertEqual(capture.hour, hour, text)
      if direct && hour != nil {
        XCTAssertTrue(capture.alertsAtTime(calendar: calendar), text)
      }
      if text == "30分钟后关烤箱" {
        XCTAssertEqual(capture.clockTime(calendar: calendar), now.addingTimeInterval(1800))
      }
      if text == "明早7点叫我起床" {
        XCTAssertTrue(
          capture.summary(now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
            .hasPrefix("Alarm Tomorrow"))
      }
      if text == "提醒我下周一交报销单" { XCTAssertFalse(capture.ringsAsAlarm) }
    }
  }

  func testMigratedEnglishDinnerCorrectionsKeepTitleKindAndDay() throws {
    var draft = try XCTUnwrap(
      FastLane.localPreview(
        "At 6pm tonight, remind me not to eat dinner again every day.",
        items: [], now: now, calendar: calendar))
    XCTAssertTrue(draft.title.localizedCaseInsensitiveContains("Do not eat dinner again"))
    XCTAssertEqual(draft.kindLabel, "New reminder")
    XCTAssertEqual(draft.hour, 18)
    XCTAssertTrue(calendar.isDate(draft.day, inSameDayAs: now))
    let title = draft.title
    for text in [
      "No, just add an alarm.", "I need you to help me set that alarm.",
      "Make it tomorrow instead.", "Actually, 7pm.",
    ] {
      draft = try refined(draft, answer: text)
      XCTAssertEqual(draft.title, title, text)
      XCTAssertEqual(draft.kindLabel, "New alarm", text)
      XCTAssertEqual(draft.hour, text == "Actually, 7pm." ? 19 : 18, text)
      let dayOffset = text == "Make it tomorrow instead." || text == "Actually, 7pm." ? 1 : 0
      XCTAssertTrue(
        calendar.isDate(draft.day, inSameDayAs: now.addingTimeInterval(Double(dayOffset * 86400))),
        text)
    }
  }

  func testMigratedAnnualBookingRoutesToUndatedReminderThenRenames() throws {
    let text = "Next August book a doctor for an annual check"
    let route = plan(text)
    XCTAssertEqual(route.decision, .notFastLane)
    XCTAssertTrue(route.useAgent)
    let draft = try XCTUnwrap(FastLane.localPreview(text, items: [], now: now, calendar: calendar))
    XCTAssertEqual(draft.kindLabel, "New reminder")
    XCTAssertTrue(draft.title.contains("2027"))
    XCTAssertTrue(draft.title.contains("book a doctor for an annual check"))
    XCTAssertFalse(draft.hasDay)
    XCTAssertNil(draft.taskTiming(calendar: calendar).due)
    let renamed = try refined(draft, answer: "call it Book annual check")
    XCTAssertEqual(renamed.title, "Book annual check")
    XCTAssertEqual(renamed.kindLabel, "New reminder")
    XCTAssertNil(renamed.taskTiming(calendar: calendar).due)
    XCTAssertTrue(renamed.isReadyToAdd)
  }
  func testMigratedExplicitAlarmAndEventUseLocalPreviews() throws {
    for (text, kind) in [
      ("Set an alarm for 7am", "New alarm"),
      ("Dentist appointment tomorrow at 3pm", "New event"),
    ] {
      let route = plan(text)
      XCTAssertEqual(route.decision, .notFastLane, text)
      XCTAssertTrue(route.useAgent, text)
      let preview = try XCTUnwrap(
        FastLane.localPreview(text, items: [], now: now, calendar: calendar))
      XCTAssertEqual(preview.kindLabel, kind, text)
      XCTAssertTrue(preview.isReadyToAdd, text)
    }
  }
}
