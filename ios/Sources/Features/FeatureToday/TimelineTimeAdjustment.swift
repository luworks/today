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
    @GestureState private var holding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var adjustmentGesture: some Gesture {
      LongPressGesture(minimumDuration: 0.35)
        .sequenced(before: DragGesture())
        .onChanged { value in
          if case .second(true, let drag) = value {
            if target == nil {
              frozenTiming = timing
              begin()
              UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            translation = drag?.translation ?? .zero
            target = (frozenTiming ?? timing).target(translation: Double(translation.height))
          }
        }
        .updating($holding) { value, state, _ in
          if case .second = value { state = true }
        }
        .onEnded { value in
          if case .second(true, let drag) = value, let drag {
            let session = frozenTiming ?? timing
            let date = session.target(translation: Double(drag.translation.height))
            if abs(drag.translation.width) < 80, date != session.original { commit(date) }
          }
          target = nil
          frozenTiming = nil
        }
    }

    func body(content: Content) -> some View {
      HStack(spacing: 0) {
        content
        Image(systemName: "arrow.up.arrow.down")
          .font(.caption).foregroundStyle(.secondary)
          .frame(width: 44, height: 44).contentShape(Rectangle())
          .onTapGesture(perform: edit)
          .highPriorityGesture(adjustmentGesture)
          .accessibilityLabel("Change time")
          .accessibilityHint("Double tap to edit the exact time")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction(perform: edit)
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
                Text(
                  target.addingTimeInterval(Double(step) * 900)
                    .formatted(date: .omitted, time: .shortened))
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
      .onChange(of: holding) { _, active in if !active { target = nil } }
    }
  }
#endif
