import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

final class HealthMetricsTests: XCTestCase {
  private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
  }()
  private let en = Locale(identifier: "en_US")

  private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
  }
  private var nowDate: Date { date(16, 15) }
  private func daily(_ back: Int, _ value: Double) -> HealthPoint {
    HealthPoint(
      date: cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: nowDate))!, value: value)
  }

  // MARK: Catalog

  func testCatalogCoversEveryMetricOnceInAGroup() {
    XCTAssertEqual(HealthMetric.allCases.count, 123)
    XCTAssertEqual(Set(HealthMetric.allCases.map(\.rawValue)).count, 123)
    for g in HealthGroup.allCases {
      XCTAssertFalse(HealthMetric.allCases.filter { $0.group == g }.isEmpty, "\(g) has metrics")
    }
    XCTAssertTrue(HealthMetric.allCases.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty })
  }

  func testDefaultSetIsThreeMetricsThatNeedNoWatch() {
    XCTAssertEqual(HealthSelection.default.shown, [.steps, .sleep, .weight])
    XCTAssertEqual(HealthSelection.default.hidden.count, 120)
    XCTAssertFalse(HealthSelection.default.shown.contains(.restingHeartRate))
  }

  func testShapesBarsForTotalsDotsForReadings() {
    for m in [
      HealthMetric.steps, .sleep, .activeEnergy, .exerciseMinutes, .distance, .mindfulMinutes,
      .daylight,
    ] {
      XCTAssertEqual(m.shape, .bars, "\(m)")
    }
    for m in [HealthMetric.weight, .restingHeartRate, .bodyFat] {
      XCTAssertEqual(m.shape, .dots, "\(m)")
    }
  }

  // MARK: Selection

  func testCategoriesDoNotChangeGlobalOrder() {
    var s = HealthSelection.default
    s.add([.daylight, .bodyFat, .activeEnergy, .steps])
    XCTAssertEqual(
      s.shown, [.steps, .sleep, .weight, .daylight, .bodyFat, .activeEnergy],
      "no duplicates, added at the end")
    XCTAssertEqual(s.ordered, s.shown)
    XCTAssertEqual(s.groups.map(\.group), [.activity, .recovery, .body])
    s.hide(.sleep)
    XCTAssertEqual(s.groups.map(\.group), [.activity, .body], "an empty group is not listed")
    XCTAssertTrue(s.hidden.contains(.sleep))
  }

  func testMoveCrossesCategoriesAndNudgesUseGlobalOrder() {
    var selection = HealthSelection(shown: [.steps, .sleep, .weight, .activeEnergy])
    selection.move(from: [2], to: 0)
    XCTAssertEqual(selection.ordered, [.weight, .steps, .sleep, .activeEnergy])
    XCTAssertEqual(HealthSelection.decoded(selection.encoded()), selection)
    selection.nudge(.sleep, by: -1)
    XCTAssertEqual(selection.ordered, [.weight, .sleep, .steps, .activeEnergy])
    selection.nudge(.weight, by: -1)
    selection.nudge(.activeEnergy, by: 1)
    XCTAssertEqual(selection.ordered, [.weight, .sleep, .steps, .activeEnergy])
    selection.moveToTop(.activeEnergy)
    XCTAssertEqual(selection.ordered.first, .activeEnergy)
    selection.move(from: [0, 2], to: 4)
    XCTAssertEqual(selection.ordered, [.weight, .steps, .activeEnergy, .sleep])
  }

  func testSavedFormRoundTripsAndToleratesJunk() {
    let s = HealthSelection(shown: [.weight, .steps, .distance])
    XCTAssertEqual(HealthSelection.decoded(s.encoded()), s)
    XCTAssertEqual(HealthSelection.decoded(nil), .default, "nothing saved: the default")
    XCTAssertEqual(HealthSelection.decoded(Data("nope".utf8)), .default)
    XCTAssertEqual(
      HealthSelection.decoded(Data(#"["steps","bogus","steps","weight"]"#.utf8)).shown,
      [.steps, .weight],
      "unknown ids and repeats are dropped")
    XCTAssertEqual(
      HealthSelection.decoded(HealthSelection(shown: []).encoded()).shown, [],
      "a saved empty list stays empty")
  }

  @MainActor
  func testStorePersistsAndTestLaunchesStartClean() async {
    let suite = "health-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = HealthTestSelection.make(defaults: defaults, arguments: [])
    XCTAssertEqual(first.selection, .default)
    first.save(HealthSelection(shown: [.weight, .steps]))
    XCTAssertEqual(
      HealthTestSelection.make(defaults: defaults, arguments: []).selection.shown,
      [.weight, .steps], "survives a relaunch")
    XCTAssertEqual(
      HealthTestSelection.make(
        defaults: defaults, arguments: ["-uiTesting", "-uiTestingKeepHealthMetrics"]
      ).selection.shown,
      [.weight, .steps], "a test relaunch can keep it")
    XCTAssertEqual(
      HealthTestSelection.make(defaults: defaults, arguments: ["-uiTesting"]).selection, .default,
      "a test launch starts clean")
    XCTAssertEqual(
      HealthTestSelection.make(
        defaults: defaults,
        arguments: ["-uiTesting", "-uiTestingHealthMetrics", "weight,bogus,daylight"]
      ).selection.shown,
      [.weight, .daylight], "or from a seeded list")
  }

  // MARK: Formatting

  func testValueAndUnit() {
    XCTAssertEqual(HealthFormat.value(.steps, 6_240, locale: en).text, "6,240 steps")
    XCTAssertEqual(HealthFormat.value(.steps, 1, locale: en).text, "1 step")
    XCTAssertEqual(
      HealthFormat.value(.sleep, 432, locale: en).parts,
      [.init(number: "7", unit: "hr"), .init(number: "12", unit: "min")])
    XCTAssertEqual(HealthFormat.value(.sleep, 420, locale: en).text, "7 hr")
    XCTAssertEqual(HealthFormat.value(.sleep, 45, locale: en).text, "45 min")
    XCTAssertEqual(HealthFormat.value(.activeEnergy, 173.4, locale: en).text, "173 kcal")
    XCTAssertEqual(HealthFormat.value(.restingHeartRate, 58.2, locale: en).text, "58 bpm")
    XCTAssertEqual(HealthFormat.value(.bodyFat, 20.74, locale: en).text, "20.7%")
    XCTAssertEqual(HealthFormat.value(.exerciseMinutes, 24, locale: en).text, "24 min")
    XCTAssertEqual(HealthFormat.value(.daylight, 85, locale: en).text, "1 hr 25 min")
  }

  func testLocaleUnits() {
    let us = HealthUnits(locale: Locale(identifier: "en_US"))
    let de = HealthUnits(locale: Locale(identifier: "de_DE"))
    let uk = HealthUnits(locale: Locale(identifier: "en_GB"))
    XCTAssertTrue(us.poundsForWeight && us.milesForDistance)
    XCTAssertFalse(de.poundsForWeight || de.milesForDistance)
    XCTAssertTrue(uk.milesForDistance && !uk.poundsForWeight)
    XCTAssertEqual(HealthFormat.value(.weight, 70.3, units: us, locale: en).text, "155.0 lb")
    XCTAssertEqual(HealthFormat.value(.weight, 70.3, units: .metric, locale: en).text, "70.3 kg")
    XCTAssertEqual(HealthFormat.value(.distance, 5_000, units: us, locale: en).text, "3.1 mi")
    XCTAssertEqual(HealthFormat.value(.distance, 5_000, units: .metric, locale: en).text, "5.0 km")
    XCTAssertEqual(
      HealthFormat.value(.distance, 800, units: .metric, locale: en).text, "0.80 km",
      "two decimals under one")
  }

  func testChangeText() {
    XCTAssertEqual(HealthFormat.change(.steps, 312, locale: en), "+312 steps")
    XCTAssertEqual(HealthFormat.change(.weight, -0.4, units: .metric, locale: en), "−0.4 kg")
    XCTAssertEqual(HealthFormat.change(.weight, 0.01, units: .metric, locale: en), "No change")
    XCTAssertEqual(HealthFormat.change(.sleep, 12, locale: en), "+12 min")
    XCTAssertEqual(HealthFormat.change(.sleep, -65, locale: en), "−1 hr 5 min")
    XCTAssertEqual(HealthFormat.change(.steps, 0.2, locale: en), "No change")
  }

  func testDateLabels() {
    XCTAssertEqual(
      HealthFormat.dateLabel(date(16, 7), now: nowDate, calendar: cal, locale: en), "Today")
    XCTAssertEqual(
      HealthFormat.dateLabel(date(15, 23), now: nowDate, calendar: cal, locale: en), "Yesterday")
    XCTAssertEqual(
      HealthFormat.dateLabel(date(4, 9), now: nowDate, calendar: cal, locale: en), "Oct 4")
    let lastYear = cal.date(from: DateComponents(year: 2025, month: 12, day: 30))!
    XCTAssertEqual(
      HealthFormat.dateLabel(lastYear, now: nowDate, calendar: cal, locale: en), "Dec 30, 2025")
  }

  func testAxisLabel() {
    XCTAssertEqual(HealthFormat.axisLabel(10_000, locale: en), "10K")
    XCTAssertEqual(HealthFormat.axisLabel(8, locale: en), "8")
    XCTAssertEqual(HealthFormat.axisLabel(70.5, locale: en), "70.5")
  }

  // MARK: Row

  func testRowShowsLatestValueWithItsDate() {
    let series = HealthSeries(points: [daily(2, 5_000), daily(1, 7_000), daily(0, 4_200)])
    let row = HealthRowModel(
      metric: .steps, series: series, now: nowDate, calendar: cal, locale: en)
    XCTAssertEqual(row.value?.text, "4,200 steps")
    XCTAssertEqual(row.dateLabel, "Today")
    XCTAssertNil(row.shownDateLabel, "today's reading needs no label on the row")
    XCTAssertEqual(row.spark.count, 7)
    XCTAssertEqual(row.spark.last!!, 4_200 / 7_000, accuracy: 0.001)
    XCTAssertNil(row.spark[0], "no data that day: a gap, not a zero")
    XCTAssertEqual(row.accessibilityText, "Steps, 4,200 steps, Today")
  }

  func testStaleAndMissingNeverFakeAZero() {
    let stale = HealthSeries(points: [HealthPoint(date: date(4, 7), value: 20.7)])
    let row = HealthRowModel(
      metric: .bodyFat, series: stale, now: nowDate, calendar: cal, locale: en)
    XCTAssertEqual(row.value?.text, "20.7%")
    XCTAssertEqual(row.dateLabel, "Oct 4")
    XCTAssertEqual(row.shownDateLabel, "Oct 4", "a stale reading says its date")
    XCTAssertFalse(row.hasSpark, "nothing in the last 7 days")

    let none = HealthRowModel(
      metric: .mindfulMinutes, series: nil, now: nowDate, calendar: cal, locale: en)
    XCTAssertNil(none.value)
    XCTAssertEqual(none.dateLabel, "No data")
    XCTAssertEqual(none.shownDateLabel, "No data")
    XCTAssertFalse(none.hasSpark)
    XCTAssertEqual(none.accessibilityText, "Mindful Minutes, no data, No data")
  }

  // MARK: Sparkline

  func testBarsScaleToTheLargestDay() {
    let n = HealthSpark.normalised([2, nil, 4, 8], shape: .bars)
    XCTAssertEqual(n[0]!, 0.25, accuracy: 1e-9)
    XCTAssertNil(n[1])
    XCTAssertEqual(n[3]!, 1, accuracy: 1e-9)
  }

  func testDotsCenterOnTheMiddleOfTheReadings() {
    let n = HealthSpark.normalised([60, nil, 72, 66], shape: .dots)
    XCTAssertEqual(n[0]!, 0, accuracy: 1e-9)
    XCTAssertEqual(n[2]!, 1, accuracy: 1e-9)
    XCTAssertEqual(n[3]!, 0.5, accuracy: 1e-9)
    // A flat week stays flat: tiny noise is not a trend.
    let flat = HealthSpark.normalised([70.0, 70.1, 70.0], shape: .dots).compactMap { $0 }
    XCTAssertTrue(flat.allSatisfy { abs($0 - 0.5) < 0.05 }, "\(flat)")
    XCTAssertEqual(HealthSpark.normalised([70], shape: .dots), [0.5])
    XCTAssertEqual(HealthSpark.normalised([nil, nil], shape: .bars).compactMap { $0 }, [])
  }

  func testSlotsAreTheLastSevenDaysOldestFirst() {
    let series = HealthSeries(points: [
      daily(10, 1), daily(6, 2), daily(0, 3),
      HealthPoint(date: date(16, 7), value: 9),
    ])
    let slots = HealthSpark.slots(series, now: nowDate, calendar: cal)
    XCTAssertEqual(slots.count, 7)
    XCTAssertEqual(slots[0], 2)
    XCTAssertEqual(slots[6], 9, "the last reading of the day wins")
    XCTAssertEqual(slots.compactMap { $0 }.count, 2, "the 10-days-ago point is outside")
  }

  // MARK: Detail statistics

  func testRangeStatisticsAndChange() {
    // 7 days: 1…7 (average 4); the 7 days before: all 2.
    let current = (0..<7).map { daily($0, Double(7 - $0)) }
    let before = (7..<14).map { daily($0, 2) }
    let stats = HealthStats.range(
      HealthSeries(points: current + before), days: 7, now: nowDate, calendar: cal)!
    XCTAssertEqual(stats.count, 7)
    XCTAssertEqual(stats.average, 4, accuracy: 1e-9)
    XCTAssertEqual(stats.low, 1)
    XCTAssertEqual(stats.high, 7)
    XCTAssertEqual(stats.change!, 2, accuracy: 1e-9)
  }

  func testNinetyDayComparisonLoadsTheWholePreviousRange() throws {
    // Steps rose during the previous range: comparing only its final days hides that change.
    // Match the history cutoff used by HealthModel and HealthKitSource.
    let history = HealthWindow(days: MovingAverage.historyDays, now: nowDate, calendar: cal)
    let available = (0..<180).map { back in
      daily(back, back < 103 ? 10_000 : 1_000)
    }
    let loaded = HealthSeries(points: available.filter { history.contains($0.date) })
    let stats = try XCTUnwrap(HealthStats.range(loaded, days: 90, now: nowDate, calendar: cal))
    let previousAverage = (13.0 * 10_000 + 77.0 * 1_000) / 90
    XCTAssertEqual(stats.average, 10_000)
    XCTAssertEqual(try XCTUnwrap(stats.change), 10_000 - previousAverage, accuracy: 0.001)
  }

  func testMissingDaysDoNotCountAsZeroAndChangeNeedsAPreviousWindow() {
    let series = HealthSeries(points: [daily(0, 10), daily(3, 20)])
    let stats = HealthStats.range(series, days: 7, now: nowDate, calendar: cal)!
    XCTAssertEqual(stats.count, 2)
    XCTAssertEqual(stats.average, 15, accuracy: 1e-9)
    XCTAssertNil(stats.change, "nothing in the 7 days before")
    XCTAssertNil(
      HealthStats.range(HealthSeries(points: [daily(20, 5)]), days: 7, now: nowDate, calendar: cal),
      "empty window")
    XCTAssertNotNil(
      HealthStats.range(HealthSeries(points: [daily(20, 5)]), days: 30, now: nowDate, calendar: cal)
    )
  }

  func testWindowsAreWholeDaysEndingToday() {
    let w = HealthWindow(days: 30, now: nowDate, calendar: cal)
    XCTAssertEqual(
      cal.dateComponents([.month, .day], from: w.start), DateComponents(month: 9, day: 17))
    XCTAssertEqual(cal.dateComponents([.day], from: w.start, to: w.end).day, 30)
    XCTAssertTrue(w.contains(date(16, 23)))
    XCTAssertFalse(w.contains(date(17, 0)))
    let p = w.previous(calendar: cal)
    XCTAssertEqual(p.end, w.start)
    XCTAssertEqual(cal.dateComponents([.day], from: p.start, to: p.end).day, 30)
  }

  func testAxisHasFourEvenlySpacedDays() {
    for days in [7, 30, 90] {
      let ticks = HealthStats.axisTicks(days: days, now: nowDate, calendar: cal)
      XCTAssertEqual(ticks.count, 4)
      XCTAssertEqual(ticks.first, HealthWindow(days: days, now: nowDate, calendar: cal).start)
      XCTAssertEqual(ticks.last, cal.startOfDay(for: nowDate), "ends today")
      let gaps = zip(ticks, ticks.dropFirst()).map {
        cal.dateComponents([.day], from: $0, to: $1).day!
      }
      XCTAssertLessThanOrEqual(gaps.max()! - gaps.min()!, 1, "\(days) days: \(gaps)")
    }
    XCTAssertEqual(
      HealthStats.axisTicks(days: 7, now: nowDate, calendar: cal).map {
        cal.component(.day, from: $0)
      }, [10, 12, 14, 16])
  }

  // MARK: Today line

  private func lineSeries(
    steps: Double?, sleepMinutes: Double?, extra: [HealthMetric: HealthSeries] = [:]
  ) -> [HealthMetric: HealthSeries] {
    var out = extra
    if let steps { out[.steps] = HealthSeries(points: [daily(0, steps)]) }
    if let sleepMinutes { out[.sleep] = HealthSeries(points: [daily(0, sleepMinutes)]) }
    return out
  }

  private func line(
    _ selection: HealthSelection, _ series: [HealthMetric: HealthSeries], at when: Date? = nil
  ) -> String? {
    HealthLine.text(
      selection: selection, series: series, now: when ?? nowDate, calendar: cal, units: .metric,
      locale: en)
  }

  func testTodayLineStaysStepsAndSleepByDefault() {
    let d = HealthSelection.default
    XCTAssertEqual(
      line(d, lineSeries(steps: 6_240, sleepMinutes: 432)), "6,240 steps · slept 7 hr 12 min")
    XCTAssertEqual(line(d, lineSeries(steps: 6_240, sleepMinutes: nil)), "6,240 steps")
    XCTAssertEqual(line(d, lineSeries(steps: 0, sleepMinutes: 390)), "slept 6 hr 30 min")
    XCTAssertNil(line(d, lineSeries(steps: 0, sleepMinutes: nil)), "nothing to say: no line")
    XCTAssertNil(line(d, [:]))
    XCTAssertNil(line(d, lineSeries(steps: nil, sleepMinutes: 30)), "a short nap is not a night")
    XCTAssertNil(
      line(d, lineSeries(steps: 6_240, sleepMinutes: 432), at: date(17, 9)),
      "yesterday's numbers never show as today's")
  }

  func testTodayLineIgnoresOrderWhileStepsAndSleepAreShown() {
    let s = HealthSelection(shown: [.weight, .sleep, .steps])
    XCTAssertEqual(HealthLine.metrics(for: s), [.steps, .sleep])
  }

  func testTodayLineUsesTheFirstTwoShownWhenStepsOrSleepIsHidden() {
    var s = HealthSelection.default
    s.hide(.sleep)
    s.add([.daylight, .activeEnergy])
    // The summary fallback follows the same global order as the dashboard.
    XCTAssertEqual(HealthLine.metrics(for: s), [.steps, .weight])
    let series = lineSeries(
      steps: 3_000, sleepMinutes: nil, extra: [.weight: HealthSeries(points: [daily(0, 70.3)])])
    XCTAssertEqual(line(s, series), "3,000 steps · 70.3 kg")

    s.hide(.steps)
    XCTAssertEqual(HealthLine.metrics(for: s), [.weight, .daylight])
    XCTAssertNil(
      line(s, series.filter { $0.key == .steps }), "a metric with no value today stays quiet")

    let w = HealthSelection(shown: [.weight])
    let weighed = [
      HealthMetric.weight: HealthSeries(points: [HealthPoint(date: date(16, 7), value: 70.3)])
    ]
    XCTAssertEqual(line(w, weighed), "70.3 kg")
    XCTAssertNil(
      line(w, [.weight: HealthSeries(points: [HealthPoint(date: date(14, 7), value: 70.3)])]),
      "a stale weigh-in is not today's")
    XCTAssertNil(line(HealthSelection(shown: []), weighed), "everything hidden: no line")
  }

  func testLinePhrases() {
    XCTAssertEqual(HealthFormat.linePhrase(.restingHeartRate, 58, locale: en), "resting 58 bpm")
    XCTAssertEqual(HealthFormat.linePhrase(.activeEnergy, 173, locale: en), "173 kcal active")
    XCTAssertEqual(HealthFormat.linePhrase(.exerciseMinutes, 24, locale: en), "24 min exercise")
    XCTAssertEqual(HealthFormat.linePhrase(.bodyFat, 20.7, locale: en), "20.7% body fat")
  }

  // MARK: Sample data

  func testSampleSeriesAreStableDenseAndTellTheEdgeStates() {
    let a = HealthSampleSeries.all(now: nowDate, calendar: cal)
    XCTAssertEqual(
      a, HealthSampleSeries.all(now: nowDate, calendar: cal), "seeded: the same every run")
    XCTAssertEqual(Set(a.keys), Set(HealthMetric.allCases))
    let steps = a[.steps]!
    XCTAssertEqual(steps.points.count, MovingAverage.historyDays)
    XCTAssertEqual(steps.latest?.date, cal.startOfDay(for: nowDate))
    XCTAssertTrue(steps.points.dropLast().allSatisfy { (3_000...13_000).contains($0.value) })
    XCTAssertTrue(a[.sleep]!.points.allSatisfy { (5.5 * 60...8.5 * 60).contains($0.value) })
    XCTAssertTrue(
      a[.weight]!.points.allSatisfy { (69...73).contains($0.value) && $0.date <= nowDate })
    XCTAssertGreaterThan(a[.weight]!.points.count, 40)
    XCTAssertTrue(a[.restingHeartRate]!.points.allSatisfy { (50...70).contains($0.value) })
    XCTAssertNil(a[.mindfulMinutes]!.latest, "the empty row")
    let stale = HealthRowModel(
      metric: .bodyFat, series: a[.bodyFat], now: nowDate, calendar: cal, locale: en)
    XCTAssertEqual(stale.dateLabel, "Oct 4", "the stale row")
    for m in HealthMetric.allCases where m != .mindfulMinutes {
      XCTAssertNotNil(
        HealthStats.range(a[m]!, days: 90, now: nowDate, calendar: cal), "\(m) has a 90-day range")
    }
  }
}
