#if os(iOS) && DEBUG
  import Foundation
  import SwiftData
  import SwiftUI
  import Testing
  import TodayCore
  import TodayDesignSystem
  import TodayPlatform
  import TodayTestSupport
  import UIKit
  @testable import FeatureAsk
  @testable import One

  /// P3 evaluation driver (docs/qa/agent-p3-eval-20261101.md). Runs the real `AskView` (FastLane + agent)
  /// on a frozen eval set against the deployed Luna Worker with synthetic accounts, over an
  /// in-memory store seeded from the set's synthetic world. Only observes: scoring is
  /// `scripts/ai/agent_p3_score.py`. A no-op unless `/tmp/agent-p3/run.json` exists, so CI never pays.
  @MainActor
  @Suite(.serialized)
  struct AgentEvalTests {
    static let configPath = "/tmp/agent-p3/run.json"

    struct Config: Decodable {
      var fixture: String
      var reps: Int
      var cases: [String]?
      var out: String
      var endpoint: String
      var accounts: String
      var accountOffset: Int
      var settleMilliseconds: Int?
      var repStart: Int?
    }

    @Test
    func runFrozenEvalSet() async throws {
      guard FileManager.default.fileExists(atPath: Self.configPath) else { return }
      let config = try JSONDecoder().decode(
        Config.self, from: Data(contentsOf: URL(fileURLWithPath: Self.configPath)))
      let fixtureText = String(
        decoding: try Data(contentsOf: URL(fileURLWithPath: config.fixture)), as: UTF8.self)
      let fixture = try #require(JSONValue.parse(fixtureText))
      let accountsText = String(
        decoding: try Data(contentsOf: URL(fileURLWithPath: config.accounts)), as: UTF8.self)
      let bearers = (JSONValue.parse(accountsText)?.array ?? []).compactMap(\.string)
      #expect(!bearers.isEmpty)
      let endpoint = try #require(URL(string: config.endpoint))
      FileManager.default.createFile(atPath: config.out, contents: nil)
      let out = try #require(FileHandle(forWritingAtPath: config.out))
      defer { try? out.close() }
      let world = try #require(fixture["world"])
      let wanted = config.cases.map(Set.init)
      var turnIndex = config.accountOffset
      let account = EvalAccount()
      let first = config.repStart ?? 1
      for rep in first..<(first + max(1, config.reps)) {
        for item in fixture["cases"]?.array ?? [] {
          guard let id = item["id"]?.string, wanted?.contains(id) ?? true else { continue }
          let harness = try EvalHarness(
            world: world,
            model: AgentModel(
              client: HostedLunaClient(configuration: { account.configuration }),
              isAvailable: { true }))
          defer { harness.dispose() }
          try await harness.open()
          for (n, turn) in (item["turns"]?.array ?? []).enumerated() {
            let index = turnIndex % bearers.count
            turnIndex += 1
            account.set(.init(endpoint: endpoint, bearer: bearers[index]))
            var record = await harness.turn(
              turn["input"]?.string ?? "", settle: config.settleMilliseconds ?? 1500)
            for step in turn["expect"]?["then"]?.array ?? [] {
              if let m = step["mutate"] {
                harness.mutate(m)
              } else if step["apply"] != nil {
                record["apply"] = await harness.applyOpenChange(
                  settle: config.settleMilliseconds ?? 1500)
              }
            }
            record["case"] = .string(id)
            record["rep"] = .number(Double(rep))
            record["turn"] = .number(Double(n + 1))
            record["account"] = .number(Double(index))
            record["time_zone"] = .string(TimeZone.current.identifier)
            out.write(Data((JSONValue.object(record).text + "\n").utf8))
          }
        }
      }
    }
  }

  /// The synthetic account the next agent step uses (rotated per turn to stay inside per-user quotas).
  private final class EvalAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var current: HostedLunaClient.Configuration?
    var configuration: HostedLunaClient.Configuration? {
      lock.lock()
      defer { lock.unlock() }
      return current
    }
    func set(_ c: HostedLunaClient.Configuration) {
      lock.lock()
      current = c
      lock.unlock()
    }
  }

  /// One fresh chat over a fresh in-memory store seeded with the eval world.
  @MainActor
  private final class EvalHarness {
    let suite = "AgentEval.\(UUID().uuidString)"
    let defaults: UserDefaults
    let container: ModelContainer
    let context: ModelContext
    let runtime: PlannerRuntime
    let services: PlannerTestServices
    let presentation: PlannerPresentation
    let probe = AskEvalProbe()
    /// World key → store identity (`AskEvalProbe.key`), and back.
    var keys: [String: String] = [:]
    var models: [String: any PersistentModel] = [:]
    var window: UIWindow?
    var previous: UIWindow?
    var turnNumber = 0

    let model: AgentModel

    init(world: JSONValue, model: AgentModel) throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      self.model = model
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(identifier: world["timeZone"]?.string ?? ""))
      let now = try #require(Self.date(world["localNow"]?.string, calendar))
      runtime = PlannerRuntime(
        now: { now }, nextID: { UUID() }, calendar: calendar,
        locale: Locale(identifier: "en_US"))
      let schema = Schema([
        OneTask.self, OneEvent.self, OneAlarm.self, OneList.self,
        ChatThread.self, ShareImportReceipt.self,
      ])
      container = try ModelContainer(
        for: schema,
        configurations: [
          ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
      context = container.mainContext
      services = try PlannerTestServices(
        container: container, defaults: defaults, runtime: runtime, arguments: [])
      presentation = PlannerPresentation(runtime: runtime, defaults: defaults)
      try seed(world["items"]?.array ?? [])
    }

    static func date(_ text: String?, _ calendar: Calendar) -> Date? {
      guard let text else { return nil }
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = calendar.timeZone
      for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
        f.dateFormat = format
        if let d = f.date(from: text) { return d }
      }
      return nil
    }

    private func seed(_ items: [JSONValue]) throws {
      let cal = runtime.calendar
      for item in items {
        guard let key = item["key"]?.string, let title = item["title"]?.string else { continue }
        switch item["kind"]?.string {
        case "reminder":
          let task = OneTask(
            title: title, note: item["note"]?.string ?? "", due: Self.date(item["due"]?.string, cal)
          )
          task.createdAt = runtime.now().addingTimeInterval(-86_400)
          context.insert(task)
          models[key] = task
        case "event":
          let start = try #require(Self.date(item["start"]?.string, cal))
          let event = OneEvent(
            title: title, start: start, durationMinutes: item["minutes"]?.int ?? 60)
          event.location = item["location"]?.string
          if let ext = item["externalID"]?.string {
            event.externalID = ext
            services.calendar.audiences[ext] = (
              item["attendees"]?.int ?? 0, item["organizer"]?.bool ?? true
            )
            services.calendar.writableExternalIDs.insert(ext)
          }
          context.insert(event)
          models[key] = event
        case "alarm":
          let alarm = OneAlarm(
            hour: item["hour"]?.int ?? 0, minute: item["minute"]?.int ?? 0, label: title,
            weekdays: (item["weekdays"]?.array ?? []).compactMap(\.int))
          alarm.isOn = item["on"]?.bool ?? true
          context.insert(alarm)
          models[key] = alarm
        default: continue
        }
      }
      try context.save()
      for (key, model) in models { keys[key] = AskEvalProbe.key(model) }
    }

    func open() async throws {
      AskEvalProbe.current = probe
      let view = AskView(
        thread: nil, calendar: services.calendar, now: runtime.now,
        actions: services.actions, ledger: services.ledger, activity: services.activity,
        agentModel: model,
        voice: VoiceInput(driver: LiveSpeechInputDriver(locale: runtime.locale)),
        presentation: presentation,
        onBack: { _ in }, onAdded: { _ in }, onOpenDay: { _ in },
        onOpenTask: { _, _ in }, onOpenAlarm: { _, _ in }
      )
      .modelContainer(container)
      let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      previous = scene.windows.first(where: \.isKeyWindow)
      let w = UIWindow(windowScene: scene)
      w.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
      w.rootViewController = UIHostingController(rootView: view)
      window = w
      w.makeKeyAndVisible()
      for _ in 0..<200 where probe.snapshot() == .null {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(probe.snapshot() != .null, "AskView registered the eval probe")
    }

    func dispose() {
      window?.endEditing(true)
      window?.isHidden = true
      window?.rootViewController = nil
      window = nil
      previous?.makeKey()
      AskEvalProbe.current = nil
      services.dispose()
      defaults.removePersistentDomain(forName: suite)
    }

    /// Item fields that matter for "written without a tap", by store identity.
    func store() -> JSONValue {
      let cal = runtime.calendar
      var out: [String: JSONValue] = [:]
      for t in (try? context.fetch(FetchDescriptor<OneTask>())) ?? [] {
        out[AskEvalProbe.key(t)] = [
          "kind": "reminder", "title": .string(t.title),
          "due": AskEvalProbe.stamp(t.due, calendar: cal), "done": .bool(t.isDone),
          "repeat": t.repeatRule.map(JSONValue.string) ?? .null, "alarm": .bool(t.ringsAsAlarm),
        ]
      }
      for e in (try? context.fetch(FetchDescriptor<OneEvent>())) ?? [] {
        out[AskEvalProbe.key(e)] = [
          "kind": "event", "title": .string(e.title),
          "start": AskEvalProbe.stamp(e.start, calendar: cal),
          "minutes": .number(Double(e.durationMinutes)),
          "repeat": e.repeatRule.map(JSONValue.string) ?? .null,
        ]
      }
      for a in (try? context.fetch(FetchDescriptor<OneAlarm>())) ?? [] {
        out[AskEvalProbe.key(a)] = [
          "kind": "alarm", "title": .string(a.label),
          "time": .string(String(format: "%02d:%02d", a.hour, a.minute)),
          "weekdays": .array(a.weekdays.map { .number(Double($0)) }), "on": .bool(a.isOn),
        ]
      }
      return .object(out)
    }

    /// Cards on screen: capture cards, the old change card, agent change cards, Tidy.
    static func cardCount(_ s: JSONValue) -> Int {
      (s["proposals"]?.array?.count ?? 0) + (s["change"] == .null || s["change"] == nil ? 0 : 1)
        + (s["agent_changes"]?.array?.count ?? 0) + (s["tidy"]?.int ?? 0 > 0 ? 1 : 0)
    }

    private func waitForSettle(
      from t0: Date, baseline: Int, settle: Int, shown: JSONValue? = nil
    ) async -> (snapshot: JSONValue, firstCard: Double?, settled: Double, timedOut: Bool) {
      var last = shown ?? probe.snapshot()
      var lastChange = t0
      var firstCard: Double?
      var sawThinking = false
      while true {
        try? await Task.sleep(for: .milliseconds(25))
        let s = probe.snapshot()
        if firstCard == nil, Self.cardCount(s) > baseline {
          firstCard = Date().timeIntervalSince(t0)
        }
        if s["thinking"]?.bool == true { sawThinking = true }
        if s != last {
          last = s
          lastChange = Date()
        }
        let elapsed = Date().timeIntervalSince(t0)
        let quiet = Date().timeIntervalSince(lastChange) * 1000
        if s["thinking"]?.bool != true, quiet >= Double(settle), elapsed > 0.3 {
          _ = sawThinking
          return (s, firstCard, lastChange.timeIntervalSince(t0), false)
        }
        if elapsed > 75 { return (s, firstCard, elapsed, true) }
      }
    }

    func turn(_ input: String, settle: Int) async -> [String: JSONValue] {
      turnNumber += 1
      let before = store()
      let shown = probe.snapshot()
      let runs = probe.runs.count
      let t0 = Date()
      probe.send(input)
      let r = await waitForSettle(
        from: t0, baseline: Self.cardCount(shown), settle: settle, shown: shown)
      let after = store()
      var record: [String: JSONValue] = [
        "input": .string(input), "before_snapshot": shown, "snapshot": r.snapshot,
        "store_before": before, "store_after": after,
        "first_card_ms": r.firstCard.map { .number(($0 * 1000).rounded()) } ?? .null,
        "settled_ms": .number((r.settled * 1000).rounded()), "timed_out": .bool(r.timedOut),
        "keys": .object(keys.mapValues(JSONValue.string)),
      ]
      record["agent_runs"] = .array(probe.runs.dropFirst(runs).map(Self.run))
      return record
    }

    static func run(_ r: AgentRunResult) -> JSONValue {
      let stop: String
      switch r.stop {
      case .finished: stop = "finished"
      case .stepCap: stop = "step_cap"
      case .deadline: stop = "deadline"
      case .cancelled: stop = "cancelled"
      case .failed(let e): stop = "failed:\(e)"
      }
      return [
        "steps": .number(Double(r.steps)), "cards": .number(Double(r.cards)),
        "first_card_ms": r.firstCard.map { .number(($0 * 1000).rounded()) } ?? .null,
        "duration_ms": .number((r.duration * 1000).rounded()),
        "cost_micros": .number(Double(r.costMicros)),
        "input": .number(Double(r.usage.reduce(0) { $0 + $1.input })),
        "cached": .number(Double(r.usage.reduce(0) { $0 + $1.cached })),
        "output": .number(Double(r.usage.reduce(0) { $0 + $1.output })),
        "stop": .string(stop), "calls": .array(r.calls.map(JSONValue.string)),
        "reply": .string(r.reply), "model_text": .string(r.modelText),
        "user_message": .string(r.items.first.flatMap(AgentItem.text) ?? ""),
        "tool_args": .array(
          r.items.filter { $0["type"]?.string == "function_call" }.map {
            .string("\($0["name"]?.string ?? "")(\($0["arguments"]?.string ?? ""))")
          }),
      ]
    }

    /// A change made outside the chat (another device, the Reminders app) after the card showed.
    func mutate(_ m: JSONValue) {
      guard let key = m["key"]?.string, let task = models[key] as? OneTask else { return }
      if let due = m["due"]?.string { task.due = Self.date(due, runtime.calendar) }
      try? context.save()
    }

    func applyOpenChange(settle: Int) async -> JSONValue {
      let before = store()
      let t0 = Date()
      await probe.applyChange()
      let r = await waitForSettle(from: t0, baseline: Int.max, settle: settle)
      return ["store_before": before, "store_after": store(), "snapshot": r.snapshot]
    }
  }
#endif
