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

  extension View {
    /// Liquid Glass circle.
    package func glassCircle() -> some View {
      glassEffect(.regular.interactive(), in: Circle())
    }
  }

#endif
