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
    @State private var target: Date?
    @GestureState private var holding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
      HStack(spacing: 0) {
        content
        Image(systemName: "arrow.up.arrow.down")
          .font(.caption).foregroundStyle(.secondary)
          .frame(width: 44, height: 44).contentShape(Rectangle())
          .onTapGesture(perform: edit)
          .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.35).sequenced(before: DragGesture())
              .onChanged { value in
                if case .second(true, let drag) = value {
                  if target == nil {
                    begin()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                  }
                  target = timing.target(translation: drag?.translation.height ?? 0)
                }
              }
              .updating($holding) { value, state, _ in
                if case .second = value { state = true }
              }
              .onEnded { value in
                if case .second(true, let drag) = value, let drag {
                  let date = timing.target(translation: drag.translation.height)
                  if date != timing.original { commit(date) }
                }
                target = nil
              }
          )
          .accessibilityLabel("Change time")
          .accessibilityHint("Double tap to edit the exact time")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction(perform: edit)
      }
      .overlay(alignment: .trailing) {
        if holding, let target {
          VStack(alignment: .leading, spacing: 8) {
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
              }.font(.caption2).frame(height: 22)
            }
            Text("This day only · 5-minute steps").font(.caption2)
          }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
        }
      }
      .scaleEffect(holding && !reduceMotion ? 1.015 : 1)
      .onChange(of: holding) { _, active in if !active { target = nil } }
    }
  }
#endif
