#if os(iOS)
  import SwiftUI
  import TodayCore

  /// Opens a new AI chat when a calendar surface is pulled down past its top.
  /// The shell provides the action; it is nil where no chat can open
  /// (previews, tests) and the pull then does nothing at all.
  package typealias PullToAskAction = @MainActor () -> Void

  private struct PullToAskKey: EnvironmentKey {
    static var defaultValue: PullToAskAction? { nil }
  }

  extension EnvironmentValues {
    package var pullToAsk: PullToAskAction? {
      get { self[PullToAskKey.self] }
      set { self[PullToAskKey.self] = newValue }
    }
  }

  extension View {
    /// Pulling this scrollable surface down past its top offers AI chat:
    /// release past the threshold opens it with the editor focused.
    /// See docs/design/pull-to-ask.md.
    package func pullToAsk() -> some View {
      modifier(PullToAskModifier())
    }
  }

  private struct PullToAskModifier: ViewModifier {
    @Environment(\.pullToAsk) private var action
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pull = PullToAsk()
    @State private var isTracking = false
    @State private var armHaptics = 0

    func body(content: Content) -> some View {
      Group {
        if action == nil {
          content
        } else {
          content
            .onScrollPhaseChange { _, phase in
              let tracking = phase == .tracking || phase == .interacting
              if tracking != isTracking {
                isTracking = tracking
                apply(pull.update(pullDistance: pull.pull, isTracking: tracking))
              }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
              -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, overscroll in
              apply(pull.update(pullDistance: overscroll, isTracking: isTracking))
            }
            .overlay(alignment: .top) { indicator }
            .sensoryFeedback(InteractionFeedback.detent, trigger: armHaptics)
        }
      }
    }

    private func apply(_ events: [PullToAsk.Event]) {
      for event in events {
        switch event {
        case .armed: armHaptics += 1
        case .open: action?()
        }
      }
    }

    private var indicator: some View {
      Label(
        pull.isArmed ? "Release to ask AI" : "Pull to ask AI",
        systemImage: "sparkles"
      )
      .font(.footnote.weight(.medium))
      .foregroundStyle(pull.isArmed ? Color.primary : Color.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(Color(.secondarySystemBackground), in: Capsule())
      .padding(.top, 8)
      .offset(y: reduceMotion ? 0 : min(24, pull.pull * 0.3))
      .opacity(pull.pull >= 8 ? Double(pull.progress) : 0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .accessibilityIdentifier("pullToAsk.indicator")
    }
  }
#endif
