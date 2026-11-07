#if os(iOS)
  import TodayCore
  import TodayShared
  import SwiftUI
  import UIKit

  extension Appearance {
    /// nil = follow the system.
    public var colorScheme: ColorScheme? {
      forcesDark.map { $0 ? .dark : .light }
    }

    public var userInterfaceStyle: UIUserInterfaceStyle {
      UIUserInterfaceStyle(rawValue: userInterfaceStyleRawValue) ?? .unspecified
    }

    /// Composition may explicitly supply an initial choice before creating views.
    /// A nil choice preserves the value already stored in these defaults.
    public static func applyConfiguration(_ appearance: Appearance?, defaults: UserDefaults) {
      if let appearance { defaults.set(appearance.rawValue, forKey: storageKey) }
    }

    /// Update only windows owned by the caller. System appearance uses `.unspecified`.
    @MainActor
    public func applyToWindows(_ windows: [UIWindow]) {
      for window in windows where window.overrideUserInterfaceStyle != userInterfaceStyle {
        window.overrideUserInterfaceStyle = userInterfaceStyle
      }
    }
  }

  extension UIWindow {
    /// A window-level trait reaches SwiftUI, UIKit text and every sheet alike, from one place.
    @MainActor
    fileprivate static func applyCompactTextSize(_ windows: [UIWindow]) {
      let system = UIApplication.shared.preferredContentSizeCategory
      let size = UIContentSizeCategory(
        rawValue: Appearance.compactTextSize(system: system.rawValue))
      // The override has no readable value until the first write, so always write it.
      for window in windows { window.traitOverrides.preferredContentSizeCategory = size }
    }
  }

  /// The root supplies its defaults and window ownership, including newly created windows.
  @MainActor
  private struct AppearanceRoot: ViewModifier {
    @AppStorage private var stored: String
    private let windows: @MainActor () -> [UIWindow]

    init(defaults: UserDefaults, windows: @escaping @MainActor () -> [UIWindow]) {
      _stored = AppStorage(
        wrappedValue: Appearance.default.rawValue, Appearance.storageKey, store: defaults)
      self.windows = windows
    }

    private var appearance: Appearance { Appearance(stored: stored) }

    private func applyToWindows() {
      let windows = windows()
      appearance.applyToWindows(windows)
      UIWindow.applyCompactTextSize(windows)
    }

    func body(content: Content) -> some View {
      content
        .preferredColorScheme(appearance.colorScheme)
        .onAppear { applyToWindows() }
        .onChange(of: stored) { _, _ in applyToWindows() }
        // Global notifications only trigger a refresh of the caller's owned windows.
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) {
          _ in
          applyToWindows()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) {
          _ in
          applyToWindows()
        }
        .onReceive(
          NotificationCenter.default.publisher(for: UIContentSizeCategory.didChangeNotification)
        ) { _ in
          applyToWindows()
        }
    }
  }

  extension View {
    /// Production supplies its app windows; each Workbench session supplies only its own window.
    @MainActor
    public func appearanceRoot(
      defaults: UserDefaults, windows: @escaping @MainActor () -> [UIWindow]
    ) -> some View {
      modifier(AppearanceRoot(defaults: defaults, windows: windows))
    }
  }
#endif
