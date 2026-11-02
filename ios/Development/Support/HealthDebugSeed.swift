import FeatureReminders
import One

#if DEBUG
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import TodayDesignSystem
  import FeatureClock
  import FeatureHealth
  import Foundation
  import HealthKit
  import os

  /// Debug builds only: `-seedHealth steps,sleep,weight,bodyFat` writes a week of made-up samples for those metrics into the
  /// (simulator's) Health database, so the real `HealthKitSource` code path has something to read. It asks for write
  /// access to exactly those types, so anything not listed is still "not asked about yet" and shows Apple's sheet on Add Metric.
  enum HealthDebugSeed {
    private static let log = Logger(subsystem: "com.luworks.today", category: "health")

    static func runIfRequested() {
      let args = ProcessInfo.processInfo.arguments
      guard let i = args.firstIndex(of: "-seedHealth"), i + 1 < args.count,
        HKHealthStore.isHealthDataAvailable()
      else { return }
      let ids = args[i + 1].split(separator: ",").map(String.init)
      Task.detached { await seed(ids) }
    }

    private static func seed(_ ids: [String]) async {
      let store = HKHealthStore()
      let quantityTypes: [String: (HKQuantityType, HKUnit, (Int) -> Double)] = [
        "steps": (HKQuantityType(.stepCount), .count(), { 4000 + Double($0 * 700) }),
        "weight": (HKQuantityType(.bodyMass), .gramUnit(with: .kilo), { 70 + Double($0) * 0.1 }),
        "bodyFat": (HKQuantityType(.bodyFatPercentage), .percent(), { 0.2 + Double($0) * 0.001 }),
        "restingHeartRate": (
          HKQuantityType(.restingHeartRate), HKUnit.count().unitDivided(by: .minute()),
          { 58 + Double($0) }
        ),
        "activeEnergy": (
          HKQuantityType(.activeEnergyBurned), .kilocalorie(), { 200 + Double($0 * 20) }
        ),
      ]
      var share: Set<HKSampleType> = []
      for id in ids { if let q = quantityTypes[id] { share.insert(q.0) } }
      if ids.contains("sleep") { share.insert(HKCategoryType(.sleepAnalysis)) }
      do {
        try await store.requestAuthorization(toShare: share, read: share)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var samples: [HKSample] = []
        for back in 0..<7 {
          guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
          for id in ids {
            guard let (type, unit, value) = quantityTypes[id] else { continue }
            let start = day.addingTimeInterval(8 * 3600)
            let end = day.addingTimeInterval(9 * 3600)
            samples.append(
              HKQuantitySample(
                type: type, quantity: HKQuantity(unit: unit, doubleValue: value(back)),
                start: start, end: end))
          }
          if ids.contains("sleep") {
            let start = day.addingTimeInterval(-1.5 * 3600)
            let end = day.addingTimeInterval(6 * 3600)
            samples.append(
              HKCategorySample(
                type: HKCategoryType(.sleepAnalysis),
                value: HKCategoryValueSleepAnalysis.asleepCore.rawValue, start: start, end: end))
          }
        }
        try await store.save(samples)
        log.info(
          "seeded \(samples.count) Health samples for \(ids.joined(separator: ","), privacy: .public)"
        )
      } catch {
        log.error("seeding Health failed: \((error as NSError).code, privacy: .public)")
      }
    }
  }
#endif
