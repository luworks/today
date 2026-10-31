import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class DialogueTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()
  lazy var now = cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9, minute: 0))!

  private func card(_ text: String) -> Capture {
    CaptureParser.parse(text, now: now, calendar: cal)
  }

  func testPendingAlarmClarificationDateAndTime() {
    let afternoon = cal.date(bySettingHour: 15, minute: 42, second: 0, of: now)!
    let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: afternoon))!
    let pending = CaptureConversation.parse(
      "Set an alarm to wake me up.", now: afternoon, calendar: cal)
    for answer in ["Tomorrow at 7am.", "tomorrow at 7am", "明天早上7点"] {
      XCTAssertTrue(FastLane.isOnlyWhen(answer, now: afternoon, calendar: cal), answer)
      guard
        case .updated(let updated) = FastLane.refine(
          pending, with: answer, now: afternoon, calendar: cal)
      else {
        XCTFail("Rejected time answer: \(answer)")
        continue
      }
      XCTAssertTrue(updated.ringsAsAlarm)
      XCTAssertEqual(updated.day, tomorrow)
      XCTAssertEqual(updated.hour, 7)
      guard
        case .updated(let repeated) = FastLane.refine(
          updated, with: "7am", now: afternoon, calendar: cal)
      else {
        XCTFail("Rejected short answer")
        continue
      }
      XCTAssertEqual(repeated.day, tomorrow)
    }
    guard
      case .updated(let bare) = FastLane.refine(pending, with: "7am", now: afternoon, calendar: cal)
    else {
      return XCTFail("Rejected bare time")
    }
    XCTAssertEqual(bare.day, tomorrow)
  }

  // MARK: pick

  func testPickByOrdinal() {
    let t = ["Product sync", "Design review", "Lunch with Priya"]
    XCTAssertEqual(Dialogue.pick("the first one", from: t), 0)
    XCTAssertEqual(Dialogue.pick("第二个", from: t), 1)
    XCTAssertEqual(Dialogue.pick("3", from: t), 2)
    XCTAssertEqual(Dialogue.pick("the last one", from: t), 2)
    XCTAssertEqual(Dialogue.pick("最后一个", from: t), 2)
  }

  func testPickByTitleWords() {
    let t = ["Product sync", "Design review", "Lunch with Priya"]
    XCTAssertEqual(Dialogue.pick("the design one", from: t), 1)
    XCTAssertEqual(Dialogue.pick("lunch", from: t), 2)
    XCTAssertNil(Dialogue.pick("something else entirely", from: t), "no match: it is a new message")
    XCTAssertNil(Dialogue.pick("sync review", from: t), "two matches: ask again")
  }

  // MARK: refine

  func testChangeTimeOnly() {
    let c = card("Call Alex tomorrow at 3pm")
    guard case .updated(let r) = FastLane.refine(c, with: "make it 4pm", now: now, calendar: cal)
    else { return XCTFail() }
    XCTAssertEqual(r.hour, 16)
    XCTAssertEqual(r.title, "Call Alex")
    XCTAssertEqual(r.day, c.day, "the day stays")
  }

  func testChangeDayOnly() {
    let c = card("Call Alex tomorrow at 3pm")
    guard case .updated(let r) = FastLane.refine(c, with: "Friday instead", now: now, calendar: cal)
    else { return XCTFail() }
    XCTAssertEqual(r.hour, 15, "the time stays")
    XCTAssertEqual(cal.component(.weekday, from: r.day), 6)
  }

  func testChineseTimeChange() {
    let c = card("明天下午3点给Alex打电话")
    guard case .updated(let r) = FastLane.refine(c, with: "改成下午4点", now: now, calendar: cal) else {
      return XCTFail()
    }
    XCTAssertEqual(r.hour, 16)
  }

  func testMakeItAnAlarm() {
    let c = card("Wake up tomorrow at 7am")
    guard
      case .updated(let r) = FastLane.refine(c, with: "make it an alarm", now: now, calendar: cal)
    else { return XCTFail() }
    XCTAssertTrue(r.ringsAsAlarm)
    XCTAssertEqual(r.hour, 7)
  }

  func testAlarmWithoutATimeAsksForOne() {
    let c = card("Buy milk")
    XCTAssertEqual(
      FastLane.refine(c, with: "set an alarm for it", now: now, calendar: cal), .needsTime)
    guard case .updated(let r) = FastLane.refine(c, with: "alarm at 6pm", now: now, calendar: cal)
    else { return XCTFail() }
    XCTAssertTrue(r.ringsAsAlarm)
    XCTAssertEqual(r.hour, 18)
  }

  func testMakeItAnEventAndBack() {
    let c = card("Lunch with Priya tomorrow at noon")
    guard
      case .updated(let e) = FastLane.refine(c, with: "make it an event", now: now, calendar: cal)
    else { return XCTFail() }
    XCTAssertEqual(e.kind, .event)
    guard
      case .updated(let t) = FastLane.refine(e, with: "actually a task", now: now, calendar: cal)
    else { return XCTFail() }
    XCTAssertEqual(t.kind, .task)
  }

  func testRename() {
    let c = card("Send report Friday")
    guard
      case .updated(let r) = FastLane.refine(
        c, with: "call it Quarterly report", now: now, calendar: cal)
    else { return XCTFail() }
    XCTAssertEqual(r.title, "Quarterly report")
  }

  func testNewItemIsNotARefinement() {
    let c = card("Call Alex tomorrow at 3pm")
    XCTAssertEqual(
      FastLane.refine(c, with: "Pick up the kids at 5pm", now: now, calendar: cal), .notARefinement)
    XCTAssertEqual(FastLane.refine(c, with: "Buy milk", now: now, calendar: cal), .notARefinement)
  }

  func testDismiss() {
    XCTAssertEqual(
      FastLane.refine(card("Buy milk"), with: "never mind", now: now, calendar: cal), .dismissed)
    XCTAssertEqual(
      FastLane.refine(card("Buy milk"), with: "算了", now: now, calendar: cal), .dismissed)
  }

  // MARK: answerTime

  func testAnswerTimeKeepsTheOldDay() {
    let old = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 10, minute: 30))!
    let new = FastLane.answerTime("5pm", keeping: old, now: now, calendar: cal)!
    XCTAssertEqual(
      cal.dateComponents([.day, .hour, .minute], from: new),
      DateComponents(day: 17, hour: 17, minute: 0))
    let tomorrow = FastLane.answerTime("tomorrow", keeping: old, now: now, calendar: cal)!
    XCTAssertEqual(
      cal.dateComponents([.day, .hour, .minute], from: tomorrow),
      DateComponents(day: 17, hour: 10, minute: 30))
    XCTAssertNil(FastLane.answerTime("hmm", keeping: old, now: now, calendar: cal))
  }

  /// After "Move Dentist" asks when, an unrelated timed reminder must remain a new request.
  func testNewTimedRequestDoesNotAnswerAnExistingItemsTimePrompt() {
    let old = cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 15))!
    for request in ["Remind me to call Mom tomorrow at 5pm", "明天下午5点提醒我给妈妈打电话"] {
      XCTAssertEqual(ChatRouting.intent(request), .capture, request)
      XCTAssertNil(
        FastLane.answerTime(request, keeping: old, now: now, calendar: cal),
        "A new reminder must not turn into a move of Dentist: \(request)")
    }
  }

  func testRecapIsShort() {
    let lines = (0..<10).map { (isUser: $0 % 2 == 0, text: String(repeating: "x", count: 300)) }
    let recap = Dialogue.recap(lines)
    XCTAssertEqual(recap.split(separator: "\n").count, 4)
    XCTAssertLessThan(recap.count, 600)
  }
}
