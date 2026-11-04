#if os(iOS)
  import Foundation
  import SwiftData
  import TodayCore

  /// Apply only after the user approves a preview. The caller owns the preview and its lifetime.
  @MainActor
  package enum AttachedReminderActions {
    package enum Failure: LocalizedError {
      case changed, noChange, saveAfterSystemCommit
      package var errorDescription: String? {
        switch self {
        case .changed: "This reminder changed since the preview. Ask again."
        case .noChange: "This reminder already has that value."
        case .saveAfterSystemCommit:
          "Apple Reminders accepted the change, but Today could not save its copy. Reopen Today to reconcile."
        }
      }
    }

    /// A receipt is single-use. A failed or stale undo is reported rather than claimed as successful.
    package final class Receipt {
      private var used = false
      private let perform: () throws -> Void
      fileprivate init(_ perform: @escaping () throws -> Void) { self.perform = perform }
      package func undo() throws {
        guard !used else { throw Failure.changed }
        try perform()
        used = true
      }
    }

    package static func apply(
      _ operation: AttachedItemEdit.Operation, to task: OneTask, expected: TaskSnapshot,
      context: ModelContext, reminders: any ReminderService, ledger: Ledger,
      runtime: PlannerRuntime, actor: LedgerActor = .todayAI, channel: LedgerChannel = .ask
    ) throws -> Receipt {
      guard !task.isDeleted, task.modelContext === context,
        Ledger.snapshot(of: task) == expected,
        try persistedMatches(task, expected: expected, context: context)
      else { throw Failure.changed }
      switch operation {
      case .rename(let title):
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != expected.title else { throw Failure.noChange }
        var draft = expected
        draft.title = name
        return try edit(
          task, before: expected, after: draft, context: context,
          reminders: reminders, ledger: ledger, actor: actor, channel: channel)
      case .move(let due):
        guard expected.due != due else { throw Failure.noChange }
        var draft = expected
        draft.due = due
        return try edit(
          task, before: expected, after: draft, context: context,
          reminders: reminders, ledger: ledger, actor: actor, channel: channel)
      case .done:
        guard !expected.isDone else { throw Failure.noChange }
        // Repeating completion can advance the system reminder or create another local item;
        // a snapshot of this item alone cannot safely guard its Undo.
        guard expected.repeatRule == nil else { throw Failure.changed }
        let toast = UndoToast()
        let undoManager = UndoManager()
        toast.undoManager = undoManager
        TaskActions.toggleDone(
          task, context: context, toast: toast, reminders: reminders,
          ledger: ledger, runtime: runtime, actor: actor, channel: channel)
        guard toast.canUndo else { throw Failure.changed }
        let after = Ledger.snapshot(of: task)
        return Receipt {
          guard !task.isDeleted, task.modelContext === context,
            Ledger.snapshot(of: task) == after
          else { throw Failure.changed }
          guard undoManager.canUndo else { throw Failure.changed }
          withExtendedLifetime(toast) { undoManager.undo() }
          guard Ledger.snapshot(of: task) == expected else { throw Failure.changed }
        }
      case .delete:
        let backup = task.copy()
        let externalID = task.externalID
        let deletion = try reminders.commitDeletion(task, expected: expected)
        if case .alreadyAbsent = deletion { throw Failure.changed }
        if externalID != nil { backup.createdAt = runtime.now() }
        context.delete(task)
        do { try context.save() } catch {
          context.insert(task)
          if externalID != nil {
            reminders.noteDeleted(reminder: externalID)
            throw Failure.saveAfterSystemCommit
          }
          throw error
        }
        if externalID != nil { reminders.noteDeleted(reminder: externalID) }
        let snapshot: TaskSnapshot?
        if case .localOnly = deletion { snapshot = expected } else { snapshot = nil }
        let entry = ledger.record(
          .deleted, title: expected.title, actor: actor,
          channel: channel, approval: actor == .you ? .userMade : .asked, snapshot: snapshot,
          context: context)
        return Receipt {
          guard backup.modelContext == nil else { throw Failure.changed }
          let accepted = try reminders.restoreDeletion(backup, receipt: deletion)
          if let accepted { backup.externalID = accepted.id }
          context.insert(backup)
          do { try context.save() } catch {
            if accepted != nil { reminders.scheduleReconcile(after: .milliseconds(50)) }
            throw error
          }
          reminders.didPersistEdit(backup, accepted: accepted)
          ledger.recordUndo(of: entry, task: backup, channel: channel, context: context)
        }
      }
    }

    private static func edit(
      _ task: OneTask, before: TaskSnapshot, after: TaskSnapshot, context: ModelContext,
      reminders: any ReminderService, ledger: Ledger, actor: LedgerActor, channel: LedgerChannel
    ) throws -> Receipt {
      try persist(task, from: before, to: after, context: context, reminders: reminders)
      let entry = ledger.record(
        before.title == after.title ? .redated : .edited, task: task, title: after.title,
        before: before.title == after.title
          ? ledger.timeLabel(before.due, none: "No date") : before.title,
        after: before.title == after.title
          ? ledger.timeLabel(after.due, none: "No date") : after.title,
        beforeDate: before.due, afterDate: after.due, actor: actor, channel: channel,
        approval: actor == .you ? .userMade : .asked, context: context)
      return Receipt {
        guard !task.isDeleted, task.modelContext === context,
          Ledger.snapshot(of: task) == after,
          try persistedMatches(task, expected: after, context: context)
        else { throw Failure.changed }
        try persist(task, from: after, to: before, context: context, reminders: reminders)
        ledger.recordUndo(of: entry, task: task, channel: channel, context: context)
      }
    }

    private static func persistedMatches(
      _ task: OneTask, expected: TaskSnapshot,
      context: ModelContext
    ) throws -> Bool {
      let reader = ModelContext(context.container)
      let saved = try reader.fetch(FetchDescriptor<OneTask>()).first {
        $0.persistentModelID == task.persistentModelID
      }
      return saved.map { Ledger.snapshot(of: $0) == expected } ?? false
    }

    private static func persist(
      _ task: OneTask, from before: TaskSnapshot, to after: TaskSnapshot,
      context: ModelContext, reminders: any ReminderService
    ) throws {
      let accepted = try reminders.commitEdit(task, draft: after, expected: before)
      task.title = after.title
      task.due = after.due
      do { try context.save() } catch {
        if accepted != nil {
          reminders.scheduleReconcile(after: .milliseconds(50))
          throw Failure.saveAfterSystemCommit
        }
        task.title = before.title
        task.due = before.due
        throw error
      }
      reminders.didPersistEdit(task, accepted: accepted)
    }
  }
#endif
