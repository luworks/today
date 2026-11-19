#if os(iOS)
  import SwiftUI

  /// Shared iOS responses for the interaction roles described in the design specification.
  enum InteractionFeedback {
    static let selection = SensoryFeedback.selection
    static let detent = SensoryFeedback.selection
    static let settle = SensoryFeedback.impact(weight: .light)
    static let dateSelection = Animation.easeOut(duration: 0.12)
  }
#endif
