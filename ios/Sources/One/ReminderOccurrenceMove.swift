#if os(iOS)
  import Foundation
  import SwiftData
  import TodayCore

  /// One EventKit batch, paired with one local save. Session-only, not a planner database model.
  @MainActor
  package struct ReminderOccurrenceCommit {
    package struct Accepted {
      package let series: RemindersSync.Remote
      package let occurrence: RemindersSync.Remote
      package init(series: RemindersSync.Remote, occurrence: RemindersSync.Remote) {
        self.series = series
        self.occurrence = occurrence
      }
    }
    package let nextDue: Date
    package let apply: (Date) throws -> Accepted
    package let restore: () throws -> RemindersSync.Remote
    package let restart: () -> Void
    package init(
      nextDue: Date, apply: @escaping (Date) throws -> Accepted,
      restore: @escaping () throws -> RemindersSync.Remote, restart: @escaping () -> Void
    ) {
      self.nextDue = nextDue
      self.apply = apply
      self.restore = restore
      self.restart = restart
    }
  }

  /// Explicit manual occurrence move. The original series keeps its identity and original next time.
  @MainActor
  package final class ReminderOccurrenceMove {
    package enum Failure: LocalizedError {
      case changed, unsupported, partialCommit
      package var errorDescription: String? {
        switch self {
        case .changed: "One of these reminders changed. Open Reminders before trying again."
        case .unsupported:
          "This repeat pattern cannot be split safely here. Use the reminder editor for an explicit series change."
        case .partialCommit:
          "The reminder operation could not be fully restored. Check the original series and its single reminder in Apple Reminders before trying again."
        }
      }
    }

    private struct History: Codable {
      let original: TaskSnapshot
      let next: TaskSnapshot
      let occurrence: TaskSnapshot
      let occurrenceRef: String?
    }

    private let series: OneTask
    private let before: TaskSnapshot
    private let context: ModelContext
    private let reminders: any ReminderService
    private let ledger: Ledger
    private let runtime: PlannerRuntime
    private let source: ReminderOccurrenceCommit?
    private let seriesID: String?
    private let nextDue: Date
    private var applied = false
    private var blocked = false

    package init(
      series: OneTask, expected: TaskSnapshot, context: ModelContext,
      reminders: any ReminderService, ledger: Ledger, runtime: PlannerRuntime
    ) throws {
      guard !expected.isDone, let due = expected.due,
        let rule = expected.repeatRule.flatMap(RepeatRule.init(rawValue:))
      else { throw Failure.unsupported }
      try Self.validate(series, expected: expected, context: context)
      self.series = series
      before = expected
      self.context = context
      self.reminders = reminders
      self.ledger = ledger
      self.runtime = runtime
      seriesID = series.externalID
      source = try reminders.prepareOccurrenceMove(series, expected: expected)
      nextDue = source?.nextDue ?? rule.next(after: due, calendar: runtime.calendar)
      guard nextDue > due else { throw Failure.unsupported }
    }

    package func apply(
      to due: Date, save: (() throws -> Void)? = nil,
      undoSave: ((ModelContext) throws -> Void)? = nil
    ) throws
      -> AttachedReminderActions.Receipt
    {
      guard !applied, !blocked, series.externalID == seriesID, let original = before.due,
        runtime.calendar.isDate(due, inSameDayAs: original), due != original
      else { throw Failure.changed }
      try Self.validate(series, expected: before, context: context)
      let occurrence = series.copy()
      occurrence.repeatRule = nil
      occurrence.due = due
      occurrence.createdAt = runtime.now()
      let accepted = try source?.apply(due)
      occurrence.externalID = accepted?.occurrence.id
      series.due = nextDue
      context.insert(occurrence)
      do {
        if let save { try save() } else { try context.save() }
      } catch {
        series.due = original
        context.delete(occurrence)
        if let source {
          do {
            let restored = try source.restore()
            reminders.didPersistEdit(series, accepted: restored)
            source.restart()
          } catch {
            blocked = true
            reminders.scheduleReconcile(after: .milliseconds(50))
            throw Failure.partialCommit
          }
        }
        throw error
      }
      applied = true
      reminders.didPersistEdit(series, accepted: accepted?.series)
      reminders.didPersistEdit(occurrence, accepted: accepted?.occurrence)
      let after = Ledger.snapshot(of: series)
      let moved = Ledger.snapshot(of: occurrence)
      let seriesID = series.externalID
      let occurrenceID = occurrence.externalID
      let entry = ledger.record(
        .edited, task: series, title: before.title,
        before: ledger.timeLabel(original), after: "This occurrence: " + ledger.timeLabel(due),
        beforeDate: original, afterDate: due, actor: .you, channel: .app, approval: .userMade,
        snapshot: History(
          original: before, next: after, occurrence: moved,
          occurrenceRef: Ledger.ref(occurrence.persistentModelID)), context: context)
      return AttachedReminderActions.Receipt { [self, series] in
        guard series.externalID == seriesID, occurrence.externalID == occurrenceID else {
          throw Failure.changed
        }
        try Self.validate(series, expected: after, context: self.context)
        try Self.validate(occurrence, expected: moved, context: self.context)
        let restored = try self.source?.restore()
        // A failed deletion cannot safely be repaired by reinserting the same SwiftData object.
        // Keep both displayed identities intact until a separate context commits the whole pair.
        let writer = ModelContext(self.context.container)
        writer.autosaveEnabled = false
        let saved = try writer.fetch(FetchDescriptor<OneTask>())
        guard
          let savedSeries = saved.first(where: { $0.persistentModelID == series.persistentModelID }
          ),
          let savedChild = saved.first(where: {
            $0.persistentModelID == occurrence.persistentModelID
          }),
          Ledger.snapshot(of: savedSeries) == after, Ledger.snapshot(of: savedChild) == moved
        else { throw Failure.changed }
        savedSeries.due = original
        writer.delete(savedChild)
        if let undoSave { try undoSave(writer) } else { try writer.save() }
        _ = try self.context.fetch(FetchDescriptor<OneTask>())
        if let occurrenceID { self.reminders.noteDeleted(reminder: occurrenceID) }
        self.reminders.didPersistEdit(series, accepted: restored)
        self.ledger.recordUndo(of: entry, task: series, channel: .app, context: self.context)
      }
    }

    private static func validate(_ task: OneTask, expected: TaskSnapshot, context: ModelContext)
      throws
    {
      guard !task.isDeleted, task.modelContext === context, Ledger.snapshot(of: task) == expected
      else {
        throw Failure.changed
      }
      let reader = ModelContext(context.container)
      guard
        let saved = try reader.fetch(FetchDescriptor<OneTask>()).first(where: {
          $0.persistentModelID == task.persistentModelID
        }), Ledger.snapshot(of: saved) == expected, saved.externalID == task.externalID
      else {
        throw Failure.changed
      }
    }
  }
#endif
