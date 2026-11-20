#if os(iOS)
  import SwiftUI
  import TodayCore

  package enum InteractionFeedback {
    package static let selection = SensoryFeedback.selection
    package static let detent = SensoryFeedback.selection
    package static let settle = SensoryFeedback.impact(weight: .light)
    package static let arm = SensoryFeedback.impact(
      flexibility: .soft, intensity: PullToAskWelcome.armIntensity)
    package static let welcome = PullToAskWelcome.beats.map {
      SensoryFeedback.impact(flexibility: .soft, intensity: $0.intensity)
    }
  }
#endif
