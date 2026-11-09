#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem
  import TodayPlatform

  /// The one accent Health uses (the heart on the Today line). System pink adapts to dark mode.
  public enum HealthStyle {
    public static let accent = Color.pink
    /// The past days of a sparkline: grey, so only the latest reading carries colour.
    public static let trend = Color(.systemGray3)
    /// The muted look of a missing day or an empty row.
    public static let muted = Color(.tertiaryLabel)
  }

  /// A tiny sparkline of the last 7 days, drawn by hand (no chart per row). `values` come from `HealthSpark.normalised`:
  /// 0…1, nil for a day without data. Bars for totals, a thin line for readings. Only the latest reading is in colour;
  /// a reading with no neighbour is a small grey dot, a day missing from the bars a muted one, and with no data at all
  /// the row is seven muted dots.
  public struct HealthSparkline: View {
    let values: [Double?]
    let shape: HealthShape

    public init(values: [Double?], shape: HealthShape) {
      self.values = values
      self.shape = shape
    }

    public var body: some View {
      Canvas { context, size in
        let count = max(values.count, 1)
        let slot = size.width / CGFloat(count)
        let last = values.lastIndex { $0 != nil }
        let empty = last == nil

        func center(_ i: Int) -> CGFloat { slot * (CGFloat(i) + 0.5) }
        func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: Color) {
          context.fill(
            Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
            with: .color(color))
        }

        switch shape {
        case .bars:
          let barWidth = min(7, slot * 0.58)
          for (i, v) in values.enumerated() {
            guard let v else {
              dot(center(i), size.height - 1.5, 1.5, HealthStyle.muted)
              continue
            }
            let h = 3 + CGFloat(v) * (size.height - 3)
            let rect = CGRect(
              x: center(i) - barWidth / 2, y: size.height - h, width: barWidth, height: h)
            context.fill(
              Path(roundedRect: rect, cornerRadius: barWidth / 2),
              with: .color(i == last ? HealthStyle.accent : HealthStyle.trend))
          }
        case .dots:
          func y(_ v: Double) -> CGFloat { 3 + CGFloat(1 - v) * (size.height - 6) }
          if empty {
            for i in values.indices { dot(center(i), size.height / 2, 1.5, HealthStyle.muted) }
            return
          }
          var line = Path()
          var open = false
          for (i, v) in values.enumerated() {
            guard let v else {
              open = false
              continue
            }
            let p = CGPoint(x: center(i), y: y(v))
            if open { line.addLine(to: p) } else { line.move(to: p) }
            open = true
          }
          context.stroke(
            line, with: .color(HealthStyle.trend),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
          for (i, v) in values.enumerated() {
            guard let v else { continue }
            let joined =
              (i > 0 && values[i - 1] != nil) || (i + 1 < values.count && values[i + 1] != nil)
            if i == last {
              dot(center(i), y(v), 3, HealthStyle.accent)
            } else if !joined {
              dot(center(i), y(v), 1.5, HealthStyle.trend)
            }
          }
        }
      }
      .accessibilityHidden(true)
    }
  }
#endif
