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
    @GestureState private var holding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var adjustmentGesture: some Gesture {
      LongPressGesture(minimumDuration: 0.35)
        .sequenced(before: DragGesture(coordinateSpace: .global))
        .onChanged { value in
          if case .second(true, let drag) = value {
            if target == nil {
              edgeMinutes = 0
              frozenTiming = timing
              begin()
              UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            translation = drag?.translation ?? .zero
            let screenHeight =
              UIApplication.shared.connectedScenes
              .compactMap { $0 as? UIWindowScene }.first?.screen.bounds.height ?? 0
            let y = drag?.location.y ?? screenHeight / 2
            edge = y < 170 ? -1 : (y > screenHeight - 170 ? 1 : 0)
            let session = frozenTiming ?? timing
            target = session.target(
              translation: Double(translation.height) + edgeMinutes * session.pointsPerMinute)
          }
        }
        .updating($holding) { value, state, _ in
          if case .second = value { state = true }
        }
        .onEnded { value in
          if case .second(true, let drag) = value, let drag {
            let session = frozenTiming ?? timing
            let date = target ?? session.target(translation: Double(drag.translation.height))
            if abs(drag.translation.width) < 80, date != session.original { commit(date) }
          }
          target = nil
          frozenTiming = nil
          edge = 0
          edgeMinutes = 0
        }
    }

    func body(content: Content) -> some View {
      HStack(spacing: 0) {
        content.opacity(holding ? 0.25 : 1)
        Image(systemName: "arrow.up.arrow.down")
          .font(.caption).foregroundStyle(.secondary)
          .frame(width: 44, height: 44).contentShape(Rectangle())
          .onTapGesture(perform: edit)
          .highPriorityGesture(adjustmentGesture)
          .accessibilityLabel("Change time")
          .accessibilityHint("Double tap to edit the exact time")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction(.default) { edit() }
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
