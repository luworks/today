#if os(iOS)
  import SwiftUI
  import TodayCore

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
    package func pullToAsk() -> some View {
      modifier(PullToAskModifier())
    }
  }

  enum PullToAskPalette {
    static let ember = Color.orange
    static let amber = Color.orange.mix(with: .yellow, by: 0.45)
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
            .overlay(alignment: .top) {
              if pull.pull > 0 { indicator }
            }
            .sensoryFeedback(InteractionFeedback.arm, trigger: armHaptics)
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
      ZStack(alignment: .top) {
        EllipticalGradient(
          colors: [
            PullToAskPalette.amber.opacity(0.45), PullToAskPalette.ember.opacity(0.12), .clear,
          ],
          center: .top, startRadiusFraction: 0, endRadiusFraction: 0.55
        )
        .frame(height: 180)
        .opacity(Double(pull.glow))

        VStack(spacing: 6) {
          orb
          Text(pull.isArmed ? "Release, I'm here" : "Pull to ask AI")
            .font(.footnote.weight(.medium))
            .foregroundStyle(pull.isArmed ? Color.primary : Color.secondary)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: pull.isArmed)
        }
        .padding(.top, 10)
        .offset(y: reduceMotion ? 0 : min(20, pull.pull * 0.25))
        .opacity(pull.pull >= 8 ? Double(pull.progress) : 0)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .accessibilityIdentifier("pullToAsk.indicator")
    }

    private var orb: some View {
      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [PullToAskPalette.amber.opacity(0.55), .clear],
              center: .center, startRadius: 0, endRadius: 22)
          )
          .frame(width: 44, height: 44)
        Image(systemName: "sparkles")
          .font(.title3.weight(.semibold))
          .foregroundStyle(
            LinearGradient(
              colors: [PullToAskPalette.amber, PullToAskPalette.ember],
              startPoint: .top, endPoint: .bottom)
          )
          .symbolEffect(.breathe, isActive: pull.isArmed && !reduceMotion)
      }
      .scaleEffect(reduceMotion ? 1 : pull.orbScale)
    }
  }

  package struct PullToAskWelcomeEdge: View {
    private let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var run: Int?
    @State private var secondBeat = 0

    package init(trigger: Int) { self.trigger = trigger }

    package var body: some View {
      ZStack {
        if let run {
          EdgeSweepRun(turning: !reduceMotion) {
            if self.run == run { self.run = nil }
          }
          .id(run)
        }
      }
      .ignoresSafeArea()
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .sensoryFeedback(InteractionFeedback.welcome[0], trigger: trigger)
      .sensoryFeedback(InteractionFeedback.welcome[1], trigger: secondBeat)
      .onChange(of: trigger) { _, new in run = new }
      .task(id: trigger) {
        guard trigger > 0 else { return }
        try? await Task.sleep(for: PullToAskWelcome.beats[1].delay)
        secondBeat += 1
      }
    }
  }

  private struct EdgeSweepRun: View {
    let turning: Bool
    let done: () -> Void
    @State private var phase = 0.0

    var body: some View {
      EdgeSweep(phase: phase, turning: turning)
        .onAppear {
          withAnimation(.easeOut(duration: PullToAskWelcome.sweep)) {
            phase = 1
          } completion: {
            done()
          }
        }
    }
  }

  private struct EdgeSweep: View, Animatable {
    var phase: Double
    let turning: Bool

    nonisolated var animatableData: Double {
      get { phase }
      set { phase = newValue }
    }

    var body: some View {
      RoundedRectangle(cornerRadius: 52, style: .continuous)
        .strokeBorder(
          AngularGradient(
            colors: [.clear, PullToAskPalette.amber, PullToAskPalette.ember, .clear, .clear],
            center: .center, angle: .degrees((turning ? phase * 360 : 0) - 90)),
          lineWidth: 5
        )
        .blur(radius: 6)
        .opacity(PullToAskWelcome.edgeOpacity(at: phase))
    }
  }
#endif
