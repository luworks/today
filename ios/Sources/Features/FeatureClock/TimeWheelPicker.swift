#if os(iOS)
  import SwiftUI
  import TodayCore
  import UIKit
  import UIKit.UIGestureRecognizerSubclass

  /// What the custom wheel tells its owner, with the touch or frame time (seconds, `CACurrentMediaTime` clock).
  package enum TimeWheelEvent: Equatable, Sendable {
    /// A finger touched a column; `moving` = it stopped a coast.
    case touchDown(moving: Bool)
    /// The finger lifted and the column keeps moving until `settled`.
    case liftedWhileMoving
    case reversal
    /// A column came to rest; the time is now `minutes` (minutes of the day).
    case settled(minutes: Int)
  }

  /// The experimental hour and minute wheel (alarm wheel lab, variants B and C): the same rows, font, band and
  /// haptics in both; `adaptiveMinutes` turns on the speed-sensitive minute spacing. The physics is
  /// `TimeWheelColumn` (TodayCore); this view only draws it and feeds it touches. Minutes of the day in and out, so it
  /// can later serve start and end times too.
  package struct TimeWheelPicker: UIViewRepresentable {
    @Binding var minutes: Int
    /// Change it to show `minutes` again (a new trial), stopping any motion.
    var resetID: Int
    var adaptiveMinutes: Bool
    /// The minute column's step: 1 = every minute, 5 = 00, 05 … 55. `minutes` must be a multiple of it.
    var minuteStep: Int
    var locale: Locale
    var onEvent: (TimeWheelEvent, Double) -> Void

    package init(
      minutes: Binding<Int>, resetID: Int = 0, adaptiveMinutes: Bool, minuteStep: Int = 1,
      locale: Locale, onEvent: @escaping (TimeWheelEvent, Double) -> Void = { _, _ in }
    ) {
      _minutes = minutes
      self.resetID = resetID
      self.adaptiveMinutes = adaptiveMinutes
      self.minuteStep = minuteStep
      self.locale = locale
      self.onEvent = onEvent
    }

    package func makeCoordinator() -> Coordinator { Coordinator() }

    package func makeUIView(context: Context) -> TimeWheelView {
      let view = TimeWheelView(
        minutes: minutes, adaptive: adaptiveMinutes, minuteStep: minuteStep, locale: locale)
      let coordinator = context.coordinator
      coordinator.resetID = resetID
      coordinator.parent = self
      view.onChange = { minutes in coordinator.parent?.minutes = minutes }
      view.onEvent = { event, time in coordinator.parent?.onEvent(event, time) }
      return view
    }

    package func updateUIView(_ view: TimeWheelView, context: Context) {
      context.coordinator.parent = self
      view.configure(adaptive: adaptiveMinutes, locale: locale)
      if context.coordinator.resetID != resetID {
        context.coordinator.resetID = resetID
        view.show(minutes: minutes)
      }
    }

    package static func dismantleUIView(_ view: TimeWheelView, coordinator: Coordinator) {
      view.stop()
    }

    @MainActor package final class Coordinator {
      var parent: TimeWheelPicker?
      var resetID = 0
    }
  }

  /// Hour, minute and (on a 12-hour clock) AM/PM columns over one shared selection band.
  package final class TimeWheelView: UIView {
    var onChange: (Int) -> Void = { _ in }
    var onEvent: (TimeWheelEvent, Double) -> Void = { _, _ in }

    private let band = UIView()
    private let hours: TimeWheelColumnView
    private let mins: TimeWheelColumnView
    private let period = PeriodColumnView()
    private var locale: Locale
    private let minuteStep: Int

    init(minutes: Int, adaptive: Bool, minuteStep: Int, locale: Locale) {
      self.locale = locale
      self.minuteStep = max(minuteStep, 1)
      hours = TimeWheelColumnView(kind: .hour, value: minutes / 60, adaptive: false)
      mins = TimeWheelColumnView(
        kind: .minute, value: minutes % 60 / self.minuteStep, adaptive: adaptive && minuteStep == 1,
        step: self.minuteStep)
      super.init(frame: .zero)
      band.backgroundColor = .tertiarySystemFill
      band.layer.cornerRadius = 8
      band.layer.cornerCurve = .continuous
      band.isUserInteractionEnabled = false
      addSubview(band)
      for column in [hours, mins] {
        addSubview(column)
        column.onValue = { [weak self] in self?.valueChanged() }
        column.onEvent = { [weak self] event, time in self?.columnEvent(event, time) }
      }
      addSubview(period)
      period.onToggle = { [weak self] time in self?.togglePeriod(at: time) }
      hours.uses24Hour = Self.uses24Hour(locale)
      period.locale = locale
      period.isHidden = hours.uses24Hour
      period.isPM = hours.value >= 12
      registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
        (view: TimeWheelView, _: UITraitCollection) in view.setNeedsLayout()
      }
    }

    required init?(coder: NSCoder) { fatalError() }

    override package var intrinsicContentSize: CGSize {
      CGSize(width: UIView.noIntrinsicMetric, height: 216)
    }

    var minutes: Int { hours.value * 60 + mins.minuteValue }

    func configure(adaptive: Bool, locale: Locale) {
      // A coarse step has only 12 rows, each already labelled 00, 05 …: nothing to compress.
      mins.setAdaptive(adaptive && minuteStep == 1)
      guard locale != self.locale else { return }
      self.locale = locale
      hours.uses24Hour = Self.uses24Hour(locale)
      period.locale = locale
      period.isHidden = hours.uses24Hour
      setNeedsLayout()
    }

    func show(minutes: Int) {
      hours.show(value: minutes / 60)
      mins.show(value: minutes % 60 / minuteStep)
      period.isPM = hours.value >= 12
    }

    func stop() {
      hours.stop()
      mins.stop()
    }

    override package func layoutSubviews() {
      super.layoutSubviews()
      let row = TimeWheelColumnView.rowHeight(for: traitCollection)
      hours.rowHeight = row
      mins.rowHeight = row
      let width: CGFloat = 76
      let periodWidth: CGFloat = period.isHidden ? 0 : 64
      let total = 2 * width + periodWidth
      var x = (bounds.width - total) / 2
      for column in [hours, mins] {
        column.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
        x += width
      }
      period.frame = CGRect(x: x, y: 0, width: periodWidth, height: bounds.height)
      period.rowHeight = row
      band.frame = CGRect(
        x: max((bounds.width - total) / 2 - 12, 8), y: (bounds.height - row) / 2,
        width: min(total + 24, bounds.width - 16), height: row)
    }

    private func valueChanged() {
      period.isPM = hours.value >= 12
      onChange(minutes)
    }

    private func columnEvent(_ event: TimeWheelEvent, _ time: Double) {
      if case .settled = event {
        onEvent(.settled(minutes: minutes), time)
      } else {
        onEvent(event, time)
      }
    }

    /// AM/PM moves the hour by 12, like Apple's picker; the minute stays.
    private func togglePeriod(at time: Double) {
      onEvent(.touchDown(moving: hours.isMoving || mins.isMoving), time)
      hours.nudge(by: hours.value >= 12 ? -12 : 12)
      onEvent(.settled(minutes: minutes), time)
    }

    static func uses24Hour(_ locale: Locale) -> Bool {
      AlarmPlan.timeParts(hour: 13, minute: 0, locale: locale).suffix == nil
    }
  }

  /// One column: numbers on a band of rows, short ticks on the inner edge, a touch recognizer that claims the touch
  /// on contact (so the column stays locked to the gesture and no sheet or scroll view takes it), a display link only
  /// while something moves, and one selection haptic per tick the model lets through.
  final class TimeWheelColumnView: UIView {
    enum Kind { case hour, minute }

    var onValue: () -> Void = {}
    var onEvent: (TimeWheelEvent, Double) -> Void = { _, _ in }
    var uses24Hour = false { didSet { render() } }
    var rowHeight: CGFloat = 34 {
      didSet {
        guard rowHeight != oldValue else { return }
        model.tuning.finePointsPerUnit = Double(rowHeight)
        render()
      }
    }

    private let kind: Kind
    private var model: TimeWheelColumn
    private var labels: [UILabel] = []
    private let ticks = CAShapeLayer()
    private let recognizer = WheelTouchRecognizer()
    private lazy var haptics = UISelectionFeedbackGenerator(view: self)
    private var link: CADisplayLink?
    private var labelStep = 1
    private var reportedValue: Int
    /// Minutes per row in the minute column (5 → 00, 05 … 55); 1 for hours.
    private let step: Int

    init(kind: Kind, value: Int, adaptive: Bool, step: Int = 1) {
      self.kind = kind
      self.step = kind == .minute ? step : 1
      model = TimeWheelColumn(
        count: kind == .hour ? 24 : 60 / self.step, value: value, adaptive: adaptive)
      reportedValue = model.value
      super.init(frame: .zero)
      clipsToBounds = true
      ticks.fillColor = nil
      ticks.lineWidth = 1
      layer.addSublayer(ticks)
      recognizer.addTarget(self, action: #selector(handleTouch(_:)))
      addGestureRecognizer(recognizer)
      isAccessibilityElement = true
      accessibilityTraits = .adjustable
      accessibilityLabel = kind == .hour ? "Hours" : "Minutes"
      accessibilityIdentifier = kind == .hour ? "wheelLab.hours" : "wheelLab.minutes"
      registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
        (view: TimeWheelColumnView, _: UITraitCollection) in view.render()
      }
    }

    required init?(coder: NSCoder) { fatalError() }

    var value: Int { model.value }
    /// What the column shows, in minutes (`value` times the step).
    var minuteValue: Int { model.value * step }
    var isMoving: Bool { model.isMoving }

    func setAdaptive(_ adaptive: Bool) {
      guard adaptive != model.adaptive else { return }
      // A new model with the same whole value: switching versions never carries motion over.
      let tuning = model.tuning
      model = TimeWheelColumn(
        count: model.count, value: model.value, adaptive: adaptive, tuning: tuning)
      updateLink()
      render()
    }

    func show(value: Int) {
      model.set(value: value)
      reportedValue = model.value
      updateLink()
      render()
    }

    func nudge(by steps: Int) {
      model.nudge(by: steps)
      reportValue()
      updateLink()
      render()
    }

    /// Ends any drag or coast on the shown value (leaving the page, switching versions, Save while moving).
    func stop() {
      model.stop()
      recognizer.isEnabled = false
      recognizer.isEnabled = true
      reportValue()
      updateLink()
      render()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil { stop() }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      ticks.frame = bounds
      render()
    }

    // MARK: Touch

    @objc private func handleTouch(_ recognizer: WheelTouchRecognizer) {
      let samples = recognizer.drainSamples()
      guard let last = samples.last else { return }
      switch recognizer.state {
      case .began:
        let wasMoving = model.isMoving
        haptics.prepare()
        apply(model.touchDown(y: Double(last.y), at: last.time), at: last.time)
        onEvent(.touchDown(moving: wasMoving), last.time)
      case .changed:
        for sample in samples {
          apply(model.touchMove(y: Double(sample.y), at: sample.time), at: sample.time)
        }
      case .ended:
        for sample in samples.dropLast() {
          apply(model.touchMove(y: Double(sample.y), at: sample.time), at: sample.time)
        }
        let out = model.touchUp(y: Double(last.y), at: last.time)
        if model.isMoving { onEvent(.liftedWhileMoving, last.time) }
        apply(out, at: last.time)
      case .cancelled, .failed:
        let out = model.touchCancel(at: last.time)
        if model.isMoving { onEvent(.liftedWhileMoving, last.time) }
        apply(out, at: last.time)
      default:
        break
      }
      updateLink()
      render()
    }

    private func apply(_ out: TimeWheelOutput, at time: Double) {
      if out.contains(.tick) { haptics.selectionChanged() }
      reportValue()
      if out.contains(.reversal) { onEvent(.reversal, time) }
      if out.contains(.settled) { onEvent(.settled(minutes: 0), time) }
    }

    private func reportValue() {
      guard model.value != reportedValue else { return }
      reportedValue = model.value
      onValue()
    }

    // MARK: Frames

    private func updateLink() {
      if model.needsFrames {
        guard link == nil else { return }
        let link = CADisplayLink(
          target: LinkProxy(self), selector: #selector(LinkProxy.advance(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
      } else {
        link?.invalidate()
        link = nil
      }
    }

    fileprivate func advance(_ link: CADisplayLink) {
      apply(model.step(at: link.timestamp), at: link.timestamp)
      updateLink()
      render()
    }

    // MARK: Drawing

    static func font(for traits: UITraitCollection) -> UIFont {
      let base = UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .regular)
      return UIFontMetrics(forTextStyle: .title2).scaledFont(
        for: base, maximumPointSize: 34, compatibleWith: traits)
    }

    static func rowHeight(for traits: UITraitCollection) -> CGFloat {
      max(34, ceil(font(for: traits).lineHeight + 8))
    }

    private func text(_ value: Int) -> String {
      switch kind {
      case .minute: return String(format: "%02d", value * step)
      case .hour:
        if uses24Hour { return String(format: "%02d", value) }
        return "\(value % 12 == 0 ? 12 : value % 12)"
      }
    }

    private func render() {
      guard bounds.height > 0 else { return }
      let font = Self.font(for: traitCollection)
      let ppu = model.pointsPerUnit
      let mid = Double(bounds.midY)
      let half = Double(bounds.height) / 2
      let gap = Double(font.lineHeight) * 1.05
      labelStep = TimeWheelColumn.labelStep(current: labelStep, pointsPerUnit: ppu, gap: gap)
      let selected = model.rounded
      let selectedY = mid + (Double(selected) - model.position) * ppu
      let low = Int((model.position - half / ppu).rounded(.down)) - 1
      let high = Int((model.position + half / ppu).rounded(.up)) + 1

      var used = 0
      let path = UIBezierPath()
      let inner = kind == .hour ? Double(bounds.width) - 2 : 2
      let outward = kind == .hour ? -1.0 : 1.0
      for v in low...high {
        let y = mid + (Double(v) - model.position) * ppu
        let wrapped = TimeWheelColumn.wrap(v, model.count)
        let major = wrapped * step % 5 == 0
        if ppu >= 3 || major {
          let length = major ? 10.0 : 5.0
          path.move(to: CGPoint(x: inner, y: y))
          path.addLine(to: CGPoint(x: inner + outward * length, y: y))
        }
        let shows = v == selected || (wrapped % labelStep == 0 && abs(y - selectedY) >= gap)
        guard shows else { continue }
        if used == labels.count {
          let label = UILabel()
          label.textAlignment = .center
          label.isAccessibilityElement = false
          addSubview(label)
          labels.append(label)
        }
        let label = labels[used]
        used += 1
        label.isHidden = false
        label.font = font
        label.text = text(wrapped)
        label.textColor = .label
        let distance = min(abs(y - mid) / half, 1)
        label.alpha = v == selected ? 1 : CGFloat(1 - 0.75 * distance)
        label.frame = CGRect(
          x: 0, y: y - Double(font.lineHeight) / 2, width: Double(bounds.width),
          height: Double(font.lineHeight))
      }
      for label in labels[used...] { label.isHidden = true }
      ticks.strokeColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
      ticks.path = path.cgPath
      accessibilityValue = text(model.value)
    }

    // MARK: Accessibility

    override func accessibilityIncrement() { nudgeForAccessibility(1) }
    override func accessibilityDecrement() { nudgeForAccessibility(-1) }

    private func nudgeForAccessibility(_ steps: Int) {
      let time = CACurrentMediaTime()
      onEvent(.touchDown(moving: model.isMoving), time)
      nudge(by: steps)
      onEvent(.settled(minutes: 0), time)
    }
  }

  /// A display link holds its target strongly; this keeps the column free to go away.
  @MainActor private final class LinkProxy: NSObject {
    weak var column: TimeWheelColumnView?
    init(_ column: TimeWheelColumnView) { self.column = column }
    @objc func advance(_ link: CADisplayLink) {
      guard let column else {
        link.invalidate()
        return
      }
      column.advance(link)
    }
  }

  /// AM and PM, Apple-style: the current one in the band, the other a row away. A tap switches.
  final class PeriodColumnView: UIView {
    var onToggle: (Double) -> Void = { _ in }
    var locale = Locale.current { didSet { setNeedsLayout() } }
    var isPM = false { didSet { if isPM != oldValue { setNeedsLayout() } } }
    var rowHeight: CGFloat = 34 { didSet { setNeedsLayout() } }
    private let am = UILabel()
    private let pm = UILabel()

    override init(frame: CGRect) {
      super.init(frame: frame)
      for label in [am, pm] {
        label.textAlignment = .center
        label.isAccessibilityElement = false
        addSubview(label)
      }
      addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
      isAccessibilityElement = true
      accessibilityTraits = .adjustable
      accessibilityLabel = "AM or PM"
      accessibilityIdentifier = "wheelLab.period"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
      super.layoutSubviews()
      let formatter = DateFormatter()
      formatter.locale = locale
      am.text = formatter.amSymbol
      pm.text = formatter.pmSymbol
      let font = TimeWheelColumnView.font(for: traitCollection)
      let mid = bounds.midY
      for (label, offset) in [(am, isPM ? -1.0 : 0), (pm, isPM ? 0 : 1.0)] {
        label.font = font
        label.textColor = .label
        label.alpha = offset == 0 ? 1 : 0.5
        label.frame = CGRect(
          x: 0, y: mid + offset * rowHeight - font.lineHeight / 2, width: bounds.width,
          height: font.lineHeight)
      }
      accessibilityValue = isPM ? formatter.pmSymbol : formatter.amSymbol
    }

    @objc private func tap() { onToggle(CACurrentMediaTime()) }
    override func accessibilityIncrement() { if !isPM { tap() } }
    override func accessibilityDecrement() { if isPM { tap() } }
  }

  /// Claims a touch the moment it lands (state `.began` on touch down), so a coast stops at once and no outer
  /// gesture can take the column's touch. Hands the owner every coalesced sample with its own timestamp.
  final class WheelTouchRecognizer: UIGestureRecognizer {
    struct Sample {
      let y: CGFloat
      let time: Double
    }

    private weak var tracked: UITouch?
    private var pending: [Sample] = []

    func drainSamples() -> [Sample] {
      defer { pending.removeAll() }
      return pending
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      for touch in touches where tracked != nil || touch !== touches.first {
        ignore(touch, for: event)
      }
      guard tracked == nil, let touch = touches.first else { return }
      tracked = touch
      pending = [sample(touch)]
      state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
      guard let tracked, touches.contains(tracked) else { return }
      let all = event.coalescedTouches(for: tracked) ?? [tracked]
      pending.append(contentsOf: all.map(sample))
      state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
      guard let tracked, touches.contains(tracked) else { return }
      pending.append(sample(tracked))
      state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
      guard let tracked, touches.contains(tracked) else { return }
      pending.append(sample(tracked))
      state = .cancelled
    }

    override func reset() {
      super.reset()
      tracked = nil
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
      false
    }

    private func sample(_ touch: UITouch) -> Sample {
      Sample(y: touch.location(in: view).y, time: touch.timestamp)
    }
  }
#endif
