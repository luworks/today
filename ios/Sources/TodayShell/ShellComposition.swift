#if os(iOS)
  import Foundation
  import SwiftData
  import One
  import TodayCore
  import TodayDesignSystem
  import FeatureClock
  import FeatureAsk

  /// Retained executable composition, passed only through the shell's destination builders.
  @MainActor
  package final class ShellComposition {
    package let session: PlannerSession
    package let presentation: PlannerPresentation
    package let world: WorldClockStore
    package let stopwatch: StopwatchModel
    package let intelligence: AskIntelligence
    package let agentModel: AgentModel
    package let voice: VoiceInput
    package let suggestionMemory: AskSuggestionMemory
    package let arguments: [String]
    package let openSettings: @MainActor () -> Void

    package init(
      session: PlannerSession, world: WorldClockStore, stopwatch: StopwatchModel,
      intelligence: AskIntelligence, agentModel: AgentModel, voice: VoiceInput,
      arguments: [String],
      openSettings: @escaping @MainActor () -> Void
    ) {
      self.session = session
      self.world = world
      self.stopwatch = stopwatch
      self.intelligence = intelligence
      self.agentModel = agentModel
      self.voice = voice
      self.arguments = arguments
      self.openSettings = openSettings
      presentation = PlannerPresentation(runtime: session.runtime, defaults: session.defaults)
      suggestionMemory = AskSuggestionMemory()
    }

    package func recordCreatedAlarm(_ alarm: OneAlarm, context: ModelContext) {
      AlarmActions.recordCreated(
        alarm, title: alarm.label.isEmpty ? AlarmPlan.defaultLabel : alarm.label,
        ledger: session.ledger, runtime: session.runtime, context: context)
    }

    package func dispose() {
      voice.stop()
      suggestionMemory.dispose()
      session.dispose()
    }
  }
#endif
