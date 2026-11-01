import Foundation

/// The cards one conversation's agent has proposed, by proposal id ("p1", "p2" …). Code owns their
/// status; the model can only read it back. `revise_proposal` works only on undecided cards (§1.3),
/// and "Add all" never submits a card that must be confirmed on its own (§3 O2).
public struct AgentProposalBook: Equatable, Sendable {
  public enum Status: String, Equatable, Sendable {
    case open, added, applied, dropped, undone, void
    public var isDecided: Bool { self != .open }
  }

  public struct Entry: Equatable, Sendable {
    public var id: String
    public var tool: AgentTool
    public var kind: String
    public var tier: ActionPolicy.Tier
    public var status: Status
    /// Short id of the item this card touches, or of the item it created once added.
    public var itemID: String?
    /// The run (one user message) that proposed it.
    public var run: String
    /// Creates with the same content in one run are one card.
    public var contentKey: String?
  }

  public enum ReviseError: Error, Equatable, Sendable {
    case unknown
    case decided(Status, itemID: String?)
  }

  public private(set) var entries: [Entry] = []
  private var next = 1

  public init() {}

  /// Registers a new card. A create with the same content as an earlier card of the same run returns that card.
  public mutating func open(
    tool: AgentTool, kind: String, tier: ActionPolicy.Tier, itemID: String? = nil, run: String,
    contentKey: String? = nil
  ) -> (id: String, duplicate: Bool) {
    if let contentKey,
      let same = entries.first(where: { $0.run == run && $0.contentKey == contentKey })
    {
      return (same.id, true)
    }
    let id = "p\(next)"
    next += 1
    entries.append(
      Entry(
        id: id, tool: tool, kind: kind, tier: tier, status: .open, itemID: itemID, run: run,
        contentKey: contentKey))
    return (id, false)
  }

  public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

  /// The card `revise_proposal` may change, or why it may not.
  public func revisable(_ id: String) -> Result<Entry, ReviseError> {
    guard let e = entry(id) else { return .failure(.unknown) }
    guard !e.status.isDecided else { return .failure(.decided(e.status, itemID: e.itemID)) }
    return .success(e)
  }

  public mutating func set(_ id: String, status: Status, itemID: String? = nil) {
    guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[i].status = status
    if let itemID { entries[i].itemID = itemID }
  }

  public mutating func retier(_ id: String, _ tier: ActionPolicy.Tier) {
    guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[i].tier = tier
  }

  /// What "Add all" submits: open cards at or below preview. confirmConsequence cards are tapped one by one.
  public func addAll(run: String? = nil) -> [String] {
    entries.filter {
      $0.status == .open && $0.tier.allowsAddAll && (run == nil || $0.run == run)
    }.map(\.id)
  }

  public var hasOpen: Bool { entries.contains { $0.status == .open } }
}

/// Which lane a submitted message takes when the agent is on (§4.2 "多轮续答").
public enum AgentRouting {
  /// FastLane runs first. Its direct one-off reminder always wins. Corrections and continuation
  /// answers belong to the agent while the agent's own cards are open: continuations only ever
  /// complete FastLane's own drafts, never Apply an agent card.
  public static func useAgent(_ decision: FastLane.Decision, agentHasOpenCards: Bool) -> Bool {
    switch decision {
    case .directReminder: false
    case .clarifyCorrection, .continuation: agentHasOpenCards
    case .notFastLane: true
    }
  }

  /// The user's own words ask to move or reschedule something (principle 2: meetings move only
  /// when asked). Read from the typed text by rules, never from the model's call.
  public static func userAskedToMove(_ text: String) -> Bool {
    text.range(
      of:
        #"(?i)[改推挪调换移延提][到成在至前后]|推迟|延后|提前|改期|改时间|换个时间|\b(move|moved|reschedule|push|postpone|bring forward|shift|change)\b|其实是"#,
      options: .regularExpression) != nil
  }
}

/// The agent's replayable history for one conversation, stored in `ChatThread.agentItemsData`
/// (§1.5): items exactly as exchanged, the version they were made with, and the short ids the
/// model has seen. Older or oversized history is compacted to text plus card receipts.
public struct AgentHistory: Codable, Equatable, Sendable {
  public struct Meta: Codable, Equatable, Sendable {
    public var model: String
    public var toolsVersion: String
    public var created: Date

    enum CodingKeys: String, CodingKey {
      case model
      case toolsVersion = "tools_version"
      case created
    }
  }

  public var meta: Meta
  public var items: [JSONValue]
  /// Short id ("t3", "e1", "a2") → stable item reference.
  public var ids: [String: String]

  /// Replayed history above this size is compacted (the Worker accepts 256 KB per step).
  public static let maxBytes = 160_000
  public static let maxItems = 200

  public init(now: Date) {
    meta = Meta(
      model: AgentContract.model, toolsVersion: AgentContract.toolsVersion, created: now)
    items = []
    ids = [:]
  }

  public static func restore(_ data: Data, now: Date) -> AgentHistory {
    guard !data.isEmpty, let h = try? JSONDecoder().decode(AgentHistory.self, from: data) else {
      return AgentHistory(now: now)
    }
    return h
  }

  public var encoded: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(self)) ?? Data()
  }

  public var isCurrent: Bool {
    meta.model == AgentContract.model && meta.toolsVersion == AgentContract.toolsVersion
  }

  public var needsCompaction: Bool {
    !isCurrent || items.count > Self.maxItems
      || items.reduce(0) { $0 + $1.text.utf8.count } > Self.maxBytes
  }

  // MARK: Short ids

  /// The short id for an item, assigned once per conversation so earlier turns keep meaning the same item.
  public mutating func shortID(for ref: String, prefix: String) -> String {
    if let known = ids.first(where: { $0.value == ref })?.key { return known }
    let n =
      (ids.keys.filter { $0.hasPrefix(prefix) }.compactMap { Int($0.dropFirst(prefix.count)) }
        .max() ?? 0) + 1
    let id = "\(prefix)\(n)"
    ids[id] = ref
    return id
  }

  public func ref(for shortID: String) -> String? { ids[shortID] }

  // MARK: Turns that did not go through the model

  /// A FastLane turn: what the user said and a receipt of what code did, so "其实是4点" next can
  /// find the item (§1.5 "快车道写进历史").
  public mutating func appendReceipt(user: String, receipt: String) {
    items.append(AgentItem.userMessage(user))
    items.append(AgentItem.assistantMessage(receipt))
  }

  /// Replaces the replayable items with plain text: the recent conversation and the card receipts.
  /// Used when the version changed, the history is too big, or a replay was rejected.
  public mutating func compact(
    transcript: [(isUser: Bool, text: String)], receipts: [String], now: Date
  ) {
    var summary: [JSONValue] = []
    for turn in transcript.suffix(12) {
      let text = String(turn.text.prefix(600))
      guard !text.isEmpty else { continue }
      summary.append(turn.isUser ? AgentItem.userMessage(text) : AgentItem.assistantMessage(text))
    }
    if !receipts.isEmpty {
      summary.append(
        AgentItem.assistantMessage(
          "Card receipts so far (status is set by the app):\n" + receipts.joined(separator: "\n")))
    }
    items = summary
    meta = Meta(
      model: AgentContract.model, toolsVersion: AgentContract.toolsVersion, created: now)
  }
}
