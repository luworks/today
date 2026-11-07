import Foundation

/// The Appearance choice in Settings: follow the system (the default), always light, or always dark.
/// Plain Swift (no SwiftUI/UIKit) so the mapping runs under `swift test`; `Appearance.swift` turns it into
/// `ColorScheme` and `UIUserInterfaceStyle`.
public enum Appearance: String, CaseIterable, Identifiable, Sendable {
  case system, light, dark

  public var id: String { rawValue }

  /// `@AppStorage` key. Not part of "Delete All Data".
  public static let storageKey = "today.appearance"
  public static let `default`: Appearance = .system

  /// A stored raw value (nil or unknown, e.g. from an older build) falls back to the default.
  public init(stored: String?) {
    self = stored.flatMap(Appearance.init(rawValue:)) ?? Appearance.default
  }

  public var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  /// The order shown in Settings.
  public static let displayOrder: [Appearance] = [.system, .light, .dark]

  /// nil = follow the system, otherwise whether the app is forced dark.
  public var forcesDark: Bool? {
    switch self {
    case .system: nil
    case .light: false
    case .dark: true
    }
  }

  /// The app's text size for the system's Text Size, as `UIContentSizeCategory` raw values: one
  /// step smaller, so the default reads denser and the user's setting still scales it. The smallest
  /// size and accessibility sizes stay put: those users need all the size they asked for.
  public static func compactTextSize(system: String) -> String {
    let sizes = ["XS", "S", "M", "L", "XL", "XXL", "XXXL"].map { "UICTContentSizeCategory\($0)" }
    guard let index = sizes.firstIndex(of: system), index > 0 else { return system }
    return sizes[index - 1]
  }

  /// `UIUserInterfaceStyle` raw values: 0 unspecified (follow the system), 1 light, 2 dark.
  public var userInterfaceStyleRawValue: Int {
    switch self {
    case .system: 0
    case .light: 1
    case .dark: 2
    }
  }

}
