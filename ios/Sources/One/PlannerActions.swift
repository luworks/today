#if os(iOS)
  import Foundation
  import Observation
  import SwiftData
  import EventKit
  import TodayCore
  import TodayData

  /// Model-bound planner actions. The same retained dependencies follow every toast and shake Undo.
  /// This capability exposes operations; consumers cannot resolve a service graph through it.
  @MainActor
  @Observable
  package final class PlannerActions {
    // One proposal ID owns one creation attempt, including a partially compensated failure.
    private var reminderCreationDrafts: [UUID: OneTask] = [:]
    private var reminderCreationReceipts: [UUID: (id: PersistentIdentifier, entry: LedgerItem)] =
      [:]
    private var eventCreationDrafts: [UUID: OneEvent] = [:]
    private var eventCreationReceipts:
      [UUID: (id: PersistentIdentifier, entry: LedgerItem, localOnly: Bool)] = [:]
    package let focus: TodayFocus
    private let calendar: any CalendarService
    private let reminders: any ReminderService
    private let alarms: any AlarmService
    private let ledger: Ledger
    private let runtime: PlannerRuntime
    private let defaults: UserDefaults

    package init(
      calendar: any CalendarService, reminders: any ReminderService,
      alarms: any AlarmService, ledger: Ledger, runtime: PlannerRuntime,
      defaults: UserDefaults = .standard
    ) {
      self.defaults = defaults
      focus = TodayFocus(ledger: ledger, runtime: runtime)
      self.calendar = calendar
      self.reminders = reminders
      self.alarms = alarms
      self.ledger = ledger
      self.runtime = runtime
    }

    package func applyAttachedReminder(
      _ operation: AttachedItemEdit.Operation, task: OneTask, expected: TaskSnapshot,
      context: ModelContext
    ) throws -> AttachedReminderActions.Receipt {
      try AttachedReminderActions.apply(
        operation, to: task, expected: expected,
        context: context, reminders: reminders, ledger: ledger, runtime: runtime)
    }

    package func applyAttachedAlarm(_ change: AttachedAlarmChange, context: ModelContext)
      async throws -> LedgerItem
    {
      try await change.apply(context: context, alarms: alarms, ledger: ledger, runtime: runtime)
    }

    package func toggleDone(
      _ task: OneTask, context: ModelContext, toast: UndoToast?,
      actor: LedgerActor = .you, channel: LedgerChannel = .app
    ) {
      TaskActions.toggleDone(
        task, context: context, toast: toast, reminders: reminders,
        ledger: ledger, runtime: runtime, actor: actor, channel: channel)
    }

    package func delete(
      _ task: OneTask, context: ModelContext, toast: UndoToast?,
      actor: LedgerActor = .you, channel: LedgerChannel = .app
    ) {
      TaskActions.delete(
        task, context: context, toast: toast, reminders: reminders,
        ledger: ledger, runtime: runtime, actor: actor, channel: channel)
    }

    package func deleteConfirmed(_ task: OneTask, context: ModelContext, toast: UndoToast?) throws {
      try TaskActions.deleteConfirmed(
        task, context: context, toast: toast, reminders: reminders, ledger: ledger, runtime: runtime
      )
    }

    /// Undo from Activity: reminders through the ledger, alarms through AlarmKit. Nil when done, else what the row says.
    package func undo(_ entry: LedgerItem, context: ModelContext) async -> String? {
      switch entry.itemKind {
      case "alarm":
        return await AlarmActions.undo(
          entry, context: context, alarms: alarms, ledger: ledger, runtime: runtime)
      case "list":
        return ListActions.undo(
          entry, context: context, reminders: reminders, ledger: ledger, runtime: runtime)
      case "event":
        return EntryDeletion.undo(entry, context: context, calendar: calendar, ledger: ledger)
      default:
        return ledger.undo(entry, context: context) ? nil : ActivityUndoMessage.changedSince
      }
    }

    /// Records an alarm edit or switch flip (see `AlarmActions.recordChange`).
    package func recordChange(_ alarm: OneAlarm, from before: AlarmSnapshot, context: ModelContext)
    {
      AlarmActions.recordChange(
        alarm, from: before, ledger: ledger, runtime: runtime, context: context)
    }

    @discardableResult
    package func delete(_ alarm: OneAlarm, context: ModelContext, toast: UndoToast?) -> Bool {
      AlarmActions.delete(
        alarm, context: context, toast: toast, alarms: alarms, ledger: ledger, runtime: runtime)
    }

    package func delete(_ entry: CalEntry, span: EKSpan, context: ModelContext, toast: UndoToast?) {
      EntryDeletion.perform(
        entry, span: span, context: context, toast: toast, calendar: calendar,
        reminders: reminders, alarms: alarms, ledger: ledger, runtime: runtime)
    }

    @discardableResult
    package func setDue(
      _ task: OneTask, to due: Date?, context: ModelContext,
      actor: LedgerActor = .you, channel: LedgerChannel = .app,
      approval: LedgerApproval = .userMade
    ) -> LedgerItem? {
      let entry = TaskActions.setDue(
        task, to: due, context: context, ledger: ledger,
        actor: actor, channel: channel, approval: approval)
      if entry != nil, task.externalID != nil {
        reminders.scheduleReconcile(after: .milliseconds(300))
      }
      return entry
    }

    /// Confirmed recurrence edit. Preserve a failed local copy for reconciliation after a remote commit.
    package func setRepeat(_ task: OneTask, rule: String?, due: Date?, context: ModelContext)
      throws -> LedgerItem
    {
      let before = Ledger.snapshot(of: task)
      var draft = before
      draft.repeatRule = rule
      draft.due = due
      let accepted = try reminders.commitEdit(task, draft: draft, expected: before)
      task.repeatRule = rule
      task.due = due
      do { try context.save() } catch {
        if accepted != nil {
          reminders.scheduleReconcile(after: .milliseconds(50))
        } else {
          task.repeatRule = before.repeatRule
          task.due = before.due
        }
        throw error
      }
      reminders.didPersistEdit(task, accepted: accepted)
      return ledger.record(
        .edited, task: task, title: task.title,
        before: before.repeatRule ?? "Once", after: rule ?? "Once",
        actor: .todayAI, channel: .ask, approval: .asked, context: context)
    }

    @discardableResult
    package func insert(
      _ capture: Capture, into context: ModelContext,
      actor: LedgerActor = .you, channel: LedgerChannel = .app,
      approval: LedgerApproval = .userMade
    ) throws -> (id: PersistentIdentifier, entry: LedgerItem) {
      try capture.insertRecorded(
        into: context, actor: actor, channel: channel, approval: approval,
        ledger: ledger, runtime: runtime, alarmDefaults: AlarmPlan.newAlarmDefaults(defaults))
    }

    /// A proposal retains the committed system identity until local persistence succeeds.
    package func insertCalendarEvent(
      _ capture: Capture, requestID: UUID, recoveryExternalID: String?,
      into context: ModelContext, save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> (id: PersistentIdentifier, entry: LedgerItem, localOnly: Bool) {
      if let receipt = eventCreationReceipts[requestID] { return receipt }
      guard capture.kind == .event else { throw CocoaError(.coderInvalidValue) }
      let event =
        eventCreationDrafts[requestID].flatMap { $0.externalID == nil ? nil : $0 }
        ?? capture.makeEvent(
          calendar: runtime.calendar, alertMinutes: Preferences.newEventAlertMinutes(defaults))
      if event.externalID == nil { event.externalID = recoveryExternalID }
      eventCreationDrafts[requestID] = event
      if event.externalID == nil {
        let receipt = try calendar.create(event, calendarID: nil)
        if case .committed(let id) = receipt { event.externalID = id }
      }
      let writeContext = ModelContext(context.container)
      writeContext.autosaveEnabled = false
      writeContext.insert(event)
      do { try save(writeContext) } catch {
        let retained = event.copy()
        retained.externalID = event.externalID
        eventCreationDrafts[requestID] = retained
        writeContext.rollback()
        throw error
      }
      let entry = ledger.record(
        .created, kind: "event", title: event.title, after: capture.summary,
        actor: .todayAI, channel: .ask, approval: .asked, context: context)
      eventCreationDrafts[requestID] = nil
      let receipt = (event.persistentModelID, entry, event.externalID == nil)
      eventCreationReceipts[requestID] = receipt
      return receipt
    }

    package func didUndoEventCreation(_ requestID: UUID) {
      eventCreationReceipts[requestID] = nil
    }

    package func pendingEventCreationID(_ requestID: UUID) -> String? {
      eventCreationDrafts[requestID]?.externalID
    }

    package func cancelEventCreation(
      _ capture: Capture, requestID: UUID, recoveryExternalID: String?
    ) throws {
      let event = eventCreationDrafts[requestID] ?? capture.makeEvent(calendar: runtime.calendar)
      if event.externalID == nil { event.externalID = recoveryExternalID }
      if event.externalID != nil, !calendar.delete(event, span: .thisEvent) {
        throw CalendarCreationError.unavailable
      }
      eventCreationDrafts[requestID] = nil
    }

    /// Narrow submitted-chat authority; does not grant background autonomy or recurrence writes.
    package func insertOneOffReminder(
      _ capture: Capture, requestID: UUID, recoveryExternalID: String? = nil,
      into context: ModelContext
    ) throws -> (id: PersistentIdentifier, entry: LedgerItem) {
      if let receipt = reminderCreationReceipts[requestID] { return receipt }
      guard capture.kind == .task, !capture.ringsAsAlarm, capture.repeatRule == nil else {
        throw CocoaError(.coderInvalidValue)
      }
      // With no accepted remote identity, edits to a failed draft become the next attempt.
      let retained = reminderCreationDrafts[requestID]
      let task =
        retained?.externalID != nil ? retained! : capture.makeTask(calendar: runtime.calendar)
      if task.externalID == nil { task.externalID = recoveryExternalID }
      if task.externalID != nil {
        let requested = capture.makeTask(calendar: runtime.calendar)
        guard RemindersSync.fingerprint(of: task) == RemindersSync.fingerprint(of: requested) else {
          throw CocoaError(.coderInvalidValue)
        }
      }
      if retained == nil { task.createdAt = runtime.now() }
      reminderCreationDrafts[requestID] = task
      try reminders.commitCreation(task, context: context)
      let entry = ledger.record(
        .created, task: task, kind: "task", title: task.title, after: capture.summary,
        actor: .todayAI, channel: .ask, approval: .asked, context: context)
      let receipt = (id: task.persistentModelID, entry: entry)
      reminderCreationReceipts[requestID] = receipt
      reminderCreationDrafts[requestID] = nil
      return receipt
    }

    package func didUndoReminderCreation(_ requestID: UUID) {
      reminderCreationReceipts[requestID] = nil
    }

    package func pendingReminderCreationID(_ requestID: UUID) -> String? {
      reminderCreationDrafts[requestID]?.externalID
    }

    package func cancelReminderCreation(
      _ capture: Capture, requestID: UUID, recoveryExternalID: String?, context: ModelContext
    ) throws {
      let task = reminderCreationDrafts[requestID] ?? capture.makeTask(calendar: runtime.calendar)
      if task.externalID == nil { task.externalID = recoveryExternalID }
      if task.externalID != nil {
        _ = try reminders.commitDeletion(task, expected: Ledger.snapshot(of: task))
      }
      reminderCreationDrafts[requestID] = nil
    }

    @discardableResult
    package func undo(_ entry: LedgerItem, context: ModelContext) -> Bool {
      ledger.undo(entry, context: context)
    }

    @discardableResult
    package func undoCapture(itemRef: String?, entryID: UUID?, title: String, context: ModelContext)
      -> Bool
    {
      CaptureUndo.undo(
        itemRef: itemRef, entryID: entryID, title: title, context: context,
        calendar: calendar, alarms: alarms, ledger: ledger)
    }

    package func captureTitle(_ ref: String?, in context: ModelContext) -> String? {
      CaptureUndo.title(ref, in: context, calendar: calendar)
    }

    @discardableResult
    package func renameCapture(_ ref: String?, to title: String, in context: ModelContext) -> Bool {
      CaptureUndo.rename(
        ref, to: title, in: context, calendar: calendar, reminders: reminders, alarms: alarms)
    }
  }
#endif
