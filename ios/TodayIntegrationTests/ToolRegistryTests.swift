#if os(iOS)
  import Foundation
  import SwiftData
  import Testing
  import TodayCore
  import TodayData
  import TodayTestSupport
  @testable import One

  /// Re-validation in the code-owned write layer (docs/engineering/ai-agent-architecture.md §4.2).
  /// Ask's own writes are pinned by `AskWriteSnapshotTests`.
  @MainActor
  @Suite(.serialized)
  struct ToolRegistryTests {
    @Test
    func aReminderEditWithAStaleExpectationWritesNothing() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let due = a.now.addingTimeInterval(3600)
      let task = a.task("Call Sam", due: due)
      let expected = ToolRegistry.snapshot(of: .task(task))
      task.flagged = true
      try a.context.save()
      for edit in [ChangeProposal.Edit.move(due.addingTimeInterval(3600)), .delete] {
        let result = a.apply(
          ChangeProposal(
            target: .task(task), edit: edit, oldText: "", attendees: 0, expected: expected))
        #expect(!result.applied && result.undo == nil)
        #expect(
          result.replies == [
            "This reminder changed since the preview. Ask again to prepare a current preview."
          ])
      }
      #expect(task.due == due && !task.isDeleted)
      #expect(try a.rows().isEmpty)
    }

    @Test
    func aReminderEditWithACurrentExpectationApplies() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let due = a.now.addingTimeInterval(3600)
      let task = a.task("Call Sam", due: due)
      let result = a.apply(
        ChangeProposal(
          target: .task(task), edit: .move(due.addingTimeInterval(3600)), oldText: "",
          attendees: 0, expected: ToolRegistry.snapshot(of: .task(task))))
      #expect(result.applied && task.due == due.addingTimeInterval(3600))
      #expect(try a.rows().first?.actionValue == .redated)
    }

    @Test
    func aRepeatChangeWithoutAnExpectationIsTreatedAsStale() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let due = a.now.addingTimeInterval(3600)
      let task = a.task("Stretch", due: due)
      let result = a.apply(
        ChangeProposal(
          target: .task(task), edit: .setRepeat(rule: "daily", due: due), oldText: "",
          attendees: 0))
      #expect(!result.applied && task.repeatRule == nil)
    }

    @Test
    func anEventEditWithAStaleExpectationWritesNothing() throws {
      let a = try RegistryFixture()
      defer { a.dispose() }
      let start = a.now.addingTimeInterval(3600)
      let event = OneEvent(title: "Review", start: start, durationMinutes: 30)
      a.context.insert(event)
      try a.context.save()
      let expected = ToolRegistry.snapshot(of: .event(event), attendees: 2)
      #expect(expected.start == start && expected.attendees == 2 && !expected.repeats)
      event.start = start.addingTimeInterval(600)
      try a.context.save()
      let result = a.apply(
        ChangeProposal(
          target: .event(event), edit: .move(start.addingTimeInterval(3600)), oldText: "",
          attendees: 2, expected: expected))
      #expect(!result.applied && event.start == start.addingTimeInterval(600))
      #expect(
        result.replies == [
          "This event changed since the preview. Ask again to prepare a current preview."
        ])
      #expect(try a.rows().isEmpty)
    }

    @Test
    func aSystemMoveExpectationCarriesItsLastModifiedTimeAndAudience() {
      let modified = Date(timeIntervalSince1970: 1_792_400_000)
      let start = modified.addingTimeInterval(86_400)
      let snapshot = CalendarMoveSnapshot(
        externalID: "ek", calendarID: "work", sourceID: "local", itemID: "item",
        occurrence: start, start: start, end: start.addingTimeInterval(1800), isAllDay: false,
        lastModified: modified, title: "Board call", location: nil, notes: nil, url: nil,
        audience: CalendarMoveAudience(attendeeCount: 3, isOrganizer: true),
        participantIDs: ["a", "b", "c"])
      let expected = SystemMoveProposal(expected: snapshot, start: start).snapshot
      #expect(
        expected
          == ProposalSnapshot(lastModified: modified, start: start, attendees: 3, repeats: false))
    }
  }

  @MainActor
  private final class RegistryFixture {
    let suite = "ToolRegistryTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let runtime: PlannerRuntime
    let context: ModelContext
    let services: PlannerTestServices
    var now: Date { runtime.now() }

    init() throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
      let fixed = Date(timeIntervalSince1970: 1_792_486_800)
      runtime = PlannerRuntime(
        now: { fixed }, nextID: { UUID() }, calendar: calendar,
        locale: Locale(identifier: "en_US_POSIX"))
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

    func task(_ title: String, due: Date) -> OneTask {
      let task = OneTask(title: title, due: due)
      context.insert(task)
      try? context.save()
      return task
    }

    func apply(_ p: ChangeProposal) -> WriteResult {
      ToolRegistry.apply(
        p, context: context, calendar: services.calendar, actions: services.actions,
        ledger: services.ledger)
    }

    func rows() throws -> [LedgerItem] {
      services.ledger.flush(context)
      return try services.activityStore.page(ActivityQuery(tiers: [.changes]), limit: 150).map {
        LedgerItem(event: $0)
      }
    }
  }
#endif
