#if os(iOS)
  import TodayCore
  import TodayShared
  import Foundation
  import AVFoundation
  import UserNotifications
  #if canImport(AlarmKit)
    import ActivityKit
  #endif

  /// The tones bundled with the app (made by `Tools/make_alarm_sounds.py`). AlarmKit can ring the system alarm sound or a
  /// sound file from the app, but not Apple's ringtones. Alarm tones are 28 seconds for alarms and timers; event and
  /// reminder tones are short notification sounds.
  package struct AlarmSound: Identifiable, Hashable {
    package enum Kind: Hashable { case alarm, event, reminder }

    package let name: String
    package let kind: Kind
    package var id: String { name }
    package var file: String { name.replacingOccurrences(of: " ", with: "") }

    package static let alarms: [AlarmSound] = [
      "Daybreak", "Chimes", "Marimba", "Glass", "Ripple", "Morning Piano", "Beacon", "Crystal",
      "Sunrise", "Harp", "Music Box", "Steel Drum", "Vibes", "Birdsong", "Classic", "Pulse",
    ].map { AlarmSound(name: $0, kind: .alarm) }

    package static let events: [AlarmSound] = [
      "Heads Up", "Doorbell", "Agenda", "Bloom", "Knock", "Prelude", "Signal", "Arrival",
    ].map { AlarmSound(name: $0, kind: .event) }

    package static let reminders: [AlarmSound] = [
      "Ping", "Note", "Tap", "Pop", "Drop", "Glint", "Nudge", "Pluck",
    ].map { AlarmSound(name: $0, kind: .reminder) }

    package static let all = alarms + events + reminders

    /// The tone saved on an alarm; nil for the system default (or a name that no longer exists).
    package static func named(_ name: String) -> AlarmSound? { all.first { $0.name == name } }

    package var url: URL? { Bundle.main.url(forResource: file, withExtension: "caf") }

    package var notificationSound: UNNotificationSound {
      UNNotificationSound(named: UNNotificationSoundName(file + ".caf"))
    }

    #if canImport(AlarmKit)
      package var alertSound: ActivityKit.AlertConfiguration.AlertSound { .named(file + ".caf") }
    #endif
  }

  @MainActor
  package protocol SoundPreviewing: AnyObject {
    func play(_ sound: AlarmSound)
    func stop()
  }

  /// Plays a tone for a few seconds while the user is choosing one, and stops when it is told to or the screen goes.
  @MainActor
  package final class SoundPreview: SoundPreviewing {
    package init() {}
    private var player: AVAudioPlayer?

    package func play(_ sound: AlarmSound) {
      stop()
      guard let url = sound.url else { return }
      try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
      try? AVAudioSession.sharedInstance().setActive(true)
      player = try? AVAudioPlayer(contentsOf: url)
      player?.prepareToPlay()
      player?.play()
    }

    package func stop() {
      player?.stop()
      player = nil
    }
  }

#endif
