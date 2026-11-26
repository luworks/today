import Foundation

/// Where a preview card is in its life. The card stays in the conversation in every state; only its footer changes:
/// open (Cancel / Add), added (Added · Undo · Open), dropped (dimmed, no actions), undone (Undone · Add again).
public enum CardStatus: String, Codable, Equatable {
  case open, added, dropped, undone

  public enum Event { case add, drop, undo }

  /// The state after `event`, or nil when it does not apply (nothing changes then).
  public func after(_ event: Event) -> CardStatus? {
    switch (self, event) {
    case (.open, .add), (.undone, .add): .added
    case (.open, .drop): .dropped
    case (.added, .undo): .undone
    default: nil
    }
  }

  /// Whether the card offers Add (or Add again).
  public var canAdd: Bool { after(.add) != nil }
  public var canUndo: Bool { after(.undo) != nil }
  public var canDrop: Bool { after(.drop) != nil }

  /// What the footer says. Empty while the card is still open.
  public var footerTitle: String {
    switch self {
    case .open: ""
    case .added: "Added"
    case .dropped: "Dropped"
    case .undone: "Undone"
    }
  }

  /// The card's spoken label once decided: "Added: Call Alex, Tomorrow 15:00 · alerts you".
  public func accessibilityLabel(for capture: Capture) -> String {
    switch self {
    case .open: capture.title + ", " + capture.summary
    default: footerTitle + ": " + capture.title + ", " + capture.summary
    }
  }
}

/// A capture card saved with its conversation, including open agent and recoverable local drafts. `itemRef` and `entryID` say what Add wrote, so Undo can take back exactly that.
public struct StoredCard: Codable, Equatable, Identifiable {
  public var id: UUID
  /// The AI message the card sits under.
  public var anchor: UUID
  /// Cards from one line share a batch (they are one card, or one list of rows).
  public var batch: UUID
  public var batchSize: Int
  public var capture: Capture
  public var status: CardStatus
  /// JSON of the created item's persistent id (`Ledger.ref`), nil before it is added or after it was undone.
  public var itemRef: String?
  /// The Activity entry that recorded the creation, so Undo is recorded against it.
  public var entryID: UUID?
  /// A failed submitted one-off request remains recoverable across chat reopen.
  public var retainsDraft: Bool = false
  public var pendingExternalID: String?
  public var agentID: String?

  public var shouldPersist: Bool { status != .open || retainsDraft || agentID != nil }

  public init(
    id: UUID, anchor: UUID, batch: UUID, batchSize: Int, capture: Capture, status: CardStatus,
    itemRef: String? = nil, entryID: UUID? = nil, retainsDraft: Bool = false,
    pendingExternalID: String? = nil, agentID: String? = nil
  ) {
    self.id = id
    self.anchor = anchor
    self.batch = batch
    self.batchSize = batchSize
    self.capture = capture
    self.status = status
    self.itemRef = itemRef
    self.entryID = entryID
    self.retainsDraft = retainsDraft
    self.pendingExternalID = pendingExternalID
    self.agentID = agentID
  }

  private enum CodingKeys: String, CodingKey {
    case id, anchor, batch, batchSize, capture, status, itemRef, entryID, retainsDraft,
      pendingExternalID, agentID
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    anchor = try c.decode(UUID.self, forKey: .anchor)
    batch = try c.decodeIfPresent(UUID.self, forKey: .batch) ?? id
    batchSize = try c.decodeIfPresent(Int.self, forKey: .batchSize) ?? 1
    capture = try c.decode(Capture.self, forKey: .capture)
    // A missing or unknown status is read as "nothing to show" (see `restore`).
    status = (try? c.decodeIfPresent(CardStatus.self, forKey: .status)) ?? .open
    itemRef = try c.decodeIfPresent(String.self, forKey: .itemRef)
    entryID = try c.decodeIfPresent(UUID.self, forKey: .entryID)
    retainsDraft = try c.decodeIfPresent(Bool.self, forKey: .retainsDraft) ?? false
    pendingExternalID = try c.decodeIfPresent(String.self, forKey: .pendingExternalID)
    agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
  }

  /// The cards to keep for a conversation.
  public static func encode(_ cards: [StoredCard]) -> Data {
    (try? JSONEncoder().encode(cards.filter(\.shouldPersist))) ?? Data()
  }

  /// Saved cards back. Old conversations (no data), damaged entries and cards with no final status give nothing extra,
  /// and one bad card never takes the others with it.
  public static func restore(_ data: Data) -> [StoredCard] {
    guard !data.isEmpty, let items = try? JSONDecoder().decode([Lossy].self, from: data) else {
      return []
    }
    return items.compactMap(\.card).filter(\.shouldPersist)
  }

  private struct Lossy: Decodable {
    let card: StoredCard?
    init(from decoder: Decoder) throws { card = try? StoredCard(from: decoder) }
  }
}
