#if os(iOS)
  import SwiftUI
  import TodayCore

  private struct CalendarCityDatabaseKey: EnvironmentKey {
    static let defaultValue = CityDatabase(cities: [])
  }
  extension EnvironmentValues {
    package var calendarCityDatabase: CityDatabase {
      get { self[CalendarCityDatabaseKey.self] }
      set { self[CalendarCityDatabaseKey.self] = newValue }
    }
  }

  /// Shared by Calendar and Settings, using the city database supplied by the composition root.
  package struct CalendarTimeZoneSettings: View {
    @Environment(PlannerPresentation.self) private var presentation
    @Environment(\.calendarCityDatabase) private var database
    @Environment(\.locale) private var locale
    @AppStorage(CalendarTimeZone.enabledKey) private var enabled = false
    @AppStorage(CalendarTimeZone.cityKey) private var storedCity = ""
    @State private var query = ""
    @State private var choosing = false
    @State private var addedCity: CityRecord?
    @State private var previousCity = ""
    @State private var previousEnabled = false
    @State private var addedKeys: [String] = []
    private var city: CityRecord? { CalendarTimeZone.city(stored: storedCity) }

    package init() {}
    package var body: some View {
      Form {
        if let addedCity {
          Section {
            Text("\(addedCity.name) added to World Clock")
            Button("Undo") {
              // Undo only this addition; preserve a subsequently edited city list.
              let defaults = presentation.defaults
              if defaults.stringArray(forKey: CalendarTimeZone.worldCitiesKey) == addedKeys {
                defaults.set(
                  addedKeys.filter { $0 != addedCity.key }, forKey: CalendarTimeZone.worldCitiesKey)
              }
              if city?.key == addedCity.key {
                storedCity = previousCity
                enabled = previousEnabled
              }
              self.addedCity = nil
            }
            .accessibilityIdentifier("calendar.secondZone.undoAdd")
          }
        }
        Section {
          Toggle(
            "Second time zone",
            isOn: Binding(
              get: { enabled },
              set: { value in
                if value && city == nil { choosing = true } else { enabled = value }
              })
          )
          .accessibilityIdentifier("calendar.secondZone.enabled")
          Button {
            choosing = true
          } label: {
            LabeledContent(
              "City",
              value: city.map { database.displayName($0, locale: locale) } ?? "Choose a City")
          }
          .accessibilityIdentifier("calendar.secondZone.city")
        } footer: {
          Text(
            "Show a second time column beside your iPhone's local time in Today and Calendar 2 Day. +1 and −1 mean the next and previous date. Cities you choose are also added to World Clock. L and R identify the left and right day when their times differ. Turning this off keeps the city in World Clock."
          )
        }
        if let city {
          Section {
            Text(city.tz.replacingOccurrences(of: "_", with: " "))
            if enabled { Label("Shown in Calendar", systemImage: "calendar") }
          }
        }
      }
      .navigationTitle("Second Time Zone")
      .navigationBarTitleDisplayMode(.inline)
      .sheet(isPresented: $choosing) { cityPicker }
    }

    private func choose(_ choice: CityRecord) {
      let keys = presentation.defaults.stringArray(forKey: CalendarTimeZone.worldCitiesKey) ?? []
      addedCity = nil
      if !keys.contains(choice.key) {
        previousCity = storedCity
        previousEnabled = enabled
        addedCity = choice
      }
      CalendarTimeZone.choose(choice, defaults: presentation.defaults)
      addedKeys = presentation.defaults.stringArray(forKey: CalendarTimeZone.worldCitiesKey) ?? []
    }

    private var cityPicker: some View {
      NavigationStack {
        List {
          ForEach(database.search(query)) { city in
            Button {
              choose(city)
              choosing = false
            } label: {
              VStack(alignment: .leading) {
                Text(database.displayName(city, locale: locale))
                Text(city.tz.replacingOccurrences(of: "_", with: " "))
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            .accessibilityIdentifier("calendar.secondZone.choose.\(city.key)")
          }
          // IANA identifiers cover zones without a city in the offline database.
          if !query.isEmpty {
            ForEach(
              TimeZone.knownTimeZoneIdentifiers.filter {
                $0.localizedCaseInsensitiveContains(query)
              }.prefix(20), id: \.self
            ) { identifier in
              Button(identifier.replacingOccurrences(of: "_", with: " ")) {
                let city =
                  database.city(forTimeZone: identifier)
                  ?? CityRecord(id: 0, name: identifier, tz: identifier)
                choose(city)
                choosing = false
              }
            }
          }
          Text("City data: GeoNames (CC BY 4.0)").font(.footnote).foregroundStyle(.secondary)
        }
        .searchable(text: $query, prompt: "City or time zone")
        .navigationTitle("Choose a City")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosing = false } }
        }
      }
    }
  }
#endif
