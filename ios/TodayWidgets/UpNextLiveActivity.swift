import ActivityKit
import SwiftUI
import TodayShared
import WidgetKit

// The Lock Screen "Up Next" card: up to three equal rows of clock time and title, and nothing else.
// The app starts and updates it (`Sources/One/UpNextActivity.swift`); this only draws `UpNextAttributes`.

struct UpNextLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: UpNextAttributes.self) { context in
      UpNextRows(rows: context.state.rows)
        .padding(.vertical, 13)
        .padding(.horizontal, 18)
        // The system background follows the Lock Screen's light or dark look; white text needs it dark in both.
        .activityBackgroundTint(.black.opacity(0.45))
        .activitySystemActionForegroundColor(.white)
        .widgetURL(WidgetLink.url())
    } dynamicIsland: { context in
      let next = context.state.rows.first
      return DynamicIsland {
        DynamicIslandExpandedRegion(.bottom) {
          UpNextRows(rows: context.state.rows)
        }
      } compactLeading: {
        Circle()
          .fill(UpNextStyle.time)
          .frame(width: 6, height: 6)
      } compactTrailing: {
        if let next {
          Text(shortTime(next.start))
            .monospacedDigit()
            .minimumScaleFactor(0.7)
            .frame(maxWidth: 56)
            .foregroundStyle(UpNextStyle.title)
        }
      } minimal: {
        Image(systemName: "clock")
          .foregroundStyle(UpNextStyle.title)
      }
      .keylineTint(UpNextStyle.time)
      .widgetURL(WidgetLink.url())
    }
  }
}

private enum UpNextStyle {
  // Fixed because the Lock Screen and the Dynamic Island are not app-themed.
  static let time = Color.white.opacity(0.58)
  static let title = Color.white.opacity(0.9)
}

private struct UpNextRows: View {
  let rows: [UpNextRow]

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        GridRow {
          Text(shortTime(row.start))
            .monospacedDigit()
            .foregroundStyle(UpNextStyle.time)
          Text(row.title)
            .foregroundStyle(UpNextStyle.title)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
        .frame(height: 29)
        .accessibilityElement(children: .combine)
      }
    }
    .font(.system(size: 17))
  }
}

private let ciTrialWidget = 1
