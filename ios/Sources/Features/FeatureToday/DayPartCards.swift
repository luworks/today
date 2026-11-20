#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem

  /// The timeline's rows in their faint neutral Morning / Afternoon / Evening cards. The cards are only row
  /// backgrounds: a background fills the whole cell, so rows keep their own insets and title width.
  struct DayPartRows<Item: Identifiable, Row: View>: View {
    let rows: [DayPartRow<Item>]
    let swipes: DayPartSwipes
    let drag: TimelineDragModel
    /// Toggles a part open or closed; nil leaves every label inert (a past day's history).
    var onToggle: ((DayPart) -> Void)? = nil
    /// The "time title" a collapsed part still shows for its first planned item.
    var previewText: ((Item) -> String?)? = nil
    @ViewBuilder let row: (Item) -> Row

    private var collapsedParts: Set<DayPart> {
      Set(
        rows.compactMap {
          if case .collapsed(let part, _, _) = $0 { part } else { nil }
        })
    }

    var body: some View {
      let collapsed = collapsedParts
      ForEach(rows) { entry in
        switch entry {
        case .label(let part):
          DayPartLabel(part: part, onToggle: onToggle).modifier(drag.frameReader(entry.id))
        case .collapsed(let part, let preview, let extraCount):
          DayPartCollapsedLabel(
            part: part, preview: preview.flatMap { previewText?($0) }, extraCount: extraCount,
            onToggle: onToggle
          )
          .modifier(drag.frameReader(entry.id))
        case .cardEnd(let part): if !collapsed.contains(part) { DayPartGap() }
        case .emptyPart:
          Color.clear
            .frame(height: AgendaRowStyle.minHeight)
            .accessibilityHidden(true)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(DayPartFill(edge: .bottom, id: entry.id, swipes: swipes))
        case .item(let item, let card, let closesCard):
          row(item)
            .modifier(drag.frameReader(entry.id))
            .listRowBackground(
              card.map { _ in
                DayPartFill(edge: closesCard ? .bottom : .middle, id: entry.id, swipes: swipes)
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

  extension DayPart {
    var agendaTitle: String {
      switch self {
      case .morning: "Morning"
      case .afternoon: "Afternoon"
      case .evening: "Evening"
      }
    }

    var disclosureIdentifier: String {
      switch self {
      case .morning: "dayPart.morning"
      case .afternoon: "dayPart.afternoon"
      case .evening: "dayPart.evening"
      }
    }
  }

  /// Heads an open card. With a toggle it is the Settled-style disclosure row: title, hairline, chevron.
  private struct DayPartLabel: View {
    let part: DayPart
    var onToggle: ((DayPart) -> Void)? = nil

    var body: some View {
      Group {
        if let onToggle {
          Button {
            onToggle(part)
          } label: {
            HStack {
              Text(part.agendaTitle).font(AgendaRowStyle.detail.weight(.semibold))
              Rectangle().fill(.quaternary).frame(height: 1)
              Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(part.disclosureIdentifier)
          .accessibilityLabel(part.agendaTitle)
          .accessibilityValue("Expanded")
        } else {
          Text(part.agendaTitle)
            .font(AgendaRowStyle.detail.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
        }
      }
      .listRowSeparator(.hidden)
      .listRowInsets(
        EdgeInsets(top: onToggle == nil ? 10 : 0, leading: 20, bottom: 0, trailing: 20)
      )
      .listRowBackground(DayPartShape(edge: .top))
    }
  }

  /// A closed part on one line, like Settled: title, hairline, its first timed item ("18:30 Gym +2"), chevron.
  private struct DayPartCollapsedLabel: View {
    let part: DayPart
    let preview: String?
    let extraCount: Int
    var onToggle: ((DayPart) -> Void)? = nil

    private var previewText: String? {
      guard let preview else { return nil }
      return extraCount > 0 ? "\(preview) +\(extraCount)" : preview
    }

    private var accessibilityText: String {
      guard let preview else { return part.agendaTitle }
      return extraCount > 0
        ? "\(part.agendaTitle), \(preview), \(extraCount) more" : "\(part.agendaTitle), \(preview)"
    }

    var body: some View {
      Button {
        onToggle?(part)
      } label: {
        HStack {
          Text(part.agendaTitle).font(AgendaRowStyle.detail.weight(.semibold))
          Rectangle().fill(.quaternary).frame(height: 1)
          if let previewText {
            Text(previewText)
              .font(AgendaRowStyle.detail)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          Image(systemName: "chevron.right").font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(onToggle == nil)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
      .listRowBackground(Color.clear)
      .accessibilityIdentifier(part.disclosureIdentifier)
      .accessibilityLabel(accessibilityText)
      .accessibilityValue("Collapsed")
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

  /// A row's fill in its cell, handed to `DayPartSwipeLayer` while a swipe moves the cell off the List's left edge.
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
          // UIKit reports the closed position as the close animation starts, so the fill waits it out.
          release = Task {
            guard (try? await Task.sleep(for: DayPartMetrics.swipeClose)) != nil else { return }
            swipes.slides[id] = nil
          }
        }
    }
  }

  enum DayPartEdge { case top, middle, bottom }

  /// One neutral fill for every card: the shape and the gaps do the grouping.
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
      // Runs past its short cell: a shape cannot round more than its own height, and Free rows are short.
      .padding(.bottom, edge == .bottom ? -DayPartMetrics.endPadding : 0)
    }
  }
#endif
