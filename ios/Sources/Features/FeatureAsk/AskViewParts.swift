#if os(iOS)
  import One
  import TodayCore
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import SwiftUI
  import SwiftData

  /// User messages are bubbles on the right; AI replies are plain text, no bubble. Text can be selected
  /// (long-press), and a small copy button sits under each message, as in ChatGPT.
  package struct MessageView: View {
    package let message: ChatMessage
    @State private var copied = false

    package var body: some View {
      switch message.role {
      case .user:
        VStack(alignment: .trailing, spacing: 4) {
          HStack {
            Spacer(minLength: 48)
            Text(message.text)
              .textSelection(.enabled)
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
              .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 20))
          }
          copyButton
        }
      case .ai:
        VStack(alignment: .leading, spacing: 4) {
          Text(message.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          // The app's own status sentences ("Here's what I understood…", "Updated…") have nothing worth copying.
          if !message.isTemplate { copyButton }
        }
      }
    }

    private var copyButton: some View {
      Button {
        UIPasteboard.general.string = message.text
        copied = true
        Task {
          try? await Task.sleep(for: .seconds(1.5))
          copied = false
        }
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(width: 44, height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .sensoryFeedback(.success, trigger: copied) { _, new in new }
      .accessibilityLabel(copied ? "Copied" : "Copy message")
      .accessibilityIdentifier("message.copy")
    }

    package init(message: ChatMessage) { self.message = message }
  }

  /// One overdue reminder on the tidy card, with the date the user picked for it.
  package struct TidyRow: Identifiable {
    package let id = UUID()
    package let task: OneTask
    package let oldDue: Date
    package var choice: OverdueTidy.Choice

    package init(task: OneTask, oldDue: Date, choice: OverdueTidy.Choice) {
      self.task = task
      self.oldDue = oldDue
      self.choice = choice
    }
  }

  /// "Tidy overdue" preview: a suggested date per reminder, each changeable from its menu; Apply writes them all.
  package struct TidyCard: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    @Binding package var rows: [TidyRow]
    package var onApply: () -> Void
    package var onCancel: () -> Void

    package var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Label("New dates for overdue", systemImage: "sparkles")
          .font(.caption)
          .foregroundStyle(.secondary)
        ViewThatFits(in: .vertical) {
          list
          ScrollView { list }
        }
        .frame(maxHeight: 240)
        HStack {
          Button("Cancel", action: onCancel).buttonStyle(.bordered)
          Spacer()
          Button(action: onApply) {
            Text("Apply").foregroundStyle(Color.accentColor.contrastForeground(for: colorScheme))
          }
          .buttonStyle(.borderedProminent)
          .disabled(rows.allSatisfy { $0.choice == .keep })
          .accessibilityIdentifier("tidy.apply")
        }
        .padding(.top, 4)
      }
      .padding(14)
      .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private var list: some View {
      VStack(spacing: 6) {
        ForEach($rows) { $row in
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
              Text(row.task.title).font(.subheadline).lineLimit(1)
              Text("was " + plannerDayLabel(row.oldDue, runtime: presentation.runtime)).font(
                .caption
              ).foregroundStyle(.red)
            }
            Spacer(minLength: 8)
            Menu {
              Picker("New date", selection: $row.choice) {
                ForEach(OverdueTidy.choices(repeats: row.task.repeats != nil)) {
                  Text($0.rawValue).tag($0)
                }
              }
            } label: {
              HStack(spacing: 4) {
                Text(row.choice.rawValue)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
              }
              .font(.subheadline)
              .foregroundStyle(row.choice == .keep ? Color.secondary : Color.accentColor)
            }
            .accessibilityIdentifier("tidy.choice.\(row.task.title)")
            .accessibilityValue(row.choice.rawValue)
          }
        }
      }
    }

    package init(
      rows: Binding<[TidyRow]>, onApply: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
      _rows = rows
      self.onApply = onApply
      self.onCancel = onCancel
    }
  }

  /// An AI edit waiting for Apply: what changes and who it reaches. Nothing has been written yet.
  package struct PendingChange: Equatable, Identifiable {
    package enum Subject {
      case task(OneTask)
      case event(OneEvent)
      case alarm(OneAlarm)
      case systemEvent
    }
    package let id = UUID()
    package let subject: Subject
    package let delete: Bool
    package let title: String
    package let oldText: String
    package var newStart: Date?
    package let notes: [String]
    package let attendees: Int
    package var newRepeatRule: String?
    package var expectedTask: TaskSnapshot?
    package var attachedOperation: AttachedItemEdit.Operation?
    package var alarmChange: AttachedAlarmChange?
    package var systemMove: CalendarMoveSnapshot?

    package static func == (a: PendingChange, b: PendingChange) -> Bool { a.id == b.id }

    /// The write this card stands for; nil for subjects Ask applies elsewhere (alarms, Apple Calendar).
    @MainActor
    package var proposal: ChangeProposal? {
      let target: ChangeProposal.Target
      switch subject {
      case .task(let task): target = .task(task)
      case .event(let event): target = .event(event)
      case .alarm, .systemEvent: return nil
      }
      let edit: ChangeProposal.Edit?
      if delete {
        edit = .delete
      } else if case .task = subject, let rule = newRepeatRule, let due = newStart {
        edit = .setRepeat(rule: rule, due: due)
      } else if let newStart {
        edit = .move(newStart)
      } else {
        edit = nil
      }
      var expected: ProposalSnapshot?
      if case .task = subject { expected = expectedTask.map(ProposalSnapshot.init(task:)) }
      return ChangeProposal(
        target: target, edit: edit, oldText: oldText, attendees: attendees, expected: expected)
    }

    package var isEvent: Bool {
      switch subject {
      case .event, .systemEvent: true
      default: false
      }
    }

    package init(
      subject: Subject, delete: Bool, title: String, oldText: String,
      newStart: Date?, notes: [String], attendees: Int
    ) {
      self.subject = subject
      self.delete = delete
      self.title = title
      self.oldText = oldText
      self.newStart = newStart
      self.notes = notes
      self.attendees = attendees
    }
  }

  package struct UndoRow: Identifiable {
    package let id = UUID()
    package let label: String
    package let action: () -> Void

    package init(label: String, action: @escaping () -> Void) {
      self.label = label
      self.action = action
    }
  }

  /// AI change preview: old → new, who is affected, applied only on tap.
  package struct ChangeCard: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    package let change: PendingChange
    package var onApply: () -> Void
    package var onCancel: () -> Void

    package var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Label(heading, systemImage: "sparkles")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(change.title).font(.headline)
        if change.delete {
          Text(change.oldText).font(.subheadline).foregroundStyle(.secondary)
        } else if case .rename(let name)? = change.attachedOperation {
          Text("\(change.title) → \(name)").font(.subheadline)
        } else if case .done? = change.attachedOperation {
          Text("Mark completed").font(.subheadline)
        } else if let new = change.newStart {
          Text("\(change.oldText) → \(plannerDayLabel(new, runtime: presentation.runtime))")
            .font(.subheadline)
            .accessibilityIdentifier("change-times")
        }
        ForEach(change.notes, id: \.self) { note in
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Cancel", action: onCancel).buttonStyle(.bordered)
          Spacer()
          Button(action: onApply) {
            Text(change.delete ? "Delete" : "Apply")
              .foregroundStyle(Color.accentColor.contrastForeground(for: colorScheme))
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(.top, 4)
      }
      .padding(14)
      .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25)))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("change-card")
    }

    private var heading: String {
      if change.attachedOperation != nil { return "Change item" }
      if change.newRepeatRule != nil { return "Change reminder" }
      switch (change.delete, change.isEvent) {
      case (false, false): return "Move task"
      case (false, true): return "Move event"
      case (true, false): return "Delete task"
      case (true, true): return "Delete event"
      }
    }

    package init(
      change: PendingChange, onApply: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
      self.change = change
      self.onApply = onApply
      self.onCancel = onCancel
    }
  }

  /// Native mutation feedback shared by Ask and deterministic scenes. Call Undo through the caller's Activity/UI host.
  @MainActor
  package struct AskActionFeedback {
    package var messages: [ChatMessage] = []
    package var undo: UndoRow?
    package var applied = true
  }

  /// Real approved Ask mutations. These functions never run while a proposal is merely being prepared.
  @MainActor
  package enum AskNativeActions {
    package static func applyChange(
      _ c: PendingChange, context: ModelContext, calendar: any CalendarService,
      actions: PlannerActions, ledger: Ledger, runtime: PlannerRuntime
    ) -> AskActionFeedback {
      guard let proposal = c.proposal else {
        var feedback = AskActionFeedback()
        feedback.applied = false
        return feedback
      }
      return feedback(
        ToolRegistry.apply(
          proposal, context: context, calendar: calendar, actions: actions, ledger: ledger),
        runtime: runtime)
    }

    /// A user-approved move of one Apple Calendar occurrence. `report` posts replies that arrive later (Undo).
    /// `moved` is the verified result, so the caller can point its attached subject at it.
    package static func applySystemMove(
      _ snapshot: CalendarMoveSnapshot, to start: Date, context: ModelContext,
      calendar: any CalendarService, ledger: Ledger, runtime: PlannerRuntime,
      report: @escaping (ChatMessage) -> Void
    ) -> (feedback: AskActionFeedback, moved: CalendarMoveSnapshot?) {
      let outcome = ToolRegistry.apply(
        SystemMoveProposal(expected: snapshot, start: start), context: context,
        calendar: calendar, ledger: ledger,
        report: { report(ChatMessage(role: .ai, text: $0, timestamp: runtime.now())) })
      return (feedback(outcome.result, runtime: runtime), outcome.moved)
    }

    package static func applyTidy(
      rows: inout [TidyRow], context: ModelContext, actions: PlannerActions, ledger: Ledger,
      runtime: PlannerRuntime
    ) -> AskActionFeedback {
      let proposal = TidyProposal(
        rows: rows.map {
          TidyProposal.Row(task: $0.task, expectedDue: $0.oldDue, choice: $0.choice)
        }
      )
      let result = ToolRegistry.apply(
        proposal, context: context, actions: actions, ledger: ledger, runtime: runtime)
      if result.applied { rows = [] }
      return feedback(result, runtime: runtime)
    }

    private static func feedback(_ result: WriteResult, runtime: PlannerRuntime)
      -> AskActionFeedback
    {
      var feedback = AskActionFeedback()
      feedback.applied = result.applied
      feedback.messages = result.replies.map {
        ChatMessage(role: .ai, text: $0, timestamp: runtime.now())
      }
      feedback.undo = result.undo.map { UndoRow(label: $0.label, action: $0.run) }
      return feedback
    }
  }
#endif
