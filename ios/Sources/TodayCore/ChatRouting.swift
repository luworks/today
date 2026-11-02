import Foundation

/// Decide whether a NEW message asks for a planner item before extracting its kind or dates.
/// Uncertainty is a conversation, never permission to manufacture an obligation.
public enum ChatRouting {
  public enum Intent: Equatable, Sendable { case capture, conversation, unsure }

  private static func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// Use the same polite request boundary for creation and content-generation exclusions.
  private static func requestBody(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"^(?:(?:please|can you|could you|would you)\s+)+"#, with: "",
      options: [.regularExpression, .caseInsensitive])
  }

  /// An anchored event creation request; never a quoted or reported command.
  public static func requestsEvent(_ text: String) -> Bool {
    has(
      requestBody(text.trimmingCharacters(in: .whitespacesAndNewlines)),
      #"^(?:create|add|schedule) (?:a |an )?(?:calendar )?event\b|^new (?:calendar )?event\b"#)
  }

  /// Separate action clauses require separate previews; conjunctions inside an object do not.
  public static func hasMultipleActions(_ text: String) -> Bool {
    has(
      text,
      #"[;；\n]|然后|另外还|\band then\b|\band\s+(?:(?:then|also)\s+)?(?:remind me to\s+)?(?:buy|call|pay|send|email|submit|book|pick up|return|renew|clean|wash|write|finish|take|walk|water)\b"#
    )
  }

  /// Contradictory dates in one submitted request are not single-item write authority.
  public static func hasMaterialCorrection(_ text: String) -> Bool {
    has(
      text,
      #"(?:^|[,，])\s*(?:不对|说错了|纠正一下|更正一下)\s*[,，]|(?:^|[,，])\s*(?:no[, ]+wait|I mean)\b"#)
  }

  public static func requestsAlarm(_ text: String) -> Bool {
    // A standalone trailing kind marker is supported in mixed Chinese/English capture.
    if has(text, #"^提醒(?:我)?\s+.+\s+alarm[.!?]*$"#) { return true }
    return has(
      text,
      #"^(?:(?:please|can you|could you|would you)\s+)?(?:(?:set|create|add|make) (?:me )?(?:an? )?(?:alarm|timer)\b|wake me\b)|^(?:(?:请|可以|能不能|能|可不可以)(?:你)?(?:帮我)?|帮我)?(?:(?:设|定|加|创建).{0,12}(?:闹钟|计时器)|[明天早上晚今后午晨点分半零一二三四五六七八九十两0-9:：\s]*(?:叫醒我|叫我起床))"#
    )
  }

  /// Only complete, supported operation requests may bypass generic chat. The legacy matchers
  /// also find words inside explanations, so they are not sufficient at this boundary.
  public static func isSupportedOperationRequest(_ text: String) -> Bool {
    guard
      OverdueTidy.isRequest(text)
    else { return false }
    let body = requestBody(text.trimmingCharacters(in: .whitespacesAndNewlines))
    return has(
      body,
      #"^(?:(?:tidy(?: up)?|clean up|clear|reschedule|sort out) (?:my )?(?:\d+ )?overdue(?: reminders)?)\s*[.!?]*$|^(?:(?:整理|处理|清理)(?:\d+条)?(?:过期|逾期)(?:提醒)?)(?:好吗|可以吗)?[。！？?]*$"#
    )
  }

  // Match CaptureParser's weekday vocabulary as complete tokens, including Sunday 日/天.
  private static let chineseWeekday = #"(?:下下|下|这个?|本|每(?:个)?)?(?:周|星期|礼拜)[一二三四五六日天]"#
  private static let chineseTimeToken =
    #"(?:"# + #"每(?:个)?工作日|每(?:个)?周末|"# + CaptureParser.chineseWeeklyDays + "|" + chineseWeekday
    + #"|[明天早上下晚今后中午晨点分半零一二三四五六七八九十两0-9:：\s])"#

  /// Inspect the leading action, not action words inside the object of an explicit request.
  private static func isChineseReportedActionQuestion(_ text: String) -> Bool {
    let body = requestBody(text).replacingOccurrences(
      of: "^" + chineseTimeToken + #"*(?:的时候)?"#,
      with: "", options: .regularExpression)
    guard
      let verb = body.range(
        of: #"^(?:创建|添加|增加|新增|新建|提醒(?:我|一下)?)"#,
        options: .regularExpression)
    else { return false }
    let remainder = String(body[verb.upperBound...])
    // Attributive/past action plus an inquiry, or a completed action being confirmed.
    if has(remainder, #"^(?:的|了|过).*(?:什么|谁|哪(?:个|些|条|一)|多少|是否|是不是)"#) { return true }
    if has(remainder, #"^(?:了|过).*(?<!好)(?<!行)(?<!可以)吗[?？]*$"#) { return true }
    // A 没有/没 completion check describes this action only immediately after its verb.
    // Later checks can be the reminder's object, such as 确认报告提交了没有.
    if has(remainder, #"^(?:了|过)(?:没有|没)[?？]*$"#) { return true }
    if has(remainder, #"的是(?:谁|什么|哪(?:个|些|条|一))[?？]*$"#) { return true }
    guard has(remainder, #"(?:了|过)吗[?？]*$"#) else { return false }
    // A check/inquiry verb starts a subordinate question in the requested object. Leading
    // completed actions and relative-clause questions above still describe the reminder itself.
    let object = remainder.replacingOccurrences(
      of: #"^(?:(?:一个|一条|个|条)?提醒[，,：:]\s*)?"# + chineseTimeToken + "*",
      with: "", options: .regularExpression)
    return !has(object, #"^(?:确认|检查|问|询问|核实|查看|查明|看看)"#)
  }

  public static func intent(_ raw: String) -> Intent {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let month = CaptureParser.leadingMonth(text) {
      // A date prefix must not turn a question, completed booking or refusal into a task.
      if isQuestion(month.action)
        || has(
          month.action,
          #"^(?:已经|已|不要|不用|别|预约(?:了|好|过)|(?:I\s+)?already\b|booked\b|don't\b|do not\b)"#)
      {
        return .conversation
      }
      return intent(month.action)
    }
    if isContextQuestion(text) { return .conversation }
    // A complete leading clock phrase may introduce an explicit imperative.
    let withoutClock = text.replacingOccurrences(
      of: #"^(?:at\s+)?[0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)\s*(?:today|tonight|tomorrow)?[, ]+"#,
      with: "", options: [.regularExpression, .caseInsensitive])
    if withoutClock != text,
      has(requestBody(withoutClock), #"^(?:remind me|set (?:an? |that )?alarm)\b"#),
      intent(withoutClock) == .capture
    {
      return .capture
    }
    if let prefix = text.range(
      of:
        #"^(?:today|tonight|tomorrow)\s+(?:(?:at\s+)?[0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)\s*)?[, ]*"#,
      options: [.regularExpression, .caseInsensitive]),
      prefix.upperBound < text.endIndex
    {
      let remainingIntent = intent(String(text[prefix.upperBound...]))
      if remainingIntent != .unsure { return remainingIntent }
    }
    // Recurrence can lead a direct request, just as "at 5pm" can. Re-route only
    // the remaining imperative; quoted, reported and declined statements keep their guards.
    if let prefix = text.range(
      of: "^(?:" + CaptureParser.englishWeeklyDays
        + #"|every\s+weekday|weekdays|every\s+weekend|weekends)\s+(?:(?:at\s+)?[0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)\s*)?[, ]*"#,
      options: [.regularExpression, .caseInsensitive]),
      prefix.upperBound < text.endIndex
    {
      let remainingIntent = intent(String(text[prefix.upperBound...]))
      if remainingIntent != .unsure { return remainingIntent }
    }
    // Talking ABOUT reminders, or explicitly declining one, is not asking for one.
    if has(
      text,
      #"don['’]t (?:add|create|set|remind|wake)|do not (?:add|create|set|remind|wake)|不要(?:创建|添加|提醒|设)|不用(?:创建|添加|提醒|设)|(?:不要|不用|别).*(?:叫醒|叫我起床)|只是聊|just (?:chatting|talking)|\bhow (?:do|can) (?:i|you)\b|怎么(?:创建|添加|设)|如何"#
    ) {
      return .conversation
    }
    if has(
      text,
      #"^(?:i (?:already|just|have)|i've) (?:set|added|created|finished|completed)|我(?:已经|刚刚|刚才).*(?:了|过)|我记得|^i (?:remember|asked)\b|^(?:what (?:does|is)|can you explain)|是什么意思|怎么用"#
    ) {
      return .conversation
    }
    // Embedded command words in an explanation question or a past report are not a new request.
    if has(
      text,
      #"^(?:what happens\b|why (?:did|does|do|would)\b|how (?:does|would)\b|(?:can|could) you (?:explain|tell me|show me)\b)|^(?:为什么|怎么(?:才能|会|设置|添加|创建)|如何)|^(?:yesterday|last night|this morning)[, ]+i (?:set|added|created)\b|^我(?:昨天|昨晚|今天早上)(?:设置了|设了|添加了|创建了)"#
    ) {
      return .conversation
    }
    if isChineseReportedActionQuestion(text) { return .conversation }
    // A concrete object may precede the reminder instruction. Require a complete suffix,
    // and keep quoted/reported statements behind the conversation boundary above.
    if !has(
      text, #"["“”「」]|(?:他说|她说|说过|昨天|已经)|\b(?:said|asked|already|finished|completed|yesterday)\b"#),
      has(
        text,
        #"^.+(?:下下|下|本|这)?(?:周|星期|礼拜)[一二三四五六日天]\s*提醒我(?:吧)?[。.!！]*$|^.+\s+(?:next\s+)?(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)[,， ]+remind me[.!]*$"#
      )
    {
      return .capture
    }
    // Alarm verbs must be the request itself, not words embedded in a question or report.
    if requestsAlarm(text) { return .capture }
    // A leading relative time may precede the imperative. Reuse capture's time grammar and
    // the ordinary request boundary, rather than treating any dated statement as a request.
    if !isQuestion(text),
      let action = CaptureParser.actionAfterLeadingRelativeTime(requestBody(text)),
      intent(action) == .capture || has(action, #"^(?:turn (?:off|on)\b|关(?:闭)?|打开)"#)
    {
      return .capture
    }
    if requestsEvent(text) { return .capture }
    if Dialogue.startsNewItem(text) {
      // Dialogue's unanchored matcher also protects editing follow-ups. At this NEW-message
      // boundary require the request itself, rather than a report/question quoting its words.
      if has(requestBody(text), #"^[\p{Han}0-9]"#) {
        let when = chineseTimeToken
        let direct =
          #"^(?:(?:请|麻烦|可以|能不能|能|可不可以)(?:你)?(?:帮我)?|帮我)?"#
          + when
          + #"*(?:的时候)?(?:吧)?[，,]?\s*(?:就)?(?:提醒我|提醒一下|提醒(?=\s+\S)|记得|别忘了|帮我记|新建|添加|(?:增加|新增)\s*(?:一?个|一条)?\s*(?:reminder|提醒事项|提醒|待办事项|待办|任务)|加一个|加个)"#
        // A narrative can end in an explicit timed reminder clause. Its earlier words
        // need not be a command, but the reminder clause itself must start at a boundary.
        let timedClause = #"(?:^|[，,。；;]|然后)\s*"# + when + #"+(?:的时候)?提醒我"#
        return has(requestBody(text), direct) || has(text, timedClause) ? .capture : .conversation
      }
      return has(
        requestBody(text),
        #"^(?:remind me|don't forget|new (?:reminder|task|event)|add (?:a |an )?(?:reminder|task|event|to-?do)|set (?:a |an )?reminder)\b|^when i\b.+\bremind me\b"#
      )
        ? .capture : .conversation
    }
    // Existing plan/tidy dispatch, not capture.
    if isSupportedOperationRequest(text) { return .unsure }
    if has(
      text,
      #"^(?:hi|hello|hey|thanks|thank you|good morning|good night)\b|^(?:你好|嗨|谢谢|早上好|晚安)|\bi(?: am| was|'m| have| already| just)\b|我(?:正在|在|刚|已经|进行|只是)|(?:感觉|心情|很累|累了|难过|聊聊)|\b(?:feel|feeling)\b|activity|活动记录"#
    ) {
      return .conversation
    }
    if has(
      requestBody(text),
      #"^(?:write|draft|compose|make) (?:me|us)\b|^(?:帮我写|给我写|给我讲)|^(?:write|tell|make).*(?:poem|story|joke|诗|故事|笑话)|\b(?:already|finished|completed|yesterday)\b|已经|昨天"#
    ) {
      return .conversation
    }
    // An action word with an unknown object ("Buy what?") is still a question.
    // Quantities (买几个苹果) and polite imperatives (Can you buy milk?) remain requests.
    if has(
      requestBody(text),
      #"^(?:buy|pay|send|email|submit|call|order|book)\s+(?:what|which|who|whom|where|when|how)\b|^(?:买|付|交|发|寄|订|预约)(?:什么|哪|谁)"#
    ) {
      return .conversation
    }
    // A leading edit operation cannot authorize a new reminder merely because a
    // dated object contains "dentist" or "meeting". Existing-item matching runs later.
    if has(
      requestBody(text),
      #"^(?:move|reschedule|postpone|delay|shift|bump|cancel|delete|remove)\b"#)
    {
      return .unsure
    }
    // Keep terse planner input working, including no-date errands. Dates alone are not an intent.
    if has(
      requestBody(text),
      #"^(?:buy|pay|send|email|submit|sign|print|book|order|pack|clean|wash|write|finish|fix|water|take out|pick up|drop off|return|renew|file|read|study|prepare|update|reply|follow up|check|call|get|cook|make|gym|workout|run|jog|swim|yoga|walk)\b|^(?:请|帮我)?(?:买|付|交|发|寄|回复|写|整理|订|预订|预约|打电话|取|拿|洗|倒垃圾|遛狗|充电|续|缴|健身|跑步|游泳|瑜伽)"#
    ) {
      return .capture
    }
    if isQuestion(text) { return .conversation }
    // First-person intentions can be a story or a request; let the model ask/decide, rather than guessing from a date.
    if has(text, #"\bi (?:want|need|plan|wonder)\b|我(?:想|要|打算)"#) { return .unsure }
    let parsed = CaptureParser.parse(text)
    if parsed.hasDay || parsed.hour != nil,
      has(
        text,
        #"\b(?:meeting|appointment|lunch|dinner|dentist|flight|class|interview)\b|会议|开会|面试|上课|聚餐|航班|看牙|体检"#
      )
    {
      return .capture
    }
    // A terse timed errand is a submitted action, even without a reminder wrapper.
    // Inspect the parsed action only after question, report and refusal guards above.
    if !isQuestion(text), parsed.hour != nil,
      has(
        parsed.title,
        #"^去\s*\S+.*(?:加油|买|取|拿|还|缴)|^(?:go to|stop at)\b.+\b(?:buy|get|pick up|gas|refuel)\b"#)
    {
      return .capture
    }
    if !isQuestion(text), parsed.hour != nil, parsed.title != text,
      has(
        parsed.title,
        #"^(?:buy|pay|send|email|submit|call|pick up|return|renew)\b|^(?:买|付|交|寄|取|拿|缴|打电话)"#)
    {
      return .capture
    }
    return .unsure
  }

  /// Only a time-only answer may precede the conversation guard, and only with an open time context.
  /// Strip a few complete answer wrappers, never arbitrary question/story words that happen to contain a time.
  public static func contextualTimeAnswer(
    _ raw: String, hasTimeContext: Bool,
    now: Date = .now, calendar: Calendar = .current
  ) -> String? {
    guard hasTimeContext else { return nil }
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    text = text.replacingOccurrences(of: #"[?？]+$"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"^(?:how about|what about)\s+"#, with: "",
      options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(
      of: #"(?:[,，]\s*)?(?:可以吗|行吗|好吗)$"#, with: "", options: .regularExpression)
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Dialogue.isOnlyWhen(text, now: now, calendar: calendar) else { return nil }
    return text
  }

  static func isQuestion(_ text: String) -> Bool {
    has(text, #"[?？]|什么|怎么|吗|多少|几|是不是|^(?:what|how|when|which|why|do |is |am |any)"#)
  }

  static func isContextQuestion(_ text: String) -> Bool {
    has(
      text,
      #"^[\s.…]*(?:(?:请问)?你\s*)?(?:能|可以|会|是否).*(?:看到|看见|读取|记得|记住).*(?:上面|之前|前面|历史|context|上下文|聊天)|^[\s.…]*(?:can|could|do) you (?:see|read|remember|access).*(?:above|previous|earlier|context|history|conversation)"#
    )
  }

}
