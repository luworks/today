import Foundation

/// A narrow submitted-message authority, separate from seven-day background grants.
/// Rules must establish the action and timing; model output alone cannot authorize a write.
public enum OneOffReminderRequest {
  public static func capture(
    _ text: String, now: Date, calendar: Calendar
  ) -> Capture? {
    guard ChatRouting.intent(text) == .capture, !ChatRouting.requestsEvent(text),
      !ChatRouting.hasMultipleActions(text), !ChatRouting.hasMaterialCorrection(text),
      CaptureParser.leadingMonth(text) == nil,
      !CaptureConversation.referencesReminder(text),
      // Someone else's plans, a question about what Today can do, an event with a length, or two
      // reminders in one message are never a clear one-off reminder (agent P3 holdout findings).
      !FastLane.isReportedSpeech(text), !isQuestion(text), !hasDuration(text),
      reminderVerbs(text) < 2,
      text.range(
        of:
          #"[;；\n]|然后|另外还|\band then\b|\bevery\b|\brecurr|重复|每|还是|或者|\bor\b|\b(?:alarm|timer)\b|wake me|闹钟|计时器|叫醒|叫我起床"#,
        options: [.regularExpression, .caseInsensitive]) == nil
    else { return nil }
    let capture = CaptureConversation.parse(text, now: now, calendar: calendar)
    return eligible(capture) ? capture : nil
  }

  /// "Can you …?", "你能…吗？": a question is not permission to write (it may be answered or previewed).
  static func isQuestion(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let asks =
      t.range(
        of:
          #"^(?:can|could|would|will|do|does|is|are)\s+you\b|^(?:你|您)(?:能|可以|会)|^(?:能不能|可不可以|能否)|吗[?？]?$"#,
        options: [.regularExpression, .caseInsensitive]) != nil
    return asks || (t.hasSuffix("?") || t.hasSuffix("？"))
  }

  /// A length ("for 30 minutes", "开一小时") makes it an event, not a reminder; "in an hour"/"1小时后" is a time.
  static func hasDuration(_ text: String) -> Bool {
    text.range(
      of:
        #"\bfor\s+(?:\d+|an?|one|two|three|half an?)\s*(?:min(?:ute)?s?|hours?|hrs?)\b|^\s*schedule\b|(?:\d+|半|一|两|三|四)\s*(?:个)?(?:分钟|小时|钟头)(?!\s*(?:后|以后|之后|前|以前|之前|内))"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// How many reminder instructions the message holds ("提醒我…，…提醒我…" is two items).
  static func reminderVerbs(_ text: String) -> Int {
    let pattern = try? NSRegularExpression(pattern: #"提醒我|remind me"#, options: [.caseInsensitive])
    return pattern?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
  }

  /// Recovery can use the original subject, but never erase ambiguity or recurrence words
  /// just because the parsed result omitted them.
  public static func contextAllows(_ context: ConversationContext) -> Bool {
    for turn in context.userTurns.reversed() {
      if CaptureConversation.referencesReminder(turn.text)
        || CaptureConversation.isOneOffAnswer(turn.text)
        || turn.text.range(
          of: #"^\s*(?:你做吧|你来吧|go ahead|do it|please do)[.!。]*\s*$"#,
          options: [.regularExpression, .caseInsensitive]) != nil
      {
        continue
      }
      guard CaptureParser.leadingMonth(turn.text) == nil,
        !ChatRouting.hasMultipleActions(turn.text), !ChatRouting.hasMaterialCorrection(turn.text)
      else { return false }
      return turn.text.range(
        of: #"还是|或者|\bor\b|\bevery\b|\brecurr|重复|每"#,
        options: [.regularExpression, .caseInsensitive]) == nil
    }
    return false
  }

  public static func eligible(_ capture: Capture) -> Bool {
    guard capture.kind == .task, !capture.ringsAsAlarm, capture.repeatRule == nil,
      !capture.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      capture.title.range(
        of:
          #"^(?:something|anything|a reminder|reminder|remind me|new task|task|alarm|timer|提醒|提醒我|一个提醒|任务|闹钟|计时器|某事)[.!。]*$"#,
        options: [.regularExpression, .caseInsensitive]) == nil
    else { return false }
    return true
  }

  /// Only continuation answers reuse a prior card. A freshly submitted action is a new request.
  public static func matches(_ lhs: Capture, _ rhs: Capture) -> Bool {
    lhs.title == rhs.title && lhs.kind == rhs.kind && lhs.day == rhs.day
      && lhs.hour == rhs.hour && lhs.minute == rhs.minute && lhs.repeatRule == rhs.repeatRule
      && lhs.ringsAsAlarm == rhs.ringsAsAlarm && lhs.isWorkBlock == rhs.isWorkBlock
  }
}
