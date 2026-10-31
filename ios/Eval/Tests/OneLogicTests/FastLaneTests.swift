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

  func testOrdinaryConversationIsNotForTheFastLane() {
    XCTAssertEqual(decide("What happens if I set a reminder?"), .notFastLane)
  }
}
