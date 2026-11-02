#if os(iOS)
  import TodayCore
  import TodayDesignSystem
  import TodayPlannerUI
  import SwiftUI

  /// A row a past day rebuilt from Activity (`DayHistory`): a reminder completed then, an alarm stopped then, or an event
  /// deleted after it happened. Read-only: no tap, swipe or menu, because its source may be gone.
  struct PastDayRow: View {
    enum Mark {
      /// A completed reminder: the done style of a reminder row (green check, struck through, dimmed).
      case completed
      /// A stopped alarm: green check, dimmed.
      case stopped
      /// An event deleted after it started: a quiet bar, dimmed.
      case deletedEvent
    }

    @Environment(PlannerPresentation.self) private var presentation
    let time: Date
    let title: String
    let detail: String
    let mark: Mark
    /// The Today tab's layout (as `TodayRowAttention` gives the other rows); false in the Calendar's day list.
    let todayStyle: Bool

    var body: some View {
      HStack(
        alignment: todayStyle ? .firstTextBaseline : .center, spacing: todayStyle ? 0 : 10
      ) {
        TimeColumn(date: time, compact: todayStyle).dynamicTypeSize(
          ...(todayStyle ? DynamicTypeSize.xxxLarge : .accessibility5))
        icon.modifier(AgendaIconSlot(enabled: todayStyle))
        TitleDetail(
          title: Text(title.isEmpty ? fallbackTitle : title)
            .strikethrough(mark == .completed)
            .foregroundStyle(.secondary)
        ) {
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(minHeight: 44)
      .font(todayStyle ? AgendaRowStyle.title : Font.body)
      .modifier(TodayItemSurface(enabled: todayStyle))
      .listRowSeparator(.hidden)
      .listRowInsets(
        EdgeInsets(
          top: todayStyle ? 0 : 1, leading: todayStyle ? 12 : 20, bottom: todayStyle ? 0 : 1,
          trailing: todayStyle ? 12 : 20)
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(title.isEmpty ? fallbackTitle : title), \(detail), "
          + time.plannerFormatted(date: .omitted, time: .shortened, runtime: presentation.runtime)
      )
      .accessibilityIdentifier("today.history.row")
    }

    @ViewBuilder private var icon: some View {
      switch mark {
      case .completed, .stopped:
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(Color.green)
          .frame(minWidth: todayStyle ? nil : 24)
          .accessibilityHidden(true)
      case .deletedEvent:
        CalendarBar(color: Color(.tertiaryLabel))
          .frame(height: todayStyle ? 20 : nil)
      }
    }

    private var fallbackTitle: String {
      switch mark {
      case .completed: "Reminder"
      case .stopped: "Alarm"
      case .deletedEvent: "Event"
      }
    }
  }

#endif
