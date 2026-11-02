#if os(iOS)
  import TodayCore
  import TodayShared
  import CoreLocation
  import MapKit
  import Observation
  import UIKit
  import os

  /// Travel time to upcoming events with a location ("Drive 18 min · Leave by 14:20"), like Apple Calendar's Time to Leave.
  ///
  /// Rows ask `seconds(...)` while they draw: it answers from the cache right away (never blocks the list) and, when the
  /// estimate is missing or 15 minutes old, queues a MapKit lookup in the background. Only Apple's MapKit is contacted
  /// (address search when the event has no coordinate, then an ETA from the current location); nothing else leaves the device.
  /// Rules (who is eligible, keys, refresh, leave-by) live in `Shared/TravelTime.swift` and are unit-tested.
  @MainActor
  @Observable
  package final class TravelTimes: NSObject, CLLocationManagerDelegate, TravelTimeProviding {
    /// Composition receives completed estimates without a dependency on the persistence/widget layer.
    @ObservationIgnored package var didUpdateEstimate: (@MainActor () -> Void)?

    /// Bumped when an estimate lands or location permission changes, so rows redraw.
    package private(set) var version = 0

    @ObservationIgnored private let log = Logger(subsystem: "com.luworks.today", category: "travel")
    @ObservationIgnored private var cache: [String: TravelEstimate] = [:]
    @ObservationIgnored private var queued: [String: Job] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Address → resolved place for this launch (several events at the same address need one search).
    @ObservationIgnored private var askedThisLaunch = false
    @ObservationIgnored private var requestedFix = false
    @ObservationIgnored private var resolved: [String: MKMapItem] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let runtime: PlannerRuntime
    @ObservationIgnored private var disposed = false
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var permissionRequests: Set<String> = []
    @ObservationIgnored private var requestIDs: [String: UUID] = [:]
    @ObservationIgnored private var deferred: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var searches: [String: MKLocalSearch] = [:]
    @ObservationIgnored private var directions: [String: MKDirections] = [:]
    @ObservationIgnored private var locationManager: CLLocationManager?

    private var manager: CLLocationManager {
      if let locationManager { return locationManager }
      let m = CLLocationManager()
      m.delegate = self
      locationManager = m
      return m
    }

    private struct Job {
      let key: String
      let place: TravelPlace
      let start: Date
    }

    private static let cacheKey = "today.travel.cache"

    /// The Settings toggle (on unless turned off).
    package var isEnabled: Bool { defaults.object(forKey: SettingsKey.travelTime) as? Bool ?? true }

    package init(defaults: UserDefaults, runtime: PlannerRuntime) {
      self.defaults = defaults
      self.runtime = runtime
      super.init()
      if let data = defaults.data(forKey: Self.cacheKey),
        let saved = try? JSONDecoder().decode([String: TravelEstimate].self, from: data)
      {
        cache = TravelTime.pruned(saved, now: runtime.now(), calendar: runtime.calendar)
      }
    }

    // MARK: Reading

    /// Travel seconds worth showing for this occurrence, or nil. Never waits: a lookup it needs runs in the background.
    /// `askPermission`: false from background work (no prompt can show there).
    package func seconds(
      eventID: String, start: Date, isAllDay: Bool, place: TravelPlace?, now: Date,
      askPermission: Bool = true
    ) -> TimeInterval? {
      _ = version
      guard !disposed, isEnabled, let place, !eventID.isEmpty,
        TravelTime.isEligible(
          start: start, isAllDay: isAllDay, location: place.address, now: now,
          calendar: runtime.calendar)
      else { return nil }
      // Location refused: no estimate can be made, so don't queue anything.
      guard status != .denied, status != .restricted else { return nil }
      let key = TravelTime.cacheKey(
        eventID: eventID, start: start, address: place.address, calendar: runtime.calendar)
      let cached = cache[key]
      if TravelTime.needsRefresh(cached, now: now), !inFlight.contains(key) {
        // Deferred: rows call this while drawing, and starting work (or a prompt) must wait until that's done.
        let job = Job(key: key, place: place, start: start)
        if askPermission { permissionRequests.insert(key) }
        if deferred[key] == nil {
          deferred[key] = Task { @MainActor [weak self] in
            guard let self, !self.disposed, !Task.isCancelled else { return }
            self.deferred.removeValue(forKey: key)
            self.enqueue(job, askPermission: self.permissionRequests.remove(key) != nil)
          }
        }
      }
      return TravelTime.usable(cached)
    }

    // MARK: Lookups

    private var status: CLAuthorizationStatus { manager.authorizationStatus }
    private var isAuthorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    private func enqueue(_ job: Job, askPermission: Bool) {
      guard !disposed, isEnabled else { return }
      if status == .notDetermined {
        // Asked the first time an event with a location is upcoming; iOS shows the prompt once and remembers the answer.
        if askPermission, !askedThisLaunch,
          TravelTime.shouldAskPermission(
            notDetermined: true, enabled: isEnabled, hasEligibleEvent: true)
        {
          askedThisLaunch = true
          manager.requestWhenInUseAuthorization()
        }
        return  // the answer bumps `version`, rows redraw and ask again
      }
      guard isAuthorized, !inFlight.contains(job.key) else { return }
      if !requestedFix {
        // One location fix per launch, so address searches look near you (not in another city with the same street).
        requestedFix = true
        manager.requestLocation()
      }
      if queued[job.key] == nil { queued[job.key] = job }
      pump()
    }

    /// Starts the soonest queued lookups, a few at a time (MapKit throttles bursts). Only while the app is open:
    /// with "when in use" permission a background refresh has no current location, and a failed lookup would be
    /// cached for 15 minutes. Queued jobs start the next time a row asks in the foreground.
    private func pump() {
      guard !disposed, isEnabled, UIApplication.shared.applicationState == .active else { return }
      let next = TravelTime.nextRequests(
        queued.values.map { (id: $0.key, start: $0.start) }, inFlight: inFlight.count)
      for key in next {
        guard let job = queued.removeValue(forKey: key) else { continue }
        inFlight.insert(key)
        let requestID = UUID()
        requestIDs[key] = requestID
        tasks[key] = Task { @MainActor [weak self] in
          guard let self, !self.disposed, !Task.isCancelled,
            self.requestIDs[key] == requestID
          else { return }
          let seconds = await self.eta(to: job.place, arrivingBy: job.start, key: key)
          guard !Task.isCancelled, !self.disposed, self.requestIDs[key] == requestID else { return }
          self.requestIDs.removeValue(forKey: key)
          self.tasks.removeValue(forKey: key)
          self.inFlight.remove(key)
          guard self.isEnabled, self.isAuthorized else {
            self.pump()
            return
          }
          self.cache[key] = TravelEstimate(seconds: seconds, computedAt: self.runtime.now())
          self.save()
          self.version += 1
          self.didUpdateEstimate?()
          self.pump()
        }
      }
    }

    /// Driving time from the current location, for arriving by `start`. Nil when the place or a route can't be found.
    private func eta(to place: TravelPlace, arrivingBy start: Date, key: String) async
      -> TimeInterval?
    {
      guard let destination = await mapItem(for: place, key: key) else { return nil }
      guard !disposed, !Task.isCancelled else { return nil }
      let request = MKDirections.Request()
      request.source = MKMapItem.forCurrentLocation()
      request.destination = destination
      request.transportType = .automobile
      if start > runtime.now() { request.arrivalDate = start }
      let direction = MKDirections(request: request)
      directions[key] = direction
      defer { if directions[key] === direction { directions.removeValue(forKey: key) } }
      do {
        let response = try await direction.calculateETA()
        guard !disposed, !Task.isCancelled, directions[key] === direction else { return nil }
        return response.expectedTravelTime
      } catch {
        guard !disposed, !Task.isCancelled else { return nil }
        log.info("ETA failed: \((error as NSError).code, privacy: .public)")
        return nil
      }
    }

    /// The event's place: Apple Calendar's coordinate when it has one (no search), else an address search near you.
    private func mapItem(for place: TravelPlace, key: String) async -> MKMapItem? {
      guard !disposed, !Task.isCancelled else { return nil }
      if let lat = place.latitude, let lon = place.longitude {
        return MKMapItem(location: CLLocation(latitude: lat, longitude: lon), address: nil)
      }
      let address = place.address.trimmingCharacters(in: .whitespacesAndNewlines)
      if let hit = resolved[address] { return hit }
      let request = MKLocalSearch.Request()
      request.naturalLanguageQuery = address
      request.resultTypes = [.address, .pointOfInterest]
      if let here = manager.location?.coordinate {
        request.region = MKCoordinateRegion(
          center: here, latitudinalMeters: 100_000, longitudinalMeters: 100_000)
      }
      guard !disposed, !Task.isCancelled else { return nil }
      let search = MKLocalSearch(request: request)
      searches[key] = search
      defer { if searches[key] === search { searches.removeValue(forKey: key) } }
      do {
        let item = try await search.start().mapItems.first
        guard !disposed, !Task.isCancelled, searches[key] === search else { return nil }
        if let item { resolved[address] = item }
        return item
      } catch {
        guard !disposed, !Task.isCancelled else { return nil }
        log.info("Address search failed: \((error as NSError).code, privacy: .public)")
        return nil
      }
    }

    private func save() {
      cache = TravelTime.pruned(cache, now: runtime.now(), calendar: runtime.calendar)
      if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Self.cacheKey) }
    }

    /// Terminal teardown: only this adapter's requests and callback are cancelled.
    package func dispose() {
      guard !disposed else { return }
      disposed = true
      didUpdateEstimate = nil
      for task in deferred.values { task.cancel() }
      for task in tasks.values { task.cancel() }
      for search in searches.values { search.cancel() }
      for direction in directions.values { direction.cancel() }
      permissionRequests.removeAll()
      requestIDs.removeAll()
      deferred.removeAll()
      tasks.removeAll()
      searches.removeAll()
      directions.removeAll()
      queued.removeAll()
      inFlight.removeAll()
      locationManager?.delegate = nil
      locationManager?.stopUpdatingLocation()
      locationManager = nil
    }

    // MARK: CLLocationManagerDelegate

    package nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
      let source = ObjectIdentifier(manager)
      Task { @MainActor [weak self] in
        guard let self, !self.disposed, let current = self.locationManager,
          ObjectIdentifier(current) == source
        else { return }
        self.version += 1
      }
    }

    /// The fix lands in `manager.location`, which address searches read; nothing else to do.
    package nonisolated func locationManager(
      _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {}

    /// Required with `requestLocation()`. Without a fix, searches just aren't biased toward you.
    package nonisolated func locationManager(
      _ manager: CLLocationManager, didFailWithError error: Error
    ) {}
  }

  extension TravelTimes {
    /// The row line for an occurrence ("Drive 18 min · Leave by 14:20"), or nil.
    package func label(eventID: String, start: Date, isAllDay: Bool, place: TravelPlace?, now: Date)
      -> String?
    {
      guard
        let s = seconds(eventID: eventID, start: start, isAllDay: isAllDay, place: place, now: now)
      else { return nil }
      let formatter = DateFormatter()
      formatter.locale = runtime.locale
      formatter.calendar = runtime.calendar
      formatter.timeZone = runtime.calendar.timeZone
      formatter.dateStyle = .none
      formatter.timeStyle = .short
      return TravelTime.label(start: start, travelSeconds: s, now: now) {
        formatter.string(from: $0)
      }
    }

    /// Travel fields for the widget snapshot (no permission prompt from here).
    package func widgetFields(
      eventID: String, start: Date, isAllDay: Bool, place: TravelPlace?, now: Date
    ) -> (minutes: Int, leaveBy: Date)? {
      guard
        let s = seconds(
          eventID: eventID, start: start, isAllDay: isAllDay, place: place, now: now,
          askPermission: false)
      else { return nil }
      return (TravelTime.minutes(s), TravelTime.leaveBy(start: start, travelSeconds: s))
    }
  }

#endif
