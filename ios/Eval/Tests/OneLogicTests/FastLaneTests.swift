import XCTest

@testable import TodayCore

/// `FastLane.decide` applies the rule gates in Ask's order (docs/engineering/ai-agent-architecture.md §4.2, §5 H1).
/// The individual gates are covered by the ported OneOff/SubmittedCapture/ExplicitPlanner/AttachedItem/EditRouting/Dialogue tests.
final class FastLaneTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }
  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9, minute: 11))!
  }

  private func decide(
    _ text: String, turns: [String] = [], pending: Capture? = nil, items: [EditItem] = [],
    itemsRead: (() -> Void)? = nil
  ) -> FastLane.Decision {
    let context = ConversationContext(
      turns: turns.map { .init(isUser: true, text: $0, timestamp: now) })
    return FastLane.decide(
      text, intent: FastLane.intent(text), context: context, pending: pending,
      editItems: {
        itemsRead?()
        return items
      }, now: now, calendar: calendar)
  }

  func testAClearOneOffReminderIsTheOnlyDirectWrite() throws {
    let text = "Remind me to call Alex tomorrow at 11am"
    guard case .directReminder(let capture) = decide(text) else {
      return XCTFail("expected a direct reminder")
    }
    XCTAssertEqual(capture, FastLane.oneOffReminder(text, now: now, calendar: calendar))
    XCTAssertEqual(capture.kind, .task)
    XCTAssertNil(capture.repeatRule)
    for text in [
      "Remind me to buy milk every Monday", "Set an alarm for 11am",
      "Lunch with Alex tomorrow at 11am",
      "Tomorrow remind me to buy [QA] milk at 9am and call [QA] Alex at 3pm", "今天还剩什么",
    ] {
      let decision = decide(text)
      if case .directReminder = decision { XCTFail(text) }
      if case .continuation(_, direct: true) = decision { XCTFail(text) }
    }
  }

  func testAMaterialCorrectionAsksBeforeAnythingElseAndReadsNoItems() {
    var reads = 0
    XCTAssertEqual(
      decide("提醒我周四，不对，周五下午两点买[QA]面包", itemsRead: { reads += 1 }), .clarifyCorrection)
    XCTAssertEqual(reads, 0)
    XCTAssertNotEqual(decide("Remind me to check the date tomorrow"), .clarifyCorrection)
  }

  func testAnEditOfAnExistingItemIsNeverADirectReminder() {
    let dentist = EditItem(
      id: "t1", type: "task", title: "Dentist", start: now.addingTimeInterval(3600), minutes: 30,
      attendees: 0)
    for text in [
      "Move the dentist to 4pm", "Remind me about the dentist at 4pm", "把牙医改到4点", "Dentist at 4pm",
    ] {
      let edit = FastLane.looksLikeEdit(text, items: [dentist], now: now, calendar: calendar)
      if edit, case .directReminder = decide(text, items: [dentist]) { XCTFail(text) }
    }
  }

  func testContinuationsCompleteTheConversationsOwnDraft() throws {
    let utterance = "11点去 costco 加油 买 粒粒"
    guard case .continuation(let capture, let direct) = decide("one off", turns: [utterance]) else {
      return XCTFail("expected a continuation")
    }
    XCTAssertEqual(capture.title, "去 costco 加油 买 粒粒")
    XCTAssertEqual(capture.hour, 11)
    XCTAssertEqual(
      direct,
      FastLane.isEligibleOneOff(capture)
        && FastLane.contextAllowsOneOff(
          ConversationContext(turns: [.init(isUser: true, text: utterance, timestamp: now)]))
    )
    // A recurring request stays out of the one-off exception, even when answered with "one off".
    XCTAssertEqual(decide("one off", turns: ["每天11点提醒我买奶"]), .notFastLane)
  }

  func testOnlyASingleOwnStatedReminderIsDirect() {
    // Questions, events with a length, two reminders at once and someone else's plans are not a clear
    // one-off reminder; the agent (or a preview) handles them.
    for text in [
      "Can you share my calendar with Jo?", "Could you remind me to stretch at 4pm?",
      "你能帮我明天早上提醒一下开会吗？", "明天提醒我交作业可以吗",
      "Book a meeting with Lee tomorrow at 10am for an hour",
      "Schedule lunch with Ana Friday at 1pm",
      "明天下午两点和小王开会一个小时，提醒我",
      "今晚7点提醒我倒垃圾，9点提醒我关窗", "Remind me at 8 to stretch and remind me at 9 to read",
      "我妈说她明天要提醒自己吃药",
    ] {
      let decision = decide(text)
      if case .directReminder = decision { XCTFail(text) }
    }
    // Still direct: plain requests, including relative times that mention minutes or hours.
    for text in [
      "Remind me to call Alex tomorrow at 11am", "明天下午3点提醒我交房租",
      "提醒我1小时后喝水", "Remind me in 30 minutes to check the oven",
      "Remind me to schedule a haircut tomorrow at 10am", "明天下午3点提醒我去开会",
    ] {
      guard case .directReminder = decide(text) else { return XCTFail("expected direct: \(text)") }
    }
  }

  func testAFollowUpToASavedReminderNeverRecreatesIt() {
    let turns = ["提醒我后天交房租"]
    // While its card is still open, an answer completes the draft (unchanged behaviour)…
    if case .notFastLane = decide("下午五点", turns: turns) { XCTFail("open draft continues") }
    // …but once that reminder is saved, the follow-up is a correction for the agent, not a new write.
    let context = ConversationContext(
      turns: turns.map { .init(isUser: true, text: $0, timestamp: now) })
    let saved = FastLane.decide(
      "下午五点", intent: FastLane.intent("下午五点"), context: context, pending: nil,
      savedDraft: true, editItems: { [] }, now: now, calendar: calendar)
    XCTAssertEqual(saved, .notFastLane)
  }

  func testReportedSpeechIsNotARequestButTheUsersOwnAskIs() {
    for text in [
      "我朋友说他明天要提醒自己买茶", "我同事说他明天下午要去开会", "老婆说她周五要提醒自己去体检",
      "My brother said he set an alarm for 6am",
      "Sam told me he has a meeting with the bank on Friday",
      "She says she'll remind herself tomorrow",
    ] {
      XCTAssertTrue(FastLane.isReportedSpeech(text), text)
    }
    for text in [
      "明天下午3点提醒我给妈妈打电话", "老婆说她明天要用车，提醒我加油", "提醒我跟妈妈说一声",
      "Sam said he needs the report, remind me Friday at 9", "Remind me to call Sam at 5pm",
      "他说明天的会改到下午了",
    ] {
      XCTAssertFalse(FastLane.isReportedSpeech(text), text)
    }
  }

  func testOrdinaryConversationIsNotForTheFastLane() {
    XCTAssertEqual(decide("What happens if I set a reminder?"), .notFastLane)
  }

  // MARK: Local previews (offline / not signed in, §4.7 #3)

  private func preview(_ text: String, items: [EditItem] = []) -> Capture? {
    FastLane.localPreview(text, items: items, now: now, calendar: calendar)
  }

  func testConfidentEventsAlarmsAndRemindersGetALocalPreview() throws {
    let event = try XCTUnwrap(preview("Add an event tomorrow at 3pm called [QA] Review"))
    XCTAssertEqual(event.kind, .event)
    XCTAssertEqual(event.hour, 15)
    let lunch = try XCTUnwrap(preview("Lunch with [QA] Alex tomorrow at 12pm"))
    XCTAssertEqual(lunch.hour, 12)
    XCTAssertTrue(lunch.hasDay)

    let alarm = try XCTUnwrap(preview("Set an alarm for 7am tomorrow"))
    XCTAssertTrue(alarm.ringsAsAlarm)
    XCTAssertEqual(alarm.hour, 7)
    let wake = try XCTUnwrap(preview("明天早上7点叫醒我"))
    XCTAssertTrue(wake.ringsAsAlarm)
    XCTAssertEqual(wake.hour, 7)

    // A recurring reminder is never direct, but it is a confident preview.
    let weekly = try XCTUnwrap(preview("Remind me to water the plants every Monday at 9am"))
    XCTAssertEqual(weekly.kind, .task)
    XCTAssertFalse(weekly.ringsAsAlarm)
    XCTAssertNotNil(weekly.repeatRule)
    XCTAssertNil(
      FastLane.oneOffReminder(
        "Remind me to water the plants every Monday at 9am", now: now, calendar: calendar))
  }

  func testUnsureOrNonRequestTextHasNoLocalPreview() {
    let dentist = EditItem(
      id: "t1", type: "task", title: "Dentist", start: now.addingTimeInterval(3600), minutes: 30,
      attendees: 0)
    for text in [
      "What's on tomorrow?", "How are you?", "thanks",
      "Tidy overdue",
      "Remind me to buy [QA] milk at 9am and call [QA] Alex at 3pm",
      "提醒我周四，不对，周五下午两点买[QA]面包",
      "Sam told me he has a meeting with the bank on Friday",
      "Remind me tomorrow",
    ] {
      XCTAssertNil(preview(text), text)
    }
    XCTAssertNil(preview("Move the dentist to 4pm", items: [dentist]))
  }

  func testAnAlarmNeedsItsWordsAndATime() throws {
    XCTAssertEqual(
      FastLane.ruleKind(
        "Wake me at 6:30",
        parsed: FastLane.parse(
          "Wake me at 6:30", now: now, calendar: calendar)), .alarm)
    // A meeting word alone leaves the kind to the parser (reminder or event, the user picks on the card).
    XCTAssertNil(
      FastLane.ruleKind(
        "Dentist tomorrow at 3pm",
        parsed: FastLane.parse(
          "Dentist tomorrow at 3pm", now: now, calendar: calendar)))
    let plain = try XCTUnwrap(preview("Call the bank tomorrow at 10am"))
    XCTAssertFalse(plain.ringsAsAlarm)
    XCTAssertEqual(plain.kind, .task)
  }
}
