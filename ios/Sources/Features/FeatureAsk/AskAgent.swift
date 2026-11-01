#if os(iOS)
  import One
  import SwiftUI
  import TodayCore
  import TodayDesignSystem
  import TodayPlatform
  import os

  /// The model Ask's agent talks to (docs/engineering/ai-agent-architecture.md §1.2). The app uses the
  /// Luna Worker; TodayMock and tests use `ScriptedModelClient` fixtures, or none (not signed in), so
  /// the offline path (FastLane previews, §4.7 #3) is what they see by default.
  package struct AgentModel: Sendable {
    package let client: any ModelClient
    /// False when a request can't even be made (no Luna sign-in): Ask goes straight to the rules.
    package let isAvailable: @Sendable () -> Bool

    package init(client: any ModelClient, isAvailable: @escaping @Sendable () -> Bool) {
      self.client = client
      self.isAvailable = isAvailable
    }

    package static var live: AgentModel {
      let client = HostedLunaClient()
      return AgentModel(client: client, isAvailable: { client.isAvailable })
    }

    /// Not signed in: every message FastLane doesn't write directly is handled by the rules.
    package static var unavailable: AgentModel {
      AgentModel(client: ScriptedModelClient([.fail(.unavailable)]), isAvailable: { false })
    }

    /// A scripted model (TodayMock, tests): the steps play in order across the app's runs.
    package static func scripted(_ steps: [ScriptedModelClient.Step]) -> AgentModel {
      AgentModel(client: ScriptedModelClient(steps), isAvailable: { true })
    }
  }

  /// The agent side of one Ask conversation (docs/engineering/ai-agent-architecture.md P2, P4). It owns
  /// the on-phone tools and receives their cards: creates go into Ask's capture stack, changes are
  /// shown here, Tidy uses the Tidy card. Nothing writes until a tap.
  @MainActor @Observable
  final class AskAgentSession: AgentCardSink {
    struct Change: Identifiable {
      let id: String
      var card: AgentCard
      var anchor: UUID
      var status: AgentProposalBook.Status = .open
      var note: String?
      var busy = false
      var undo: (() async -> String?)?
    }

    var changes: [Change] = []
    /// The user message the current run's cards sit under.
    var anchor: UUID?
    @ObservationIgnored let tools: AgentPlannerTools
    @ObservationIgnored var onCreate: (AgentCard, UUID) -> Void = { _, _ in }
    @ObservationIgnored var onReviseCreate: (AgentCard) -> Void = { _ in }
    @ObservationIgnored var onTidy: (AgentCard) -> Void = { _ in }

    static let log = Logger(subsystem: "com.luworks.one", category: "Agent")

    init(tools: AgentPlannerTools) {
      self.tools = tools
      tools.sink = self
    }

    func show(_ card: AgentCard) {
      let anchor = anchor ?? UUID()
      switch card.body {
      case .create: onCreate(card, anchor)
      case .change: changes.append(Change(id: card.id, card: card, anchor: anchor))
      case .tidy: onTidy(card)
      }
    }

    func revise(_ card: AgentCard) {
      switch card.body {
      case .create: onReviseCreate(card)
      case .change:
        if let i = changes.firstIndex(where: { $0.id == card.id }) { changes[i].card = card }
      case .tidy: onTidy(card)
      }
    }

    var hasOpenCards: Bool { tools.book.hasOpen }

    /// A new message that isn't for the agent leaves its open change cards behind, dropped.
    func dropOpenChanges() {
      for i in changes.indices where changes[i].status == .open {
        changes[i].status = .dropped
        tools.mark(changes[i].id, .dropped)
      }
    }

    func cancel(_ id: String) {
      guard let i = changes.firstIndex(where: { $0.id == id }), changes[i].status == .open else {
        return
      }
      changes[i].status = .dropped
      tools.mark(id, .dropped)
    }

    func apply(_ id: String) async {
      guard let i = changes.firstIndex(where: { $0.id == id }), changes[i].status == .open,
        !changes[i].busy
      else { return }
      changes[i].busy = true
      let outcome = await tools.apply(id)
      guard let j = changes.firstIndex(where: { $0.id == id }) else { return }
      changes[j].busy = false
      changes[j].note = outcome.message
      switch outcome.kind {
      case .applied:
        changes[j].status = .applied
        changes[j].undo = outcome.undo
      case .void: changes[j].status = .void
      case .reconfirm:
        if let card = tools.cards[id] { changes[j].card = card }
      case .failed: break
      }
    }

    func undo(_ id: String) async {
      guard let i = changes.firstIndex(where: { $0.id == id }), changes[i].status == .applied,
        let undo = changes[i].undo
      else { return }
      changes[i].busy = true
      let error = await undo()
      guard let j = changes.firstIndex(where: { $0.id == id }) else { return }
      changes[j].busy = false
      if let error {
        changes[j].note = error
      } else {
        changes[j].status = .undone
        changes[j].undo = nil
        tools.mark(id, .undone)
      }
    }

    /// The turn context the model reads at the end of the user's message (§1.5 本轮上下文).
    static func context(
      now: Date, calendar: Calendar, locale: Locale, chinese: Bool, attached: String?
    ) -> String {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = calendar.timeZone
      f.dateFormat = "EEE yyyy-MM-dd HH:mm"
      var lines = [
        "[Context from the app, not the user]",
        "now: \(f.string(from: now)) (\(calendar.timeZone.identifier))",
        "language: \(chinese ? "zh" : (locale.language.languageCode?.identifier ?? "en"))",
        "screen: Ask chat",
      ]
      if let attached { lines.append("attached item: \(attached)") }
      return lines.joined(separator: "\n")
    }

    static func runID() -> String {
      "r" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
    }

    static func logRun(_ r: AgentRunResult, runID: String) {
      let input = r.usage.reduce(0) { $0 + $1.input }
      let cached = r.usage.reduce(0) { $0 + $1.cached }
      let output = r.usage.reduce(0) { $0 + $1.output }
      let first = r.firstCard.map { String(Int($0 * 1000)) } ?? "-"
      let stop: String
      switch r.stop {
      case .finished: stop = "finished"
      case .stepCap: stop = "step_cap"
      case .deadline: stop = "deadline"
      case .cancelled: stop = "cancelled"
      case .failed(let e): stop = "failed:\(e)"
      }
      log.info(
        "AGENT_RUN run=\(runID, privacy: .public) steps=\(r.steps) cards=\(r.cards) first_card_ms=\(first, privacy: .public) total_ms=\(Int(r.duration * 1000)) input=\(input) cached=\(cached) output=\(output) cost_micros=\(r.costMicros) stop=\(stop, privacy: .public) calls=\(r.calls.joined(separator: ","), privacy: .public)"
      )
    }
  }

  /// An agent change card: code-rendered before → after, consequences that must be confirmed, the
  /// model's note marked as an AI note, and a status footer set by code (Applied · Undo).
  struct AgentChangeCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let change: AskAgentSession.Change
    var onApply: () -> Void
    var onCancel: () -> Void
    var onUndo: () -> Void

    private var body_: AgentChange? {
      if case .change(let c) = change.card.body { return c }
      return nil
    }

    private var zh: Bool { change.card.chinese }

    private var heading: String {
      guard let c = body_ else { return "" }
      let kind: String
      switch c.kind {
      case .reminder: kind = zh ? "提醒" : "reminder"
      case .event: kind = zh ? "事件" : "event"
      case .alarm: kind = zh ? "闹钟" : "alarm"
      case .list: kind = zh ? "列表" : "list"
      }
      switch c.operation {
      case .move: return zh ? "改时间 · \(kind)" : "Move \(kind)"
      case .rename: return zh ? "改名 · \(kind)" : "Rename \(kind)"
      case .done: return zh ? "标为完成 · \(kind)" : "Complete \(kind)"
      case .delete: return zh ? "删除 · \(kind)" : "Delete \(kind)"
      }
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Label(heading, systemImage: "sparkles")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let c = body_ {
          Text(c.title).font(.headline)
          if c.isDelete {
            Text(c.before).font(.subheadline).foregroundStyle(.secondary).strikethrough()
          } else {
            Text("\(c.before) → \(c.after)")
              .font(.subheadline)
              .accessibilityIdentifier("agent-change-times")
          }
        }
        ForEach(change.card.consequences, id: \.self) { line in
          Label(line, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .accessibilityIdentifier("agent-consequence")
        }
        if let why = change.card.why {
          Text((zh ? "AI 说明：" : "AI note: ") + why)
            .font(.caption)
            .foregroundStyle(.secondary)
            .italic()
        }
        if let note = change.note {
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
        footer.padding(.top, 4)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25)))
      .opacity(change.status == .dropped || change.status == .void ? 0.55 : 1)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("agent-change-card")
    }

    @ViewBuilder private var footer: some View {
      switch change.status {
      case .open:
        HStack {
          Button(zh ? "取消" : "Cancel", action: onCancel).buttonStyle(.bordered)
          Spacer()
          Button(action: onApply) {
            Text(
              body_?.isDelete == true
                ? (zh ? "删除" : "Delete")
                : (change.card.consequences.isEmpty
                  ? (zh ? "应用" : "Apply") : (zh ? "确认并应用" : "Confirm"))
            )
            .foregroundStyle(
              (body_?.isDelete == true ? Color.red : Color.accentColor).contrastForeground(
                for: colorScheme))
          }
          .buttonStyle(.borderedProminent)
          .tint(body_?.isDelete == true ? .red : .accentColor)
          .disabled(change.busy)
          .accessibilityIdentifier("agent-change-apply")
        }
      case .applied:
        HStack {
          Label(zh ? "已应用" : "Applied", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
          Spacer()
          if change.undo != nil {
            Button(zh ? "撤销" : "Undo", action: onUndo)
              .font(.subheadline.weight(.semibold))
              .disabled(change.busy)
              .accessibilityIdentifier("agent-change-undo")
          }
        }
      case .undone:
        Text(zh ? "已撤销" : "Undone").font(.subheadline).foregroundStyle(.secondary)
      case .dropped, .added:
        Text(zh ? "已取消" : "Dropped").font(.subheadline).foregroundStyle(.secondary)
      case .void:
        Text(zh ? "已作废" : "Void").font(.subheadline).foregroundStyle(.secondary)
      }
    }
  }
#endif
