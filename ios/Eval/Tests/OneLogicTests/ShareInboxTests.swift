import XCTest

@testable import TodayShared

final class ShareInboxTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()
  // Friday 16 Oct 2026, 22:17
  lazy var now = cal.date(
    from: DateComponents(year: 2026, month: 10, day: 16, hour: 22, minute: 17))!

  func testDraftFromTextAndLinks() {
    let a = ShareInbox.draft(text: "Buy oat milk\nthe barista one", url: nil, pageTitle: nil)
    XCTAssertEqual(a.title, "Buy oat milk")
    XCTAssertEqual(a.note, "the barista one")

    let url = URL(string: "https://www.example.com/a/b")!
    let b = ShareInbox.draft(text: nil, url: url, pageTitle: "How to fix a bike")
    XCTAssertEqual(b.title, "How to fix a bike")
    XCTAssertEqual(b.note, url.absoluteString)

    let c = ShareInbox.draft(text: url.absoluteString, url: url, pageTitle: nil)
    XCTAssertEqual(c.title, "example.com", "a bare link is named after its site")
    XCTAssertEqual(c.note, url.absoluteString)
  }

  func testDays() {
    func day(_ d: Date?) -> DateComponents? {
      d.map { cal.dateComponents([.month, .day, .hour], from: $0) }
    }
    XCTAssertNil(ShareInbox.due(for: .none, now: now, calendar: cal))
    XCTAssertEqual(
      day(ShareInbox.due(for: .today, now: now, calendar: cal)),
      DateComponents(month: 10, day: 16, hour: 0))
    XCTAssertEqual(
      day(ShareInbox.due(for: .tomorrow, now: now, calendar: cal)),
      DateComponents(month: 10, day: 17, hour: 0))
    XCTAssertEqual(
      day(ShareInbox.due(for: .nextWeek, now: now, calendar: cal)),
      DateComponents(month: 10, day: 19, hour: 0))
  }

  func testAppendThenAcknowledgeEmptiesTheInbox() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "share-inbox-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertTrue(ShareInbox.append(SharedReminder(title: "One", sharedAt: now), at: url))
    XCTAssertTrue(
      ShareInbox.append(
        SharedReminder(title: "Two", due: now, sharedAt: now.addingTimeInterval(5)), at: url))
    let read = try ShareInbox.read(at: url)
    XCTAssertEqual(read.map(\.title), ["One", "Two"])
    XCTAssertTrue(ShareInbox.acknowledge(Set(read.map(\.id)), at: url))
    XCTAssertEqual(try ShareInbox.read(at: url), [], "taken once")
  }

  func testReadPreservesAnUndecodableInboxForRecovery() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "share-inbox-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    // A truncated file can still contain the user's reminder text.
    let original = Data(#"[{"title":"Keep the original shared note""#.utf8)
    try original.write(to: url)

    XCTAssertThrowsError(try ShareInbox.read(at: url))
    XCTAssertEqual(
      try Data(contentsOf: url), original, "a decode failure must not delete the only copy")
  }

  func testAppendDoesNotOverwriteAnUndecodableInbox() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "share-inbox-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    // Valid JSON with an unsupported record is also different from an empty inbox.
    let original = Data(#"[{"title":"Keep this","due":"unreadable date"}]"#.utf8)
    try original.write(to: url)

    XCTAssertFalse(
      ShareInbox.append(SharedReminder(title: "New share"), at: url),
      "the Share sheet must report failure")
    XCTAssertEqual(
      try Data(contentsOf: url), original, "a new share must not replace unimported data")
  }

  func testSubmissionFinishesOnlyAfterAWriteAndCanRetryTheSameDraft() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "share-inbox-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let draft = SharedReminder(
      title: "Edited title", note: "Keep my edited note", due: now, sharedAt: now)
    var completions = 0
    // No App Group is a real failure: it must not dismiss the Share sheet or emit a success event.
    XCTAssertFalse(ShareInbox.submit(draft, at: nil) { completions += 1 })
    XCTAssertEqual(completions, 0)

    let damaged = Data("not JSON".utf8)
    try damaged.write(to: url)
    XCTAssertFalse(ShareInbox.submit(draft, at: url) { completions += 1 })
    XCTAssertEqual(completions, 0)
    XCTAssertEqual(try Data(contentsOf: url), damaged)

    // After the inbox is repaired, retrying that same draft succeeds exactly once.
    try XCTUnwrap(ShareInbox.encode([])).write(to: url)
    XCTAssertTrue(ShareInbox.submit(draft, at: url) { completions += 1 })
    XCTAssertEqual(completions, 1)
    XCTAssertEqual(
      try ShareInbox.read(at: url), [draft],
      "title, note and date survive the failed submission and retry")
  }
}
