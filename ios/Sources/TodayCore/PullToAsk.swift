import Foundation

/// Decides when pulling a calendar list down past its top opens AI chat.
///
/// The view feeds overscroll distance (points the content is pulled below its
/// resting top) and whether a finger is tracking. Arming requires tracking, so
/// a fast flick that only bounces at the top while decelerating can never
/// open chat. Releasing while armed opens; sliding back below the disarm
/// band before release cancels.
public struct PullToAsk: Equatable, Sendable {
  /// Overscroll that arms the pull.
  public static let threshold: CGFloat = 64
  /// Below this an armed pull disarms again, so the boundary cannot chatter.
  public static let disarmBelow: CGFloat = 56

  public enum Event: Equatable, Sendable {
    case armed
    /// The finger released while armed; open chat.
    case open
  }

  /// Current overscroll, never negative. Keeps following the rubber band
  /// after release so progress can fade out with the content.
  public private(set) var pull: CGFloat = 0
  public private(set) var isArmed = false
  private var wasTracking = false

  public init() {}

  /// 0 at rest, 1 once the pull reaches the threshold.
  public var progress: CGFloat { min(1, pull / Self.threshold) }

  public mutating func update(pullDistance: CGFloat, isTracking: Bool) -> [Event] {
    pull = max(0, pullDistance)
    var events: [Event] = []
    if isTracking {
      if !isArmed, pull >= Self.threshold {
        isArmed = true
        events.append(.armed)
      } else if isArmed, pull < Self.disarmBelow {
        isArmed = false
      }
    } else if wasTracking {
      if isArmed { events.append(.open) }
      isArmed = false
    }
    wasTracking = isTracking
    return events
  }
}

extension PullToAsk {
  public var glow: CGFloat {
    let p = progress
    return p * p * (3 - 2 * p)
  }

  public var orbScale: CGFloat { 0.55 + 0.45 * progress }
}

public enum PullToAskWelcome {
  public struct Beat: Equatable, Sendable {
    public let delay: Duration
    public let intensity: Double
  }

  public static let sweep: TimeInterval = 0.7
  public static let armIntensity = 0.6
  public static let beats = [
    Beat(delay: .zero, intensity: 0.6), Beat(delay: .milliseconds(120), intensity: 0.35),
  ]

  public static func edgeOpacity(at phase: Double) -> Double {
    let t = min(1, max(0, phase))
    return t < 0.2 ? t / 0.2 : (1 - t) / 0.8
  }
}
