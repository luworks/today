#if os(iOS)
  import SwiftUI
  import UIKit
  import os.signpost

  /// Opt-in benchmark probes. Times are app-side layout proxies, never touch-to-photon measurements.
  @MainActor @Observable
  public final class PerformanceTrace {
    public static let shared = PerformanceTrace()
    public static let enabled = ProcessInfo.processInfo.arguments.contains("-performanceTrace")
    private static var pageContext: String {
      ProcessInfo.processInfo.arguments.contains("-performancePageRevisits")
        ? "first_cycle_plus_two_revisits" : "unclassified"
    }
    private let log = OSLog(subsystem: "com.luworks.today", category: "PerformanceTrace")
    private struct Pending {
      let name: String
      let destination: String?
      let start: UInt64
    }
    private var pending: Pending?
    private var phaseMarks: [String: UInt64] = [:]
    private var sequence = 0
    private var pageVisits: [String: Int] = [:]
    public private(set) var bootstrapComplete = false
    public private(set) var launchComplete = false
    public private(set) var generation = 0
    public private(set) var report = ""
    /// Composer and keyboard timings relative to the latest `begin`, appended to its sample (opt-in only).
    private var lastStart: UInt64?
    private var extras = ""
    /// The shared instance lives for the process; its keyboard observers are kept, never removed.
    private var observers: [NSObjectProtocol] = []

    private init() {
      guard Self.enabled else { return }
      observers = [
        (UIResponder.keyboardWillShowNotification, "keyboard_will_show"),
        (UIResponder.keyboardDidShowNotification, "keyboard_did_show"),
      ].map { name, event in
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in MainActor.assumeIsolated { self?.mark(event) }
        }
      }
    }

    /// Events whose first occurrence after a `begin` is added to that sample, in ms since the begin.
    private static let relative: Set = [
      "first_frame", "chat.revealed", "chat.shown", "chat.native_shown", "chat.composer_laid_out",
      "chat.focus_end",
      "keyboard_will_show", "keyboard_did_show",
    ]

    private func since(_ event: String, at now: UInt64) {
      let key = event.replacingOccurrences(of: "chat.", with: "")
      guard let lastStart, !extras.contains(";\(key)_ms=") else { return }
      let field = ";\(key)_ms=\(Double(now - lastStart) / 1_000_000)"
      extras += field
      if pending == nil { report += field }
    }

    public func mark(_ event: String) {
      guard Self.enabled else { return }
      let now = DispatchTime.now().uptimeNanoseconds
      if ["store_start", "store_ready", "bootstrap_start", "bootstrap_complete"].contains(event) {
        phaseMarks[event] = now
      }
      os_signpost(
        .event, log: log, name: "PerformanceEndpoint", "%{public}@ uptime_ns=%llu",
        event as NSString, now)
      print("PERF_TRACE v=1 event=\(event) uptime_ns=\(now)")
      if Self.relative.contains(event) { since(event, at: now) }
    }

    public func beginLaunch() {
      guard Self.enabled else { return }
      begin("app_init_to_content_layout", destination: nil)
    }

    public func finishBootstrap() {
      guard Self.enabled else { return }
      mark("bootstrap_complete")
      bootstrapComplete = true
    }

    public func begin(_ name: String, destination: String?) {
      guard Self.enabled else { return }
      // A superseded operation is not silently turned into a successful sample.
      if let pending { mark("cancel.\(pending.name)") }
      pending = Pending(
        name: name, destination: destination, start: DispatchTime.now().uptimeNanoseconds)
      lastStart = pending?.start
      extras = ""
      generation += 1
      mark("begin.\(name)")
      if PageResourceTrace.enabled, let pending {
        PageResourceTrace.shared.begin(generation: generation, start: pending.start)
      }
    }

    public func wantsLayout(_ route: String) -> Bool {
      guard Self.enabled, bootstrapComplete, let pending else { return false }
      return pending.destination == nil || pending.destination == route
    }

    public func finishLayout(_ route: String, generation expected: Int) {
      guard expected == generation, wantsLayout(route), let pending else { return }
      let end = DispatchTime.now().uptimeNanoseconds
      self.pending = nil
      if pending.name == "app_init_to_content_layout" { launchComplete = true }
      sequence += 1
      let ms = Double(end - pending.start) / 1_000_000
      report =
        "v=1;seq=\(sequence);name=\(pending.name);route=\(route);start_ns=\(pending.start);end_ns=\(end);ms=\(ms)"
        + extras
      if pending.name.hasPrefix("page.") {
        let visit = (pageVisits[route] ?? 0) + 1
        pageVisits[route] = visit
        report += ";page_context=\(Self.pageContext);route_visit=\(visit)"
      }
      if pending.name == "app_init_to_content_layout",
        let storeStart = phaseMarks["store_start"], let storeReady = phaseMarks["store_ready"],
        let bootstrapStart = phaseMarks["bootstrap_start"],
        let bootstrapEnd = phaseMarks["bootstrap_complete"]
      {
        report += ";init_to_store_ms=\(Double(storeStart - pending.start) / 1_000_000)"
        report += ";store_ms=\(Double(storeReady - storeStart) / 1_000_000)"
        report += ";bootstrap_ms=\(Double(bootstrapEnd - bootstrapStart) / 1_000_000)"
        report += ";post_bootstrap_layout_ms=\(Double(end - bootstrapEnd) / 1_000_000)"
      }
      os_signpost(.event, log: log, name: "PerformanceSample", "%{public}@", report as NSString)
      print("PERF_SAMPLE_APP \(report)")
      if PageResourceTrace.enabled {
        let finishedSequence = sequence
        PageResourceTrace.shared.layout(
          generation: expected, sequence: finishedSequence, name: pending.name, route: route,
          visit: pageVisits[route] ?? 0, end: end
        ) { [weak self] encoded in
          guard let self, self.sequence == finishedSequence, self.generation == expected else {
            return
          }
          // Publish only after the original endpoint and fixed resource window are frozen.
          self.report += ";resource_b64=\(encoded)"
        }
      }
    }
  }

  /// Attached to the real content's background, after its bootstrap state has been published.
  /// Two display-link callbacks leave a display opportunity between layout and the endpoint;
  /// neither callback proves compositor presentation, animation completion or asynchronous sync.
  public struct PerformanceContentProbe: UIViewRepresentable {
    public init(route: String, generation: Int, bootstrapComplete: Bool) {
      self.route = route
      self.generation = generation
      self.bootstrapComplete = bootstrapComplete
    }
    public let route: String
    public let generation: Int
    public let bootstrapComplete: Bool

    public func makeUIView(context: Context) -> ProbeView { ProbeView() }
    public func updateUIView(_ view: ProbeView, context: Context) {
      view.arm(route: route, generation: generation, ready: bootstrapComplete)
    }
    public static func dismantleUIView(_ view: ProbeView, coordinator: ()) { view.stop() }

    public final class ProbeView: UIView {
      private var link: CADisplayLink?
      private var route = ""
      private var generation = -1
      private var ticks = 0

      func arm(route: String, generation: Int, ready: Bool) {
        guard ready, PerformanceTrace.shared.wantsLayout(route) else {
          stop()
          return
        }
        guard self.route != route || self.generation != generation || link == nil else { return }
        stop()
        self.route = route
        self.generation = generation
        ticks = 0
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
      }

      @objc private func tick() {
        guard window != nil, bounds.width > 0, bounds.height > 0,
          window?.windowScene?.activationState == .foregroundActive
        else { return }
        // Observe normal layout; never force the app to perform layout early for the benchmark.
        guard !isHidden, let window else { return }
        // A sheet can leave its presenting root mounted and nonhidden underneath it.
        var foreground = window.rootViewController
        while let presented = foreground?.presentedViewController { foreground = presented }
        guard let foregroundView = foreground?.viewIfLoaded, isDescendant(of: foregroundView),
          convert(bounds, to: window).intersects(window.bounds)
        else { return }
        ticks += 1
        // The first callback after the content is on screen: about when its first frame was handed to display.
        if ticks == 1 { PerformanceTrace.shared.mark("first_frame") }
        if ticks >= 2 {
          PerformanceTrace.shared.finishLayout(route, generation: generation)
          stop()
        }
      }

      func stop() {
        link?.invalidate()
        link = nil
      }
    }
  }

  /// Page timers start in the action (or a control's binding setter), before navigation mutates state.
  /// The endpoint describes content geometry, not async data readiness or animation completion.
  extension PerformanceTrace {
    public func beginPage(_ route: String) {
      begin("page.\(route)", destination: route)
    }
  }

  extension Binding where Value: Equatable {
    @MainActor
    public func performanceAction(_ route: @escaping (Value) -> String?) -> Binding<Value> {
      guard PerformanceTrace.enabled else { return self }
      return Binding(
        get: { wrappedValue },
        set: { value in
          if value != wrappedValue, let destination = route(value) {
            PerformanceTrace.shared.beginPage(destination)
          }
          wrappedValue = value
        })
    }
  }

  private struct PerformanceDestination: ViewModifier {
    public let route: String
    public func body(content: Content) -> some View {
      content.background {
        if PerformanceTrace.enabled {
          PerformanceContentProbe(
            route: route, generation: PerformanceTrace.shared.generation,
            bootstrapComplete: PerformanceTrace.shared.bootstrapComplete)
        }
      }
      .overlay(alignment: .topLeading) {
        if PerformanceTrace.enabled {
          Text(PerformanceTrace.shared.report).font(.system(size: 1)).opacity(0.01)
            .accessibilityIdentifier("performance.trace")
            .accessibilityLabel(PerformanceTrace.shared.report)
            .allowsHitTesting(false)
        }
      }
    }
  }

  extension View {
    /// Apply to the destination's List/Form/content, never the obscured presenting root.
    public func performanceDestination(_ route: String) -> some View {
      modifier(PerformanceDestination(route: route))
    }
  }

  extension View {
    /// Keep NavigationLink's production structure and state ownership unchanged.
    /// Opt-in runs begin on the real navigation tap, never destination onAppear.
    @ViewBuilder
    public func performanceNavigationAction(_ route: String) -> some View {
      if PerformanceTrace.enabled {
        simultaneousGesture(TapGesture().onEnded { PerformanceTrace.shared.beginPage(route) })
      } else {
        self
      }
    }
  }

  /// Opt-in navigation owns its activation binding so beginPage precedes the state write.
  /// Without tracing, the caller's original NavigationLink is returned unchanged.
  private struct PerformanceControlledNavigation<Destination: View, LinkLabel: View>: ViewModifier {
    public let route: String
    public let destination: () -> Destination
    public let label: () -> LinkLabel
    @State private var isActive = false

    public init(
      route: String, destination: @escaping () -> Destination, label: @escaping () -> LinkLabel
    ) {
      self.route = route
      self.destination = destination
      self.label = label
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
      if PerformanceTrace.enabled {
        Button {
          PerformanceTrace.shared.beginPage(route)
          isActive = true
        } label: {
          label()
        }
        .navigationDestination(isPresented: $isActive) { destination() }
      } else {
        content
      }
    }
  }

  extension View {
    public func performanceControlledNavigation<Destination: View, LinkLabel: View>(
      _ route: String,
      @ViewBuilder destination: @escaping () -> Destination,
      @ViewBuilder label: @escaping () -> LinkLabel
    ) -> some View {
      modifier(
        PerformanceControlledNavigation(route: route, destination: destination, label: label))
    }
  }
#endif
