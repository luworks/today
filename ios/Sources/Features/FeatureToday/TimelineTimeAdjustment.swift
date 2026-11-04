#if os(iOS)
  import SwiftUI
  import TodayCore
  import UIKit

  /// A separate time handle keeps completion targets, menus and ordinary scrolling independent.
  struct TimelineTimeAdjustment: ViewModifier {
    let timing: TimelineDragTime
    let begin: () -> Void
    let commit: (Date) -> Void
    let edit: () -> Void
    var overlaps: (Date) -> Bool = { _ in false }
    @State private var target: Date?
    @State private var frozenTiming: TimelineDragTime?
    @State private var translation: CGSize = .zero
    @State private var edge = 0
    @State private var edgeMinutes = 0.0
    @State private var holding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
      HStack(spacing: 0) {
        content.opacity(holding ? 0.25 : 1)
        TimelineTimeHandle(
          edit: edit,
          began: {
            frozenTiming = timing
            edgeMinutes = 0
            translation = .zero
            begin()
            target = timing.original
            holding = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
          },
          changed: { delta, location in
            translation = delta
            let height =
              UIApplication.shared.connectedScenes
              .compactMap { $0 as? UIWindowScene }.first?.screen.bounds.height ?? 0
            edge = location.y < 170 ? -1 : (location.y > height - 170 ? 1 : 0)
            let session = frozenTiming ?? timing
            target = session.target(
              translation: Double(delta.height) + edgeMinutes * session.pointsPerMinute)
          },
          ended: { cancelled in
            let session = frozenTiming ?? timing
            if !cancelled, abs(translation.width) < 80, let target, target != session.original {
              commit(target)
            }
            holding = false
            target = nil
            frozenTiming = nil
            edge = 0
            edgeMinutes = 0
          }
        ).frame(width: 44, height: 44)

      }
      .overlay(alignment: .leading) {
        if holding {
          content.padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: reduceMotion ? 0 : 4, y: 2)
            .offset(y: max(-120, min(120, translation.height)))
            .allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      .overlay(alignment: .trailing) {
        if holding, let target {
          VStack(alignment: .leading, spacing: 0) {
            Text(
              timing.original.formatted(date: .abbreviated, time: .shortened)
                + " → " + target.formatted(date: .abbreviated, time: .shortened)
            )
            .font(.caption.bold()).monospacedDigit()
            ForEach(-2...2, id: \.self) { step in
              HStack {
                let tick = target.addingTimeInterval(Double(step) * 900)
                Text(
                  tick >= timing.earliest && tick <= timing.latest
                    ? tick.formatted(date: .omitted, time: .shortened) : "—")
                Rectangle().frame(width: 60, height: 1)
              }.font(.caption2).frame(height: 30)
            }
            Text("This day only · 5-minute steps").font(.caption2)
            Text(abs(translation.width) >= 80 ? "Release to cancel" : "Slide sideways to cancel")
              .font(.caption2)
            if overlaps(target) {
              Text("Overlaps another item").font(.caption.bold()).foregroundStyle(.orange)
            }
            Text(
              "Available: " + timing.earliest.formatted(date: .omitted, time: .shortened)
                + "–" + timing.latest.formatted(date: .omitted, time: .shortened)
            ).font(.caption2)
          }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .offset(y: max(-120, min(120, translation.height)))
            .allowsHitTesting(false)
        }
      }
      .scaleEffect(holding && !reduceMotion ? 1.015 : 1)
      .task(id: edge) {
        guard edge != 0 else { return }
        while !Task.isCancelled, holding, target != nil {
          do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
          guard holding, let session = frozenTiming else { return }
          edgeMinutes += Double(edge) * 5
          target = session.target(
            translation: Double(translation.height) + edgeMinutes * session.pointsPerMinute)
        }
      }
      .onChange(of: holding) { _, active in
        if !active {
          target = nil
          edge = 0
        }
      }
    }
  }
#endif

#if os(iOS)
  /// UIKit's long-press recognizer tracks the same contact through movement and cancellation.
  /// A normal tap remains the existing exact-time editor; scrolling before the hold wins normally.
  private struct TimelineTimeHandle: UIViewRepresentable {
    let edit: () -> Void
    let began: () -> Void
    let changed: (CGSize, CGPoint) -> Void
    let ended: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
      let button = UIButton(type: .system)
      button.setImage(UIImage(systemName: "arrow.up.arrow.down"), for: .normal)
      button.tintColor = .secondaryLabel
      button.accessibilityLabel = "Change time"
      button.accessibilityHint = "Double tap to edit the exact time"
      button.addAction(UIAction { _ in context.coordinator.parent.edit() }, for: .touchUpInside)
      let hold = UILongPressGestureRecognizer(
        target: context.coordinator, action: #selector(Coordinator.handle(_:)))
      hold.minimumPressDuration = 0.35
      hold.allowableMovement = 10
      button.addGestureRecognizer(hold)
      return button
    }
    func updateUIView(_ view: UIButton, context: Context) { context.coordinator.parent = self }

    @MainActor final class Coordinator: NSObject {
      var parent: TimelineTimeHandle
      private var anchor = CGPoint.zero
      init(_ parent: TimelineTimeHandle) { self.parent = parent }
      @objc func handle(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: nil)
        switch gesture.state {
        case .began:
          anchor = location
          parent.began()
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
