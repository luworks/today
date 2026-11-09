#if os(iOS)
  import SwiftUI
  import TodayCore

  /// "Open Health": one tap into Apple's Health app, shared by every place Today shows Health. If iOS refuses the URL
  /// the label says so for a moment ("Couldn't open Health"); nothing else happens. `quiet` is a centred text link.
  public struct OpenHealthButton: View {
    @Environment(\.openURL) private var openURL
    @State private var failed = false
    private let quiet: Bool

    public init(quiet: Bool = false) { self.quiet = quiet }

    private var title: String { failed ? HealthLauncher.failureMessage : "Open Health" }
    private var alignment: Alignment { quiet ? .center : .leading }

    public var body: some View {
      Button {
        openURL(HealthLauncher.url) { accepted in
          guard !accepted else { return }
          failed = true
          AccessibilityNotification.Announcement(HealthLauncher.failureMessage).post()
          Task {
            try? await Task.sleep(for: .seconds(2.5))
            failed = false
          }
        }
      } label: {
        Group {
          if quiet {
            Text(title)
          } else {
            Label(title, systemImage: failed ? "exclamationmark.circle" : "heart.text.square")
          }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(failed ? Color.secondary : HealthStyle.accent)
        .frame(minHeight: 44, alignment: alignment)
        .frame(maxWidth: .infinity, alignment: alignment)
        .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityHint("Opens Apple's Health app")
      .accessibilityIdentifier("health.open")
    }
  }
#endif
