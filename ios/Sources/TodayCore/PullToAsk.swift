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
    /// The pull crossed into armed; play one detent haptic.
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
