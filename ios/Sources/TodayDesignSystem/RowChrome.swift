#if os(iOS)
  import SwiftUI
  import TodayCore

  /// Today typography and geometry; semantic fonts continue to follow Dynamic Type.
  package enum AgendaRowStyle {
    package static let title = Font.callout
    package static let detail = Font.footnote
    package static let disclosure = Font.footnote
    package static let iconWidth: CGFloat = 32
    package static let titleGap: CGFloat = 6
    package static let timeWidth: CGFloat = 50
    /// A one-line row; a title with a secondary line grows past it by content plus padding.
    package static let minHeight: CGFloat = 38
    package static let verticalPadding: CGFloat = 5
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

  /// A 44pt checkbox can extend into the noninteractive time gutter, never into the title.
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

  package struct TimeColumn: View {
    package init(date: Date, compact: Bool = false) {
      self.date = date
      self.compact = compact
    }
    package var compact = false
    package let date: Date
    @Environment(PlannerPresentation.self) private var presentation
    private func label(_ value: Date) -> Text {
      Text(
        value.formatted(
          Date.FormatStyle(
            date: .omitted, time: .shortened, locale: presentation.locale,
            calendar: presentation.calendar, timeZone: presentation.calendar.timeZone)))
    }

    package var body: some View {
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
        label(date)
      }
      .font(AgendaRowStyle.detail.monospacedDigit())
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize()
      .frame(minWidth: compact ? AgendaRowStyle.timeWidth : 58, alignment: .leading)
    }
  }

  /// Title and detail share at most two lines, including at accessibility text sizes.
  package struct TitleDetail<Detail: View>: View {
    package init(title: Text, hasDetail: Bool = true, @ViewBuilder detail: () -> Detail) {
      self.title = title
      self.hasDetail = hasDetail
      self.detail = detail()
    }
    package let title: Text
    package let hasDetail: Bool
    @ViewBuilder package var detail: Detail

    @ViewBuilder package var body: some View {
      if hasDetail {
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
    package init(date: Date) { self.date = date }
    package let date: Date
    @Environment(PlannerPresentation.self) private var presentation
    package var body: some View {
      HStack(spacing: 8) {
        NowDot()
        Text(
          "Now "
            + date.formatted(
              Date.FormatStyle(
                date: .omitted, time: .shortened, locale: presentation.locale,
                calendar: presentation.calendar, timeZone: presentation.calendar.timeZone))
        )
        .font(AgendaRowStyle.detail.weight(.semibold).monospacedDigit())
        .foregroundStyle(.red)
        .fixedSize(horizontal: true, vertical: false)
        Rectangle().fill(Color.red).frame(height: 1)
      }
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
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
      .frame(width: 32, height: 32)
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
