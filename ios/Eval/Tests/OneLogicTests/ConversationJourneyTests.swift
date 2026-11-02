import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class ConversationJourneyTests: XCTestCase {
  private struct Journey: Decodable {
    let name: String
    let steps: [Step]
  }
  private struct Step: Decodable {
    let text: String
    let route: String
    let thread: String
    let action: String
    let writes: Int
    let title: String?
    let hour: Int?
    let minute: Int?
    let day: Int?
    let alarm: Bool?
    let resume: Bool?
  }

  func testBilingualConversationJourneys() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "conversation-journeys", withExtension: "json"))
    let journeys = try JSONDecoder().decode([Journey].self, from: Data(contentsOf: url))
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9)))
    for journey in journeys {
      var threads: [String: [(isUser: Bool, text: String)]] = [:]
      var pending: [String: Capture] = [:]
      for step in journey.steps {
        let note = "\(journey.name): \(step.text)"
        // stored chats restore messages, not open cards
        if step.resume == true { pending[step.thread] = nil }
        let context = ConversationContext(threads[step.thread] ?? [])
        let old = pending[step.thread]
        var route = "conversation"
        if let result = CaptureConversation.resolve(
          step.text, context: context, pending: old, now: now, calendar: cal)
        {
          pending[step.thread] = result
          route = old == nil ? "capture" : "update"
        } else if ChatRouting.intent(step.text) != .conversation {
          if let old,
            case .updated(let result) = Dialogue.refine(
              old, with: step.text, now: now, calendar: cal)
          {
            pending[step.thread] = result
            route = "update"
          } else if ChatRouting.intent(step.text) == .capture {
            pending[step.thread] = CaptureConversation.parse(step.text, now: now, calendar: cal)
            route = "capture"
          }
        }
        XCTAssertEqual(route, step.route, note)
        if let title = step.title {
          XCTAssertTrue(
            pending[step.thread]?.title.localizedCaseInsensitiveContains(title) == true,
            "\(note): \(pending[step.thread]?.title ?? "nil")")
        }
        if let hour = step.hour { XCTAssertEqual(pending[step.thread]?.hour, hour, note) }
        if let minute = step.minute { XCTAssertEqual(pending[step.thread]?.minute, minute, note) }
        if let day = step.day, let capture = pending[step.thread] {
          XCTAssertEqual(
            cal.dateComponents([.day], from: cal.startOfDay(for: now), to: capture.day).day, day,
            note)
        }
        if let alarm = step.alarm {
          XCTAssertEqual(pending[step.thread]?.ringsAsAlarm, alarm, note)
        }
        if route == "conversation" {
          XCTAssertEqual(pending[step.thread], old, "Chat must not mutate a preview: \(note)")
        }
        if step.text == "make it an alarm" && step.hour == nil {
          XCTAssertNil(pending[step.thread]?.hour, note)
        }
        XCTAssertEqual(step.action, route == "conversation" ? "conversation" : "preview", note)
        threads[step.thread, default: []].append((true, step.text))
        threads[step.thread, default: []].append((false, "Preview or conversational response"))
      }
    }
  }

  func testContextIsBoundedAndScopedToSuppliedThread() {
    let context = ConversationContext(
      (0..<30).map { (true, String(repeating: "x", count: 600) + "\($0)") })
    XCTAssertLessThanOrEqual(context.turns.count, 8)
    XCTAssertLessThanOrEqual(context.turns.reduce(0) { $0 + $1.text.count }, 1600)
    XCTAssertTrue(ConversationContext([]).turns.isEmpty)
  }
}
