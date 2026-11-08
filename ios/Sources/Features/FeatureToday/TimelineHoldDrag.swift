#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem
  import UIKit
  import UIKit.UIGestureRecognizerSubclass

  /// One contact, three outcomes. Moving before the hold fails, so scrolling and swipes win. A held row
  /// lifts; moving then begins the drag, and staying still fails so the system row menu takes the contact.
  /// Everything inside the List waits for this recognizer, which is what keeps the menu from opening early.
  @MainActor
  final class TimelineHoldDragRecognizer: UIGestureRecognizer {
    private static let liftDelay: TimeInterval = 0.35
    /// How long a lifted row waits for movement; the menu opens when this ends. Has to cover the
    /// time to feel the lift and start moving.
    private static let menuDelay: TimeInterval = 0.3
    private static let preLiftTolerance: CGFloat = 10
    private static let dragThreshold: CGFloat = 6

    var canLift: (CGPoint) -> Bool = { _ in false }
    var lifted: (CGPoint) -> Void = { _ in }
    var unlifted: () -> Void = {}
    private(set) var point = CGPoint.zero

    private var start = CGPoint.zero
    private var liftPoint: CGPoint?
    private var touch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      guard touch == nil, let first = touches.first, touches.count == 1 else {
        if state == .possible {
          fail()
        } else {
          touches.forEach { ignore($0, for: event) }
        }
        return
      }
      touch = first
      start = first.location(in: nil)
      point = start
      // A row that cannot move is left to the List from the first moment.
      guard canLift(start) else {
        fail()
        return
      }
      perform(#selector(lift), with: nil, afterDelay: Self.liftDelay, inModes: [.common])
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
      guard let touch, touches.contains(touch) else { return }
      point = touch.location(in: nil)
      switch state {
      case .possible:
        if let liftPoint {
          if distance(point, liftPoint) >= Self.dragThreshold {
            cancelTimers()
            state = .began
          }
        } else if distance(point, start) > Self.preLiftTolerance {
          fail()
        }
      case .began, .changed: state = .changed
      default: break
      }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
      guard let touch, touches.contains(touch) else { return }
      if state == .possible { fail() } else { state = .ended }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
      guard let touch, touches.contains(touch) else { return }
      if state == .possible { fail() } else { state = .cancelled }
    }

    override func reset() {
      cancelTimers()
      touch = nil
      liftPoint = nil
      super.reset()
    }

    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
      guard let view, let otherView = other.view else { return false }
      return otherView.isDescendant(of: view)
    }

    @objc private func lift() {
      guard state == .possible, touch != nil else { return }
      guard canLift(point) else {
        fail()
        return
      }
      liftPoint = point
      lifted(point)
      perform(#selector(giveToMenu), with: nil, afterDelay: Self.menuDelay, inModes: [.common])
    }

    @objc private func giveToMenu() {
      if state == .possible { fail() }
    }

    private func fail() {
      cancelTimers()
      // Before the state changes: the system menu snapshots the row, which must be back at rest.
      if liftPoint != nil { unlifted() }
      liftPoint = nil
      state = .failed
    }

    private func cancelTimers() { NSObject.cancelPreviousPerformRequests(withTarget: self) }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
  }

  /// Puts the recognizer on the List's own collection view, which outlives every cell, so the
  /// contact survives the dragged row's cell being moved or reused during auto-scroll.
  struct TimelineHoldDragInstaller: UIViewRepresentable {
    let model: TimelineDragModel
    let canLift: (CGPoint) -> Bool
    let began: (CGPoint) -> Bool
    let ended: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Anchor {
      let anchor = Anchor()
      anchor.isUserInteractionEnabled = false
      anchor.coordinator = context.coordinator
      return anchor
    }
    func updateUIView(_ view: Anchor, context: Context) {
      context.coordinator.parent = self
      view.installSoon()
    }

    final class Anchor: UIView {
      weak var coordinator: Coordinator?
      override func didMoveToWindow() {
        super.didMoveToWindow()
        installSoon()
      }
      func installSoon() {
        DispatchQueue.main.async { [weak self] in
          guard let self, self.window != nil else { return }
          self.coordinator?.install(near: self)
        }
      }
    }

    @MainActor final class Coordinator: NSObject {
      private static let edgeZone: CGFloat = 72
      private static let edgeSpeed: CGFloat = 520

      var parent: TimelineHoldDragInstaller
      private weak var list: UICollectionView?
      private weak var recognizer: TimelineHoldDragRecognizer?
      private var link: CADisplayLink?

      init(_ parent: TimelineHoldDragInstaller) { self.parent = parent }

      func install(near view: UIView) {
        guard recognizer?.view == nil || list?.window == nil else { return }
        var ancestor = view.superview
        while let current = ancestor {
          if let found = Self.collectionView(in: current) {
            attach(to: found)
            return
          }
          ancestor = current.superview
        }
      }

      private static func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for child in view.subviews {
          if let list = collectionView(in: child) { return list }
        }
        return nil
      }

      private func attach(to found: UICollectionView) {
        let hold = TimelineHoldDragRecognizer(target: self, action: #selector(handle(_:)))
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
        hold.canLift = { [weak self] in self?.parent.canLift($0) ?? false }
        hold.lifted = { [weak self] in self?.parent.model.lift(at: $0) }
        hold.unlifted = { [weak self] in self?.parent.model.unlift() }
        found.addGestureRecognizer(hold)
        recognizer?.view?.removeGestureRecognizer(recognizer!)
        recognizer = hold
        list = found
      }

      @objc private func handle(_ gesture: TimelineHoldDragRecognizer) {
        switch gesture.state {
        case .began:
          guard parent.began(gesture.point) else {
            parent.model.unlift()
            gesture.isEnabled = false
            gesture.isEnabled = true
            return
          }
          if let band = visibleBand() { parent.model.band = band.top...band.bottom }
          let display = CADisplayLink(target: self, selector: #selector(tick(_:)))
          display.add(to: .main, forMode: .common)
          link = display
        case .changed: parent.model.move(to: gesture.point)
        case .ended, .cancelled, .failed:
          link?.invalidate()
          link = nil
          parent.ended(gesture.state != .ended)
        default: break
        }
      }

      private func visibleBand() -> (top: CGFloat, bottom: CGFloat)? {
        guard let list, let window = list.window else { return nil }
        let frame = list.convert(list.bounds, to: window)
        let insets = list.adjustedContentInset
        guard frame.height > insets.top + insets.bottom else { return nil }
        return (frame.minY + insets.top, frame.maxY - insets.bottom)
      }

      /// Scrolls while the finger rests near an edge of the visible List.
      @objc private func tick(_ display: CADisplayLink) {
        guard let list, let point = recognizer?.point, let (top, bottom) = visibleBand() else {
          return
        }
        let insets = list.adjustedContentInset
        let depth: CGFloat
        if point.y < top + Self.edgeZone {
          depth = -min(1, (top + Self.edgeZone - point.y) / Self.edgeZone)
        } else if point.y > bottom - Self.edgeZone {
          depth = min(1, (point.y - bottom + Self.edgeZone) / Self.edgeZone)
        } else {
          return
        }
        let lowest = -insets.top
        let highest = max(lowest, list.contentSize.height - list.bounds.height + insets.bottom)
        let next = min(
          highest,
          max(lowest, list.contentOffset.y + depth * Self.edgeSpeed * CGFloat(display.duration)))
        guard next != list.contentOffset.y else { return }
        list.contentOffset.y = next
        parent.model.move(to: point)
      }
    }
  }

  /// A drag in progress. Only the slot is watched by the List; the finger is watched only by the floating row.
  @MainActor @Observable final class TimelineDragModel {
    struct Session {
      let item: TimelineItem
      let timing: TimelineDragTime
      let anchors: [TimelineItem]
      let stops: [TimelineDropStop]
      let originalStop: Int
      let row: AnyView
      let overlaps: (Date) -> Bool
      var id: AnyHashable { item.id }
    }

    private static let cancelDistance: CGFloat = 80
    private static let stepMargin: CGFloat = 4

    private(set) var liftedID: AnyHashable?
    private(set) var session: Session?
    private(set) var stopIndex = 0
    private(set) var top: CGFloat = 0
    private(set) var isCancelling = false
    private(set) var frame = CGRect.zero
    @ObservationIgnored private var frames: [AnyHashable: CGRect] = [:]
    @ObservationIgnored private var grab: CGFloat = 0
    @ObservationIgnored private var startX: CGFloat = 0
    @ObservationIgnored private var released = false
    /// The List's visible band: the row stays in it even with the finger over the bottom bar.
    @ObservationIgnored var band: ClosedRange<CGFloat> = 0...CGFloat.greatestFiniteMagnitude
    @ObservationIgnored private let haptic = UISelectionFeedbackGenerator()
    @ObservationIgnored private var animated: Animation? = .spring(duration: 0.3, bounce: 0.2)

    var target: Date? { session.map { $0.stops[stopIndex].target } }

    func frameReader(_ id: AnyHashable) -> TimelineDragFrameReader {
      TimelineDragFrameReader(id: id, model: self)
    }

    func setFrame(_ frame: CGRect?, for id: AnyHashable) { frames[id] = frame }

    /// Timeline rows only: the labels share the dictionary but are never held.
    func rowID(at point: CGPoint) -> AnyHashable? {
      frames.first { !isLabel($0.key) && $0.value.contains(point) }?.key
    }

    func lift(at point: CGPoint) {
      guard let id = rowID(at: point) else { return }
      liftedID = id
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func unlift() { liftedID = nil }

    func begin(_ new: Session, at point: CGPoint, reduceMotion: Bool) -> Bool {
      guard let rowFrame = frames[new.id] else { return false }
      animated = reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2)
      grab = point.y - rowFrame.minY
      startX = point.x
      frame = rowFrame
      top = rowFrame.minY
      released = false
      isCancelling = false
      stopIndex = new.originalStop
      haptic.prepare()
      withAnimation(animated) { session = new }
      return true
    }

    func move(to point: CGPoint) {
      guard let session, !released else { return }
      top = min(
        max(point.y - grab, band.lowerBound), max(band.lowerBound, band.upperBound - frame.height))
      let cancelling = abs(point.x - startX) >= Self.cancelDistance
      if cancelling != isCancelling { isCancelling = cancelling }
      step(session)
    }

    /// One slot per update; the neighbours' next positions are not known until the List lays out.
    private func step(_ session: Session) {
      let bottom = top + frame.height
      if stopIndex + 1 < session.stops.count,
        let line = boundary(session, above: stopIndex + 1), bottom > line + Self.stepMargin
      {
        go(to: stopIndex + 1)
      } else if stopIndex > 0, let line = boundary(session, above: stopIndex),
        top < line - Self.stepMargin
      {
        go(to: stopIndex - 1)
      }
    }

    /// What separates a place from the one before it: the next card's label, or the anchor between them.
    private func boundary(_ session: Session, above index: Int) -> CGFloat? {
      let lower = session.stops[index]
      let id =
        lower.part != session.stops[index - 1].part
        ? DayPartRow<TimelineItem>.label(lower.part).id
        : session.anchors[lower.index - 1].id
      return frames[id]?.midY
    }

    private func go(to index: Int) {
      haptic.selectionChanged()
      haptic.prepare()
      withAnimation(animated) { stopIndex = index }
    }

    /// Settles the row, then reports the time to commit, or nil when nothing should change.
    func release(cancelled: Bool, reduceMotion: Bool, finish: @escaping (Date?) -> Void) {
      guard let session, !released else {
        liftedID = nil
        return
      }
      released = true
      let keep = cancelled || isCancelling
      if keep, stopIndex != session.originalStop {
        withAnimation(animated) { stopIndex = session.originalStop }
      }
      let chosen = session.stops[stopIndex].target
      Task { @MainActor in
        // The List has to lay out the final place before there is a frame to settle into.
        try? await Task.sleep(for: .milliseconds(16))
        if let rest = frames[session.id] {
          withAnimation(animated) { top = rest.minY }
        }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 240))
        guard self.session?.id == session.id, released else { return }
        finish(keep || chosen == session.timing.original ? nil : chosen)
      }
    }

    func end() {
      session = nil
      liftedID = nil
      released = false
      isCancelling = false
      stopIndex = 0
    }

    private func isLabel(_ id: AnyHashable) -> Bool {
      DayPart.allCases.contains { DayPartRow<TimelineItem>.label($0).id == id }
    }
  }

  struct TimelineDragFrameReader: ViewModifier {
    let id: AnyHashable
    let model: TimelineDragModel

    /// In a background: on the row itself this loses the row's List insets and separator setting.
    func body(content: Content) -> some View {
      content.background {
        Color.clear
          .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
          } action: {
            model.setFrame($0, for: id)
          }
          .onDisappear { model.setFrame(nil, for: id) }
      }
    }
  }

  /// The row in the List: raised while held, then an empty place while its floating copy follows the finger.
  struct TimelineDragRowChrome: ViewModifier {
    let model: TimelineDragModel
    let id: AnyHashable
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
      let lifted = model.liftedID == id && model.session == nil
      content
        .scaleEffect(lifted && !reduceMotion ? 1.02 : 1)
        .shadow(color: .black.opacity(lifted ? 0.18 : 0), radius: 8, y: 3)
        .opacity(model.session?.id == id ? 0 : 1)
        // The floating copy takes over in one frame; a fade would show both.
        .animation(nil, value: model.session?.id)
    }
  }

  /// Drawn above the List so its cells cannot clip the row, and so the row can leave its card.
  struct TimelineDragOverlay: View {
    let model: TimelineDragModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PlannerPresentation.self) private var presentation

    var body: some View {
      GeometryReader { geometry in
        if let session = model.session, let target = model.target {
          let origin = geometry.frame(in: .global).origin
          session.row
            .environment(\.agendaDragTime, target)
            .frame(width: model.frame.width, height: model.frame.height)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
            )
            .overlay(alignment: .bottomTrailing) { note(session, target) }
            .scaleEffect(reduceMotion ? 1 : 1.02)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .opacity(model.isCancelling ? 0.55 : 1)
            .position(
              x: model.frame.midX - origin.x,
              y: model.top - origin.y + model.frame.height / 2
            )
            .transition(.identity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
              "Moving to "
                + target.plannerFormatted(
                  date: .omitted, time: .shortened, runtime: presentation.runtime)
            )
        }
      }
    }

    /// The one thing the time pill cannot say.
    @ViewBuilder
    private func note(_ session: TimelineDragModel.Session, _ target: Date) -> some View {
      let overlaps = target != session.timing.original && session.overlaps(target)
      if model.isCancelling || overlaps {
        Text(model.isCancelling ? "Release to cancel" : "Overlaps another item")
          .font(.caption2.bold())
          .foregroundStyle(model.isCancelling ? Color.primary : Color.orange)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(.regularMaterial, in: Capsule())
          .offset(x: -8, y: 12)
      }
    }
  }
#endif
