#if os(iOS)
  import SwiftUI
  import TodayCore
  import TodayDesignSystem
  import TodayPlatform

  /// A globally ordered read-only dashboard: the numbers, and little else. Manage Metrics owns visibility and order.
  public struct HealthView: View {
    @Environment(\.scenePhase) private var scenePhase
    private let model: HealthModel
    @State private var detail: HealthMetric?
    @State private var adding = false
    @State private var recordsPresented = false
    @State private var draft = HealthSelection.default

    public init(model: HealthModel) {
      self.model = model
    }

    private func manageMetrics() {
      PerformanceTrace.shared.beginPage("health.picker")
      draft = model.selection
      adding = true
    }

    public var body: some View {
      List {
        if !model.isAvailable {
          unavailable
        } else {
          Section {
            if model.selection.shown.isEmpty {
              Text("No metrics shown.").font(.subheadline).foregroundStyle(.secondary)
              Button("Manage Metrics", action: manageMetrics)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(HealthStyle.accent)
            }
            ForEach(model.selection.ordered) { metric in row(metric) }
              .onMove { model.move(from: $0, to: $1) }
          }
          Section {
            // Today shows the simplest view; Apple Health has everything else, one tap away.
            OpenHealthButton(quiet: true)
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
            if model.isSample {
              Text("Sample data. On iPhone this page reads Apple Health.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("health.sample")
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .listSectionSpacing(.compact)
      .performanceDestination("health")
      .toolbar {
        if model.isAvailable {
          ToolbarItem(placement: .topBarLeading) {
            Menu {
              Button("Manage Metrics", systemImage: "slider.horizontal.3", action: manageMetrics)
                .accessibilityIdentifier("health.add")
              if model.recordSource != nil {
                Button("Browse Health Records", systemImage: "list.bullet.rectangle") {
                  recordsPresented = true
                }
                .accessibilityIdentifier("health.records")
              }
            } label: {
              Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("health.more")
          }
        }
      }
      .task(id: scenePhase) {
        guard scenePhase == .active else { return }
        await model.load()
      }
      .refreshable { await model.load() }
      .sheet(isPresented: $recordsPresented) {
        if let source = model.recordSource {
          HealthRecordsView(source: source, runtime: model.runtime)
        }
      }
      .sheet(item: $detail) { metric in
        HealthMetricDetail(
          metric: metric, series: model.series[metric] ?? .empty, now: model.runtime.now(),
          units: model.units, calendar: model.runtime.calendar, locale: model.runtime.locale)
      }
      .sheet(
        isPresented: $adding,
        onDismiss: {
          let next = draft
          Task { await model.customize(next) }
        }
      ) {
        HealthMetricPicker(selection: $draft)
      }
    }

    // MARK: Rows

    private func row(_ metric: HealthMetric) -> some View {
      let item = model.row(for: metric)
      let state = model.state(for: metric)
      var failure: HealthFailure?
      if case .failed(let reason) = state { failure = reason }
      return VStack(alignment: .leading, spacing: 4) {
        Button {
          PerformanceTrace.shared.beginPage("health.detail")
          detail = metric
        } label: {
          HealthRow(item: item, isLoading: state == .loading && item.value == nil)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          failure == nil ? item.accessibilityText : "\(item.accessibilityText). \(Self.cantRead)"
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("health.row.\(metric.rawValue)")
        if let failure {
          // A failed row says so quietly, once, and offers the one action that can help.
          HStack(spacing: 8) {
            Text(failure == .queryFailed ? "Couldn't refresh. Try again." : Self.cantRead)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("health.note.\(metric.rawValue)")
            Spacer(minLength: 4)
            Button(failure == .accessUnanswered ? "Allow" : "Try Again") {
              Task { await model.retry(metric) }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(HealthStyle.accent)
            .accessibilityIdentifier("health.action.\(metric.rawValue)")
          }
        }
      }
      // About 60 pt: name, value line, and 6 pt above and below (the default cell padding makes rows 90 pt).
      .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 16))
      // Hide only hides the row; Apple Health keeps everything. Same icon-only look as every swipe action.
      .swipeActions(edge: .trailing) {
        Button {
          withAnimation(.snappy) { model.hide(metric) }
        } label: {
          Label("Hide", systemImage: "eye.slash.fill").labelStyle(.iconOnly)
        }
        .tint(Color(.systemGray))
      }
      .accessibilityAction(named: "Move Up") { model.nudge(metric, by: -1) }
      .accessibilityAction(named: "Move Down") { model.nudge(metric, by: 1) }
      .accessibilityAction(named: "Move to Top") { model.moveToTop(metric) }
      .contextMenu {
        Button {
          model.moveToTop(metric)
        } label: {
          Label("Move to Top", systemImage: "arrow.up.to.line")
        }
        .disabled(model.selection.ordered.first == metric)
        Button {
          withAnimation(.snappy) { model.hide(metric) }
        } label: {
          Label("Hide", systemImage: "eye.slash")
        }
        Button {
          withAnimation(.snappy) { model.nudge(metric, by: -1) }
        } label: {
          Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(model.selection.ordered.first == metric)
        Button {
          withAnimation(.snappy) { model.nudge(metric, by: 1) }
        } label: {
          Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(model.selection.ordered.last == metric)
      }
    }

    static let cantRead = "Can't read this yet. Check Health access."

    private var unavailable: some View {
      VStack(spacing: 8) {
        Image(systemName: "heart.slash").font(.largeTitle).foregroundStyle(.secondary)
        Text("Health Isn't Available").font(.title3.weight(.semibold))
        Text("This device doesn't have Apple Health.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 40)
      .accessibilityElement(children: .combine)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
    }
  }

  /// One row: name over the latest value (large number, small unit, a date only when it isn't today's), and the
  /// sparkline on the right.
  private struct HealthRow: View {
    let item: HealthRowModel
    /// Waiting for this metric's first answer: a small spinner in place of the number (never over the whole sheet).
    var isLoading = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(item.metric.title)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
          HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let value = item.value {
              ForEach(Array(value.parts.enumerated()), id: \.offset) { index, part in
                Text(part.number)
                  .font(.system(.title2, design: .rounded).weight(.semibold))
                  .monospacedDigit()
                  .padding(.leading, index > 0 ? 3 : 0)
                if !part.unit.isEmpty {
                  Text(part.unit).font(.subheadline).foregroundStyle(.secondary)
                }
              }
            } else if isLoading {
              ProgressView().controlSize(.small).frame(height: 28)
                .accessibilityIdentifier("health.row.loading.\(item.metric.rawValue)")
            } else {
              Text("—").font(.system(.title2, design: .rounded).weight(.semibold)).foregroundStyle(
                .secondary)
            }
            if !isLoading, let date = item.shownDateLabel {
              Text(date)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            }
          }
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        }
        Spacer(minLength: 8)
        if !typeSize.isAccessibilitySize {
          HealthSparkline(values: item.spark, shape: item.metric.shape)
            .frame(width: 68, height: 28)
        }
      }
      .frame(minHeight: 48)
      .contentShape(Rectangle())
    }
  }
#endif
