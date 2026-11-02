import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class ConversationHistoryTests: XCTestCase {
  var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()

  func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
  }

  /// "Now" is Fri Oct 16 2026, 10:00.
  var now: Date { date(16, 10) }

  func testBucketsFollowCalendarDays() {
    XCTAssertEqual(ConversationBucket.of(date(16, 0, 5), now: now, calendar: cal), .today)
    XCTAssertEqual(ConversationBucket.of(date(15, 23, 55), now: now, calendar: cal), .yesterday)
    XCTAssertEqual(ConversationBucket.of(date(14, 12), now: now, calendar: cal), .previous7Days)
    // 7 days ago
    XCTAssertEqual(ConversationBucket.of(date(9, 0, 1), now: now, calendar: cal), .previous7Days)
    // 8 days ago
    XCTAssertEqual(ConversationBucket.of(date(8, 23, 59), now: now, calendar: cal), .older)
  }

  func testFutureDateCountsAsToday() {
    XCTAssertEqual(ConversationBucket.of(date(17, 9), now: now, calendar: cal), .today)
  }

  func testGroupsNewestFirstAndSkipsEmptyBuckets() {
    let items = [
      ("old", date(1, 9)), ("today-early", date(16, 8)), ("last-week", date(12, 9)),
      ("today-late", date(16, 9)),
    ]
    let groups = ConversationHistory.group(items, date: { $0.1 }, now: now, calendar: cal)
    XCTAssertEqual(groups.map(\.bucket), [.today, .previous7Days, .older])
    XCTAssertEqual(groups[0].items.map(\.0), ["today-late", "today-early"])
  }

  func testEmptyInputGivesNoGroups() {
    XCTAssertTrue(
      ConversationHistory.group([Date](), date: { $0 }, now: now, calendar: cal).isEmpty)
  }

  func testTitleCollapsesWhitespaceAndCaps() {
    XCTAssertEqual(
      ConversationHistory.title(from: "  Call   Alex\n tomorrow "), "Call Alex tomorrow")
    XCTAssertEqual(ConversationHistory.title(from: "   "), "New chat")
    let long = String(repeating: "word ", count: 40)
    let t = ConversationHistory.title(from: long, limit: 20)
    XCTAssertTrue(t.hasSuffix("…"))
    XCTAssertLessThanOrEqual(t.count, 21)
  }
}

/// Chats settle by themselves: a week idle, or an hour after everything they added is done.
final class AutoArchiveTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testAWeekWithoutMessagesArchives() {
    XCTAssertTrue(
      ConversationHistory.shouldAutoArchive(
        updatedAt: now.addingTimeInterval(-7 * 86_400), settled: [], now: now))
    XCTAssertFalse(
      ConversationHistory.shouldAutoArchive(
        updatedAt: now.addingTimeInterval(-6 * 86_400), settled: [], now: now))
  }

  func testEverythingDoneArchivesAfterAnHour() {
    XCTAssertTrue(
      ConversationHistory.shouldAutoArchive(
        updatedAt: now.addingTimeInterval(-3_600), settled: [true, true], now: now))
    XCTAssertFalse(
      ConversationHistory.shouldAutoArchive(
        updatedAt: now.addingTimeInterval(-600), settled: [true], now: now),
      "not while you are still in it")
    XCTAssertFalse(
      ConversationHistory.shouldAutoArchive(
        updatedAt: now.addingTimeInterval(-3_600), settled: [true, false], now: now),
      "one open item keeps it")
    XCTAssertFalse(
      ConversationHistory.shouldAutoArchive(
        updatedAt: now.addingTimeInterval(-3_600), settled: [], now: now),
      "a chat that added nothing waits for the week")
  }

  func testContextIsBoundedAndScopedToSuppliedThread() {
    let context = ConversationContext(
      (0..<30).map { (true, String(repeating: "x", count: 600) + "\($0)") })
    XCTAssertLessThanOrEqual(context.turns.count, 8)
    XCTAssertLessThanOrEqual(context.turns.reduce(0) { $0 + $1.text.count }, 1600)
    XCTAssertTrue(ConversationContext([]).turns.isEmpty)
  }
}
