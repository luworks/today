#if os(iOS)
  import Foundation
  import SwiftData
  import Testing
  import TodayCore
  import TodayData
  import TodayTestSupport
  @testable import One

  /// The agent's on-phone tools against a real in-memory store (docs/engineering/ai-agent-architecture.md
  /// §1.3, §4.2): reads never write, writes only prepare cards, and Apply re-checks the item and tier.
  @MainActor
  @Suite(.serialized)
  struct AgentPlannerToolsTests {
    @Test
    func aStaleReminderCardIsVoidAtApplyAndWritesNothing() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      let due = a.now.addingTimeInterval(26 * 3600)
      let task = a.task("[QA] Dentist", due: due)
      let id = a.tools.id(for: task)
      let out = await a.call("propose_edit", ["id": .string(id), "when_text": "4pm"])
      let p = try #require(out["proposal_id"]?.string)
      #expect(a.sink.shown.count == 1)
      #expect(task.due == due, "preparing a card writes nothing")
      // The reminder changes before the user taps Apply.
      task.flagged = true
      try a.context.save()
      let outcome = await a.tools.apply(p)
      #expect(outcome.kind == .void)
      #expect(task.due == due)
      #expect(a.tools.book.entry(p)?.status == .void)
      #expect(try a.rows().isEmpty)
    }

    @Test
    func aCurrentReminderCardAppliesRecordsAndUndoes() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      let due = a.now.addingTimeInterval(26 * 3600)
      let task = a.task("[QA] Dentist", due: due)
      let out = await a.call(
        "propose_edit", ["id": .string(a.tools.id(for: task)), "when_text": "4pm"])
      let p = try #require(out["proposal_id"]?.string)
      let outcome = await a.tools.apply(p)
      #expect(outcome.kind == .applied)
      #expect(task.due != due)
      #expect(a.runtime.calendar.component(.hour, from: task.due!) == 16)
      #expect(try a.rows().count == 1)
      #expect(a.tools.book.entry(p)?.status == .applied)
      #expect(await outcome.undo?() == nil)
      #expect(task.due == due)
    }

    @Test
    func anEventWithAttendeesNeedsItsOwnConfirmationAndSaysWhoIsNotified() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      let event = OneEvent(
        title: "[QA] Weekly sync", start: a.now.addingTimeInterval(20 * 3600), durationMinutes: 60)
      event.externalID = "qa-linked"
      a.context.insert(event)
      try a.context.save()
      a.services.calendar.audiences["qa-linked"] = (3, true)
      a.tools.turn = AgentTurn(text: "把明天的周会删掉", chinese: true, runID: "r1")
      let found = await a.call("find_items", ["query": "Weekly sync", "kinds": ["event"]])
      let id = try #require(found["items"]?.array?.first?["id"]?.string)
      let out = await a.call("propose_delete", ["id": .string(id), "scope": "this"])
      let p = try #require(out["proposal_id"]?.string)
      let card = try #require(a.sink.shown.last)
      #expect(card.tier == .confirmConsequence([.deletesEvent, .notifies(attendees: 3)]))
      #expect(card.consequences.contains("会通知 3 人"))
      #expect(a.tools.book.addAll().isEmpty, "never part of Add all")
      #expect(a.tools.book.entry(p)?.status == .open)
      #expect(!event.isDeleted)
    }

    @Test
    func meetingsStayFixedUnlessTheUserAskedToMoveOne() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      let event = OneEvent(
        title: "[QA] Lunch", start: a.now.addingTimeInterval(20 * 3600), durationMinutes: 60)
      a.context.insert(event)
      try a.context.save()
      let found = await a.call("find_items", ["query": "lunch"])
      let id = try #require(found["items"]?.array?.first?["id"]?.string)
      a.tools.turn = AgentTurn(text: "what's on tomorrow", chinese: false, runID: "r1")
      let refused = await a.call("propose_edit", ["id": .string(id), "when_text": "3pm"])
      #expect(refused["reason"] == "meetingsStayFixed")
      #expect(a.sink.shown.isEmpty)
      a.tools.turn = AgentTurn(text: "move lunch to 3pm", chinese: false, runID: "r2")
      let shown = await a.call("propose_edit", ["id": .string(id), "when_text": "3pm"])
      #expect(shown["proposal_id"] != nil)
      #expect(a.sink.shown.last?.tier == .preview)
    }

    @Test
    func readsReturnShortIDsAndCreatesOnlyPrepareCards() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      _ = a.task("[QA] 看牙医", due: a.now.addingTimeInterval(26 * 3600))
      // A dentist "appointment" asked for as an event is still found as a reminder.
      let found = await a.call("find_items", ["query": "牙医", "kinds": ["event"]])
      #expect(found["items"]?.array?.first?["id"] == "t1")
      #expect(found["note"] != nil)
      let before = try a.context.fetchCount(FetchDescriptor<OneTask>())
      let created = await a.call(
        "propose_create",
        ["items": [["kind": "reminder", "title": "买牛奶", "when_text": "tomorrow 9am"]]])
      let result = try #require(created["results"]?.array?.first)
      #expect(result["status"] == "shown_to_user")
      #expect(result["parsed"]?["time"] == "09:00")
      #expect(try a.context.fetchCount(FetchDescriptor<OneTask>()) == before)
      #expect(a.sink.shown.last?.tier == .preview)
      #expect(try a.rows().isEmpty)
    }

    @Test
    func reportedSpeechCreatesNoCard() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      a.tools.turn = AgentTurn(text: "我朋友说他明天要提醒自己买茶", chinese: true, runID: "r1")
      let out = await a.call(
        "propose_create",
        ["items": [["kind": "reminder", "title": "买茶", "when_text": "明天"]]])
      let result = try #require(out["results"]?.array?.first)
      #expect(result["reason"] == "reportedSpeech")
      #expect(a.sink.shown.isEmpty)
      a.tools.turn = AgentTurn(text: "提醒我明天买茶", chinese: true, runID: "r2")
      let shown = await a.call(
        "propose_create",
        ["items": [["kind": "reminder", "title": "买茶", "when_text": "明天"]]])
      #expect(shown["results"]?.array?.first?["status"] == "shown_to_user")
    }

    @Test
    func reviseWorksOnlyOnUndecidedCards() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      let task = a.task("[QA] Dentist", due: a.now.addingTimeInterval(26 * 3600))
      let out = await a.call(
        "propose_edit", ["id": .string(a.tools.id(for: task)), "when_text": "4pm"])
      let p = try #require(out["proposal_id"]?.string)
      let revised = await a.call(
        "revise_proposal", ["proposal_id": .string(p), "when_text": "5pm"])
      #expect(revised["status"] == "revised")
      _ = await a.tools.apply(p)
      #expect(a.runtime.calendar.component(.hour, from: task.due!) == 17)
      let refused = await a.call(
        "revise_proposal", ["proposal_id": .string(p), "when_text": "6pm"])
      #expect(refused["error"] == "proposal_decided")
      #expect(refused["item_id"] == "t1")
    }
  }

  @MainActor
  private final class CardSink: AgentCardSink {
    var shown: [AgentCard] = []
    func show(_ card: AgentCard) { shown.append(card) }
    func revise(_ card: AgentCard) {}
  }

  @MainActor
  private final class AgentFixture {
    let suite = "AgentPlannerToolsTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let runtime: PlannerRuntime
    let context: ModelContext
    let services: PlannerTestServices
    let tools: AgentPlannerTools
    let sink = CardSink()
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
      tools = AgentPlannerTools(
        history: AgentHistory(now: fixed), context: context, calendar: services.calendar,
        actions: services.actions, ledger: services.ledger, runtime: runtime)
      tools.turn = AgentTurn(text: "move the dentist to 4pm", chinese: false, runID: "r0")
      tools.sink = sink
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

    func call(_ name: String, _ args: JSONValue) async -> JSONValue {
      let out = await tools.run(
        AgentToolCall(callID: UUID().uuidString, name: name, arguments: args.text))
      return JSONValue.parse(out.output) ?? .null
    }

    func rows() throws -> [LedgerItem] {
      services.ledger.flush(context)
      return try services.activityStore.page(ActivityQuery(tiers: [.changes]), limit: 150).map {
        LedgerItem(event: $0)
      }
    }
  }
#endif
