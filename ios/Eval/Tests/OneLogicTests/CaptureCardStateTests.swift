import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// A preview card stays in the chat after Add / Cancel: its status moves open → added → undone → added, or open → dropped,
/// and the decided cards are saved with the conversation.
final class CaptureCardStateTests: XCTestCase {
  func testTransitions() {
    XCTAssertEqual(CardStatus.open.after(.add), .added)
    XCTAssertEqual(CardStatus.open.after(.drop), .dropped)
    XCTAssertEqual(CardStatus.added.after(.undo), .undone)
    XCTAssertEqual(CardStatus.undone.after(.add), .added, "Add again")
    // Everything else is refused, so a double tap never writes twice.
    XCTAssertNil(CardStatus.added.after(.add))
    XCTAssertNil(CardStatus.added.after(.drop))
    XCTAssertNil(CardStatus.open.after(.undo))
    XCTAssertNil(CardStatus.dropped.after(.add))
    XCTAssertNil(CardStatus.dropped.after(.undo))
    XCTAssertNil(CardStatus.undone.after(.undo))
    XCTAssertNil(CardStatus.undone.after(.drop))
  }

  // MARK: Saving with the conversation

  private func card(_ status: CardStatus, title: String = "Call Alex") -> StoredCard {
    var capture = Capture(
      title: title, day: Date(timeIntervalSince1970: 1_800_000_000), hasDay: true, hour: 15,
      minute: 0)
    capture.listName = "Inbox"
    return StoredCard(
      id: UUID(), anchor: UUID(), batch: UUID(), batchSize: 1, capture: capture, status: status,
      itemRef: status == .added ? "{\"ref\":1}" : nil, entryID: status == .added ? UUID() : nil)
  }

  func testCardsStillOpenAreNotKept() {
    let kept = StoredCard.restore(StoredCard.encode([card(.open), card(.added)]))
    XCTAssertEqual(kept.map(\.status), [.added])
  }

  func testOldConversationsShowNothingExtra() {
    XCTAssertEqual(StoredCard.restore(Data()), [])
    XCTAssertEqual(StoredCard.restore(Data("not json".utf8)), [])
    XCTAssertEqual(StoredCard.restore(Data("[]".utf8)), [])
  }

  func testMissingOrUnknownStatusShowsNothing() throws {
    var json =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(card(.added))) as! [String: Any]
    json.removeValue(forKey: "status")
    let missing = try JSONSerialization.data(withJSONObject: [json])
    XCTAssertEqual(StoredCard.restore(missing), [], "no status = old behaviour: nothing extra")
    json["status"] = "archived-by-a-newer-version"
    let unknown = try JSONSerialization.data(withJSONObject: [json])
    XCTAssertEqual(StoredCard.restore(unknown), [])
  }

  func testOneBadCardDoesNotTakeTheOthersWithIt() throws {
    let good =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(card(.dropped))) as! [String: Any]
    let data = try JSONSerialization.data(withJSONObject: [["id": "nope"], good])
    XCTAssertEqual(StoredCard.restore(data).map(\.status), [.dropped])
  }

  func testOlderCardWithoutOptionalFieldsStillDecodes() throws {
    var json =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(card(.added))) as! [String: Any]
    for key in ["itemRef", "entryID", "batch", "batchSize"] { json.removeValue(forKey: key) }
    let back = StoredCard.restore(try JSONSerialization.data(withJSONObject: [json]))
    XCTAssertEqual(back.count, 1)
    XCTAssertNil(back[0].itemRef)
    XCTAssertEqual(back[0].batchSize, 1)
  }
}
