import Foundation

/// Keeps Today's timeline on the Now line while it is still laying out. Rows arrive late (Apple Calendar warms up after
/// launch, Health and weather load in) and self-sizing rows change height as they are measured, so one scroll at launch
/// can land nowhere or go stale. Centring holds from opening until the user's first touch, whatever they touch.
public struct TimelineNowCentering: Equatable {
  public private(set) var isHolding = false

  public init() {}

  /// On opening the timeline or changing day. Any other day, or scroll-to-now off, ends the hold.
  public mutating func arm(isToday: Bool, jumpsToNow: Bool) {
    isHolding = isToday && jumpsToNow
  }

  public mutating func touched() {
    isHolding = false
  }

  /// Whether a change in the list's content or container height should centre Now again. Never during a drag.
  public func recenters(from old: [CGFloat], to new: [CGFloat], isDragging: Bool) -> Bool {
    isHolding && !isDragging && old != new
  }
}
