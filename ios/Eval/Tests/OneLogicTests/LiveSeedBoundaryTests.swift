import Foundation
import Testing

/// Guards the executable/package boundary: Live must never link the synthetic planner.
struct LiveSeedBoundaryTests {
  private var ios: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  @Test func liveShellCannotSeedSamplePlannerOrReadTestSeedArguments() throws {
    let shell = try String(contentsOf: ios.appendingPathComponent("Sources/TodayShell/HomeView.swift"), encoding: .utf8)
    #expect(!shell.contains("SampleData"))
    #expect(shell.contains("Self.seedUITestReminder(context, arguments: composition.arguments)"))
    #expect(!FileManager.default.fileExists(atPath: ios.appendingPathComponent("Sources/One/SampleData.swift").path))
    let fixture = try String(contentsOf: ios.appendingPathComponent("Development/Support/SampleData.swift"), encoding: .utf8)
    #expect(fixture.hasPrefix("#if TODAY_MOCK"))
    let app = try String(contentsOf: ios.appendingPathComponent("App/OneApp.swift"), encoding: .utf8)
    #expect(app.contains("arguments: [],"), "Live ignores development seed arguments")
    #expect(app.contains("prepareData: prepareMockData"), "Mock retains deterministic dataset preparation")
  }
}
