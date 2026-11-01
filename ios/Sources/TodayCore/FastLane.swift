import Foundation

/// The rules-only lane (docs/engineering/ai-agent-architecture.md §1.2, §4.2, §4.5 P1, §5 H1): local,
/// offline, deterministic. It gathers every gate the scoped one-off reminder exception depends on, so the
/// agent migration cannot remove one by accident. Only `Decision.directReminder` may write without a
/// card (`ActionPolicy` tier `direct`); continuation answers only complete FastLane's own drafts.
public enum FastLane {
  /// What the rule gates decide for one submitted message, in the order Ask applies them.
  public enum Decision: Equatable {
    /// The message corrects a date or time mid-sentence: ask for a restatement; nothing is added.
    case clarifyCorrection
    /// A clear one-off reminder in the user's own words: create it directly, with Undo.
    case directReminder(Capture)
    /// An answer that completes the conversation's own draft. `direct` is true when that draft is a
    /// clear one-off reminder whose context allows the exception; otherwise it stays a preview.
    case continuation(Capture, direct: Bool)
    /// Not for the fast lane; the remaining routes (time answers, edits, Tidy, chat) handle it.
    case notFastLane
  }

  /// `editItems` is evaluated only when the correction gate passes; reading items may be costly.
  /// `savedDraft`: the chat's last card is already decided (e.g. added directly) and no draft is open,
  /// so a follow-up like "改成下午4点" corrects a saved item; it is never re-created (P3 holdout finding).
  public static func decide(
    _ text: String, intent: ChatRouting.Intent, context: ConversationContext, pending: Capture?,
    savedDraft: Bool = false, editItems: () -> [EditItem], now: Date, calendar: Calendar
  ) -> Decision {
    if intent != .conversation, hasMaterialCorrection(text) { return .clarifyCorrection }
    if !looksLikeEdit(text, items: editItems(), now: now, calendar: calendar),
      let capture = oneOffReminder(text, now: now, calendar: calendar)
    {
      return .directReminder(capture)
    }
    if !(savedDraft && pending == nil),
      let resolved = resolve(
        text, context: context, pending: pending, now: now, calendar: calendar)
    {
      return .continuation(
        resolved, direct: isEligibleOneOff(resolved) && contextAllowsOneOff(context))
    }
    return .notFastLane
  }

  // MARK: Gates

  public static func intent(_ text: String) -> ChatRouting.Intent { ChatRouting.intent(text) }
  public static func requestsEvent(_ text: String) -> Bool { ChatRouting.requestsEvent(text) }
  public static func hasMultipleActions(_ text: String) -> Bool {
    ChatRouting.hasMultipleActions(text)
  }
  public static func hasMaterialCorrection(_ text: String) -> Bool {
    ChatRouting.hasMaterialCorrection(text)
  }
  public static func parse(_ text: String, now: Date, calendar: Calendar) -> Capture {
    CaptureConversation.parse(text, now: now, calendar: calendar)
  }
  public static func referencesReminder(_ text: String) -> Bool {
    CaptureConversation.referencesReminder(text)
  }
  public static func resolve(
    _ text: String, context: ConversationContext, pending: Capture?, now: Date, calendar: Calendar
  ) -> Capture? {
    CaptureConversation.resolve(
      text, context: context, pending: pending, now: now, calendar: calendar)
  }
  public static func isOneOffAnswer(_ text: String) -> Bool {
    CaptureConversation.isOneOffAnswer(text)
  }
  public static func looksLikeEdit(
    _ text: String, items: [EditItem], now: Date, calendar: Calendar
  ) -> Bool {
    Editing.looksLikeEdit(text, items: items, now: now, calendar: calendar)
  }
  /// An explicit edit of the item the chat is attached to ("move it to 4"); nil outside its grammar.
  public static func attachedEdit(
    _ text: String, attachedItemID: String?, items: [EditItem], now: Date, calendar: Calendar
  ) -> AttachedItemEdit? {
    AttachedItemEditing.parse(
      text, attachedItemID: attachedItemID, items: items, now: now, calendar: calendar)
  }

  // MARK: The one-off reminder exception

  public static func oneOffReminder(_ text: String, now: Date, calendar: Calendar) -> Capture? {
    OneOffReminderRequest.capture(text, now: now, calendar: calendar)
  }
  public static func isEligibleOneOff(_ capture: Capture) -> Bool {
    OneOffReminderRequest.eligible(capture)
  }
  public static func contextAllowsOneOff(_ context: ConversationContext) -> Bool {
    OneOffReminderRequest.contextAllows(context)
  }
  public static func sameOneOff(_ lhs: Capture, _ rhs: Capture) -> Bool {
    OneOffReminderRequest.matches(lhs, rhs)
  }

  /// Someone else's words or plans reported by the user ("我朋友说他明天要提醒自己买茶", "Sam told me he
  /// has a meeting"): a third person follows the reporting verb and the user asks nothing for themselves.
  /// Not a request, so nothing is created from it (principle 1).
  public static func isReportedSpeech(_ text: String) -> Bool {
    let reported =
      text.range(
        of:
          #"说(?:他|她|他们|她们|自己)|告诉我(?:他|她|他们|她们)|\b(?:said|says|told me|mentioned)\s+(?:that\s+)?(?:he|she|they)\b"#,
        options: [.regularExpression, .caseInsensitive]) != nil
    guard reported else { return false }
    let forMe =
      text.range(
        of:
          #"提醒我|帮我|给我设|叫我|remind me|wake me|set (?:me|an alarm for me)|for me\b|can you|could you|please"#,
        options: [.regularExpression, .caseInsensitive]) != nil
    return !forMe
  }

  // MARK: Local previews when the agent can't run (§4.7 #3)

  /// A reminder, event or alarm the rules read with confidence from one request: the offline and
  /// not-signed-in path. Always a preview, never a write (only `oneOffReminder` may be direct). nil
  /// when the rules aren't sure; the caller then says the AI is unavailable and keeps the draft.
  ///
  /// Confident means: a request to add something (not a question, chat, edit of an existing item,
  /// list of several actions, mid-sentence correction or someone else's words), with a real title,
  /// and either words that settle the kind or a day or time.
  public static func localPreview(
    _ text: String, items: [EditItem], now: Date, calendar: Calendar
  ) -> Capture? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard intent(trimmed) == .capture, !hasMultipleActions(trimmed),
      !hasMaterialCorrection(trimmed), !isReportedSpeech(trimmed),
      !OverdueTidy.isRequest(trimmed),
      !looksLikeEdit(trimmed, items: items, now: now, calendar: calendar)
    else { return nil }
    let parsed = parse(trimmed, now: now, calendar: calendar)
    let kind = ruleKind(trimmed, parsed: parsed)
    guard kind != nil || parsed.hasDay || parsed.hour != nil else { return nil }
    let capture = kind.map { combine(parsed, kind: $0, text: trimmed) } ?? parsed
    // An alarm may be just "Alarm"; anything else needs a real title.
    let title = capture.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard capture.ringsAsAlarm || (!title.isEmpty && !isGenericTitle(title)) else { return nil }
    return capture
  }

  /// What a new item is, when the words settle it without a model.
  public enum Kind: Equatable, Sendable { case task, event, alarm }

  /// The kind the words settle, or nil (e.g. "dentist tomorrow at 3" could be a reminder or an event).
  public static func ruleKind(_ text: String, parsed: Capture) -> Kind? {
    if requestsEvent(text) { return .event }
    if parsed.ringsAsAlarm { return .alarm }
    if asksForAlarm(text), parsed.hour != nil { return .alarm }
    if matches(text, #"提醒我|\bremind me\b"#) { return .task }
    if CaptureParser.isBookingAction(text) { return .task }
    if matches(text, eventCue) { return nil }
    let title = parsed.title.lowercased().trimmingCharacters(in: .whitespaces)
    if matches(title, taskLead) { return .task }
    return nil
  }

  /// The parser's fields with the settled kind. An alarm needs a time, and the alarm words, to ring.
  public static func combine(_ parsed: Capture, kind: Kind, text: String) -> Capture {
    var c = parsed
    c.kind = kind == .event ? .event : .task
    if kind == .alarm, parsed.hour != nil, asksForAlarm(text) || parsed.ringsAsAlarm {
      c.ringsAsAlarm = true
    }
    return c
  }

  /// Words that mean "ring me". With a time they make an alarm.
  public static func asksForAlarm(_ text: String) -> Bool {
    matches(text, #"wake\s+me|\balarm\b|\btimer\b|计时|闹钟|叫醒|叫我起床|起床"#)
  }

  static func isGenericTitle(_ title: String) -> Bool {
    matches(
      title,
      #"^(?:something|anything|a reminder|reminder|remind me|new task|task|event|an event|alarm|an alarm|timer|提醒|提醒我|一个提醒|任务|事件|闹钟|计时器|某事)[.!。]*$"#
    )
  }

  private static func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  private static let eventCue =
    #"\b(?:meeting|mtg|appointment|appt|interview|class|lecture|session|lunch|dinner|brunch|breakfast|party|wedding|flight|train|concert|show|movie|conference|standup|stand-up|sync|1:1|call with|catch up|date|exam|checkup|check-up|dentist|doctor|workshop|webinar|trip)\b|会议|开会|面试|上课|课程|聚餐|吃饭|午饭|晚饭|早饭|聚会|婚礼|航班|火车|高铁|演出|电影|音乐会|约会|见面|体检|复诊|门诊|看病|考试|周会|例会|站会|视频会|喝咖啡|看牙|培训"#
  private static let taskLead =
    #"^(?:buy|pay|send|email|text|submit|sign|print|book|order|pack|clean|wash|write|finish|fix|water|take out|pick up|drop off|return|renew|file|read|study|prepare|update|reply|follow up|check|call|get|grab|cook|make|plan|gym|workout|run|jog|swim|yoga|walk|hike|hiking)\b|^(?:买|付|交|发|寄|回复|写|整理|订|预订|预约|打电话|取|拿|洗|收|倒垃圾|遛狗|充电|还|退|续|缴|健身|跑步|游泳|瑜伽)"#

  // MARK: Continuation answers to FastLane's own draft

  public static func refine(
    _ draft: Capture, with answer: String, now: Date, calendar: Calendar
  ) -> Dialogue.Refinement {
    Dialogue.refine(draft, with: answer, now: now, calendar: calendar)
  }
  public static func isOnlyWhen(_ text: String, now: Date, calendar: Calendar) -> Bool {
    Dialogue.isOnlyWhen(text, now: now, calendar: calendar)
  }
  public static func answerTime(
    _ text: String, keeping old: Date?, now: Date, calendar: Calendar
  ) -> Date? {
    Dialogue.answerTime(text, keeping: old, now: now, calendar: calendar)
  }
}
