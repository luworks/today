import Foundation

/// Stable single-page snapping for Calendar's vertical months and horizontal day columns.
public enum CalendarPaging {
  public static func monthPageHeight(rowHeight: Double) -> Double { 6 * rowHeight }

  /// Snap to one adjacent page, including after an interrupted drag or edge rubber band.
  public static func targetOffset(
    original: Double, proposed: Double, velocity: Double, pageLength: Double,
    contentLength: Double, visiblePages: Int = 1, limitsToAdjacent: Bool = true
  ) -> Double {
    guard pageLength > 0 else { return 0 }
    let last = max(0, (contentLength / pageLength).rounded() - Double(max(1, visiblePages)))
    // Layout/size changes and explicit date jumps must retain their full requested destination.
    if !limitsToAdjacent {
      return min(last, max(0, (proposed / pageLength).rounded())) * pageLength
    }
    let page = min(last, max(0, (original / pageLength).rounded()))
    let delta = proposed - original
    let direction: Double =
      abs(delta) > pageLength * 0.15
      ? (delta > 0 ? 1 : -1)
      : (abs(velocity) > 100 ? (velocity > 0 ? 1 : -1) : 0)
    return min(last, max(0, page + direction)) * pageLength
  }
}
