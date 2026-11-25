#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem

  struct DayPartRows<Item: Identifiable, Row: View>: View {
    let rows: [DayPartRow<Item>]
    let drag: TimelineDragModel
    var viewport: TimelineViewport? = nil
    let toggle: (DayPart) -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
      ForEach(rows) { entry in
        switch entry {
        case .label(let part, let count, let isOpen):
          TodaySectionHeader(
            title: part.agendaTitle, count: count, isOpen: isOpen,
            identifier: "dayPart.\(part.rawValue)"
          ) { toggle(part) }
        case .item(let item, _):
          row(item)
            .modifier(drag.frameReader(entry.id, viewport: viewport))
            .listRowBackground(Color.clear)
        }
      }
    }
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

  struct TodaySectionHeader: View {
    let title: String
    let count: Int
    let isOpen: Bool
    let identifier: String
    let toggle: () -> Void

    var body: some View {
      Button(action: toggle) {
        HStack(spacing: 10) {
          Text("\(title) (\(count))").font(AgendaRowStyle.disclosure)
          Rectangle().fill(.quaternary).frame(height: 1)
          Image(systemName: isOpen ? "chevron.up" : "chevron.down")
            .font(.footnote)
            .frame(width: 20)
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 30)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(title), \(count)")
      .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier(identifier)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
      .listRowBackground(Color.clear)
    }
  }
#endif
