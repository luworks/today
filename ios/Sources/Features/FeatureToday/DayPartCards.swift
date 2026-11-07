#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem

  /// The timeline's rows in their soft Morning / Afternoon / Evening cards. The cards are only row
  /// backgrounds: a background fills the whole cell, so rows keep their own insets and title width.
  struct DayPartRows<Item: Identifiable, Row: View>: View {
    let rows: [DayPartRow<Item>]
    let swipes: DayPartSwipes
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
      ForEach(rows) { entry in
        switch entry {
        case .label(let part): DayPartLabel(part: part)
        case .cardEnd: DayPartGap()
        case .item(let item, let card, let closesCard):
          row(item)
            .listRowBackground(
              card.map {
                DayPartFill(
                  part: $0, edge: closesCard ? .bottom : .middle, id: entry.id, swipes: swipes)
              }
            )
            // Here, not on the fill: a row deleted mid-swipe never reports its background gone.
            .onDisappear { swipes.slides[entry.id] = nil }
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
    static let swipeClose = Duration.seconds(1)
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
        .font(AgendaRowStyle.detail.weight(.semibold))
        .foregroundStyle(part.color.mix(with: .primary, by: 0.35))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 4, trailing: 20))
        .listRowBackground(DayPartShape(part: part, edge: .top))
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

  /// A swipe slides a row's whole cell, fill included, and the clear List shows the page behind it.
  /// So a row that has left its place hands its fill to the still layer behind the List.
  @MainActor @Observable final class DayPartSwipes {
    struct Slide: Equatable {
      let part: DayPart
      let edge: DayPartEdge
      let frame: CGRect
    }

    /// Global positions: a row background does not see a named coordinate space set on the List.
    var slides: [AnyHashable: Slide] = [:]
    var listOrigin = CGPoint.zero
  }

  /// Sits behind the List and holds the fill of each swiped row.
  struct DayPartSwipeLayer: View {
    let swipes: DayPartSwipes

    var body: some View {
      ZStack(alignment: .topLeading) {
        ForEach(Array(swipes.slides), id: \.key) { _, slide in
          DayPartShape(part: slide.part, edge: slide.edge)
            .frame(width: slide.frame.width, height: slide.frame.height)
            .offset(y: slide.frame.minY - swipes.listOrigin.y)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .allowsHitTesting(false)
      .onGeometryChange(for: CGPoint.self) {
        $0.frame(in: .global).origin
      } action: {
        swipes.listOrigin = $0
      }
    }
  }

  /// A row's fill in its cell, handed to `DayPartSwipeLayer` while a swipe moves the cell off the List's left edge.
  private struct DayPartFill: View {
    let part: DayPart
    let edge: DayPartEdge
    let id: AnyHashable
    let swipes: DayPartSwipes
    @State private var release: Task<Void, Never>?

    var body: some View {
      DayPartShape(part: part, edge: edge)
        .opacity(swipes.slides[id] == nil ? 1 : 0)
        .onGeometryChange(for: CGRect.self) {
          $0.frame(in: .global)
        } action: { cell in
          let swiped = abs(cell.minX - swipes.listOrigin.x) >= 0.5
          guard swiped || swipes.slides[id] != nil else { return }
          swipes.slides[id] = DayPartSwipes.Slide(
            part: part, edge: edge,
            frame: CGRect(x: 0, y: cell.minY, width: cell.width, height: cell.height))
          release?.cancel()
          guard !swiped else { return }
          // UIKit reports the closed position as the close animation starts, so the fill waits it out.
          release = Task {
            guard (try? await Task.sleep(for: DayPartMetrics.swipeClose)) != nil else { return }
            swipes.slides[id] = nil
          }
        }
    }
  }

  enum DayPartEdge { case top, middle, bottom }

  private struct DayPartShape: View {
    let part: DayPart
    let edge: DayPartEdge
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
