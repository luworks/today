#if os(iOS)
  import One
  import SwiftUI
  import TodayCore
  import TodayPlatform
  import TodayDesignSystem

  /// Row for a system calendar event (read-only, opens nothing).
  package struct ExternalEventRow: View {
    @Environment(PlannerPresentation.self) private var presentation
    package init(
      event: ExternalEvent, pendingDelete: Binding<CalEntry?>, calendar: any CalendarService,
      travel: any TravelTimeProviding, attention: TodayRowAttention? = nil
    ) {
      self.attention = attention
      self.event = event
      _pendingDelete = pendingDelete
      self.calendar = calendar
      self.travelProvider = travel
    }
    private let attention: TodayRowAttention?
    private let calendar: any CalendarService
    private let travelProvider: any TravelTimeProviding
    package let event: ExternalEvent
    /// The list that holds this row asks "this event or the series?" (see `entryDeleteDialog`).
    @Binding package var pendingDelete: CalEntry?
    @AppStorage(SettingsKey.travelTime) private var travelOn = true

    /// The same swipe and long-press actions as in the Calendar tab.
    private var entry: CalEntry {
      CalEntry(
        id: event.id, source: .system(event.eventIdentifier), title: event.title,
        location: event.location,
        start: event.start, end: event.end, isAllDay: event.isAllDay, color: event.color,
        calendarTitle: event.calendarTitle,
        repeats: event.repeats)
    }

    package var body: some View {
      HStack(
        alignment: attention == nil ? .center : .firstTextBaseline,
        spacing: attention == nil ? 10 : 0
      ) {
        if !event.isAllDay {
          TimeColumn(date: event.start, compact: attention != nil).dynamicTypeSize(
            ...(attention == nil ? DynamicTypeSize.accessibility5 : .xxxLarge))
        }
        CalendarBar(color: event.color)
          .frame(height: attention == nil ? nil : 20)
          .modifier(AgendaIconSlot(enabled: attention != nil))
        VStack(alignment: .leading, spacing: 1) {
          TitleDetail(title: Text(event.title)) {
            Group {
              if attention != nil {
                Text(rowDetail)
              } else {
                Label(rowDetail, systemImage: "calendar")
                  .labelStyle(.titleAndIcon)
              }
            }
            .font(attention == nil ? .caption : AgendaRowStyle.detail)
            .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
      }
      .fixedSize(horizontal: false, vertical: true)
      .modifier(AgendaRowFrame(enabled: attention != nil))
      .contentShape(Rectangle())
      .font(attention == nil ? Font.body : AgendaRowStyle.title)
      .modifier(TodayItemSurface(enabled: attention != nil))
      .onTapGesture {
        (calendar as? any NativeCalendarService)?.edit(
          identifier: event.eventIdentifier, start: event.start, end: nil, onComplete: nil)
      }
      .entryActions(
        entry, pendingDelete: $pendingDelete,
        open: { _ in
          (calendar as? any NativeCalendarService)?.edit(
            identifier: event.eventIdentifier, start: event.start, end: nil, onComplete: nil)
        },
        edit: { _ in
          (calendar as? any NativeCalendarService)?.edit(
            identifier: event.eventIdentifier, start: event.start, end: nil, onComplete: nil)
        }, calendar: calendar, attention: attention
      )
      .listRowSeparator(.hidden)
      .listRowInsets(
        EdgeInsets(
          top: attention == nil ? 1 : 0, leading: attention == nil ? 20 : 12,
          bottom: attention == nil ? 1 : 0, trailing: attention == nil ? 20 : 12)
      )
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        plannerEventSpeech(
          title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay,
          location: event.location, calendar: event.calendarTitle, runtime: presentation.runtime)
          + (travel.map { ". " + $0 } ?? "")
      )
      .accessibilityAddTraits(.isButton)
    }

    private var detail: String {
      event.isAllDay
        ? event.calendarTitle
        : "\(DurationLabel.text(minutes: event.durationMinutes)) · \(event.calendarTitle)"
    }

    private var rowDetail: String { detail + (travel.map { " · " + $0 } ?? "") }

    /// "Drive 18 min · Leave by 14:20" for an upcoming event with a location (today or tomorrow).
    private var travel: String? {
      guard travelOn else { return nil }
      return travelProvider.label(
        eventID: event.eventIdentifier, start: event.start, isAllDay: event.isAllDay,
        place: event.place, now: presentation.now)
    }
  }
#endif
