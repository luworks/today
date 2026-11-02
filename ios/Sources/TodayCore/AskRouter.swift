import Foundation

/// Pure routing plan for a submitted turn. The caller applies preview edits first, then dispatches
/// the fallback. Reading planner items is lazy so material corrections never need a store read.
public enum AskRouter {
  public struct Plan: Equatable {
    public let decision: FastLane.Decision
    public let previewAnswer: String?
    public let useAgent: Bool
  }

  public static func plan(
    _ text: String, context: ConversationContext, pending: Capture?, savedDraft: Bool,
    agentHasOpenCards: Bool, hasLocalTimeContext: Bool, editItems: () -> [EditItem],
    now: Date, calendar: Calendar
  ) -> Plan {
    let intent = FastLane.intent(text)
    let decision = FastLane.decide(
      text, intent: intent, context: context, pending: pending, savedDraft: savedDraft,
      editItems: editItems, now: now, calendar: calendar)
    let mayAnswer: Bool
    switch decision {
    case .notFastLane, .directReminder: mayAnswer = !agentHasOpenCards
    case .clarifyCorrection, .continuation: mayAnswer = false
    }
    let answer =
      FastLane.timeAnswer(text, hasTimeContext: hasLocalTimeContext)
      ?? (intent == .conversation ? nil : text)
    return Plan(
      decision: decision, previewAnswer: mayAnswer ? answer : nil,
      useAgent: AgentRouting.useAgent(decision, agentHasOpenCards: agentHasOpenCards))
  }
}
