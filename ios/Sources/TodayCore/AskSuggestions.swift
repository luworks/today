import Foundation

// What the Ask AI page suggests when it is empty. Not a fixed list: the suggestions are guesses about what you want
// right now, made from your own plans (today's events and free time, overdue and flagged reminders, the next meeting,
// the evening, your past reminders and your last chats). Foundation only, so it runs under `swift test`.
//
// Layers:
//  1. `SuggestionContext`  a plain snapshot of what the app knows (the app target fills it in from SwiftData / EventKit).
//  2. `SuggestionRules`    deterministic candidates, each with a score and the exact sentence a tap sends. A candidate is
//                          kept only when that sentence really lands on something the app can do (`SentenceRoute`).
//  3. `SuggestionBlend`    optional: the on-device model re-ranks and rewords the candidates (AskSuggestionRanker.swift);
//                          its wording is kept only when it still lands on the same thing.
// Nothing here writes anything. A tap sends the sentence like typed text; the usual preview cards do the rest.

// MARK: - Language

public enum SuggestionLanguage: String, Sendable {
  case en, zh

  /// More Chinese characters than Latin letters.
  static func isChinese(_ text: String) -> Bool {
    var cjk = 0
    var latin = 0
    for u in text.unicodeScalars {
      if (0x4E00...0x9FFF).contains(u.value) {
        cjk += 1
      } else if (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value) {
        latin += 1
      }
    }
    return cjk > latin
  }

  /// The language you write in: your latest messages when there are any, else the system language.
  /// `recentUserTexts` is newest first; the last four count.
  static func detect(recentUserTexts: [String], systemIsChinese: Bool) -> SuggestionLanguage {
    let texts = recentUserTexts.prefix(4).filter {
      !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }
    guard !texts.isEmpty else { return systemIsChinese ? .zh : .en }
    let zh = texts.filter(isChinese).count
    return zh * 2 > texts.count ? .zh : .en
  }
}

// MARK: - Routing mirror

/// Where a sentence goes when it is sent from the Ask page, in the order `AskView.send` tries: tidy,
/// question, edit of an existing item, else a new item. Pure, so a suggestion can be checked before it is shown.
public enum SentenceRoute: Equatable {
  case tidy, question
  case edit(EditDecision)
  case attachedEdit(AttachedItemEdit)
  case capture(Capture)

  private static func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// The words that make an alarm (`FastLane.asksForAlarm`).
  public static func asksForAlarm(_ text: String) -> Bool { FastLane.asksForAlarm(text) }

  public static func route(
    _ raw: String, items: [EditItem], now: Date, calendar: Calendar = .current,
    attachedItemID: String? = nil
  ) -> SentenceRoute {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if OverdueTidy.isRequest(text) { return .tidy }
    if Editing.isQuestion(text) { return .question }
    if attachedItemID != nil,
      let edit = AttachedItemEditing.parse(
        text, attachedItemID: attachedItemID, items: items, now: now, calendar: calendar)
    {
      return .attachedEdit(edit)
    }
    if Editing.looksLikeEdit(text, items: items, now: now, calendar: calendar) {
      let d = Editing.decide(text: text, plan: nil, items: items, now: now, calendar: calendar)
      if d.op != .none { return .edit(d) }
    }
    return .capture(CaptureParser.parse(text, now: now, calendar: calendar))
  }

  /// Lands on something the app can do right away: an answer, a preview card, a resolved change or a new item with a day or time.
  /// A "which one?" question or "when?" question is not enough for a suggestion, because the point is one tap.
  public var isActionable: Bool {
    switch self {
    case .tidy, .question: return true
    case .attachedEdit: return false  // Requires an app-side preview integration.
    case .edit(let d):
      return (d.op == .move && d.target != nil && d.newStart != nil)
        || (d.op == .delete && d.target != nil)
    case .capture(let c):
      return !c.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (c.hasDay || c.hour != nil)
    }
  }

  /// Something the user could tap again and get a different card from: a model-invented suggestion may be one of these.
  public var isNewItemOrMove: Bool {
    switch self {
    case .capture: return isActionable
    case .edit(let d): return d.op == .move && isActionable
    case .question: return true
    default: return false
    }
  }

  /// Same thing in the sense of "do not suggest it twice".
  public var family: String {
    switch self {
    case .tidy: return "tidy"
    case .attachedEdit(let edit): return "edit:" + (edit.target ?? "?")
    case .question: return "question"
    case .edit(let d): return "edit:" + (d.target ?? "?")
    case .capture(let c): return "capture:" + c.title.lowercased()
    }
  }
}

/// What a candidate's sentence must land on. Checked against `SentenceRoute`, for the rule sentence and for any rewording.
public enum SuggestionExpectation: Equatable, Sendable {
  case tidy, question
  /// Move this item (by title) to this time.
  case move(title: String, to: Date)
  /// A new reminder at this time of day (not an alarm), `day` days from today.
  case reminder(hour: Int, minute: Int, day: Int)
  /// A new alarm at this time of day, `day` days from today.
  case alarm(hour: Int, minute: Int, day: Int)

  public func matches(
    _ route: SentenceRoute, text: String, items: [EditItem], now: Date,
    calendar: Calendar = .current
  ) -> Bool {
    guard route.isActionable else { return false }
    switch (self, route) {
    case (.tidy, .tidy), (.question, .question): return true
    case (.move(let title, let to), .edit(let d)):
      guard d.op == .move, let new = d.newStart, let id = d.target,
        items.first(where: { $0.id == id })?.title == title
      else { return false }
      return abs(new.timeIntervalSince(to)) < 60
    case (.reminder(let h, let m, let day), .capture(let c)):
      return c.hour == h && c.minute == m && Self.dayOffset(c, calendar: calendar, now: now) == day
        && !SentenceRoute.asksForAlarm(text)
    case (.alarm(let h, let m, let day), .capture(let c)):
      return c.hour == h && c.minute == m && Self.dayOffset(c, calendar: calendar, now: now) == day
        && SentenceRoute.asksForAlarm(text)
    default: return false
    }
  }
}

extension SuggestionExpectation {
  /// Days from today the capture is for (a time with no day is today).
  fileprivate static func dayOffset(_ c: Capture, calendar: Calendar, now: Date) -> Int {
    guard c.hasDay else { return 0 }
    return calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: c.day)
    ).day ?? 0
  }
}

// MARK: - Snapshot

/// Everything the rules look at. Plain values, so tests can build any day.
public struct SuggestionContext: Equatable {
  public struct Event: Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var location = ""
    /// Minutes of travel, when a lookup is cached. nil = unknown.
    public var travelMinutes: Int? = nil
    public var attendees = 0
    public var repeats = false

    public init(
      title: String, start: Date, end: Date, location: String = "", travelMinutes: Int? = nil,
      attendees: Int = 0, repeats: Bool = false
    ) {
      self.title = title
      self.start = start
      self.end = end
      self.location = location
      self.travelMinutes = travelMinutes
      self.attendees = attendees
      self.repeats = repeats
    }
  }

  public struct Task: Equatable {
    public var title: String
    public var due: Date? = nil
    public var minutes = 25
    public var flagged = false
    public var repeats = false
    public var ringsAsAlarm = false
    public var isDone = false
    public var doneAt: Date? = nil

    public init(
      title: String, due: Date? = nil, minutes: Int = 25,
      flagged: Bool = false, repeats: Bool = false, ringsAsAlarm: Bool = false,
      isDone: Bool = false, doneAt: Date? = nil
    ) {
      self.title = title
      self.due = due
      self.minutes = minutes
      self.flagged = flagged
      self.repeats = repeats
      self.ringsAsAlarm = ringsAsAlarm
      self.isDone = isDone
      self.doneAt = doneAt
    }
  }

  /// One recent conversation: when it last changed and what the user typed in it (newest first).
  public struct Chat: Equatable {
    public var title: String
    public var userTexts: [String]
    public var at: Date

    public init(title: String, userTexts: [String], at: Date) {
      self.title = title
      self.userTexts = userTexts
      self.at = at
    }
  }

  public var now: Date
  public var systemIsChinese = false
  /// Today's timed events, past and future, from every calendar shown.
  public var events: [Event] = []
  public var tomorrowFirst: Event? = nil
  /// Open reminders that matter now (overdue, due or planned today or tomorrow, flagged) and what was done today.
  public var tasks: [Task] = []
  /// Alarm fire times in the next 36 hours (Alarms tab and reminders that ring).
  public var alarms: [Date] = []
  /// The time the user sets alarms for most (`AlarmQuickPicks.usualTime`): the morning alarm the fallback offers.
  public var usualAlarm = AlarmQuickPicks.Time(hour: 7, minute: 0)
  /// Newest first.
  public var chats: [Chat] = []
  /// Reminders you tend to add around now (`ReminderSuggest`).
  public var habits: [ReminderSuggest.Suggestion] = []
  /// The items an edit sentence can name (same list the Ask page uses).
  public var editItems: [EditItem] = []

  // MARK: Derived

  func startOfToday(_ cal: Calendar) -> Date { cal.startOfDay(for: now) }

  public func hour(_ cal: Calendar = .current) -> Double {
    Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60
  }

  public func overdue(_ cal: Calendar = .current) -> [Task] {
    let today = startOfToday(cal)
    return tasks.filter { !$0.isDone && ($0.due.map { $0 < today } ?? false) }
  }

  /// Still open for today: due today and not overdue.
  func leftToday(_ cal: Calendar = .current) -> [Task] {
    tasks.filter { t in
      guard !t.isDone else { return false }
      if let due = t.due, due < startOfToday(cal) { return false }
      return t.due.map { cal.isDate($0, inSameDayAs: now) } ?? false
    }
  }

  func doneToday(_ cal: Calendar = .current) -> Int {
    tasks.filter { $0.isDone && ($0.doneAt.map { cal.isDate($0, inSameDayAs: now) } ?? false) }
      .count
  }

  func upcomingEvents() -> [Event] {
    events.filter { $0.start > now }.sorted { $0.start < $1.start }
  }

  public func busy(_ cal: Calendar = .current) -> [DateInterval] {
    var out = events.filter { $0.end > $0.start }.map { DateInterval(start: $0.start, end: $0.end) }
    for t in tasks where !t.isDone {
      if let s = t.due, cal.isDate(s, inSameDayAs: now),
        cal.dateComponents([.hour, .minute], from: s) != DateComponents(hour: 0, minute: 0)
      {
        out.append(DateInterval(start: s, duration: TimeInterval(max(t.minutes, 5) * 60)))
      }
    }
    return out
  }

  public func freeGaps(_ cal: Calendar = .current) -> [DateInterval] {
    DaySchedule.freeGaps(busy: busy(cal), day: now, now: now, minimum: 30, calendar: cal)
  }

  func freeMinutes(_ cal: Calendar = .current) -> Int {
    Int(freeGaps(cal).reduce(0) { $0 + $1.duration } / 60)
  }

  /// Language of the text: what you write in, else the system language.
  public var language: SuggestionLanguage {
    SuggestionLanguage.detect(
      recentUserTexts: chats.flatMap { Array($0.userTexts.prefix(1)) },
      systemIsChinese: systemIsChinese)
  }

  public init(
    now: Date, systemIsChinese: Bool = false, events: [Event] = [], tomorrowFirst: Event? = nil,
    tasks: [Task] = [], alarms: [Date] = [], chats: [Chat] = [],
    habits: [ReminderSuggest.Suggestion] = [], editItems: [EditItem] = []
  ) {
    self.now = now
    self.systemIsChinese = systemIsChinese
    self.events = events
    self.tomorrowFirst = tomorrowFirst
    self.tasks = tasks
    self.alarms = alarms
    self.chats = chats
    self.habits = habits
    self.editItems = editItems
  }
}

// MARK: - Candidates

public struct SuggestionCandidate: Equatable, Identifiable, Sendable {
  public enum Kind: String, Sendable {
    case tidy, whatsLeft, moveEvent, habit, prepare, leave, wake,
      fallbackReminder
  }

  public var id: String
  public var kind: Kind
  /// The whole sentence a tap sends.
  public var text: String
  public var score: Double
  public var expectation: SuggestionExpectation
  /// Why this fits right now, in English, for the model's prompt.
  public var why: String

  public init(
    id: String, kind: Kind, text: String, score: Double, expectation: SuggestionExpectation,
    why: String
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.score = score
    self.expectation = expectation
    self.why = why
  }
}

/// One chip on the page: what it says is what a tap sends.
public struct AskSuggestion: Equatable, Identifiable {
  public var id: String
  public var text: String

  public init(id: String, text: String) {
    self.id = id
    self.text = text
  }
}

public enum SuggestionRules {
  // MARK: Wording

  /// "3pm", "3:35pm" (English) or "15:35" (Chinese).
  public static func clock(_ date: Date, _ lang: SuggestionLanguage, _ cal: Calendar = .current)
    -> String
  {
    let c = cal.dateComponents([.hour, .minute], from: date)
    let h = c.hour ?? 0
    let m = c.minute ?? 0
    if lang == .zh { return String(format: "%d:%02d", h, m) }
    let h12 = h % 12 == 0 ? 12 : h % 12
    let ampm = h < 12 ? "am" : "pm"
    return m == 0 ? "\(h12)\(ampm)" : "\(h12):" + String(format: "%02d", m) + ampm
  }

  /// Rounded up to the next 5 minutes.
  static func roundUp5(_ d: Date, _ cal: Calendar = .current) -> Date {
    let m = cal.component(.minute, from: d)
    let s = cal.component(.second, from: d)
    let base = cal.date(bySetting: .second, value: 0, of: d) ?? d
    let add = (5 - m % 5) % 5
    return add == 0 && s == 0 ? d : base.addingTimeInterval(TimeInterval((add == 0 ? 5 : add) * 60))
  }

  /// Daily rituals need no preparation reminder.
  private static let noPrep = #"stand-?up|站会|早会"#
  private static let meetingCue =
    #"meeting|review|sync|1:1|interview|presentation|demo|workshop|standup|stand-up|call with|会议|评审|面试|周会|例会|站会|汇报|演示"#

  // MARK: Generation

  /// Every candidate whose sentence lands on what it promises, best first. Always has the safe fallbacks, so it is never empty.
  public static func candidates(_ ctx: SuggestionContext, calendar cal: Calendar = .current)
    -> [SuggestionCandidate]
  {
    let lang = ctx.language
    let zh = lang == .zh
    let h = ctx.hour(cal)
    var out: [SuggestionCandidate] = []

    // Tidy overdue.
    let overdue = ctx.overdue(cal)
    if !overdue.isEmpty {
      let n = overdue.count
      var s = 40 + Double(min(n, 6)) * 5
      if overdue.contains(where: \.flagged) { s += 8 }
      if h < 12 { s += 5 }
      out.append(
        .init(
          id: "tidy", kind: .tidy, text: zh ? "整理\(n)条过期提醒" : "Tidy \(n) overdue", score: s,
          expectation: .tidy,
          why: "\(n) overdue reminder\(n == 1 ? "" : "s")"))
    }

    // What's left today.
    let left = ctx.leftToday(cal)
    let upcomingToday = ctx.upcomingEvents().count
    let remaining = left.count + upcomingToday
    let leftScore: Double =
      remaining == 0
      ? 20 : 38 + min(Double(remaining), 6) * 2 + (h >= 12 ? 4 : 0)
    out.append(
      .init(
        id: "left", kind: .whatsLeft, text: zh ? "今天还剩什么？" : "What's left today?", score: leftScore,
        expectation: .question,
        why: remaining == 0
          ? "Nothing is left today"
          : "\(left.count) reminders and \(upcomingToday) events still ahead today"))

    // Two events overlap: offer to move the later, non-repeating one right after the other.
    let events = ctx.events.sorted { $0.start < $1.start }
    outer: for (i, a) in events.enumerated() {
      for b in events.dropFirst(i + 1)
      where b.start < a.end && b.end > a.start && b.start > ctx.now && !b.repeats {
        let slot = roundUp5(a.end.addingTimeInterval(300), cal)
        let end = slot.addingTimeInterval(b.end.timeIntervalSince(b.start))
        guard
          let close = cal.date(
            bySettingHour: DaySchedule.closeHour, minute: 0, second: 0, of: ctx.now), end <= close,
          !events.contains(where: { $0 != b && $0.start < end && $0.end > slot })
        else { continue }
        out.append(
          .init(
            id: "moveEvent:" + b.title, kind: .moveEvent,
            text: zh
              ? "把\(b.title)改到\(clock(slot, lang, cal))"
              : "Move \(b.title) to \(clock(slot, lang, cal))",
            score: 78, expectation: .move(title: b.title, to: slot),
            why: "\(b.title) overlaps \(a.title); it could start at \(clock(slot, .en, cal))"))
        break outer
      }
    }

    // The usual reminder for this time of day, from your own past reminders.
    for (i, habit) in ctx.habits.enumerated() {
      guard let when = habit.when else { continue }
      let c = cal.dateComponents([.hour, .minute], from: when)
      guard let hh = c.hour, let mm = c.minute else { continue }
      let tomorrow = !cal.isDate(when, inSameDayAs: ctx.now)
      let soon = when.timeIntervalSince(ctx.now) < 3 * 3600
      let time = clock(when, lang, cal)
      let text: String
      if zh {
        text = (tomorrow ? "明天" : "") + "\(time)提醒我\(habit.title)"
      } else {
        text = "Remind me to \(habit.title) " + (tomorrow ? "tomorrow at " : "at ") + time
      }
      out.append(
        .init(
          id: "habit:" + habit.title, kind: .habit, text: text,
          score: 52 - Double(i) * 4 + (soon ? 10 : 0) - (tomorrow ? 12 : 0),
          expectation: .reminder(hour: hh, minute: mm, day: tomorrow ? 1 : 0),
          why:
            "You often add \"\(habit.title)\" around this time (usually \(clock(when, .en, cal)))"))
      break
    }

    // The next meeting: a reminder to prepare, half an hour before.
    if let next = ctx.upcomingEvents().first(where: {
      ($0.attendees > 0
        || $0.title.range(of: meetingCue, options: [.regularExpression, .caseInsensitive]) != nil)
        && $0.title.range(of: noPrep, options: [.regularExpression, .caseInsensitive]) == nil
    }),
      next.start.timeIntervalSince(ctx.now) <= 4 * 3600
    {
      let at = roundUp5(next.start.addingTimeInterval(-1800), cal)
      if at > ctx.now.addingTimeInterval(1200) {
        let c = cal.dateComponents([.hour, .minute], from: at)
        let soon = next.start.timeIntervalSince(ctx.now) < 2 * 3600
        out.append(
          .init(
            id: "prepare:" + next.title, kind: .prepare,
            text: zh
              ? "\(clock(at, lang, cal))提醒我准备\(next.title)"
              : "Remind me to prepare for \(next.title) at \(clock(at, lang, cal))",
            score: 62 + (soon ? 8 : 0),
            expectation: .reminder(hour: c.hour ?? 0, minute: c.minute ?? 0, day: 0),
            why:
              "\(next.title) starts at \(clock(next.start, .en, cal)); a reminder 30 minutes before to prepare"
          ))
      }
    }

    // Leave on time for the next event with a place and a known travel time.
    if let next = ctx.upcomingEvents().first(where: {
      !$0.location.isEmpty && $0.travelMinutes != nil
    }), let travel = next.travelMinutes {
      let leave = roundUp5(next.start.addingTimeInterval(-TimeInterval((travel + 5) * 60)), cal)
      if leave > ctx.now.addingTimeInterval(300), leave.timeIntervalSince(ctx.now) <= 3 * 3600 {
        let c = cal.dateComponents([.hour, .minute], from: leave)
        out.append(
          .init(
            id: "leave:" + next.title, kind: .leave,
            text: zh
              ? "\(clock(leave, lang, cal))提醒我出发去\(next.title)"
              : "Remind me to leave for \(next.title) at \(clock(leave, lang, cal))",
            score: 82, expectation: .reminder(hour: c.hour ?? 0, minute: c.minute ?? 0, day: 0),
            why:
              "\(next.title) is at \(next.location), \(travel) min away, starts \(clock(next.start, .en, cal))"
          ))
      }
    }

    // Tonight: an alarm before an early start tomorrow, unless one already rings.
    if h >= 19.5, let first = ctx.tomorrowFirst {
      let tomorrow = cal.date(byAdding: .day, value: 1, to: ctx.startOfToday(cal)) ?? ctx.now
      let early = cal.date(bySettingHour: 10, minute: 30, second: 0, of: tomorrow) ?? first.start
      let morningAlarm = ctx.alarms.contains {
        cal.isDate($0, inSameDayAs: tomorrow) && $0 < first.start.addingTimeInterval(-1800)
      }
      if first.start <= early, !morningAlarm {
        let raw = first.start.addingTimeInterval(-5400)
        let c = cal.dateComponents([.hour, .minute], from: raw)
        let mins = ((c.hour ?? 7) * 60 + (c.minute ?? 0)) / 30 * 30
        let hh = max(5, mins / 60)
        let mm = mins % 60
        let probe = cal.date(bySettingHour: hh, minute: mm, second: 0, of: tomorrow) ?? raw
        out.append(
          .init(
            id: "wake", kind: .wake,
            text: zh
              ? "明天\(clock(probe, lang, cal))叫我起床"
              : "Wake me at \(clock(probe, lang, cal)) tomorrow",
            score: h >= 20 ? 72 : 55, expectation: .alarm(hour: hh, minute: mm, day: 1),
            why:
              "\(first.title) starts tomorrow at \(clock(first.start, .en, cal)) and no alarm is set before it"
          ))
      }
    }

    // Safe fallbacks: they route and ask for nothing from your data, so there are always at least two suggestions.
    if h < 16.5 {
      out.append(
        .init(
          id: "fallback:reminder", kind: .fallbackReminder,
          text: zh ? "17:30提醒我收尾" : "Remind me to wrap up at 5:30pm", score: 15,
          expectation: .reminder(hour: 17, minute: 30, day: 0),
          why: "A reminder to close out the day"))
    } else {
      out.append(
        .init(
          id: "fallback:reminder", kind: .fallbackReminder,
          text: zh ? "明天9:00提醒我看一眼日程" : "Remind me to check my calendar tomorrow at 9am", score: 15,
          expectation: .reminder(hour: 9, minute: 0, day: 1), why: "A reminder to look at the day"))
    }
    if h >= 17 {
      let usual = ctx.usualAlarm
      let tomorrow = cal.date(byAdding: .day, value: 1, to: ctx.startOfToday(cal)) ?? ctx.now
      let at =
        cal.date(bySettingHour: usual.hour, minute: usual.minute, second: 0, of: tomorrow)
        ?? tomorrow
      out.append(
        .init(
          id: "fallback:wake", kind: .wake,
          text: zh
            ? "明天\(clock(at, lang, cal))叫我起床" : "Wake me at \(clock(at, lang, cal)) tomorrow",
          score: h >= 20 ? 18 : 14,
          expectation: .alarm(hour: usual.hour, minute: usual.minute, day: 1),
          why: "Your usual alarm time"))
    }

    // Keep only what lands on what it promises (the tap would otherwise make a wrong card).
    let valid = out.filter { c in
      c.expectation.matches(
        SentenceRoute.route(c.text, items: ctx.editItems, now: ctx.now, calendar: cal),
        text: c.text, items: ctx.editItems, now: ctx.now, calendar: cal)
    }
    return penalized(valid, ctx, cal).sorted {
      $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score
    }
  }

  /// A suggestion you just used (or asked for another way) in the last hour drops down, so the page moves on.
  private static func penalized(
    _ list: [SuggestionCandidate], _ ctx: SuggestionContext, _ cal: Calendar
  ) -> [SuggestionCandidate] {
    let recent = ctx.chats.filter {
      ctx.now.timeIntervalSince($0.at) <= recentWindow && ctx.now.timeIntervalSince($0.at) >= -60
    }
    .flatMap { $0.userTexts.prefix(3) }
    guard !recent.isEmpty else { return list }
    let routes = recent.map {
      SentenceRoute.route($0, items: ctx.editItems, now: ctx.now, calendar: cal)
    }
    let asked = Set(recent.map { norm($0) })
    return list.map { c in
      var c = c
      let same =
        asked.contains(norm(c.text))
        || routes.contains { r in
          switch (r, c.expectation) {
          case (.tidy, .tidy), (.question, .question):
            return true
          default: return false
          }
        }
      if same { c.score -= 70 }
      return c
    }
  }

  /// How long a used suggestion stays out of the way.
  public static let recentWindow: TimeInterval = 3600

  private static func norm(_ s: String) -> String {
    s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
  }

  // MARK: Choice

  /// The best two or three for now (one per kind). A third only when it is clearly worth showing.
  public static func top(
    _ ctx: SuggestionContext, limit: Int = 3, calendar cal: Calendar = .current
  ) -> [SuggestionCandidate] {
    var seen = Set<SuggestionCandidate.Kind>()
    var picked: [SuggestionCandidate] = []
    for c in candidates(ctx, calendar: cal) where !seen.contains(c.kind) {
      seen.insert(c.kind)
      picked.append(c)
      if picked.count == max(limit, 2) { break }
    }
    if picked.count >= 3, limit >= 3, picked[2].score >= thirdChipMinimum {
      return Array(picked.prefix(3))
    }
    return Array(picked.prefix(2))
  }

  public static let thirdChipMinimum: Double = 40

  /// The strongest candidate of each kind, best first: what the model may choose from. Contains every chip `top` shows.
  public static func pool(
    _ ctx: SuggestionContext, limit: Int = 6, calendar cal: Calendar = .current
  ) -> [SuggestionCandidate] {
    var seen = Set<SuggestionCandidate.Kind>()
    return candidates(ctx, calendar: cal).filter { seen.insert($0.kind).inserted }.prefix(limit).map
    { $0 }
  }

  public static func chips(_ ctx: SuggestionContext, calendar: Calendar = .current)
    -> [AskSuggestion]
  {
    top(ctx, calendar: calendar).map { AskSuggestion(id: $0.id, text: $0.text) }
  }

  // MARK: Facts for the model

  /// A few plain lines about now, for the model's prompt. No titles beyond the candidates' own.
  public static func facts(_ ctx: SuggestionContext, calendar cal: Calendar = .current) -> [String]
  {
    let weekday = DateFormatter()
    weekday.calendar = cal
    weekday.locale = Locale(identifier: "en_US_POSIX")
    weekday.dateFormat = "EEEE"
    var lines = ["Now: \(weekday.string(from: ctx.now)) \(clock(ctx.now, .en, cal))."]
    if let next = ctx.upcomingEvents().first {
      lines.append("Next event: \(next.title) at \(clock(next.start, .en, cal)).")
    } else {
      lines.append("No more events today.")
    }
    lines.append("Free time left today: \(ctx.freeMinutes(cal)) min.")
    lines.append(
      "Reminders: \(ctx.leftToday(cal).count) left today, \(ctx.overdue(cal).count) overdue, \(ctx.doneToday(cal)) done today."
    )
    return lines
  }
}

// MARK: - Model blend

/// What the model returns for one slot: a candidate id and its own wording.
public struct SuggestionPick: Equatable, Sendable {
  public var id: String
  public var message: String

  public init(id: String, message: String) {
    self.id = id
    self.message = message
  }
}

public enum SuggestionBlend {
  /// The chips to show once the model has answered. Always the same number as the rule chips (`rules.count`):
  /// the model chooses and rewords among `pool`; wording that no longer lands on the same thing is dropped for the rule sentence;
  /// an extra model-invented sentence replaces the last chip only if it is a new item or a move that routes cleanly.
  public static func apply(
    rules: [AskSuggestion], pool: [SuggestionCandidate], picks: [SuggestionPick], invented: String?,
    ctx: SuggestionContext, calendar cal: Calendar = .current
  ) -> [AskSuggestion] {
    let n = rules.count
    guard n > 0 else { return rules }
    var chips: [AskSuggestion] = []
    var used = Set<String>()
    func add(_ c: SuggestionCandidate, wording: String?) {
      guard chips.count < n, !used.contains(c.id) else { return }
      used.insert(c.id)
      var text = c.text
      if let w = wording?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty,
        w.count <= 80, w != c.text,
        c.expectation.matches(
          SentenceRoute.route(w, items: ctx.editItems, now: ctx.now, calendar: cal), text: w,
          items: ctx.editItems, now: ctx.now, calendar: cal)
      {
        text = w
      }
      chips.append(AskSuggestion(id: c.id, text: text))
    }
    for p in picks {
      if let c = pool.first(where: { $0.id == p.id }) { add(c, wording: p.message) }
    }
    // The model chose fewer than shown: fill from the rule order.
    for r in rules { if let c = pool.first(where: { $0.id == r.id }) { add(c, wording: nil) } }

    if let extra = invented?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty,
      extra.count <= 80, chips.count >= 2
    {
      let route = SentenceRoute.route(extra, items: ctx.editItems, now: ctx.now, calendar: cal)
      let duplicate =
        chips.contains { $0.text.lowercased() == extra.lowercased() }
        || chips.contains {
          SentenceRoute.route($0.text, items: ctx.editItems, now: ctx.now, calendar: cal).family
            == route.family
        }
      if route.isNewItemOrMove, !duplicate, extra.count >= 4 {
        chips[chips.count - 1] = AskSuggestion(id: "model", text: extra)
      }
    }
    return chips
  }
}

/// The last model answer, reused while nothing changed and it is fresh. A new context (other chips) never reuses an old answer.
public struct SuggestionCache: Equatable {
  public var key: String
  public var chips: [AskSuggestion]
  public var at: Date

  public static let lifetime: TimeInterval = 180

  public static func key(for rules: [AskSuggestion], language: SuggestionLanguage) -> String {
    language.rawValue + "|" + rules.map(\.text).joined(separator: "|")
  }

  public func hit(key: String, now: Date) -> [AskSuggestion]? {
    self.key == key && now.timeIntervalSince(at) >= 0 && now.timeIntervalSince(at) < Self.lifetime
      ? chips : nil
  }

  public init(key: String, chips: [AskSuggestion], at: Date) {
    self.key = key
    self.chips = chips
    self.at = at
  }
}
