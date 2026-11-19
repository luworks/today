#if os(iOS)
  import SwiftUI
  import TodayCore

  package struct WeekStrip: View {
    /// `calendar` sets the first day of the week; without it the week starts on Monday.
    package init(selected: Binding<Date>, calendar: Calendar? = nil) {
      _selected = selected
      self.calendar = calendar
    }
    @Binding package var selected: Date
    private let calendar: Calendar?
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum DragAxis { case undecided, horizontal, ignored }
    @GestureState private var touching = false
    @State private var dragAxis: DragAxis?
    @State private var swipe = WeekStripSwipe()
    @State private var localSelection: Date?
    @State private var selections = 0
    @State private var detents = 0
    @State private var landings = 0

    private var cal: Calendar {
      if let calendar { return calendar }
      var c = presentation.calendar
      c.firstWeekday = 2  // Monday
      return c
    }

    private func weekDays(starting start: Date) -> [Date] {
      return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    package var body: some View {
      let settle = swipe.settle
      GeometryReader { geometry in
        let width = geometry.size.width
        let center = cal.dateInterval(of: .weekOfYear, for: selected)?.start ?? selected
        let extent = reduceMotion ? 0 : (settle?.start ?? swipe.offset(at: CACurrentMediaTime()))
        let first = min(-1, -Int(ceil(extent)))
        let last = max(1, -Int(floor(extent)))
        let pages = (first...last).compactMap { index in
          cal.date(byAdding: .day, value: index * 7, to: center).map { (index: index, start: $0) }
        }
        TimelineView(.animation(paused: reduceMotion || !swipe.needsFrames)) { _ in
          let offset = reduceMotion ? 0 : swipe.offset(at: CACurrentMediaTime())
          ZStack {
            ForEach(pages, id: \.start) { page in
              week(starting: page.start)
                .frame(width: width)
                .offset(x: (CGFloat(page.index) + offset) * width)
                .accessibilityHidden(page.index != 0)
                .allowsHitTesting(page.index == 0)
            }
          }
        }
        .frame(width: width, height: 52)
        .clipped()
        .contentShape(Rectangle())
        .highPriorityGesture(
          DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { value in dragChanged(value, width: width) }
            .onEnded { value in
              let horizontal = dragAxis == .horizontal
              dragAxis = nil
              finish(pages: width > 0 ? value.translation.width / width : 0, cancelled: !horizontal)
            }
        )
        .onChange(of: touching) { _, active in
          guard !active, dragAxis != nil else { return }
          dragAxis = nil
          finish(pages: 0, cancelled: true)
        }
      }
      .frame(height: 52)
      .task(id: settle) {
        guard let settle else { return }
        let remaining = max(0, settle.time + settle.duration - CACurrentMediaTime())
        do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        guard !Task.isCancelled else { return }
        if swipe.complete(settle) { landings += 1 }
      }
      .onChange(of: selected) { _, new in
        if localSelection != new { swipe = WeekStripSwipe() }
        localSelection = nil
      }
      .sensoryFeedback(InteractionFeedback.selection, trigger: selections)
      .sensoryFeedback(InteractionFeedback.detent, trigger: detents)
      .sensoryFeedback(InteractionFeedback.settle, trigger: landings)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("weekStrip")
      .accessibilityAction(named: "Previous week") { moveWeek(-1) }
      .accessibilityAction(named: "Next week") { moveWeek(1) }
      .buttonStyle(.borderless)
      .tint(.primary)
    }

    private func week(starting start: Date) -> some View {
      let now = presentation.now
      return HStack(spacing: 2) {
        ForEach(weekDays(starting: start), id: \.self) { d in
          let isSelected = cal.isDate(d, inSameDayAs: selected)
          Button {
            guard !isSelected else { return }
            swipe = WeekStripSwipe()
            select(cal.startOfDay(for: d))
            selections += 1
          } label: {
            VStack(spacing: 4) {
              Text(
                d.formatted(
                  Date.FormatStyle(
                    locale: presentation.locale, calendar: cal, timeZone: cal.timeZone
                  ).weekday(.narrow))
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
              Text("\(cal.component(.day, from: d))")
                .font(.callout.weight(isSelected ? .bold : .regular))
                .frame(width: 32, height: 32)
                .background(isSelected ? Color.accentColor : Color.clear, in: Circle())
                .foregroundStyle(
                  isSelected
                    ? Color.accentColor.contrastForeground(for: colorScheme)
                    : (cal.isDate(d, inSameDayAs: now) ? Color.accentColor : Color.primary)
                )
                .animation(
                  reduceMotion ? nil : InteractionFeedback.dateSelection, value: isSelected)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
          }
          .accessibilityLabel(
            d.formatted(
              Date.FormatStyle(locale: presentation.locale, calendar: cal, timeZone: cal.timeZone)
                .weekday(.wide).month(.wide).day())
          )
          .accessibilityAddTraits(isSelected ? .isSelected : [])
          .accessibilityIdentifier("weekStrip." + Self.key(d, cal))
        }
      }
    }

    /// "weekStrip.2026-10-26": a stable handle for UI tests.
    private static func key(_ d: Date, _ cal: Calendar) -> String {
      let c = cal.dateComponents([.year, .month, .day], from: d)
      return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func select(_ date: Date) {
      localSelection = date
      selected = date
    }

    private func dragChanged(_ value: DragGesture.Value, width: CGFloat) {
      guard width > 0 else { return }
      let now = CACurrentMediaTime()
      if dragAxis == nil {
        swipe.touchDown(at: now)
        dragAxis = .undecided
      }
      let x = value.translation.width
      let y = value.translation.height
      if dragAxis == .undecided {
        guard max(abs(x), abs(y)) >= 8 else { return }
        let opensDrawer = x > 0 && value.startLocation.x <= DrawerLayout.edgeSwipeWidth
        let horizontal = abs(x) > abs(y) && !opensDrawer
        dragAxis = horizontal ? .horizontal : .ignored
        if !horizontal { finish(pages: 0, cancelled: true) }
      }
      if dragAxis == .horizontal, swipe.drag(x / width, at: now) { detents += 1 }
    }

    private func finish(pages: CGFloat, cancelled: Bool) {
      let step = swipe.release(
        pages, cancelled: cancelled, animated: !reduceMotion,
        at: CACurrentMediaTime())
      guard step != 0, let date = cal.date(byAdding: .day, value: step * 7, to: selected) else {
        return
      }
      select(date)
      if swipe.settle == nil { landings += 1 }
    }

    private func moveWeek(_ step: Int) {
      guard let date = cal.date(byAdding: .day, value: step * 7, to: selected) else { return }
      swipe = WeekStripSwipe()
      select(date)
      landings += 1
    }
  }

#endif
