#if os(iOS)
  import SwiftUI
  import TodayCore

  enum InteractionFeedback {
    static let selection = SensoryFeedback.selection
    static let detent = SensoryFeedback.selection
    static let settle = SensoryFeedback.impact(weight: .light)
    static let arm = SensoryFeedback.impact(
      flexibility: .soft, intensity: PullToAskWelcome.armIntensity)
    static let welcome = PullToAskWelcome.beats.map {
      SensoryFeedback.impact(flexibility: .soft, intensity: $0.intensity)
    }
    static let dateSelection = Animation.easeOut(duration: 0.12)
  }
#endif
