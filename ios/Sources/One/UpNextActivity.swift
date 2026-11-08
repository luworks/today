#if os(iOS)
  import ActivityKit
  import Foundation
  import TodayCore
  import TodayData
  import TodayShared
  import UIKit

  /// Starts, updates and ends the single Lock Screen "Up Next" card. The decisions are `UpNextLifecycle`; this only
  /// talks to ActivityKit and remembers a dismissal. Local updates only: no push, no scheduled start, no alert.
  @MainActor
  package final class UpNextActivity {
    private static let dismissedAtKey = "today.upNext.dismissedAt"
    /// When the app last started a card, to tell afterwards that it vanished while the app was not running.
    private static let requestedAtKey = "today.upNext.requestedAt"

    private let defaults: UserDefaults
    private let activity: ActivityCenter
    private let runtime: PlannerRuntime
    private var pendingRows: [UpNextRow]?
    private var pump: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var observedID: String?
    private var endedByApp: Set<String> = []
    private var checkedVanished = false

    package init(defaults: UserDefaults, activity: ActivityCenter, runtime: PlannerRuntime) {
      self.defaults = defaults
      self.activity = activity
      self.runtime = runtime
    }

    package func dispose() {
      pendingRows = nil
      pump?.cancel()
      observer?.cancel()
    }

    package func refresh(items: [WidgetItem], now: Date) {
      pendingRows = UpNextLive.rows(from: items, now: now)
      guard pump == nil else { return }
      // One at a time: an update or end suspends, and a second pass in between could request a second card.
      pump = Task { [weak self] in
        while let self, !Task.isCancelled, let rows = self.pendingRows {
          self.pendingRows = nil
          await self.apply(rows)
        }
        self?.pump = nil
      }
    }

    /// Lets background refresh finish its ActivityKit work before it tells iOS it is done.
    package func settle() async {
      await pump?.value
    }

    private func apply(_ rows: [UpNextRow]) async {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      let now = runtime.now()
      let existing = Activity<UpNextAttributes>.activities.filter { $0.activityState != .dismissed }
      noticeVanished(existing: existing, now: now)
      for extra in existing.dropFirst() { await end(extra) }
      let current = existing.first
      if let current { observe(current) }

      let allowed =
        Preferences.upNextLiveActivityEnabled(defaults)
        && !UpNextLifecycle.isSuppressed(
          dismissedAt: defaults.object(forKey: Self.dismissedAtKey) as? Date, now: now,
          calendar: runtime.calendar)
      let live = current.map {
        UpNextLifecycle.Live(
          rows: $0.content.state.rows, requestedAt: $0.attributes.requestedAt,
          isEnded: $0.activityState == .ended)
      }
      let action = UpNextLifecycle.action(
        rows: rows, live: live, allowed: allowed,
        isForeground: UIApplication.shared.applicationState != .background, now: now)
      let content = ActivityKit.ActivityContent(
        state: UpNextAttributes.ContentState(rows: rows), staleDate: nil)
      switch action {
      case .none:
        break
      case .start:
        request(content, now: now)
      case .update:
        if let current { await update(current, content) }
      case .end:
        if let current { await end(current) }
      case .restart:
        if let current { await end(current) }
        request(content, now: now)
      }
    }

    private func request(
      _ content: ActivityKit.ActivityContent<UpNextAttributes.ContentState>, now: Date
    ) {
      guard
        let started = try? Activity.request(
          attributes: UpNextAttributes(requestedAt: now), content: content, pushType: nil)
      else { return }
      defaults.set(now, forKey: Self.requestedAtKey)
      observe(started)
    }

    private func update(
      _ activity: Activity<UpNextAttributes>,
      _ content: ActivityKit.ActivityContent<UpNextAttributes.ContentState>
    ) async {
      // ActivityKit's nonisolated calls take the activity, which it does not mark Sendable; only this actor holds it.
      nonisolated(unsafe) let activity = activity
      await activity.update(content, alertConfiguration: nil)
    }

    private func end(_ activity: Activity<UpNextAttributes>) async {
      endedByApp.insert(activity.id)
      defaults.removeObject(forKey: Self.requestedAtKey)
      nonisolated(unsafe) let activity = activity
      await activity.end(nil, dismissalPolicy: .immediate)
    }

    /// A Lock Screen swipe usually happens while the app is not running, so the state stream never reports it.
    private func noticeVanished(existing: [Activity<UpNextAttributes>], now: Date) {
      guard !checkedVanished else { return }
      checkedVanished = true
      guard existing.isEmpty else { return }
      let requestedAt = defaults.object(forKey: Self.requestedAtKey) as? Date
      if UpNextLifecycle.vanishedByDismissal(requestedAt: requestedAt, now: now) {
        recordDismissal(now: now)
      }
      defaults.removeObject(forKey: Self.requestedAtKey)
    }

    private func observe(_ activity: Activity<UpNextAttributes>) {
      guard observedID != activity.id else { return }
      observedID = activity.id
      observer?.cancel()
      observer = Task { [weak self] in
        var previous = activity.activityState
        for await state in activity.activityStateUpdates {
          // From `.ended` it was the system clearing a finished card, not the user.
          if state == .dismissed, previous != .ended { self?.didDismiss(activity.id) }
          previous = state
        }
      }
    }

    private func didDismiss(_ id: String) {
      guard !endedByApp.contains(id), ActivityAuthorizationInfo().areActivitiesEnabled else {
        return
      }
      defaults.removeObject(forKey: Self.requestedAtKey)
      recordDismissal(now: runtime.now())
    }

    private func recordDismissal(now: Date) {
      defaults.set(now, forKey: Self.dismissedAtKey)
      activity.record(ActivityEvents.upNextDismissed(at: now))
    }
  }
#endif
