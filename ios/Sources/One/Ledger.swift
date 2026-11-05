#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import SwiftUI
  import SwiftData

  /// Records changes in the ledger. Called from the write paths (TaskActions, Ask AI, App Intents, Share, sync).
  /// Items are held a moment and written together, after the reminders they point at have their final ids. The ledger lives in the
  /// Activity store (`activity.store`); the reads (Activity screen, Undo, the policy's look-back) are SQL queries.
  @MainActor
  package final class Ledger {
    package let activity: ActivityCenter
    private let reminders: any ReminderService
    private let runtime: PlannerRuntime
    private var flushTask: Task<Void, Never>?
    private var pendingContext: ModelContext?
    private var disposed = false
    private var undoneIDs: Set<UUID> = []

    package init(activity: ActivityCenter, reminders: any ReminderService, runtime: PlannerRuntime)
    {
      self.activity = activity
      self.reminders = reminders
      self.runtime = runtime
    }

    package func timeLabel(_ date: Date?, none: String = "Not planned") -> String {
      date.map { plannerDayLabel($0, runtime: runtime) } ?? none
    }

    package func dayLabel(_ date: Date) -> String {
      plannerDayLabel(date, runtime: runtime, includeTime: false)
    }

    package func dispose() {
      if let context = pendingContext { flush(context) }
      flushTask?.cancel()
      flushTask = nil
      pendingContext = nil
      disposed = true
    }

    private struct Pending {
      var item: LedgerItem
      var snapshot: Data?
      /// The reminder or alarm it is about; its id goes in `subject_ref` once saved.
      var model: (any PersistentModel)?
      var observedAt: Date
    }

    private var pending: [Pending] = []
    private var flushScheduled = false

    @discardableResult
    package func record(
      _ action: LedgerAction, task: OneTask? = nil, item model: (any PersistentModel)? = nil,
      kind: String = "task", title: String,
      before: String = "", after: String = "", beforeDate: Date? = nil, afterDate: Date? = nil,
      actor: LedgerActor = .you, channel: LedgerChannel = .app,
      approval: LedgerApproval = .userMade,
      snapshot: (any Encodable)? = nil, reference: String? = nil, undoOf: UUID? = nil,
      at date: Date? = nil,
      context: ModelContext
    ) -> LedgerItem {
      var item = LedgerItem(
        actor: actor, channel: channel, action: action, itemKind: kind, title: title,
        before: before, after: after, approval: approval)
      item.id = runtime.nextID()
      // A change seen later (a completion in Apple Reminders) keeps the time it happened, so it lands on its own day.
      item.date = date ?? runtime.now()
      item.beforeDate = beforeDate ?? (action == .completed ? task?.due : nil)
      item.afterDate = afterDate
      item.itemRef = reference
      item.undoOf = undoOf
      let data = snapshot.flatMap { try? JSONEncoder().encode($0) }
      item.hasSnapshot = data != nil
      guard !disposed else { return item }
      pending.append(
        Pending(item: item, snapshot: data, model: task ?? model, observedAt: runtime.now()))
      scheduleFlush(context)
      return item
    }

    /// Records that `entry` was undone (by you, unless said otherwise).
    @discardableResult
    package func recordUndo(
      of entry: LedgerItem, task: OneTask? = nil, item model: (any PersistentModel)? = nil,
      actor: LedgerActor = .you, channel: LedgerChannel = .app,
      context: ModelContext
    ) -> LedgerItem {
      undoneIDs.insert(entry.id)
      return record(
        .undone, task: task, item: model, kind: entry.itemKind, title: entry.title,
        before: entry.after, after: entry.before,
        actor: actor, channel: channel, approval: .userMade, undoOf: entry.id, context: context)
    }

    private func scheduleFlush(_ context: ModelContext) {
      guard !disposed, !flushScheduled else { return }
      pendingContext = context
      flushScheduled = true
      flushTask = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        guard let self, !self.disposed, !Task.isCancelled else { return }
        self.flush(context)
      }
    }

    /// Saves what is waiting: the reminders first (a new one's id becomes final on save), then the items with their ids, into
    /// the store. After this the Activity screen and the policy queries see everything recorded so far.
    package func flush(_ context: ModelContext) {
      flushTask?.cancel()
      flushTask = nil
      pendingContext = nil
      flushScheduled = false
      if !pending.isEmpty {
        if pending.contains(where: { $0.model != nil }) {
          do { try context.save() } catch {
            pendingContext = context
            return
          }
        }
        let recorder = activity.recorder
        for var p in pending {
          if let model = p.model, !model.isDeleted, model.modelContext != nil {
            p.item.itemRef = Self.ref(model.persistentModelID)
          }
          var event = p.item.event(snapshot: p.snapshot, calendar: runtime.calendar)
          var props = ActivityProps.dictionary(event.props)
          props["observed_ms"] = ActivityClock.ms(p.observedAt)
          event.props = ActivityProps.json(props)
          recorder.record(event)
        }
        pending = []
        recorder.flush()
      }
      try? context.save()
    }

    private func cancelPendingFlush() {
      flushTask?.cancel()
      flushTask = nil
      pendingContext = nil
      flushScheduled = false
    }

    nonisolated package static func ref(_ id: PersistentIdentifier) -> String? {
      (try? JSONEncoder().encode(id)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Compare decoded identity values without rewriting existing serialized Activity references.
    nonisolated package static func comparisonKey(_ reference: String) -> String {
      guard let data = reference.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data),
        let stable = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
        let key = String(data: stable, encoding: .utf8)
      else { return reference }
      return key
    }

    /// The reminder an entry points at, if it still exists.
    package func task(for entry: LedgerItem, in context: ModelContext) -> OneTask? {
      model(OneTask.self, for: entry, in: context)
    }

    /// The reminder, alarm or list an entry points at, if it still exists.
    package func model<T: PersistentModel>(
      _ type: T.Type, for entry: LedgerItem, in context: ModelContext
    ) -> T? {
      guard let ref = entry.itemRef, let data = ref.data(using: .utf8),
        let id = try? JSONDecoder().decode(PersistentIdentifier.self, from: data)
      else { return nil }
      var d = FetchDescriptor<T>(predicate: #Predicate { $0.persistentModelID == id })
      d.fetchLimit = 1
      return (try? context.fetch(d))?.first
    }

    /// Whether `entry` was undone already (here, or in the store by an earlier launch).
    package func isUndone(_ entry: LedgerItem) -> Bool {
      if undoneIDs.contains(entry.id) { return true }
      let undone = try? activity.store?.undone(among: [entry.id.uuidString])
      return undone?.contains(entry.id.uuidString) == true
    }

    /// The Undo snapshot stored with `entry`, decoded; nil when there is none (an old row, pruned after 30 days, or
    /// already undone).
    package func undoSnapshot<T: Decodable>(
      _ type: T.Type, of entry: LedgerItem, context: ModelContext
    ) -> T? {
      flush(context)
      guard !disposed, !isUndone(entry),
        let data = try? activity.store?.snapshot(uid: entry.id.uuidString)
      else { return nil }
      return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Drops expired activity (the changes ledger by the Settings choice: 90 days, 1 year or forever). Called at launch.
    package func prune(now: Date) {
      let center = activity
      guard let store = center.store else { return }
      _ = try? store.prune(retention: center.settings.retention, now: now)
    }

    /// Changes recorded (tier 1).
    package func count() -> Int {
      activity.recorder.flush()
      return (try? activity.store?.count(ActivityQuery(tiers: [.changes]))) ?? 0
    }

    /// Clears every kind of activity; used by Delete All Data.
    package func clearAll() {
      cancelPendingFlush()
      pending = []
      activity.clear()
    }

    package static func snapshot(of t: OneTask) -> TaskSnapshot {
      TaskSnapshot(
        title: t.title, note: t.note, isDone: t.isDone, doneAt: t.doneAt,
        durationMinutes: t.durationMinutes, due: t.due, createdAt: t.createdAt,
        reminderOffsetMinutes: t.reminderOffsetMinutes, listName: t.listName, tags: t.tags,
        flagged: t.flagged,
        repeatRule: t.repeatRule, checklist: t.checklist, ringsAsAlarm: t.ringsAsAlarm,
        reminderAlert: t.reminderAlert)
    }

    package func task(from s: TaskSnapshot) -> OneTask {
      let t = OneTask(
        title: s.title, note: s.note, durationMinutes: s.durationMinutes, due: s.due)
      t.isDone = s.isDone
      t.doneAt = s.doneAt
      // A new creation date, so it is written to Apple Reminders again when that is connected (as TaskActions' Undo does).
      t.createdAt = runtime.now()
      t.reminderOffsetMinutes = s.reminderOffsetMinutes
      t.listName = s.listName
      t.tags = s.tags
      t.flagged = s.flagged
      t.repeatRule = s.repeatRule
      t.checklist = s.checklist
      t.ringsAsAlarm = s.ringsAsAlarm
      t.reminderAlert = s.reminderAlert
      return t
    }

    @discardableResult
    package func removeCreatedTask(_ task: OneTask, context: ModelContext, channel: LedgerChannel)
      -> Bool
    {
      guard !task.isDeleted, task.modelContext != nil else { return true }
      reminders.noteDeleted(reminder: task.externalID)
      let title = task.title
      context.delete(task)
      do { try context.save() } catch { return false }
      record(.deleted, title: title, channel: channel, context: context)
      return true
    }

    /// Undo from Activity: puts the reminder back as it was before this entry, and records the undo.
    /// False when it can't (the reminder is gone, or it changed again since).
    @discardableResult
    package func undo(_ entry: LedgerItem, context: ModelContext) -> Bool {
      flush(context)
      guard !disposed, entry.itemKind == "task", !isUndone(entry) else { return false }
      let action = entry.actionValue
      if action == .deleted {
        guard let stored = try? activity.store?.snapshot(uid: entry.id.uuidString),
          let s = try? JSONDecoder().decode(TaskSnapshot.self, from: stored)
        else { return false }
        let t = task(from: s)
        context.insert(t)
        do { try context.save() } catch {
          context.delete(t)
          return false
        }
        recordUndo(of: entry, task: t, context: context)
        flush(context)
        return true
      }
      guard let t = task(for: entry, in: context) else { return false }
      let oldDoneAt = t.doneAt
      switch action {
      case .completed:
        guard t.isDone else { return false }
        do { _ = try reminders.commitCompletion(t, done: !t.isDone) } catch { return false }
        t.isDone.toggle()
        t.doneAt = t.isDone ? runtime.now() : nil
        do { try context.save() } catch {
          if t.externalID != nil {
            reminders.scheduleReconcile(after: .milliseconds(50))
          } else {
            t.isDone.toggle()
            t.doneAt = oldDoneAt
          }
          return false
        }
        reminders.didPersistCompletion(t)
      case .reopened:
        guard !t.isDone else { return false }
        do { _ = try reminders.commitCompletion(t, done: !t.isDone) } catch { return false }
        t.isDone.toggle()
        t.doneAt = t.isDone ? runtime.now() : nil
        do { try context.save() } catch {
          if t.externalID != nil {
            reminders.scheduleReconcile(after: .milliseconds(50))
          } else {
            t.isDone.toggle()
            t.doneAt = oldDoneAt
          }
          return false
        }
        reminders.didPersistCompletion(t)
      case .planned, .moved, .unscheduled:
        // Retired planned-time entries from before a reminder had one date: nothing to put back.
        return false
      case .redated:
        guard !t.isDone, t.due == entry.afterDate else { return false }
        let before = Ledger.snapshot(of: t)
        var restored = before
        restored.due = entry.beforeDate
        do {
          try AttachedReminderActions.persist(
            t, from: before, to: restored,
            context: context, reminders: reminders)
        } catch { return false }
      case .renamed:
        guard t.title == entry.after else { return false }
        t.title = entry.before
        try? context.save()
        reminders.scheduleReconcile()
      case .created:
        reminders.noteDeleted(reminder: t.externalID)
        context.delete(t)
      case .deleted, .undone, .granted, .revoked, .settled, .snoozed, .restored, .edited,
        .switchedOn, .switchedOff:
        return false
      }
      if action != .redated {
        do { try context.save() } catch {
          reminders.scheduleReconcile(after: .milliseconds(50))
          return false
        }
      }
      recordUndo(of: entry, task: action == .created ? nil : t, context: context)
      flush(context)
      return true
    }
  }

#endif
