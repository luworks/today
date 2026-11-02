#if os(iOS)
  import SwiftUI
  import TodayCore

  package struct CircleButton: View {
    package init(
      systemImage: String, label: String, size: CGFloat = ButtonConfiguration.Icon.size,
      action: @escaping () -> Void
    ) {
      self.systemImage = systemImage
      self.label = label
      self.size = size
      self.action = action
    }
    package let systemImage: String
    package let label: String
    package var size: CGFloat = ButtonConfiguration.Icon.size
    package var action: () -> Void

    package var body: some View {
      Button(action: action) {
        Image(systemName: systemImage)
          .font(ButtonConfiguration.Icon.actionFont)
          .foregroundStyle(.primary)
          .frame(
            width: max(ButtonConfiguration.minimumHitSize, size),
            height: max(ButtonConfiguration.minimumHitSize, size)
          )
          .glassCircle()
      }
      .buttonStyle(PressScale())
      .accessibilityLabel(label)
    }
  }

  /// 0.97 press scale with a light haptic.

  extension View {
    @ViewBuilder
    package func glassCircle() -> some View {
      if #available(iOS 26, *) {
        glassEffect(.regular.interactive(), in: Circle())
      } else {
        background(.regularMaterial, in: Circle())
      }
    }
  }

#endif
