#if DEBUG
  import Foundation
  import Synchronization
  import SwiftUI
  import TodayCore
  import TodayScenes
  import TodayShared
  import FeatureAsk
  import One

  /// Thread-safe deterministic clock/identity stream; no process clock or mutable static state.
  final class SceneRuntimeState: Sendable {
    private struct Values {
      var now: Date
      var index: UInt64 = 10_000
    }
    private let values: Mutex<Values>
    private let configuration: SceneConfiguration

    init(configuration: SceneConfiguration) {
      self.configuration = configuration
      values = Mutex(Values(now: configuration.now))
    }
    func now() -> Date { values.withLock { $0.now } }
    func nextID() -> UUID {
      values.withLock { state in
        defer { state.index &+= 1 }
        return configuration.uuid(at: state.index)
      }
    }
    func advance(by seconds: TimeInterval) { values.withLock { $0.now.addTimeInterval(seconds) } }
    var runtime: PlannerRuntime {
      PlannerRuntime(
        now: { self.now() }, nextID: { self.nextID() },
        calendar: configuration.calendar, locale: Locale(identifier: configuration.localeIdentifier)
      )
    }
  }

  /// The agent's model, scripted per scenario, outside production features.
  @MainActor
  final class SceneAskCapabilities {
    let scenario: SceneScenario
    private(set) var disposed = false
    init(scenario: SceneScenario) { self.scenario = scenario }

    var agentModel: AgentModel {
      guard !disposed else { return .unavailable }
      switch scenario {
      case .unavailable, .denied, .revoked: return .unavailable
      case .error: return .scripted([.fail(.rejected("scripted_failure"))])
      default:
        return .scripted([
          ScriptedModelClient.reply(
            "This is a local scripted conversation. Tell me what you would like to prepare; Add or Apply confirms any change."
          )
        ])
      }
    }
    func dispose() { disposed = true }
  }

  /// Local speech driver. Start/stop never resolve speech recognition, audio or a permission API.
  @MainActor
  final class SceneSpeechDriver: SpeechInputDriving {
    let scenario: SceneScenario
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var stateCallback: (@MainActor (VoiceInput.State) -> Void)?
    init(scenario: SceneScenario) { self.scenario = scenario }
    func start(
      onTranscript: @escaping @MainActor (String) -> Void,
      onState: @escaping @MainActor (VoiceInput.State) -> Void
    ) async {
      startCount += 1
      stateCallback = onState
      switch scenario {
      case .denied, .revoked: onState(.denied)
      case .unavailable, .error: onState(.unavailable)
      case .loading: onState(.listening)
      default:
        onState(.listening)
        onTranscript("Remind me to review the design tomorrow at 2 pm")
      }
    }
    func stop() {
      stopCount += 1
      stateCallback?(.idle)
      stateCallback = nil
    }
  }

  @MainActor
  struct SceneEmptyInbox: ShareInboxReading {
    func read() throws -> [SharedReminder] { [] }
    func acknowledge(_ ids: Set<UUID>) -> Bool { ids.isEmpty }
  }
#endif
