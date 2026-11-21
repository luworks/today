#if os(iOS)
  import TodayCore
  import SwiftUI
  import UIKit

  /// State of the left drawer. Kept out of `HomeView`'s body on purpose: only the small modifiers below read
  /// `isOpen` and `drag`, so a drag frame re-runs those modifiers and nothing else. The page and the sidebar
  /// content are not rebuilt while the finger moves.
  @MainActor
  @Observable
  package final class DrawerModel {
    package init() {}
    package private(set) var isOpen = false
    /// Horizontal finger translation while dragging, 0 otherwise.
    package private(set) var drag: CGFloat = 0
    /// The sidebar view is created on first need (a short while after launch, or when the first drag starts)
    /// and then kept alive, so opening it never pays for building it.
    package var isBuilt = false

    private enum Claim { case undecided, claimed, rejected }
    @ObservationIgnored private var claim = Claim.undecided

    package static let spring = Animation.spring(response: 0.36, dampingFraction: 0.88)

    /// 0 = closed, 1 = fully open.
    package func progress(width: CGFloat) -> CGFloat {
      guard width > 0 else { return 0 }
      return min(max((isOpen ? width : 0) + drag, 0), width) / width
    }

    package func set(open: Bool, animated: Bool = true) {
      if open { isBuilt = true }
      claim = .undecided
      if animated {
        withAnimation(Self.spring) {
          isOpen = open
          drag = 0
        }
      } else {
        isOpen = open
        drag = 0
      }
    }

    // MARK: Gesture handling

    /// Feeds one drag event. The first event decides once whether this drag belongs to the drawer
    /// (mostly horizontal, in the direction that opens or closes it); later events follow that decision.
    package func dragChanged(translation: CGSize) {
      if claim == .undecided {
        let horizontal = abs(translation.width) > abs(translation.height)
        let rightWay = isOpen ? translation.width < 0 : translation.width > 0
        claim = horizontal && rightWay ? .claimed : .rejected
        if claim == .claimed { isBuilt = true }
      }
      guard claim == .claimed else { return }
      drag = translation.width
    }

    /// Releases the drag and settles open or closed from where the finger was heading (`projected` includes momentum).
    package func dragEnded(width: CGFloat, projected: CGFloat?) {
      guard claim == .claimed else {
        claim = .undecided
        return
      }
      let base = isOpen ? width : 0
      let end = base + (projected ?? drag)
      set(open: end > width / 2)
    }

    /// For a drag the system cancelled: settle by position so the drawer is never left half open.
    package func dragCancelled(width: CGFloat) {
      switch claim {
      case .claimed: dragEnded(width: width, projected: nil)
      // a cancelled vertical drag must not swallow the next edge swipe
      case .rejected: claim = .undecided
      case .undecided: break
      }
    }
  }

  /// A drag on the open sidebar that closes it.
  package struct DrawerDrag: ViewModifier {
    package init(model: DrawerModel, width: CGFloat) {
      self.model = model
      self.width = width
    }
    package let model: DrawerModel
    package let width: CGFloat

    @GestureState private var active = false

    package func body(content: Content) -> some View {
      content.simultaneousGesture(gesture)
        .onChange(of: active) { _, isActive in
          guard !isActive else { return }
          Task { @MainActor in model.dragCancelled(width: width) }
        }
    }

    private var gesture: some Gesture {
      DragGesture(minimumDistance: 8, coordinateSpace: .global)
        .updating($active) { _, state, _ in state = true }
        .onChanged { v in
          guard model.isOpen else { return }
          model.dragChanged(translation: v.translation)
        }
        .onEnded { v in
          guard model.isOpen else { return }
          model.dragEnded(width: width, projected: v.predictedEndTranslation.width)
        }
    }
  }

  /// A rightward swipe anywhere in the window opens the sidebar, like ChatGPT. Inside the left edge strip it always
  /// wins; elsewhere content that can still move right keeps the swipe: a horizontal scroll view that is not at its
  /// leading edge, and areas marked `drawerSwipeExcluded`. It never starts over a presented sheet.
  package struct DrawerPan: UIViewRepresentable {
    package init(
      isEnabled: Bool, changed: @escaping (CGSize) -> Void,
      ended: @escaping (CGSize, CGFloat) -> Void, cancelled: @escaping () -> Void
    ) {
      self.isEnabled = isEnabled
      self.changed = changed
      self.ended = ended
      self.cancelled = cancelled
    }
    let isEnabled: Bool
    let changed: (CGSize) -> Void
    let ended: (CGSize, CGFloat) -> Void
    let cancelled: () -> Void

    package func makeCoordinator() -> Coordinator { Coordinator() }

    package func makeUIView(context: Context) -> Anchor {
      let view = Anchor()
      view.coordinator = context.coordinator
      view.isUserInteractionEnabled = false
      return view
    }

    package func updateUIView(_ view: Anchor, context: Context) {
      context.coordinator.pan = self
    }

    package static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) {
      coordinator.attach(to: nil)
    }

    package final class Anchor: UIView {
      weak var coordinator: Coordinator?
      override package func didMoveToWindow() {
        super.didMoveToWindow()
        coordinator?.attach(to: window)
      }
    }

    @MainActor
    package final class Coordinator: NSObject, UIGestureRecognizerDelegate {
      var pan: DrawerPan?
      private let recognizer = UIPanGestureRecognizer()
      private var paused: [UIScrollView] = []

      override init() {
        super.init()
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(handle(_:)))
      }

      func attach(to window: UIWindow?) {
        recognizer.view?.removeGestureRecognizer(recognizer)
        window?.addGestureRecognizer(recognizer)
      }

      @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
        let t = recognizer.translation(in: recognizer.view)
        let translation = CGSize(width: t.x, height: t.y)
        switch recognizer.state {
        case .began:
          pauseScrolling(at: start(of: recognizer))
          pan?.changed(translation)
        case .changed:
          pan?.changed(translation)
        case .ended:
          resumeScrolling()
          let v = recognizer.velocity(in: recognizer.view).x
          pan?.ended(translation, t.x + v * 0.2)
        case .cancelled, .failed:
          resumeScrolling()
          pan?.cancelled()
        default:
          break
        }
      }

      private func start(of recognizer: UIPanGestureRecognizer) -> CGPoint {
        let location = recognizer.location(in: recognizer.view)
        let t = recognizer.translation(in: recognizer.view)
        return CGPoint(x: location.x - t.x, y: location.y - t.y)
      }

      package func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan, pan.isEnabled, let panRecognizer = recognizer as? UIPanGestureRecognizer,
          let window = recognizer.view as? UIWindow,
          window.rootViewController?.presentedViewController == nil
        else { return false }
        let v = panRecognizer.velocity(in: window)
        guard v.x > 0, v.x > 1.5 * abs(v.y) else { return false }
        let point = start(of: panRecognizer)
        if point.x <= DrawerLayout.edgeSwipeWidth { return true }
        if DrawerSwipeExclusions.contains(point) { return false }
        var view = window.hitTest(point, with: nil)
        while let current = view {
          if let scroll = current as? UIScrollView, Self.canMoveRight(scroll) { return false }
          view = current.superview
        }
        return true
      }

      package func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
      ) -> Bool { true }

      private static func canMoveRight(_ scroll: UIScrollView) -> Bool {
        guard scroll.isScrollEnabled else { return false }
        let scrollsSideways = scroll.contentSize.width > scroll.bounds.width + 1
        return scrollsSideways && scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1
      }

      private func pauseScrolling(at point: CGPoint) {
        var view = recognizer.view?.hitTest(point, with: nil)
        while let current = view {
          if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
            scroll.isScrollEnabled = false
            paused.append(scroll)
          }
          view = current.superview
        }
      }

      private func resumeScrolling() {
        paused.forEach { $0.isScrollEnabled = true }
        paused = []
      }
    }
  }

  @MainActor
  package enum DrawerSwipeExclusions {
    static var frames: [UUID: CGRect] = [:]
    static func contains(_ point: CGPoint) -> Bool { frames.values.contains { $0.contains(point) } }
  }

  private struct DrawerSwipeExcluded: ViewModifier {
    let isOn: Bool
    @State private var id = UUID()
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
      content
        .onGeometryChange(for: CGRect.self) {
          $0.frame(in: .global)
        } action: {
          frame = $0
          update()
        }
        .onChange(of: isOn) { update() }
        .onDisappear { DrawerSwipeExclusions.frames[id] = nil }
    }

    private func update() { DrawerSwipeExclusions.frames[id] = isOn ? frame : nil }
  }

  extension View {
    /// Keeps a rightward swipe that starts here for this view's own horizontal drag instead of opening the sidebar.
    package func drawerSwipeExcluded(_ isOn: Bool = true) -> some View {
      modifier(DrawerSwipeExcluded(isOn: isOn))
    }
  }

  /// How much of the screen the sidebar takes. The page slides this far to the right and stays visible beside it (as in ChatGPT
  /// and Claude), rounded and dimmed; tapping it closes the sidebar.
  package enum DrawerLayout {
    package static let widthFraction: CGFloat = 0.78
    package static let edgeSwipeWidth: CGFloat = 44
  }

  /// The page: slides right by the sidebar's width, with rounded corners and a dim layer that fade in as it moves.
  package struct DrawerMainSlide: ViewModifier {
    package init(
      model: DrawerModel, width: CGFloat, size: CGSize = .zero, insets: EdgeInsets = EdgeInsets()
    ) {
      self.model = model
      self.width = width
      self.size = size
      self.insets = insets
    }
    package let model: DrawerModel
    package let width: CGFloat
    /// The screen's size and safe-area insets, so the rounded corners are the screen's own, not the safe area's.
    package var size: CGSize = .zero
    package var insets = EdgeInsets()

    package func body(content: Content) -> some View {
      let p = model.progress(width: width)
      content
        .overlay {
          Color.black.opacity(0.22 * p)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        // The mask covers the whole screen (also under the safe areas), so the corners are the screen's own.
        .mask {
          RoundedRectangle(cornerRadius: 44 * min(1, p * 5), style: .continuous)
            .frame(width: size.width, height: size.height + insets.top + insets.bottom)
            .offset(y: (insets.bottom - insets.top) / 2)
        }
        .offset(x: p * width)
        .accessibilityHidden(model.isOpen)
        .allowsHitTesting(!model.isOpen)
        .sensoryFeedback(.impact(weight: .light), trigger: model.isOpen)
    }
  }

  /// The sidebar: follows the page with a small parallax, so it settles at 0 when fully open.
  package struct DrawerSidebarSlide: ViewModifier {
    package init(model: DrawerModel, width: CGFloat) {
      self.model = model
      self.width = width
    }
    package let model: DrawerModel
    package let width: CGFloat

    package func body(content: Content) -> some View {
      let p = model.progress(width: width)
      content
        .offset(x: (p - 1) * width * 0.25)
        .accessibilityHidden(!model.isOpen)
        .allowsHitTesting(model.isOpen)
    }
  }

#endif
