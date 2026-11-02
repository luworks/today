#if os(iOS)
  import Foundation
  import Darwin

  #if DEBUG
    /// Separate opt-in resource cohort. Sampling maxima are not exact allocation peaks or leak evidence.
    /// All mutable sampling state belongs to the serial queue; latency endpoints remain unchanged.
    public final class PageResourceTrace: @unchecked Sendable {
      public static let shared = PageResourceTrace()
      public static let enabled: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        return ["-performanceResources", "-performanceTrace", "-uiTesting"].allSatisfy(
          arguments.contains)
      }()
      private let queue = DispatchQueue(label: "com.luworks.today.page-resources", qos: .utility)
      private let interval: UInt64 = 100_000_000
      private let dwell: UInt64 = 1_000_000_000
      private struct Sample: Encodable {
        let ns: UInt64
        let sample_gap_ns: UInt64?
        let kern_return: Int32
        let response_count: UInt32
        let valid: Bool
        let phys_footprint_bytes: UInt64?
        let resident_size_bytes: UInt64?
        let error: String?

        private enum CodingKeys: String, CodingKey {
          case ns, sample_gap_ns, kern_return, response_count, valid
          case phys_footprint_bytes, resident_size_bytes, error
        }
        func encode(to encoder: Encoder) throws {
          var container = encoder.container(keyedBy: CodingKeys.self)
          try container.encode(ns, forKey: .ns)
          try container.encode(sample_gap_ns, forKey: .sample_gap_ns)
          try container.encode(kern_return, forKey: .kern_return)
          try container.encode(response_count, forKey: .response_count)
          try container.encode(valid, forKey: .valid)
          try container.encode(phys_footprint_bytes, forKey: .phys_footprint_bytes)
          try container.encode(resident_size_bytes, forKey: .resident_size_bytes)
          try container.encode(error, forKey: .error)
        }
      }
      private struct Window {
        let generation: Int
        let start: UInt64
        var layout: UInt64?
        var yearCache: YearCacheTrace.Snapshot?
        var sequence: Int?
        var route: String?
        var name: String?
        var visit = 0
        var visitBasis = "page_route"
        var samples: [Sample] = []
        var completion: (@MainActor @Sendable (String) -> Void)?
      }
      private struct Summary: Encodable {
        let min: UInt64
        let median: Double
        let max: UInt64
      }
      private struct Payload: Encodable {
        let schema = 1
        let cohort = "resources_fixed_postlayout_1s"
        let status: String
        let seq: Int
        let name: String
        let route: String
        let route_visit: Int
        let visit_basis: String
        let pid: Int32
        let start_ns: UInt64
        let layout_ns: UInt64
        let window_end_ns: UInt64
        let collection_end_ns: UInt64
        let period_ms: Double
        let samples: [Sample]
        let valid_count: Int
        let error_count: Int
        let postlayout_valid_count: Int
        let sampled_max_phys_footprint_bytes: UInt64?
        let postlayout_phys_footprint_bytes: Summary?
        let postlayout_resident_size_bytes: Summary?
        let year_cache: YearCacheTrace.Snapshot?
      }
      private var window: Window?
      private var operationVisits: [String: Int] = [:]

      public func begin(generation: Int, start: UInt64) {
        guard Self.enabled else { return }
        queue.async { [self] in
          if let old = window {
            print("PERF_RESOURCE_CANCEL generation=\(old.generation) reason=superseded")
          }
          window = Window(generation: generation, start: start)
          sample(generation: generation)
        }
      }

      public func layout(
        generation: Int, sequence: Int, name: String, route: String, visit: Int, end: UInt64,
        completion: @escaping @MainActor @Sendable (String) -> Void
      ) {
        guard Self.enabled else { return }
        queue.async { [self] in
          guard window?.generation == generation else { return }
          window?.layout = end
          // Queue observation may follow end; consumers must filter events at layout_ns.
          window?.yearCache = YearCacheTrace.snapshot()
          window?.sequence = sequence
          window?.route = route
          window?.name = name
          if visit > 0 {
            window?.visit = visit
            window?.visitBasis = "page_route"
          } else {
            let next = (operationVisits[name] ?? 0) + 1
            operationVisits[name] = next
            window?.visit = next
            window?.visitBasis = "layout_operation_name"
          }
          window?.completion = completion
        }
      }

      private func sample(generation: Int) {
        guard var current = window, current.generation == generation else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
          MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
          pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
          }
        }
        // phys_footprint is included in revision 1. Never read a truncated response as zero bytes.
        let requiredBytes = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint)
          .map { $0 + MemoryLayout<mach_vm_size_t>.size }
        let complete =
          requiredBytes.map { Int(count) * MemoryLayout<integer_t>.size >= $0 } ?? false
        let responseValid = result == KERN_SUCCESS && complete
        let valid = responseValid && info.phys_footprint > 0 && info.resident_size > 0
        let error: String? =
          result != KERN_SUCCESS
          ? "task_info_failed"
          : (!complete
            ? "short_or_unsupported_response" : (valid ? nil : "nonpositive_memory_value"))
        current.samples.append(
          Sample(
            ns: now, sample_gap_ns: current.samples.last.map { now - $0.ns },
            kern_return: result, response_count: count, valid: valid,
            phys_footprint_bytes: valid ? UInt64(info.phys_footprint) : nil,
            resident_size_bytes: valid ? UInt64(info.resident_size) : nil, error: error))
        window = current
        if let layout = current.layout, now >= layout + dwell {
          finish(current, observedEnd: now)
          window = nil
        } else {
          queue.asyncAfter(deadline: .now() + .nanoseconds(Int(interval))) { [self] in
            sample(generation: generation)
          }
        }
      }

      private func summary(_ values: [UInt64]) -> Summary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median =
          sorted.count.isMultiple(of: 2)
          ? (Double(sorted[middle - 1]) + Double(sorted[middle])) / 2 : Double(sorted[middle])
        return Summary(min: sorted[0], median: median, max: sorted[sorted.count - 1])
      }

      private func finish(_ current: Window, observedEnd: UInt64) {
        guard let layout = current.layout, let sequence = current.sequence,
          let route = current.route, let name = current.name, let completion = current.completion
        else { return }
        let deadline = layout + dwell
        let measured = current.samples.filter { $0.ns <= deadline }
        let postlayout = measured.filter { $0.ns >= layout && $0.valid }
        let valid = measured.filter(\.valid)
        let errors = current.samples.filter { !$0.valid }.count
        let payload = Payload(
          status: errors == 0 && !valid.isEmpty && !postlayout.isEmpty
            ? "complete" : "missing_or_error",
          seq: sequence, name: name, route: route, route_visit: current.visit,
          visit_basis: current.visitBasis, pid: getpid(), start_ns: current.start,
          layout_ns: layout, window_end_ns: deadline, collection_end_ns: observedEnd,
          period_ms: Double(interval) / 1_000_000, samples: current.samples,
          valid_count: valid.count,
          error_count: errors, postlayout_valid_count: postlayout.count,
          sampled_max_phys_footprint_bytes: valid.compactMap(\.phys_footprint_bytes).max(),
          postlayout_phys_footprint_bytes: summary(postlayout.compactMap(\.phys_footprint_bytes)),
          postlayout_resident_size_bytes: summary(postlayout.compactMap(\.resident_size_bytes)),
          year_cache: current.yearCache)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else {
          print("PERF_RESOURCE_ERROR sequence=\(sequence) reason=encoding_failed")
          return
        }
        let encoded = data.base64EncodedString()
        Task { @MainActor in completion(encoded) }
      }
    }
  #else
    /// Resource diagnostics are absent from Release; normal navigation keeps the same API.
    public final class PageResourceTrace: @unchecked Sendable {
      public static let shared = PageResourceTrace()
      public static let enabled = false
      public func begin(generation: Int, start: UInt64) {}
      public func layout(
        generation: Int, sequence: Int, name: String, route: String, visit: Int, end: UInt64,
        completion: @escaping @MainActor @Sendable (String) -> Void
      ) {}
    }
  #endif
#endif
