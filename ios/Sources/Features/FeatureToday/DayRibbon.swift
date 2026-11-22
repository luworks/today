#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem

  struct DayRibbon: View {
    struct Mark: Equatable {
      let start: Date
      let end: Date?
      let kind: TodayTimeline.Kind
      let repeats: Bool
      let faded: Bool
      let late: Bool
    }

    let marks: [Mark]
    let range: DateInterval
    let calendar: Calendar
    let now: Date?
    let viewport: TimelineViewport
    let label: (Date) -> String
    let pick: (Date, Bool) -> Bool
    let showNow: () -> Void

    static let height: CGFloat = 46

    @Environment(\.colorScheme) private var colorScheme
    @GestureState private var touching = false
    @State private var axis: Axis?
    @State private var detents = 0
    @State private var settles = 0

    private enum Axis { case horizontal, ignored }

    var body: some View {
      let visibleRange = viewport.range
      GeometryReader { geometry in
        let frame = geometry.frame(in: .global)
        DayRibbonTrack(marks: marks, range: range, calendar: calendar, now: now)
          .equatable()
          .overlay {
            if let visibleRange {
              Canvas { context, size in
                drawViewport(visibleRange, in: &context, width: size.width)
              }
              .allowsHitTesting(false)
              .accessibilityHidden(true)
            }
          }
          .contentShape(Rectangle())
          .highPriorityGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
              .updating($touching) { _, state, _ in state = true }
              .onChanged { changed($0, frame: frame) }
              .onEnded { _ in finish() }
          )
          .onTapGesture(coordinateSpace: .local) { point in
            _ = pick(date(at: point.x, width: frame.width), true)
            settles += 1
          }
          .onChange(of: touching) { _, active in
            if !active, axis != nil { finish() }
          }
      }
      .frame(height: Self.height)
      .drawerSwipeExcluded()
      .overlay(alignment: .topTrailing) {
        if let now, range.contains(now), visibleRange?.contains(now) != true, axis == nil {
          Button {
            showNow()
            settles += 1
          } label: {
            Text("Now")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(Capsule().fill(Color.red))
              .contentShape(Rectangle().inset(by: -10))
          }
          .buttonStyle(.plain)
          .offset(y: -8)
          .accessibilityIdentifier("today.ribbon.now")
          .accessibilityLabel("Show now")
        }
      }
      .sensoryFeedback(InteractionFeedback.detent, trigger: detents)
      .sensoryFeedback(InteractionFeedback.settle, trigger: settles)
      .accessibilityElement()
      .accessibilityLabel("Day overview")
      .accessibilityValue(spokenValue(visibleRange))
      .accessibilityAdjustableAction { direction in
        let from = visibleRange?.start ?? range.start
        let step: TimeInterval = direction == .increment ? 3600 : -3600
        _ = pick(from.addingTimeInterval(step), true)
      }
      .accessibilityIdentifier("today.ribbon")
    }

    private func spokenValue(_ viewport: DateInterval?) -> String {
      guard let viewport else { return "\(marks.count) items" }
      return "Showing \(label(viewport.start)) to \(label(viewport.end))"
    }

    private func date(at x: CGFloat, width: CGFloat) -> Date {
      guard width > 0 else { return range.start }
      return TodayTimeline.date(at: Double(x / width), in: range)
    }

    private func changed(_ value: DragGesture.Value, frame: CGRect) {
      if axis == nil {
        let dx = value.translation.width
        let dy = value.translation.height
        let opensDrawer = dx > 0 && value.startLocation.x <= DrawerLayout.edgeSwipeWidth
        axis = abs(dx) > abs(dy) && !opensDrawer ? .horizontal : .ignored
      }
      guard axis == .horizontal else { return }
      if pick(date(at: value.location.x - frame.minX, width: frame.width), false) {
        detents += 1
      }
    }

    private func finish() {
      if axis == .horizontal { settles += 1 }
      axis = nil
    }

    private func drawViewport(
      _ viewport: DateInterval, in context: inout GraphicsContext, width: CGFloat
    ) {
      let left = max(0, ribbonX(viewport.start, in: range, width: width))
      let right = min(width, ribbonX(viewport.end, in: range, width: width))
      let frame = CGRect(x: min(left, width - 12), y: 5, width: max(right - left, 12), height: 28)
      let box = Path(roundedRect: frame, cornerRadius: 9)
      context.fill(
        box, with: .color(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14)))
      context.stroke(box, with: .color(Color.accentColor.opacity(0.9)), lineWidth: 1.5)
    }
  }

  private struct DayRibbonTrack: View, Equatable {
    let marks: [DayRibbon.Mark]
    let range: DateInterval
    let calendar: Calendar
    let now: Date?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.range == rhs.range && lhs.calendar == rhs.calendar && lhs.now == rhs.now
        && lhs.marks == rhs.marks
    }

    var body: some View {
      Canvas { context, size in
        let width = size.width
        context.fill(
          Path(CGRect(x: 0, y: 18.5, width: width, height: 1)), with: .color(Color(.separator)))
        drawHours(in: &context, width: width)
        for mark in marks { drawMark(mark, in: &context, width: width) }
        if let now, range.contains(now) {
          context.fill(
            Path(CGRect(x: ribbonX(now, in: range, width: width) - 1, y: 4, width: 2, height: 30)),
            with: .color(.red))
        }
      }
    }

    private func drawHours(in context: inout GraphicsContext, width: CGFloat) {
      let midnight = calendar.startOfDay(for: range.start)
      for hour in stride(from: 0, through: 24, by: 3) {
        guard let tick = calendar.date(byAdding: .hour, value: hour, to: midnight),
          range.contains(tick)
        else { continue }
        let position = ribbonX(tick, in: range, width: width)
        let anchor: UnitPoint =
          position < 8 ? .leading : (position > width - 8 ? .trailing : .center)
        context.draw(
          Text("\(hour)").font(.system(size: 10)).foregroundStyle(Color(.tertiaryLabel)),
          at: CGPoint(x: position, y: 37), anchor: anchor)
      }
    }

    private func drawMark(
      _ mark: DayRibbon.Mark, in context: inout GraphicsContext, width: CGFloat
    ) {
      var layer = context
      if mark.faded { layer.opacity = 0.28 }
      let left = ribbonX(mark.start, in: range, width: width)
      switch mark.kind {
      case .event:
        let right = ribbonX(mark.end ?? mark.start, in: range, width: width)
        let rect = CGRect(x: left, y: 13, width: max(right - left, 5), height: 13)
        layer.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.blue))
      case .alarm:
        layer.fill(
          Path(roundedRect: CGRect(x: left - 1.25, y: 11, width: 2.5, height: 17), cornerRadius: 1),
          with: .color(.orange))
      case .reminder:
        let color: Color = mark.late ? .red : .primary
        if mark.repeats {
          layer.stroke(
            Path(ellipseIn: CGRect(x: left - 3.5, y: 16, width: 7, height: 7)),
            with: .color(color), lineWidth: 1.5)
        } else {
          layer.fill(
            Path(ellipseIn: CGRect(x: left - 4.5, y: 15, width: 9, height: 9)),
            with: .color(color))
        }
      }
    }
  }

  private func ribbonX(_ date: Date, in range: DateInterval, width: CGFloat) -> CGFloat {
    guard range.duration > 0 else { return 0 }
    return CGFloat(date.timeIntervalSince(range.start) / range.duration) * width
  }
#endif
