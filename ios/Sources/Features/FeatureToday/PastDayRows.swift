#if os(iOS)
  import TodayData
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

  struct HistoricalFactRow: View {
    let fact: DayHistory.Fact
    let todayStyle: Bool
    @State private var showsDetails = false

    var body: some View {
      PastDayRow(
        time: fact.at, title: fact.title, detail: fact.action,
        mark: fact.event.kind == "change.completed"
          ? .completed
          : (fact.event.kind == ActivityKind.sysAlarmStopped ? .stopped : .deletedEvent),
        todayStyle: todayStyle
      )
      .contentShape(Rectangle())
      .onTapGesture { showsDetails = true }
      .accessibilityAddTraits(.isButton)
      .sheet(isPresented: $showsDetails) {
        NavigationStack {
          List {
            Section("Recorded fact") {
              LabeledContent("Title", value: fact.title)
              LabeledContent("Action", value: fact.action)
              LabeledContent("Source", value: fact.event.subjectKind ?? "Unknown")
              LabeledContent(
                "Actor",
                value: fact.event.actor == "system"
                  ? "System" : LedgerActor(raw: fact.event.actor).name)
              LabeledContent("Channel", value: fact.event.channel ?? "Unknown")
              LabeledContent("Recorded time", value: fact.at.formatted())
              if let observed = ActivityProps.dictionary(fact.event.props)["observed_ms"]
                as? NSNumber
              {
                LabeledContent(
                  "Observed", value: ActivityClock.date(ms: observed.int64Value).formatted())
              } else {
                Text("Observation time unavailable in this record.")
              }
            }
            Section("Plan at the time") {
              LabeledContent(
                "Before",
                value: fact.event.beforeTs.map { ActivityClock.date(ms: $0).formatted() }
                  ?? "Not recorded")
              LabeledContent(
                "After",
                value: fact.event.afterTs.map { ActivityClock.date(ms: $0).formatted() }
                  ?? "Not recorded")
              if let before = fact.event.beforeText, !before.isEmpty { Text(before) }
              if let after = fact.event.afterText, !after.isEmpty { Text("→ " + after) }
            }
            Section {
              Text(
                "Read-only Activity record. Scheduled does not mean attended; stopped does not mean completed. History includes only observations retained by your Activity settings."
              )
              .font(.footnote).foregroundStyle(.secondary)
            }
          }
          .navigationTitle("History")
          .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { showsDetails = false } }
          }
        }
      }
    }
  }

#endif
