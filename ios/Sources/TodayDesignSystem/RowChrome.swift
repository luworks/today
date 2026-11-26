#if os(iOS)
  import SwiftUI
  import TodayCore

  /// Today typography and geometry; semantic fonts continue to follow Dynamic Type.
  package enum AgendaRowStyle {
    package static let title = Font.callout
    package static let detail = Font.footnote
    package static let disclosure = Font.footnote
    package static let iconWidth: CGFloat = 26
    package static let titleGap: CGFloat = 4
    package static let timeWidth: CGFloat = 50
    package static let minHeight: CGFloat = ButtonConfiguration.minimumHitSize
    package static let verticalPadding: CGFloat = 2
  }

  /// One vertical rhythm for every Today row. Elsewhere rows keep the 44pt floor.
  package struct AgendaRowFrame: ViewModifier {
    package var enabled: Bool
    package init(enabled: Bool) { self.enabled = enabled }
    @ViewBuilder package func body(content: Content) -> some View {
      if enabled {
        content
          .padding(.vertical, AgendaRowStyle.verticalPadding)
          .frame(minHeight: AgendaRowStyle.minHeight)
      } else {
        content.frame(minHeight: ButtonConfiguration.minimumHitSize)
      }
    }
  }

  /// One title line tall, holding `content` on the title's first line. The invisible glyph
  /// supplies the real baseline; a 44pt target overflows the slot without growing the row.
  package struct AgendaLineSlot: ViewModifier {
    package var width: CGFloat
    package init(width: CGFloat) { self.width = width }
    package func body(content: Content) -> some View {
      Text(" ").font(AgendaRowStyle.title).hidden()
        .frame(width: width)
        .overlay { content }
    }
  }

  /// A 44pt checkbox can extend into the time gutter, where it wins over the time label; never into the title.
  package struct AgendaIconSlot: ViewModifier {
    package var enabled: Bool
    package init(enabled: Bool) { self.enabled = enabled }
    @ViewBuilder package func body(content: Content) -> some View {
      if enabled {
        content
          .modifier(AgendaLineSlot(width: AgendaRowStyle.iconWidth))
          .padding(.trailing, AgendaRowStyle.titleGap)
      } else {
        content
      }
    }
  }

  extension EnvironmentValues {
    /// Set on a row whose time can change: tapping its time label calls this.
    @Entry package var agendaTimeEdit: (@MainActor () -> Void)?
    /// Set on the row being dragged: the time it would land at, shown as an accent pill.
    @Entry package var agendaDragTime: Date?
  }

  /// A subordinate line in the existing agenda time column, shared by events, Now and free time.
  package struct AgendaSecondaryTime: DynamicProperty {
    @Environment(PlannerPresentation.self) private var presentation
    @AppStorage(CalendarTimeZone.enabledKey) private var enabled = false
    @AppStorage(CalendarTimeZone.cityKey) private var storedCity = ""

    package init() {}

    package struct Label {
      let visible: String
      package let spoken: String
    }

    @MainActor package func label(at date: Date) -> Label? {
      guard enabled, let city = CalendarTimeZone.city(stored: storedCity), let zone = city.timeZone,
        let time = CalendarTimeZone.workingTimeLabel(
          at: date, zone: zone, local: presentation.calendar)
      else { return nil }
      let prefix = city.name == "Beijing" ? "BJ" : String(city.name.prefix(2)).uppercased()
      return Label(visible: "\(prefix) \(time)", spoken: "\(city.name) \(time)")
    }

    @MainActor package static func line(_ label: Label) -> some View {
      Text(verbatim: label.visible)
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(Color(.secondaryLabel))
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .frame(width: AgendaRowStyle.timeWidth, alignment: .leading)
        .accessibilityLabel(Text(verbatim: label.spoken))
        .accessibilityIdentifier("today.secondZone.time")
    }
  }

  package struct TimeColumn: View {
    package init(date: Date, compact: Bool = false, tint: Color? = nil) {
      self.date = date
      self.compact = compact
      self.tint = tint
    }
    package var compact = false
    package let date: Date
    package var tint: Color?
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.agendaTimeEdit) private var edit
    @Environment(\.agendaDragTime) private var dragTime
    private var secondaryTime = AgendaSecondaryTime()
    private func label(_ value: Date) -> Text {
      Text(
        value.formatted(
          Date.FormatStyle(
            date: .omitted, time: .shortened, locale: presentation.locale,
            calendar: presentation.calendar, timeZone: presentation.calendar.timeZone)))
    }

    package var body: some View {
      // An overlay, so the 44pt target leaves the row's height alone.
      VStack(alignment: .leading, spacing: 0) {
        column
        if compact, let remote = secondaryTime.label(at: dragTime ?? date) {
          AgendaSecondaryTime.line(remote)
        }
      }
      .overlay(alignment: .leading) {
        if compact, let edit {
          Button(action: edit) {
            Color.clear
              .frame(
                width: AgendaRowStyle.timeWidth,
                height: ButtonConfiguration.minimumHitSize
              )
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityHidden(true)
        }
      }
    }

    private var column: some View {
      ZStack(alignment: .leading) {
        if compact {
          // Reserve the same two-digit hour and AM/PM width in every Today row.
          // Hidden references size the localized column without truncating large text.
          ForEach([11, 23], id: \.self) { hour in
            label(
              presentation.calendar.date(bySettingHour: hour, minute: 58, second: 0, of: date)
                ?? date
            ).hidden()
          }
        }
        if let dragTime {
          label(dragTime)
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .background(
              Capsule().fill(Color.accentColor).padding(.horizontal, -5).padding(.vertical, -2))
        } else {
          label(date)
        }
      }
      .font(AgendaRowStyle.detail.monospacedDigit())
      .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
      .lineLimit(1)
      .fixedSize()
      .frame(minWidth: compact ? AgendaRowStyle.timeWidth : 58, alignment: .leading)
    }
  }

  /// Title and detail share at most two lines, including at accessibility text sizes.
  /// Today's rows prioritize a trailing detail and allow long titles to wrap once.
  package struct TitleDetail<Detail: View>: View {
    package init(
      title: Text, hasDetail: Bool = true, agendaStyle: Bool = false,
      @ViewBuilder detail: () -> Detail
    ) {
      self.title = title
      self.hasDetail = hasDetail
      self.agendaStyle = agendaStyle
      self.detail = detail()
    }
    package let title: Text
    package let hasDetail: Bool
    package let agendaStyle: Bool
    @ViewBuilder package var detail: Detail
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder package var body: some View {
      if agendaStyle, !typeSize.isAccessibilitySize {
        if hasDetail {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            title.lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            detail.lineLimit(1).layoutPriority(1)
          }
        } else {
          title.lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
      } else if hasDetail {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            title.lineLimit(1)
            detail.lineLimit(1)
          }
          VStack(alignment: .leading, spacing: 1) {
            title.lineLimit(1)
            detail.lineLimit(1)
          }
        }
      } else {
        title.lineLimit(2)
      }
    }
  }

  /// The travel-time line under an event with a location: "Drive 18 min · Leave by 14:20".
  package struct TravelLine: View {
    package init(text: String) { self.text = text }
    @Environment(\.dynamicTypeSize) private var typeSize
    package let text: String
    package var body: some View {
      Label(text, systemImage: "car.fill")
        .font(AgendaRowStyle.detail)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        // One line normally; at accessibility sizes "Drive 18 min · Leave by 14:20" wraps instead of losing the time.
        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
    }
  }

  /// The calendar color bar beside an event; it stretches to the height of the row's text.
  package struct CalendarBar: View {
    package init(color: Color) { self.color = color }
    package let color: Color
    package var body: some View {
      RoundedRectangle(cornerRadius: 2)
        .fill(color)
        .frame(width: 4)
        .frame(minHeight: 18, maxHeight: .infinity)
    }
  }

  package struct NowRow: View {
    let date: Date
    let free: DateInterval?
    let openFree: () -> Void

    package init(date: Date, free: DateInterval?, openFree: @escaping () -> Void) {
      self.date = date
      self.free = free
      self.openFree = openFree
    }

    package var body: some View {
      Group {
        if let free {
          Button(action: openFree) {
            line(freeLabel: DaySchedule.freeLabel(free.duration))
          }
          .buttonStyle(.plain)
          .accessibilityHint("Shows reminders that could fit here")
          .accessibilityIdentifier("today.freeRow")
        } else {
          line(freeLabel: nil)
            .accessibilityElement(children: .combine)
        }
      }
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
    }

    private func line(freeLabel: String?) -> some View {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        TimeColumn(date: date, compact: true, tint: .red)
        NowDot().modifier(AgendaIconSlot(enabled: true))
        Text("Now").font(AgendaRowStyle.detail.weight(.semibold)).foregroundStyle(.red)
        if let freeLabel {
          Text(freeLabel)
            .font(AgendaRowStyle.detail)
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
        }
        Spacer(minLength: 0)
      }
      .frame(minHeight: AgendaRowStyle.minHeight)
      .background(Color.red.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
    }
  }

  /// Only this decoration animates; the agenda keeps its existing minute clock.
  private struct NowDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    private var animates: Bool { visible && scenePhase == .active && !reduceMotion }
    var body: some View {
      ZStack {
        if animates {
          BreathingHalo()
        } else {
          Circle().fill(Color.red.opacity(0.12)).frame(width: 24, height: 24)
        }
        Circle().fill(.red).frame(width: 12, height: 12)
      }
      .frame(width: 32, height: 18)
      .accessibilityHidden(true)
      .onScrollVisibilityChange(threshold: 0.1) { visible = $0 }
      .onDisappear { visible = false }
    }
  }

  private struct BreathingHalo: View {
    @State private var expanded = false
    var body: some View {
      Circle()
        .fill(
          RadialGradient(
            colors: [.red.opacity(0.4), .red.opacity(0)],
            center: .center, startRadius: 3, endRadius: 16)
        )
        .frame(width: 32, height: 32)
        .scaleEffect(expanded ? 1 : 0.65)
        .opacity(expanded ? 0.6 : 1)
        .onAppear {
          withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            expanded = true
          }
        }
    }
  }
#endif
