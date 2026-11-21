#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem

  struct DayPartRows<Item: Identifiable, Row: View>: View {
    let rows: [DayPartRow<Item>]
    let swipes: DayPartSwipes
    let drag: TimelineDragModel
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
      ForEach(rows) { entry in
        switch entry {
        case .label(let part): DayPartLabel(part: part)
        case .cardEnd: DayPartGap()
        case .item(let item, let card, let closesCard):
          row(item)
            .modifier(drag.frameReader(entry.id))
            .listRowBackground(
              card.map { _ in
                DayPartFill(edge: closesCard ? .bottom : .middle, id: entry.id, swipes: swipes)
              }
            )
            .onDisappear { swipes.slides[entry.id] = nil }
        }
      }
    }
  }

  private enum DayPartMetrics {
    static let margin: CGFloat = 8
    static let corner: CGFloat = 20
    static let gap: CGFloat = 10
    static let endPadding: CGFloat = 6
    static let swipeClose = Duration.seconds(1)
  }

  extension DayPart {
    var agendaTitle: String {
      switch self {
      case .morning: "Morning"
      case .afternoon: "Afternoon"
      case .evening: "Evening"
      }
    }
  }

  private struct DayPartLabel: View {
    let part: DayPart

    var body: some View {
      HStack {
        Text(part.agendaTitle).font(AgendaRowStyle.detail.weight(.semibold))
        Rectangle().fill(.quaternary).frame(height: 1)
      }
      .foregroundStyle(.secondary)
      .frame(minHeight: 32)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("dayPart.\(part.rawValue)")
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 0, trailing: 20))
      .listRowBackground(DayPartShape(edge: .top))
    }
  }

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

  @MainActor @Observable final class DayPartSwipes {
    struct Slide: Equatable {
      let edge: DayPartEdge
      let frame: CGRect
    }

    var slides: [AnyHashable: Slide] = [:]
    var listOrigin = CGPoint.zero
  }

  struct DayPartSwipeLayer: View {
    let swipes: DayPartSwipes

    var body: some View {
      ZStack(alignment: .topLeading) {
        ForEach(Array(swipes.slides), id: \.key) { _, slide in
          DayPartShape(edge: slide.edge)
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

  private struct DayPartFill: View {
    let edge: DayPartEdge
    let id: AnyHashable
    let swipes: DayPartSwipes
    @State private var release: Task<Void, Never>?

    var body: some View {
      DayPartShape(edge: edge)
        .opacity(swipes.slides[id] == nil ? 1 : 0)
        .onGeometryChange(for: CGRect.self) {
          $0.frame(in: .global)
        } action: { cell in
          let swiped = abs(cell.minX - swipes.listOrigin.x) >= 0.5
          guard swiped || swipes.slides[id] != nil else { return }
          swipes.slides[id] = DayPartSwipes.Slide(
            edge: edge, frame: CGRect(x: 0, y: cell.minY, width: cell.width, height: cell.height))
          release?.cancel()
          guard !swiped else { return }
          release = Task {
            guard (try? await Task.sleep(for: DayPartMetrics.swipeClose)) != nil else { return }
            swipes.slides[id] = nil
          }
        }
    }
  }

  enum DayPartEdge { case top, middle, bottom }

  private struct DayPartShape: View {
    let edge: DayPartEdge
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
      let top = edge == .top ? DayPartMetrics.corner : 0
      let bottom = edge == .bottom ? DayPartMetrics.corner : 0
      UnevenRoundedRectangle(
        cornerRadii: RectangleCornerRadii(
          topLeading: top, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: top),
        style: .continuous
      )
      .fill(Color(.secondarySystemBackground).opacity(colorScheme == .dark ? 0.75 : 0.6))
      .padding(.horizontal, DayPartMetrics.margin)
      .padding(.bottom, edge == .bottom ? -DayPartMetrics.endPadding : 0)
    }
  }
#endif
