#if os(iOS)
  import Foundation
  import EventKit
  import SwiftData
  import Testing
  import TodayCore
  import TodayData
  import TodayTestSupport
  @testable import One

  @MainActor @Suite(.serialized)
  struct ReminderOccurrenceMoveTests {
    @Test func theSplitAndItsUndoAreDurableAcrossFreshDiskReaders() throws {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReminderOccurrenceMove-\(UUID()).store")
      let a = try Fixture(storeURL: url)
      defer { a.dispose() }
      let before = Ledger.snapshot(of: a.series)
      func read() throws -> [TaskSnapshot] {
        let container = try ModelContainer(
          for: Fixture.schema,
          configurations: [
            ModelConfiguration(schema: Fixture.schema, url: url, cloudKitDatabase: .none)
          ])
        let reader = ModelContext(container)
        return try reader.fetch(FetchDescriptor<OneTask>()).map { Ledger.snapshot(of: $0) }
      }
      let receipt = try a.move().apply(to: a.target)
      let moved = try read()
      #expect(moved.count == 2)
      #expect(moved.contains { $0.due == a.target && $0.repeatRule == nil })
      #expect(
        moved.contains { $0.due == a.due.addingTimeInterval(86400) && $0.repeatRule == "daily" })
      try receipt.undo()
      #expect(try read() == [before])
    }

    @Test func nativeWeekdayAdvanceKeepsTheExplicitDaysAcrossRegionalWeekends() throws {
      var calendar = Calendar(identifier: .gregorian)
      calendar.locale = Locale(identifier: "ar_SA")
      calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
      let friday = try #require(
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12)))
      let monday = try #require(
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12)))
      #expect(
        RemindersSync.nextOccurrenceDue(rule: .weekdays, after: friday, calendar: calendar)
          == monday)
    }

    @Test func nativeRepeatRulesMustNotBeFlattenedOrShiftTheirDateAnchor() throws {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
      let due = try #require(
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12)))
      #expect(
        RemindersSync.supportsOccurrenceSplit(
          RemindersSync.recurrence(for: .weekdays), rule: .weekdays, due: due, calendar: calendar))
      #expect(
        !RemindersSync.supportsOccurrenceSplit(
          EKRecurrenceRule(
            recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3)),
          rule: .daily, due: due, calendar: calendar))
      #expect(
        !RemindersSync.supportsOccurrenceSplit(
          EKRecurrenceRule(recurrenceWith: .daily, interval: 2, end: nil),
          rule: .daily, due: due, calendar: calendar))
      #expect(
        !RemindersSync.supportsOccurrenceSplit(
          RemindersSync.recurrence(for: .monthly), rule: .monthly, due: due, calendar: calendar))
    }

    @Test func aFailedCompensationBlocksAnotherSplitInsteadOfCreatingADuplicate() throws {
      let a = try Fixture()
      defer { a.dispose() }
      let move = try a.move()
      a.services.reminders.occurrenceUndoFailure = .injected
      #expect(throws: (any Error).self) {
        try move.apply(to: a.target, save: { throw CocoaError(.fileWriteUnknown) })
      }
      #expect(a.services.reminders.occurrenceCommits == 1)
      #expect(a.services.reminders.occurrenceRemotes.count == 2)
      #expect(throws: (any Error).self) { try move.apply(to: a.target) }
      #expect(throws: (any Error).self) { try a.move() }
      #expect(a.services.reminders.occurrenceCommits == 1)
    }

    @Test func localSplitKeepsTheOriginalNextTimeAndUndoRestoresBoth() throws {
      let a = try Fixture(connected: false)
      defer { a.dispose() }
      let original = Ledger.snapshot(of: a.series)
      let receipt = try a.move().apply(to: a.target)
      let child = try #require(try a.tasks().first { $0 !== a.series })
      #expect(a.series.due == a.due.addingTimeInterval(86400))
      #expect(child.due == a.target && child.repeatRule == nil && !child.isDone)
      #expect(child.title == original.title && child.note == original.note)
      #expect(child.flagged && child.listName == "Work" && child.tags == ["review"])
      #expect(child.checklist == original.checklist && child.ringsAsAlarm)
      #expect(child.reminderOffsetMinutes == 10 && child.durationMinutes == 25)
      try receipt.undo()
      #expect(try a.tasks().count == 1 && Ledger.snapshot(of: a.series) == original)
    }

    @Test func syncedSplitCommitsOnePairAndUndoKeepsTheSeriesIdentity() throws {
      let a = try Fixture()
      defer { a.dispose() }
      let move = try a.move()
      let receipt = try move.apply(to: a.target)
      #expect(a.services.reminders.occurrenceCommits == 1)
      #expect(a.services.reminders.occurrenceRemotes.count == 2)
      #expect(
        a.services.reminders.occurrenceRemotes["series"]?.due == a.due.addingTimeInterval(86400))
      #expect(a.series.externalID == "series")
      #expect(throws: (any Error).self) { try move.apply(to: a.target) }
      try receipt.undo()
      #expect(a.services.reminders.occurrenceRestores == 1)
      #expect(a.services.reminders.occurrenceRemotes.count == 1)
      #expect(a.services.reminders.occurrenceRemotes["series"]?.due == a.due)
      #expect(try a.tasks().count == 1 && a.series.externalID == "series")
      #expect(throws: (any Error).self) { try receipt.undo() }
    }

    @Test func failedSourceCommitWritesNeitherObjectAndRetryCreatesOnlyOneChild() throws {
      let a = try Fixture()
      defer { a.dispose() }
      let move = try a.move()
      a.services.reminders.creationFailure = .injected
      #expect(throws: (any Error).self) { try move.apply(to: a.target) }
      #expect(try a.tasks().count == 1 && a.series.due == a.due)
      #expect(a.services.reminders.occurrenceRemotes.count == 1)
      #expect(a.services.reminders.occurrenceCommits == 0)
      a.services.reminders.creationFailure = nil
      _ = try move.apply(to: a.target)
      #expect(try a.tasks().count == 2)
      #expect(a.services.reminders.occurrenceCommits == 1)
    }

    @Test func aLocalSaveFailureCompensatesThePairBeforeRetry() throws {
      let a = try Fixture()
      defer { a.dispose() }
      let move = try a.move()
      #expect(throws: (any Error).self) {
        try move.apply(to: a.target, save: { throw CocoaError(.fileWriteUnknown) })
      }
      #expect(try a.tasks().count == 1 && a.series.due == a.due)
      #expect(a.services.reminders.occurrenceRemotes.count == 1)
      #expect(a.services.reminders.occurrenceRestores == 1)
      let receipt = try move.apply(to: a.target)
      #expect(try a.tasks().count == 2 && a.services.reminders.occurrenceRemotes.count == 2)
      try receipt.undo()
      #expect(try a.tasks().count == 1 && a.services.reminders.occurrenceRemotes.count == 1)
    }

    @Test func failedSourceUndoRetainsBothObjectsAndItsReceiptForRetry() throws {
      let a = try Fixture()
      defer { a.dispose() }
      let receipt = try a.move().apply(to: a.target)
      a.services.reminders.occurrenceUndoFailure = .injected
      #expect(throws: (any Error).self) { try receipt.undo() }
      #expect(try a.tasks().count == 2 && a.series.due == a.due.addingTimeInterval(86400))
      #expect(a.services.reminders.occurrenceRemotes.count == 2)
      a.services.reminders.occurrenceUndoFailure = nil
      try receipt.undo()
      #expect(try a.tasks().count == 1 && a.series.due == a.due)
      #expect(a.services.reminders.occurrenceRestores == 1)
    }

    @Test func aLaterChildEditPreventsUndoOfEitherObject() throws {
      let a = try Fixture()
      defer { a.dispose() }
      let receipt = try a.move().apply(to: a.target)
      let child = try #require(try a.tasks().first { $0 !== a.series })
      child.title = "Changed later"
      try a.context.save()
      #expect(throws: (any Error).self) { try receipt.undo() }
      #expect(child.title == "Changed later" && a.series.due == a.due.addingTimeInterval(86400))
      #expect(a.services.reminders.occurrenceRestores == 0)
      #expect(a.services.reminders.occurrenceRemotes.count == 2)
    }

    @Test func aMissingSystemChildPreventsUndoAndDoesNotRecreateIt() throws {
      let a = try Fixture()
      defer { a.dispose() }
      let receipt = try a.move().apply(to: a.target)
      let child = try #require(try a.tasks().first { $0 !== a.series })
      a.services.reminders.occurrenceRemotes[try #require(child.externalID)] = nil
      #expect(throws: (any Error).self) { try receipt.undo() }
      #expect(try a.tasks().count == 2 && a.series.due == a.due.addingTimeInterval(86400))
      #expect(
        a.services.reminders.occurrenceCommits == 1 && a.services.reminders.occurrenceRestores == 0)
    }

    @Test func aLocalUndoRetryNeverReplaysTheCommittedSourceRestoration() throws {
      let a = try Fixture()
      defer { a.dispose() }
      var failOnce = true
      let receipt = try a.move().apply(
        to: a.target,
        undoSave: { writer in
          if failOnce {
            failOnce = false
            throw CocoaError(.fileWriteUnknown)
          }
          try writer.save()
        })
      #expect(throws: (any Error).self) { try receipt.undo() }
      #expect(try a.tasks().count == 2 && a.series.due == a.due.addingTimeInterval(86400))
      #expect(a.services.reminders.occurrenceRestores == 1)
      try receipt.undo()
      #expect(try a.tasks().count == 1 && a.series.due == a.due)
      #expect(a.services.reminders.occurrenceRestores == 1)
    }

    @Test func aLaterSeriesEditOrLinkChangePreventsTheSplit() throws {
      let a = try Fixture()
      defer { a.dispose() }
      let move = try a.move()
      a.series.externalID = "another-series"
      try a.context.save()
      #expect(throws: (any Error).self) { try move.apply(to: a.target) }
      #expect(try a.tasks().count == 1 && a.services.reminders.occurrenceCommits == 0)
    }
  }

  @MainActor private final class Fixture {
    static var schema: Schema {
      Schema([
        OneTask.self, OneEvent.self, OneAlarm.self, OneList.self, ChatThread.self,
        ShareImportReceipt.self,
      ])
    }
    let defaults: UserDefaults
    let suite = "ReminderOccurrenceMoveTests.\(UUID())"
    let context: ModelContext
    let services: PlannerTestServices
    let runtime: PlannerRuntime
    let series: OneTask
    let due: Date
    var target: Date { due.addingTimeInterval(1800) }

    init(connected: Bool = true, storeURL: URL? = nil) throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
      let now = Date(timeIntervalSince1970: 1_792_486_800)
      runtime = PlannerRuntime(
        now: { now }, nextID: { UUID() }, calendar: calendar,
        locale: Locale(identifier: "en_US_POSIX"))
      due = now.addingTimeInterval(3600)
      let configuration =
        storeURL.map {
          ModelConfiguration(schema: Self.schema, url: $0, cloudKitDatabase: .none)
        }
        ?? ModelConfiguration(
          schema: Self.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      let container = try ModelContainer(for: Self.schema, configurations: [configuration])
      context = ModelContext(container)
      context.autosaveEnabled = false
      services = try PlannerTestServices(
        container: container, defaults: defaults, runtime: runtime, arguments: [])
      series = OneTask(title: "Daily review", note: "Keep this note", due: due)
      series.createdAt = now
      series.repeatRule = "daily"
      series.listName = "Work"
      series.flagged = true
      series.tags = ["review"]
      series.ringsAsAlarm = true
      series.reminderOffsetMinutes = 10
      series.checklist = [ChecklistItem(title: "Read")]
      series.externalID = connected ? "series" : nil
      context.insert(series)
      try context.save()
      services.reminders.isConnected = connected
      services.reminders.occurrenceRemotes["series"] = RemindersSync.Remote(
        id: "series", title: series.title, notes: series.note, isDone: false, doneAt: nil,
        due: due, listID: "work", listTitle: "Work", flagged: true, repeatRule: "daily",
        repeats: true)
    }
    func tasks() throws -> [OneTask] { try context.fetch(FetchDescriptor<OneTask>()) }
    func move() throws -> ReminderOccurrenceMove {
      try ReminderOccurrenceMove(
        series: series, expected: Ledger.snapshot(of: series), context: context,
        reminders: services.reminders, ledger: services.ledger, runtime: runtime)
    }
    func dispose() {
      services.dispose()
      defaults.removePersistentDomain(forName: suite)
    }
  }
#endif
