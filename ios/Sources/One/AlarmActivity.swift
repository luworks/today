#if os(iOS)
  #if canImport(AlarmKit)
    import AlarmKit
    import AppIntents
    import Foundation
    import TodayShared

    // Shared by the app and the TodayWidgets extension: the metadata on every AlarmKit alarm (so both sides agree on
    // the `AlarmAttributes<AlarmMeta>` Live Activity type), and the buttons on that Live Activity.
    // AlarmKit ships no intents of its own; these call AlarmManager, and run in the app's process.

    struct AlarmMeta: AlarmMetadata {
      enum Kind: String, Codable, Hashable, Sendable {
        case timer, alarm
      }
      var kind: Kind
    }

    struct PauseAlarmIntent: LiveActivityIntent {
      static let title: LocalizedStringResource = "Pause"
      static let isDiscoverable = false

      @Parameter(title: "Alarm ID") var alarmID: String

      init(alarmID: UUID) { self.alarmID = alarmID.uuidString }
      init() {}

      func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try AlarmManager.shared.pause(id: id) }
        return .result()
      }
    }

    struct ResumeAlarmIntent: LiveActivityIntent {
      static let title: LocalizedStringResource = "Resume"
      static let isDiscoverable = false

      @Parameter(title: "Alarm ID") var alarmID: String

      init(alarmID: UUID) { self.alarmID = alarmID.uuidString }
      init() {}

      func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try AlarmManager.shared.resume(id: id) }
        return .result()
      }
    }

    /// The alarm's own Stop (AlarmKit's `stopIntent`): stops it and leaves a `sys.alarm.stopped` event in the Activity outbox,
    /// so the day it rang shows it stopped (`DayHistory`). The outbox, not the store: this may run before the app is up.
    struct AlarmStoppedIntent: LiveActivityIntent {
      static let title: LocalizedStringResource = "Stop"
      static let isDiscoverable = false

      @Parameter(title: "Alarm ID") var alarmID: String
      @Parameter(title: "Label") var label: String

      init(alarmID: UUID, label: String) {
        self.alarmID = alarmID.uuidString
        self.label = label
      }
      init() {}

      func perform() async throws -> some IntentResult {
        // As Apple's AlarmKit sample does: the intent stops the alarm itself.
        if let id = UUID(uuidString: alarmID) { try? AlarmManager.shared.stop(id: id) }
        ActivityOutbox.append(
          kind: "sys.alarm.stopped", actor: "you", channel: "notification", subjectKind: "alarm",
          subjectRef: alarmID, title: label)
        return .result()
      }
    }

    /// Ends a running timer or a snooze. `stop` deletes a one-shot alarm (the timer) and puts a repeating alarm
    /// back on its schedule, so a snoozing weekday alarm still rings tomorrow.
    struct StopAlarmIntent: LiveActivityIntent {
      static let title: LocalizedStringResource = "Stop"
      static let isDiscoverable = false

      @Parameter(title: "Alarm ID") var alarmID: String

      init(alarmID: UUID) { self.alarmID = alarmID.uuidString }
      init() {}

      func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try AlarmManager.shared.stop(id: id) }
        return .result()
      }
    }
  #endif
#endif
