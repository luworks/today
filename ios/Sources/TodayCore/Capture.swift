import Foundation

/// What the composer understood from a line of text. Shown as a preview card;
/// nothing is created until the user taps 添加.
public struct Capture: Equatable, Codable, Sendable {
  public enum Kind: String, CaseIterable, Codable, Sendable { case task, event }

  public var title: String
  public var day: Date
  public var hasDay: Bool
  public var hour: Int?
  public var minute: Int = 0
  /// RepeatRule raw value; nil = one-off.
  public var repeatRule: String? = nil
  /// Set when a time range was given ("3-4pm").
  public var durationMinutes: Int? = nil
  /// What the line most likely is. The user can switch it on the preview card.
  public var kind: Kind = .task
  /// An alarm ("wake me at 7", "alarm in 30 minutes"); needs a time. Becomes a real alarm on the Alarms tab when it rings
  /// within a day (see `Capture.insert`). The title loses the instruction words ("set an alarm", "remind me to").
  public var ringsAsAlarm: Bool = false {
    didSet { if ringsAsAlarm, !oldValue { title = CaptureParser.alarmLabel(title) } }
  }
  /// A whole-day event (no start time).
  public var isAllDay: Bool = false
  /// The Reminders list a task goes to (`OneTask.listName`). nil = the app's default; the AI screen fills in the Inbox
  /// or a confident `ListGuess`, and the user can change it on the card.
  public var listName: String? = nil
  /// The time is working time ("work on the report for 2 hours"). A reminder has one date, so it is written like any
  /// other timed reminder (due at that time, alert at it).
  public var isWorkBlock: Bool = false
  /// Verbatim context retained when a concise title separates action from motivation.
  public var notes: String? = nil

  /// An alarm without a chosen time remains a preview, never an ordinary reminder.
  public var isReadyToAdd: Bool { !ringsAsAlarm || hour != nil }

  /// The clock time the line named, on its day.
  public var clockTime: Date? {
    clockTime(calendar: .current)
  }

  public func clockTime(calendar: Calendar) -> Date? {
    guard let hour else { return nil }
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
  }

  /// The date a reminder made from this capture is written with: a clock time is its due time and the alert fires at it
  /// (reminderOffsetMinutes 0), a bare day is a date-only due.
  public var taskTiming: (due: Date?, alertMinutesBefore: Int?) {
    taskTiming(calendar: .current)
  }

  public func taskTiming(calendar: Calendar) -> (due: Date?, alertMinutesBefore: Int?) {
    if let start = clockTime(calendar: calendar) { return (start, 0) }
    return (hasDay ? day : nil, nil)
  }

  /// "New reminder", "New event", "New alarm": the card's first line.
  public var kindLabel: String {
    switch kind {
    case .event: "New event"
    case .task: ringsAsAlarm ? "New alarm" : "New reminder"
    }
  }

  /// The list a reminder goes to, in Apple's words: no name = "Reminders".
  public var listLabel: String {
    guard let listName, !listName.isEmpty else { return "Reminders" }
    return listName
  }

  /// A reminder with a clock time that alerts at that time (see `makeTask`): not an event, not an alarm, not working time.
  public var alertsAtTime: Bool {
    alertsAtTime(calendar: .current)
  }

  public func alertsAtTime(calendar: Calendar) -> Bool {
    kind == .task && !ringsAsAlarm && clockTime(calendar: calendar) != nil
  }

  /// What the card says will be created, in the words of the result: "Tomorrow 9:00 AM · alerts you", "Due Friday".
  public var summary: String {
    summary(now: .now, calendar: .current, locale: .current)
  }

  /// The existing readiness policy depends only on whether an alarm has a chosen hour.
  /// Accepts the same calendar as the explicit timing path without adding date-validity requirements.
  public func isReadyToAdd(calendar: Calendar) -> Bool { isReadyToAdd }

  public func summary(now: Date, calendar: Calendar, locale: Locale) -> String {
    let clockTime = clockTime(calendar: calendar)
    func dayText(_ date: Date) -> String {
      if calendar.isDate(date, inSameDayAs: now) { return "Today" }
      if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
        calendar.isDate(date, inSameDayAs: tomorrow)
      {
        return "Tomorrow"
      }
      if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
        calendar.isDate(date, inSameDayAs: yesterday)
      {
        return "Yesterday"
      }
      return date.formatted(
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month()
          .day())
    }
    func withTime(_ date: Date) -> String {
      let parts = calendar.dateComponents([.hour, .minute], from: date)
      if parts.hour == 0 && parts.minute == 0 { return dayText(date) }
      return dayText(date) + " "
        + date.formatted(
          Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, calendar: calendar,
            timeZone: calendar.timeZone))
    }
    var parts: [String] = []
    switch kind {
    case .event where isAllDay:
      parts.append(dayText(day) + " · All day")
    case .event:
      let start = clockTime ?? day
      parts.append(withTime(start))
      if let d = durationMinutes { parts.append(DurationLabel.text(minutes: d)) }
    case .task where ringsAsAlarm:
      parts.append("Alarm " + (clockTime.map { withTime($0) } ?? ""))
      if let rule = repeatRule.flatMap(RepeatRule.init(rawValue:)) { parts.append(rule.label) }
    case .task:
      if let start = clockTime {
        parts.append(withTime(start))
      } else if hasDay {
        parts.append("Due " + dayText(day))
      } else {
        parts.append("No date")
      }
      if let rule = repeatRule.flatMap(RepeatRule.init(rawValue:)) { parts.append(rule.label) }
      if alertsAtTime(calendar: calendar) { parts.append("alerts you") }
    }
    return parts.joined(separator: " · ")
  }

  public init(
    title: String, day: Date, hasDay: Bool, hour: Int? = nil, minute: Int = 0,
    repeatRule: String? = nil, durationMinutes: Int? = nil, kind: Kind = .task,
    ringsAsAlarm: Bool = false, isAllDay: Bool = false,
    listName: String? = nil, isWorkBlock: Bool = false, notes: String? = nil
  ) {
    self.title = title
    self.day = day
    self.hasDay = hasDay
    self.hour = hour
    self.minute = minute
    self.repeatRule = repeatRule
    self.durationMinutes = durationMinutes
    self.kind = kind
    self.ringsAsAlarm = ringsAsAlarm
    self.isAllDay = isAllDay
    self.listName = listName
    self.isWorkBlock = isWorkBlock
    self.notes = notes
  }
}

extension CardStatus {
  /// Explicit presentation context for the existing spoken card label.
  public func accessibilityLabel(
    for capture: Capture, now: Date, calendar: Calendar, locale: Locale
  ) -> String {
    let summary = capture.summary(now: now, calendar: calendar, locale: locale)
    switch self {
    case .open: return capture.title + ", " + summary
    default: return footerTitle + ": " + capture.title + ", " + summary
    }
  }
}

public enum CaptureParser {
  /// Words that only connect a date or time to the title ("at 3pm", "on Friday", "by Oct 20").
  private static let lead = #"(?:\b(?:at|on|by|due|before|this|coming|until|till|around)\s+)*"#

  private static let weekdayNames: [(String, Int)] = [
    ("sunday", 1), ("sun", 1), ("monday", 2), ("mon", 2), ("tuesday", 3), ("tues", 3), ("tue", 3),
    ("wednesday", 4), ("wed", 4), ("thursday", 5), ("thurs", 5), ("thur", 5), ("thu", 5),
    ("friday", 6), ("fri", 6), ("saturday", 7), ("sat", 7),
  ]
  private static let chineseWeekdays: [Character: Int] = [
    "日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7,
  ]
  private static let months = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
  ]

  /// A month is context, not an exact due date. Keep it in the title and notes instead of
  /// inventing a day. The remaining action also supplies the new-message routing boundary.
  public static func leadingMonth(
    _ raw: String, now: Date = .now, calendar: Calendar = .current
  ) -> (action: String, label: String)? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern =
      #"^(?:(明年|今年|[0-9]{4}年)\s*([0-9]{1,2})月(?!\s*[0-9])|next\s+(January|February|March|April|May|June|July|August|September|October|November|December)\b(?!\s*[0-9]))\s*[,，:]?\s*"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let prefix = Range(match.range, in: text)
    else { return nil }
    func group(_ n: Int) -> String? {
      Range(match.range(at: n), in: text).map { String(text[$0]) }
    }
    let currentYear = calendar.component(.year, from: now)
    let month: Int
    let year: Int
    let label: String
    if let zh = group(1), let number = group(2).flatMap(Int.init), (1...12).contains(number) {
      month = number
      year =
        zh == "明年" ? currentYear + 1 : zh == "今年" ? currentYear : Int(zh.dropLast()) ?? currentYear
      label = "\(year)年\(month)月"
    } else if let name = group(3),
      let index = months.firstIndex(of: String(name.lowercased().prefix(3)))
    {
      month = index + 1
      year = currentYear + (month <= calendar.component(.month, from: now) ? 1 : 0)
      label = "\(name.capitalized) \(year)"
    } else {
      return nil
    }
    let action = String(text[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !action.isEmpty else { return nil }
    return (action, label)
  }

  /// Booking is a personal action, even when its object is an appointment or meeting.
  public static func isBookingAction(_ raw: String) -> Bool {
    let text = leadingMonth(raw)?.action ?? raw
    return text.range(
      of:
        #"^(?:(?:please|can you|could you)\s+|请|帮我)?(?:book\s+(?:(?:a|an|the|my)\s+)?(?:doctor|dentist|appointment|annual\s+check)|预约(?!了|好|过)\S)"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  public static func parse(_ raw: String, now: Date = .now, calendar: Calendar = .current)
    -> Capture
  {
    let monthContext = leadingMonth(raw, now: now, calendar: calendar)
    var text =
      " " + (monthContext?.action ?? raw).trimmingCharacters(in: .whitespacesAndNewlines) + " "
    let today = calendar.startOfDay(for: now)
    var day = today
    var hasDay = false
    var repeatRule: String?

    func setDay(_ d: Date?) {
      guard let d else { return }
      day = calendar.startOfDay(for: d)
      hasDay = true
    }
    func offset(_ n: Int) -> Date? { calendar.date(byAdding: .day, value: n, to: today) }

    // Consume the entire weekday list before generic "每周" / "every week" tokens.
    // The stored rule carries every day, rather than relying on the first due date alone.
    let weeklyDays = takeWeeklyDays(from: &text)
    if !weeklyDays.isEmpty {
      repeatRule = RepeatRule.weeklyOn(weeklyDays).rawValue
      setDay(
        weeklyDays.compactMap { upcoming($0, today: today, calendar: calendar, allowToday: true) }
          .min())
    }

    // Repeat ("every day", "weekly", "每天"…). Weekday first so "every weekday" isn't read as "every week".
    let repeats: [(String, RepeatRule)] = [
      (#"\bevery\s+weekday\b|\bweekdays\b|每(?:个)?工作日|工作日"#, .weekdays),
      (#"\bevery\s+weekends?\b|\bweekends\b|每(?:个)?周末"#, .weeklyOn([1, 7])),
      (#"\bevery\s*day\b|\bdaily\b|每天|每日"#, .daily),
      (#"\bevery\s*week\b|\bweekly\b|每周|每星期"#, .weekly),
      (#"\bevery\s*month\b|\bmonthly\b|每月|每个月"#, .monthly),
      (#"\bevery\s*year\b|\byearly\b|\bannually\b|每年"#, .yearly),
    ]
    for (pattern, rule) in repeats where take(pattern, from: &text) != nil {
      repeatRule = rule.rawValue
      if rule == .weekdays {
        setDay(
          [2, 3, 4, 5, 6].compactMap {
            upcoming($0, today: today, calendar: calendar, allowToday: true)
          }.min())
      } else if case .weeklyOn(let days) = rule {
        setDay(
          days.compactMap { upcoming($0, today: today, calendar: calendar, allowToday: true) }.min()
        )
      }
      break
    }

    // Chinese numerals in clock times and dates ("七点半", "九点", "下个月三号") become digits first.
    text = normalizeChinese(text)
    text = normalizeEnglishClock(text)

    // Relative times: "30分钟后", "半小时后", "in 2 hours", "in half an hour". Gives the day and the time at once.
    var relativeHour: Int?
    var relativeMinute = 0
    if let minutes = takeRelativeMinutes(from: &text) {
      let target = now.addingTimeInterval(TimeInterval(minutes * 60))
      let c = calendar.dateComponents([.hour, .minute], from: target)
      relativeHour = c.hour
      relativeMinute = c.minute ?? 0
      setDay(target)
    }

    // Relative day words.
    // Some day words also say which half of the day a bare hour means ("今晚8点" is 20:00, "明早6点" is 06:00).
    let dayWords: [(String, Int, String?)] = [
      (#"\bday\s+after\s+tomorrow\b"#, 2, nil), ("大后天", 3, nil), ("后天", 2, nil), ("后儿个", 2, nil),
      ("后儿", 2, nil), ("明天", 1, nil), ("明儿个", 1, nil), ("明儿", 1, nil),
      ("今天", 0, nil), ("今儿个", 0, nil), ("今儿", 0, nil),
      ("明早", 1, "上午"), ("明晚", 1, "晚上"), ("今早", 0, "上午"), ("今晚", 0, "晚上"),
      (#"\b(?:tomorrow|tomorow|tommorow|tmrw|tmr|2morrow|2mrw)\b"#, 1, nil),
      (#"\btonight\b"#, 0, "晚上"), (#"\btoday\b"#, 0, nil),
    ]
    var impliedPeriod: String?
    for (word, n, period) in dayWords where take(lead + word, from: &text) != nil {
      setDay(offset(n))
      impliedPeriod = period
      break
    }
    // An alarm request means a morning hour unless it says otherwise ("wake me at 6:30" is 06:30, not 18:30).
    let isAlarm =
      raw.range(
        of: #"wake\s+me|\balarm\b|\btimer\b|计时|闹钟|起床|叫醒"#,
        options: [.regularExpression, .caseInsensitive]) != nil
    let defaultPeriod = impliedPeriod ?? (isAlarm ? "上午" : nil)

    // "by end of day" / EOD: no clock time.
    _ = take(#"\b(?:by\s+)?(?:the\s+)?end\s+of\s+(?:the\s+)?day\b|\beod\b|\bcob\b"#, from: &text)

    // Weekend (= Saturday), end of month, "下个月3号", "下下周一".
    if !hasDay {
      if let m = take(#"下下(?:周|星期|礼拜)([一二三四五六日天])"#, from: &text) {
        setDay(
          nextWeek(chinese(m[0]), today: today, calendar: calendar).flatMap {
            calendar.date(byAdding: .day, value: 7, to: $0)
          })
      } else if take(#"下(?:个)?(?:周末|星期末)|\bnext\s+weekend\b"#, from: &text) != nil {
        setDay(nextWeek(7, today: today, calendar: calendar))
      } else if take(#"(?:这个?|本)?(?:周末|星期末)|\b(?:this\s+|on\s+the\s+)?weekend\b"#, from: &text)
        != nil
      {
        setDay(upcoming(7, today: today, calendar: calendar, allowToday: true))
      } else if take(#"下个?月[底末](?:之?前)?|\b(?:the\s+)?end\s+of\s+next\s+month\b"#, from: &text)
        != nil
      {
        setDay(monthEnd(offset: 1, today: today, calendar: calendar))
      } else if take(
        #"(?:本|这个)?月[底末](?:之?前)?|\b(?:the\s+)?end\s+of\s+(?:the\s+|this\s+)?month\b|\bmonth[-\s]end\b"#,
        from: &text) != nil
      {
        setDay(monthEnd(offset: 0, today: today, calendar: calendar))
      } else if let m = take(#"下个?月\s*(\d{1,2})\s*[号日]"#, from: &text), let d = Int(m[0] ?? "") {
        setDay(dayInMonth(d, offset: 1, today: today, calendar: calendar))
      }
    }

    // Weekdays: "next Monday" / 下周一 = next week's; "Friday" / 周五 = the next one after today.
    if !hasDay {
      let english = weekdayNames.map(\.0).joined(separator: "|")
      if let m = take(lead + #"\bnext\s+("# + english + #")\b"#, from: &text) {
        setDay(nextWeek(weekday(m[0]), today: today, calendar: calendar))
      } else if let m = take(#"(?<!一)下(?:周|星期|礼拜)([一二三四五六日天])"#, from: &text) {
        setDay(nextWeek(chinese(m[0]), today: today, calendar: calendar))
      } else if let m = take(lead + #"\b("# + english + #")\b"#, from: &text) {
        setDay(upcoming(weekday(m[0]), today: today, calendar: calendar))
      } else if let m = take(#"(?:这个?|本)(?:周|星期|礼拜)([一二三四五六日天])"#, from: &text) {
        setDay(upcoming(chinese(m[0]), today: today, calendar: calendar, allowToday: true))
      } else if let m = take(#"(?:周|星期|礼拜)([一二三四五六日天])"#, from: &text) {
        setDay(upcoming(chinese(m[0]), today: today, calendar: calendar))
      }
    }

    // Calendar dates: "Oct 20", "October 20th", "10/20", "10月20日".
    if !hasDay {
      let monthPattern =
        lead + #"\b("# + months.joined(separator: "|")
        + #")[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b"#
      if let m = take(monthPattern, from: &text),
        let mi = months.firstIndex(of: String((m[0] ?? "").lowercased().prefix(3))),
        let d = Int(m[1] ?? "")
      {
        setDay(date(month: mi + 1, day: d, today: today, calendar: calendar))
      } else if let m = take(#"(\d{1,2})月(\d{1,2})[日号]?"#, from: &text), let mo = Int(m[0] ?? ""),
        let d = Int(m[1] ?? "")
      {
        setDay(date(month: mo, day: d, today: today, calendar: calendar))
      } else if let m = take(lead + #"\b(\d{1,2})/(\d{1,2})\b"#, from: &text),
        let mo = Int(m[0] ?? ""), let d = Int(m[1] ?? "")
      {
        setDay(date(month: mo, day: d, today: today, calendar: calendar))
      } else if let m = take(
        #"\b(?:on|by|before|until|the)\s+(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)\b"#, from: &text),
        let d = Int(m[0] ?? "")
      {
        // "the 22nd", "on the 1st": this month if it hasn't passed, else next month.
        setDay(dayInMonth(d, offset: nil, today: today, calendar: calendar))
      } else if let m = take(#"(?<![\d月])(\d{1,2})\s*[号日](?![楼线门口店])"#, from: &text),
        let d = Int(m[0] ?? "")
      {
        setDay(dayInMonth(d, offset: nil, today: today, calendar: calendar))
      }
    }

    // Times. A range ("3-4pm", "10点到11点") gives a start and a duration.
    var hour: Int? = relativeHour
    var minute = relativeMinute
    var duration: Int?
    let rangeEN =
      lead
      + #"(?<![:：.\d])\b(\d{1,2})(?:[:：](\d{2}))?\s*(am|pm)?\s*(?:-|–|to|~)\s*(\d{1,2})(?:[:：](\d{2}))?\s*(am|pm)\b"#
    let rangeZH =
      #"(凌晨|清晨|早晨|上午|早上|中午|下午|傍晚|晚上)?\s*(?<![:：.\d])(\d{1,2})(?:[:：](\d{2})|点(半)?)?\s*(?:到|至|-|~)\s*(\d{1,2})(?:[:：](\d{2})|点(半)?)"#
    if let m = take(rangeEN, from: &text) {
      let endPeriod = m[5]
      let endH = adjust(Int(m[3] ?? ""), period: endPeriod)
      let endM = Int(m[4] ?? "") ?? 0
      var startH = adjust(Int(m[0] ?? ""), period: m[2] ?? endPeriod)
      // "11-1pm": the start is the morning before a PM end.
      if let s = startH, let e = endH, s > e, m[2] == nil { startH = s - 12 }
      hour = startH
      minute = Int(m[1] ?? "") ?? 0
      if let h = hour, let e = endH { duration = (e * 60 + endM) - (h * 60 + minute) }
    } else if let g = peek(
      lead
        + #"(?<![:：.\d])\b(\d{1,2})(?:[:：](\d{2}))?\s*(?:to|-|–|until|till)\s*(\d{1,2})(?:[:：](\d{2}))?\b(?!\s*(?:am|pm|%|\d|:|分|个|人|天|号|月|日))"#,
      in: text),
      let a = Int(g[0] ?? ""), let b = Int(g[2] ?? ""), (1...12).contains(a), (1...12).contains(b),
      g[1] != nil || g[3] != nil || b != a,
      let startH = adjust(a, period: nil), let endH = adjust(b, period: nil),
      endH > startH
        || (endH * 60 + (Int(g[3] ?? "") ?? 0)) > (startH * 60 + (Int(g[1] ?? "") ?? 0)),
      endH - startH <= 8,
      take(
        lead
          + #"(?<![:：.\d])\b(\d{1,2})(?:[:：](\d{2}))?\s*(?:to|-|–|until|till)\s*(\d{1,2})(?:[:：](\d{2}))?\b(?!\s*(?:am|pm|%|\d|:|分|个|人|天|号|月|日))"#,
        from: &text) != nil
    {
      // "10 to 11", "wed 10 to 12" with no am / pm: same rules as a single bare hour.
      hour = startH
      minute = Int(g[1] ?? "") ?? 0
      duration = (endH * 60 + (Int(g[3] ?? "") ?? 0)) - (startH * 60 + minute)
    } else if let m = take(rangeZH, from: &text) {
      hour = adjust(Int(m[1] ?? ""), period: m[0] ?? defaultPeriod)
      minute = m[3] != nil ? 30 : Int(m[2] ?? "") ?? 0
      let endH = adjust(Int(m[4] ?? ""), period: m[0] ?? defaultPeriod)
      let endM = m[6] != nil ? 30 : Int(m[5] ?? "") ?? 0
      if let h = hour, let e = endH { duration = (e * 60 + endM) - (h * 60 + minute) }
    }
    if let d = duration, d <= 0 { duration = nil }
    let rangeDuration = duration
    // A length in words ("开会两个小时", "for 90 minutes", "2-hour") is a duration but does not make it an event by itself.
    if duration == nil, let d = takeDurationMinutes(from: &text) { duration = d }
    if hour != nil {
      // already set by a range
    } else if let m = take(
      lead + #"(凌晨|清晨|早晨|上午|早上|中午|下午|傍晚|晚上)?\s*(\d{1,2})[:：](\d{2})\s*(am|pm)?(?![a-z0-9])"#,
      from: &text)
    {
      hour = adjust(Int(m[1] ?? ""), period: m[0] ?? m[3] ?? defaultPeriod)
      minute = Int(m[2] ?? "") ?? 0
    } else if let m = take(lead + #"\b(\d{1,2})\s*(am|pm)\b"#, from: &text) {
      hour = adjust(Int(m[0] ?? ""), period: m[1])
    } else if let m = take(
      #"(凌晨|清晨|早晨|上午|早上|中午|下午|傍晚|晚上)?\s*(\d{1,2})\s*点\s*(半|(\d{1,2})\s*分?)?\s*整?\s*(?:左右|前后)?\s*(之?前)?"#,
      from: &text)
    {
      hour = adjust(Int(m[1] ?? ""), period: m[0] ?? defaultPeriod)
      minute = m[2] == "半" ? 30 : Int(m[3] ?? "") ?? 0
      // "下午5点前" with no day is a deadline today.
      if m[4] != nil, !hasDay { setDay(today) }
    } else if take(lead + #"\bnoon\b|中午"#, from: &text) != nil {
      hour = 12
    } else if take(lead + #"\bmidnight\b"#, from: &text) != nil {
      hour = 0
    } else if let m = take(#"\bat\s+(\d{1,2})\b(?![:/])"#, from: &text) {
      hour = adjust(Int(m[0] ?? ""), period: defaultPeriod)
    } else if let m = take(#"\b(\d{1,2})\s*ish\b"#, from: &text) {
      hour = adjust(Int(m[0] ?? ""), period: defaultPeriod)
    } else if impliedPeriod != nil,
      let m = take(
        #"(?<![\d:/.-])\b(\d{1,2})\b(?![:/.\d-]|\s*(?:%|个|人|号|日|月|块|元|st|nd|rd|th))"#, from: &text)
    {
      // "tonight 8", "明早 9": a bare number after a day word that says morning / evening.
      hour = adjust(Int(m[0] ?? ""), period: defaultPeriod)
    }
    if let h = hour, !(0...23).contains(h) || !(0...59).contains(minute) {
      hour = nil
      minute = 0
    }
    // A time with no day: if it has already passed today, it most likely means tomorrow.
    if let h = hour, !hasDay,
      let t = calendar.date(bySettingHour: h, minute: minute, second: 0, of: today), t < now
    {
      setDay(offset(1))
    }

    // A repeating occurrence whose time passed today advances within its own weekday set.
    if let h = hour, let rule = repeatRule.flatMap(RepeatRule.init(rawValue:)),
      calendar.isDate(day, inSameDayAs: today),
      let time = calendar.date(bySettingHour: h, minute: minute, second: 0, of: day), time < now
    {
      setDay(rule.next(after: day, calendar: calendar))
    }

    // Leftover connectors at either end ("Pay rent on", "at Call").
    var title =
      text
      .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(
        separator: " "
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: " ,，。.、"))
    var connectors: Set<String> = ["at", "on", "by", "due", "before", "this", "next", "every"]
    // The time-range parser removes the hours in "review from 2pm to 3pm".
    if hour != nil, duration != nil { connectors.insert("from") }
    var words = title.split(separator: " ").map(String.init)
    while let last = words.last, connectors.contains(last.lowercased()) { words.removeLast() }
    while let first = words.first, connectors.contains(first.lowercased()), words.count > 1 {
      words.removeFirst()
    }
    title = words.joined(separator: " ").trimmingCharacters(
      in: CharacterSet(charactersIn: " ,，。.、"))

    title = cleanTitle(title, raw: raw)
    let finalTitle = title.isEmpty ? raw : title
    var capture = Capture(
      title: finalTitle, day: day, hasDay: hasDay, hour: hour, minute: minute,
      repeatRule: repeatRule, durationMinutes: duration,
      kind: kind(title: finalTitle, hour: hour, duration: rangeDuration, repeatRule: repeatRule))
    capture.isWorkBlock = isWorkTime(raw, hasLength: duration != nil)
    if isBookingAction(monthContext?.action ?? raw) { capture.kind = .task }
    capture = CaptureTitleRefinement.fallback(capture, source: raw)
    if let monthContext {
      capture.title = monthContext.label + " " + capture.title
      capture.notes = [
        capture.notes, raw,
        "Requested month: \(monthContext.label). No exact due date was specified.",
      ].compactMap { $0 }.joined(separator: "\n")
    }
    return capture
  }

  /// True when the sentence is about time to work on something ("work on the report for 2 hours", "专注写方案"), not a
  /// reminder. Words that ask to be reminded win: "remind me to work on X at 3" is a reminder.
  static func isWorkTime(_ raw: String, hasLength: Bool) -> Bool {
    let remind = #"\bremind(?:er)?\b|\balert\s+me\b|\bping\s+me\b|\bnotify\s+me\b|提醒|通知我|叫我"#
    if raw.range(of: remind, options: [.regularExpression, .caseInsensitive]) != nil {
      return false
    }
    if hasLength { return true }
    return raw.range(
      of:
        #"\bwork(?:ing)?\s+on\b|\bfocus\s+(?:on|time)\b|\btime\s*block\b|\bblock\s+(?:out\s+)?(?:time|my)\b|专注|集中精力|安排时间"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  private static let eventWords = [
    "meeting", "meet ", "appointment", "lunch", "dinner", "breakfast", "brunch", "flight",
    "interview",
    "party", "class", "会议", "开会", "面试", "午饭", "晚饭", "早饭", "聚餐", "航班", "约会", "上课",
  ]

  /// Event: a time range, or meeting-like words. Everything else is a task (a repeat stays a repeating task).
  private static func kind(title: String, hour: Int?, duration: Int?, repeatRule: String?)
    -> Capture.Kind
  {
    if duration != nil { return .event }
    let lower = title.lowercased() + " "
    if eventWords.contains(where: { lower.contains($0) }) { return .event }
    return .task
  }

  // MARK: Helpers

  /// Shared complete list grammar for parsing and leading temporal request routing.
  static let chineseWeeklyDays =
    #"每(?:个|逢)?(?:周|星期|礼拜)[一二三四五六日天](?:\s*[、，,和及与]\s*(?:(?:每(?:个)?)?(?:周|星期|礼拜))?[一二三四五六日天])*"#
  private static let englishDay =
    #"(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tues|tue|wed|thurs|thur|thu|fri|sat)s?\b"#
  static let englishWeeklyDays =
    #"\bevery\s+"# + englishDay + #"(?:\s*(?:,\s*(?:and\s+)?|and\s+|&\s*)(?:every\s+)?"#
    + englishDay + #")*"#

  private static func takeWeeklyDays(from text: inout String) -> [Int] {
    let pattern = chineseWeeklyDays + "|" + englishWeeklyDays
    guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
    else { return [] }
    let phrase = String(text[range])
    text.replaceSubrange(range, with: " ")
    if phrase.contains("每") {
      return Array(Set(phrase.compactMap { chineseWeekdays[$0] })).sorted()
    }
    let lower = phrase.lowercased()
    return Array(
      Set(
        weekdayNames.compactMap { name, day in
          lower.range(of: "\\b" + name + "s?\\b", options: .regularExpression) == nil ? nil : day
        })
    ).sorted()
  }

  private static func weekday(_ name: String?) -> Int {
    let n = (name ?? "").lowercased()
    return weekdayNames.first { $0.0 == n }?.1 ?? 2
  }

  private static func chinese(_ s: String?) -> Int {
    s?.first.flatMap { chineseWeekdays[$0] } ?? 2
  }

  /// Next date with that weekday, strictly after today (or today itself when `allowToday`).
  private static func upcoming(
    _ weekday: Int, today: Date, calendar: Calendar, allowToday: Bool = false
  ) -> Date? {
    let current = calendar.component(.weekday, from: today)
    var diff = (weekday - current + 7) % 7
    if diff == 0 && !allowToday { diff = 7 }
    return calendar.date(byAdding: .day, value: diff, to: today)
  }

  /// That weekday in next week (weeks start on Monday).
  private static func nextWeek(_ weekday: Int, today: Date, calendar: Calendar) -> Date? {
    var cal = calendar
    cal.firstWeekday = 2
    guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start,
      let nextWeek = cal.date(byAdding: .day, value: 7, to: thisWeek)
    else { return nil }
    let index = (weekday - 2 + 7) % 7  // Monday = 0
    return cal.date(byAdding: .day, value: index, to: nextWeek)
  }

  /// This year's date, or next year's if it has already passed.
  private static func date(month: Int, day: Int, today: Date, calendar: Calendar) -> Date? {
    let year = calendar.component(.year, from: today)
    guard let d = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
      return nil
    }
    return d < today ? calendar.date(byAdding: .year, value: 1, to: d) : d
  }

  // MARK: Title cleanup

  /// Capture groups of the first match, without removing it.
  private static func peek(_ pattern: String, in text: String) -> [String?]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (1..<max(m.numberOfRanges, 1)).map { i in
      Range(m.range(at: i), in: text).map { String(text[$0]) }
    }
  }

  private static let leadingFillers = [
    #"^(?:(?:um+|uh+|er+|emm+|hmm+|ok(?:ay)?|so|well|hey|hi|yo|basically|actually|like)[,.]?\s+)+"#,
    #"^(?:(?:can|could|would|will)\s+(?:you|u)\s+)?(?:please\s+|pls\s+)?(?:(?:add|put|set|schedule|book|make|create)(?:\s+in|\s+up)?\s+(?:a\s+|an\s+|the\s+)?(?:reminder\s+(?:to|for)\s+|thing\s*,?\s*)?)?"#,
    #"^(?:i\s+)?(?:need|have|got|want|gotta|should|must)(?:\s+to)?\s+"#,
    #"^gotta\s+"#,
    #"^remind\s+me\s+(?:to\s+)?"#,
    #"^(?:set\s+(?:an?\s+)?)?(?:alarm|timer)\s+(?:for|to)\s+(?:the\s+)?"#,
    #"^wake\s+me\s+(?:up\s+)?(?:for|to)\s+(?:the\s+)?"#,
    #"^(?:can|could)\s+(?:you|u)\s+(?:please\s+)?"#,
    #"^(?:对了|嗯+|呃+|啊|哦|emm+|那个|就是|麻烦(?:你)?|帮我|请|记得|别忘了|不要忘记|提醒我|提醒一下|我要|我得|我需要|需要)[，,]?\s*"#,
  ]
  private static let trailingFillers = [
    #"\s*(?:谢谢|多谢|thanks?|thank you|please|pls|吧|啦|哈|呀|哦|呢|啊|i think|i guess|or something)[\s!！.。~]*$"#,
    #"\s*提醒我$"#,
    #"[,，\s]+remind me[.!]*$"#,
  ]

  /// Clean request syntax without rewriting the requested action or its modality.
  /// Also accepts model titles whose time words have already been removed.
  public static func cleanRequestTitle(_ title: String) -> String {
    var text = title
    // Generated Chinese wrappers describe the request, not the task itself.
    if let start = text.range(of: #"^(?:请|帮我)?(?:设置|设定|创建|添加)"#, options: .regularExpression),
      let end = text.range(of: #"的提醒(?:事项)?[。.!！]*$"#, options: .regularExpression),
      start.upperBound < end.lowerBound
    {
      text = String(text[start.upperBound..<end.lowerBound])
    }
    while true {
      let previous = text
      text = text.trimmingCharacters(in: titleBoundary)
      text = stripTemporalConnector(text)
      if let body = requestBody(text) { text = body }
      if text == previous { return text }
    }
  }

  private static let titleBoundary = CharacterSet.whitespacesAndNewlines
    .union(CharacterSet(charactersIn: ",，。.、:：;；!！?？~"))

  private static func stripTemporalConnector(_ title: String) -> String {
    // A removed clock time can leave "的时候提醒我…" at the start. Do not remove
    // a condition inside the action ("下雨的时候带伞") or "时候到了检查烤箱".
    title.replacingOccurrences(
      of: #"^的时候(?:吧)?[，,\s]*(?:就\s*(?=提醒))?"#, with: "", options: .regularExpression)
  }

  private static func requestBody(_ title: String) -> String? {
    if let body = CaptureLeadIn.strip(title) { return body }
    let pattern =
      #"^(?:(?:请|麻烦(?:你)?|帮我)\s*)*提醒(?:我|一下|(?=\s))\s*|^(?:(?:can|could|would|will)\s+(?:you|u)\s+)?(?:please\s+|pls\s+)?remind\s+me\b\s*(?:to\b\s*)?"#
    guard let range = title.range(of: pattern, options: [.regularExpression, .caseInsensitive])
    else { return nil }
    let body = title[range.upperBound...].trimmingCharacters(in: titleBoundary)
    return body.isEmpty ? nil : body
  }

  /// What is left of a line once date, time and repeat words are gone: no filler words, no deadline leftovers, no emoji.
  private static func cleanTitle(_ title: String, raw: String) -> String {
    var t = String(
      title.unicodeScalars.filter {
        !($0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x200D)
      })
    t = t.replacingOccurrences(
      of: #"\b(?:sometime|kind of|sort of)\b"#, with: " ",
      options: [.regularExpression, .caseInsensitive])
    for (abbr, full) in [
      (#"\bappts?\b"#, "appointment"), (#"\bmtg\b"#, "meeting"), (#"\bw/"#, "with"),
    ] {
      t = t.replacingOccurrences(
        of: abbr, with: full, options: [.regularExpression, .caseInsensitive])
    }
    // A part of the day with no clock time is not part of the thing itself.
    t = t.replacingOccurrences(
      of: #"\b(?:in the |this )?(?:morning|afternoon|evening|tonight)\b"#, with: " ",
      options: [.regularExpression, .caseInsensitive])
    t = t.replacingOccurrences(
      of: #"(?:^|\s)(?:早上|上午|下午|晚上|中午|大概|左右|差不多)(?=\s|$)"#, with: " ", options: .regularExpression)
    t = t.replacingOccurrences(
      of: #"\s(?:左右|大概|ish)(?=\s|$)|^(?:左右|大概)\s"#, with: " ",
      options: [.regularExpression, .caseInsensitive])
    let deadlineWord =
      raw.range(
        of: #"[周号日天点底末礼拜\d](?:之?前|以前)|\bby\b|\bbefore\b|之前"#,
        options: [.regularExpression, .caseInsensitive]) != nil
    var changed = true
    // "帮我增加一个 reminder 吧：我需要…": the lead-in goes, and what the user wrote after it is kept as it is.
    var hadLeadIn = false
    while changed {
      changed = false
      t = t.trimmingCharacters(in: titleBoundary)
      let withoutConnector = stripTemporalConnector(t)
      if withoutConnector != t {
        t = withoutConnector
        changed = true
      }
      if !hadLeadIn, let rest = requestBody(t) {
        t = rest
        hadLeadIn = true
        changed = true
      }
      for pattern in leadingFillers where !hadLeadIn && !isBookingAction(t) {
        if let r = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
          !r.isEmpty, r.lowerBound == t.startIndex
        {
          t.removeSubrange(r)
          changed = true
        }
      }
      for pattern in trailingFillers {
        if let r = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]), !r.isEmpty
        {
          t.removeSubrange(r)
          changed = true
        }
      }
      if deadlineWord {
        let tokens = t.split(separator: " ").map(String.init)
        var out: [String] = []
        for tok in tokens {
          if tok.hasPrefix("之前") {
            out.append(String(tok.dropFirst(2)))
          } else if tok.hasPrefix("前"), let next = tok.dropFirst().first,
            !"任男女夫台后天年面期景".contains(next)
          {
            out.append(String(tok.dropFirst()))
          } else if tok == "前" || tok == "之前" {
            continue
          } else {
            out.append(tok)
          }
        }
        let joined = out.filter { !$0.isEmpty }.joined(separator: " ")
        if joined != t {
          t = joined
          changed = true
        }
      }
      t = t.split(separator: " ").filter {
        !["那个", "就是", "嗯", "呃", "uh", "um", "like"].contains($0.lowercased())
      }.joined(separator: " ")
      let trimmed = trimConnectors(t)
      if trimmed != t {
        t = trimmed
        changed = true
      }
    }
    return t.trimmingCharacters(in: titleBoundary)
  }

  /// Connector words that a removed date or time leaves dangling: "…车库去，然后 的时候提醒我…" (the time sat between them),
  /// "Call mom and", "then buy milk". Only words at the ends of the title, or at the start of a word that follows the gap
  /// a removed time left, so "下雨的时候带伞" keeps its own "的时候".
  private static func trimConnectors(_ title: String) -> String {
    let alone: Set<String> = ["然后", "的时候", "时候", "then", "and", "and then", "接着"]
    var tokens = title.split(separator: " ").map(String.init)
    while let first = tokens.first, tokens.count > 1, alone.contains(first.lowercased()) {
      tokens.removeFirst()
    }
    while let last = tokens.last, tokens.count > 1, alone.contains(last.lowercased()) {
      tokens.removeLast()
    }
    func isCJKEnd(_ s: String) -> Bool {
      guard let u = s.unicodeScalars.last else { return false }
      return (0x4E00...0x9FFF).contains(u.value) || "，。、；：！？".unicodeScalars.contains(u)
    }
    var out: [String] = []
    for (i, token) in tokens.enumerated() {
      var tok = token
      var glue = false
      if i > 0, let p = ["的时候", "时候"].first(where: { tok.hasPrefix($0) && tok.count > $0.count }) {
        tok = String(tok.dropFirst(p.count))
        glue = true
      }
      if glue, let prev = out.last, isCJKEnd(prev), let c = tok.unicodeScalars.first,
        (0x4E00...0x9FFF).contains(c.value)
      {
        out[out.count - 1] = prev + tok
      } else {
        out.append(tok)
      }
    }
    var result = out.joined(separator: " ")
    for p in [
      #"^(?:然后|接着)[，,]?\s*(?=\S)"#, #"(?<=\S)[，,]?\s*(?:然后|接着)$"#,
      #"(?i)^(?:and\s+then|then|and)\s+(?=\S)"#, #"(?i)(?<=\S)\s+(?:and\s+then|then|and)$"#,
    ] {
      result = result.replacingOccurrences(of: p, with: "", options: .regularExpression)
    }
    return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,，。.、"))
  }

  // MARK: Chinese numerals, month days, relative times

  private static let englishHours: [String: Int] = [
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
  ]

  /// "three pm" → "3 pm"; "to like four thirty" → "at 4:30"; "at five" → "at 5". Only after a time preposition or before am/pm,
  /// so "one more thing" and "at one point" stay words.
  private static func normalizeEnglishClock(_ text: String) -> String {
    let words = englishHours.keys.joined(separator: "|")
    let minutes = [
      "thirty": ":30", "fifteen": ":15", "forty five": ":45", "forty-five": ":45", "o'clock": "",
      "oclock": "",
    ]
    var s = text
    func rewrite(_ pattern: String, _ build: (NSTextCheckingResult, NSString) -> String) {
      guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return
      }
      var ns = s as NSString
      for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
        ns = ns.replacingCharacters(in: m.range, with: build(m, ns)) as NSString
      }
      s = ns as String
    }
    // "half past six", "quarter past four", "quarter to eight"
    rewrite(
      #"\b(?:at|around|about|by|until|till)?\s*(?:like\s+)?(half|quarter)\s+(past|to)\s+("# + words
        + #"|\d{1,2})\b"#
    ) { m, ns in
      let kind = ns.substring(with: m.range(at: 1)).lowercased()
      let dir = ns.substring(with: m.range(at: 2)).lowercased()
      let hs = ns.substring(with: m.range(at: 3)).lowercased()
      let h = Int(hs) ?? englishHours[hs] ?? 0
      if dir == "past" { return "at \(h):" + (kind == "half" ? "30" : "15") }
      return "at \((h + 10) % 12 + 1):" + (kind == "half" ? "30" : "45")
    }
    // Military time: "1700前", "alarm 0545", "at 1830".
    rewrite(
      #"(?:(?<![\d:/.,$-])(?:(?:at|by|alarm|before|until|@)\s*)(?:[01]\d|2[0-3])[0-5]\d(?!\d))|(?:(?<![\d:/.,$-])(?:[01]\d|2[0-3])[0-5]\d(?=前))"#
    ) { m, ns in
      let raw = ns.substring(with: m.range)
      let digits = raw.filter(\.isNumber)
      let prefix = raw.hasPrefix(digits) ? "" : String(raw.prefix(raw.count - digits.count))
      return prefix + String(digits.prefix(2)) + ":" + String(digits.suffix(2))
    }
    // "three pm"
    rewrite(#"\b("# + words + #")\s*(a\.?m\.?|p\.?m\.?)(?![a-z])"#) { m, ns in
      "\(englishHours[ns.substring(with: m.range(at: 1)).lowercased()] ?? 0) "
        + ns.substring(with: m.range(at: 2))
    }
    // "at five", "to like four thirty", "around six o'clock"
    let after =
      #"(?=\s*(?:$|[,.!?;:)]|(?:am|pm|on|tomorrow|today|tonight|instead|please|thanks|then|and|for|with|in|i|ish)\b))"#
    rewrite(
      #"\b(?:at|to|by|around|about|until|till)\s+(?:(?:like|uh|um|er)\s+)*("# + words
        + #")(?:\s+(thirty|fifteen|forty[- ]five|o'?clock))?"# + after
    ) { m, ns in
      let h = englishHours[ns.substring(with: m.range(at: 1)).lowercased()] ?? 0
      let mm =
        m.range(at: 2).location == NSNotFound
        ? "" : (minutes[ns.substring(with: m.range(at: 2)).lowercased()] ?? "")
      return "at \(h)\(mm)"
    }
    // "6:30 in the morning" → "6:30 am"; "at 7 in the evening" → "at 7 pm"
    rewrite(#"(\d{1,2}(?::\d{2})?)\s*(?:in the |this )?(morning)\b"#) { m, ns in
      ns.substring(with: m.range(at: 1)) + " am"
    }
    rewrite(#"(\d{1,2}(?::\d{2})?)\s*(?:in the |this |at )?(afternoon|evening|night)\b"#) { m, ns in
      ns.substring(with: m.range(at: 1)) + " pm"
    }
    return s
  }

  private static let digits: [Character: Int] = [
    "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
  ]

  /// 0–99: 九, 十, 十二, 二十, 二十三.
  private static func chineseNumber(_ s: String) -> Int? {
    if let ten = s.firstIndex(of: "十") {
      let left = s[s.startIndex..<ten]
      let right = s[s.index(after: ten)...]
      guard left.count <= 1, right.count <= 1 else { return nil }
      let l = left.isEmpty ? 1 : digits[left.first!]
      let r = right.isEmpty ? 0 : digits[right.first!]
      guard let l, let r, l >= 1 else { return nil }
      return l * 10 + r
    }
    guard s.count == 1 else { return nil }
    return digits[s.first!]
  }

  /// 七点半 → 7点半, 十点十分 → 10点10分, 下个月三号 → 下个月3号, 十月二十日 → 10月20日. "一点" only counts as a clock time after a period word or 到/至/在/约/于
  /// (so "晚一点" stays a phrase).
  private static func normalizeChinese(_ text: String) -> String {
    var s = text.replacingOccurrences(of: "点一刻", with: "点15分").replacingOccurrences(
      of: "点三刻", with: "点45分"
    )
    .replacingOccurrences(of: "点钟", with: "点")
    // 早八 / 晚七 = 早上8点 / 晚上7点
    if let re = try? NSRegularExpression(pattern: #"([早晚])([五六七八九十]|十一|十二)(?![点分一二三四五六七八九十])"#) {
      var ns = s as NSString
      for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
        let n = chineseNumber(ns.substring(with: m.range(at: 2))) ?? 0
        ns =
          ns.replacingCharacters(
            in: m.range, with: (ns.substring(with: m.range(at: 1)) == "早" ? "早上" : "晚上") + "\(n)点")
          as NSString
      }
      s = ns as String
    }
    func replace(_ pattern: String, _ transform: (NSString, NSTextCheckingResult) -> String?) {
      guard let re = try? NSRegularExpression(pattern: pattern) else { return }
      var result = s as NSString
      for m in re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
        .reversed()
      {
        if let r = transform(result, m) {
          result = result.replacingCharacters(in: m.range(at: 1), with: r) as NSString
        }
      }
      s = result as String
    }
    let allowedBeforeOne = [
      "上午", "下午", "中午", "晚上", "凌晨", "早上", "清晨", "早晨", "傍晚", "到", "至", "在", "约", "于", "改到", "提前到",
    ]
    replace(#"([零一二两三四五六七八九十]{1,3})(?:点|号|月)"#) { str, m in
      let numeral = str.substring(with: m.range(at: 1))
      let end = m.range.location + m.range.length
      let unit = str.substring(with: NSRange(location: end - 1, length: 1))
      if unit == "号", end < str.length,
        "楼线门口店".contains(str.substring(with: NSRange(location: end, length: 1)))
      {
        return nil
      }
      if numeral == "一", unit == "点" {
        let before = str.substring(to: m.range.location)
        if !before.trimmingCharacters(in: .whitespaces).isEmpty,
          !allowedBeforeOne.contains(where: { before.hasSuffix($0) })
        {
          return nil
        }
      }
      return chineseNumber(numeral).map(String.init)
    }
    replace(#"(?<=月)([一二三四五六七八九十]{1,3})(?=[日号])"#) { str, m in
      chineseNumber(str.substring(with: m.range(at: 1))).map(String.init)
    }
    replace(#"(?<=点)((?:[二三四五]十[一二三四五六七八九]?)|(?:十[一二三四五六七八九]))"#) { str, m in
      chineseNumber(str.substring(with: m.range(at: 1))).map(String.init)
    }
    replace(#"(?<=点)(零[一二三四五六七八九])"#) { str, m in
      String(digits[str.substring(with: m.range(at: 1)).last!] ?? 0)
    }
    replace(#"(?<=点)([一二三四五六七八九十]{1,3})(?=分)"#) { str, m in
      chineseNumber(str.substring(with: m.range(at: 1))).map(String.init)
    }
    // 差一刻三点 = 2点45分, 差五分八点 = 7点55分
    if let re = try? NSRegularExpression(pattern: #"差(一刻|\d{1,2}分|[五十]分)\s*(\d{1,2})\s*点"#) {
      var ns = s as NSString
      for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
        let what = ns.substring(with: m.range(at: 1))
        let missing =
          what == "一刻" ? 15 : (Int(what.filter(\.isNumber)) ?? (what.hasPrefix("五") ? 5 : 10))
        let h = Int(ns.substring(with: m.range(at: 2))) ?? 0
        ns =
          ns.replacingCharacters(in: m.range, with: "\((h + 10) % 12 + 1)点\(60 - missing)分")
          as NSString
      }
      s = ns as String
    }
    return s
  }

  /// The action after a leading relative time, using the same vocabulary as date extraction.
  /// A time inside a story does not qualify: removing it must leave an unchanged suffix.
  static func actionAfterLeadingRelativeTime(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var remainder = text
    guard takeRelativeMinutes(from: &remainder) != nil else { return nil }
    let action = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !action.isEmpty, action != text, text.hasSuffix(action) else { return nil }
    return action
  }

  static func hasRelativeTime(_ raw: String) -> Bool {
    var text = raw
    return takeRelativeMinutes(from: &text) != nil
  }

  /// Minutes from now for "30分钟后", "半小时后", "一个半小时后", "in 2 hours", "in an hour", "in half an hour". Removes the match.
  private static func takeRelativeMinutes(from text: inout String) -> Int? {
    let num = #"\d+|[零一二两三四五六七八九十]{1,3}"#
    if let m = take(
      #"(?<![0-9A-Za-z])(\d+)\s*(hours?|hrs?|h|minutes?|mins?|m)\s*(?:以后|之后|后)"#, from: &text),
      let n = Int(m[0] ?? ""), n <= 525600
    {
      return n * ((m[1] ?? "").lowercased().hasPrefix("h") ? 60 : 1)
    }
    if let m = take(
      #"\b(?:set\s+(?:a\s+)?)?timer\s+(?:for\s+)?(\d+)\s*(hours?|hrs?|minutes?|mins?)\b"#,
      from: &text), let n = Int(m[0] ?? "")
    {
      return n * ((m[1] ?? "").hasPrefix("h") ? 60 : 1)
    }
    if let m = take("(" + num + #")\s*个半小时\s*(?:以后|之后|后)"#, from: &text), let n = amount(m[0]) {
      return n * 60 + 30
    }
    if let m = take("(" + num + #"|半)\s*(?:个)?\s*(小时|钟头|分钟)\s*(?:以后|之后|后)"#, from: &text) {
      let unit = (m[1] ?? "").hasPrefix("分") ? 1 : 60
      if m[0] == "半" { return unit == 60 ? 30 : nil }
      return amount(m[0]).map { $0 * unit }
    }
    let words =
      "a|an|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty|forty-five"
    if take(#"\bin\s+half\s+an?\s+hour\b"#, from: &text) != nil { return 30 }
    if let m = take(
      #"\b(?:in|after)\s+(\d+|"# + words + #")\s*(hours?|hrs?|minutes?|mins?)\b"#, from: &text)
      ?? take(
        #"\b(\d+|"# + words + #")\s*(hours?|hrs?|minutes?|mins?)\s+(?:later|from\s+now)\b"#,
        from: &text)
    {
      let unit = (m[1] ?? "").hasPrefix("h") ? 60 : 1
      return amount(m[0]).map { $0 * unit }
    }
    return nil
  }

  /// The name of an alarm made from a sentence: the sentence without the instruction words.
  /// "Adding alarm after remind me to walking" → "Walking"; "叫我起床" → "起床". Empty → "Alarm".
  static func alarmLabel(_ title: String) -> String {
    var t = " " + title + " "
    let patterns = [
      #"\b(?:please\s+)?(?:add(?:ing)?|set(?:ting)?|create|make|start)\s+(?:an?\s+|the\s+)?(?:alarm|timer)\b(?:\s+(?:for|to|at|that))?"#,
      #"\b(?:alarm|timer)\s+(?:for|to|at)\b"#, #"\bremind\s+me\s+(?:to|about|of)?\b"#,
      #"\bwake\s+me(?:\s+up)?\b"#,
      #"\b(?:alarm|timer|after|later|from\s+now)\b"#,
      #"(?:帮我)?(?:设(?:置)?|定|订|加)(?:一?个)?闹钟"#, "闹钟", #"提醒(?:我|一下|(?=\s))\s*"#, "叫醒我", "叫我(?=起床)",
    ]
    for p in patterns {
      t = t.replacingOccurrences(of: p, with: " ", options: [.regularExpression, .caseInsensitive])
    }
    t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: " ,，.。:：-"))
    guard let first = t.first else { return "Alarm" }
    return first.uppercased() + t.dropFirst()
  }

  /// "两个小时", "半小时", "一个半小时", "90分钟", "for 2 hours", "2-hour", "half an hour" → minutes. Not "...后" (that is a relative time).
  private static func takeDurationMinutes(from text: inout String) -> Int? {
    let num = #"\d+|[零一二两三四五六七八九十]{1,3}"#
    if let m = take("(" + num + #")\s*个半(?:小时|钟头)(?!\s*(?:以后|之后|后))"#, from: &text),
      let n = amount(m[0])
    {
      return n * 60 + 30
    }
    if let m = take("(" + num + #"|半)\s*(?:个)?\s*(小时|钟头|分钟)(?!\s*(?:以后|之后|后))(?:的)?"#, from: &text)
    {
      let unit = (m[1] ?? "").hasPrefix("分") ? 1 : 60
      if m[0] == "半" { return unit == 60 ? 30 : nil }
      return amount(m[0]).map { $0 * unit }
    }
    if take(#"\b(?:for\s+)?half\s+an?\s+hour\b"#, from: &text) != nil { return 30 }
    let words = "a|an|one|two|three|four|five|six|ten|fifteen|twenty|thirty|forty-five|ninety"
    if let m = take(
      #"\b(?:for\s+)?(\d+|"# + words + #")[\s-]*(hours?|hrs?|minutes?|mins?)\b"#, from: &text)
    {
      let unit = (m[1] ?? "").hasPrefix("h") ? 60 : 1
      return amount(m[0]).map { $0 * unit }
    }
    return nil
  }

  private static func amount(_ s: String?) -> Int? {
    guard let s else { return nil }
    if let n = Int(s) { return n }
    if let n = chineseNumber(s) { return n }
    let words: [String: Int] = [
      "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
      "eight": 8,
      "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
      "forty-five": 45,
    ]
    return words[s.lowercased()]
  }

  /// The `n`th of this month if it hasn't passed (offset nil) or of the month `offset` months ahead; nil if the month is too short.
  private static func dayInMonth(_ n: Int, offset: Int?, today: Date, calendar: Calendar) -> Date? {
    guard (1...31).contains(n), let start = calendar.dateInterval(of: .month, for: today)?.start
    else { return nil }
    func make(_ months: Int) -> Date? {
      guard let base = calendar.date(byAdding: .month, value: months, to: start),
        let days = calendar.range(of: .day, in: .month, for: base)?.count, n <= days
      else { return nil }
      return calendar.date(byAdding: .day, value: n - 1, to: base)
    }
    if let offset { return make(offset) }
    if n >= calendar.component(.day, from: today), let d = make(0) { return d }
    return make(1)
  }

  private static func monthEnd(offset: Int, today: Date, calendar: Calendar) -> Date? {
    guard let start = calendar.dateInterval(of: .month, for: today)?.start,
      let base = calendar.date(byAdding: .month, value: offset, to: start),
      let days = calendar.range(of: .day, in: .month, for: base)?.count
    else { return nil }
    return calendar.date(byAdding: .day, value: days - 1, to: base)
  }

  private static func adjust(_ hour: Int?, period: String?) -> Int? {
    guard var h = hour else { return nil }
    switch period?.lowercased() {
    case "pm"?, "下午"?, "晚上"?, "傍晚"?: if h < 12 { h += 12 }
    case "中午"?: if h < 11 { h += 12 }
    case "am"?, "上午"?, "早上"?, "凌晨"?, "清晨"?, "早晨"?: if h == 12 { h = 0 }
    case nil: if (1...6).contains(h) { h += 12 }  // "3点开会" / "at 4" almost always means PM
    default: break
    }
    return h
  }

  /// Finds the first match, removes it from `text`, and returns its capture groups.
  private static func take(_ pattern: String, from text: inout String) -> [String?]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let whole = Range(m.range, in: text)
    else { return nil }
    let groups = (1..<max(m.numberOfRanges, 1)).map { i -> String? in
      Range(m.range(at: i), in: text).map { String(text[$0]) }
    }
    text.replaceSubrange(whole, with: " ")
    return groups
  }
}

/// Title-only content cleanup by rules (the parser's last step). No model.
public enum CaptureTitleRefinement {
  public static func fallback(_ capture: Capture, source: String) -> Capture {
    var result = capture
    var title = CaptureParser.cleanRequestTitle(capture.title)
    // Explicit notes use the same content path as motivation, preserving existing notes.
    // Read the note from the original request so scheduling extraction cannot alter its text.
    let noteLabel = #"[，,;；]\s*(?:备注(?:写|为|是)?\s*[:：]?|(?i:notes?)\s*[:：])\s*"#
    if let marker = source.range(of: noteLabel, options: .regularExpression),
      !insideQuotedText(source, at: marker.lowerBound)
    {
      let note = String(source[marker.upperBound...]).trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: "。"))
      if !note.isEmpty {
        if let label = title.range(of: noteLabel, options: .regularExpression) {
          let action = String(title[..<label.lowerBound]).trimmingCharacters(
            in: .whitespacesAndNewlines)
          if !action.isEmpty { title = action }
        }
        if let existing = result.notes, !existing.isEmpty {
          if !existing.contains(note) { result.notes = existing + "\n" + note }
        } else {
          result.notes = note
        }
      }
    }
    let motive =
      #"[，,。;；]\s*(?:因为|我需要|我想|这样|以便|(?i:because\b|so that\b|I need to\b|I want to\b|I am allergic\b))"#
    if let range = title.range(of: motive, options: .regularExpression) {
      let action = String(title[..<range.lowerBound]).trimmingCharacters(
        in: .whitespacesAndNewlines)
      if !action.isEmpty {
        result.title = action
        result.notes = retainedNotes(result.notes, source: source)
      }
    } else {
      result.title = title
    }
    result.title = result.title.replacingOccurrences(
      of: #"^not to\s+"#, with: "Do not ", options: [.regularExpression, .caseInsensitive])
    // A narrow offline normalization for an explicit watch + sleep purpose, not a general semantic model.
    // We describe the requested action, never promise a score or a device capability.
    if source.localizedCaseInsensitiveContains("Apple Watch"),
      source.range(of: "(?:测量|记录|监测|追踪).{0,12}睡眠", options: .regularExpression) != nil,
      source.range(of: "不|别|禁止|关闭|停止", options: .regularExpression) == nil,
      result.title.range(
        of: #"^(?:带上|戴上|佩戴)\s*Apple\s*Watch$"#, options: [.regularExpression, .caseInsensitive])
        != nil
    {
      result.title = "佩戴Apple Watch记录睡眠"
      result.notes = retainedNotes(result.notes, source: source)
    }
    return result
  }

  private static func insideQuotedText(_ text: String, at index: String.Index) -> Bool {
    let prefix = text[..<index]
    // A note label inside an explicitly quoted name belongs to that name.
    return prefix.filter { $0 == "\"" }.count % 2 == 1
      || prefix.filter { $0 == "“" }.count > prefix.filter { $0 == "”" }.count
      || prefix.filter { $0 == "「" }.count > prefix.filter { $0 == "」" }.count
  }

  private static func retainedNotes(_ notes: String?, source: String) -> String {
    guard let notes, !notes.isEmpty, notes != source else { return source }
    return notes.contains(source) ? notes : notes + "\n" + source
  }

}
