#if os(iOS)
  import TodayCore
  import SwiftUI

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

  /// What a drag does to the drawer.
  package enum DrawerDragKind {
    /// The 24pt strip on the left edge. Wins over row swipe actions underneath.
    case edgeStrip
    /// A drag that starts within 44pt of the left edge anywhere on the page; other drags (scrolling, Calendar paging) are left alone.
    case edgeOnly
    /// A drag on the open sidebar that closes it.
    case close
  }

  package struct DrawerDrag: ViewModifier {
    package init(model: DrawerModel, width: CGFloat, kind: DrawerDragKind, enabled: Bool = true) {
      self.model = model
      self.width = width
      self.kind = kind
      self.enabled = enabled
    }
    package let model: DrawerModel
    package let width: CGFloat
    package let kind: DrawerDragKind
    package var enabled = true

    @GestureState private var active = false

    package func body(content: Content) -> some View {
      Group {
        switch kind {
        case .edgeStrip: content.highPriorityGesture(gesture)
        case .edgeOnly, .close: content.simultaneousGesture(gesture)
        }
      }
      // `onEnded` is skipped when the system cancels a drag. One turn after the gesture state resets,
      // a drag that is still claimed was cancelled, so settle it instead of leaving the drawer half open.
      .onChange(of: active) { _, isActive in
        guard !isActive else { return }
        Task { @MainActor in model.dragCancelled(width: width) }
      }
    }

    private var gesture: some Gesture {
      DragGesture(minimumDistance: 8, coordinateSpace: .global)
        .updating($active) { _, state, _ in state = true }
        .onChanged { v in
          guard accepts(v.startLocation) else { return }
          model.dragChanged(translation: v.translation)
        }
        .onEnded { v in
          guard accepts(v.startLocation) else { return }
          model.dragEnded(width: width, projected: v.predictedEndTranslation.width)
        }
    }

    private func accepts(_ start: CGPoint) -> Bool {
      switch kind {
      case .edgeStrip: enabled && !model.isOpen
      case .edgeOnly: enabled && !model.isOpen && start.x <= DrawerLayout.edgeSwipeWidth
      case .close: model.isOpen
      }
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
