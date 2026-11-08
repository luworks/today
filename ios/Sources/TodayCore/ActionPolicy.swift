import Foundation

/// The agent's twelve tools and their risk metadata (docs/engineering/ai-agent-architecture.md §1.3, §3 O1).
/// Read tools run by themselves; write tools only prepare a proposal, tiered by `ActionPolicy`.
public enum AgentTool: String, CaseIterable, Sendable {
  case getAgenda = "get_agenda"
  case findItems = "find_items"
  case getItem = "get_item"
  case freeTime = "free_time"
  case listLists = "list_lists"
  case getActivity = "get_activity"
  case proposeCreate = "propose_create"
  case proposeEdit = "propose_edit"
  case proposeDelete = "propose_delete"
  case proposeUndo = "propose_undo"
  case reviseProposal = "revise_proposal"
  case proposeTidy = "propose_tidy"

  public enum Effect: String, Sendable { case read, create, modify, delete }
  /// Whether a write can reach other people (an event's attendees). `self` writes stay on this device's planner.
  public enum Audience: String, Sendable { case none, selfOnly, mayReachOthers }

  public struct Metadata: Equatable, Sendable {
    public let effect: Effect
    /// Undoable with an exact receipt (Activity ledger + Undo).
    public let reversible: Bool
    public let audience: Audience
  }

  public var metadata: Metadata {
    switch self {
    case .getAgenda, .findItems, .getItem, .freeTime, .listLists, .getActivity:
      Metadata(effect: .read, reversible: true, audience: .none)
    // Creates are personal: no tool invites anyone (§1.3 "不提供：邀请别人").
    case .proposeCreate: Metadata(effect: .create, reversible: true, audience: .selfOnly)
    case .proposeEdit: Metadata(effect: .modify, reversible: true, audience: .mayReachOthers)
    // Re-creating a deleted event is compensation; invitations already sent can't be recalled.
    case .proposeDelete: Metadata(effect: .delete, reversible: true, audience: .mayReachOthers)
    case .proposeUndo: Metadata(effect: .modify, reversible: true, audience: .mayReachOthers)
    // Revising edits a card that is not decided yet; the revised card is tiered again.
    case .reviseProposal: Metadata(effect: .modify, reversible: true, audience: .mayReachOthers)
    case .proposeTidy: Metadata(effect: .modify, reversible: true, audience: .selfOnly)
    }
  }

  public var isWrite: Bool { metadata.effect != .read }
}

/// Decides how a proposed write is handled: applied right after the reply with Undo, shown as a preview,
/// confirmed with its consequence spelled out, or refused. Pure code; the model never decides this. Product principles 1–6
/// (CLAUDE.md) live here. Called when a card is prepared and again when the user taps Apply (`recheck`).
public enum ActionPolicy {
  public enum Source: String, Sendable {
    /// Rules only (FastLane), on a message the user submitted.
    case fastLane
    /// The model-driven agent loop.
    case agent
    /// An App Intent (Siri / Shortcuts). P5 maps `preview` to the intent's own confirmation.
    case siri
    /// Anything not started by the user in this moment. There is no background autonomy grant.
    case background
  }

  /// Where the words behind the request came from (§3 O3).
  public enum Words: String, Sendable {
    /// Typed or dictated by the user.
    case user
    /// Text that carries data written by others (calendar titles etc.).
    case derived
  }

  public enum Kind: String, Sendable { case reminder, event, alarm, list }

  /// Fields a write can set. A reminder has one date, `due` (principle 3).
  public enum Field: String, Sendable {
    case title, due, start, repeatRule, done, enabled, list, ringsAsAlarm, note
  }

  /// Everything the policy needs, read from the tool metadata and from the live item.
  public struct Request: Equatable, Sendable {
    public var tool: AgentTool
    public var source: Source
    public var words: Words
    public var kind: Kind
    public var fields: Set<Field>
    /// The user's message clearly asks for an action (`asksForAction`), not a question or chit-chat.
    public var askedForAction: Bool
    /// The user explicitly asked to move this meeting (or tapped an AI conflict card), principle 2.
    public var userAskedToMoveEvent: Bool
    public var attendees: Int
    public var affectsSeries: Bool
    /// The item is a note; it becomes a task only from "Make a task" (principle 5).
    public var fromNote: Bool
    /// The user tapped "Make a task" on that note.
    public var viaMakeTask: Bool
    /// The completion would come from stopping an alarm (principle 4).
    public var fromAlarmStop: Bool
    /// The item differs from the snapshot the card was prepared from (§4.2).
    public var changedSincePreview: Bool
    /// The user reported someone else's words or plans (`FastLane.isReportedSpeech`): not a request.
    public var reportedSpeech: Bool
    /// Settings > AI Changes is Preview First: a clear request gets a card to tap, not a direct write.
    public var previewFirst: Bool

    public init(
      tool: AgentTool, source: Source, words: Words = .user, kind: Kind,
      fields: Set<Field> = [], askedForAction: Bool = false,
      userAskedToMoveEvent: Bool = false, attendees: Int = 0, affectsSeries: Bool = false,
      fromNote: Bool = false, viaMakeTask: Bool = false, fromAlarmStop: Bool = false,
      changedSincePreview: Bool = false, reportedSpeech: Bool = false, previewFirst: Bool = false
    ) {
      self.tool = tool
      self.source = source
      self.words = words
      self.kind = kind
      self.fields = fields
      self.askedForAction = askedForAction
      self.userAskedToMoveEvent = userAskedToMoveEvent
      self.attendees = attendees
      self.affectsSeries = affectsSeries
      self.fromNote = fromNote
      self.viaMakeTask = viaMakeTask
      self.fromAlarmStop = fromAlarmStop
      self.changedSincePreview = changedSincePreview
      self.reportedSpeech = reportedSpeech
      self.previewFirst = previewFirst
    }
  }

  public enum Consequence: Equatable, Hashable, Sendable {
    /// Calendar sends an update to this many attendees.
    case notifies(attendees: Int)
    case wholeSeries
    case deletesEvent
  }

  public enum Refusal: String, Equatable, Sendable {
    case readOnlyTool
    case backgroundWrite
    case meetingsStayFixed
    case stoppingAlarmIsNotCompletion
    case noteIsNotATask
    case changedSincePreview
    case reportedSpeech
  }

  public enum Tier: Equatable, Sendable {
    /// Applied right after the reply, with an exact Undo receipt (owner decision 2026-11-02).
    case direct
    /// A card the user taps Add / Apply on: only when the message did not clearly ask for an action
    /// (a question, chit-chat, words written by others) or a Siri intent confirms it itself.
    case preview
    /// A card that names its consequences and is tapped on its own (never "Add all").
    case confirmConsequence(Set<Consequence>)
    case refuse(Refusal)

    /// "Add all" may submit only cards at or below preview (§3 O2).
    public var allowsAddAll: Bool {
      switch self {
      case .direct, .preview: true
      case .confirmConsequence, .refuse: false
      }
    }

    fileprivate var rank: Int {
      switch self {
      case .direct: 0
      case .preview: 1
      case .confirmConsequence: 2
      case .refuse: 3
      }
    }
  }

  public static func tier(_ r: Request) -> Tier {
    let effect = r.tool.metadata.effect
    guard effect != .read else { return .refuse(.readOnlyTool) }
    // Principle 1: nothing applies by itself.
    guard r.source != .background else { return .refuse(.backgroundWrite) }
    // §4.2: a card prepared from a different state is void; prepare a current one.
    guard !r.changedSincePreview else { return .refuse(.changedSincePreview) }
    // Principle 1: what someone else said or plans is not the user's request.
    guard !(r.reportedSpeech && effect == .create) else { return .refuse(.reportedSpeech) }
    // Principle 4: stopping an alarm never finishes a task.
    guard !(r.fromAlarmStop && r.fields.contains(.done)) else {
      return .refuse(.stoppingAlarmIsNotCompletion)
    }
    // Principle 5: ideas aren't obligations.
    guard !(r.fromNote && r.kind != .list && !r.viaMakeTask && effect == .create) else {
      return .refuse(.noteIsNotATask)
    }
    var consequences: Set<Consequence> = []
    if r.kind == .event {
      // Principle 2: meetings stay fixed unless the user asked to move this one.
      if effect == .modify, r.fields.contains(.start), !r.userAskedToMoveEvent {
        return .refuse(.meetingsStayFixed)
      }
      // What leaves the phone can't be recalled by Undo: an update to attendees, a whole series.
      if r.affectsSeries && effect != .create { consequences.insert(.wholeSeries) }
      if r.attendees > 0 && effect != .create {
        consequences.insert(.notifies(attendees: r.attendees))
      }
      if effect == .delete && !consequences.isEmpty { consequences.insert(.deletesEvent) }
    }
    if !consequences.isEmpty { return .confirmConsequence(consequences) }
    // Owner decision 2026-11-02: a clear request in the user's own words is applied right after the
    // reply, with Undo. Questions, chit-chat and words written by others only get a preview.
    if r.words == .user, r.askedForAction, r.source == .fastLane || r.source == .agent {
      return r.previewFirst ? .preview : .direct
    }
    // Principle 6 needs no rule of its own: nothing here moves an overdue item without being asked.
    return .preview
  }

  /// A new item has what it needs to be added without asking: an alarm needs its time, an event its
  /// day. Anything less is a question to the user, never a guess (owner decision 2026-11-02).
  public static func autoAddReady(_ c: Capture) -> Bool {
    guard c.isReadyToAdd else { return false }
    if c.kind == .event { return c.hasDay }
    return true
  }

  /// Whether a submitted message clearly asks Today to do something (create, change, delete, tidy).
  /// Questions ("should I move it?"), chit-chat, declines and someone else's words do not; polite
  /// requests ("can you remind me…", "能帮我设个闹钟吗") do.
  public static func asksForAction(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, !FastLane.isReportedSpeech(t) else { return false }
    if ChatRouting.intent(t) != .conversation, !OneOffReminderRequest.isQuestion(t) { return true }
    // A polite request is phrased as a question; read what it asks for.
    guard
      t.range(
        of: #"^(?:can|could|would|will) you (?:explain|tell me|show me|see|read|remember)\b"#,
        options: [.regularExpression, .caseInsensitive]) == nil,
      let lead = t.range(
        of:
          #"^(?:(?:please\s+)?(?:can|could|would|will) you(?: please)?\s+|(?:请问)?(?:能不能|可不可以|能否|你能|你可以|您能|您可以|可以|能)(?:你|您)?(?:帮我|给我)?)"#,
        options: [.regularExpression, .caseInsensitive])
    else { return false }
    let body = String(t[lead.upperBound...])
      .replacingOccurrences(
        of: #"(?:[,，]?\s*(?:吗|好吗|可以吗|行吗|好不好|可不可以|please))?\s*[?？.。!！]*$"#, with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return !body.isEmpty && ChatRouting.intent(body) != .conversation
      && !OneOffReminderRequest.isQuestion(body)
  }

  public enum Recheck: Equatable, Sendable {
    case apply
    /// The stakes went up since the card was shown (e.g. attendees were added): confirm again.
    case reconfirm(Tier)
    case void(Refusal)
  }

  /// At Apply: tier the request again from live facts and compare with what the user was shown.
  public static func recheck(shown: Tier, now r: Request) -> Recheck {
    let current = tier(r)
    if case .refuse(let reason) = current { return .void(reason) }
    if current == shown || current.rank < shown.rank { return .apply }
    return .reconfirm(current)
  }
}

extension Capture {
  /// What `ActionPolicy` calls this new item.
  public var policyKind: ActionPolicy.Kind {
    kind == .event ? .event : (ringsAsAlarm ? .alarm : .reminder)
  }
}
