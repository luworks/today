#if os(iOS)
  import SwiftUI
  import UIKit

  /// Apple's wheel `DatePicker`, hours and minutes: version A of the alarm wheel lab. The alarm editor itself uses
  /// the custom wheel (`TimeWheelPicker`, version C with five-minute minutes). The caller sets the calendar, locale
  /// and time zone in the environment.
  struct AlarmTimePicker: View {
    @Binding var time: Date

    var body: some View {
      DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
        .datePickerStyle(.wheel)
        .labelsHidden()
    }
  }

  /// Watches touches inside its own area without taking part (it never leaves `.possible`, so nothing it sits over
  /// changes). The lab uses it to time first touch, touches and lifts on the system picker, which reports none.
  struct TouchProbe: UIViewRepresentable {
    /// `true` on touch down, `false` on lift, with the touch time (`CACurrentMediaTime` clock).
    var onTouch: (Bool, Double) -> Void

    func makeUIView(context: Context) -> ProbeView {
      let view = ProbeView()
      view.onTouch = onTouch
      return view
    }

    func updateUIView(_ view: ProbeView, context: Context) { view.onTouch = onTouch }

    final class ProbeView: UIView {
      var onTouch: (Bool, Double) -> Void = { _, _ in }
      private let probe = ProbeRecognizer()

      override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        probe.cancelsTouchesInView = false
        probe.delaysTouchesBegan = false
        probe.delaysTouchesEnded = false
        probe.owner = self
      }

      required init?(coder: NSCoder) { fatalError() }

      override func didMoveToWindow() {
        super.didMoveToWindow()
        probe.view?.removeGestureRecognizer(probe)
        window?.addGestureRecognizer(probe)
      }

      fileprivate func contains(_ touch: UITouch) -> Bool {
        bounds.contains(touch.location(in: self))
      }
    }

    final class ProbeRecognizer: UIGestureRecognizer {
      weak var owner: ProbeView?
      private var inside: Set<ObjectIdentifier> = []

      override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let owner else { return }
        for touch in touches where owner.contains(touch) {
          inside.insert(ObjectIdentifier(touch))
          owner.onTouch(true, touch.timestamp)
        }
      }

      override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
      override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
      }

      override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
      override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
      }

      private func lift(_ touches: Set<UITouch>) {
        for touch in touches where inside.remove(ObjectIdentifier(touch)) != nil {
          owner?.onTouch(false, touch.timestamp)
        }
        // Never recognizes: once its fingers are up it fails, which only resets it.
        if inside.isEmpty { state = .failed }
      }

      override func reset() {
        super.reset()
        inside.removeAll()
      }
    }
  }
#endif
