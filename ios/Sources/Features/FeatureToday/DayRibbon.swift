#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem

  struct DayRibbon: View {
    struct Mark: Equatable {
      let start: Date
      let end: Date?
      let kind: TodayWindow.Kind
      let repeats: Bool
      let faded: Bool
      let late: Bool
    }

    let marks: [Mark]
    let range: DateInterval
    let calendar: Calendar
    let now: Date?
    let start: Date
    let end: Date
    let targets: [Date]
    let laterCount: Int
    let label: (Date) -> String
    let scrub: (Date) -> Void
    let jump: (Date) -> Void

    static let height: CGFloat = 46

    @Environment(\.colorScheme) private var colorScheme
    @GestureState private var touching = false
    @State private var axis: Axis?
    @State private var origin: Date?
    @State private var live: Date?
    @State private var tracker = TodayRibbonScrub()
    @State private var detents = 0
    @State private var settles = 0

    private enum Axis { case horizontal, ignored }

    private var isAtNow: Bool { now.map { abs(start.timeIntervalSince($0)) < 60 } ?? true }

    var body: some View {
      GeometryReader { geometry in
        let width = geometry.size.width
        Canvas { context, size in draw(in: &context, size: size) }
          .contentShape(Rectangle())
          .highPriorityGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
              .updating($touching) { _, state, _ in state = true }
              .onChanged { changed($0, width: width) }
              .onEnded { _ in finish() }
          )
          .onTapGesture(coordinateSpace: .local) { point in
            tap(at: point.x, width: width)
          }
          .onChange(of: touching) { _, active in
            if !active, axis != nil { finish() }
          }
      }
      .frame(height: Self.height)
      .overlay(alignment: .topTrailing) {
        if let now, !isAtNow, live == nil {
          Button {
            jump(now)
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
          .accessibilityLabel("Back to now")
        }
      }
      .sensoryFeedback(InteractionFeedback.detent, trigger: detents)
      .sensoryFeedback(InteractionFeedback.settle, trigger: settles)
      .accessibilityElement()
      .accessibilityLabel("Time window")
      .accessibilityValue(spokenValue)
      .accessibilityAdjustableAction { direction in
        let step = direction == .increment ? 1 : -1
        if let next = TodayWindow.step(from: start, by: step, in: targets) { jump(next) }
      }
      .accessibilityIdentifier("today.ribbon")
    }

    private var spokenValue: String {
      let shown = "Showing \(label(start)) to \(label(end))"
      return laterCount > 0 ? shown + ", \(laterCount) more later" : shown
    }

    private func x(_ date: Date, width: CGFloat) -> CGFloat {
      guard range.duration > 0 else { return 0 }
      return CGFloat(date.timeIntervalSince(range.start) / range.duration) * width
    }

    private func date(at x: CGFloat, width: CGFloat) -> Date {
      guard width > 0 else { return range.start }
      return range.start.addingTimeInterval(TimeInterval(x / width) * range.duration)
    }

    private func changed(_ value: DragGesture.Value, width: CGFloat) {
      let dx = value.translation.width
      let dy = value.translation.height
      if axis == nil {
        let opensDrawer = dx > 0 && value.startLocation.x <= DrawerLayout.edgeSwipeWidth
        axis = abs(dx) > abs(dy) && !opensDrawer ? .horizontal : .ignored
        origin = start
      }
      guard axis == .horizontal, let origin, width > 0 else { return }
      let moved = origin.addingTimeInterval(TimeInterval(dx / width) * range.duration)
      let position = TodayWindow.clamp(moved, in: range)
      live = position
      if tracker.move(to: position, targets: targets, at: CACurrentMediaTime()) { detents += 1 }
      if let snapped = TodayWindow.nearest(position, in: targets), snapped != start {
        scrub(snapped)
      }
    }

    private func finish() {
      defer {
        axis = nil
        origin = nil
        live = nil
      }
      guard axis == .horizontal, let position = live else { return }
      if let snapped = TodayWindow.nearest(position, in: targets) { scrub(snapped) }
      if tracker.release(at: CACurrentMediaTime()) { settles += 1 }
    }

    private func tap(at x: CGFloat, width: CGFloat) {
      guard let target = TodayWindow.nearest(date(at: x, width: width), in: targets),
        target != start
      else { return }
      jump(target)
      settles += 1
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
      let width = size.width
      context.fill(
        Path(CGRect(x: 0, y: 18.5, width: width, height: 1)), with: .color(Color(.separator)))
      drawHours(in: &context, width: width)
      for mark in marks { drawMark(mark, in: &context, width: width) }
      if let now, range.contains(now) {
        context.fill(
          Path(CGRect(x: x(now, width: width) - 1, y: 4, width: 2, height: 30)),
          with: .color(.red))
      }
      let shownStart = live ?? start
      let span = max(end.timeIntervalSince(start), 0)
      let left = max(0, x(shownStart, width: width))
      let right = min(width, x(shownStart.addingTimeInterval(span), width: width))
      let frame = CGRect(x: left, y: 5, width: max(right - left, 12), height: 28)
      let window = Path(roundedRect: frame, cornerRadius: 9)
      context.fill(
        window, with: .color(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14)))
      context.stroke(window, with: .color(Color.accentColor.opacity(0.9)), lineWidth: 1.5)
    }

    private func drawHours(in context: inout GraphicsContext, width: CGFloat) {
      let midnight = calendar.startOfDay(for: range.start)
      for hour in stride(from: 0, through: 24, by: 3) {
        guard let tick = calendar.date(byAdding: .hour, value: hour, to: midnight),
          range.contains(tick)
        else { continue }
        let position = x(tick, width: width)
        let anchor: UnitPoint =
          position < 8 ? .leading : (position > width - 8 ? .trailing : .center)
        context.draw(
          Text("\(hour)").font(.system(size: 10)).foregroundStyle(Color(.tertiaryLabel)),
          at: CGPoint(x: position, y: 37), anchor: anchor)
      }
    }

    private func drawMark(_ mark: Mark, in context: inout GraphicsContext, width: CGFloat) {
      var layer = context
      if mark.faded { layer.opacity = 0.28 }
      let left = x(mark.start, width: width)
      switch mark.kind {
      case .event:
        let right = x(mark.end ?? mark.start, width: width)
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
#endif
