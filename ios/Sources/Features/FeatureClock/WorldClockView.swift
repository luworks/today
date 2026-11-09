#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem
  import TodayPlatform

  extension Color {
    fileprivate init(_ rgb: WorldClock.RGB) {
      self.init(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255)
    }
  }

  /// The saved World Clock cities (city keys, in the user's order), kept in UserDefaults. Old installs saved time zone
  /// identifiers; they are converted to cities when loaded (`CityDatabase.migrate`). The home city (the device's time
  /// zone, mapped to a named city) is not stored: it is always shown first. Root composition retains the store when leaving the tab.
  /// Development composition supplies explicit initial keys and a home zone or city.
  @MainActor
  @Observable
  public final class WorldClockStore {
    public static let defaultsKey = "today.worldClock.cities"

    public private(set) var keys: [String]
    /// The overlap graph is open instead of the cards (not saved: World Clock opens on the cards).
    public var showsGraph = false
    public let database: CityDatabase
    private let defaults: UserDefaults
    private let homeZoneIdentifier: String
    /// An explicitly injected home city.
    private var homeOverride: CityRecord?

    public init(
      database: CityDatabase, defaults: UserDefaults,
      homeZoneIdentifier: String, homeCity: CityRecord? = nil,
      initialKeys: [String]? = nil
    ) {
      self.database = database
      self.defaults = defaults
      self.homeOverride = homeCity
      self.homeZoneIdentifier = homeZoneIdentifier
      let stored = initialKeys ?? defaults.stringArray(forKey: Self.defaultsKey)
      keys = database.migrate(stored)
      if initialKeys == nil, keys != (stored ?? []) { defaults.set(keys, forKey: Self.defaultsKey) }
    }

    /// The starred first card: the city that stands for the device's time zone.
    public var home: CityRecord {
      homeOverride ?? database.city(forTimeZone: homeZoneIdentifier)
        ?? CityRecord(id: 0, name: homeZoneIdentifier, tz: homeZoneIdentifier)
    }

    /// The cities after home, in the user's order.
    public var others: [CityRecord] {
      WorldClock.others(keys, home: home.key).compactMap { database.city(forKey: $0) }
    }

    /// The week start chosen in Settings, for the date sheet.
    var firstWeekday: Preferences.FirstWeekday { Preferences.firstWeekdayChoice(defaults) }

    public func contains(_ city: CityRecord) -> Bool {
      city.key == home.key || keys.contains(city.key)
    }

    public func add(_ city: CityRecord) { set(WorldClock.adding(city.key, to: keys)) }

    public func remove(_ city: CityRecord) { set(keys.filter { $0 != city.key }) }

    public func insert(_ city: CityRecord, at index: Int) {
      guard !keys.contains(city.key) else { return }
      var list = others.map(\.key)
      list.insert(city.key, at: min(max(0, index), list.count))
      set(list)
    }

    /// Reorders the cities after home (`others` indices, as `List.onMove` gives them).
    public func move(from source: IndexSet, to destination: Int) {
      set(WorldClock.moving(others.map(\.key), from: source, to: destination))
    }

    private func set(_ list: [String]) {
      keys = list
      defaults.set(list, forKey: Self.defaultsKey)
    }
  }

  /// World Clock, a copy of the look and the gestures of the app "Overlap" (see docs/design/world-clock.md): one card per
  /// city, colored by the time of day there (green inside good hours, 9:00 to 18:00), home first with a star. Drag sideways
  /// anywhere to move every clock together: a slow drag is exact, a fast one covers hours and coasts on (`WorldClock.Scrub`).
  /// The pill at the bottom says how far ("15 HOURS BEFORE NOW", "NOW") and a tap on it goes back to now. The calendar at
  /// the left of the pill jumps to a date; the bell curve at the right swaps the cards for the overlap graph.
  /// No Edit button: a long press on a city offers Move Up / Move Down and Delete, press, hold and drag reorders
  /// (the sideways swipe belongs to scrubbing). + adds a city.
  public struct WorldClockView: View {
    @Environment(\.locale) private var locale
    private let now: () -> Date
    private let showUndo: (String, @escaping () -> Void) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var store: WorldClockStore
    @State private var scrub = ScrubDriver()
    @State private var texts = WorldClock.CardTexts()
    @State private var showsDatePicker = false

    /// The app supplies its existing Undo toast; Workbench can capture and exercise the same undo action.
    public init(
      store: WorldClockStore, now: @escaping () -> Date,
      showUndo: @escaping (String, @escaping () -> Void) -> Void
    ) {
      _store = State(initialValue: store)
      self.now = now
      self.showUndo = showUndo
    }

    private var db: CityDatabase { store.database }

    public var body: some View {
      TimelineView(.everyMinute) { _ in
        let now = self.now()
        let date = WorldClock.Scrub.date(now: now, offset: scrub.offset)
        let home = store.home
        let others = store.others
        let graph = store.showsGraph
        ZStack {
          (colorScheme == .dark ? Color.black : Color(.systemBackground)).ignoresSafeArea()
          if graph {
            WaveBackground(
              waves: WorldClock.waves(zones: ([home] + others).compactMap(\.timeZone), start: date)
            )
            .ignoresSafeArea(edges: .bottom)
            .transition(.opacity)
          }
          List {
            CityCard(
              city: home, home: home, date: date, isHome: true, flat: graph, moving: scrub.isFast,
              db: db,
              texts: texts
            )
            .moveDisabled(true)
            .deleteDisabled(true)
            // A sideways drag scrubs time, so there is no swipe-to-delete here: Delete and the order are in the
            // long-press menu, and a press, hold and drag reorders.
            ForEach(others) { city in
              CityCard(
                city: city, home: home, date: date, isHome: false, flat: graph,
                moving: scrub.isFast,
                db: db, texts: texts
              )
              .contextMenu { cityMenu(city) }
              .deleteDisabled(true)
            }
            .onMove { store.move(from: $0, to: $1) }
            if others.isEmpty && !graph { hint }
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
          .environment(\.defaultMinListRowHeight, 0)
          .contentMargins(.top, 6, for: .scrollContent)
          .gesture(
            HorizontalPan(
              onTouchDown: scrub.touchDown, onChange: scrub.dragged, onEnd: scrub.released)
          )
          .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomArea(home: home, others: others, date: date, graph: graph, now: now)
          }
        }
        .animation(.snappy, value: graph)
        .onDisappear { scrub.touchDown() }
      }
    }

    private func returnToNow() {
      withAnimation(.snappy) { scrub.jump(to: 0) }
    }

    // MARK: Bottom: sentence, pill, calendar and graph buttons

    private func bottomArea(
      home: CityRecord, others: [CityRecord], date: Date, graph: Bool, now: Date
    ) -> some View {
      VStack(spacing: 14) {
        if graph { overlapSentence(home: home, others: others, date: date) }
        HStack(spacing: 8) {
          calendarButton
          Spacer(minLength: 0)
          scrubPill
          Spacer(minLength: 0)
          graphButton(graph)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 10)
      .sheet(isPresented: $showsDatePicker) {
        ScrubDateSheet(
          home: home.timeZone ?? TimeZone(secondsFromGMT: 0)!, firstWeekday: store.firstWeekday,
          shown: date, range: WorldClock.Scrub.pickableRange(now: now), isAtNow: scrub.offset == 0,
          pick: { day, calendar in
            let offset = WorldClock.Scrub.offset(
              picking: day, shown: date, now: now, calendar: calendar)
            withAnimation(.snappy) { scrub.jump(to: offset) }
            showsDatePicker = false
          },
          returnToNow: {
            returnToNow()
            showsDatePicker = false
          })
      }
    }

    private var calendarButton: some View {
      Button {
        scrub.touchDown()
        showsDatePicker = true
      } label: {
        Image(systemName: "calendar")
          .font(.system(size: 21, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Choose a date")
      .accessibilityIdentifier("worldClock.calendar")
    }

    private var scrubPill: some View {
      let parts = WorldClock.Scrub.pillParts(scrub.offset)
      var text = AttributedString(parts.lead)
      text.font = .system(size: 15, weight: .regular)
      var keyword = AttributedString(parts.keyword)
      keyword.font = .system(size: 15, weight: .bold)
      text.append(keyword)
      return Button(action: returnToNow) {
        Text(text)
          .tracking(0.2)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .foregroundStyle(.white)
          .contentTransition(.numericText())
          .padding(.horizontal, 18)
          .frame(height: 36)
          .background(Capsule().fill(Color(WorldClock.Look.pill)))
      }
      .buttonStyle(PressScale())
      .accessibilityLabel(WorldClock.Scrub.pillText(scrub.offset))
      .accessibilityHint(
        scrub.offset == 0 ? "Drag sideways on the cities to see other times." : "Goes back to now."
      )
      .accessibilityIdentifier("worldClock.scrub")
    }

    private func graphButton(_ on: Bool) -> some View {
      Button {
        withAnimation(.snappy) { store.showsGraph.toggle() }
      } label: {
        BellCurve()
          .stroke(style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
          .frame(width: 26, height: 16)
          .foregroundStyle(on ? Color(WorldClock.Look.green) : Color.secondary)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(on ? "Show cities" : "Show overlap graph")
      .accessibilityIdentifier("worldClock.graph")
    }

    private func overlapSentence(home: CityRecord, others: [CityRecord], date: Date) -> some View {
      let hm = WorldClock.hourMinute(zone: home.timeZone ?? TimeZone(secondsFromGMT: 0)!, at: date)
      let parts = texts.timeParts(hour: hm.hour, minute: hm.minute, locale: locale)
      let segments = WorldClock.overlapSegments(
        cities: others.map { db.displayName($0, locale: locale) },
        home: db.displayName(home, locale: locale),
        time: parts.time + (parts.suffix.map { " " + $0 } ?? ""), offset: scrub.offset)
      var text = AttributedString()
      for s in segments {
        var run = AttributedString(s.text)
        run.font = .system(size: 24, weight: s.bold ? .bold : .light)
        text.append(run)
      }
      return Text(text)
        .multilineTextAlignment(.center)
        .foregroundStyle(.primary)
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("worldClock.overlapText")
    }

    // MARK: Rows

    private var hint: some View {
      Text("Tap + to add a city. Drag sideways to see their time later or earlier.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .accessibilityIdentifier("worldClock.hint")
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .moveDisabled(true)
        .deleteDisabled(true)
    }

    /// A city's long-press menu: move it up or down among your cities (home stays first), or delete it.
    @ViewBuilder
    private func cityMenu(_ city: CityRecord) -> some View {
      let others = store.others
      let i = others.firstIndex(of: city) ?? 0
      Button {
        withAnimation(.snappy) { store.move(from: [i], to: i - 1) }
      } label: {
        Label("Move Up", systemImage: "arrow.up")
      }
      .disabled(i == 0)
      Button {
        withAnimation(.snappy) { store.move(from: [i], to: i + 2) }
      } label: {
        Label("Move Down", systemImage: "arrow.down")
      }
      .disabled(i >= others.count - 1)
      Divider()
      RowAction.delete { remove(city) }
    }

    private func remove(_ city: CityRecord) {
      guard let index = store.others.firstIndex(of: city) else { return }
      withAnimation(.snappy) { store.remove(city) }
      showUndo("Removed \(db.displayName(city, locale: locale))") {
        withAnimation(.snappy) { store.insert(city, at: index) }
      }
    }
  }

  /// A sideways pan that starts only when the finger moves clearly sideways, and runs alongside the list's own
  /// scrolling, so vertical scrolling stays untouched.
  private struct HorizontalPan: UIGestureRecognizerRepresentable {
    var onTouchDown: () -> Void
    /// Cumulative translation and velocity, in points and points per second.
    var onChange: (CGFloat, CGFloat) -> Void
    /// Velocity at the release; 0 when the gesture was cancelled.
    var onEnd: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
      Coordinator(onTouchDown: onTouchDown)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
      let pan = UIPanGestureRecognizer()
      pan.delegate = context.coordinator
      return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
      switch pan.state {
      case .began, .changed:
        onChange(pan.translation(in: pan.view).x, pan.velocity(in: pan.view).x)
      case .ended: onEnd(pan.velocity(in: pan.view).x)
      case .cancelled, .failed: onEnd(0)
      default: break
      }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
      private let onTouchDown: () -> Void

      init(onTouchDown: @escaping () -> Void) {
        self.onTouchDown = onTouchDown
      }

      /// Called as soon as a finger lands, long before the pan begins: this is what stops a coast at once.
      func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        onTouchDown()
        return true
      }

      func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: pan.view)
        return abs(v.x) > abs(v.y) * 1.5
      }

      func gestureRecognizer(
        _ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
      ) -> Bool { true }
    }
  }

  /// Feeds `WorldClock.Scrub.Motion` from the finger and the display, and publishes only whole-minute changes,
  /// so the page redraws no more often than the time it shows actually moves.
  @MainActor
  @Observable
  private final class ScrubDriver: NSObject {
    private(set) var offset = 0
    private(set) var isFast = false

    @ObservationIgnored private var motion = WorldClock.Scrub.Motion()
    @ObservationIgnored private var lastTranslation: CGFloat = 0
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var releasedAt: CFTimeInterval = 0

    func touchDown() {
      stopLink()
      motion.touchDown()
      publish()
    }

    func jump(to minutes: Int) {
      stopLink()
      motion.jump(to: minutes)
      publish()
    }

    func dragged(translation: CGFloat, velocity: CGFloat) {
      motion.drag(points: Double(translation - lastTranslation), speed: abs(Double(velocity)))
      lastTranslation = translation
      publish()
    }

    func released(velocity: CGFloat) {
      lastTranslation = 0
      motion.release(velocity: Double(velocity))
      publish()
      guard motion.isCoasting else { return }
      releasedAt = CACurrentMediaTime()
      let link = CADisplayLink(target: self, selector: #selector(tick))
      link.add(to: .main, forMode: .common)
      self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
      motion.advance(elapsed: link.targetTimestamp - releasedAt)
      publish()
      if !motion.isCoasting { stopLink() }
    }

    private func stopLink() {
      link?.invalidate()
      link = nil
    }

    private func publish() {
      if offset != motion.offset { offset = motion.offset }
      if isFast != motion.isFast { isFast = motion.isFast }
    }
  }

  /// The month grid behind the calendar button: pick a day to go there, or come back to now.
  private struct ScrubDateSheet: View {
    let home: TimeZone
    let firstWeekday: Preferences.FirstWeekday
    let shown: Date
    let range: ClosedRange<Date>
    let isAtNow: Bool
    let pick: (Date, Calendar) -> Void
    let returnToNow: () -> Void

    @Environment(\.calendar) private var environmentCalendar

    private var calendar: Calendar {
      var c = firstWeekday.calendar(base: environmentCalendar)
      c.timeZone = home
      return c
    }

    var body: some View {
      let calendar = self.calendar
      VStack(spacing: 8) {
        DatePicker(
          "Date", selection: Binding(get: { shown }, set: { pick($0, calendar) }), in: range,
          displayedComponents: .date
        )
        .datePickerStyle(.graphical)
        .labelsHidden()
        .tint(Color(WorldClock.Look.green))
        .environment(\.calendar, calendar)
        .environment(\.timeZone, home)
        .accessibilityIdentifier("worldClock.datePicker")
        Button(action: returnToNow) {
          Text("Return to Now")
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
            .opacity(isAtNow ? 0.4 : 1)
        }
        .buttonStyle(PressScale())
        .disabled(isAtNow)
        .accessibilityIdentifier("worldClock.returnToNow")
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .presentationDetents([.height(480)])
      .presentationDragIndicator(.visible)
      .presentationBackground(Color(.systemBackground))
    }
  }

  /// The bell curve of Overlap's toolbar: a flat foot, a hill, a flat foot.
  private struct BellCurve: Shape {
    func path(in r: CGRect) -> Path {
      var p = Path()
      p.move(to: CGPoint(x: r.minX, y: r.maxY))
      p.addCurve(
        to: CGPoint(x: r.midX, y: r.minY), control1: CGPoint(x: r.width * 0.34, y: r.maxY),
        control2: CGPoint(x: r.width * 0.30, y: r.minY))
      p.addCurve(
        to: CGPoint(x: r.maxX, y: r.maxY), control1: CGPoint(x: r.width * 0.70, y: r.minY),
        control2: CGPoint(x: r.width * 0.66, y: r.maxY))
      return p
    }
  }

  /// One city: the name and "+2" (a star for home) on the left, the time big and heavy with the date under it on the
  /// right, on a card colored by the time of day there. In graph mode the card is flat: no background, content moved inward.
  private struct CityCard: View {
    let city: CityRecord
    let home: CityRecord
    let date: Date
    let isHome: Bool
    let flat: Bool
    /// The time is racing by: skip the per-step color and digit animations.
    let moving: Bool
    let db: CityDatabase
    let texts: WorldClock.CardTexts

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    private var zone: TimeZone { city.timeZone ?? TimeZone(secondsFromGMT: 0)! }
    private var homeZone: TimeZone { home.timeZone ?? TimeZone(secondsFromGMT: 0)! }
    private var name: String { db.displayName(city, locale: locale) }
    private var colors: WorldClock.CardColors { WorldClock.Look.card(zone: zone, at: date) }
    private var offset: String { WorldClock.offsetBadge(zone: zone, home: homeZone, at: date) }
    private var dateText: String { texts.longDate(zone: zone, at: date, locale: locale) }
    private var parts: (time: String, suffix: String?) {
      let hm = WorldClock.hourMinute(zone: zone, at: date)
      return texts.timeParts(hour: hm.hour, minute: hm.minute, locale: locale)
    }

    var body: some View {
      let c = colors
      StackedCard(
        fill: LinearGradient(
          colors: [Color(c.leading), Color(c.trailing)], startPoint: .leading, endPoint: .trailing),
        horizontalPadding: flat ? 41 : 16,
        flat: flat
      ) {
        HStack(alignment: .top, spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(name)
              .font(.system(size: 19, weight: .bold))
              .lineLimit(1)
              .minimumScaleFactor(0.7)
            if isHome {
              Image(systemName: "star.fill").font(.system(size: 12))
            } else {
              Text(offset)
                .font(.system(size: 10.5, weight: .medium))
                .opacity(0.9)
            }
          }
          .padding(.top, 21)
          Spacer(minLength: 8)
          VStack(alignment: .trailing, spacing: -1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
              Text(parts.time)
                .font(
                  .system(size: flat ? 33 : 35, weight: .heavy, design: .rounded).monospacedDigit()
                )
                .contentTransition(.numericText())
              if let suffix = parts.suffix {
                Text(suffix).font(.system(size: 14, weight: .semibold))
              }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            Text(dateText)
              .font(.system(size: 10, weight: .medium))
              .tracking(0.5)
              .lineLimit(1)
              .minimumScaleFactor(0.6)
          }
          .padding(.top, 11)
        }
        .foregroundStyle(.white)
        .frame(height: flat ? 78 : 82, alignment: .top)
      }
      .animation(moving ? nil : .easeInOut(duration: 0.25), value: c)
      .stackedCardRow()
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "\(name), \(isHome ? "Home" : offset), \(dateText.capitalized), \(parts.time) \(parts.suffix ?? "")"
      )
      .accessibilityIdentifier(isHome ? "worldClock.home" : "worldClock.row")
    }
  }

  /// The waves behind the graph: three layers of green, the front one solid, the two behind translucent and fading up
  /// into the black. Height is the share of cities in the window, at most 70 % of the page.
  private struct WaveBackground: View {
    let waves: [[Double]]

    var body: some View {
      GeometryReader { geo in
        let maxHeight = geo.size.height * 0.7
        ZStack(alignment: .bottom) {
          ForEach([2, 1, 0], id: \.self) { layer in
            if layer < waves.count, !waves[layer].isEmpty {
              wave(waves[layer], in: geo.size, maxHeight: maxHeight)
                .fill(fill(layer))
            }
          }
        }
      }
    }

    private func fill(_ layer: Int) -> AnyShapeStyle {
      let green = Color(WorldClock.Look.green)
      switch layer {
      case 0: return AnyShapeStyle(green)
      case 1:
        return AnyShapeStyle(
          LinearGradient(
            colors: [green.opacity(0), green.opacity(0.5)], startPoint: .top, endPoint: .bottom))
      default:
        return AnyShapeStyle(
          LinearGradient(
            colors: [green.opacity(0), green.opacity(0.32)], startPoint: .top, endPoint: .bottom))
      }
    }

    private func wave(_ heights: [Double], in size: CGSize, maxHeight: CGFloat) -> Path {
      var p = Path()
      let n = heights.count
      p.move(to: CGPoint(x: 0, y: size.height))
      for (i, h) in heights.enumerated() {
        let x = size.width * CGFloat(i) / CGFloat(max(1, n - 1))
        let y = size.height - maxHeight * CGFloat(max(h, 0.05))
        p.addLine(to: CGPoint(x: x, y: y))
      }
      p.addLine(to: CGPoint(x: size.width, y: size.height))
      p.closeSubpath()
      return p
    }
  }

  /// Add a city: about a thousand cities (every capital, every big city, the main hubs), searchable in English and Chinese,
  /// by city, country or time zone. Each row: "Beijing, China", the UTC offset and the local time there.
  /// Cities already shown (home included) are checked.
  public struct CityPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store: WorldClockStore
    @Environment(\.locale) private var locale
    private let now: () -> Date
    @State private var query = ""

    public init(store: WorldClockStore, now: @escaping () -> Date) {
      _store = State(initialValue: store)
      self.now = now
    }

    public var body: some View {
      let db = store.database
      let results = db.search(query)
      let now = self.now()
      NavigationStack {
        List {
          ForEach(results) { city in
            let added = store.contains(city)
            Button {
              store.add(city)
              dismiss()
            } label: {
              row(city, db: db, added: added, now: now)
            }
            .buttonStyle(.plain)
            .disabled(added)
            .accessibilityIdentifier("city.\(city.name).\(city.cc)")
          }
          Text("City data: GeoNames (CC BY 4.0)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("cityPicker.credit")
        }
        .listStyle(.plain)
        .overlay {
          if results.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .performanceDestination("clock.cityPicker")
        .navigationTitle("Choose a City")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
          text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search"
        )
        .textInputAutocapitalization(.never)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
      }
    }

    private func row(_ city: CityRecord, db: CityDatabase, added: Bool, now: Date) -> some View {
      let zone = city.timeZone ?? TimeZone(secondsFromGMT: 0)!
      let hm = WorldClock.hourMinute(zone: zone, at: now)
      let time = AlarmPlan.timeParts(hour: hm.hour, minute: hm.minute, locale: locale)
      let country = CityDatabase.countryName(city.cc, locale: locale)
      return HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(db.displayName(city, locale: locale) + (country.isEmpty ? "" : ", " + country))
            .foregroundStyle(added ? .secondary : .primary)
            .lineLimit(1)
          Text(WorldClock.utcOffsetText(zone: zone, at: now))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        if added {
          Image(systemName: "checkmark").foregroundStyle(.secondary)
        } else {
          Text(time.time + (time.suffix.map { " " + $0 } ?? ""))
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
    }
  }
#endif
