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
    func requestedEveningMoveUsesFullDurationAndPreservesTarget() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      let day = a.runtime.calendar.startOfDay(for: a.now.addingTimeInterval(86400))
      let start = day.addingTimeInterval(9 * 3600)
      let event = OneEvent(title: "Move Apple benefit to Sunday at 9am", start: start, durationMinutes: 60)
      let busy = OneEvent(title: "Busy", start: day.addingTimeInterval(18 * 3600), durationMinutes: 120)
      a.context.insert(event)
      a.context.insert(busy)
      try a.context.save()
      let found = await a.call("find_items", ["query": "Apple benefit"])
      let id = try #require(found["items"]?.array?.first?["id"]?.string)
      a.tools.turn = AgentTurn(text: "改到晚上", chinese: true, runID: "evening")
      let out = await a.call("propose_edit", ["id": .string(id), "when_text": "晚上"])
      let proposal = try #require(out["proposal_id"]?.string)
      let result = await a.tools.apply(proposal)
      #expect(result.kind == .applied)
      #expect(event.start == day.addingTimeInterval(20 * 3600))
      #expect(event.durationMinutes == 60)
      #expect(await result.undo?() == nil)
      #expect(event.start == start)
    }

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
      // An attendee-free move the user asked for is applied right after the reply, with Undo.
      #expect(a.sink.shown.last?.tier == .direct)
      #expect(shown["applied_after_reply"] == .bool(true))
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

    // MARK: when_text (docs/qa/agent-p3-eval-20261101.md, Must fix 4–8). The clock is Tue 2026-10-20 09:00.

    private func createdCapture(_ a: AgentFixture) -> Capture? {
      guard case .create(let c)? = a.sink.shown.last?.body else { return nil }
      return c
    }

    /// Must fix 4: "6:15 tomorrow" for an alarm is 06:15, as in Apple Clock, and "make it 6:45"
    /// keeps the morning and the card's day; an existing alarm moved to "6:45" rings at 06:45.
    @Test
    func alarmTimesDefaultToTheMorning() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      a.tools.turn = AgentTurn(text: "Set an alarm for 6:15 tomorrow", chinese: false, runID: "r1")
      let out = await a.call(
        "propose_create",
        [
          "items": [
            ["kind": "alarm", "title": "Alarm", "when_text": "6:15 tomorrow", "ring": true]
          ]
        ])
      let result = try #require(out["results"]?.array?.first)
      #expect(result["parsed"]?["time"] == "06:15")
      #expect(result["parsed"]?["day"] == "Wed 2026-10-21")
      let p = try #require(result["proposal_id"]?.string)
      a.tools.turn = AgentTurn(text: "make it 6:45", chinese: false, runID: "r2")
      let revised = await a.call(
        "revise_proposal", ["proposal_id": .string(p), "when_text": "6:45"])
      #expect(revised["parsed"]?["time"] == "06:45")
      #expect(revised["parsed"]?["day"] == "Wed 2026-10-21")

      let alarm = OneAlarm(hour: 6, minute: 15, label: "[QA] Gym")
      a.context.insert(alarm)
      try a.context.save()
      let found = await a.call("find_items", ["query": "Gym", "kinds": ["alarm"]])
      let id = try #require(found["items"]?.array?.first?["id"]?.string)
      a.tools.turn = AgentTurn(text: "change my gym alarm to 6:45", chinese: false, runID: "r3")
      let edited = await a.call("propose_edit", ["id": .string(id), "when_text": "6:45"])
      #expect(edited["after"]?.string?.contains("6:45") == true)
      #expect(edited["after"]?.string?.contains("AM") == true)
    }

    /// Must fix 5: "Monday from 9am to 5pm" (and "周一从9点到5点") is an eight-hour event card.
    @Test
    func anEventRangeGivesTheCardItsLength() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      for words in ["Monday from 9am to 5pm", "周一从9点到5点"] {
        let out = await a.call(
          "propose_create",
          [
            "items": [
              [
                "kind": "event", "title": .string("[QA] Offsite \(words)"),
                "when_text": .string(words),
              ]
            ]
          ])
        let parsed = try #require(out["results"]?.array?.first?["parsed"])
        #expect(parsed["day"] == "Mon 2026-10-26", "\(words)")
        #expect(parsed["time"] == "09:00", "\(words)")
        #expect(parsed["minutes"] == 480, "\(words)")
        #expect(parsed["end"] == "Mon 2026-10-26 17:00", "\(words)")
        #expect(createdCapture(a)?.durationMinutes == 480, "\(words)")
      }
    }

    /// Must fix 6: "改成11点" on next Monday's card keeps Monday; a new day in the words still moves it.
    @Test
    func aRevisionKeepsTheCardsOwnDay() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      a.tools.turn = AgentTurn(text: "下周一上午10点和 Kim 开会", chinese: true, runID: "r1")
      let out = await a.call(
        "propose_create",
        ["items": [["kind": "event", "title": "[QA] 和 Kim 开会", "when_text": "下周一上午10点"]]])
      let p = try #require(out["results"]?.array?.first?["proposal_id"]?.string)
      a.tools.turn = AgentTurn(text: "改成11点", chinese: true, runID: "r2")
      let revised = await a.call(
        "revise_proposal", ["proposal_id": .string(p), "when_text": "11点"])
      #expect(revised["parsed"]?["day"] == "Mon 2026-10-26")
      #expect(revised["parsed"]?["time"] == "11:00")
      // A time that has already passed today is still on the card's day, not rolled to tomorrow.
      let early = await a.call("revise_proposal", ["proposal_id": .string(p), "when_text": "8am"])
      #expect(early["parsed"]?["day"] == "Mon 2026-10-26")
      #expect(early["parsed"]?["time"] == "08:00")
      // A day-only revision keeps the card's time.
      let friday = await a.call("revise_proposal", ["proposal_id": .string(p), "when_text": "周五"])
      #expect(friday["parsed"]?["day"] == "Fri 2026-10-23")
      #expect(friday["parsed"]?["time"] == "08:00")
    }

    /// Must fix 7: moving a 12:00 lunch to "今天12点半" is 12:30 (the time is the destination,
    /// not the item's own time).
    @Test
    func anEditToHalfPastTheItemsOwnHourKeepsTheMinutes() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      let event = OneEvent(
        title: "[QA] 午餐", start: a.now.addingTimeInterval(3 * 3600), durationMinutes: 60)
      a.context.insert(event)
      try a.context.save()
      let found = await a.call("find_items", ["query": "午餐", "kinds": ["event"]])
      let id = try #require(found["items"]?.array?.first?["id"]?.string)
      a.tools.turn = AgentTurn(text: "把今天的午餐改到12点半", chinese: true, runID: "r1")
      for words in ["今天12点半", "12点半"] {
        _ = await a.call("propose_edit", ["id": .string(id), "when_text": .string(words)])
        guard case .change(let change)? = a.sink.shown.last?.body,
          case .move(let date) = change.operation
        else {
          Issue.record("no move card for \(words)")
          continue
        }
        let c = a.runtime.calendar.dateComponents([.day, .hour, .minute], from: date)
        #expect(c.day == 20 && c.hour == 12 && c.minute == 30, "\(words)")
      }
    }

    /// Must fix 8: a bare "10" is 10:00 (it was unreadable), and "tomorrow 10" is tomorrow.
    @Test
    func aBareHourIsATime() async throws {
      let a = try AgentFixture()
      defer { a.dispose() }
      a.tools.turn = AgentTurn(
        text: "Also remind me to buy stamps at 10", chinese: false, runID: "r1")
      let bare = await a.call(
        "propose_create",
        ["items": [["kind": "reminder", "title": "[QA] buy stamps", "when_text": "10"]]])
      #expect(bare["results"]?.array?.first?["parsed"]?["time"] == "10:00")
      #expect(bare["results"]?.array?.first?["parsed"]?["day"] == "Tue 2026-10-20")
      let carried = await a.call(
        "propose_create",
        ["items": [["kind": "reminder", "title": "[QA] buy stamps", "when_text": "tomorrow 10"]]])
      #expect(carried["results"]?.array?.first?["parsed"]?["time"] == "10:00")
      #expect(carried["results"]?.array?.first?["parsed"]?["day"] == "Wed 2026-10-21")
      // A month and day stays a date, not a time.
      let date = await a.call(
        "propose_create",
        ["items": [["kind": "reminder", "title": "[QA] buy stamps", "when_text": "Nov 5"]]])
      #expect(date["results"]?.array?.first?["parsed"]?["day"] == "Thu 2026-11-05")
      #expect(date["results"]?.array?.first?["parsed"]?["time"] == .null)
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
        OneTask.self, OneEvent.self, OneAlarm.self, OneList.self,
        ChatThread.self, ShareImportReceipt.self,
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
