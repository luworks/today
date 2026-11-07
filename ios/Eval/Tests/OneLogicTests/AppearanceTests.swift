import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// Settings → Appearance: System (default), Light, Dark and how they map to the SwiftUI and UIKit styles.
final class AppearanceTests: XCTestCase {
  func testDefaultIsSystem() {
    XCTAssertEqual(Appearance.default, .system)
    XCTAssertEqual(Appearance(stored: nil), .system, "nothing saved yet")
    XCTAssertEqual(Appearance(stored: "sepia"), .system, "an unknown saved value falls back")
  }

  func testRawValuesAreStable() {
    XCTAssertEqual(
      Appearance.allCases.map(\.rawValue), ["system", "light", "dark"],
      "saved under today.appearance")
    XCTAssertEqual(Appearance.storageKey, "today.appearance")
    for a in Appearance.allCases { XCTAssertEqual(Appearance(stored: a.rawValue), a) }
  }

  func testSettingsOrderAndTitles() {
    XCTAssertEqual(Appearance.displayOrder.map(\.title), ["System", "Light", "Dark"])
  }

  func testAppTextIsOneStepSmallerThanTheSystemSetting() {
    let name = { (size: String) in "UICTContentSizeCategory\(size)" }
    let sizes = ["XS", "S", "M", "L", "XL", "XXL", "XXXL"].map(name)
    XCTAssertEqual(Appearance.compactTextSize(system: name("L")), name("M"), "the iOS default")
    XCTAssertEqual(Appearance.compactTextSize(system: name("XS")), name("XS"), "nothing below it")
    XCTAssertEqual(
      sizes.dropFirst().map { Appearance.compactTextSize(system: $0) }, Array(sizes.dropLast()))
  }

  func testAccessibilityTextSizesAreNotReduced() {
    for size in ["M", "L", "XL", "XXL", "XXXL"].map({ "UICTContentSizeCategoryAccessibility\($0)" })
    {
      XCTAssertEqual(Appearance.compactTextSize(system: size), size)
    }
    XCTAssertEqual(
      Appearance.compactTextSize(system: "_UICTContentSizeCategoryUnspecified"),
      "_UICTContentSizeCategoryUnspecified")
  }

  func testMappingToSchemes() {
    XCTAssertNil(Appearance.system.forcesDark, "system leaves the scheme to iOS")
    XCTAssertEqual(Appearance.light.forcesDark, false)
    XCTAssertEqual(Appearance.dark.forcesDark, true)
    // UIUserInterfaceStyle: 0 unspecified, 1 light, 2 dark. System must restore .unspecified.
    XCTAssertEqual(Appearance.system.userInterfaceStyleRawValue, 0)
    XCTAssertEqual(Appearance.light.userInterfaceStyleRawValue, 1)
    XCTAssertEqual(Appearance.dark.userInterfaceStyleRawValue, 2)
  }

  func testLaunchOverrideOnlyUnderUITesting() {
    XCTAssertNil(
      LaunchTestConfiguration.appearanceOverride(arguments: ["-appearance", "dark"]),
      "a real launch ignores it")
    XCTAssertEqual(
      LaunchTestConfiguration.appearanceOverride(arguments: ["-uiTesting"]), .system,
      "UI tests start on System")
    XCTAssertEqual(
      LaunchTestConfiguration.appearanceOverride(arguments: ["-uiTesting", "-appearance", "dark"]),
      .dark)
    XCTAssertEqual(
      LaunchTestConfiguration.appearanceOverride(arguments: ["-uiTesting", "-appearance", "light"]),
      .light)
    XCTAssertNil(
      LaunchTestConfiguration.appearanceOverride(arguments: [
        "-uiTesting", "-uiTestingKeepAppearance",
      ]), "keeps what was saved")
  }
}
