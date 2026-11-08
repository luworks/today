#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import EventKit
  import EventKitUI
  import SwiftUI
  import os

  /// A read-only event from the system calendar (Apple Calendar, Google, Exchange…).
  package struct ExternalEvent: Identifiable, Hashable {
    package let id: String
    /// EventKit identifier, for opening the event in Apple's own viewer.
    package let eventIdentifier: String
    package let title: String
    package var location: String = ""
    package let start: Date
    package let end: Date
    package let isAllDay: Bool
    package var calendarID: String = ""
    package let calendarTitle: String
    package let color: Color
    /// Address plus coordinate (when Apple Calendar has one), for travel time. Nil without a location.
    package var place: TravelPlace? = nil
    /// Part of a repeating series (Delete asks "this event or all future", and offers no Undo).
    package var repeats = false
    /// From a subscribed, holiday or Birthdays calendar: background, not the user's own load (Year's busy days).
    package var isBackground = false
    package var isBirthday = false
    package var isHoliday = false

    package init(
      id: String, eventIdentifier: String, title: String, location: String = "",
      start: Date, end: Date, isAllDay: Bool, calendarID: String = "", calendarTitle: String,
      color: Color, place: TravelPlace? = nil, repeats: Bool = false,
      isBackground: Bool = false, isBirthday: Bool = false, isHoliday: Bool = false
    ) {
      self.id = id
      self.eventIdentifier = eventIdentifier
      self.title = title
      self.location = location
      self.start = start
      self.end = end
      self.isAllDay = isAllDay
      self.calendarID = calendarID
      self.calendarTitle = calendarTitle
      self.color = color
      self.place = place
      self.repeats = repeats
      self.isBackground = isBackground
      self.isBirthday = isBirthday
      self.isHoliday = isHoliday
    }

    package var durationMinutes: Int { max(1, Int(end.timeIntervalSince(start) / 60)) }
  }

  /// Private-content-bearing snapshots belong in the ledger snapshot, never in props.
  package struct CalendarMoveSnapshot: Codable, Equatable {
    package let externalID: String
    package let calendarID: String
    package let sourceID: String
    package let itemID: String
    /// The actual start used for occurrence lookup, including after a move.
    package let occurrence: Date
    package let start: Date
    package let end: Date
    package let isAllDay: Bool
    package let lastModified: Date
    package let title: String
    package let location: String?
    package let notes: String?
    package let url: String?
    package let audience: CalendarMoveAudience
    /// Participant identifiers make changes to the audience stale, not just count changes.
    package let participantIDs: [String]
  }

  package struct CalendarMoveAudience: Codable, Equatable {
    package let attendeeCount: Int
    package let isOrganizer: Bool?
  }

  package struct CalendarMoveReceipt: Codable, Equatable {
    package let before: CalendarMoveSnapshot
    package let after: CalendarMoveSnapshot
  }

  package struct CalendarMoveUnverified: Codable, Equatable {
    package let before: CalendarMoveSnapshot
    package let requestedStart: Date
    package let requestedEnd: Date
    package let savedExternalID: String?
  }

  package enum CalendarMoveOutcome {
    case verified(CalendarMoveReceipt)
    case committedUnverified(CalendarMoveUnverified)
  }

  package enum CalendarMoveUndoOutcome {
    case verified
    case committedUnverified
  }

  package enum CalendarMoveError: Error, Equatable {
    case unavailable, notFound, readOnly, audienceUnknownOrUnsafe, audienceAcknowledgmentRequired,
      stale, invalidTime
  }

  /// A system calendar (one line in Apple's Calendars list).
  package struct SystemCalendar: Identifiable, Hashable {
    package let id: String
    package let title: String
    package let sourceTitle: String
    package let color: Color
    package var allowsContentModifications: Bool
    package var isBirthday = false
    package var isHoliday = false
    package init(
      id: String, title: String, sourceTitle: String, color: Color,
      isBirthday: Bool = false, isHoliday: Bool = false,
      allowsContentModifications: Bool = true
    ) {
      self.id = id
      self.title = title
      self.sourceTitle = sourceTitle
      self.color = color
      self.isBirthday = isBirthday
      self.isHoliday = isHoliday
      self.allowsContentModifications = allowsContentModifications
    }

  }

  /// Scalar transport: EventKit objects remain on the reader actor.
  package struct CalendarFocusImport: Sendable {
    package let externalID: String
    package let identity: FocusIdentity
    package let title: String
    package let start: Date
    package let end: Date
    package let isAllDay: Bool
    package let calendarTitle: String
    package let colorComponents: [Double]
    package let repeats: Bool
    package let canDelete: Bool

    @MainActor var event: ExternalEvent {
      ExternalEvent(
        id: externalID + "@\(start.timeIntervalSince1970)", eventIdentifier: externalID,
        title: title, start: start, end: end, isAllDay: isAllDay,
        calendarID: identity.calendar, calendarTitle: calendarTitle,
        color: colorComponents.count >= 3
          ? Color(
            .sRGB, red: colorComponents[0], green: colorComponents[1], blue: colorComponents[2])
          : .blue, repeats: repeats)
    }
  }

  private actor CalendarFocusReader {
    func load(_ records: [FocusRecord]) -> [CalendarFocusImport] {
      guard !Task.isCancelled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
        return []
      }
      let store = EKEventStore()
      var result: [CalendarFocusImport] = []
      for record in records {
        guard !Task.isCancelled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
          return []
        }
        guard let ref = record.localReference, ref.hasPrefix("eventkit:") else { continue }
        let id = String(ref.dropFirst("eventkit:".count))
        guard let calendar = store.calendar(withIdentifier: record.identity.calendar),
          calendar.source?.sourceIdentifier == record.identity.account
        else { continue }
        let event: EKEvent?
        if let occurrence = record.identity.occurrence {
          let predicate = store.predicateForEvents(
            withStart: occurrence.addingTimeInterval(-60),
            end: occurrence.addingTimeInterval(60), calendars: [calendar])
          event = store.events(matching: predicate).first {
            $0.eventIdentifier == id && $0.occurrenceDate == occurrence
          }
        } else {
          event = store.event(withIdentifier: id)
        }
        guard let event, let source = event.calendar.source else { continue }
        let repeats = event.hasRecurrenceRules || event.isDetached
        let identity = FocusIdentity(
          provider: "apple.calendar", account: source.sourceIdentifier,
          calendar: event.calendar.calendarIdentifier, item: event.calendarItemIdentifier,
          occurrence: repeats ? event.occurrenceDate : nil)
        guard identity == record.identity, !repeats || identity.occurrence != nil else { continue }
        result.append(
          CalendarFocusImport(
            externalID: id, identity: identity, title: event.title ?? "Untitled",
            start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
            calendarTitle: event.calendar.title,
            colorComponents: (event.calendar.cgColor.components ?? []).map(Double.init),
            repeats: repeats, canDelete: event.calendar.allowsContentModifications))
      }
      return result
    }
  }

  /// Scalar transport for a range read off the main actor (the Year view's year of events).
  private struct CalendarRangeImport: Sendable {
    let eventIdentifier: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarID: String
    let calendarTitle: String
    /// sRGB red, green, blue; empty when the calendar color has no sRGB form.
    let rgb: [Double]
    let repeats: Bool
    let isSubscription: Bool
    let isBirthday: Bool

    @MainActor var event: ExternalEvent {
      ExternalEvent(
        id: eventIdentifier + "@\(start.timeIntervalSince1970)", eventIdentifier: eventIdentifier,
        title: title, start: start, end: end, isAllDay: isAllDay, calendarID: calendarID,
        calendarTitle: calendarTitle,
        color: rgb.count == 3 ? Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2]) : .blue,
        repeats: repeats,
        isBackground: YearLoad.isBackgroundCalendar(
          isSubscription: isSubscription, isBirthday: isBirthday, title: calendarTitle),
        isBirthday: isBirthday,
        isHoliday: YearEventMarks.isHolidayCalendar(
          isSubscription: isSubscription, title: calendarTitle))
    }
  }

  /// Reads long ranges with its own store, so a year of events never blocks the main actor. EventKit objects stay here.
  private actor CalendarRangeReader {
    private var store: EKEventStore?

    func events(in interval: DateInterval, hidden: Set<String>) -> [CalendarRangeImport] {
      guard !Task.isCancelled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
        return []
      }
      let store = self.store ?? EKEventStore()
      self.store = store
      let all = store.calendars(for: .event)
      let visible = all.filter { !hidden.contains($0.calendarIdentifier) }
      guard !visible.isEmpty else { return [] }
      let srgb = CGColorSpace(name: CGColorSpace.sRGB)
      var colors: [String: [Double]] = [:]
      for calendar in visible {
        colors[calendar.calendarIdentifier] =
          srgb.flatMap {
            calendar.cgColor.converted(to: $0, intent: .defaultIntent, options: nil)?.components
          }.map { Array($0.prefix(3).map(Double.init)) } ?? []
      }
      let predicate = store.predicateForEvents(
        withStart: interval.start, end: interval.end,
        calendars: visible.count == all.count ? nil : visible)
      return store.events(matching: predicate).map { e in
        CalendarRangeImport(
          eventIdentifier: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Untitled",
          start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
          calendarID: e.calendar.calendarIdentifier, calendarTitle: e.calendar.title,
          rgb: colors[e.calendar.calendarIdentifier] ?? [], repeats: e.hasRecurrenceRules,
          isSubscription: e.calendar.type == .subscription,
          isBirthday: e.calendar.type == .birthday)
      }
    }
  }

  /// EventKit bridge: shows system calendar events in Today / Calendar, and can save new events there.
  @MainActor
  @Observable
  package final class CalendarSync: NativeCalendarService {
    @ObservationIgnored private let log = Logger(
      subsystem: "com.luworks.today", category: "calendar")

    /// Created on first use: EKEventStore is slow to set up and most launches don't need it.
    @ObservationIgnored private lazy var store: EKEventStore = {
      let s = makeStore()
      observers.append(
        NotificationCenter.default.addObserver(
          forName: .EKEventStoreChanged, object: s, queue: .main
        ) { [weak self] _ in
          Task { @MainActor in
            guard let self, !self.disposed else { return }
            self.version += 1
          }
        })
      return s
    }()
    private static let enabledKey = "today.calendarSync.enabled"
    private static let hiddenKey = "today.calendarSync.hiddenCalendars"

    /// Bumped when the system calendar changes so views refetch.
    package private(set) var version = 0
    /// UI tests start with Apple Calendar off (a saved "on" from an earlier run would leak test events into the
    /// system calendar); the tests that need it pass `-uiTestingCalendarSync`.
    package private(set) var enabled: Bool
    /// Calendars turned off in the Calendars list. Stored as "hidden" so new calendars show by default, like Apple's.
    /// (UI tests start with every calendar shown, so an earlier run can't hide events from a later one.)
    package private(set) var hiddenCalendarIDs: Set<String>

    package var hasAccess: Bool {
      let status = authorizationStatus()
      // A successful full-access callback can precede EventKit's status update.
      // Keep that session-only answer until a determined status supersedes it.
      if status != .notDetermined { pendingFullAccessGrant = false }
      return status == .fullAccess || (status == .notDetermined && pendingFullAccessGrant)
    }
    package var isOn: Bool { !disposed && enabled && hasAccess }

    /// Apple's own event editor is used when Calendar access is on. UI tests keep the in-app editor (no permission prompts).
    package var usesNativeEditor: Bool { isOn && !arguments.contains("-uiTesting") }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let runtime: PlannerRuntime
    @ObservationIgnored private let arguments: [String]
    @ObservationIgnored private let makeStore: () -> EKEventStore
    @ObservationIgnored private let readEvents: ((DateInterval) -> [ExternalEvent])?
    @ObservationIgnored private let loadFocus:
      @Sendable ([FocusRecord]) async -> [CalendarFocusImport]
    @ObservationIgnored private let authorizationStatus: () -> EKAuthorizationStatus
    @ObservationIgnored private let requestFullAccess: (() async throws -> Bool)?
    @ObservationIgnored private var pendingFullAccessGrant = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var disposed = false

    package init(
      defaults: UserDefaults, runtime: PlannerRuntime, arguments: [String],
      makeStore: @escaping () -> EKEventStore,
      readEvents: ((DateInterval) -> [ExternalEvent])? = nil,
      loadFocus: @escaping @Sendable ([FocusRecord]) async -> [CalendarFocusImport] = { records in
        await CalendarFocusReader().load(records)
      },
      authorizationStatus: @escaping () -> EKAuthorizationStatus = {
        EKEventStore.authorizationStatus(for: .event)
      },
      requestFullAccess: (() async throws -> Bool)? = nil
    ) {
      self.defaults = defaults
      self.runtime = runtime
      self.arguments = arguments
      self.makeStore = makeStore
      self.readEvents = readEvents
      storeReady = readEvents != nil
      self.loadFocus = loadFocus
      self.authorizationStatus = authorizationStatus
      self.requestFullAccess = requestFullAccess
      enabled =
        defaults.bool(forKey: Self.enabledKey)
        && (!arguments.contains("-uiTesting") || arguments.contains("-uiTestingCalendarSync"))
      hiddenCalendarIDs =
        arguments.contains("-uiTesting")
        ? [] : Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    package func dispose() {
      disposed = true
      pendingFullAccessGrant = false
      observers.forEach(NotificationCenter.default.removeObserver)
      observers.removeAll()
      warmTask?.cancel()
      warmTask = nil
      nativePresenter.dispose()
    }

    /// The store is created just after launch so the first frame never waits for EventKit.
    @ObservationIgnored private var storeReady = false
    @ObservationIgnored private var warming = false
    @ObservationIgnored private var warmTask: Task<Void, Never>?

    /// False while Apple Calendar is on but the store is still warming up (events read now would come back empty).
    package var isReady: Bool { !isOn || storeReady }

    /// Creates the store now: a background refresh has no first frame to protect.
    package func prepareStore() {
      guard isOn, !storeReady else { return }
      _ = store
      storeReady = true
      version += 1
    }

    private func warmUp() {
      guard !warming else { return }
      warming = true
      warmTask = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard let self, !self.disposed else { return }
        _ = self.store
        self.storeReady = true
        self.version += 1
      }
    }

    /// Sets the store up right away. App Intents (Siri, Shortcuts) read events with no UI that would warm it first.
    package func prepare() {
      guard isOn, !storeReady else { return }
      _ = store
      storeReady = true
    }

    /// On the first launch show iOS's own Calendar permission prompt. Does nothing afterwards.
    package func connectIfFirstRun() async {
      guard !arguments.contains("-uiTesting"),
        EKEventStore.authorizationStatus(for: .event) == .notDetermined
      else { return }
      await setEnabled(true)
    }

    /// Turns sync on (asking for access the first time) or off.
    package func setEnabled(_ on: Bool) async {
      guard !disposed else { return }
      if !on { pendingFullAccessGrant = false }
      if on && !hasAccess {
        do {
          let granted: Bool
          if let requestFullAccess {
            granted = try await requestFullAccess()
          } else {
            granted = try await store.requestFullAccessToEvents()
          }
          guard !disposed else { return }
          pendingFullAccessGrant = granted
        } catch {
          pendingFullAccessGrant = false
          log.error("calendar access request failed: \((error as NSError).code, privacy: .public)")
        }
      }
      guard !disposed else { return }
      storeReady = true
      enabled = on && hasAccess
      defaults.set(enabled, forKey: Self.enabledKey)
      version += 1
    }

    /// The store behind every system event, for Apple's own editor and calendar chooser.
    package var eventStore: EKEventStore { store }

    /// Tells views to refetch (after Apple's editor saved or deleted something).
    package func refresh() { version += 1 }

    // MARK: Calendars list

    /// All event calendars in the order Apple lists them: by account, then by name.
    package func calendars() -> [SystemCalendar] {
      _ = version
      guard isOn, storeReady else { return [] }
      return store.calendars(for: .event)
        .sorted { ($0.source?.title ?? "", $0.title) < ($1.source?.title ?? "", $1.title) }
        .map(Self.describe)
    }

    /// Applies the Calendars list: `selected` calendars stay visible, the rest are hidden everywhere.
    package func setVisibleCalendars(_ selected: Set<String>) {
      let all = Set(store.calendars(for: .event).map(\.calendarIdentifier))
      hiddenCalendarIDs = all.subtracting(selected)
      defaults.set(Array(hiddenCalendarIDs), forKey: Self.hiddenKey)
      version += 1
    }

    /// The calendars whose events are shown. nil = all of them.
    private func visibleCalendars() -> [EKCalendar]? {
      guard !hiddenCalendarIDs.isEmpty else { return nil }
      return store.calendars(for: .event).filter {
        !hiddenCalendarIDs.contains($0.calendarIdentifier)
      }
    }

    private static func describe(_ c: EKCalendar) -> SystemCalendar {
      SystemCalendar(
        id: c.calendarIdentifier, title: c.title, sourceTitle: c.source?.title ?? "",
        color: Color(cgColor: c.cgColor),
        isBirthday: c.type == .birthday,
        isHoliday: YearEventMarks.isHolidayCalendar(
          isSubscription: c.type == .subscription, title: c.title),
        allowsContentModifications: c.allowsContentModifications)
    }

    // MARK: Events

    /// System events overlapping `interval`, excluding ones Today created itself (`exclude`).
    package func events(in interval: DateInterval, excluding exclude: Set<String> = [])
      -> [ExternalEvent]
    {
      _ = version
      guard isOn else { return [] }
      // A scalar range source can be injected by an isolated native-view integration fixture.
      if let readEvents {
        return readEvents(interval).filter {
          !exclude.contains($0.eventIdentifier) && !hiddenCalendarIDs.contains($0.calendarID)
        }
      }
      guard storeReady else {
        warmUp()
        return []
      }
      let visible = visibleCalendars()
      if let visible, visible.isEmpty { return [] }
      let predicate = store.predicateForEvents(
        withStart: interval.start, end: interval.end, calendars: visible)
      return store.events(matching: predicate)
        .map { e in
          let value = ExternalEvent(
            id: (e.eventIdentifier ?? UUID().uuidString) + "@\(e.startDate.timeIntervalSince1970)",
            eventIdentifier: e.eventIdentifier ?? "",
            title: e.title ?? "Untitled", location: e.location ?? "",
            start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
            calendarID: e.calendar.calendarIdentifier,
            calendarTitle: e.calendar.title, color: Color(cgColor: e.calendar.cgColor),
            place: Self.place(e), repeats: e.hasRecurrenceRules,
            isBackground: YearLoad.isBackgroundCalendar(
              isSubscription: e.calendar.type == .subscription,
              isBirthday: e.calendar.type == .birthday,
              title: e.calendar.title),
            isBirthday: e.calendar.type == .birthday,
            isHoliday: YearEventMarks.isHolidayCalendar(
              isSubscription: e.calendar.type == .subscription, title: e.calendar.title))
          let identity = e.calendar.source.map {
            FocusIdentity(
              provider: "apple.calendar", account: $0.sourceIdentifier,
              calendar: e.calendar.calendarIdentifier, item: e.calendarItemIdentifier,
              occurrence: e.hasRecurrenceRules || e.isDetached ? e.occurrenceDate : nil)
          }
          acceptFocusSnapshot(
            value, identity: identity, canDelete: e.calendar.allowsContentModifications)
          return value
        }
        .filter { !exclude.contains($0.eventIdentifier) }
    }

    @ObservationIgnored private let rangeReader = CalendarRangeReader()

    /// `events(in:excluding:)` read on a background actor: no travel place and no focus snapshots (the Year view needs
    /// neither). Fixtures and a store that is still warming up take the main-actor path.
    package func loadEvents(in interval: DateInterval, excluding exclude: Set<String>) async
      -> [ExternalEvent]
    {
      guard isOn, readEvents == nil, storeReady else {
        return events(in: interval, excluding: exclude)
      }
      let rows = await rangeReader.events(in: interval, hidden: hiddenCalendarIDs)
      guard isOn else { return [] }
      return rows.filter { !exclude.contains($0.eventIdentifier) }.map { $0.event }
    }

    package func events(on day: Date, excluding exclude: Set<String> = []) -> [ExternalEvent] {
      guard let interval = runtime.calendar.dateInterval(of: .day, for: day) else { return [] }
      return events(in: interval, excluding: exclude)
    }

    /// Called by the root lifecycle, never by a row/body lookup. Only saved exact anchors are read.
    package func hydrateFocus(_ records: [FocusRecord]) async {
      guard isOn, !Task.isCancelled else { return }
      let requestedVersion = version
      let requested = records.filter {
        $0.identity.provider == "apple.calendar"
          && $0.localReference?.hasPrefix("eventkit:") == true
      }
      guard !requested.isEmpty else { return }
      // A resume can discover a removed event without a version notification. Retire old display data first.
      for record in requested {
        guard let ref = record.localReference else { continue }
        let id = String(ref.dropFirst("eventkit:".count))
        focusSnapshots[id]?.removeAll { $0.identity == record.identity }
      }
      focusSnapshotRevision += 1
      let imported = await loadFocus(requested)
      guard !Task.isCancelled, isOn, version == requestedVersion else { return }
      for row in imported {
        guard
          requested.contains(where: {
            $0.identity == row.identity && $0.localReference == "eventkit:" + row.externalID
          }), !hiddenCalendarIDs.contains(row.identity.calendar)
        else { continue }
        acceptFocusSnapshot(row.event, identity: row.identity, canDelete: row.canDelete)
      }
      focusSnapshotRevision += 1
    }

    package private(set) var focusSnapshotRevision = 0

    private struct FocusSnapshot {
      let event: ExternalEvent
      let identity: FocusIdentity?
      let canDelete: Bool
    }
    @ObservationIgnored private var focusSnapshots: [String: [FocusSnapshot]] = [:]
    @ObservationIgnored private var focusSnapshotVersion = -1

    /// Import scalar values on the adapter's actor; never retain or transfer an EKEvent.
    package func acceptFocusSnapshot(
      _ event: ExternalEvent, identity: FocusIdentity?, canDelete: Bool
    ) {
      if focusSnapshotVersion != version {
        focusSnapshots.removeAll()
        focusSnapshotVersion = version
      }
      var rows = focusSnapshots[event.eventIdentifier] ?? []
      rows.removeAll { $0.event.start == event.start }
      rows.append(FocusSnapshot(event: event, identity: identity, canDelete: canDelete))
      focusSnapshots[event.eventIdentifier] = rows
    }

    private func focusSnapshot(_ id: String, occurrence: Date?) -> FocusSnapshot? {
      _ = focusSnapshotRevision
      guard isOn, focusSnapshotVersion == version else { return nil }
      return focusSnapshots[id]?.first {
        if let occurrence {
          return $0.event.start == occurrence || $0.identity?.occurrence == occurrence
        }
        return $0.identity?.occurrence == nil
      }
    }

    package func cachedFocusIdentity(externalID: String?, occurrence: Date?)
      -> FocusIdentityResolution
    {
      _ = version
      guard let id = externalID else { return .localOnly }
      guard hasAccess else { return .permissionDenied }
      guard let identity = focusSnapshot(id, occurrence: occurrence)?.identity else {
        return .unavailable
      }
      return .available(identity)
    }

    package func cachedEvent(externalID: String, occurrence: Date?) -> ExternalEvent? {
      _ = version
      return focusSnapshot(externalID, occurrence: occurrence)?.event
    }

    package func cachedCanDelete(externalID: String?) -> Bool {
      _ = version
      _ = focusSnapshotRevision
      guard let id = externalID else { return true }
      guard isOn, focusSnapshotVersion == version else { return false }
      return focusSnapshots[id]?.contains { $0.canDelete } ?? false
    }

    /// Only immutable identifiers leave the adapter. Source IDs are device-local EventKit sources.
    package func focusIdentity(externalID: String?, occurrence requested: Date?)
      -> FocusIdentityResolution
    {
      guard let id = externalID else { return .localOnly }
      guard hasAccess else { return .permissionDenied }
      guard isOn, storeReady else { return .unavailable }
      let event: EKEvent?
      if let requested {
        if let exact = occurrence(id, at: requested) {
          event = exact
        } else if let candidate = store.event(withIdentifier: id) {
          guard candidate.occurrenceDate == requested || candidate.startDate == requested else {
            return .unavailable
          }
          event = candidate
        } else {
          event = nil
        }
      } else {
        event = store.event(withIdentifier: id)
      }
      guard let event, let source = event.calendar.source else { return .notFound }
      let repeating = event.hasRecurrenceRules || event.isDetached
      guard !repeating || event.occurrenceDate != nil else { return .unavailable }
      return .available(
        FocusIdentity(
          provider: "apple.calendar", account: source.sourceIdentifier,
          calendar: event.calendar.calendarIdentifier, item: event.calendarItemIdentifier,
          occurrence: repeating ? event.occurrenceDate : nil))
    }

    /// The calendar a mirrored event (one Today created) lives in: its color, and whether the Calendars list hides it.
    package func calendar(forExternalID id: String?) -> SystemCalendar? {
      mirror(id)?.calendar
    }

    /// The location of a mirrored event's system copy (Today's own events keep no location), for travel time.
    package func place(forExternalID id: String?) -> TravelPlace? {
      mirror(id)?.place
    }

    private func mirror(_ id: String?) -> MirrorLookup? {
      _ = version
      guard isOn, storeReady, let id else { return nil }
      if mirrorCacheVersion != version {
        mirrorCache = [:]
        mirrorCacheVersion = version
      }
      if let hit = mirrorCache[id] { return hit }
      let ek = store.event(withIdentifier: id)
      let found = MirrorLookup(
        calendar: ek?.calendar.map(Self.describe), place: ek.flatMap(Self.place))
      mirrorCache[id] = found
      return found
    }

    /// An event's address, with the coordinate Apple Calendar stored when the location was picked from Maps.
    package static func place(_ e: EKEvent) -> TravelPlace? {
      let text = (e.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      let geo = e.structuredLocation?.geoLocation?.coordinate
      return TravelPlace(address: text, latitude: geo?.latitude, longitude: geo?.longitude)
    }
    private struct MirrorLookup {
      let calendar: SystemCalendar?
      let place: TravelPlace?
    }
    @ObservationIgnored private var mirrorCache: [String: MirrorLookup] = [:]
    @ObservationIgnored private var mirrorCacheVersion = -1

    /// Color of a mirrored event's calendar, nil when unknown.
    package func color(forExternalID id: String?) -> Color? { calendar(forExternalID: id)?.color }

    /// True when the Calendars list hides the calendar this mirrored event lives in.
    package func isHidden(externalID id: String?) -> Bool {
      guard let c = calendar(forExternalID: id) else { return false }
      return hiddenCalendarIDs.contains(c.id)
    }

    /// A system event and the store it belongs to, for Apple's event viewer.
    /// `occurrence`: the start of the occurrence that was tapped, so a repeating event opens on that day, not its first one.
    package func nativeEvent(identifier: String, occurrence: Date? = nil) -> (
      EKEvent, EKEventStore
    )? {
      guard isOn,
        let e = occurrence.flatMap({ self.occurrence(identifier, at: $0) })
          ?? store.event(withIdentifier: identifier)
      else { return nil }
      return (e, store)
    }

    /// Settings → "New events go to" when that calendar still exists and is writable, else the system default.
    package var newEventLength: TimeInterval {
      TimeInterval(Preferences.newEventMinutes(defaults) * 60)
    }

    package var calendarForNewEvents: EKCalendar? {
      let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
      if let id = Preferences.newEventCalendar(
        writable: writable.map(\.calendarIdentifier), defaults),
        let chosen = writable.first(where: { $0.calendarIdentifier == id })
      {
        return chosen
      }
      return store.defaultCalendarForNewEvents
    }

    package func create(_ event: OneEvent, calendarID: String? = nil) throws
      -> CalendarCreationReceipt
    {
      guard event.externalID == nil else { throw CalendarCreationError.existingEvent }
      // Enabled but denied/disposed must not be reported as a successful local-only creation.
      guard !enabled || isOn else { throw CalendarCreationError.unavailable }
      return try CalendarCreation.commit(
        calendarID: calendarID, connected: isOn,
        resolve: { id in
          if let id { return self.store.calendar(withIdentifier: id) }
          return self.calendarForNewEvents
        },
        writable: { $0.allowsContentModifications },
        save: { calendar in
          let ek = EKEvent(eventStore: self.store)
          ek.calendar = calendar
          ek.title = event.title
          ek.notes = event.note
          ek.location = event.location
          ek.url = event.url.flatMap(URL.init(string:))
          if let busy = event.busy { ek.availability = busy ? .busy : .free }
          if let offset = event.reminderOffsetMinutes {
            ek.addAlarm(EKAlarm(relativeOffset: TimeInterval(-offset * 60)))
          }
          ek.startDate = event.start
          ek.endDate = event.start.addingTimeInterval(event.duration)
          ek.isAllDay = event.isAllDay
          if let rule = event.repeats {
            ek.recurrenceRules = [RemindersSync.recurrence(for: rule)]
          }
          try self.store.save(ek, span: .thisEvent, commit: true)
          self.version += 1
          return ek.eventIdentifier
        })
    }

    /// Saves a copy of `event` to the default calendar and returns its identifier.
    /// `span` is what a repeating event's change applies to; the default keeps the old behavior, AI edits pass `.thisEvent`.
    package func save(_ event: OneEvent, span: EKSpan = .futureEvents) -> String? {
      guard isOn, let calendar = calendarForNewEvents else {
        log.error(
          "save skipped isOn=\(self.isOn) default=\(self.store.defaultCalendarForNewEvents != nil)")
        return nil
      }
      let ek =
        event.externalID.flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
      ek.calendar = ek.calendar ?? calendar
      ek.title = event.title
      if let location = event.location { ek.location = location }
      if let url = event.url { ek.url = URL(string: url) }
      if let busy = event.busy { ek.availability = busy ? .busy : .free }
      ek.startDate = event.start
      ek.endDate = event.start.addingTimeInterval(event.duration)
      ek.isAllDay = event.isAllDay
      if let rule = event.repeats {
        ek.recurrenceRules = [RemindersSync.recurrence(for: rule)]
      } else {
        ek.recurrenceRules = nil
      }
      do {
        try store.save(ek, span: span)
        log.info("saved \(ek.eventIdentifier ?? "nil", privacy: .public)")
        return ek.eventIdentifier
      } catch {
        log.error("save failed \((error as NSError).code, privacy: .public)")
        return nil
      }
    }

    /// Strictly resolves the occurrence; never falls back to another series instance.
    private func moveTarget(id: String, start: Date) -> EKEvent? {
      if let exact = occurrence(id, at: start), exact.startDate == start { return exact }
      guard let event = store.event(withIdentifier: id), event.startDate == start else {
        return nil
      }
      return event
    }

    private func moveSnapshot(_ event: EKEvent) throws -> CalendarMoveSnapshot {
      guard event.calendar.allowsContentModifications else { throw CalendarMoveError.readOnly }
      // Require the two EventKit audience signals to agree; do not infer safety from
      // an inconsistent or incompletely identified participant list.
      let attendees = event.attendees ?? []
      guard event.hasAttendees == !attendees.isEmpty,
        attendees.isEmpty || event.organizer != nil
      else {
        throw CalendarMoveError.audienceUnknownOrUnsafe
      }
      let participantIDs = attendees.map { $0.url.absoluteString }.sorted()
      guard participantIDs.allSatisfy({ !$0.isEmpty }) else {
        throw CalendarMoveError.audienceUnknownOrUnsafe
      }
      guard let id = event.eventIdentifier, let source = event.calendar.source,
        let modified = event.lastModifiedDate, let start = event.startDate, let end = event.endDate,
        end > start
      else { throw CalendarMoveError.unavailable }
      return CalendarMoveSnapshot(
        externalID: id, calendarID: event.calendar.calendarIdentifier,
        sourceID: source.sourceIdentifier, itemID: event.calendarItemIdentifier,
        occurrence: start, start: start, end: end, isAllDay: event.isAllDay,
        lastModified: modified, title: event.title ?? "", location: event.location,
        notes: event.notes, url: event.url?.absoluteString,
        audience: CalendarMoveAudience(
          attendeeCount: attendees.count, isOrganizer: event.organizer?.isCurrentUser),
        participantIDs: participantIDs)
    }

    package func moveSnapshot(externalID: String, occurrence: Date) throws -> CalendarMoveSnapshot {
      guard isOn, hasAccess, storeReady else { throw CalendarMoveError.unavailable }
      guard let event = moveTarget(id: externalID, start: occurrence) else {
        throw CalendarMoveError.notFound
      }
      return try moveSnapshot(event)
    }

    package func moveEvent(
      expected: CalendarMoveSnapshot, to start: Date, acknowledgingAudience: Bool
    ) throws
      -> CalendarMoveOutcome
    {
      guard start.timeIntervalSinceReferenceDate.isFinite else {
        throw CalendarMoveError.invalidTime
      }
      guard isOn, hasAccess, storeReady else { throw CalendarMoveError.unavailable }
      guard let event = moveTarget(id: expected.externalID, start: expected.occurrence) else {
        throw CalendarMoveError.stale
      }
      guard try moveSnapshot(event) == expected else { throw CalendarMoveError.stale }
      guard expected.audience.attendeeCount == 0 || acknowledgingAudience else {
        throw CalendarMoveError.audienceAcknowledgmentRequired
      }
      guard
        let end = CalendarMoveTiming.end(
          newStart: start, oldStart: expected.start, oldEnd: expected.end,
          wasAllDay: expected.isAllDay)
      else { throw CalendarMoveError.invalidTime }
      event.isAllDay = false
      event.startDate = start
      event.endDate = end
      try store.save(event, span: .thisEvent, commit: true)
      version += 1
      // EventKit may detach the instance and replace its identifier. Read back the moved
      // instance, not the old occurrence; ambiguity or incomplete metadata is not success.
      guard let id = event.eventIdentifier,
        let moved = moveTarget(id: id, start: start),
        let after = try? moveSnapshot(moved), after.start == start, after.end == end,
        !after.isAllDay, after.calendarID == expected.calendarID,
        after.sourceID == expected.sourceID, after.audience == expected.audience,
        after.participantIDs == expected.participantIDs, after.title == expected.title,
        after.location == expected.location, after.notes == expected.notes,
        after.url == expected.url
      else {
        return .committedUnverified(
          CalendarMoveUnverified(
            before: expected, requestedStart: start, requestedEnd: end,
            savedExternalID: event.eventIdentifier))
      }
      return .verified(CalendarMoveReceipt(before: expected, after: after))
    }

    package func undoMove(_ receipt: CalendarMoveReceipt, acknowledgingAudience: Bool) throws
      -> CalendarMoveUndoOutcome
    {
      guard isOn, hasAccess, storeReady else { throw CalendarMoveError.unavailable }
      let after = receipt.after
      guard let event = moveTarget(id: after.externalID, start: after.occurrence) else {
        throw CalendarMoveError.stale
      }
      guard try moveSnapshot(event) == after else { throw CalendarMoveError.stale }
      guard after.audience.attendeeCount == 0 || acknowledgingAudience else {
        throw CalendarMoveError.audienceAcknowledgmentRequired
      }
      guard receipt.before.calendarID == after.calendarID,
        receipt.before.sourceID == after.sourceID
      else { throw CalendarMoveError.stale }
      event.isAllDay = receipt.before.isAllDay
      event.startDate = receipt.before.start
      event.endDate = receipt.before.end
      try store.save(event, span: .thisEvent, commit: true)
      version += 1
      guard let id = event.eventIdentifier,
        let restored = moveTarget(id: id, start: receipt.before.start),
        let snapshot = try? moveSnapshot(restored),
        snapshot.start == receipt.before.start, snapshot.end == receipt.before.end,
        snapshot.isAllDay == receipt.before.isAllDay,
        snapshot.calendarID == receipt.before.calendarID,
        snapshot.sourceID == receipt.before.sourceID,
        snapshot.audience == receipt.before.audience,
        snapshot.participantIDs == receipt.before.participantIDs,
        snapshot.title == receipt.before.title, snapshot.location == receipt.before.location,
        snapshot.notes == receipt.before.notes, snapshot.url == receipt.before.url
      else { return .committedUnverified }
      return .verified
    }

    /// Removes the system copy of an event. False when the calendar refused (read-only or subscribed calendars such as
    /// Holidays and Birthdays), so callers can say so instead of acting as if it worked. A copy that is already gone,
    /// or no copy at all, counts as removed.
    /// `occurrence` is the start of the occurrence that was tapped. A repeating event's identifier alone finds its FIRST
    /// occurrence, so without it "Delete This Event Only" removed another day's occurrence and the tapped one stayed
    /// (seen on a real iCloud calendar). With it, that occurrence is removed, and "all future events" start there.
    @discardableResult
    package func delete(externalID: String?, occurrence: Date? = nil, span: EKSpan = .futureEvents)
      -> Bool
    {
      guard let id = externalID else { return true }
      guard isOn, hasAccess, storeReady else { return false }
      let ek: EKEvent?
      if let occurrence {
        if let exact = self.occurrence(id, at: occurrence) {
          ek = exact
        } else if let candidate = store.event(withIdentifier: id) {
          guard candidate.occurrenceDate == occurrence || candidate.startDate == occurrence else {
            return false
          }
          ek = candidate
        } else {
          ek = nil
        }
      } else {
        ek = store.event(withIdentifier: id)
      }
      // A genuinely absent exact ID is already deleted; callers must not offer resurrection Undo.
      guard let ek else { return true }
      return remove(ek, span: span)
    }

    /// The occurrence of event `id` that starts at `start` (within a minute).
    package func occurrence(_ id: String, at start: Date) -> EKEvent? {
      let predicate = store.predicateForEvents(
        withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(60), calendars: nil)
      let found = store.events(matching: predicate)
      return EventMatch.occurrence(
        id, at: start, in: found.map { ($0.eventIdentifier, $0.startDate) }
      ).map { found[$0] }
    }

    /// Explicit deletion uses exact source identity, never the sync mirror's title-matching fallback.
    @discardableResult
    package func delete(_ event: OneEvent, span: EKSpan = .futureEvents) -> Bool {
      delete(externalID: event.externalID, occurrence: event.start, span: span)
    }

    private func remove(_ ek: EKEvent, span: EKSpan) -> Bool {
      log.info(
        "event deletion requested; modifiable=\(ek.calendar.allowsContentModifications) recurring=\(ek.hasRecurrenceRules) thisOccurrence=\(span == .thisEvent)"
      )
      guard ek.calendar.allowsContentModifications else {
        log.error("delete refused: calendar is read-only")
        return false
      }
      let id = ek.eventIdentifier
      do {
        try store.remove(ek, span: span, commit: true)
        let still = id.flatMap { store.event(withIdentifier: $0) } != nil
        log.info("delete: removed, still there=\(still)")
        version += 1
        return true
      } catch {
        log.error("delete failed \((error as NSError).code, privacy: .public)")
        return false
      }
    }

    /// The Apple Calendar copy of an event Today created: by its identifier, or, when sync has re-keyed it, by the same title
    /// starting within a minute of the same time (then the new identifier is saved on the event).
    package func systemCopy(of event: OneEvent) -> EKEvent? {
      guard isOn, let id = event.externalID else { return nil }
      if let ek = store.event(withIdentifier: id) { return ek }
      let predicate = store.predicateForEvents(
        withStart: event.start.addingTimeInterval(-60),
        end: event.start.addingTimeInterval(max(120, event.duration)), calendars: nil)
      let found = store.events(matching: predicate)
      guard
        let i = EventMatch.copy(
          titled: event.title, at: event.start, in: found.map { ($0.title, $0.startDate) })
      else { return nil }
      let match = found[i]
      log.info("event relinked after identifier changed")
      event.externalID = match.eventIdentifier
      return match
    }

    /// Whether the system copy of an event can be deleted (its calendar accepts changes). True when there is no system copy.
    package func canDelete(externalID: String?) -> Bool {
      guard let id = externalID else { return true }
      guard isOn, hasAccess, storeReady else { return false }
      guard let ek = store.event(withIdentifier: id) else { return true }
      return ek.calendar.allowsContentModifications
    }

    /// Events Today created whose copy in Apple Calendar is gone (deleted there). Apple Calendar is the source of truth, so
    /// the local copy goes too. Empty unless Calendar sync is on and its store is ready, so a missing permission never counts as a delete.
    package func removedMirrors(_ events: [OneEvent]) -> [OneEvent] {
      guard isOn, storeReady else { return [] }
      // A copy found again under a new identifier is relinked, not dropped (see `systemCopy(of:)`).
      return events.filter { e in e.externalID != nil && systemCopy(of: e) == nil }
    }

    #if DEBUG
      /// UI-test hook (`-debugDeleteSystemEvent <title>`): deletes system events with this title, as if they had been deleted
      /// in the Calendar app. Also the cleanup for the events the create hooks below make: a whole series goes, even one
      /// that started days ago (its earliest occurrence is removed with all future events).
      package func debugDeleteSystemEvents(titled title: String) {
        guard isOn else { return }
        storeReady = true
        let predicate = store.predicateForEvents(
          withStart: runtime.now().addingTimeInterval(-30 * 86_400),
          end: runtime.now().addingTimeInterval(30 * 86_400), calendars: nil)
        for e in store.events(matching: predicate).filter({ $0.title == title }).sorted(by: {
          $0.startDate < $1.startDate
        }) {
          try? store.remove(e, span: .futureEvents)
        }
        version += 1
      }

      /// UI-test hooks (`-debugCreateSystemEvent <title>`, `-debugCreateRepeatingEvent <title>`): an event made in the Calendar
      /// app, not by Today, in the default calendar. It starts at the top of the current hour (next to the Today list's now
      /// line, and still today at 23:59); the repeating one is daily and starts yesterday, so it has a past occurrence,
      /// today's and tomorrow's.
      package func debugCreateSystemEvent(titled title: String, repeating: Bool) {
        guard isOn, let calendar = store.defaultCalendarForNewEvents else { return }
        storeReady = true
        let cal = runtime.calendar
        let hour = cal.dateInterval(of: .hour, for: runtime.now())?.start ?? runtime.now()
        let e = EKEvent(eventStore: store)
        e.calendar = calendar
        e.title = title
        e.startDate = repeating ? cal.date(byAdding: .day, value: -1, to: hour) ?? hour : hour
        e.endDate = e.startDate.addingTimeInterval(1800)
        if arguments.contains("-uiTestingCalendarSaveAllDay") {
          // Convert the existing same-day timed interval using EventKit. Setting
          // the end again after allDay rounded the fixture into a second day.
          e.isAllDay = true
        }
        if repeating {
          e.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]
        }
        do { try store.save(e, span: .futureEvents) } catch {
          log.error("debug create failed \((error as NSError).code, privacy: .public)")
        }
        version += 1
      }
    #endif

    /// Whether the system copy of an event repeats (Delete then asks: this event or the series).
    package func isRepeating(externalID: String?) -> Bool {
      guard isOn, let id = externalID, let ek = store.event(withIdentifier: id) else {
        return false
      }
      return ek.hasRecurrenceRules
    }

    /// Who a change to the system copy of an event reaches: attendee count and whether you organize it. Nil without a system copy.
    package func audience(externalID: String?) -> (attendees: Int, isOrganizer: Bool)? {
      guard isOn, storeReady, let id = externalID, let ek = store.event(withIdentifier: id) else {
        return nil
      }
      return (ek.attendees?.count ?? 0, ek.organizer?.isCurrentUser ?? true)
    }
    @ObservationIgnored private lazy var nativePresenter = NativeEvents(sync: self)

    package func edit(
      identifier: String?, start: Date, end: Date?,
      onComplete: ((EKEventEditViewAction) -> Void)?
    ) {
      nativePresenter.edit(identifier: identifier, start: start, end: end, onComplete: onComplete)
    }

    package func title(externalID: String, occurrence: Date?) -> String? {
      nativeEvent(identifier: externalID, occurrence: occurrence)?.0.title
    }

    package func rename(externalID: String, occurrence: Date?, to title: String) -> Bool {
      guard let (event, store) = nativeEvent(identifier: externalID, occurrence: occurrence),
        event.calendar.allowsContentModifications
      else { return false }
      let old = event.title
      event.title = title
      do {
        try store.save(event, span: .thisEvent)
        refresh()
        return true
      } catch {
        event.title = old
        return false
      }
    }

    package func setOptions(
      externalID: String, occurrence: Date?, calendarID: String?, alertMinutes: Int?
    ) -> String? {
      guard let (event, store) = nativeEvent(identifier: externalID, occurrence: occurrence),
        event.calendar.allowsContentModifications
      else { return nil }
      if let calendarID, calendarID != event.calendar.calendarIdentifier {
        // An invitation stays in its account: moving it would cancel and re-invite everyone.
        guard !event.hasAttendees, let target = store.calendar(withIdentifier: calendarID),
          target.allowsContentModifications
        else { return nil }
        event.calendar = target
      }
      event.alarms = alertMinutes.map { [EKAlarm(relativeOffset: TimeInterval(-$0 * 60))] } ?? []
      do {
        try store.save(event, span: event.hasRecurrenceRules ? .futureEvents : .thisEvent)
        refresh()
        return event.eventIdentifier
      } catch {
        event.reset()
        log.error("set options failed \((error as NSError).code, privacy: .public)")
        return nil
      }
    }

  }

  /// Shows Apple's event editor the way UIKit expects: presented over the top screen, not embedded in a SwiftUI sheet.
  /// Embedded, its Delete Event confirmation closed without deleting anything (reproduced in the simulator), and a sheet
  /// attached to each row of a long list could open the wrong event. One presenter for every place that opens it.
  @MainActor
  package final class NativeEvents {
    private unowned let sync: CalendarSync
    private var watchTask: Task<Void, Never>?
    package init(sync: CalendarSync) { self.sync = sync }
    package func dispose() {
      watchTask?.cancel()
      watchTask = nil
      retainedCoordinator = nil
    }
    // Retained because EventKitUI holds its delegate weakly; Delegate holds this owner weakly.
    private var retainedCoordinator: Delegate?
    private let log = Logger(subsystem: "com.luworks.today", category: "calendar")

    /// `identifier` nil = a new event starting at `start`.
    /// `start`: for an existing event, the start of the occurrence that was tapped; for a new event, when it starts.
    /// `end`: for a new event, when it ends (default: Settings → "New event length" after `start`).
    /// Every event, new or existing, opens in Apple's own Edit Event: it has every field Apple Calendar has (calendar,
    /// alerts, travel time, invitees, attachments), several of which EventKit gives no API to write.
    /// Like Apple Calendar, its checkmark stays grey until something changes; X closes an unchanged event.
    package func edit(
      identifier: String?, start: Date, end: Date?,
      onComplete: ((EKEventEditViewAction) -> Void)?
    ) {
      let vc = EKEventEditViewController()
      vc.eventStore = sync.eventStore
      if let identifier {
        guard let (existing, _) = sync.nativeEvent(identifier: identifier, occurrence: start) else {
          log.error("edit: event not found")
          return
        }
        vc.event = existing
      } else {
        let event = EKEvent(eventStore: sync.eventStore)
        event.startDate = start
        event.endDate = end ?? start.addingTimeInterval(sync.newEventLength)
        event.calendar = sync.calendarForNewEvents
        vc.event = event
      }
      let d = Delegate(owner: self, onComplete: onComplete)
      retainedCoordinator = d
      vc.editViewDelegate = d
      vc.presentationController?.delegate = d
      guard let top = Self.topViewController() else { return }
      top.present(vc, animated: true)
      if let identifier { watch(vc, identifier: identifier, occurrence: start) }
    }

    /// iOS 27's editor deletes the event but may not call its delegate, so it stays on screen and the list keeps the row,
    /// which looks like the delete failed (reproduced in the simulator: the event was gone from the calendar database).
    /// While the editor is up, check whether the event still exists; once it is gone, close the editor and refresh.
    private func watch(_ vc: EKEventEditViewController, identifier: String, occurrence: Date) {
      watchTask?.cancel()
      watchTask = Task { @MainActor [weak self, weak vc] in
        guard let self else { return }
        while let vc, vc.presentingViewController != nil {
          do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
          guard !Task.isCancelled else { return }
          // Gone: the whole event, or (a repeating one) just the occurrence that was open.
          if self.sync.eventStore.event(withIdentifier: identifier) == nil
            || self.sync.occurrence(identifier, at: occurrence) == nil
          {
            log.info("editor: event is gone, closing")
            self.sync.refresh()
            let completion = self.retainedCoordinator?.onComplete
            vc.dismiss(animated: true) { completion?(.deleted) }
            self.retainedCoordinator = nil
            return
          }
        }
        self.sync.refresh()
      }
    }

    private static func topViewController() -> UIViewController? {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
      var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
      while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
      return top
    }

    private final class Delegate: NSObject, @MainActor EKEventEditViewDelegate,
      UIAdaptivePresentationControllerDelegate
    {
      let onComplete: ((EKEventEditViewAction) -> Void)?
      weak var owner: NativeEvents?
      init(owner: NativeEvents, onComplete: ((EKEventEditViewAction) -> Void)?) {
        self.owner = owner
        self.onComplete = onComplete
      }
      /// Swiped down: nothing to save; refetch in case something changed meanwhile.
      func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        Task { @MainActor in
          self.owner?.sync.refresh()
          self.owner?.retainedCoordinator = nil
        }
      }

      package func eventEditViewController(
        _ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction
      ) {
        print("NativeEvents: editor completed \(action.rawValue)")
        self.owner?.log.info(
          "apple editor done: \(action == .deleted ? "deleted" : action == .saved ? "saved" : "cancelled", privacy: .public)"
        )
        Task { @MainActor in
          self.owner?.sync.refresh()
          controller.dismiss(animated: true) { self.onComplete?(action) }
          self.owner?.retainedCoordinator = nil
        }
      }
    }
  }

  /// Opening a system event goes straight to Apple's editor (EventKitUI): title, start and end, all-day, calendar, alerts and
  /// Delete Event are all editable at once, Done saves. Apple's read-only viewer made you tap Edit first and drew its own
  /// Delete, so it is not used.
  package struct NativeEventSheet: View {
    package init(identifier: String, start: Date, calendar: any NativeCalendarService) {
      self.identifier = identifier
      self.start = start
      self.calendar = calendar
    }
    private let start: Date
    private let calendar: any NativeCalendarService
    package let identifier: String

    package var body: some View {
      NativeEventEditor(identifier: identifier, start: start, calendar: calendar).ignoresSafeArea()
    }
  }

  /// Apple's own event editor (EventKitUI), for a new event or an existing one. Saving, cancelling and deleting
  /// (with Apple's "This event only / all future events" prompts) are all Apple's.
  package struct NativeEventEditor: UIViewControllerRepresentable {
    package init(identifier: String?, start: Date, calendar: any NativeCalendarService) {
      self.identifier = identifier
      self.start = start
      self.calendar = calendar
    }
    private let calendar: any NativeCalendarService
    /// nil = a new event.
    package var identifier: String?
    /// Where a new event starts (ignored when editing).
    package var start: Date
    @Environment(\.dismiss) private var dismiss

    package func makeUIViewController(context: Context) -> EKEventEditViewController {
      let sync = calendar
      let vc = EKEventEditViewController()
      vc.eventStore = sync.eventStore
      if let identifier,
        let (existing, _) = sync.nativeEvent(identifier: identifier, occurrence: start)
      {
        vc.event = existing
      } else {
        let event = EKEvent(eventStore: sync.eventStore)
        event.startDate = start
        event.endDate = start.addingTimeInterval(sync.newEventLength)
        event.calendar = sync.calendarForNewEvents
        vc.event = event
      }
      vc.editViewDelegate = context.coordinator
      return vc
    }

    package func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {
    }

    package func makeCoordinator() -> Coordinator {
      Coordinator(calendar: calendar, dismiss: { dismiss() })
    }

    @MainActor
    // EventKitUI invokes editor delegates on the UI thread; its SDK protocol lacks actor annotations.
    package final class Coordinator: NSObject, @preconcurrency EKEventEditViewDelegate {
      let calendar: any CalendarService
      let dismiss: () -> Void
      init(calendar: any CalendarService, dismiss: @escaping () -> Void) {
        self.calendar = calendar
        self.dismiss = dismiss
      }
      package func eventEditViewController(
        _ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction
      ) {
        Logger(subsystem: "com.luworks.today", category: "calendar").info(
          "apple editor done: \(action == .deleted ? "deleted" : action == .saved ? "saved" : "cancelled", privacy: .public)"
        )
        calendar.refresh()
        dismiss()
      }
    }
  }

#endif
