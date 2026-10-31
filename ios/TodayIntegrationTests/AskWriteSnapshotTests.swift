#if os(iOS)
  import Foundation
  import SwiftData
  import Synchronization
  import Testing
  import TodayCore
  import TodayData
  import TodayTestSupport
  @testable import FeatureAsk
  @testable import One

  /// Behavior snapshots of every approved Ask write (P1 of docs/engineering/ai-agent-architecture.md).
  /// They pin the store state, Activity ledger rows, replies and Undo results before the write layer moves,
  /// and must keep passing unchanged afterwards.
  @MainActor
  @Suite(.serialized)
  struct AskWriteSnapshotTests {
    // MARK: Reminders

    @Test
    func reminderMoveRecordsARedateAndUndoRestoresOnce() throws {
      let a = try WriteFixture(seed: 1)
      defer { a.dispose() }
      let original = a.now.addingTimeInterval(3600)
      let moved = original.addingTimeInterval(7200)
      let task = try a.addTask("Call the bank", due: original)
      let feedback = a.apply(a.change(.task(task), newStart: moved))
      #expect(feedback.applied)
      #expect(task.due == moved)
      #expect(feedback.messages.map(\.text) == ["Moved “Call the bank” to \(a.label(moved))."])
      #expect(feedback.messages.allSatisfy { $0.role == .ai })
      #expect(feedback.undo?.label == "Moved “Call the bank”.")
      let rows = try a.rows()
      #expect(rows.count == 1)
      let row = try #require(rows.first)
      #expect(row.actionValue == .redated && row.itemKind == "task" && row.title == "Call the bank")
      #expect(row.before == a.label(original) && row.after == a.label(moved))
      #expect(row.beforeDate == original && row.afterDate == moved)
      #expect(row.actor == LedgerActor.todayAI.raw && row.channel == LedgerChannel.ask.rawValue)
      #expect(row.approval == LedgerApproval.asked.rawValue)
      try #require(feedback.undo).action()
      try #require(feedback.undo).action()
      #expect(task.due == original)
      #expect(try a.rows().filter { $0.actionValue == .undone }.count == 1)
    }

    @Test
    func reminderMoveUndoStepsAsideAfterALaterEditOrCompletion() throws {
      for completes in [false, true] {
        let a = try WriteFixture(seed: completes ? 3 : 2)
        defer { a.dispose() }
        let original = a.now.addingTimeInterval(3600)
        let moved = original.addingTimeInterval(3600)
        let task = try a.addTask("Pay rent", due: original)
        let feedback = a.apply(a.change(.task(task), newStart: moved))
        if completes { task.isDone = true } else { task.due = moved.addingTimeInterval(600) }
        try a.context.save()
        try #require(feedback.undo).action()
        #expect(task.due == (completes ? moved : moved.addingTimeInterval(600)))
        #expect(try a.rows().filter { $0.actionValue == .undone }.isEmpty)
      }
    }

    @Test
    func reminderMoveToTheSameDateWritesNothingAndOffersNoUndo() throws {
      let a = try WriteFixture(seed: 4)
      defer { a.dispose() }
      let due = a.now.addingTimeInterval(3600)
      let task = try a.addTask("Unchanged", due: due)
      let feedback = a.apply(a.change(.task(task), newStart: due))
      #expect(feedback.applied && feedback.messages.isEmpty && feedback.undo == nil)
      #expect(task.due == due)
      #expect(try a.rows().isEmpty)
    }

    @Test
    func reminderDeleteRecordsASnapshotAndUndoRestoresTheSameFields() throws {
      let a = try WriteFixture(seed: 5)
      defer { a.dispose() }
      let due = a.now.addingTimeInterval(5400)
      let task = try a.addTask("Return the parcel", due: due)
      task.note = "Front desk"
      task.flagged = true
      try a.context.save()
      let feedback = a.apply(a.change(.task(task), delete: true))
      try a.context.save()
      #expect(feedback.applied && feedback.messages.isEmpty)
      #expect(try a.tasks().isEmpty)
      #expect(feedback.undo?.label == "Deleted “Return the parcel”")
      let row = try #require(try a.rows().first)
      #expect(row.actionValue == .deleted && row.title == "Return the parcel" && row.hasSnapshot)
      #expect(row.actor == LedgerActor.todayAI.raw && row.channel == LedgerChannel.ask.rawValue)
      try #require(feedback.undo).action()
      try #require(feedback.undo).action()
      let restored = try #require(try a.tasks().first)
      #expect(try a.tasks().count == 1)
      #expect(restored.title == "Return the parcel" && restored.note == "Front desk")
      #expect(restored.flagged && restored.due == due)
      #expect(try a.rows().filter { $0.actionValue == .undone }.count == 1)
    }

    @Test
    func reminderRepeatChangeAppliesAndUndoRestoresTheRuleAndDate() throws {
      let a = try WriteFixture(seed: 6)
      defer { a.dispose() }
      let original = a.now.addingTimeInterval(3600)
      let next = original.addingTimeInterval(86_400)
      let task = try a.addTask("Water the plants", due: original)
      var change = a.change(.task(task), newStart: next)
      change.newRepeatRule = "daily"
      change.expectedTask = Ledger.snapshot(of: task)
      let feedback = a.apply(change)
      #expect(feedback.applied)
      #expect(task.repeatRule == "daily" && task.due == next)
      #expect(feedback.messages.map(\.text) == ["Updated “Water the plants” to repeat every day."])
      #expect(feedback.undo?.label == "Changed “Water the plants”.")
      try #require(feedback.undo).action()
      #expect(task.repeatRule == nil && task.due == original)
      #expect(try a.rows().filter { $0.actionValue == .undone }.count == 1)
      // A second Undo finds the reminder changed since and does nothing.
      try #require(feedback.undo).action()
      #expect(task.repeatRule == nil && task.due == original)
      #expect(try a.rows().filter { $0.actionValue == .undone }.count == 1)
    }

    @Test
    func reminderRepeatChangeRefusesAStalePreview() throws {
      let a = try WriteFixture(seed: 7)
      defer { a.dispose() }
      let original = a.now.addingTimeInterval(3600)
      let task = try a.addTask("Stretch", due: original)
      var change = a.change(.task(task), newStart: original.addingTimeInterval(86_400))
      change.newRepeatRule = "daily"
      change.expectedTask = Ledger.snapshot(of: task)
      task.title = "Stretch for ten minutes"
      try a.context.save()
      let feedback = a.apply(change)
      #expect(!feedback.applied && feedback.undo == nil)
      #expect(
        feedback.messages.map(\.text) == [
          "This reminder changed since the preview. Ask again to prepare a current preview."
        ])
      #expect(task.repeatRule == nil && task.due == original)
      #expect(try a.rows().isEmpty)
    }

    @Test
    func deletedReminderAlarmAndSystemSubjectsAreNotApplied() throws {
      let a = try WriteFixture(seed: 8)
      defer { a.dispose() }
      let task = try a.addTask("Gone", due: a.now.addingTimeInterval(3600))
      let stale = a.change(.task(task), newStart: a.now.addingTimeInterval(7200))
      a.context.delete(task)
      try a.context.save()
      let gone = a.apply(stale)
      #expect(!gone.applied && gone.messages.isEmpty && gone.undo == nil)
      let alarm = OneAlarm(hour: 7, minute: 30)
      a.context.insert(alarm)
      try a.context.save()
      let alarmChange = a.apply(a.change(.alarm(alarm), newStart: a.now))
      #expect(!alarmChange.applied && alarmChange.messages.isEmpty && alarmChange.undo == nil)
      let system = a.apply(a.change(.systemEvent, newStart: a.now))
      #expect(!system.applied && system.messages.isEmpty && system.undo == nil)
      #expect(try a.rows().isEmpty)
    }

    // MARK: Today events

    @Test
    func localEventMoveRecordsAMoveAndUndoRestoresTheStart() throws {
      let a = try WriteFixture(seed: 9)
      defer { a.dispose() }
      let start = a.now.addingTimeInterval(3600)
      let moved = start.addingTimeInterval(5400)
      let event = a.addEvent("Design review", start: start)
      let feedback = a.apply(a.change(.event(event), newStart: moved))
      #expect(feedback.applied && event.start == moved)
      #expect(feedback.messages.map(\.text) == ["Moved “Design review” to \(a.label(moved))."])
      #expect(feedback.undo?.label == "Moved “Design review”.")
      let row = try #require(try a.rows().first)
      #expect(row.actionValue == .moved && row.itemKind == "event" && row.title == "Design review")
      #expect(row.before == a.label(start) && row.after == a.label(moved))
      #expect(row.actor == LedgerActor.todayAI.raw && row.approval == LedgerApproval.asked.rawValue)
      try #require(feedback.undo).action()
      #expect(event.start == start)
      try #require(feedback.undo).action()
      #expect(try a.rows().filter { $0.actionValue == .undone }.count == 1)
    }

    @Test
    func eventUndoNamesAttendeesWhoseUpdatesCannotBeRecalled() throws {
      let a = try WriteFixture(seed: 10)
      defer { a.dispose() }
      let event = a.addEvent("Team sync", start: a.now.addingTimeInterval(3600))
      let feedback = a.apply(
        a.change(.event(event), newStart: a.now.addingTimeInterval(7200), attendees: 4))
      #expect(
        feedback.undo?.label
          == "Moved “Team sync”. Attendee updates already sent can't be recalled.")
    }

    @Test
    func localEventDeleteRecordsTheDeletionAndUndoRecreatesIt() throws {
      let a = try WriteFixture(seed: 11)
      defer { a.dispose() }
      let start = a.now.addingTimeInterval(3600)
      let event = a.addEvent("Dentist", start: start)
      event.note = "Bring the card"
      try a.context.save()
      let feedback = a.apply(a.change(.event(event), delete: true, oldText: "Today 10:00"))
      #expect(feedback.applied)
      #expect(try a.events().isEmpty)
      #expect(feedback.messages.map(\.text) == ["Deleted “Dentist”."])
      #expect(feedback.undo?.label == "Deleted “Dentist”.")
      let row = try #require(try a.rows().first)
      #expect(row.actionValue == .deleted && row.itemKind == "event" && row.before == "Today 10:00")
      try #require(feedback.undo).action()
      let restored = try #require(try a.events().first)
      #expect(restored.title == "Dentist" && restored.note == "Bring the card")
      #expect(restored.start == start && restored.externalID == nil)
      #expect(try a.rows().filter { $0.actionValue == .undone }.count == 1)
    }

    @Test
    func repeatingAndReadOnlyEventsAreRefused() throws {
      let a = try WriteFixture(seed: 12)
      defer { a.dispose() }
      let start = a.now.addingTimeInterval(3600)
      let repeating = a.addEvent("Standup", start: start)
      repeating.repeatRule = "daily"
      let readOnly = a.addEvent("Shared review", start: start)
      readOnly.externalID = "read-only"
      try a.context.save()
      for event in [repeating, readOnly] {
        let feedback = a.apply(a.change(.event(event), newStart: start.addingTimeInterval(3600)))
        #expect(!feedback.applied && feedback.undo == nil)
        #expect(
          feedback.messages.map(\.text) == [
            "This event can't be changed here. Open it in Calendar."
          ])
        #expect(event.start == start)
      }
      #expect(try a.rows().isEmpty)
    }

    @Test
    func linkedEventMoveSavesThroughCalendarAndRollsBackARefusal() throws {
      let a = try WriteFixture(seed: 13)
      defer { a.dispose() }
      let start = a.now.addingTimeInterval(3600)
      let moved = start.addingTimeInterval(3600)
      let event = a.addEvent("Linked review", start: start)
      event.externalID = "ek-1"
      try a.context.save()
      a.calendar.writableExternalIDs = ["ek-1"]
      a.calendar.saveResult = { _ in nil }
      let refused = a.apply(a.change(.event(event), newStart: moved))
      #expect(!refused.applied && refused.undo == nil && event.start == start)
      #expect(
        refused.messages.map(\.text) == [
          "Couldn't update the calendar event. The preview is still here."
        ])
      #expect(try a.rows().isEmpty)
      var saved: [Date] = []
      a.calendar.saveResult = { event in
        saved.append(event.start)
        return event.externalID
      }
      let feedback = a.apply(a.change(.event(event), newStart: moved))
      #expect(feedback.applied && event.start == moved && saved == [moved])
      #expect(try a.rows().first?.actionValue == .moved)
      try #require(feedback.undo).action()
      #expect(event.start == start && saved == [moved, start])
      #expect(try a.rows().filter { $0.actionValue == .undone }.count == 1)
    }

    @Test
    func linkedEventDeleteKeepsTheEventWhenCalendarRefuses() throws {
      let a = try WriteFixture(seed: 14)
      defer { a.dispose() }
      let event = a.addEvent("Linked lunch", start: a.now.addingTimeInterval(3600))
      event.externalID = "ek-2"
      try a.context.save()
      a.calendar.writableExternalIDs = ["ek-2"]
      a.calendar.deletionResult = false
      let refused = a.apply(a.change(.event(event), delete: true))
      #expect(!refused.applied && refused.undo == nil)
      #expect(
        refused.messages.map(\.text) == [
          "Couldn't delete the calendar event. The preview is still here."
        ])
      #expect(try a.events().count == 1 && a.rows().isEmpty)
      a.calendar.deletionResult = true
      a.calendar.saveResult = { _ in "ek-2-restored" }
      let feedback = a.apply(a.change(.event(event), delete: true))
      #expect(feedback.applied && a.calendar.deletionRequests.last == "ek-2")
      #expect(try a.events().isEmpty)
      try #require(feedback.undo).action()
      let restored = try #require(try a.events().first)
      #expect(restored.title == "Linked lunch" && restored.externalID == "ek-2-restored")
      #expect(try a.rows().filter { $0.actionValue == .undone }.count == 1)
    }

    // MARK: Tidy overdue

    @Test
    func tidyRedatesChosenRowsKeepsOthersAndUndoRestoresEach() throws {
      let a = try WriteFixture(seed: 15)
      defer { a.dispose() }
      let yesterday = a.now.addingTimeInterval(-86_400)
      let moved = try a.addTask("Send invoice", due: yesterday)
      let kept = try a.addTask("Old idea", due: yesterday.addingTimeInterval(-3600))
      var rows = [
        TidyRow(task: moved, oldDue: yesterday, choice: .today),
        TidyRow(task: kept, oldDue: yesterday.addingTimeInterval(-3600), choice: .keep),
      ]
      let expected = OverdueTidy.newDue(
        yesterday, .today, now: a.now, calendar: a.runtime.calendar)
      let feedback = AskNativeActions.applyTidy(
        rows: &rows, context: a.context, actions: a.services.actions, ledger: a.services.ledger,
        runtime: a.runtime)
      #expect(feedback.applied && rows.isEmpty)
      #expect(moved.due == expected && kept.due == yesterday.addingTimeInterval(-3600))
      #expect(feedback.messages.map(\.text) == ["Moved 1 reminder."])
      #expect(feedback.undo?.label == "Moved 1 reminder.")
      let row = try #require(try a.rows().first)
      #expect(try a.rows().count == 1)
      #expect(row.actionValue == .redated && row.title == "Send invoice")
      #expect(row.beforeDate == yesterday && row.afterDate == expected)
      #expect(row.actor == LedgerActor.todayAI.raw && row.channel == LedgerChannel.ask.rawValue)
      try #require(feedback.undo).action()
      #expect(moved.due == yesterday)
      #expect(try a.rows().filter { $0.actionValue == .undone }.count == 1)
    }

    @Test
    func tidySkipsRowsChangedSinceThePreviewAndUndoSkipsLaterEdits() throws {
      let a = try WriteFixture(seed: 16)
      defer { a.dispose() }
      let yesterday = a.now.addingTimeInterval(-86_400)
      let first = try a.addTask("First", due: yesterday)
      let second = try a.addTask("Second", due: yesterday)
      let changed = try a.addTask("Changed", due: yesterday)
      var rows = [first, second, changed].map {
        TidyRow(task: $0, oldDue: yesterday, choice: .tomorrow)
      }
      changed.due = a.now.addingTimeInterval(3600)
      try a.context.save()
      let feedback = AskNativeActions.applyTidy(
        rows: &rows, context: a.context, actions: a.services.actions, ledger: a.services.ledger,
        runtime: a.runtime)
      let expected = OverdueTidy.newDue(
        yesterday, .tomorrow, now: a.now, calendar: a.runtime.calendar)
      #expect(feedback.applied && feedback.messages.map(\.text) == ["Moved 2 reminders."])
      #expect(first.due == expected && second.due == expected)
      #expect(changed.due == a.now.addingTimeInterval(3600))
      #expect(try a.rows().filter { $0.actionValue == .redated }.count == 2)
      second.isDone = true
      try a.context.save()
      try #require(feedback.undo).action()
      #expect(first.due == yesterday && second.due == expected)
      #expect(try a.rows().filter { $0.actionValue == .undone }.count == 1)
    }

    // MARK: Apple Calendar occurrence move

    @Test
    func systemMoveVerifiedRecordsTheReceiptAndUndoRestores() throws {
      let a = try WriteFixture(seed: 17)
      defer { a.dispose() }
      let before = a.moveSnapshot(start: a.now.addingTimeInterval(3600))
      let target = before.start.addingTimeInterval(7200)
      let after = a.moveSnapshot(start: target, from: before)
      var requested: [Date] = []
      a.calendar.moveEventResult = { expected, start in
        #expect(expected == before)
        requested.append(start)
        return .verified(CalendarMoveReceipt(before: before, after: after))
      }
      var undone: [CalendarMoveReceipt] = []
      a.calendar.undoMoveResult = { receipt in
        undone.append(receipt)
        return .verified
      }
      var later: [String] = []
      let result = AskNativeActions.applySystemMove(
        before, to: target, context: a.context, calendar: a.calendar,
        ledger: a.services.ledger, runtime: a.runtime, report: { later.append($0.text) })
      #expect(requested == [target])
      #expect(result.feedback.applied && result.moved == after)
      #expect(result.feedback.messages.map(\.text) == ["The calendar event was moved."])
      #expect(
        result.feedback.undo?.label == "Moved the event. Calendar may notify attendees again.")
      let row = try #require(try a.rows().first)
      #expect(row.actionValue == .moved && row.itemKind == "event" && row.title == "Board call")
      #expect(row.before == a.label(before.start) && row.after == a.label(target))
      #expect(row.beforeDate == before.start && row.afterDate == target && row.hasSnapshot)
      #expect(row.actor == LedgerActor.todayAI.raw && row.approval == LedgerApproval.asked.rawValue)
      try #require(result.feedback.undo).action()
      #expect(undone == [CalendarMoveReceipt(before: before, after: after)])
      #expect(later == ["The event was restored."])
      #expect(try a.rows().filter { $0.actionValue == .undone }.count == 1)
    }

    @Test
    func systemMoveUndoReportsUnverifiedAndFailedRestores() throws {
      let a = try WriteFixture(seed: 18)
      defer { a.dispose() }
      let before = a.moveSnapshot(start: a.now.addingTimeInterval(3600))
      let target = before.start.addingTimeInterval(3600)
      let after = a.moveSnapshot(start: target, from: before)
      a.calendar.moveEventResult = { _, _ in
        .verified(CalendarMoveReceipt(before: before, after: after))
      }
      var later: [String] = []
      a.calendar.undoMoveResult = { _ in .committedUnverified }
      let unverified = AskNativeActions.applySystemMove(
        before, to: target, context: a.context, calendar: a.calendar,
        ledger: a.services.ledger, runtime: a.runtime, report: { later.append($0.text) })
      try #require(unverified.feedback.undo).action()
      #expect(
        later == [
          "Calendar accepted Undo, but the result couldn't be verified. Open Calendar to check it."
        ])
      let edited = try a.rows().filter { $0.actionValue == .edited }
      #expect(edited.count == 1 && edited.first?.after == "Undo committed; result not verified")
      #expect(edited.first?.actor == LedgerActor.you.raw)
      #expect(try a.rows().filter { $0.actionValue == .undone }.isEmpty)
      a.calendar.undoMoveResult = { _ in throw CalendarMoveError.stale }
      let failed = AskNativeActions.applySystemMove(
        before, to: target, context: a.context, calendar: a.calendar,
        ledger: a.services.ledger, runtime: a.runtime, report: { later.append($0.text) })
      try #require(failed.feedback.undo).action()
      #expect(later.last == "Couldn't undo the event change. Open Calendar to check it.")
      #expect(try a.rows().filter { $0.actionValue == .undone }.isEmpty)
    }

    @Test
    func systemMoveCommittedButUnverifiedRecordsItWithoutUndo() throws {
      let a = try WriteFixture(seed: 19)
      defer { a.dispose() }
      let before = a.moveSnapshot(start: a.now.addingTimeInterval(3600))
      let target = before.start.addingTimeInterval(3600)
      a.calendar.moveEventResult = { _, start in
        .committedUnverified(
          CalendarMoveUnverified(
            before: before, requestedStart: start, requestedEnd: start.addingTimeInterval(1800),
            savedExternalID: before.externalID))
      }
      let result = AskNativeActions.applySystemMove(
        before, to: target, context: a.context, calendar: a.calendar,
        ledger: a.services.ledger, runtime: a.runtime, report: { _ in })
      #expect(result.feedback.applied && result.moved == nil && result.feedback.undo == nil)
      #expect(
        result.feedback.messages.map(\.text) == [
          "Calendar accepted the change, but the result couldn't be verified. Open Calendar to check it before trying again."
        ])
      let row = try #require(try a.rows().first)
      #expect(row.actionValue == .moved && row.after == "Calendar accepted; result unverified")
      #expect(row.beforeDate == before.start && row.afterDate == target && row.hasSnapshot)
    }

    @Test
    func systemMoveRefusedByCalendarWritesNothing() throws {
      let a = try WriteFixture(seed: 20)
      defer { a.dispose() }
      let before = a.moveSnapshot(start: a.now.addingTimeInterval(3600))
      for error in [CalendarMoveError.stale, .audienceUnknownOrUnsafe, .unavailable] {
        a.calendar.moveEventResult = { _, _ in throw error }
        let result = AskNativeActions.applySystemMove(
          before, to: before.start.addingTimeInterval(3600), context: a.context,
          calendar: a.calendar, ledger: a.services.ledger, runtime: a.runtime, report: { _ in })
        #expect(!result.feedback.applied && result.moved == nil && result.feedback.undo == nil)
        #expect(
          result.feedback.messages.map(\.text) == [
            "The event could not be changed. Open Calendar to check it."
          ])
      }
      #expect(try a.rows().isEmpty)
    }
  }

  private final class WriteClock: Sendable {
    private struct State {
      var now: Date
      var counter: Int
    }
    private let state: Mutex<State>
    init(seed: Int, now: Date) { state = Mutex(State(now: now, counter: seed * 1000)) }
    func now() -> Date { state.withLock { $0.now } }
    func nextID() -> UUID {
      state.withLock {
        $0.counter += 1
        return UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", $0.counter))!
      }
    }
  }

  /// One in-memory production schema, real Ledger/PlannerActions and the local calendar fake.
  @MainActor
  private final class WriteFixture {
    let suite: String
    let defaults: UserDefaults
    let clock: WriteClock
    let runtime: PlannerRuntime
    let context: ModelContext
    let services: PlannerTestServices
    var calendar: TestCalendarService { services.calendar }
    var now: Date { clock.now() }

    init(seed: Int) throws {
      suite = "AskWriteSnapshotTests.\(seed).\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defaults.removePersistentDomain(forName: suite)
      self.defaults = defaults
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
      calendar.locale = Locale(identifier: "en_US_POSIX")
      // 2026-10-20 09:00 UTC plus the seed: a fixed weekday morning.
      let clock = WriteClock(seed: seed, now: Date(timeIntervalSince1970: 1_792_486_800))
      self.clock = clock
      let runtime = PlannerRuntime(
        now: { clock.now() }, nextID: { clock.nextID() },
        calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
      self.runtime = runtime
      let schema = Schema([
        OneTask.self, OneEvent.self, OneAlarm.self, OneList.self, Habit.self,
        ChatThread.self, LedgerEntry.self, AIGrant.self, ShareImportReceipt.self,
      ])
      let container = try ModelContainer(
        for: schema,
        configurations: [
          ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
      context = ModelContext(container)
      context.autosaveEnabled = false
      services = try PlannerTestServices(
        container: container, defaults: defaults, runtime: runtime, arguments: [])
    }

    func dispose() {
      services.dispose()
      defaults.removePersistentDomain(forName: suite)
    }

    func label(_ date: Date) -> String { services.ledger.timeLabel(date) }

    @discardableResult
    func addTask(_ title: String, due: Date) throws -> OneTask {
      let task = OneTask(title: title)
      task.due = due
      context.insert(task)
      try context.save()
      return task
    }

    @discardableResult
    func addEvent(_ title: String, start: Date) -> OneEvent {
      let event = OneEvent(title: title, start: start, durationMinutes: 30)
      context.insert(event)
      try? context.save()
      return event
    }

    func tasks() throws -> [OneTask] { try context.fetch(FetchDescriptor<OneTask>()) }
    func events() throws -> [OneEvent] { try context.fetch(FetchDescriptor<OneEvent>()) }

    func rows() throws -> [LedgerItem] {
      services.ledger.flush(context)
      return try services.activityStore.page(ActivityQuery(tiers: [.changes]), limit: 150).map {
        LedgerItem(event: $0)
      }
    }

    func change(
      _ subject: PendingChange.Subject, delete: Bool = false, newStart: Date? = nil,
      oldText: String = "", attendees: Int = 0
    ) -> PendingChange {
      let title: String
      switch subject {
      case .task(let task): title = task.title
      case .event(let event): title = event.title
      case .alarm, .systemEvent: title = "Item"
      }
      return PendingChange(
        subject: subject, delete: delete, title: title, oldText: oldText, newStart: newStart,
        notes: [], attendees: attendees)
    }

    func apply(_ change: PendingChange) -> AskActionFeedback {
      AskNativeActions.applyChange(
        change, context: context, calendar: calendar, actions: services.actions,
        ledger: services.ledger, runtime: runtime)
    }

    func moveSnapshot(start: Date, from base: CalendarMoveSnapshot? = nil) -> CalendarMoveSnapshot {
      CalendarMoveSnapshot(
        externalID: base?.externalID ?? "ek-board", calendarID: "work", sourceID: "local",
        itemID: "item-board", occurrence: start, start: start,
        end: start.addingTimeInterval(1800), isAllDay: false,
        lastModified: base.map { $0.lastModified.addingTimeInterval(1) } ?? now,
        title: "Board call", location: nil, notes: nil, url: nil,
        audience: CalendarMoveAudience(attendeeCount: 3, isOrganizer: true),
        participantIDs: ["a", "b", "c"])
    }
  }
#endif
