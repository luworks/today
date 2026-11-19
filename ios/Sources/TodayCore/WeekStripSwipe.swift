import Foundation

/// Tracks presentation in page widths so a new touch can take over a settling page.
public struct WeekStripSwipe {
  private static let cell: CGFloat = 1 / 7
  private static let hysteresis: CGFloat = 0.14 * cell
  private static let detentInterval: TimeInterval = 0.055

  private var contact: Contact?
  public private(set) var settle: Settle?
  public var needsFrames: Bool { (settle?.start ?? 0) != 0 }

  private struct Contact {
    let start: CGFloat
    var travel: CGFloat = 0
    var tooth = 0
    var lastTick: TimeInterval?
  }

  public struct Settle: Equatable, Sendable {
    public let start: CGFloat
    public let time: TimeInterval
    public let duration: TimeInterval
    public let turned: Bool

    fileprivate func offset(at now: TimeInterval) -> CGFloat {
      let progress = min(1, max(0, (now - time) / duration))
      let remaining = CGFloat(1 - progress)
      return start * remaining * remaining * remaining
    }
  }

  public init() {}

  public func offset(at now: TimeInterval) -> CGFloat {
    if let contact { return contact.start + contact.travel }
    return settle?.offset(at: now) ?? 0
  }

  public mutating func touchDown(at now: TimeInterval) {
    contact = Contact(start: offset(at: now))
    settle = nil
  }

  /// One tick at most per sample. Suppressed crossings never play later.
  public mutating func drag(_ pages: CGFloat, at now: TimeInterval) -> Bool {
    guard var current = contact else { return false }
    current.travel = clamped(pages)
    let positive = current.travel >= 0
    let old = positive ? max(0, current.tooth) : max(0, -current.tooth)
    let magnitude = abs(current.travel)
    let inset = old > 0 && magnitude < CGFloat(old) * Self.cell ? Self.hysteresis : 0
    let tooth = min(2, Int((magnitude + inset) / Self.cell)) * (positive ? 1 : -1)
    let crossed = tooth != current.tooth
    let tick =
      crossed && (current.lastTick.map { now - $0 >= Self.detentInterval } ?? true)
    if tick { current.lastTick = now }
    current.tooth = tooth
    contact = current
    return tick
  }

  /// Returns the adjacent week to commit, or zero when the original week should stay selected.
  public mutating func release(
    _ pages: CGFloat, cancelled: Bool, animated: Bool, at now: TimeInterval
  ) -> Int {
    guard let contact else { return 0 }
    let travel = cancelled ? contact.travel : clamped(pages)
    let turn = !cancelled && abs(travel) >= 2 * Self.cell ? (travel < 0 ? 1 : -1) : 0
    // The committed week is about to become the center page. Keep the visible dates in place.
    let start = animated ? contact.start + travel + CGFloat(turn) : 0
    if animated && abs(start) > 0.001 {
      settle = Settle(start: start, time: now, duration: turn == 0 ? 0.15 : 0.17, turned: turn != 0)
    } else if turn != 0, let tick = contact.lastTick, now - tick < Self.detentInterval {
      // An immediate visual landing, including Reduce Motion, still gives the detent room to finish.
      settle = Settle(
        start: 0, time: now, duration: Self.detentInterval - (now - tick), turned: true)
    }
    self.contact = nil
    return turn
  }

  /// Only the active landing may complete or produce feedback.
  public mutating func complete(_ expected: Settle) -> Bool {
    guard settle == expected else { return false }
    settle = nil
    return expected.turned
  }

  private func clamped(_ pages: CGFloat) -> CGFloat {
    min(1, max(-1, pages))
  }
}
