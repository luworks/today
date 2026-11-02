#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import SwiftUI
  import SwiftData

  /// A short-lived "Completed · Undo" toast, shared through the environment.
  @MainActor
  @Observable
  package final class UndoToast {
    package init() {}
    package private(set) var message: String?
    private var undo: (() -> Void)?
    private var token = UUID()
    private var dismissTask: Task<Void, Never>?
    /// The window's undo manager: every undoable change is registered there too, so shaking the iPhone offers
    /// the system's "Undo ..." prompt for it, like in any other app. Set by `HomeView`.
    @ObservationIgnored package var undoManager: UndoManager?

    package func show(_ message: String, undo: @escaping () -> Void) {
      let t = UUID()
      token = t
      if let undoManager {
        undoManager.registerUndo(withTarget: self) { target in
          undo()
          if target.token == t { target.dismiss() }
        }
        undoManager.setActionName(Self.actionName(for: message))
      }
      withAnimation(.snappy) {
        self.message = message
        self.undo = undo
      }
      dismissTask?.cancel()
      dismissTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(6)) } catch { return }
        if let self, self.token == t { self.dismiss() }
      }
    }

    /// A message with no Undo, for something that did not happen ("can't delete a read-only calendar's event").
    package func showNotice(_ message: String) {
      let t = UUID()
      token = t
      withAnimation(.snappy) {
        self.message = message
        self.undo = nil
      }
      dismissTask?.cancel()
      dismissTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        if let self, self.token == t { self.dismiss() }
      }
    }

    package var canUndo: Bool { undo != nil }

    package func performUndo() {
      // The toast's button and the shake prompt undo the same change; once it is undone, forget the shake entry.
      undoManager?.removeAllActions(withTarget: self)
      let previousToken = token
      undo?()
      // An Undo failure may replace this toast with a useful notice.
      if token == previousToken { dismiss() }
    }

    /// "Deleted “Buy milk”" reads as "Undo Delete" in the shake prompt.
    private static func actionName(for message: String) -> String {
      let lower = message.lowercased()
      for (key, name) in [
        ("deleted", "Delete"), ("completed", "Complete"), ("archived", "Archive"),
        ("unarchived", "Unarchive"),
      ]
      where lower.contains(key) { return name }
      return message
    }

    package func dispose() {
      dismiss()
      undoManager?.removeAllActions(withTarget: self)
      undoManager = nil
    }

    package func dismiss() {
      dismissTask?.cancel()
      dismissTask = nil
      withAnimation(.snappy) {
        message = nil
        undo = nil
      }
    }
  }

  /// Task actions that need side effects (repeat, undo). Views call these instead of mutating directly.
  @MainActor
  package enum TaskActions {
    /// Complete or reopen. Completing a repeating task creates its next occurrence.
    /// Every change is also written to the Activity ledger (`Ledger`), as made by `actor` through `channel`.
    package static func toggleDone(
      _ task: OneTask, context: ModelContext, toast: UndoToast?,
      reminders: any ReminderService, ledger: Ledger, runtime: PlannerRuntime,
      actor: LedgerActor = .you, channel: LedgerChannel = .app
    ) {
      guard !task.isDeleted, task.modelContext != nil else { return }
      let oldDone = task.isDone
      let oldDoneAt = task.doneAt
      let accepted: RemindersSync.Remote?
      do {
        accepted = try reminders.commitCompletion(task, done: !oldDone)
      } catch {
        toast?.showNotice(
          "Couldn’t update Apple Reminders. " + error.localizedDescription
            + " Tap the circle to retry.")
        return
      }
      guard !task.isDone else {
        withAnimation {
          task.isDone.toggle()
          task.doneAt = task.isDone ? runtime.now() : nil
        }
        guard
          persistCompletion(
            task, context: context, toast: toast, reminders: reminders, oldDone: oldDone,
            oldDoneAt: oldDoneAt)
        else { return }
        ledger.record(
          .reopened, task: task, title: task.title, actor: actor, channel: channel, context: context
        )
        return
      }
      // Apple Reminders rolls its own repeating reminders forward, so only local-only tasks spawn the next one here.
      let next = task.externalID == nil ? nextOccurrence(of: task, runtime: runtime) : nil
      // What the finished occurrence looked like, for Undo: a synced repeating reminder comes back from Apple with its
      // due date rolled forward, so Undo must put it back exactly.
      let oldDue = task.due
      withAnimation {
        task.isDone.toggle()
        task.doneAt = task.isDone ? runtime.now() : nil
        if let next { context.insert(next) }
      }
      guard
        persistCompletion(
          task, context: context, toast: toast, reminders: reminders, oldDone: oldDone,
          oldDoneAt: oldDoneAt, next: next)
      else { return }
      let suffix =
        next.map { n in
          " · next " + plannerDayLabel(n.due ?? runtime.now(), runtime: runtime)
        } ?? ""
      let entry = ledger.record(
        .completed, task: task, title: task.title, after: next.map { _ in "Next one added" } ?? "",
        beforeDate: oldDue, actor: actor, channel: channel, context: context)
      toast?.show("Completed “\(task.title)”" + suffix) {
        guard !task.isDeleted, task.modelContext != nil else { return }
        let undoDone = task.isDone
        let undoDoneAt = task.doneAt
        do {
          _ = try reminders.commitCompletion(
            task, done: false, restoringDue: oldDue, restoresDue: true, expected: accepted)
        } catch {
          toast?.showNotice("Couldn’t reopen in Apple Reminders. " + error.localizedDescription)
          return
        }
        withAnimation {
          // Not toggleDone(): Apple may already have rolled a repeating reminder back to open (next occurrence).
          if task.isDone {
            task.isDone.toggle()
            task.doneAt = task.isDone ? runtime.now() : nil
          }
          if let next { context.delete(next) }
          if task.due != oldDue { task.due = oldDue }
        }
        if persistCompletion(
          task, context: context, toast: toast, reminders: reminders, oldDone: undoDone,
          oldDoneAt: undoDoneAt, restoredDue: true)
        {
          ledger.recordUndo(of: entry, context: context)
        }
      }
    }

    /// After EventKit accepts a linked write, do not undo it if the local save fails. Keep the accepted
    /// state in memory and retry saving on reconciliation. Local-only failures restore only this action.
    private static func persistCompletion(
      _ task: OneTask, context: ModelContext, toast: UndoToast?,
      reminders: any ReminderService, oldDone: Bool, oldDoneAt: Date?, next: OneTask? = nil,
      restoredDue: Bool = false
    ) -> Bool {
      do {
        try context.save()
        reminders.didPersistCompletion(task, restoredDue: restoredDue)
        return true
      } catch {
        if task.externalID == nil {
          task.isDone = oldDone
          task.doneAt = oldDoneAt
          if let next { context.delete(next) }
          toast?.showNotice(
            "Couldn’t save the reminder. " + error.localizedDescription
              + " Tap the circle to retry.")
        } else {
          // Keep the old persisted baseline until the local copy actually saves. Otherwise a
          // restart with the old open copy could be misread as a request to reopen Apple.
          reminders.scheduleReconcile(after: .milliseconds(50))
          toast?.showNotice(
            "Apple Reminders was updated, but Today couldn’t save its copy. "
              + error.localizedDescription + " Reopen Today to retry.")
        }
        return false
      }
    }

    package static func delete(
      _ task: OneTask, context: ModelContext, toast: UndoToast?,
      reminders: any ReminderService, ledger: Ledger, runtime: PlannerRuntime,
      actor: LedgerActor = .you, channel: LedgerChannel = .app
    ) {
      guard !task.isDeleted, task.modelContext != nil else { return }
      reminders.noteDeleted(reminder: task.externalID)
      let backup = task.copy()
      // Undo creates it again in Apple Reminders too
      if task.externalID != nil { backup.createdAt = runtime.now() }
      let entry = ledger.record(
        .deleted, title: backup.title, before: deletedDetail(task, runtime: runtime), actor: actor,
        channel: channel,
        snapshot: Ledger.snapshot(of: task), context: context)
      withAnimation { context.delete(task) }
      toast?.show("Deleted “\(backup.title)”") {
        withAnimation { context.insert(backup) }
        try? context.save()
        ledger.recordUndo(of: entry, context: context)
      }
    }

    /// The editor waits for the system acknowledgement before removing its local object.
    /// Existing background/batch deletion keeps the separate queued path above.
    package static func deleteConfirmed(
      _ task: OneTask, context: ModelContext, toast: UndoToast?, reminders: any ReminderService,
      ledger: Ledger, runtime: PlannerRuntime
    ) throws {
      guard !task.isDeleted, task.modelContext != nil else { throw EditorDeletionError.unavailable }
      let snapshot = Ledger.snapshot(of: task)
      let detail = deletedDetail(task, runtime: runtime)
      let backup = task.copy()
      let receipt = try reminders.commitDeletion(task, expected: snapshot)
      if task.externalID != nil { backup.createdAt = runtime.now() }
      let externalID = task.externalID
      context.delete(task)
      do { try context.save() } catch {
        // Apple may already have accepted the deletion. Keep its known link and pending
        // tombstone: a failed local save must never upload this object as a new reminder.
        context.insert(task)
        if externalID != nil { reminders.noteDeleted(reminder: externalID) }
        throw EditorDeletionError.localSave(systemConfirmed: externalID != nil)
      }
      if externalID != nil { reminders.noteDeleted(reminder: externalID) }
      // Activity's historical snapshot has no external deletion receipt. Only local-only
      // deletions can safely use that unguarded recreation path; linked deletes use the
      // receipt-checked toast/shake compensation below.
      let activitySnapshot: TaskSnapshot?
      if case .localOnly = receipt { activitySnapshot = snapshot } else { activitySnapshot = nil }
      let entry = ledger.record(
        .deleted, title: backup.title, before: detail,
        snapshot: activitySnapshot, context: context)
      if case .alreadyAbsent = receipt {
        toast?.showNotice("Removed the local copy. It was already deleted in Apple Reminders.")
        return
      }
      var restored = false
      toast?.show("Deleted “\(backup.title)”") {
        guard !restored, backup.modelContext == nil else { return }
        do {
          let accepted = try reminders.restoreDeletion(backup, receipt: receipt)
          if let accepted { backup.externalID = accepted.id }
          context.insert(backup)
          restored = true
          do { try context.save() } catch {
            reminders.scheduleReconcile(after: .milliseconds(50))
            toast?.showNotice(
              "The reminder was restored, but Today couldn’t save its copy. Reopen Today to retry.")
            return
          }
          reminders.didPersistEdit(backup, accepted: accepted)
          ledger.recordUndo(of: entry, context: context)
        } catch {
          toast?.showNotice("Couldn’t undo the deletion. " + error.localizedDescription)
        }
      }
    }

    private enum EditorDeletionError: LocalizedError {
      case unavailable
      case localSave(systemConfirmed: Bool)
      var errorDescription: String? {
        switch self {
        case .unavailable: "This reminder is no longer available. Close and reopen Reminders."
        case .localSave(let systemConfirmed):
          systemConfirmed
            ? "Apple Reminders confirmed deletion, but Today couldn’t save its copy. Refresh or retry; Undo is not yet available."
            : "Today couldn’t save the deletion. Please try again."
        }
      }
    }

    /// Sets or clears the reminder's date and records it: Today, Tomorrow, Unschedule, an AI move.
    /// Apple Reminders gets the new date from the next reconcile, like any other local edit.
    @discardableResult
    package static func setDue(
      _ task: OneTask, to due: Date?, context: ModelContext, ledger: Ledger,
      actor: LedgerActor = .you, channel: LedgerChannel = .app, approval: LedgerApproval = .userMade
    ) -> LedgerItem? {
      guard !task.isDeleted, task.modelContext != nil else { return nil }
      let old = task.due
      guard old != due else { return nil }
      withAnimation { task.due = due }
      return ledger.record(
        .redated, task: task, title: task.title, before: ledger.timeLabel(old, none: "No date"),
        after: ledger.timeLabel(due, none: "No date"),
        beforeDate: old, afterDate: due, actor: actor, channel: channel, approval: approval,
        context: context)
    }

    private static func nextOccurrence(of task: OneTask, runtime: PlannerRuntime) -> OneTask? {
      guard let rule = task.repeats else { return nil }
      let next = task.copy()
      next.isDone = false
      next.doneAt = nil
      next.createdAt = runtime.now()
      next.due = rule.next(
        after: task.due ?? runtime.calendar.startOfDay(for: runtime.now()),
        calendar: runtime.calendar)
      next.checklist = task.checklist.map { ChecklistItem(id: runtime.nextID(), title: $0.title) }
      return next
    }

    private static func deletedDetail(_ t: OneTask, runtime: PlannerRuntime) -> String {
      if let d = t.due { return "Due " + plannerDayLabel(d, runtime: runtime) }
      return t.listName
    }
  }

  /// Relative day labels must use the same clock as the action, including in deterministic sessions.
  package func plannerDayLabel(_ date: Date, runtime: PlannerRuntime, includeTime: Bool = true)
    -> String
  {
    let calendar = runtime.calendar
    let today = calendar.startOfDay(for: runtime.now())
    let day = calendar.startOfDay(for: date)
    let distance = calendar.dateComponents([.day], from: today, to: day).day
    let formatter = DateFormatter()
    formatter.locale = runtime.locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    let label: String
    switch distance {
    case 0: label = "Today"
    case 1: label = "Tomorrow"
    case -1: label = "Yesterday"
    default:
      formatter.setLocalizedDateFormatFromTemplate("MMMd")
      label = formatter.string(from: date)
    }
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    guard includeTime, parts.hour != 0 || parts.minute != 0 else { return label }
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return label + " " + formatter.string(from: date)
  }

#endif
