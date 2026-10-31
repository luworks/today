#if os(iOS)
  import EventKit
  import Foundation
  import SwiftData
  import TodayCore
  import TodayData

  /// What a write proposal expects the item to look like when the user taps Apply
  /// (docs/engineering/ai-agent-architecture.md §4.2). Captured when the card is prepared and
  /// compared with the item's current state before anything is written.
  package struct ProposalSnapshot: Equatable {
    package var lastModified: Date?
    package var start: Date?
    package var attendees: Int
    package var repeats: Bool
    /// The reminder's own fields, when the proposal is about a reminder.
    package var task: TaskSnapshot?

    package init(
      lastModified: Date? = nil, start: Date?, attendees: Int = 0, repeats: Bool,
      task: TaskSnapshot? = nil
    ) {
      self.lastModified = lastModified
      self.start = start
      self.attendees = attendees
      self.repeats = repeats
      self.task = task
    }

    package init(task: TaskSnapshot) {
      self.init(start: task.due, repeats: task.repeatRule != nil, task: task)
    }

    package init(system: CalendarMoveSnapshot) {
      self.init(
        lastModified: system.lastModified, start: system.start,
        attendees: system.audience.attendeeCount, repeats: false)
    }
  }

  /// An approved-on-tap write to an existing item. Nothing is written while a proposal exists;
  /// `ToolRegistry.apply` writes it after re-validating the item.
  @MainActor
  package struct ChangeProposal {
    package enum Target {
      case task(OneTask)
      case event(OneEvent)
    }
    package enum Edit: Equatable {
      case move(Date)
      case delete
      case setRepeat(rule: String, due: Date)
    }
    package let target: Target
    /// nil when the card names no change; applying it writes nothing.
    package let edit: Edit?
    /// The "before" text the card showed (the ledger keeps it for a deleted event).
    package let oldText: String
    /// People an event change reaches; Undo says their updates can't be recalled.
    package let attendees: Int
    /// nil = no expectation was captured, so only structural checks apply (P1 keeps today's checks).
    package var expected: ProposalSnapshot?

    package init(
      target: Target, edit: Edit?, oldText: String, attendees: Int,
      expected: ProposalSnapshot? = nil
    ) {
      self.target = target
      self.edit = edit
      self.oldText = oldText
      self.attendees = attendees
      self.expected = expected
    }
  }

  /// "Tidy overdue": a new date per overdue reminder; each row expects the due date it showed.
  @MainActor
  package struct TidyProposal {
    package struct Row {
      package let task: OneTask
      package let expectedDue: Date
      package let choice: OverdueTidy.Choice

      package init(task: OneTask, expectedDue: Date, choice: OverdueTidy.Choice) {
        self.task = task
        self.expectedDue = expectedDue
        self.choice = choice
      }
    }
    package let rows: [Row]

    package init(rows: [Row]) { self.rows = rows }
  }

  /// A move of one Apple Calendar occurrence; Calendar compares `expected` with its live event.
  package struct SystemMoveProposal {
    package let expected: CalendarMoveSnapshot
    package let start: Date

    package init(expected: CalendarMoveSnapshot, start: Date) {
      self.expected = expected
      self.start = start
    }

    package var snapshot: ProposalSnapshot { ProposalSnapshot(system: expected) }
  }

  /// The outcome of an approved write: replies to show, an exact Undo, and whether the card is done.
  @MainActor
  package struct WriteResult {
    package struct Undo {
      package let label: String
      package let run: () -> Void
    }
    package var replies: [String] = []
    package var undo: Undo?
    package var applied = true
  }

  /// Code-owned writes for approved proposals. Callers (Ask today; the agent and Siri later) never write
  /// directly: every change is re-validated here, goes through PlannerActions / Calendar, is recorded in
  /// the Activity ledger as an asked Today AI change, and returns an exact Undo.
  @MainActor
  package enum ToolRegistry {
    /// The item's state now, in the same shape as a proposal's expectation.
    package static func snapshot(of target: ChangeProposal.Target, attendees: Int = 0)
      -> ProposalSnapshot
    {
      switch target {
      case .task(let task): ProposalSnapshot(task: Ledger.snapshot(of: task))
      case .event(let event):
        ProposalSnapshot(start: event.start, attendees: attendees, repeats: event.repeatRule != nil)
      }
    }

    package static func apply(
      _ p: ChangeProposal, context: ModelContext, calendar: any CalendarService,
      actions: PlannerActions, ledger: Ledger
    ) -> WriteResult {
      switch p.target {
      case .task(let task): applyTask(task, p, context: context, actions: actions, ledger: ledger)
      case .event(let event):
        applyEvent(event, p, context: context, calendar: calendar, ledger: ledger)
      }
    }

    private static func applyTask(
      _ task: OneTask, _ p: ChangeProposal, context: ModelContext, actions: PlannerActions,
      ledger: Ledger
    ) -> WriteResult {
      var result = WriteResult()
      guard !task.isDeleted, task.modelContext != nil else {
        result.applied = false
        return result
      }
      // A repeat change always carries its expectation; without one it is treated as stale.
      let stale: Bool
      switch (p.edit, p.expected) {
      case (nil, _): stale = false
      case (.setRepeat, nil): stale = true
      case (_, nil): stale = false
      case (_, let expected?): stale = expected != snapshot(of: p.target)
      }
      if stale {
        result.applied = false
        result.replies.append(
          "This reminder changed since the preview. Ask again to prepare a current preview.")
        return result
      }
      switch p.edit {
      case nil: break
      case .delete:
        // Use the real action, including reminder deletion tracking and its retained Undo.
        let toast = UndoToast()
        let undoManager = UndoManager()
        toast.undoManager = undoManager
        actions.delete(task, context: context, toast: toast, actor: .todayAI, channel: .ask)
        if let label = toast.message {
          result.undo = .init(
            label: label,
            run: {
              // UndoManager does not retain its target. Keep it alive beyond the toast's timeout.
              withExtendedLifetime(toast) {
                if undoManager.canUndo { undoManager.undo() }
              }
            })
        }
      case .setRepeat(let rule, let due):
        let before = Ledger.snapshot(of: task)
        do {
          let entry = try actions.setRepeat(task, rule: rule, due: due, context: context)
          let after = Ledger.snapshot(of: task)
          result.replies.append("Updated “\(task.title)” to repeat every day.")
          result.undo = .init(
            label: "Changed “\(task.title)”.",
            run: {
              guard !task.isDeleted, task.modelContext != nil,
                Ledger.snapshot(of: task) == after
              else { return }
              do {
                _ = try actions.setRepeat(
                  task, rule: before.repeatRule, due: before.due, context: context)
                ledger.recordUndo(of: entry, task: task, channel: .ask, context: context)
              } catch { return }
            })
        } catch {
          result.applied = false
          result.replies.append("Couldn't save the repeat change: \(error.localizedDescription)")
        }
      case .move(let new):
        if let entry = actions.setDue(
          task, to: new, context: context, actor: .todayAI, channel: .ask, approval: .asked)
        {
          result.replies.append("Moved “\(task.title)” to \(ledger.timeLabel(new)).")
          result.undo = .init(
            label: "Moved “\(task.title)”.",
            run: {
              guard !task.isDeleted, task.modelContext != nil,
                !task.isDone, task.due == new
              else { return }
              var recorded = entry
              recorded.itemRef = Ledger.ref(task.persistentModelID)
              _ = actions.undo(recorded, context: context)
            })
        }
      }
      return result
    }

    private static func applyEvent(
      _ event: OneEvent, _ p: ChangeProposal, context: ModelContext, calendar: any CalendarService,
      ledger: Ledger
    ) -> WriteResult {
      var result = WriteResult()
      guard !event.isDeleted, event.modelContext != nil, event.repeatRule == nil,
        event.externalID == nil || calendar.canDelete(externalID: event.externalID)
      else {
        result.applied = false
        result.replies.append("This event can't be changed here. Open it in Calendar.")
        return result
      }
      if p.edit != nil, let expected = p.expected,
        expected != snapshot(of: p.target, attendees: expected.attendees)
      {
        result.applied = false
        result.replies.append(
          "This event changed since the preview. Ask again to prepare a current preview.")
        return result
      }
      let linked = event.externalID != nil
      let recall = p.attendees > 0 ? " Attendee updates already sent can't be recalled." : ""
      switch p.edit {
      case nil, .setRepeat: break
      case .delete:
        let backup = event.copy()
        guard calendar.delete(event, span: .thisEvent) else {
          result.applied = false
          result.replies.append("Couldn't delete the calendar event. The preview is still here.")
          return result
        }
        context.delete(event)
        do { try context.save() } catch {
          if !linked {
            context.insert(event)
            result.applied = false
            result.replies.append("Couldn't save the deletion. The preview is still here.")
            return result
          }
          result.replies.append(
            "Calendar accepted the deletion, but Today couldn't save its copy. Reopen Today to retry saving."
          )
        }
        let entry = ledger.record(
          .deleted, kind: "event", title: backup.title, before: p.oldText,
          actor: .todayAI, channel: .ask, approval: .asked, context: context)
        result.replies.append("Deleted “\(backup.title)”.")
        result.undo = .init(
          label: "Deleted “\(backup.title)”." + recall,
          run: {
            // Recreating a remote event is compensation, never an atomic recall of invitations.
            if linked {
              guard let id = calendar.save(backup, span: .thisEvent) else { return }
              backup.externalID = id
            }
            context.insert(backup)
            do { try context.save() } catch {
              if !linked { context.delete(backup) }
              return
            }
            ledger.recordUndo(of: entry, channel: .ask, context: context)
          })
      case .move(let new):
        let old = event.start
        event.start = new
        if linked, calendar.save(event, span: .thisEvent) == nil {
          event.start = old
          result.applied = false
          result.replies.append("Couldn't update the calendar event. The preview is still here.")
          return result
        }
        do { try context.save() } catch {
          if !linked {
            event.start = old
            result.applied = false
            result.replies.append("Couldn't save the change. The preview is still here.")
            return result
          }
          result.replies.append(
            "Calendar accepted the change, but Today couldn't save its copy. Reopen Today to retry saving."
          )
        }
        let entry = ledger.record(
          .moved, kind: "event", title: event.title, before: ledger.timeLabel(old),
          after: ledger.timeLabel(new),
          actor: .todayAI, channel: .ask, approval: .asked, context: context)
        result.replies.append("Moved “\(event.title)” to \(ledger.timeLabel(new)).")
        result.undo = .init(
          label: "Moved “\(event.title)”." + recall,
          run: {
            guard !event.isDeleted, event.modelContext != nil, event.start == new else { return }
            event.start = old
            if linked, calendar.save(event, span: .thisEvent) == nil {
              event.start = new
              return
            }
            do { try context.save() } catch {
              if !linked { event.start = new }
              return
            }
            ledger.recordUndo(of: entry, channel: .ask, context: context)
          })
      }
      return result
    }

    /// Writes each row whose reminder still has the due date the card showed; rows set to Keep stay.
    package static func apply(
      _ p: TidyProposal, context: ModelContext, actions: PlannerActions, ledger: Ledger,
      runtime: PlannerRuntime
    ) -> WriteResult {
      var result = WriteResult()
      let changes = p.rows.filter {
        $0.choice != .keep && !$0.task.isDeleted && $0.task.due == $0.expectedDue
      }
      let anchor = runtime.now()
      for r in changes {
        r.task.due = OverdueTidy.newDue(
          r.expectedDue, r.choice, now: anchor, calendar: runtime.calendar)
      }
      do { try context.save() } catch {
        for r in changes { r.task.due = r.expectedDue }
        result.applied = false
        result.replies.append("Couldn't save the new dates. The preview is still here.")
        return result
      }
      var entries: [(task: OneTask, entry: LedgerItem)] = []
      for r in changes {
        let new = r.task.due
        let entry = ledger.record(
          .redated, task: r.task, title: r.task.title,
          before: ledger.timeLabel(r.expectedDue, none: "No date"),
          after: ledger.timeLabel(new, none: "No date"), beforeDate: r.expectedDue,
          afterDate: new, actor: .todayAI, channel: .ask, approval: .asked, context: context)
        entries.append((r.task, entry))
      }
      let label = "Moved \(changes.count) reminder\(changes.count == 1 ? "" : "s")."
      result.replies.append(label)
      result.undo = .init(
        label: label,
        run: {
          for row in entries {
            guard !row.task.isDeleted, row.task.modelContext != nil,
              !row.task.isDone, row.task.due == row.entry.afterDate
            else { continue }
            var entry = row.entry
            entry.itemRef = Ledger.ref(row.task.persistentModelID)
            _ = actions.undo(entry, context: context)
          }
        })
      return result
    }

    /// Calendar re-validates `expected` against the live occurrence (`CalendarMoveError.stale`).
    /// `report` posts replies that arrive later, from Undo. `moved` is the verified result.
    package static func apply(
      _ p: SystemMoveProposal, context: ModelContext, calendar: any CalendarService,
      ledger: Ledger, report: @escaping (String) -> Void
    ) -> (result: WriteResult, moved: CalendarMoveSnapshot?) {
      var result = WriteResult()
      let snapshot = p.expected
      let start = p.start
      do {
        let outcome = try calendar.moveEvent(
          expected: snapshot, to: start, acknowledgingAudience: true)
        switch outcome {
        case .verified(let receipt):
          let entry = ledger.record(
            .moved, kind: "event", title: snapshot.title,
            before: ledger.timeLabel(snapshot.start), after: ledger.timeLabel(start),
            beforeDate: snapshot.start, afterDate: start, actor: .todayAI, channel: .ask,
            approval: .asked, snapshot: receipt, context: context)
          result.replies.append("The calendar event was moved.")
          result.undo = .init(
            label: "Moved the event. Calendar may notify attendees again.",
            run: {
              do {
                switch try calendar.undoMove(receipt, acknowledgingAudience: true) {
                case .verified:
                  ledger.recordUndo(of: entry, channel: .ask, context: context)
                  report("The event was restored.")
                case .committedUnverified:
                  ledger.record(
                    .edited, kind: "event", title: snapshot.title,
                    after: "Undo committed; result not verified", actor: .you, channel: .ask,
                    approval: .userMade, snapshot: receipt, context: context)
                  report(
                    "Calendar accepted Undo, but the result couldn't be verified. Open Calendar to check it."
                  )
                }
              } catch {
                report("Couldn't undo the event change. Open Calendar to check it.")
              }
            })
          return (result, receipt.after)
        case .committedUnverified(let pending):
          ledger.record(
            .moved, kind: "event", title: snapshot.title,
            before: ledger.timeLabel(snapshot.start),
            after: "Calendar accepted; result unverified",
            beforeDate: snapshot.start, afterDate: start, actor: .todayAI, channel: .ask,
            approval: .asked, snapshot: pending, context: context)
          result.replies.append(
            "Calendar accepted the change, but the result couldn't be verified. Open Calendar to check it before trying again."
          )
          return (result, nil)
        }
      } catch {
        result.applied = false
        result.replies.append("The event could not be changed. Open Calendar to check it.")
        return (result, nil)
      }
    }
  }
#endif
