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
  public static func decide(
    _ text: String, intent: ChatRouting.Intent, context: ConversationContext, pending: Capture?,
    editItems: () -> [EditItem], now: Date, calendar: Calendar
  ) -> Decision {
    if intent != .conversation, hasMaterialCorrection(text) { return .clarifyCorrection }
    if !looksLikeEdit(text, items: editItems(), now: now, calendar: calendar),
      let capture = oneOffReminder(text, now: now, calendar: calendar)
    {
      return .directReminder(capture)
    }
    if let resolved = resolve(
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
