#if os(iOS)
  import Foundation
  import TodayCore
  import os
  private let healthLog = Logger(subsystem: "com.luworks.one", category: "health")
  import HealthKit

  /// Apple Health through HealthKit. Totals (steps, energy, distance, minutes) are daily sums from HealthKit's own
  /// statistics, so iPhone and Watch are not counted twice; readings (weight, resting heart rate, body fat) are the
  /// samples themselves; sleep is category samples grouped into nights; mindful minutes are session durations per day.
  /// Values come back in the canonical units of `HealthMetric` (kg, meters, kcal, minutes, percent); display units
  /// follow the region in `HealthUnits`.
  public final class HealthKitSource: HealthSource, HealthQuerySource, @unchecked Sendable {
    private let store = HKHealthStore()
    private let queryLimiter = HealthQueryLimiter()

    public init() {}

    public var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private func quantity(_ metric: HealthMetric) -> (HKQuantityType, HealthQuantityDescriptor)? {
      guard let descriptor = HealthCatalog.quantities[metric] else { return nil }
      let required = descriptor.minimumIOS
      let major = Int(required)
      let minor = Int((required - Double(major)) * 10 + 0.5)
      guard
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
          OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)),
        let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: descriptor.identifier))
      else { return nil }
      return (type, descriptor)
    }

    private func objectType(_ metric: HealthMetric) -> HKObjectType? {
      if metric == .sleep { return HKCategoryType(.sleepAnalysis) }
      if metric == .mindfulMinutes { return HKCategoryType(.mindfulSession) }
      return quantity(metric)?.0
    }

    public func requestAccess(for metrics: [HealthMetric]) async {
      guard isAvailable, !metrics.isEmpty else { return }
      // Only the user's selected types are requested. Completion cannot establish read authorization.
      do {
        try await store.requestAuthorization(toShare: [], read: Set(metrics.compactMap(objectType)))
      } catch {
        healthLog.error("requestAuthorization failed: \((error as NSError).code, privacy: .public)")
      }
    }

    private func unit(_ kind: HealthCanonicalUnit) -> HKUnit {
      switch kind {
      case .celsius: .degreeCelsius()
      case .percent: .percent()
      case .kilograms: .gramUnit(with: .kilo)
      case .count: .count()
      case .siemens: .siemen()
      case .meters: .meter()
      case .kilocalories: .kilocalorie()
      case .minutes: .minute()
      case .metersPerSecond: HKUnit.meter().unitDivided(by: .second())
      case .perMinute: HKUnit.count().unitDivided(by: .minute())
      case .watts: .watt()
      case .effortScore: .appleEffortScore()
      case .metabolicRate:
        HKUnit.kilocalorie().unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: .hour())
      case .decibels: .decibelAWeightedSoundPressureLevel()
      case .milliseconds: .secondUnit(with: .milli)
      case .oxygenUptake:
        HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)).unitDivided(
          by: .minute())
      case .centimeters: .meterUnit(with: .centi)
      case .grams: .gram()
      case .milliliters: .literUnit(with: .milli)
      case .millimetersOfMercury: .millimeterOfMercury()
      case .internationalUnits: .internationalUnit()
      case .liters: .liter()
      case .litersPerMinute: HKUnit.liter().unitDivided(by: .minute())
      case .glucose: HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
      }
    }

    /// Health lets people pick kg or lb (and km or mi) independent of the region; this reads that choice.
    public func preferredUnits() async -> HealthUnits? {
      guard isAvailable else { return nil }
      let weight = HKQuantityType(.bodyMass)
      let distance = HKQuantityType(.distanceWalkingRunning)
      guard let units = try? await store.preferredUnits(for: [weight, distance]) else { return nil }
      let base = HealthUnits()
      return HealthUnits(
        poundsForWeight: units[weight].map { $0 == .pound() || $0 == .stone() }
          ?? base.poundsForWeight,
        milesForDistance: units[distance].map { $0 == .mile() } ?? base.milesForDistance)
    }

    public func series(for metrics: [HealthMetric], days: Int, now: Date) async -> [HealthMetric:
      HealthSeries]
    {
      guard isAvailable else { return [:] }
      let requested = Array(Set(metrics)).sorted { $0.rawValue < $1.rawValue }
      var out: [HealthMetric: HealthSeries] = [:]
      // A large selected catalog must not enqueue hundreds of HealthKit queries simultaneously.
      for offset in stride(from: 0, to: requested.count, by: HealthCatalog.maximumConcurrentQueries)
      {
        guard !Task.isCancelled else { return [:] }
        let batch = requested[
          offset..<min(offset + HealthCatalog.maximumConcurrentQueries, requested.count)]
        let values = await withTaskGroup(of: (HealthMetric, HealthSeries).self) { group in
          for metric in batch {
            group.addTask { [self] in
              do {
                let series = try await queryLimiter.run { [self] in
                  try await load(metric, days: days, now: now)
                }
                return (metric, series)
              } catch {
                healthLog.error(
                  "query failed for \(metric.rawValue, privacy: .public): \((error as NSError).code, privacy: .public)"
                )
                return (metric, .empty)
              }
            }
          }
          var result: [HealthMetric: HealthSeries] = [:]
          for await (metric, series) in group { result[metric] = series }
          return result
        }
        out.merge(values) { _, new in new }
      }
      return out
    }

    public func query(_ metric: HealthMetric, days: Int, now: Date) async throws -> HealthSeries {
      guard isAvailable else { throw HealthRecordError.unavailable }
      return try await queryLimiter.run { [self] in
        try await load(metric, days: days, now: now)
      }
    }

    private func load(_ metric: HealthMetric, days: Int, now: Date) async throws -> HealthSeries {
      try Task.checkCancellation()
      let days = min(max(days, 1), HealthCatalog.maximumHistoryDays)
      let cal = Calendar.current
      let today = cal.startOfDay(for: now)
      guard let start = cal.date(byAdding: .day, value: -(days - 1), to: today) else {
        return .empty
      }
      if let (type, descriptor) = quantity(metric) {
        let canonicalUnit = unit(descriptor.unit)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
        if descriptor.aggregation == .samples {
          // These low-frequency original metrics retain individual readings and sample-weighted trends.
          let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 20_000)
          let samples = try await query.result(for: store)
          try Task.checkCancellation()
          return HealthSeries(
            points: samples.compactMap {
              let value = $0.quantity.doubleValue(for: canonicalUnit) * descriptor.scale
              return value.isFinite ? HealthPoint(date: $0.endDate, value: value) : nil
            })
        }
        let sum = descriptor.aggregation == .dailySum
        let query = HKStatisticsCollectionQueryDescriptor(
          predicate: .quantitySample(type: type, predicate: predicate),
          options: sum ? .cumulativeSum : .discreteAverage,
          anchorDate: start, intervalComponents: DateComponents(day: 1))
        let collection = try await query.result(for: store)
        try Task.checkCancellation()
        var points: [HealthPoint] = []
        collection.enumerateStatistics(from: start, to: now) { stats, _ in
          if let quantity = sum ? stats.sumQuantity() : stats.averageQuantity() {
            let value = quantity.doubleValue(for: canonicalUnit) * descriptor.scale
            if value.isFinite {
              points.append(HealthPoint(date: cal.startOfDay(for: stats.startDate), value: value))
            }
          }
        }
        return HealthSeries(points: points)
      }
      switch metric {
      case .sleep:
        // From 18:00 the evening before the first day, so the oldest night is complete.
        let previousDay = cal.date(byAdding: .day, value: -1, to: start) ?? start
        let from = cal.date(bySettingHour: 18, minute: 0, second: 0, of: previousDay) ?? previousDay
        let query = HKSampleQueryDescriptor(
          predicates: [
            .categorySample(
              type: HKCategoryType(.sleepAnalysis),
              predicate: HKQuery.predicateForSamples(withStart: from, end: now))
          ],
          sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 20_000)
        let intervals = try await query.result(for: store).compactMap { sample -> SleepInterval? in
          guard let stage = Self.stage(sample.value) else { return nil }
          return SleepInterval(start: sample.startDate, end: sample.endDate, stage: stage)
        }
        return HealthSeries(
          points: HealthMath.nights(intervals, count: days, now: now)
            .filter { $0.asleep > 0 }
            .map { HealthPoint(date: $0.day, value: $0.asleep / 60) })
      case .mindfulMinutes:
        let query = HKSampleQueryDescriptor(
          predicates: [
            .categorySample(
              type: HKCategoryType(.mindfulSession),
              predicate: HKQuery.predicateForSamples(withStart: start, end: now))
          ],
          sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 20_000)
        let samples = try await query.result(for: store)
        try Task.checkCancellation()
        let intervals = samples.compactMap { sample -> DateInterval? in
          guard sample.endDate > sample.startDate else { return nil }
          return DateInterval(start: sample.startDate, end: sample.endDate)
        }
        return HealthSeries(
          points: HealthDurationMath.dailyMinutes(intervals, start: start, end: now, calendar: cal))
      default: return .empty
      }
    }

    /// "In bed" is not sleep and is dropped.
    private static func stage(_ raw: Int) -> SleepStage? {
      switch HKCategoryValueSleepAnalysis(rawValue: raw) {
      case .awake: .awake
      case .asleepREM: .rem
      case .asleepCore: .core
      case .asleepDeep: .deep
      case .asleepUnspecified: .unspecified
      default: nil
      }
    }
  }

  extension HealthKitSource: HealthRecordSource {
    private func availableCategoryTypes() -> [(HKCategoryType, HealthCategoryDescriptor)] {
      HealthCatalog.categories.compactMap { descriptor in
        let major = Int(descriptor.minimumIOS)
        let minor = Int((descriptor.minimumIOS - Double(major)) * 10 + 0.5)
        guard
          ProcessInfo.processInfo.isOperatingSystemAtLeast(
            .init(majorVersion: major, minorVersion: minor, patchVersion: 0)),
          let type = HKObjectType.categoryType(
            forIdentifier: .init(rawValue: descriptor.identifier))
        else { return nil }
        return (type, descriptor)
      }
    }

    private func recordReadTypes(_ families: [HealthRecordFamily]) -> Set<HKObjectType> {
      var types: Set<HKObjectType> = []
      for family in Set(families) {
        switch family {
        case .categories:
          for (type, _) in availableCategoryTypes() { types.insert(type) }
        case .workouts: types.insert(HKObjectType.workoutType())
        case .bloodPressure:
          // Correlations are authorized through their contained quantities, not the correlation type itself.
          types.insert(HKQuantityType(.bloodPressureSystolic))
          types.insert(HKQuantityType(.bloodPressureDiastolic))
        case .characteristics:
          for id: HKCharacteristicTypeIdentifier in [
            .dateOfBirth, .biologicalSex, .bloodType, .wheelchairUse, .fitzpatrickSkinType,
            .activityMoveMode,
          ] {
            if let type = HKObjectType.characteristicType(forIdentifier: id) { types.insert(type) }
          }
        }
      }
      return types
    }

    public func requestRecordAccess(for families: [HealthRecordFamily]) async throws {
      guard isAvailable else { throw HealthRecordError.unavailable }
      try Task.checkCancellation()
      try await store.requestAuthorization(toShare: [], read: recordReadTypes(families))
    }

    public func records(for families: [HealthRecordFamily], days: Int, now: Date) async throws
      -> [HealthRecordFamily: [HealthRecord]]
    {
      try await queryLimiter.run { [self] in
        try await loadRecords(for: families, days: days, now: now)
      }
    }

    private func loadRecords(for families: [HealthRecordFamily], days: Int, now: Date) async throws
      -> [HealthRecordFamily: [HealthRecord]]
    {
      guard isAvailable else { throw HealthRecordError.unavailable }
      let window = HealthWindow(days: min(max(days, 1), HealthCatalog.maximumHistoryDays), now: now)
      let predicate = HKQuery.predicateForSamples(withStart: window.start, end: now)
      var result: [HealthRecordFamily: [HealthRecord]] = [:]
      for family in Set(families) {
        try Task.checkCancellation()
        switch family {
        case .categories:
          var events: [(Date, HealthRecord)] = []
          for (type, descriptor) in availableCategoryTypes() {
            try Task.checkCancellation()
            let query = HKSampleQueryDescriptor(
              predicates: [.categorySample(type: type, predicate: predicate)],
              sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
              limit: HealthRecordLimits.maximumRecordsPerType)
            for sample in try await query.result(for: store) {
              guard let value = descriptor.values[sample.value] else { continue }
              guard sample.endDate >= sample.startDate else { continue }
              events.append(
                (
                  sample.startDate,
                  .category(
                    .init(
                      identifier: descriptor.identifier, title: descriptor.title,
                      value: value, start: sample.startDate, end: sample.endDate))
                ))
            }
          }
          result[family] = events.sorted { $0.0 > $1.0 }.prefix(
            HealthRecordLimits.maximumRecordsPerType
          ).map(\.1)
        case .workouts:
          let query = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: HealthRecordLimits.maximumRecordsPerType)
          result[family] = try await query.result(for: store).compactMap { sample in
            guard sample.duration.isFinite, sample.duration >= 0, sample.endDate >= sample.startDate
            else { return nil }
            return .workout(
              .init(
                activityCode: sample.workoutActivityType.rawValue,
                title: Self.workoutTitle(sample.workoutActivityType), start: sample.startDate,
                end: sample.endDate, durationSeconds: sample.duration))
          }
        case .bloodPressure:
          let query = HKSampleQueryDescriptor(
            predicates: [
              .correlation(type: HKCorrelationType(.bloodPressure), predicate: predicate)
            ],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: HealthRecordLimits.maximumRecordsPerType)
          result[family] = try await query.result(for: store).compactMap { sample in
            let systolic = sample.objects(for: HKQuantityType(.bloodPressureSystolic)).compactMap {
              $0 as? HKQuantitySample
            }
            let diastolic = sample.objects(for: HKQuantityType(.bloodPressureDiastolic)).compactMap
            { $0 as? HKQuantitySample }
            guard systolic.count == 1, diastolic.count == 1 else { return nil }
            let high = systolic[0].quantity.doubleValue(for: .millimeterOfMercury())
            let low = diastolic[0].quantity.doubleValue(for: .millimeterOfMercury())
            guard high.isFinite, low.isFinite, high > 0, low > 0 else { return nil }
            return .bloodPressure(.init(systolic: high, diastolic: low, date: sample.endDate))
          }
        case .characteristics:
          result[family] = try profileRecords()
        }
      }
      try Task.checkCancellation()
      return result
    }

    private func profileRecords() throws -> [HealthRecord] {
      var output: [HealthRecord] = []
      func readable<T>(_ read: () throws -> T) throws -> T? {
        do { return try read() } catch let error as HKError
          where error.code == .errorNoData || error.code == .errorAuthorizationDenied
        {
          // Missing and unreadable characteristics deliberately have the same empty presentation.
          return nil
        }
      }
      func append(_ field: String, _ code: Int?, _ values: [Int: String]) {
        guard let code, let value = values[code] else { return }
        output.append(.characteristic(.init(field: field, value: value)))
      }
      append(
        "Biological Sex", try readable { try store.biologicalSex().biologicalSex.rawValue },
        [1: "Female", 2: "Male", 3: "Other"])
      append(
        "Blood Type", try readable { try store.bloodType().bloodType.rawValue },
        [1: "A+", 2: "A−", 3: "B+", 4: "B−", 5: "AB+", 6: "AB−", 7: "O+", 8: "O−"])
      append(
        "Wheelchair Use", try readable { try store.wheelchairUse().wheelchairUse.rawValue },
        [1: "No", 2: "Yes"])
      append(
        "Fitzpatrick Skin Type", try readable { try store.fitzpatrickSkinType().skinType.rawValue },
        [1: "I", 2: "II", 3: "III", 4: "IV", 5: "V", 6: "VI"])
      append(
        "Move Mode", try readable { try store.activityMoveMode().activityMoveMode.rawValue },
        [1: "Active Energy", 2: "Move Time"])
      if let components = try readable({ try store.dateOfBirthComponents() }),
        let year = components.year,
        let month = components.month, let day = components.day
      {
        output.append(
          .characteristic(
            .init(field: "Date of Birth", value: String(format: "%04d-%02d-%02d", year, month, day))
          ))
      }
      return output
    }

    private static func workoutTitle(_ type: HKWorkoutActivityType) -> String {
      switch type {
      case .walking: "Walking"
      case .running: "Running"
      case .cycling: "Cycling"
      case .swimming: "Swimming"
      case .hiking: "Hiking"
      case .yoga: "Yoga"
      case .traditionalStrengthTraining: "Strength Training"
      case .functionalStrengthTraining: "Functional Strength Training"
      case .highIntensityIntervalTraining: "Interval Training"
      case .rowing: "Rowing"
      case .elliptical: "Elliptical"
      case .dance: "Dance"
      case .pilates: "Pilates"
      case .cooldown: "Cooldown"
      case .other: "Other Workout"
      default: "Workout (activity \(type.rawValue))"
      }
    }
  }
#endif
