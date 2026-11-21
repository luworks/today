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
}
