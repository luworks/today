import Foundation

/// The pure rules for "move / delete / ask" on items that already exist (no model, no UI), so they run under `swift test`.
/// The model part (instructions and the one request) is in Editing.swift.
public struct EditItem: Equatable, Sendable {
  public var id: String
  public var type: String  // "event" | "task"
  public var title: String
  public var start: Date?
  public var minutes: Int
  public var attendees: Int

  public init(
    id: String, type: String, title: String, start: Date? = nil, minutes: Int, attendees: Int
  ) {
    self.id = id
    self.type = type
    self.title = title
    self.start = start
    self.minutes = minutes
    self.attendees = attendees
  }
}

public enum Editing {
  // MARK: Is it an edit?

  private static func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// Questions are answered, not acted on (same test the composer uses).
  static func isQuestion(_ text: String) -> Bool {
    text.hasSuffix("?") || text.hasSuffix("？")
      || ["什么", "怎么", "吗", "多少", "几"].contains { text.contains($0) }
      || ["what", "how", "when", "which", "do ", "is ", "am ", "any"].contains {
        text.lowercased().hasPrefix($0)
      }
  }

  static func mentionsEverything(_ text: String) -> Bool {
    has(
      text,
      #"所有|全部|每一?个|\ball\b|\bevery\b|everything|(?:下午|上午|晚上|今天|明天|这周|本周|周.)的(?:事|会|安排|日程|任务|活动|都)|都(?:推|改|挪|取消|删|延)"#
    )
  }

  static func usesPronoun(_ text: String) -> Bool {
    has(
      text,
      #"\b(it|that|this|them)\b|这个|那个|它|just added|刚才|刚刚|刚加|上一个|\bthe last one\b|\bfirst one\b|\bother one\b|上面那个|下面那个|另一个|previous one"#
    )
  }

  private static let deleteCue =
    #"取消|删掉|删除|删了|不要了|不去了|不做了|不用了|不需要了|算了|去掉|划掉|\bget rid of\b|\bscratch\b|\bforget\b|\bdrop\b|\bcall off\b|\bnix\b|\bcancel(l?ed)?\b|\bdelete\b|\bremove\b"#
  private static let moveCue =
    #"推迟|延后|延期|顺延|提前|推到|改到|改成|改约|约到|约在|调到|调整|换到|换成|调成|挪|移到|移至|排到|拖到|往后推|改一下|改下|修改|晚一点|晚点|早点|早一点|推后|延迟|挪后|往前|换个时间|换时间|对调|互换|\bbump\b|\bshift\b|\bswap\b|\bswitch\b|\bearlier\b|\blater\b|\bpostpone|\breschedule|\bmove\b|\bpush\b|\bdelay\b|\bchange\b|\badjust\b|\bupdate\b|bring forward|安排在|安排到|定在|订在|放到|\binstead\b|can we (?:do|make|have|move)|how about|同一?时间|same time"#

  /// Does this sentence talk about existing items (edit) rather than add something new (capture)?
  /// An edit needs an existing item it plausibly points at; "remind me to ..." / "提醒我 ..." sentences are new items unless a title
  /// in the list is named by its words. Cancel / delete verbs count as an edit, move-like verbs only when the message also names an
  /// item, "it", a meeting or "everything". A clock time alone (no "to 4pm", no "the 3pm one") does not name an item.
  public static func looksLikeEdit(
    _ text: String, items: [EditItem], now: Date = .now, calendar: Calendar = .current
  ) -> Bool {
    if isQuestion(text) { return false }
    if Dialogue.startsNewItem(text),
      matchingItems(text, in: items, now: now, calendar: calendar, includeTime: false).isEmpty
    {
      return false
    }
    if has(text, deleteCue) { return true }
    guard has(text, moveCue) else { return false }
    return !matchingItems(text, in: items, now: now, calendar: calendar).isEmpty
      || usesPronoun(text) || mentionsEverything(text)
  }

  // MARK: Which item?

  /// Words that mean the same thing in both languages. A hit counts as one shared "concept", whatever the language.
  private static let conceptGroups: [[String]] = [
    ["lunch", "午饭", "午餐", "午休"], ["dinner", "晚饭", "晚餐"], ["breakfast", "早饭", "早餐"],
    ["meeting", "会议", "开会"], ["dentist", "牙医", "牙科"], ["doctor", "医生", "门诊", "看病"],
    ["weekly report", "周报"], ["report", "报告"], ["email", "邮件", "mail"], ["milk", "牛奶"],
    ["standup", "stand-up", "站会"],
    ["review", "评审", "复盘"], ["call", "电话"], ["gym", "健身"], ["interview", "面试"],
    ["flight", "航班", "机票"],
    ["budget", "预算"], ["1:1", "一对一", "one on one"], ["invoice", "发票"],
    ["groceries", "grocery", "买菜"],
    ["design", "设计"], ["contract", "合同"], ["slides", "幻灯片", "ppt"], ["rent", "房租"],
    ["mom", "妈妈", "mother"], ["dad", "爸爸", "father"],
    ["sales", "销售"], ["quarterly", "季度"], ["rent", "租金"], ["haircut", "理发"], ["train", "火车", "高铁"],
    ["exam", "考试"],
  ]
  /// Everyday words that appear in many titles say little about which item is meant; they weigh less than specific ones.
  private static let genericConcepts: Set<String> = [
    "call", "meeting", "review", "report", "email", "lunch", "dinner", "breakfast", "doctor",
  ]

  private static let englishStopWords: Set<String> = [
    "with", "the", "and", "for", "to", "my", "of", "in", "on", "at", "a", "an", "is", "it",
    "or", "by", "be", "move", "push", "delay", "cancel", "delete", "remove", "up", "back",
  ]

  /// Comparable pieces of a string: concept hits, then the leftover English words and two-character Chinese pieces.
  private static func units(_ raw: String) -> Set<String> {
    var s = raw.lowercased()
    var out = Set<String>()
    for (i, group) in conceptGroups.enumerated() {
      for term in group.sorted(by: { $0.count > $1.count }) where s.contains(term) {
        out.insert("c\(i)")
        s = s.replacingOccurrences(of: term, with: " ")
      }
    }
    if let re = try? NSRegularExpression(pattern: "[a-z0-9]{2,}") {
      for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
        if let r = Range(m.range, in: s), !englishStopWords.contains(String(s[r])) {
          out.insert("w" + s[r])
        }
      }
    }
    let cjk = Array(s).filter {
      $0.unicodeScalars.first.map { $0.value >= 0x4E00 && $0.value <= 0x9FFF } ?? false
    }
    if cjk.count >= 2 {
      for i in 0..<(cjk.count - 1) { out.insert("g" + String(cjk[i...(i + 1)])) }
    }
    return out
  }

  /// The items the words point at: all items sharing the most pieces with the message. Several = ambiguous.
  /// A generic "meeting / 会议 / 把会…" with no specific hit means any event with other people on it.
  /// `includeTime: false` looks at the words only (titles and concepts), not at a clock time that happens to equal an item's start.
  static func matchingItems(
    _ text: String, in items: [EditItem], now: Date = .now, calendar: Calendar = .current,
    includeTime: Bool = true
  ) -> [EditItem] {
    let t = units(text)
    let ref =
      includeTime && timeNamesItem(text)
      ? referencedTime(in: text, now: now, calendar: calendar) : nil
    let generic = Set(
      conceptGroups.enumerated().filter { genericConcepts.contains($0.element[0]) }.map {
        "c\($0.offset)"
      })
    func weight(_ unit: String) -> Int { generic.contains(unit) ? 1 : 2 }
    let hits = items.map { item -> (item: EditItem, matched: Set<String>) in
      var matched = units(item.title).intersection(t)
      if let ref, let s = item.start {
        let c = calendar.dateComponents([.hour, .minute], from: s)
        if c.hour == ref.hour, c.minute == ref.minute,
          ref.day.map({ calendar.isDate($0, inSameDayAs: s) }) ?? true
        {
          matched.insert("time")
        }
      }
      return (item, matched)
    }
    func score(_ matched: Set<String>) -> Int { matched.reduce(0) { $0 + weight($1) } }
    let best = hits.map { score($0.matched) }.max() ?? 0
    if best > 0 {
      let top = hits.filter { score($0.matched) == best }
      // A weaker item that matches on something the best one does not is a second item the message names ("牙医和产品周会").
      let covered = top.reduce(into: Set<String>()) { $0.formUnion($1.matched) }
      let others = hits.filter {
        score($0.matched) > 0 && score($0.matched) < best && !$0.matched.isSubset(of: covered)
      }
      return (top + others).map(\.item)
    }
    if has(text, #"meeting|会议|[把将的]会(?=[推改挪提延移取都])"#) {
      // With attendee info, meetings are the events other people are on; without it (no calendar access) any event could be it.
      let events = items.filter { $0.type == "event" }
      let withPeople = events.filter { $0.attendees > 0 }
      return withPeople.isEmpty ? events : withPeople
    }
    return []
  }

  /// Is a clock time in the sentence there to say *which* item ("move the 4:30 to 5:30", "三点那个会", "the 3pm one", "push my 3pm back an hour")?
  /// A time that is only where something new goes ("put the stuff in the garage at 3pm") names no item.
  static func timeNamesItem(_ text: String) -> Bool {
    has(text, #"[改推挪调换约拖延][到成在至]|提前到|推迟到|安排[到在]|\bto\b|→|\binstead\b|那个|那场|那次|\bone\b"#)
      || postponeAmount(in: text) != nil
  }

  /// "the 3pm one", "三点那个会改到四点半", "move the 4:30 to 5:30": the clock time that names an item is the one before the
  /// destination ("to ...", 改到 ...), or the only time when there is no destination.
  static func referencedTime(in text: String, now: Date, calendar: Calendar) -> (
    hour: Int, minute: Int, day: Date?
  )? {
    var zone = text
    if let r = text.range(
      of: #"[改推挪调换约拖延][到成在至]|提前到|推迟到|安排[到在]|\bto\b|→|\binstead\b"#,
      options: [.regularExpression, .caseInsensitive])
    {
      zone = String(text[text.startIndex..<r.lowerBound])
    }
    let parsed = CaptureParser.parse(zone, now: calendar.startOfDay(for: now), calendar: calendar)
    guard let h = parsed.hour else { return nil }
    return (h, parsed.minute, parsed.hasDay ? parsed.day : nil)
  }

  // MARK: New time

  private static let numberWords: [String: Int] = [
    "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "ten": 10,
  ]
  private static let chineseDigits: [Character: Int] = [
    "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
  ]

  /// "半小时", "一小时", "两天", "30 minutes", "a day", "half an hour" → minutes. Negative for "提前 / earlier". Nil if no amount.
  /// A day is 1440 minutes. "三天后" (in three days) is not an amount to shift by.
  static func postponeAmount(in text: String) -> Int? {
    let lower = text.lowercased()
    func first(_ pattern: String) -> [String?]? {
      guard let re = try? NSRegularExpression(pattern: pattern),
        let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower))
      else { return nil }
      return (1..<m.numberOfRanges).map {
        Range(m.range(at: $0), in: lower).map { String(lower[$0]) }
      }
    }
    var minutes: Int?
    if first(#"一个半小时"#) != nil {
      minutes = 90
    } else if first(#"半(?:个)?(?:小时|钟头)|half an? hour"#) != nil {
      minutes = 30
    } else if first(#"一刻钟|一刻|quarter of an hour|a quarter hour|quarter-hour"#) != nil {
      minutes = 15
    } else if first(#"两刻钟"#) != nil {
      minutes = 30
    } else if first(#"三刻钟"#) != nil {
      minutes = 45
    } else if let g = first(#"(\d+|[一二两三四五六七八九十])\s*(?:个)?\s*(小时|钟头|分钟|天)(?!后)"#), let u = g[1] {
      let n = g[0].flatMap { Int($0) ?? ($0.count == 1 ? chineseDigits[$0.first!] : nil) }
      minutes = n.map { $0 * (u == "分钟" ? 1 : u == "天" ? 1440 : 60) }
    } else if let g = first(
      #"\b(\d+|a|an|one|two|three|four|five|six|ten)[\s-]*(hours?|hrs?|minutes?|mins?|days?)\b"#),
      let u = g[1]
    {
      let n = g[0].flatMap { Int($0) ?? numberWords[$0] }
      minutes = n.map { $0 * (u.hasPrefix("m") ? 1 : u.hasPrefix("d") ? 1440 : 60) }
    }
    guard let m = minutes else { return nil }
    let earlier = has(lower, #"提前|早半|早一|早点|earlier|ahead|bring forward|move up|pull in"#)
    return earlier ? -m : m
  }

  /// New start time, from the words only (the model's numbers are not used; they were wrong too often).
  /// A day or clock time named in the message replaces that part of the old start and the rest stays. A bare time that is already
  /// past today is still today (it is an edit, not a new item). Otherwise "later / earlier by N" shifts the old start.
  /// Nil when the message gives no new time.
  public static func newStart(for item: EditItem, text: String, now: Date, calendar: Calendar)
    -> Date?
  {
    let today = calendar.startOfDay(for: now)
    // Where it goes: the words after "to / 改到 / →". An item named by its clock time ("the 3pm one") has no other time in the sentence.
    var dest = text
    if let r = text.range(
      of: #"[改推挪调换约拖延][到成在至]|提前到|推迟到|安排[到在]|\bto\b|→|\binstead\b"#,
      options: [.regularExpression, .caseInsensitive])
    {
      dest = String(text[r.upperBound...])
      // "can we do three pm instead": the new time comes before "instead".
      if text[r].lowercased() == "instead" { dest = String(text[text.startIndex..<r.lowerBound]) }
      if dest.range(
        of:
          #"^\s*(?:like\s+)?(?:\d{1,2}(?::\d{2})?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b(?!\s*(?:点|号|日|月|am|pm|a\.m|p\.m))"#,
        options: [.regularExpression, .caseInsensitive]) != nil
      {
        dest = "at " + dest
      }
    } else if let ref = referencedTime(in: text, now: now, calendar: calendar), let s = item.start,
      calendar.dateComponents([.hour, .minute], from: s).hour == ref.hour
    {
      dest = text.replacingOccurrences(
        of: #"\d{1,2}(?::\d{2})?\s*(?:am|pm|点半?|点\d{0,2}分?)?|[零一二两三四五六七八九十]{1,3}点半?"#, with: " ",
        options: [.regularExpression, .caseInsensitive])
    }
    // Parse as of midnight so "move it to 8am" is not rolled to tomorrow.
    let parsed = CaptureParser.parse(dest, now: today, calendar: calendar)
    let keepsTime = has(text, #"同一?时间|同一个时间|same time|同一时刻"#)
    if parsed.hasDay || (parsed.hour != nil && !keepsTime) {
      var day = item.start.map { calendar.startOfDay(for: $0) } ?? today
      if parsed.hasDay { day = parsed.day }
      let hour: Int
      let minute: Int
      if let h = parsed.hour, !keepsTime {
        (hour, minute) = (h, parsed.minute)
      } else if item.attendees > 0, !keepsTime {
        // a day with no time for a meeting other people are on: ask for the time rather than invite them to a guess
        return nil
      } else if let s = item.start {
        let c = calendar.dateComponents([.hour, .minute], from: s)
        (hour, minute) = (c.hour ?? 9, c.minute ?? 0)
      } else {
        return nil
      }
      return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
    if let m = postponeAmount(in: text), let start = item.start {
      return start.addingTimeInterval(TimeInterval(m * 60))
    }
    return nil
  }

}
