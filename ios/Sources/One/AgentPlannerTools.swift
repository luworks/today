#if os(iOS)
  import EventKit
  import Foundation
  import SwiftData
  import TodayCore
  import TodayData
  import os

  /// Facts about the message the agent is answering, read by rules from the user's own words.
  package struct AgentTurn: Sendable {
    package var text: String
    package var chinese: Bool
    package var runID: String
    package var words: ActionPolicy.Words

    package init(text: String, chinese: Bool, runID: String, words: ActionPolicy.Words = .user) {
      self.text = text
      self.chinese = chinese
      self.runID = runID
      self.words = words
    }
  }

  /// A change to an existing item, prepared by the agent and written only on the user's Apply.
  /// Everything the card says is rendered here by code; the model's `why` is shown as an AI note.
  @MainActor
  package struct AgentChange {
    package enum Target {
      case task(OneTask)
      case event(OneEvent)
      case system(CalendarMoveSnapshot)
      case alarm(OneAlarm)
    }
    package enum Operation: Equatable {
      case move(Date)
      case rename(String)
      case done
      case delete
    }
    package var target: Target
    package var operation: Operation
    package var title: String
    /// Code-rendered "before" and "after" (the card shows before → after).
    package var before: String
    package var after: String
    package var attendees: Int
    package var isOrganizer: Bool
    /// What the item looked like when the card was prepared (§4.2).
    package var expectedTask: TaskSnapshot?
    package var expectedEvent: ProposalSnapshot?
    /// The item's start when the card was prepared; a revision recomputes from here.
    package var baseStart: Date?
    package var itemID: String
    package var userAskedToMove: Bool

    package var kind: ActionPolicy.Kind {
      switch target {
      case .task: .reminder
      case .event, .system: .event
      case .alarm: .alarm
      }
    }

    package var isDelete: Bool { operation == .delete }

    /// The policy facts of this change, with the live attendee count and staleness.
    package func request(attendees live: Int? = nil, changed: Bool = false) -> ActionPolicy.Request
    {
      let fields: Set<ActionPolicy.Field>
      switch operation {
      case .move: fields = kind == .reminder ? [.due] : [.start]
      case .rename: fields = [.title]
      case .done: fields = [.done]
      case .delete: fields = []
      }
      return ActionPolicy.Request(
        tool: isDelete ? .proposeDelete : .proposeEdit, source: .agent, kind: kind,
        fields: fields, userAskedToMoveEvent: userAskedToMove, attendees: live ?? attendees,
        changedSincePreview: changed)
    }
  }

  /// One card the agent put on screen, by proposal id.
  @MainActor
  package struct AgentCard: Identifiable {
    package enum Body {
      case create(Capture)
      case change(AgentChange)
      case tidy([TidyProposal.Row])
    }
    package let id: String
    package var body: Body
    package var tier: ActionPolicy.Tier
    package var why: String?
    package var chinese: Bool

    /// Code-rendered consequences, shown on the card and required before Apply (§4.2 后果确认).
    package var consequences: [String] {
      guard case .confirmConsequence(let set) = tier else { return [] }
      var lines: [String] = []
      for c in set.sorted(by: { "\($0)" < "\($1)" }) {
        switch c {
        case .notifies(let n):
          lines.append(chinese ? "会通知 \(n) 人" : "Notifies \(n) attendee\(n == 1 ? "" : "s")")
        case .wholeSeries: lines.append(chinese ? "影响整个系列" : "Affects the whole series")
        case .deletesEvent:
          lines.append(chinese ? "会从日历删除这个事件" : "Deletes this event from your calendar")
        }
      }
      return lines
    }
  }

  /// Where cards go: the Ask screen shows them as soon as a tool prepares them.
  @MainActor
  package protocol AgentCardSink: AnyObject {
    func show(_ card: AgentCard)
    func revise(_ card: AgentCard)
  }

  /// The result of the user's Apply on a change card.
  @MainActor
  package struct AgentApplyOutcome {
    package enum Kind: Equatable {
      case applied
      /// The item changed since the preview; the card is void (§4.2).
      case void
      /// The stakes went up (e.g. attendees added): the card shows its new consequences; tap again.
      case reconfirm(ActionPolicy.Tier)
      case failed
    }
    package var kind: Kind
    package var message: String?
    package var undo: (() async -> String?)?
  }

  /// The twelve agent tools, run on the phone against the user's own planner (§1.3). Reads return
  /// bounded data with short ids; writes only prepare cards, tiered by `ActionPolicy`; `apply` is
  /// the code-owned write, re-checked against the item's live state.
  @MainActor
  package final class AgentPlannerTools: AgentToolbox {
    package var history: AgentHistory
    package var book = AgentProposalBook()
    package var turn = AgentTurn(text: "", chinese: false, runID: "")
    package private(set) var cards: [String: AgentCard] = [:]
    package weak var sink: (any AgentCardSink)?

    private let context: ModelContext
    private let calendar: any CalendarService
    private let actions: PlannerActions
    private let ledger: Ledger
    private let runtime: PlannerRuntime
    private var cal: Calendar { runtime.calendar }
    private var now: Date { runtime.now() }

    package init(
      history: AgentHistory, context: ModelContext, calendar: any CalendarService,
      actions: PlannerActions, ledger: Ledger, runtime: PlannerRuntime
    ) {
      self.history = history
      self.context = context
      self.calendar = calendar
      self.actions = actions
      self.ledger = ledger
      self.runtime = runtime
    }

    package func run(_ call: AgentToolCall) async -> AgentToolOutcome {
      let a = call.args
      #if DEBUG && targetEnvironment(simulator)
        // Simulator QA only (synthetic data): log the calls so a run can be reviewed. Never on a phone.
        Self.log.debug(
          "AGENT_TOOL \(call.name, privacy: .public) \(call.arguments, privacy: .public)")
      #endif
      switch call.tool {
      case .getAgenda?: return agenda(a)
      case .findItems?: return find(a)
      case .getItem?: return item(a)
      case .freeTime?: return freeTime(a)
      case .listLists?: return listLists()
      case .getActivity?: return activity(a)
      case .proposeCreate?: return create(a)
      case .proposeEdit?: return edit(a)
      case .proposeDelete?: return delete(a)
      case .proposeUndo?:
        return .error(
          "not_supported",
          "Undo from chat isn't available yet. Tell the user to use Undo on the card or in Activity."
        )
      case .reviseProposal?: return revise(a)
      case .proposeTidy?: return tidy(a)
      case nil: return .error("unknown_tool", call.name)
      }
    }

    // MARK: Data (bounded fetches; never whole stores)

    private func tasks(includeDone: Bool) -> [OneTask] {
      var d =
        includeDone
        ? FetchDescriptor<OneTask>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        : FetchDescriptor<OneTask>(
          predicate: #Predicate { !$0.isDone },
          sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
      d.fetchLimit = 3000
      return (try? context.fetch(d)) ?? []
    }

    private func events(before end: Date) -> [OneEvent] {
      var d = FetchDescriptor<OneEvent>(
        predicate: #Predicate { $0.start < end }, sortBy: [SortDescriptor(\.start)])
      d.fetchLimit = 5000
      return (try? context.fetch(d)) ?? []
    }

    private func alarms() -> [OneAlarm] {
      var d = FetchDescriptor<OneAlarm>(sortBy: [SortDescriptor(\.hour), SortDescriptor(\.minute)])
      d.fetchLimit = 200
      return (try? context.fetch(d)) ?? []
    }

    private func lists() -> [OneList] {
      var d = FetchDescriptor<OneList>(sortBy: [SortDescriptor(\.order)])
      d.fetchLimit = 200
      return (try? context.fetch(d)) ?? []
    }

    private func entries(in interval: DateInterval, includeDone: Bool) -> [CalEntry] {
      CalendarEntries.make(
        in: interval, events: events(before: interval.end), tasks: tasks(includeDone: includeDone),
        alarms: alarms(), calendarService: calendar, now: now, calendar: cal)
    }

    // MARK: Short ids

    private func id(for model: some PersistentModel, prefix: String) -> String {
      let ref = Ledger.ref(model.persistentModelID).map(Ledger.comparisonKey) ?? UUID().uuidString
      return history.shortID(for: ref, prefix: prefix)
    }

    package func id(for task: OneTask) -> String { id(for: task, prefix: "t") }

    private func id(for entry: CalEntry) -> String {
      switch entry.source {
      case .task(let t): return id(for: t, prefix: "t")
      case .local(let e): return id(for: e, prefix: "e")
      case .alarm(let a): return id(for: a, prefix: "a")
      case .system(let identifier):
        return history.shortID(
          for: "sys:\(identifier)@\(Int(entry.start.timeIntervalSince1970))", prefix: "e")
      }
    }

    private enum Resolved {
      case task(OneTask)
      case event(OneEvent)
      case alarm(OneAlarm)
      case system(identifier: String, occurrence: Date)
    }

    private func resolve(_ shortID: String?) -> Resolved? {
      guard let shortID, let ref = history.ref(for: shortID.trimmingCharacters(in: .whitespaces))
      else { return nil }
      if ref.hasPrefix("sys:") {
        let body = ref.dropFirst(4)
        guard let at = body.lastIndex(of: "@"), let seconds = Double(body[body.index(after: at)...])
        else { return nil }
        return .system(
          identifier: String(body[..<at]), occurrence: Date(timeIntervalSince1970: seconds))
      }
      switch CaptureUndo.resolve(ref, in: context) {
      case .task(let t)?: return .task(t)
      case .event(let e)?: return .event(e)
      case .alarm(let a)?: return .alarm(a)
      case nil: return nil
      }
    }

    // MARK: Dates

    private static let stamp: DateFormatter = {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "EEE yyyy-MM-dd HH:mm"
      return f
    }()
    private static let dayStamp: DateFormatter = {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "EEE yyyy-MM-dd"
      return f
    }()

    private func stamp(_ date: Date?, allDay: Bool = false) -> JSONValue {
      guard let date else { return .null }
      let f = allDay ? Self.dayStamp : Self.stamp
      f.timeZone = cal.timeZone
      return .string(f.string(from: date))
    }

    /// A day (and maybe a time) from ISO 8601 or the user's words; nil when it can't be read.
    private func moment(_ words: String?) -> (date: Date, hasTime: Bool)? {
      guard let raw = words?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
      }
      for (format, hasTime) in [
        ("yyyy-MM-dd'T'HH:mm:ssXXXXX", true), ("yyyy-MM-dd'T'HH:mm:ss", true),
        ("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false),
      ] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = format
        if let d = f.date(from: raw) { return (d, hasTime) }
      }
      let parsed = CaptureParser.parse(raw, now: now, calendar: cal)
      guard parsed.hasDay || parsed.hour != nil else { return nil }
      let day = cal.startOfDay(for: parsed.hasDay ? parsed.day : now)
      if let hour = parsed.hour,
        let d = cal.date(bySettingHour: hour, minute: parsed.minute, second: 0, of: day)
      {
        return (d, true)
      }
      return (day, false)
    }

    private func range(_ start: String?, _ end: String?, default fallback: DateInterval)
      -> DateInterval?
    {
      guard start != nil || end != nil else { return fallback }
      guard let s = moment(start) ?? moment(end) else { return nil }
      let from = s.hasTime ? s.date : cal.startOfDay(for: s.date)
      var to = from
      if let e = moment(end) {
        to =
          e.hasTime
          ? e.date : (cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: e.date)) ?? e.date)
      }
      if to <= from {
        to = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: from)) ?? from
      }
      // At most two months per read.
      let cap = cal.date(byAdding: .day, value: 62, to: from) ?? to
      return DateInterval(start: from, end: min(to, cap))
    }

    private func kinds(_ value: JSONValue?) -> Set<String> {
      Set((value?.array ?? []).compactMap(\.string))
    }

    // MARK: Read tools

    private func describe(_ e: CalEntry) -> JSONValue {
      var o: [String: JSONValue] = [
        "id": .string(id(for: e)), "title": .string(e.title),
        "start": stamp(e.start, allDay: e.isAllDay),
      ]
      switch e.source {
      case .task(let t):
        o["kind"] = "reminder"
        o["done"] = .bool(t.isDone)
        if !t.listName.isEmpty { o["list"] = .string(t.listName) }
      case .alarm: o["kind"] = "alarm"
      case .local, .system:
        o["kind"] = "event"
        if e.isAllDay { o["all_day"] = true } else { o["end"] = stamp(e.end) }
        if e.repeats { o["repeats"] = true }
      }
      return .object(o)
    }

    private func describe(_ t: OneTask) -> JSONValue {
      var o: [String: JSONValue] = [
        "id": .string(id(for: t, prefix: "t")), "kind": "reminder", "title": .string(t.title),
        "due": stamp(t.due, allDay: !t.dueHasTime), "done": .bool(t.isDone),
      ]
      if !t.listName.isEmpty { o["list"] = .string(t.listName) }
      if t.flagged { o["flagged"] = true }
      if t.repeatRule != nil { o["repeats"] = true }
      return .object(o)
    }

    private func matches(_ kinds: Set<String>, _ kind: String) -> Bool {
      kinds.isEmpty || kinds.contains(kind)
    }

    private func agenda(_ a: JSONValue) -> AgentToolOutcome {
      let today = cal.startOfDay(for: now)
      guard
        let interval = range(
          a["start"]?.string, a["end"]?.string,
          default: DateInterval(start: today, duration: 86_400))
      else {
        return .error("unreadable_date", "Couldn't read that date range. Ask the user which day.")
      }
      let want = kinds(a["kinds"])
      var rows = entries(in: interval, includeDone: true).filter {
        switch $0.source {
        case .task: matches(want, "reminder")
        case .alarm: matches(want, "alarm")
        case .local, .system: matches(want, "event")
        }
      }.sorted { $0.start < $1.start }.map(describe)
      // Reminders due on a day without a time ("Anytime").
      if matches(want, "reminder") {
        rows += tasks(includeDone: true).filter {
          guard let due = $0.due, !$0.dueHasTime else { return false }
          return interval.contains(due)
        }.prefix(20).map(describe)
      }
      let total = rows.count
      return AgentToolOutcome([
        "range": [stamp(interval.start), stamp(interval.end)],
        "items": .array(Array(rows.prefix(40))), "total": .number(Double(total)),
      ])
    }

    private static func fold(_ s: String) -> String {
      s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        .replacingOccurrences(of: #"[\s\[\]【】"“”'‘’]+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }

    /// 2 = one contains the other; 1 = a shared word (or two Han characters); 0 = no match.
    private static func score(_ title: String, _ query: String) -> Int {
      let t = fold(title)
      let q = fold(query)
      guard !q.isEmpty, !t.isEmpty else { return 0 }
      if t.contains(q) || q.contains(t) { return 2 }
      let words = q.split(separator: " ").filter { $0.count >= 2 }
      if words.contains(where: { t.contains($0) }) { return 1 }
      let han = Array(
        q.filter { $0.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false })
      if han.count >= 2 {
        for i in 0..<(han.count - 1) where t.contains(String(han[i...i + 1])) { return 1 }
      }
      return 0
    }

    private static let log = Logger(subsystem: "com.luworks.one", category: "Agent")

    /// Finds by name. When the kinds the model asked for have no match, other kinds are offered
    /// (a "dentist appointment" may be a reminder, not an event).
    private func find(_ a: JSONValue) -> AgentToolOutcome {
      let first = search(a)
      guard first.total == 0, !kinds(a["kinds"]).isEmpty, case .object(var all) = a else {
        return AgentToolOutcome([
          "items": .array(first.items), "total": .number(Double(first.total)),
        ])
      }
      all["kinds"] = []
      let other = search(.object(all))
      var out: [String: JSONValue] = [
        "items": .array(other.items), "total": .number(Double(other.total)),
      ]
      if other.total > 0 {
        out["note"] = "Nothing of the requested kinds matched; these items of other kinds do."
      }
      return AgentToolOutcome(.object(out))
    }

    private func search(_ a: JSONValue) -> (items: [JSONValue], total: Int) {
      let query = a["query"]?.string ?? ""
      let want = kinds(a["kinds"])
      let includeDone = a["include_done"]?.bool ?? false
      let today = cal.startOfDay(for: now)
      let window =
        range(
          a["start"]?.string, a["end"]?.string,
          default: DateInterval(
            start: cal.date(byAdding: .day, value: -14, to: today) ?? today,
            end: cal.date(byAdding: .day, value: 60, to: today) ?? today))
        ?? DateInterval(start: today, duration: 86_400 * 60)
      var found: [(score: Int, distance: TimeInterval, value: JSONValue)] = []
      if matches(want, "reminder") {
        for t in tasks(includeDone: includeDone) {
          let s = Self.score(t.title, query)
          guard s > 0 else { continue }
          if let due = t.due, a["start"]?.string != nil || a["end"]?.string != nil,
            !window.contains(due)
          {
            continue
          }
          found.append((s, abs((t.due ?? now).timeIntervalSince(now)), describe(t)))
        }
      }
      if matches(want, "event") || matches(want, "alarm") {
        for e in entries(in: window, includeDone: false) {
          switch e.source {
          case .task: continue
          case .alarm: if !matches(want, "alarm") { continue }
          case .local, .system: if !matches(want, "event") { continue }
          }
          let s = Self.score(e.title, query)
          guard s > 0 else { continue }
          found.append((s, abs(e.start.timeIntervalSince(now)), describe(e)))
        }
      }
      // An alarm with no ring in the window is still findable by its label.
      if matches(want, "alarm") {
        for alarm in alarms() where Self.score(alarm.label, query) > 0 {
          let v: JSONValue = [
            "id": .string(id(for: alarm, prefix: "a")), "kind": "alarm",
            "title": .string(alarm.label),
            "time": .string(String(format: "%02d:%02d", alarm.hour, alarm.minute)),
            "on": .bool(alarm.isOn),
          ]
          if !found.contains(where: { $0.value["id"] == v["id"] }) {
            found.append((Self.score(alarm.label, query), 0, v))
          }
        }
      }
      found.sort { $0.score != $1.score ? $0.score > $1.score : $0.distance < $1.distance }
      // One item per id (a repeating event shows its nearest occurrence).
      var seen = Set<JSONValue>()
      let items = found.map(\.value).filter { seen.insert($0["id"] ?? .null).inserted }
      return (Array(items.prefix(10)), items.count)
    }

    private func item(_ a: JSONValue) -> AgentToolOutcome {
      switch resolve(a["id"]?.string) {
      case .task(let t)?:
        var o = describe(t)
        if case .object(var d) = o {
          if let rule = t.repeatRule { d["repeat"] = .string(rule) }
          if !t.note.isEmpty { d["note"] = .string(String(t.note.prefix(200))) }
          d["rings_as_alarm"] = .bool(t.ringsAsAlarm)
          o = .object(d)
        }
        return AgentToolOutcome(o)
      case .event(let e)?:
        let audience = calendar.audience(externalID: e.externalID)
        var o: [String: JSONValue] = [
          "id": .string(a["id"]?.string ?? ""), "kind": "event", "title": .string(e.title),
          "start": stamp(e.start, allDay: e.isAllDay),
          "minutes": .number(Double(e.durationMinutes)),
          "attendees": .number(Double(audience?.attendees ?? 0)),
          "calendar": .string(e.calendarName),
        ]
        if let rule = e.repeatRule { o["repeat"] = .string(rule) }
        if let loc = e.location, !loc.isEmpty { o["location"] = .string(String(loc.prefix(120))) }
        if let org = audience?.isOrganizer, (audience?.attendees ?? 0) > 0 {
          o["organizer"] = .bool(org)
        }
        return AgentToolOutcome(.object(o))
      case .alarm(let alarm)?:
        return AgentToolOutcome([
          "id": .string(a["id"]?.string ?? ""), "kind": "alarm", "title": .string(alarm.label),
          "time": .string(String(format: "%02d:%02d", alarm.hour, alarm.minute)),
          "repeat": .string(alarm.repeatValue), "on": .bool(alarm.isOn),
        ])
      case .system(let identifier, let occurrence)?:
        guard let e = calendar.cachedEvent(externalID: identifier, occurrence: occurrence) else {
          return .error("not_found", "That event is no longer in the calendar.")
        }
        let audience = calendar.audience(externalID: identifier)
        return AgentToolOutcome([
          "id": .string(a["id"]?.string ?? ""), "kind": "event", "title": .string(e.title),
          "start": stamp(e.start, allDay: e.isAllDay), "end": stamp(e.end),
          "attendees": .number(Double(audience?.attendees ?? 0)), "repeats": .bool(e.repeats),
          "calendar": .string(e.calendarTitle),
        ])
      case nil:
        return .error("unknown_id", "No item with that id. Call find_items first.")
      }
    }

    private func freeTime(_ a: JSONValue) -> AgentToolOutcome {
      guard let day = moment(a["day"]?.string)?.date else {
        return .error("unreadable_date", "Couldn't read that day. Ask the user which day.")
      }
      let start = cal.startOfDay(for: day)
      let interval = DateInterval(start: start, duration: 86_400)
      let busy = entries(in: interval, includeDone: false).filter {
        !$0.isAllDay && !$0.isBackground && !$0.isTask && !$0.isAlarm
      }.map { DateInterval(start: $0.start, end: max($0.end, $0.start)) }
      let minimum = max(5, a["min_minutes"]?.int ?? 30)
      let gaps = DaySchedule.freeGaps(
        busy: busy, day: start, now: now, minimum: minimum, calendar: cal)
      return AgentToolOutcome([
        "day": stamp(start, allDay: true),
        "free": .array(
          gaps.map {
            [
              "start": stamp($0.start), "end": stamp($0.end),
              "minutes": .number(Double(Int($0.duration / 60))),
            ]
          }),
      ])
    }

    private func listLists() -> AgentToolOutcome {
      var open: [String: Int] = [:]
      for t in tasks(includeDone: false) { open[t.listName, default: 0] += 1 }
      return AgentToolOutcome([
        "lists": .array(
          lists().map { ["name": .string($0.name), "open": .number(Double(open[$0.name] ?? 0))] })
      ])
    }

    private func activity(_ a: JSONValue) -> AgentToolOutcome {
      guard let store = ledger.activity.store else {
        return .error("not_available", "Activity data is off on this device.")
      }
      let today = cal.startOfDay(for: now)
      guard
        let interval = range(
          a["start"]?.string, a["end"]?.string,
          default: DateInterval(start: today, duration: 86_400))
      else { return .error("unreadable_date", "Couldn't read that period.") }
      let since = Int64(interval.start.timeIntervalSince1970 * 1000)
      let until = Int64(interval.end.timeIntervalSince1970 * 1000)
      let rows =
        ((try? store.page(ActivityQuery(tiers: [.changes], sinceMs: since), limit: 60)) ?? [])
        .filter { $0.ts < until }
      return AgentToolOutcome([
        "changes": .array(
          rows.prefix(30).map { r in
            [
              "ledger_id": .string(r.uid), "kind": .string(r.kind),
              "who": .string(LedgerActor(raw: r.actor).name),
              "item": .string(r.subjectKind ?? ""),
              "title": .string(String((r.title ?? "").prefix(80))),
              "at": stamp(Date(timeIntervalSince1970: Double(r.ts) / 1000)),
              "undone": .bool(r.undoOf != nil),
            ]
          })
      ])
    }

    // MARK: Write tools: cards only

    private func why(_ a: JSONValue) -> String? {
      a["why"]?.string.map { String($0.prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func listName(_ raw: String?) -> String? {
      guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
      let names = lists().map(\.name)
      return names.first { Self.fold($0) == Self.fold(raw) }
        ?? names.first { Self.score($0, raw) == 2 }
    }

    /// The capture a create item describes, or the reason it can't be prepared.
    private func capture(_ item: JSONValue, base: Capture? = nil) -> Result<
      Capture, AgentToolOutcome
    > {
      let kind =
        item["kind"]?.string
        ?? (base.map { $0.kind == .event ? "event" : ($0.ringsAsAlarm ? "alarm" : "reminder") }
          ?? "reminder")
      let title = (item["title"]?.string ?? base?.title ?? "").trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard !title.isEmpty else {
        return .failure(.error("missing_title", "Give the item a short title."))
      }
      var c = base ?? Capture(title: title, day: cal.startOfDay(for: now), hasDay: false)
      c.title = title
      c.kind = kind == "event" ? .event : .task
      if let words = item["when_text"]?.string, !words.trimmingCharacters(in: .whitespaces).isEmpty
      {
        guard let m = moment(words) else {
          return .failure(
            .error("unreadable_when", "Couldn't read “\(words)”. Ask the user for the day or time.")
          )
        }
        c.day = cal.startOfDay(for: m.date)
        c.hasDay = true
        c.hour = m.hasTime ? cal.component(.hour, from: m.date) : nil
        c.minute = m.hasTime ? cal.component(.minute, from: m.date) : 0
      }
      if let list = item["list"]?.string {
        guard let name = listName(list) else {
          return .failure(
            .error("unknown_list", "There's no list named “\(list)”. Call list_lists."))
        }
        c.listName = name
      }
      if let words = item["repeat"]?.string, !words.isEmpty {
        let parsed = CaptureParser.parse(words, now: now, calendar: cal)
        if ["never", "once", "不重复", "一次"].contains(words.lowercased()) {
          c.repeatRule = nil
        } else if let rule = parsed.repeatRule {
          c.repeatRule = rule
        } else {
          return .failure(.error("unreadable_repeat", "Couldn't read the repeat rule “\(words)”."))
        }
      }
      if kind == "alarm" || item["ring"]?.bool == true { c.ringsAsAlarm = true }
      if kind == "alarm" && c.hour == nil {
        return .failure(
          .error("missing_time", "An alarm needs a time. Ask the user when it should ring."))
      }
      if c.kind == .event, !c.hasDay {
        return .failure(.error("missing_day", "An event needs a day. Ask the user which day."))
      }
      if c.kind == .event, c.hour == nil {
        c.isAllDay = true
      } else if c.kind == .event {
        c.isAllDay = false
      }
      return .success(c)
    }

    private func parsed(_ c: Capture) -> JSONValue {
      var o: [String: JSONValue] = [
        "kind": .string(
          c.kind == .event
            ? "event"
            : (c.ringsAsAlarm && c.title.isEmpty
              ? "alarm" : (c.ringsAsAlarm ? "alarm" : "reminder"))),
        "title": .string(c.title),
        "day": c.hasDay ? stamp(c.day, allDay: true) : .null,
        "time": c.hour.map { .string(String(format: "%02d:%02d", $0, c.minute)) } ?? .null,
      ]
      if let list = c.listName { o["list"] = .string(list) }
      if let rule = c.repeatRule { o["repeat"] = .string(rule) }
      if c.kind == .event && c.hour == nil {
        o["note"] = "No time given: shown as all-day. Ask if a time is wanted."
      }
      return .object(o)
    }

    private func create(_ a: JSONValue) -> AgentToolOutcome {
      let items = a["items"]?.array ?? []
      guard !items.isEmpty else { return .error("no_items", "items is empty.") }
      var results: [JSONValue] = []
      var shown = 0
      for item in items.prefix(8) {
        switch capture(item) {
        case .failure(let error):
          results.append(JSONValue.parse(error.output) ?? .null)
        case .success(let c):
          let kind: ActionPolicy.Kind =
            c.kind == .event ? .event : (c.ringsAsAlarm ? .alarm : .reminder)
          var fields: Set<ActionPolicy.Field> = [.title]
          if c.hasDay { fields.insert(kind == .event ? .start : .due) }
          if c.repeatRule != nil { fields.insert(.repeatRule) }
          if c.ringsAsAlarm { fields.insert(.ringsAsAlarm) }
          let tier = ActionPolicy.tier(
            .init(
              tool: .proposeCreate, source: .agent, words: turn.words, kind: kind, fields: fields))
          if case .refuse(let reason) = tier {
            results.append(["error": "refused", "reason": .string(reason.rawValue)])
            continue
          }
          let key = [
            kind.rawValue, Self.fold(c.title), c.hasDay ? "\(c.day.timeIntervalSince1970)" : "",
            "\(c.hour ?? -1):\(c.minute)", c.listName ?? "", c.repeatRule ?? "",
          ].joined(separator: "|")
          let opened = book.open(
            tool: .proposeCreate, kind: kind.rawValue, tier: tier, run: turn.runID, contentKey: key)
          if !opened.duplicate {
            let card = AgentCard(
              id: opened.id, body: .create(c), tier: tier, why: why(item), chinese: turn.chinese)
            cards[opened.id] = card
            sink?.show(card)
            shown += 1
          }
          results.append([
            "proposal_id": .string(opened.id),
            "status": .string(opened.duplicate ? "already_shown" : "shown_to_user"),
            "parsed": parsed(c),
          ])
        }
      }
      return AgentToolOutcome(["results": .array(results)], cards: shown)
    }

    private func editItem(_ type: String, title: String, start: Date?, minutes: Int) -> EditItem {
      EditItem(id: "x", type: type, title: title, start: start, minutes: minutes, attendees: 0)
    }

    private func newStart(_ words: String, item: EditItem) -> Date? {
      Editing.newStart(for: item, text: words, now: now, calendar: cal)
        ?? moment(words).flatMap { $0.hasTime ? $0.date : nil }
    }

    private func label(_ date: Date?) -> String {
      date.map { plannerDayLabel($0, runtime: runtime) } ?? (turn.chinese ? "无日期" : "No date")
    }

    /// Builds the change a propose_edit / propose_delete describes, or why it can't.
    private func change(
      _ shortID: String, operation op: (Date?) -> Result<AgentChange.Operation, AgentToolOutcome>
    ) -> Result<AgentChange, AgentToolOutcome> {
      let asked = AgentRouting.userAskedToMove(turn.text)
      switch resolve(shortID) {
      case .task(let t)?:
        let operation: AgentChange.Operation
        switch op(t.due) {
        case .failure(let e): return .failure(e)
        case .success(let o): operation = o
        }
        return .success(
          AgentChange(
            target: .task(t), operation: operation, title: t.title, before: label(t.due),
            after: after(operation, title: t.title), attendees: 0, isOrganizer: true,
            expectedTask: Ledger.snapshot(of: t), baseStart: t.due, itemID: shortID,
            userAskedToMove: asked))
      case .event(let e)?:
        guard e.repeatRule == nil else {
          return .failure(
            .error(
              "repeating_event",
              "Repeating events can't be changed from chat yet. Tell the user to open it in Calendar."
            ))
        }
        let operation: AgentChange.Operation
        switch op(e.start) {
        case .failure(let err): return .failure(err)
        case .success(let o): operation = o
        }
        if case .rename = operation {
          return .failure(
            .error("not_supported", "Renaming events isn't supported. Open the event to rename it.")
          )
        }
        if operation == .done {
          return .failure(.error("not_supported", "Events can't be marked done."))
        }
        let audience = calendar.audience(externalID: e.externalID)
        let n = audience?.attendees ?? 0
        return .success(
          AgentChange(
            target: .event(e), operation: operation, title: e.title,
            before: label(e.start), after: after(operation, title: e.title), attendees: n,
            isOrganizer: audience?.isOrganizer ?? true,
            expectedEvent: ToolRegistry.snapshot(of: .event(e), attendees: n), baseStart: e.start,
            itemID: shortID, userAskedToMove: asked))
      case .system(let identifier, let occurrence)?:
        let operation: AgentChange.Operation
        switch op(occurrence) {
        case .failure(let err): return .failure(err)
        case .success(let o): operation = o
        }
        guard case .move = operation else {
          return .failure(
            .error(
              "not_supported",
              "Only moving an Apple Calendar event is supported here. Tell the user to open it in Calendar."
            ))
        }
        guard
          let snapshot = try? calendar.moveSnapshot(externalID: identifier, occurrence: occurrence)
        else {
          return .failure(
            .error("not_available", "This event can't be changed here. Open it in Calendar."))
        }
        return .success(
          AgentChange(
            target: .system(snapshot), operation: operation, title: snapshot.title,
            before: label(snapshot.start), after: after(operation, title: snapshot.title),
            attendees: snapshot.audience.attendeeCount,
            isOrganizer: snapshot.audience.isOrganizer ?? true, baseStart: snapshot.start,
            itemID: shortID, userAskedToMove: asked))
      case .alarm(let alarm)?:
        let next = cal.nextDate(
          after: now, matching: DateComponents(hour: alarm.hour, minute: alarm.minute),
          matchingPolicy: .nextTime)
        let operation: AgentChange.Operation
        switch op(next) {
        case .failure(let err): return .failure(err)
        case .success(let o): operation = o
        }
        if operation == .done {
          return .failure(
            .error(
              "not_supported",
              "Stopping an alarm is not finishing a task; alarms can't be marked done."))
        }
        return .success(
          AgentChange(
            target: .alarm(alarm), operation: operation, title: alarm.label,
            before: String(format: "%02d:%02d", alarm.hour, alarm.minute),
            after: after(operation, title: alarm.label), attendees: 0, isOrganizer: true,
            baseStart: next, itemID: shortID, userAskedToMove: asked))
      case nil:
        return .failure(.error("unknown_id", "No item with that id. Call find_items first."))
      }
    }

    private func after(_ op: AgentChange.Operation, title: String) -> String {
      switch op {
      case .move(let d): label(d)
      case .rename(let name): name
      case .done: turn.chinese ? "标为完成" : "Mark completed"
      case .delete: turn.chinese ? "删除" : "Delete"
      }
    }

    /// The single operation an edit's fields describe (one change per card).
    private func operation(_ a: JSONValue, kind: String, start: Date?, title: String)
      -> Result<AgentChange.Operation, AgentToolOutcome>
    {
      if let words = a["when_text"]?.string, !words.isEmpty {
        guard
          let date = newStart(
            words, item: editItem(kind, title: title, start: start, minutes: 60))
        else {
          return .failure(
            .error("unreadable_when", "Couldn't read “\(words)”. Ask the user for the new time."))
        }
        return .success(.move(date))
      }
      if let name = a["title"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
        return .success(.rename(name))
      }
      if a["done"]?.bool == true { return .success(.done) }
      if a["enabled"]?.bool != nil || a["list"]?.string != nil || a["repeat"]?.string != nil
        || a["done"]?.bool == false
      {
        return .failure(
          .error(
            "not_supported",
            "That change isn't supported from chat yet. Tell the user to open the item."))
      }
      return .failure(.error("no_change", "No field to change was given."))
    }

    private func show(_ change: AgentChange, why: String?) -> AgentToolOutcome {
      let tier = ActionPolicy.tier(change.request())
      if case .refuse(let reason) = tier {
        let hint =
          reason == .meetingsStayFixed
          ? "Meetings stay where they are unless the user explicitly asks to move this one."
          : "This change isn't allowed."
        return AgentToolOutcome([
          "error": "refused", "reason": .string(reason.rawValue), "message": .string(hint),
        ])
      }
      let opened = book.open(
        tool: change.isDelete ? .proposeDelete : .proposeEdit, kind: change.kind.rawValue,
        tier: tier, itemID: change.itemID, run: turn.runID)
      let card = AgentCard(
        id: opened.id, body: .change(change), tier: tier, why: why, chinese: turn.chinese)
      cards[opened.id] = card
      sink?.show(card)
      var out: [String: JSONValue] = [
        "proposal_id": .string(opened.id), "status": "shown_to_user",
        "before": .string(change.before), "after": .string(change.after),
      ]
      if !tier.allowsAddAll {
        out["needs_confirmation"] = .array(card.consequences.map(JSONValue.string))
      }
      return AgentToolOutcome(.object(out), cards: 1)
    }

    private func kindName(_ id: String) -> String {
      id.hasPrefix("e") ? "event" : (id.hasPrefix("a") ? "alarm" : "task")
    }

    private func edit(_ a: JSONValue) -> AgentToolOutcome {
      let shortID = a["id"]?.string ?? ""
      let result = change(shortID) { start in
        self.operation(a, kind: self.kindName(shortID), start: start, title: "")
      }
      switch result {
      case .failure(let e): return e
      case .success(let c): return show(c, why: why(a))
      }
    }

    private func delete(_ a: JSONValue) -> AgentToolOutcome {
      if a["scope"]?.string == "series" {
        return .error(
          "not_supported", "Deleting a whole series isn't supported from chat. Open it in Calendar."
        )
      }
      switch change(a["id"]?.string ?? "", operation: { _ in .success(.delete) }) {
      case .failure(let e): return e
      case .success(let c): return show(c, why: why(a))
      }
    }

    private func revise(_ a: JSONValue) -> AgentToolOutcome {
      let id = a["proposal_id"]?.string ?? ""
      switch book.revisable(id) {
      case .failure(.unknown):
        return .error("unknown_proposal", "No card with that id.")
      case .failure(.decided(let status, let item)):
        return AgentToolOutcome([
          "error": "proposal_decided", "status": .string(status.rawValue),
          "item_id": item.map(JSONValue.string) ?? .null,
          "message":
            "That card was already decided by the user. Use propose_edit with item_id instead.",
        ])
      case .success(let entry):
        guard var card = cards[entry.id] else {
          return .error("unknown_proposal", "No card with that id.")
        }
        switch card.body {
        case .create(let c):
          var fields = a
          if case .object(var o) = fields {
            o["kind"] = nil
            fields = .object(o)
          }
          switch capture(fields, base: c) {
          case .failure(let e): return e
          case .success(let revised):
            card.body = .create(revised)
            if let w = why(a) { card.why = w }
            cards[id] = card
            sink?.revise(card)
            return AgentToolOutcome(
              ["proposal_id": .string(id), "status": "revised", "parsed": parsed(revised)], cards: 1
            )
          }
        case .change(var change):
          switch operation(
            a, kind: kindName(change.itemID), start: change.baseStart, title: change.title)
          {
          case .failure(let e): return e
          case .success(let op):
            if change.isDelete != (op == .delete) {
              return .error("not_supported", "Make a new card for a different kind of change.")
            }
            change.operation = op
            change.after = after(op, title: change.title)
            let tier = ActionPolicy.tier(change.request())
            if case .refuse(let reason) = tier {
              return AgentToolOutcome(["error": "refused", "reason": .string(reason.rawValue)])
            }
            card.body = .change(change)
            card.tier = tier
            book.retier(id, tier)
            cards[id] = card
            sink?.revise(card)
            return AgentToolOutcome(
              [
                "proposal_id": .string(id), "status": "revised", "before": .string(change.before),
                "after": .string(change.after),
              ], cards: 1)
          }
        case .tidy:
          return .error("not_supported", "Change rows on the Tidy card directly.")
        }
      }
    }

    private func tidy(_ a: JSONValue) -> AgentToolOutcome {
      let start = cal.startOfDay(for: now)
      var overdue = tasks(includeDone: false).filter { ($0.due ?? .distantFuture) < start }
      if let ids = a["ids"]?.array?.compactMap(\.string), !ids.isEmpty {
        let wanted: [OneTask] = ids.compactMap {
          if case .task(let t)? = resolve($0) { return t }
          return nil
        }
        overdue = overdue.filter { t in wanted.contains { $0 === t } }
      }
      guard !overdue.isEmpty else {
        return AgentToolOutcome(["status": "nothing_overdue"])
      }
      overdue = Array(overdue.prefix(50))
      let items = overdue.enumerated().compactMap { i, t in
        t.due.map {
          OverdueTidy.Item(id: i, due: $0, flagged: t.flagged, repeats: t.repeats != nil)
        }
      }
      let rows = OverdueTidy.suggest(items, now: now, calendar: cal).compactMap { s in
        overdue[s.id].due.map {
          TidyProposal.Row(task: overdue[s.id], expectedDue: $0, choice: s.choice)
        }
      }
      let opened = book.open(tool: .proposeTidy, kind: "reminder", tier: .preview, run: turn.runID)
      let card = AgentCard(
        id: opened.id, body: .tidy(rows), tier: .preview, why: why(a), chinese: turn.chinese)
      cards[opened.id] = card
      sink?.show(card)
      return AgentToolOutcome(
        [
          "proposal_id": .string(opened.id), "status": "shown_to_user",
          "rows": .number(Double(rows.count)),
        ],
        cards: 1)
    }

    // MARK: Card decisions (from the screen)

    /// Records what the user did with a card, so the model can read it back (revise, receipts).
    package func mark(_ id: String, _ status: AgentProposalBook.Status, created ref: String? = nil)
    {
      var itemID: String?
      if let ref, let key = Optional(Ledger.comparisonKey(ref)) {
        let prefix = ref.contains("OneEvent") ? "e" : (ref.contains("OneAlarm") ? "a" : "t")
        itemID = history.shortID(for: key, prefix: prefix)
      }
      book.set(id, status: status, itemID: itemID)
    }

    /// One line per decided card, for compacted history.
    package var receipts: [String] {
      book.entries.filter(\.status.isDecided).map {
        "\($0.id) \($0.kind) \($0.status.rawValue)" + ($0.itemID.map { " item \($0)" } ?? "")
      }
    }

    // MARK: Apply (the code-owned write)

    /// Writes a change card after re-checking the item and the tier (§4.2). Nothing else writes.
    package func apply(_ id: String) async -> AgentApplyOutcome {
      guard let card = cards[id], case .change(let change) = card.body,
        book.entry(id)?.status == .open
      else { return AgentApplyOutcome(kind: .failed, message: nil) }
      let zh = card.chinese
      let stale =
        zh
        ? "这个条目在预览之后变了，卡片已作废。需要的话请重新说一次。"
        : "This item changed since the preview, so the card is void. Ask again for a current one."
      // Live facts, then the policy again.
      var live = change.attendees
      var changed = false
      switch change.target {
      case .task(let t):
        changed =
          t.isDeleted || t.modelContext == nil || change.expectedTask != Ledger.snapshot(of: t)
      case .event(let e):
        if e.isDeleted || e.modelContext == nil {
          changed = true
        } else {
          live = calendar.audience(externalID: e.externalID)?.attendees ?? 0
          changed =
            change.expectedEvent.map {
              $0 != ToolRegistry.snapshot(of: .event(e), attendees: $0.attendees)
            } ?? false
        }
      case .system(let s):
        if let now = try? calendar.moveSnapshot(externalID: s.externalID, occurrence: s.occurrence)
        {
          live = now.audience.attendeeCount
          changed = now.lastModified != s.lastModified || now.start != s.start
        } else {
          changed = true
        }
      case .alarm(let a):
        changed = a.isDeleted || a.modelContext == nil
      }
      switch ActionPolicy.recheck(
        shown: card.tier, now: change.request(attendees: live, changed: changed))
      {
      case .void:
        book.set(id, status: .void)
        return AgentApplyOutcome(kind: .void, message: stale)
      case .reconfirm(let tier):
        var c = card
        c.tier = tier
        if case .change(var ch) = c.body {
          ch.attendees = live
          c.body = .change(ch)
        }
        cards[id] = c
        book.retier(id, tier)
        return AgentApplyOutcome(
          kind: .reconfirm(tier),
          message: zh
            ? "情况有变：" + c.consequences.joined(separator: "，") + "。确认后再点一次。"
            : "Something changed: " + c.consequences.joined(separator: ", ")
              + ". Tap again to confirm.")
      case .apply: break
      }
      let outcome = await write(change, chinese: zh)
      if outcome.kind == .applied { book.set(id, status: .applied) }
      if outcome.kind == .void { book.set(id, status: .void) }
      return outcome
    }

    private func write(_ change: AgentChange, chinese zh: Bool) async -> AgentApplyOutcome {
      switch change.target {
      case .task(let task):
        guard let expected = change.expectedTask else { return AgentApplyOutcome(kind: .failed) }
        let op: AttachedItemEdit.Operation
        switch change.operation {
        case .move(let d): op = .move(d)
        case .rename(let n): op = .rename(n)
        case .done: op = .done
        case .delete: op = .delete
        }
        do {
          let receipt = try actions.applyAttachedReminder(
            op, task: task, expected: expected, context: context)
          return AgentApplyOutcome(
            kind: .applied, message: nil,
            undo: {
              do {
                try receipt.undo()
                return nil
              } catch { return error.localizedDescription }
            })
        } catch AttachedReminderActions.Failure.changed {
          return AgentApplyOutcome(
            kind: .void,
            message: zh
              ? "这个提醒在预览之后变了，卡片已作废。需要的话请重新说一次。"
              : "This reminder changed since the preview, so the card is void. Ask again for a current one."
          )
        } catch {
          return AgentApplyOutcome(kind: .failed, message: error.localizedDescription)
        }
      case .event(let event):
        let edit: ChangeProposal.Edit
        switch change.operation {
        case .move(let d): edit = .move(d)
        case .delete: edit = .delete
        default: return AgentApplyOutcome(kind: .failed)
        }
        let result = ToolRegistry.apply(
          ChangeProposal(
            target: .event(event), edit: edit, oldText: change.before, attendees: change.attendees,
            expected: change.expectedEvent),
          context: context, calendar: calendar, actions: actions, ledger: ledger)
        // Undo of a calendar write is checked, not assumed: the card says Undone only if the event is back.
        let title = change.title
        let old = change.baseStart
        let context = self.context
        return outcome(result) {
          switch change.operation {
          case .move:
            return !event.isDeleted && event.modelContext != nil && event.start == old
          default:
            guard let old else { return false }
            var d = FetchDescriptor<OneEvent>(
              predicate: #Predicate { $0.title == title && $0.start == old })
            d.fetchLimit = 1
            return ((try? context.fetchCount(d)) ?? 0) > 0
          }
        }
      case .system(let snapshot):
        guard case .move(let start) = change.operation else {
          return AgentApplyOutcome(kind: .failed)
        }
        let result = ToolRegistry.apply(
          SystemMoveProposal(expected: snapshot, start: start), context: context,
          calendar: calendar, ledger: ledger, report: { _ in })
        return outcome(result.result)
      case .alarm(let alarm):
        let edit: AttachedAlarmChange.Edit
        switch change.operation {
        case .move(let d): edit = .move(d)
        case .rename(let n): edit = .rename(n)
        case .delete: edit = .delete
        case .done: return AgentApplyOutcome(kind: .failed)
        }
        do {
          let proposal = try AttachedAlarmChange(alarm: alarm, edit: edit)
          let entry = try await actions.applyAttachedAlarm(proposal, context: context)
          let actions = self.actions
          let context = self.context
          return AgentApplyOutcome(
            kind: .applied, message: nil,
            undo: { await actions.undo(entry, context: context) })
        } catch {
          return AgentApplyOutcome(kind: .failed, message: error.localizedDescription)
        }
      }
    }

    private func outcome(_ result: WriteResult, verify: (() -> Bool)? = nil) -> AgentApplyOutcome {
      guard result.applied else {
        let stale = result.replies.contains { $0.contains("changed since the preview") }
        return AgentApplyOutcome(kind: stale ? .void : .failed, message: result.replies.last)
      }
      let undo = result.undo
      return AgentApplyOutcome(
        kind: .applied, message: nil,
        undo: undo.map { u in
          {
            u.run()
            if let verify, !verify() {
              return "Undo didn't go through, so the change stays. Open Calendar to check it."
            }
            return nil
          }
        })
    }
  }
#endif
