#if os(iOS)
  import EventKit
  import FeatureSearch
  import SwiftData
  import SwiftUI
  import Testing
  import TodayCore
  import TodayDesignSystem
  import UIKit
  import Vision
  @testable import One

  @MainActor
  extension PlannerSessionTests {
    @Test
    func searchTypingReusesCalendarSnapshotAndRefreshRetiresOldResults() async throws {
      let suite = "SearchCalendarIntegration.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(true, forKey: "today.calendarSync.enabled")
      let now = Date(timeIntervalSince1970: 1_792_314_000)
      var cal = Calendar(identifier: .gregorian)
      cal.timeZone = try #require(TimeZone(secondsFromGMT: 0))
      let runtime = PlannerRuntime(
        now: { now }, nextID: { UUID() }, calendar: cal, locale: Locale(identifier: "en_US"))
      let schema = Schema([OneTask.self, OneEvent.self, OneAlarm.self])
      let container = try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
      var reads = 0
      var stores = 0
      var title = "Dentist source snapshot"
      let calendar = CalendarSync(
        defaults: defaults, runtime: runtime, arguments: [],
        makeStore: {
          stores += 1
          return EKEventStore()
        },
        readEvents: { _ in
          reads += 1
          return [
            ExternalEvent(
              id: "fixture-occurrence", eventIdentifier: "fixture-event", title: title,
              start: now, end: now.addingTimeInterval(3600), isAllDay: false,
              calendarID: "fixture-calendar", calendarTitle: "Fixture", color: .blue)
          ]
        }, authorizationStatus: { .fullAccess })
      defer { calendar.dispose() }
      let view = SearchView(calendar: calendar, defaults: defaults) { _ in Text("Editor") }
        .modelContainer(container)
        .environment(PlannerPresentation(runtime: runtime, defaults: defaults))
      let host = UIHostingController(rootView: view)
      let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previous = scene.windows.first(where: \.isKeyWindow)
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
      }
      try await Task.sleep(for: .milliseconds(200))
      let field = try #require(searchTextField(in: host.view))
      #expect(reads == 0, "Opening suggestions must not load four years of Calendar")
      for character in "Dentist" {
        field.insertText(String(character))
        try await Task.sleep(for: .milliseconds(60))
      }
      print("SEARCH_CALENDAR_READS typing=\(reads) characters=7 fixture=1 viewport=393x852")
      #expect(reads == 1, "Seven keystrokes must filter one accepted Calendar snapshot")
      #expect(stores == 0, "The injected range source must never open EventKit")
      #expect(try searchLabels(host).contains("Dentist source snapshot"))
      Attachment.record(searchImage(host), named: "search-calendar-typed.png")

      title = "Dentist refreshed snapshot"
      calendar.refresh()
      try await Task.sleep(for: .milliseconds(150))
      #expect(reads == 2, "A source version change must fetch fresh values")
      let refreshedLabels = try searchLabels(host)
      #expect(refreshedLabels.contains("Dentist refreshed snapshot"))
      #expect(!refreshedLabels.contains("Dentist source snapshot"))
      // A mirrored source item is excluded by its native identity without another range query.
      let mirror = OneEvent(title: title, start: now, durationMinutes: 60)
      mirror.externalID = "fixture-event"
      container.mainContext.insert(mirror)
      try container.mainContext.save()
      try await Task.sleep(for: .milliseconds(150))
      #expect(reads == 2, "Local mirror changes must not refetch the system calendar")
      #expect(try searchLabels(host).components(separatedBy: title).count == 2)
      container.mainContext.delete(mirror)
      try container.mainContext.save()
      try await Task.sleep(for: .milliseconds(100))
      #expect(reads == 2, "Removing a local mirror only changes memory filtering")
      await calendar.setEnabled(false)
      try await Task.sleep(for: .milliseconds(100))
      #expect(reads == 2, "Disabling Calendar clears its snapshot without a range read")
      #expect(try !searchLabels(host).contains(title))
      await calendar.setEnabled(true)
      try await Task.sleep(for: .milliseconds(150))
      #expect(reads == 3, "Re-enabling Calendar must not reuse a retired snapshot")
      print("SEARCH_CALENDAR_READS final=\(reads) nativeStores=\(stores)")
    }

    private func searchTextField(in view: UIView) -> UITextField? {
      if let field = view as? UITextField { return field }
      return view.subviews.lazy.compactMap { searchTextField(in: $0) }.first
    }

    private func searchLabels(_ host: UIViewController) throws -> String {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["en-US"]
      try VNImageRequestHandler(data: searchImage(host)).perform([request])
      return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
    }

    private func searchImage(_ host: UIViewController) -> Data {
      host.view.layoutIfNeeded()
      return UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }.pngData() ?? Data()
    }
  }
#endif
