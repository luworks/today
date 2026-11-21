import XCTest

@testable import TodayCore
@testable import TodayData

final class HealthLoadingTests: XCTestCase {
  private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func update(_ change: (inout T) -> Void) {
      lock.lock()
      change(&value)
      lock.unlock()
    }
    var current: T {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  /// Answers from a table; a metric not in it has no data. Records what was asked, in order.
  private struct FakeSource: HealthSource {
    var data: [HealthMetric: HealthSeries] = [:]
    var requests = Box<[[HealthMetric]]>([])
    var isAvailable: Bool { true }

    func requestAccess(for metrics: [HealthMetric]) async {
      requests.update { $0.append(metrics) }
    }

    func series(for metrics: [HealthMetric], days: Int, now: Date) async -> [HealthMetric:
      HealthSeries]
    {
      Dictionary(uniqueKeysWithValues: metrics.map { ($0, data[$0] ?? .empty) })
    }
  }

  private let now = Date(timeIntervalSince1970: 1_792_000_000)
  private func series(_ value: Double) -> HealthSeries {
    HealthSeries(points: [HealthPoint(date: now, value: value)])
  }

  // MARK: Access

  func testAccessIsRequestedOncePerNewBatch() async {
    let base = FakeSource()
    let gate = HealthAccessGate()
    let first = await gate.request([.steps, .sleep], source: base, timeout: 1)
    let again = await gate.request([.steps, .sleep], source: base, timeout: 1)
    let more = await gate.request([.steps, .bodyFat], source: base, timeout: 1)
    XCTAssertEqual([first, again, more], [.answered, .answered, .answered])
    XCTAssertEqual(
      base.requests.current, [[.steps, .sleep], [.bodyFat]],
      "second call asks for nothing, third only for the new type")
  }

  func testDeniedAccessStillGivesTheEmptyRow() async {
    // Health says nothing about a denied read: the request answers, the query returns no samples.
    let base = FakeSource(data: [.steps: series(5000)])
    let results = Box<[HealthMetric: HealthMetricState]>([:])
    let access = await HealthLoader.load(
      [.steps, .restingHeartRate], source: base, gate: HealthAccessGate(), days: 90, now: now,
      timeout: 1
    ) { metric, result, access in
      results.update {
        $0[metric] = HealthMetricState.settled(result, access: access, hadData: false)
      }
    }
    XCTAssertEqual(access, .answered)
    XCTAssertEqual(results.current[.steps], .loaded)
    XCTAssertEqual(
      results.current[.restingHeartRate], .loaded,
      "no samples: an empty row ('No data'), not an error")
  }

  private struct DiagnosticSource: HealthSource, HealthQuerySource {
    var isAvailable: Bool { true }
    func requestAccess(for metrics: [HealthMetric]) async {}
    func series(for metrics: [HealthMetric], days: Int, now: Date) async -> [HealthMetric:
      HealthSeries]
    {
      // Optional diagnostic queries must not silently turn errors into empty results.
      [:]
    }
    func query(_ metric: HealthMetric, days: Int, now: Date) async throws -> HealthSeries {
      if metric == .steps { throw CocoaError(.fileReadUnknown) }
      if metric == .weight { throw CancellationError() }
      return .empty
    }
  }

  func testDiagnosticErrorsDifferFromEmptyAndCancellationSettlesWithoutFailure() async {
    let results = Box<[HealthMetric: HealthFetchResult]>([:])
    await HealthLoader.fetch(
      [.steps, .sleep, .weight], source: DiagnosticSource(), days: 7, now: now
    ) { metric, result in
      results.update { $0[metric] = result }
    }
    XCTAssertEqual(results.current[.steps], .queryFailed)
    XCTAssertEqual(results.current[.sleep], .series(.empty))
    XCTAssertEqual(results.current[.weight], .cancelled)
    XCTAssertEqual(
      HealthMetricState.settled(.queryFailed, access: .answered, hadData: false),
      .failed(.queryFailed))
    XCTAssertEqual(HealthMetricState.settled(.cancelled, access: .answered, hadData: false), .idle)
    XCTAssertEqual(HealthMetricState.settled(.cancelled, access: .answered, hadData: true), .loaded)
  }

  // MARK: Row state

  func testSettledStates() {
    let data = HealthFetchResult.series(series(1))
    let empty = HealthFetchResult.series(.empty)
    XCTAssertEqual(HealthMetricState.settled(data, access: .answered, hadData: true), .loaded)
    XCTAssertEqual(HealthMetricState.settled(data, access: .unanswered, hadData: true), .loaded)
    XCTAssertEqual(HealthMetricState.settled(empty, access: .answered, hadData: false), .loaded)
    XCTAssertEqual(
      HealthMetricState.settled(empty, access: .unanswered, hadData: false),
      .failed(.accessUnanswered))
    XCTAssertEqual(
      HealthMetricState.settled(.stalled, access: .answered, hadData: false), .failed(.stalled))
    XCTAssertEqual(
      HealthMetricState.settled(.stalled, access: .answered, hadData: true), .loaded,
      "a stall keeps old numbers on screen")
  }
}
