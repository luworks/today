import Foundation

/// Multi-turn rules for FastLane's own preview card, as plain functions so they can be tested without a
/// model or a UI: the next message is first read as an answer to the open preview, and only becomes a new
/// item when it is not one. Nothing here writes data: it only edits the preview that is already on screen.
public enum Dialogue {
  private static func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// A sentence that asks for something NEW ("remind me to ...", "提醒我 ...", "don't forget ..."). It is never the answer to a
  /// "which one?" question and is not an edit of an existing item, unless the words name one of the user's own items.
  static func startsNewItem(_ text: String) -> Bool {
    has(
      text,
      #"提醒我|提醒一下|提醒(?=\s+\S)|记得|别忘了|帮我记|新建|添加|(?:增加|新增)\s*(?:一?个|一条)?\s*(?:reminder|提醒事项|提醒|待办事项|待办|任务)|加一个|加个|\bremind me\b|\bdon'?t forget\b|\bnew (?:reminder|task|event)\b|\badd (?:a |an )?(?:reminder|task|event|to-?do)\b|\bset (?:a |an )?reminder\b"#
    )
  }

  // MARK: Changing the preview card

  public enum Refinement: Equatable {
    case updated(Capture)
    /// The user asked for an alarm but the preview has no time to ring at.
    case needsTime
    /// "No", "never mind", "算了": drop the preview.
    case dismissed
    case notARefinement
  }

  /// Words that only carry an instruction about the preview ("make it", "改成", "instead").
  private static let filler =
    #"make (?:it|that) repeat|keeping|\brepeat\b|\bthat\b|actually|make it|change (?:it )?to|set (?:it )?to|move (?:it )?to|should be|instead|please|rather|no,?|oh,?|and|as|for|it|the|to|at|on|改成|改到|改为|换成|设为|设成|还是|不是|应该是|应该|是|要|吧|啊|呢|的|,|，|。|\.|!"#

  /// Reads a follow-up as an edit of the preview: "make it an alarm", "改成下午4点", "tomorrow instead", "call it Quarterly report".
  /// A message that has its own action text ("Call Mia at 5pm") is not a refinement, even though it has a time.
  public static func refine(
    _ capture: Capture, with raw: String, now: Date = .now, calendar: Calendar = .current
  ) -> Refinement {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if has(text, #"^(?:no|nope|cancel|never ?mind|forget it|算了|不用了|取消|不要了)[.!。！]?$"#) {
      return .dismissed
    }

    if !CaptureConversation.referencesAlarm(text),
      startsNewItem(text)
        || has(
          text, #"^(?:(?:please|can you|could you)\s+)?(?:set|add|create)\s+(?:an?\s+)?alarm\b"#)
    {
      return .notARefinement
    }

    // Rename: "call it X", "rename it to X", "标题改成X".
    if let range = text.range(
      of:
        #"(?:call it|rename (?:it )?(?:to)?|title (?:it|to)|叫做|改名(?:为|成)|标题(?:改成|改为|是))\s*[:：]?\s*"#,
      options: [.regularExpression, .caseInsensitive])
    {
      let name = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty {
        var c = capture
        c.title = name
        return .updated(c)
      }
    }

    var c = capture
    var changed = false
    var rest = text
    // In an explicit "not <old clock>, change to <new clock>" correction, the
    // rejected clock is context, never the replacement parsed below.
    if let prefix = rest.range(
      of: #"^不是([^，,]+)[，,]\s*(?=改成|改到|改为|换成)"#, options: .regularExpression)
    {
      let rejected = String(rest[prefix]).replacingOccurrences(
        of: #"^不是|[，,]\s*$"#, with: "", options: .regularExpression)
      if isOnlyWhen(rejected, now: now, calendar: calendar) { rest.removeSubrange(prefix) }
    }
    // A trailing "keep these weekdays" is a constraint, not a new date.
    // Remove it only when it names exactly the preview's existing weekday set.
    let weekdayList = #"(?:周|星期|礼拜)[一二三四五六日天](?:\s*[、和及与]\s*(?:(?:周|星期|礼拜))?[一二三四五六日天])*"#
    if let suffix = rest.range(
      of: #"[，,]\s*("# + weekdayList + #")都保留[。.!！]*$"#, options: .regularExpression)
    {
      let clause = String(rest[suffix]).trimmingCharacters(
        in: CharacterSet(charactersIn: "，,。.!！ "))
      let named = CaptureParser.parse(
        "每" + clause.replacingOccurrences(of: "都保留", with: ""), now: now, calendar: calendar)
      let current: RepeatRule? = capture.repeatRule.flatMap(RepeatRule.init(rawValue:))
      let expected: RepeatRule?
      if current == .weekdays {
        expected = .weeklyOn([2, 3, 4, 5, 6])
      } else if current == .weekly {
        expected = .weeklyOn([calendar.component(.weekday, from: capture.day)])
      } else {
        expected = current
      }
      if named.repeatRule.flatMap(RepeatRule.init(rawValue:)) == expected, expected != nil {
        rest.removeSubrange(suffix)
      }
    }

    // Kind: alarm / event / task.
    let wantsAlarm = has(text, #"alarm|wake me|闹钟|叫我起床|叫醒"#)
    let wantsEvent = !wantsAlarm && has(text, #"\bevent\b|\bmeeting\b|appointment|日程|会议|日历"#)
    let wantsTask =
      !wantsAlarm && !wantsEvent && has(text, #"\btask\b|\bto-?do\b|reminder|待办|任务|提醒"#)
    if wantsAlarm {
      // Words like "an alarm" are the instruction, not a time; the time (if any) is read below.
      let said = CaptureParser.parse(text, now: now, calendar: calendar)
      if let h = said.hour {
        c.hour = h
        c.minute = said.minute
      }
      guard c.hour != nil else { return .needsTime }
      c.kind = .task
      c.ringsAsAlarm = true
      c.isAllDay = false
      changed = true
    } else if wantsEvent {
      c.kind = .event
      c.ringsAsAlarm = false
      changed = true
    } else if wantsTask {
      c.kind = .task
      c.ringsAsAlarm = false
      changed = true
    }
    rest = rest.replacingOccurrences(
      of:
        #"alarm|wake me( up)?|闹钟|叫我起床|叫醒|event|meeting|appointment|日程|会议|日历|task|to-?do|reminder|待办|任务|提醒|\ban?\b|\bone\b"#,
      with: " ", options: [.regularExpression, .caseInsensitive])

    // Day / time / repeat: only the parts the message gives replace the old ones.
    let absolute = CaptureParser.parse(rest, now: calendar.startOfDay(for: now), calendar: calendar)
    let fromNow = CaptureParser.parse(rest, now: now, calendar: calendar)
    // Absolute clock changes preserve a chosen day; an undated alarm uses the next
    // occurrence from the real clock, just like a direct alarm request.
    let parsed =
      absolute.hour != fromNow.hour || absolute.minute != fromNow.minute
        || (capture.ringsAsAlarm && !capture.hasDay) ? fromNow : absolute
    if parsed.hasDay {
      c.day = parsed.day
      c.hasDay = true
      changed = true
    }
    if let h = parsed.hour, !wantsAlarm {
      c.hour = h
      c.minute = parsed.minute
      changed = true
    }
    if parsed.repeatRule != nil {
      c.repeatRule = parsed.repeatRule
      changed = true
    }
    if let d = parsed.durationMinutes {
      c.durationMinutes = d
      changed = true
    }
    if wantsAlarm, parsed.hasDay { c.hasDay = true }

    // Anything left over is its own text: this is a new item, not an edit of the preview.
    // (The parser falls back to the whole text when nothing is left of the title.)
    var leftover =
      parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        == CaptureParser.cleanRequestTitle(rest) && changed ? "" : parsed.title
    if parsed.hasDay || parsed.hour != nil || parsed.repeatRule != nil || changed {
      leftover = leftover.replacingOccurrences(
        of: "(?:\(filler))", with: " ", options: [.regularExpression, .caseInsensitive])
    }
    leftover = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
    if changed && leftover.isEmpty { return .updated(c) }
    return .notARefinement
  }

  /// True for a message that only gives a day and/or time ("5pm", "tomorrow instead", "改成下午4点").
  public static func isOnlyWhen(_ text: String, now: Date = .now, calendar: Calendar = .current)
    -> Bool
  {
    let probe = Capture(title: "_", day: calendar.startOfDay(for: now), hasDay: false, hour: nil)
    guard case .updated(let r) = refine(probe, with: text, now: now, calendar: calendar) else {
      return false
    }
    return r.kind == probe.kind && !r.ringsAsAlarm && r.title == probe.title
      && (r.hasDay || r.hour != nil)
  }

  // MARK: Answering "when?"

  /// The new start for a "when should I move it to?" answer: "5pm", "tomorrow", "明天下午3点".
  /// A new request with its own action is not an answer, even when it contains a time.
  public static func answerTime(
    _ text: String, keeping old: Date?, now: Date = .now, calendar: Calendar = .current
  ) -> Date? {
    guard isOnlyWhen(text, now: now, calendar: calendar) else { return nil }
    let today = calendar.startOfDay(for: now)
    let parsed = CaptureParser.parse(text, now: today, calendar: calendar)
    guard parsed.hasDay || parsed.hour != nil else { return nil }
    let day = parsed.hasDay ? parsed.day : (old.map { calendar.startOfDay(for: $0) } ?? today)
    let oldTime = old.map { calendar.dateComponents([.hour, .minute], from: $0) }
    let hour = parsed.hour ?? oldTime?.hour ?? 9
    let minute = parsed.hour != nil ? parsed.minute : (oldTime?.minute ?? 0)
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
  }

  // MARK: Context for the model

}

/// Shared by the send path, deterministic fallback and model classifier. Resolves references only;
/// ordinary conversation never acquires an obligation merely because an older turn had a time.
public enum CaptureConversation {
  private static func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// Complete, subjectless requests to turn the current subject into an alarm. Own action text
  /// ("set an alarm to take medicine") is deliberately excluded and starts a new capture.
  static func referencesAlarm(_ raw: String) -> Bool {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return has(
      text,
      #"^(?:(?:no[, ]*|actually[, ]*|please\s+|just\s+|can you\s+|could you\s+|i need you to (?:help me )?\s*|i want you to\s+))*(?:(?:set|add|create|make)(?:\s+it)?\s+(?:me\s+)?(?:(?:an?|that)\s+)?alarm(?:\s+(?:for (?:it|that)|instead|please))?|make (?:it|that) an alarm)[.!?]*$|^(?:(?:没有|不是|不|就是|只要|就|请|可以|你|我需要|我想要|来|帮我|，|,|\s))*(?:加|设定|设置|设|定|创建)(?:一?个)?闹钟(?:就可以|就行|即可|吧|哦|啊|呢|了|。|！|!)*$"#
    )
  }

  /// These complete requests supply a kind, never a new subject or permission to write.
  static func referencesReminder(_ raw: String) -> Bool {
    has(
      raw.trimmingCharacters(in: .whitespacesAndNewlines),
      #"^(?:(?:就|只要|请|帮我|你|麻烦|\s))*(?:设定|设置|设|定|创建|添加|增加|新增|加)(?:一?个|一条)?\s*(?:reminder|提醒事项|提醒)(?:就行|就可以|吧)?[。.!！]*$|^(?:(?:please|just|no|actually)[, ]+)*(?:set|setting|add|create|make)(?: it)? (?:a |the |that )?reminder(?: for (?:it|that))?[.!]*$"#
    )
  }

  public static func isOneOffAnswer(_ text: String) -> Bool {
    has(text, #"^\s*(?:one[ -]?off|one time|just once|一次性|一次|单次)[。.!！]*\s*$"#)
  }

  private static func proceeds(_ text: String) -> Bool {
    has(text, #"^\s*(?:你做吧|你来吧|就这样做吧|do it|please do|go ahead)[。.!！]*\s*$"#)
  }

  private static func acknowledges(_ text: String) -> Bool {
    has(text, #"^\s*(?:够|够了|好的|好|嗯|ok|okay|enough|that's enough)[。.!！]*\s*$"#)
  }

  /// Explicit reminders are tasks even when their object contains event words (e.g. "don't eat dinner").
  public static func parse(_ text: String, now: Date, calendar: Calendar) -> Capture {
    var capture = CaptureParser.parse(text, now: now, calendar: calendar)
    if ChatRouting.intent(text) == .capture, ChatRouting.requestsEvent(text) {
      capture.kind = .event
      capture.ringsAsAlarm = false
    } else if ChatRouting.intent(text) == .capture, ChatRouting.requestsAlarm(text) {
      capture.kind = .task
      capture.ringsAsAlarm = true
    } else if ChatRouting.intent(text) == .capture,
      has(
        text,
        #"提醒我|(?:增加|新增|添加|创建|新建|加)(?:一?个|一条)?\s*(?:reminder|提醒事项|提醒)|\bremind me\b|\b(?:add|create|set) (?:a |an )?reminder\b"#
      ), !has(text, #"闹钟|\balarm\b|wake me"#)
    {
      capture.kind = .task
      capture.ringsAsAlarm = false
    }
    return capture
  }

  /// nil means the ordinary new-message path should handle this turn. Context is caller-owned,
  /// bounded, and contains only this thread. Assistant suggestions are never parsed as requests.
  public static func resolve(
    _ text: String, context: ConversationContext, pending: Capture?,
    now: Date = .now, calendar: Calendar = .current
  ) -> Capture? {
    let alarm = referencesAlarm(text)
    let reminder = referencesReminder(text)
    let once = isOneOffAnswer(text)
    let proceed = proceeds(text)
    let time = Dialogue.isOnlyWhen(text, now: now, calendar: calendar)
    guard alarm || reminder || once || proceed || (time && pending == nil) else { return nil }
    // An explicit existing-item edit must reach edit routing, not reconstruct another capture.
    if pending == nil, time, !alarm, !reminder, !proceed,
      Editing.looksLikeEdit(text, items: [], now: now, calendar: calendar)
    {
      return nil
    }
    var prior: Capture?
    var requested = false
    for turn in context.userTurns {
      let user = turn.text
      let anchor = turn.timestamp ?? now
      // An older timestamp-free turn cannot safely restart a relative countdown.
      if turn.timestamp == nil && CaptureParser.hasRelativeTime(user) {
        prior = nil
        requested = false
        continue
      }
      if ChatRouting.isContextQuestion(user) { continue }
      if referencesAlarm(user) {
        if prior == nil {
          prior = Capture(title: "Alarm", day: calendar.startOfDay(for: now), hasDay: false)
        }
        prior?.kind = .task
        prior?.ringsAsAlarm = true
        requested = true
      } else if referencesReminder(user) {
        prior?.kind = .task
        prior?.ringsAsAlarm = false
        requested = prior != nil
      } else if isOneOffAnswer(user), prior?.repeatRule == nil {
        continue
      } else if acknowledges(user) || proceeds(user) {
        // Keep the active user subject through short acknowledgments, without treating
        // them as creation requests. Unrelated conversation below still clears it.
        continue
      } else if let current = prior, Dialogue.isOnlyWhen(user, now: anchor, calendar: calendar),
        case .updated(let updated) = Dialogue.refine(
          current, with: user, now: anchor, calendar: calendar)
      {
        prior = updated
      } else {
        let intent = ChatRouting.intent(user)
        let parsed = parse(user, now: anchor, calendar: calendar)
        // A recent timed statement can supply the subject only after an explicit conversion.
        // Questions, quoted commands and completed reports never supply actionable context.
        let reported =
          intent != .capture
          && has(user, #"[\"“”「」]|\b(?:said|asked|already|yesterday)\b|说过|他说|她说|已经|昨天"#)
        if !reported
          && (intent == .capture || (parsed.hour != nil && !ChatRouting.isQuestion(user)))
        {
          prior = parsed
          requested = intent == .capture
        } else {
          prior = nil
          requested = false
        }
      }
    }
    if alarm {
      let incomplete = pending?.title == "Alarm" && pending?.hour == nil
      var result =
        (incomplete ? prior ?? pending : pending ?? prior)
        ?? Capture(title: "Alarm", day: calendar.startOfDay(for: now), hasDay: false)
      result.kind = .task
      result.ringsAsAlarm = true
      result.isAllDay = false
      return result
    }
    if reminder || proceed || once {
      guard requested || reminder, var result = pending ?? prior else { return nil }
      if once, result.repeatRule != nil { return nil }
      if reminder {
        result.kind = .task
        result.ringsAsAlarm = false
      }
      return result
    }
    guard requested, let prior,
      case .updated(let result) = Dialogue.refine(prior, with: text, now: now, calendar: calendar)
    else { return nil }
    return result
  }
}
