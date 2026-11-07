#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem
  import UIKit

  /// A separate time handle keeps completion targets, menus and ordinary scrolling independent.
  struct TimelineTimeAdjustment: ViewModifier {
    let timing: TimelineDragTime
    let begin: () -> Bool
    let commit: (Date) -> Void
    let edit: () -> Void
    var previewChanged: (TimelineDragPreview?) -> Void = { _ in }
    var overlaps: (Date) -> Bool = { _ in false }
    @State private var target: Date?
    @State private var frozenTiming: TimelineDragTime?
    @State private var translation: CGSize = .zero
    @State private var edge = 0
    @State private var edgeMinutes = 0.0
    @State private var holding = false
    @State private var finger = CGPoint.zero
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        content.opacity(holding ? 0.25 : 1)
        TimelineTimeHandle(
          edit: edit,
          began: { location in
            let prepared = begin()
            timelineDragTrace("prepare: \(prepared)")
            guard prepared else { return }
            finger = location
            frozenTiming = timing
            edgeMinutes = 0
            translation = .zero
            target = timing.original
            holding = true
            emitPreview()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
          },
          changed: { delta, location in
            timelineDragTrace("changed holding: \(holding)")
            guard holding else { return }
            finger = location
            translation = delta
            let height =
              UIApplication.shared.connectedScenes
              .compactMap { $0 as? UIWindowScene }.first?.screen.bounds.height ?? 0
            edge = location.y < 170 ? -1 : (location.y > height - 170 ? 1 : 0)
            let session = frozenTiming ?? timing
            target = session.target(
              translation: Double(delta.height) + edgeMinutes * session.pointsPerMinute)
            emitPreview()
          },
          ended: { cancelled in
            timelineDragTrace(
              "ended cancelled: \(cancelled), holding: \(holding), target: \(target != nil)")
            let session = frozenTiming ?? timing
            if !cancelled, abs(translation.width) < 80, let target, target != session.original {
              commit(target)
            }
            previewChanged(nil)
            holding = false
            target = nil
            frozenTiming = nil
            edge = 0
            edgeMinutes = 0
          }
        )
        .frame(width: 44, height: 44)
        .modifier(AgendaLineSlot(width: 44))
      }
      .task(id: edge) {
        guard edge != 0 else { return }
        while !Task.isCancelled, holding, target != nil {
          do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
          guard holding, let session = frozenTiming else { return }
          edgeMinutes += Double(edge) * 5
          target = session.target(
            translation: Double(translation.height) + edgeMinutes * session.pointsPerMinute)
          emitPreview()
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active { cancelPreview() }
      }
      .onDisappear { cancelPreview() }

    }
    private func emitPreview() {
      guard holding, let target else { return }
      previewChanged(
        TimelineDragPreview(
          timing: frozenTiming ?? timing, target: target,
          finger: finger, cancelling: abs(translation.width) >= 80, overlaps: overlaps(target)))
    }

    private func cancelPreview() {
      timelineDragTrace("cancel preview holding: \(holding)")
      holding = false
      target = nil
      edge = 0
      previewChanged(nil)
    }

  }
#endif

#if os(iOS)
  /// UIKit's long-press recognizer tracks the same contact through movement and cancellation.
  /// A normal tap remains the existing exact-time editor; scrolling before the hold wins normally.
  private struct TimelineTimeHandle: UIViewRepresentable {
    let edit: () -> Void
    let began: (CGPoint) -> Void
    let changed: (CGSize, CGPoint) -> Void
    let ended: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
      let button = UIButton(type: .system)
      button.setImage(UIImage(systemName: "arrow.up.arrow.down"), for: .normal)
      button.setPreferredSymbolConfiguration(
        UIImage.SymbolConfiguration(pointSize: 12), forImageIn: .normal)
      button.tintColor = .secondaryLabel
      button.accessibilityLabel = "Change time"
      button.accessibilityHint = "Double tap to edit the exact time"
      button.addAction(
        UIAction { _ in
          timelineDragTrace("tap")
          context.coordinator.parent.edit()
        }, for: .touchUpInside)
      let hold = UILongPressGestureRecognizer(
        target: context.coordinator, action: #selector(Coordinator.handle(_:)))
      hold.delegate = context.coordinator
      hold.minimumPressDuration = 0.35
      hold.allowableMovement = 10
      button.addGestureRecognizer(hold)
      return button
    }
    func updateUIView(_ view: UIButton, context: Context) { context.coordinator.parent = self }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
      var parent: TimelineTimeHandle
      private var anchor = CGPoint.zero
      init(_ parent: TimelineTimeHandle) { self.parent = parent }
      // A held time handle owns the contact before a parent row menu or scroll recognizer.
      // Moving before the hold still fails this recognizer through allowableMovement.
      func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
      ) -> Bool {
        true
      }

      @objc func handle(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: nil)
        switch gesture.state {
        case .began:
          anchor = location
          parent.began(location)
        case .changed:
          parent.changed(
            CGSize(width: location.x - anchor.x, height: location.y - anchor.y), location)
        case .ended: parent.ended(false)
        case .cancelled, .failed: parent.ended(true)
        default: break
        }
      }
    }
  }
#endif

#if os(iOS)
  struct TimelineDragPreview {
    let timing: TimelineDragTime
    let target: Date
    let finger: CGPoint
    let cancelling: Bool
    let overlaps: Bool
  }

  /// Rendered above the List so its cells cannot clip the time preview or ruler.
  struct TimelineDragRuler: View {
    let preview: TimelineDragPreview
    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        Text(
          preview.timing.original.formatted(date: .abbreviated, time: .shortened)
            + " → " + preview.target.formatted(date: .abbreviated, time: .shortened)
        )
        .font(.caption.bold()).monospacedDigit()
        ForEach(-2...2, id: \.self) { step in
          let tick = preview.target.addingTimeInterval(Double(step) * 900)
          HStack {
            Text(
              tick >= preview.timing.earliest && tick <= preview.timing.latest
                ? tick.formatted(date: .omitted, time: .shortened) : "—")
            Rectangle().frame(height: 1)
          }.font(.caption2).frame(height: 30)
        }
        Text("This day only · 5-minute steps").font(.caption2)
        Text(preview.cancelling ? "Release to cancel" : "Slide sideways to cancel").font(.caption2)
        if preview.overlaps {
          Text("Overlaps another item").font(.caption.bold()).foregroundStyle(.orange)
        }
        Text(
          "Available: " + preview.timing.earliest.formatted(date: .omitted, time: .shortened)
            + "–" + preview.timing.latest.formatted(date: .omitted, time: .shortened)
        ).font(.caption2)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "From " + preview.timing.original.formatted(date: .abbreviated, time: .shortened)
          + " to " + preview.target.formatted(date: .abbreviated, time: .shortened)
          + (preview.overlaps ? ". Overlaps another item." : "")
      )
      .accessibilityIdentifier("timeline.time.preview")
    }
  }
#endif

#if os(iOS)
  private func timelineDragTrace(_ message: String) {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
        NSLog("TimelineDrag: %@", message)
      }
    #endif
  }
#endif
