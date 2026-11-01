import FeatureAsk
import FeatureClock
import FeatureHealth
import One
import SwiftData
import SwiftUI
import TodayCore
import TodayData
import TodayDesignSystem
import TodayPlatform
import TodayShared
import TodayShell

#if TODAY_MOCK
  import TodayTestSupport
#endif

@main
@MainActor
struct OneApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  private let diagnostics = LocalDiagnostics()
  private let composition: ShellComposition
  private let healthModel: HealthModel
  private let healthLineModel: HealthLineModel
  private let weatherModel: WeatherModel
  #if TODAY_MOCK
    private let mock: MockAppComposition
  #endif

  init() {
    let source: any HealthSource
    #if TODAY_MOCK
      do {
        let mock = try MockAppComposition(arguments: ProcessInfo.processInfo.arguments)
        self.mock = mock
        composition = mock.shell
      } catch { fatalError("Could not open the development store: \(error)") }
      source = HealthTestSources.scripted(
        base: MockHealthSource(), arguments: ProcessInfo.processInfo.arguments)
    #else
      let liveSession = OneStore.session
      do {
        guard let url = Bundle.main.url(forResource: "cities", withExtension: "json") else {
          throw CocoaError(.fileNoSuchFile)
        }
        let cities = try CityDatabase.decode(Data(contentsOf: url))
        let world = WorldClockStore(
          database: cities, defaults: liveSession.defaults,
          homeZoneIdentifier: liveSession.runtime.calendar.timeZone.identifier)
        let stopwatch = StopwatchModel(defaults: liveSession.defaults, now: liveSession.runtime.now)
        composition = ShellComposition(
          session: liveSession, world: world, stopwatch: stopwatch,
          intelligence: .live(locale: liveSession.runtime.locale),
          voice: VoiceInput(driver: LiveSpeechInputDriver(locale: liveSession.runtime.locale)),
          arguments: [],
          openSettings: {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
          })
      } catch { fatalError("Could not load the city database: \(error)") }
      source = HealthKitSource()
    #endif
    let session = composition.session
    #if TODAY_MOCK
      weatherModel = WeatherModel(sample: WeatherTestData.snapshot(now: session.runtime.now()))
      let selection = HealthTestSelection.make(
        defaults: session.defaults, arguments: composition.arguments)
    #else
      weatherModel = WeatherModel()
      let selection = HealthSelectionStore(defaults: session.defaults)
    #endif
    let gate = HealthAccessGate()
    healthModel = HealthModel(
      source: source, store: selection, runtime: session.runtime, gate: gate)
    healthLineModel = HealthLineModel(model: healthModel)
    diagnostics.start()
    if PerformanceTrace.enabled { PerformanceTrace.shared.beginLaunch() }
    LaunchTimer.mark("app init")
    #if TODAY_MOCK
      if composition.arguments.contains("-uiTesting") { SampleData.resetFlags() }
      HealthDebugSeed.runIfRequested()
    #endif
    LaunchTimer.mark("store ready")
  }

  #if TODAY_MOCK
    private func prepareMockData(_ context: ModelContext) async -> Bool {
      if composition.arguments.contains("-seedCalendarDemo"),
        let calendar = composition.session.calendar as? CalendarSync
      {
        await calendar.seedDemo()
      }
      LaunchTestConfiguration.seedLegacyLedgerForTests(
        context: context, arguments: composition.arguments,
        runtime: composition.session.runtime)
      if let path = DevImport.requestedPath {
        do {
          _ = try DevImport.run(path: path, into: context)
          ListActions.ensureLists(in: context, runtime: composition.session.runtime)
        } catch { print("IMPORT failed code: \((error as NSError).code)") }
        return false
      }
      if let path = TestDataset.requestedPath {
        do {
          try TestDataset.load(
            path: path, into: context, now: composition.session.runtime.now(),
            calendar: composition.session.runtime.calendar)
          if let fake = composition.session.calendar as? TestCalendarService {
            for (id, n) in TestDataset.audiences {
              fake.audiences[id] = (n, true)
              fake.writableExternalIDs.insert(id)
            }
            // Linked dataset events can be saved back (an Undo of a delete re-creates them).
            if !TestDataset.audiences.isEmpty {
              // Like EventKit, saving an unlinked copy creates a new linked event.
              fake.saveResult = { event in
                event.externalID ?? "dataset-restored-\(UUID().uuidString)"
              }
            }
          }
        } catch {
          print("DATASET failed code: \((error as NSError).code)")
        }
      } else {
        SampleData.insertIfNeeded(context)
      }
      return true
    }
  #endif

  var body: some Scene {
    WindowGroup {
      #if TODAY_MOCK
        HomeView(composition: composition, diagnostics: diagnostics, prepareData: prepareMockData)
          .environment(healthModel).environment(healthLineModel).environment(weatherModel)
          .appearanceRoot(defaults: composition.session.defaults, windows: appWindows)
      #else
        HomeView(composition: composition, diagnostics: diagnostics)
          .environment(healthModel).environment(healthLineModel).environment(weatherModel)
          .appearanceRoot(defaults: composition.session.defaults, windows: appWindows)
      #endif
    }
    .modelContainer(composition.session.container)
  }

  private func appWindows() -> [UIWindow] {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
  }
}
