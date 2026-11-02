#if os(iOS)
  import Foundation
  import MetricKit
  import os.signpost

  /// A closed schema: no raw payload, metadata, identifiers, dates, strings or error descriptions.
  struct DiagnosticSample: Encodable, Sendable {
    struct LaunchBucket: Encodable, Sendable {
      let lowerSeconds: Double
      let upperSeconds: Double
      let count: Int

      init?(lowerSeconds: Double, upperSeconds: Double, count: Int) {
        guard lowerSeconds.isFinite, upperSeconds.isFinite,
          lowerSeconds >= 0, upperSeconds >= lowerSeconds, count > 0
        else { return nil }
        self.lowerSeconds = lowerSeconds
        self.upperSeconds = upperSeconds
        self.count = count
      }
    }

    let cpuSeconds: Double?
    let peakMemoryBytes: Double?
    let launchTimeToFirstDraw: [LaunchBucket]

    init(cpuSeconds: Double?, peakMemoryBytes: Double?, launchTimeToFirstDraw: [LaunchBucket]) {
      self.cpuSeconds = Self.nonnegative(cpuSeconds)
      self.peakMemoryBytes = Self.nonnegative(peakMemoryBytes)
      self.launchTimeToFirstDraw = Array(launchTimeToFirstDraw.prefix(64))
    }

    private static func nonnegative(_ value: Double?) -> Double? {
      guard let value, value.isFinite, value >= 0 else { return nil }
      return value
    }

    var isEmpty: Bool {
      cpuSeconds == nil && peakMemoryBytes == nil && launchTimeToFirstDraw.isEmpty
    }

    /// Read SDK properties directly; never serialize or traverse arbitrary MetricKit keys.
    init(payload: MXMetricPayload) {
      var buckets: [LaunchBucket] = []
      if let histogram = payload.applicationLaunchMetrics?.histogrammedTimeToFirstDraw {
        let enumerator = histogram.bucketEnumerator
        for _ in 0..<64 {
          guard let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> else {
            break
          }
          if let value = LaunchBucket(
            lowerSeconds: bucket.bucketStart.converted(to: .seconds).value,
            upperSeconds: bucket.bucketEnd.converted(to: .seconds).value,
            count: bucket.bucketCount
          ) {
            buckets.append(value)
          }
        }
      }
      self.init(
        cpuSeconds: payload.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value,
        peakMemoryBytes: payload.memoryMetrics?.peakMemoryUsage.converted(to: .bytes).value,
        launchTimeToFirstDraw: buckets
      )
    }
  }

  /// In-memory, bounded report. Restarting the app discards received samples.
  struct DiagnosticReport: Encodable, Sendable {
    let schemaVersion = 1
    private(set) var samples: [DiagnosticSample] = []

    mutating func append(_ values: [DiagnosticSample]) {
      samples = Array((samples + values.filter { !$0.isEmpty }).suffix(7))
    }

    func data() throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return try encoder.encode(self)
    }
  }

  /// Composition root retains this instance and calls start() once at launch.
  /// Only an explicit Settings export tap may call exportURL(); this type never uploads.
  @MainActor
  public final class LocalDiagnostics: NSObject, MXMetricManagerSubscriber {
    private var started = false
    private var report = DiagnosticReport()
    private let log = OSLog(subsystem: "com.luworks.today", category: "LocalDiagnostics")

    public override init() { super.init() }

    public func start() {
      guard !started else { return }
      started = true
      MXMetricManager.shared.add(self)
      os_signpost(.event, log: log, name: "DiagnosticsStarted")
      os_log("Local diagnostics started", log: log, type: .info)
    }

    public func stop() {
      guard started else { return }
      MXMetricManager.shared.remove(self)
      started = false
    }

    // MetricKit may invoke this on a background queue. SDK objects stay on that queue;
    // only immutable checked Sendable numeric values cross to the main actor.
    nonisolated public func didReceive(_ payloads: [MXMetricPayload]) {
      let values = payloads.suffix(7).map { DiagnosticSample(payload: $0) }
      Task { @MainActor [weak self] in
        guard let self, self.started else { return }
        self.report.append(values)
        os_signpost(.event, log: self.log, name: "DiagnosticsReceived")
        os_log("Metric reports received: %ld", log: self.log, type: .info, values.count)
      }
    }

    // Crash/hang diagnostics can include stacks and arbitrary text: intentionally discard them.
    nonisolated public func didReceive(_ payloads: [MXDiagnosticPayload]) {}

    /// Creates/replaces one sanitized local file. No log archive or raw MetricKit payload is exported.
    public func exportURL(to url: URL) throws -> URL {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try report.data()
      #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
      #else
        try data.write(to: url, options: .atomic)
      #endif
      os_signpost(.event, log: log, name: "DiagnosticsExported")
      os_log("Sanitized diagnostics exported locally", log: log, type: .info)
      return url
    }
  }

#endif
