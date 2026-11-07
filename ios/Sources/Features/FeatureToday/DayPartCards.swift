#if os(iOS)
  import SwiftUI
  import TodayCore

  /// The timeline's rows in their soft Morning / Afternoon / Evening cards. The cards are only row
  /// backgrounds: a background fills the whole cell, so rows keep their own insets and title width.
  struct DayPartRows<Item: Identifiable, Row: View>: View {
    let rows: [DayPartRow<Item>]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
      ForEach(rows) { entry in
        switch entry {
        case .label(let part): DayPartLabel(part: part)
        case .cardEnd: DayPartGap()
        case .item(let item, let card, let closesCard):
          row(item).listRowBackground(
            card.map { DayPartFill(part: $0, edge: closesCard ? .bottom : .middle) })
        }
      }
    }
  }

  private enum DayPartMetrics {
    /// Rows sit 20pt in, so a card 8pt from the screen edge leaves them 12pt of padding at today's position.
    static let margin: CGFloat = 8
    static let corner: CGFloat = 20
    static let gap: CGFloat = 10
    static let endPadding: CGFloat = 6
  }

  /// Heads a card. Bare system colours fall below 3:1 on their own tint, so the text leans to the label colour.
  private struct DayPartLabel: View {
    let part: DayPart

    private var title: Text {
      switch part {
      case .morning: Text("Morning")
      case .afternoon: Text("Afternoon")
      case .evening: Text("Evening")
      }
    }

    var body: some View {
      title
        .font(.caption.weight(.semibold))
        .foregroundStyle(part.color.mix(with: .primary, by: 0.35))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 4, trailing: 20))
        .listRowBackground(DayPartFill(part: part, edge: .top))
    }
  }

  /// The card's bottom padding, drawn by its last row's fill, and the gap to the next card.
  private struct DayPartGap: View {
    var body: some View {
      Color.clear
        .frame(height: DayPartMetrics.endPadding + DayPartMetrics.gap)
        .accessibilityHidden(true)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
  }

  private struct DayPartFill: View {
    enum Edge { case top, middle, bottom }

    let part: DayPart
    let edge: Edge
    @Environment(\.colorScheme) private var colorScheme

    private var opacity: Double {
      switch (part, colorScheme) {
      case (.morning, .dark): 0.17
      case (.afternoon, .dark): 0.17
      case (.evening, .dark): 0.24
      case (.afternoon, _): 0.075
      default: 0.11
      }
    }

    var body: some View {
      let top = edge == .top ? DayPartMetrics.corner : 0
      let bottom = edge == .bottom ? DayPartMetrics.corner : 0
      UnevenRoundedRectangle(
        cornerRadii: RectangleCornerRadii(
          topLeading: top, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: top),
        style: .continuous
      )
      .fill(part.color.opacity(opacity))
      .padding(.horizontal, DayPartMetrics.margin)
      // Runs past its short cell: a shape cannot round more than its own height, and Free rows are short.
      .padding(.bottom, edge == .bottom ? -DayPartMetrics.endPadding : 0)
    }
  }

  extension DayPart {
    fileprivate var color: Color {
      switch self {
      case .morning: .orange
      case .afternoon: .blue
      case .evening: .indigo
      }
    }
  }
#endif
