import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData
@testable import TodayShared

@MainActor
final class ActivityRecorderTests: XCTestCase {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()
  let now = Date(timeIntervalSince1970: 1_792_000_000)

  /// Collects what would be written, and can be told to fail.
  final class SpyStore: ActivityStoring {
    var batches: [[ActivityEvent]] = []
    var fail = false
    struct Boom: Error {}
    func insert(_ events: [ActivityEvent]) throws -> Int {
      if fail { throw Boom() }
      batches.append(events)
      return events.count
    }
  }

  @MainActor
  final class Clock {
    var pending: [@MainActor @Sendable () -> Void] = []
    var delays: [TimeInterval] = []
    func schedule(_ d: TimeInterval, _ w: @escaping @MainActor @Sendable () -> Void) {
      delays.append(d)
      pending.append(w)
    }
    func fire() {
      let p = pending
      pending = []
      p.forEach { $0() }
    }
  }

  private func recorder(
    _ store: ActivityStoring?, settings: ActivitySettings = ActivitySettings(),
    clock: Clock = Clock()
  ) -> ActivityRecorder {
    ActivityRecorder(
      store: store, session: "S1", settings: { settings },
      schedule: { delay, work in clock.schedule(delay, work) })
  }

  private func ev(_ kind: String = "ui.screen.open") -> ActivityEvent {
    ActivityEvent(kind: kind, actor: "you", at: now, calendar: cal)
  }

  func testEventsAreBufferedAndWrittenInOneBatchWhenTheTimerFires() async {
    let store = SpyStore()
    let clock = Clock()
    let r = recorder(store, clock: clock)
    for _ in 0..<5 { r.record(ev()) }
    XCTAssertTrue(store.batches.isEmpty, "nothing is written per event")
    XCTAssertEqual(clock.pending.count, 1, "one timer for the whole burst")
    XCTAssertEqual(clock.delays, [1.5])
    clock.fire()
    XCTAssertEqual(store.batches.count, 1)
    XCTAssertEqual(store.batches[0].count, 5, "one transaction")
    XCTAssertEqual(store.batches[0].first?.session, "S1", "the launch session id is added")
  }

  func testFlushWritesAtOnceAndAFullBufferDoesNotWait() async {
    let store = SpyStore()
    let r = recorder(store)
    r.maxBuffered = 3
    r.record(ev())
    r.record(ev())
    XCTAssertEqual(r.bufferedCount, 2)
    r.record(ev())
    XCTAssertEqual(store.batches.count, 1, "the third event fills the buffer")
    r.record(ev())
    r.flush()
    XCTAssertEqual(store.batches.count, 2)
    r.flush()
    XCTAssertEqual(store.batches.count, 2, "an empty flush writes nothing")
  }

  func testPauseAndCategoryTogglesDropEventsBeforeTheyAreBuffered() async {
    var s = ActivitySettings()
    s.tiers.remove(.usage)
    let store = SpyStore()
    let r = recorder(store, settings: s)
    XCTAssertFalse(r.record(ev("ui.screen.open")), "usage is switched off")
    XCTAssertTrue(r.record(ev("ai.turn")))
    XCTAssertTrue(r.isRecording(.changes))
    XCTAssertFalse(r.isRecording(.usage))
    s.paused = true
    let paused = recorder(store, settings: s)
    XCTAssertFalse(paused.record(ev("ai.turn")))
    XCTAssertFalse(paused.isRecording(.changes), "pause stops every category")
    paused.flush()
    XCTAssertTrue(store.batches.isEmpty)
  }

  func testNoStoreMeansNothingRecordedAndNoCrash() async {
    let r = recorder(nil)
    XCTAssertFalse(r.record(ev()))
    XCTAssertFalse(r.isAvailable)
    r.flush()
  }

  func testAFailedWriteKeepsTheEventsForTheNextTry() async {
    let store = SpyStore()
    let r = recorder(store)
    r.record(ev())
    r.record(ev())
    store.fail = true
    r.flush()
    XCTAssertEqual(r.bufferedCount, 2)
    store.fail = false
    r.flush()
    XCTAssertEqual(store.batches.first?.count, 2)
    XCTAssertEqual(r.writeFailures, 0, "a good write resets the failure count")
  }

  func testRecorderWritesIntoARealStore() async throws {
    let store = try ActivityStore(location: .memory)
    let r = recorder(store)
    r.record(ActivityEvents.aiUndo(card: "capture", thread: nil, at: now))
    r.flush()
    let page = try store.page(ActivityQuery(tiers: [.ai]))
    XCTAssertEqual(page.map(\.kind), [ActivityKind.aiUndo])
    XCTAssertEqual(
      page.first?.device, store.deviceID, "the store fills in this install's device id")
  }

  // MARK: Settings

  func testSettingsRoundTripAndDefaults() async throws {
    let suite = "activity-settings-\(UUID().uuidString)"
    let d = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { d.removePersistentDomain(forName: suite) }
    let fresh = ActivitySettings(d)
    XCTAssertFalse(fresh.paused)
    XCTAssertEqual(
      fresh.tiers, Set(ActivityTier.allCases),
      "every category is on by default (decision 1: usage too)")
    XCTAssertEqual(fresh.retention, .forever, "raw events are kept by default")
    XCTAssertTrue(
      fresh.keepChatText,
      "chat text is kept by default, on this device only (the user wants real chats recorded)")
    var s = fresh
    s.paused = true
    s.tiers = [.changes]
    s.retention = .forever
    s.keepChatText = false
    s.save(to: d)
    XCTAssertEqual(ActivitySettings(d), s)
    XCTAssertFalse(s.records(.changes), "paused wins")
  }

  func testRetentionCutoffs() async {
    XCTAssertEqual(ActivityRetention.days90.days, 90)
    XCTAssertEqual(ActivityRetention.year.days, 365)
    XCTAssertNil(ActivityRetention.forever.days)
    XCTAssertNil(ActivityRetention.forever.cutoff(now: now))
    let cut = ActivityRetention.days90.cutoff(now: now, calendar: cal)!
    XCTAssertEqual(cal.dateComponents([.day], from: cut, to: cal.startOfDay(for: now)).day, 90)
    XCTAssertEqual(
      ActivityWindows.userChoseDays, 90,
      "the autonomy policy's look-back does not follow the setting")
  }

  // MARK: Event shapes

  func testRepeatedWriteFailuresKeepBatchUntilSuccessfulFlush() async {
    let store = SpyStore()
    let r = recorder(store)
    r.record(ev())
    store.fail = true
    for _ in 0..<6 {
      XCTAssertFalse(r.flush())
      XCTAssertEqual(r.bufferedCount, 1)
    }
    store.fail = false
    XCTAssertTrue(r.flush())
    XCTAssertEqual(r.bufferedCount, 0)
    XCTAssertEqual(store.batches.flatMap { $0 }.count, 1)
  }

  func testAITurnKeepsNoTextUnlessAsked() async {
    let thread = UUID()
    let off = ActivityEvents.aiTurn(
      intent: "capture", route: "rules", text: "明天下午三点开会", keepText: false, thread: thread, at: now)
    XCTAssertEqual(off.kind, "ai.turn")
    XCTAssertEqual(off.tier, 2)
    XCTAssertEqual(off.thread, thread.uuidString)
    XCTAssertTrue(off.content.isEmpty)
    XCTAssertFalse(off.props.contains("开会"), "props never carry the user's words")
    let props = ActivityProps.dictionary(off.props)
    XCTAssertEqual(props["lang"] as? String, "zh")
    XCTAssertEqual(props["len_in"] as? Int, 8)
    let on = ActivityEvents.aiTurn(
      intent: "capture", route: "model", text: "Buy milk", keepText: true, thread: nil, at: now)
    XCTAssertEqual(
      on.content, [ActivityContent(field: "input", before: nil, after: "Buy milk")],
      "the text goes to its own table")
    XCTAssertEqual(ActivityProps.dictionary(on.props)["lang"] as? String, "en")
  }

  func testSentChatTurnsRespectAIRecordingAndTextSettingsInStore() async throws {
    for mode in ["text", "noText", "paused", "aiOff"] {
      let store = try ActivityStore(location: .memory)
      var settings = ActivitySettings()
      settings.keepChatText = mode != "noText"
      settings.paused = mode == "paused"
      if mode == "aiOff" { settings.tiers.remove(.ai) }
      let r = recorder(store, settings: settings)
      let thread = UUID()
      for (intent, text) in [("conversation", "Hello"), ("unsure", "some thoughts")] {
        r.record(
          ActivityEvents.aiTurn(
            intent: intent, route: "rules", text: text,
            keepText: settings.keepChatText, thread: thread, at: now))
      }
      r.flush()
      let turns = try store.page(ActivityQuery(kinds: ["ai.turn"]))
      if mode == "paused" || mode == "aiOff" {
        XCTAssertTrue(turns.isEmpty, mode)
      } else {
        XCTAssertEqual(turns.count, 2, "one event per sent interaction")
        XCTAssertEqual(
          Set(turns.map { ActivityProps.dictionary($0.props)["intent"] as? String }),
          ["conversation", "unsure"])
        for turn in turns {
          XCTAssertEqual(turn.thread, thread.uuidString)
          XCTAssertEqual(ActivityProps.dictionary(turn.props)["route"] as? String, "rules")
          let content = try store.content(uid: turn.uid)
          XCTAssertEqual(content.isEmpty, mode == "noText")
          if mode == "text" {
            XCTAssertEqual(content.map(\.field), ["input"])
            XCTAssertTrue(["Hello", "some thoughts"].contains(content.first?.after ?? ""))
          }
        }
      }
      XCTAssertEqual(
        try store.count(ActivityQuery(tiers: [.changes])), 0,
        "chat does not enter the change ledger")
    }
  }

  func testResolvedCardNamesEditedFieldsInPropsAndKeepsWordsInContent() async {
    var shown = Capture(title: "Call mom", day: now, hasDay: true)
    shown.hour = 15
    var final = shown
    final.title = "Call Mom about Sunday"
    final.hour = 17
    final.listName = "Family"
    let edits = CaptureEdits.diff(shown: shown, final: final, calendar: cal)
    XCTAssertEqual(edits.map(\.field), ["title", "when", "list"])
    XCTAssertEqual(edits[1].before, "2026-10-14 15:00")
    XCTAssertEqual(edits[1].after, "2026-10-14 17:00")
    XCTAssertTrue(CaptureEdits.diff(shown: shown, final: shown, calendar: cal).isEmpty)
    let e = ActivityEvents.cardResolved(
      card: "capture", outcome: "edited", edits: edits, dwellMs: 4200, thread: nil, at: now)
    let props = ActivityProps.dictionary(e.props)
    XCTAssertEqual(props["edited_fields"] as? [String], ["title", "when", "list"])
    XCTAssertEqual(props["dwell_ms"] as? Int, 4200)
    XCTAssertFalse(e.props.contains("Sunday"))
    XCTAssertEqual(e.content.count, 3)
  }

  func testKindsMapToTiers() async {
    XCTAssertEqual(ActivityKind.tier(of: "change.moved"), .changes)
    XCTAssertEqual(ActivityKind.tier(of: "grant.granted"), .changes)
    XCTAssertEqual(ActivityKind.tier(of: "ai.card.shown"), .ai)
    XCTAssertEqual(ActivityKind.tier(of: "ui.screen.open"), .usage)
    XCTAssertEqual(ActivityKind.tier(of: "sys.error"), .system)
    XCTAssertEqual(
      ActivityEvents.cardShown(card: "capture", items: 1, latencyMs: nil, thread: nil, at: now)
        .tier,
      2)
    XCTAssertEqual(ActivityEvents.shareImport(count: 2, at: now).tier, 4)
    XCTAssertEqual(ActivityEvents.error(source: "sync", code: "E1", at: now).actor, "system")
  }

  // MARK: Outbox (extensions) → app

  func testOutboxFilesWrittenByAnExtensionAreImportedByTheApp() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "outbox-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    XCTAssertTrue(
      ActivityOutbox.append(
        kind: "sys.share.add", actor: "share", channel: "share",
        props: ["has_url": true, "len": 12], at: now, in: folder))
    XCTAssertTrue(
      ActivityOutbox.append(
        kind: "sys.widget.refresh", actor: "system", channel: "widget", props: ["count": 3],
        at: now.addingTimeInterval(5), in: folder))
    let files = ActivityOutbox.pendingFiles(in: folder)
    XCTAssertEqual(files.count, 2, "one small file per write")
    XCTAssertTrue(files[0].lastPathComponent < files[1].lastPathComponent, "oldest first")
    // A half-written file from a crashed writer must not block the rest.
    try Data("{\"kind\":\"sys.share".utf8).write(
      to: folder.appendingPathComponent("0-broken.jsonl"))

    let read = ActivityOutboxImport.read(ActivityOutbox.pendingFiles(in: folder))
    XCTAssertEqual(read.events.map(\.kind).sorted(), ["sys.share.add", "sys.widget.refresh"])
    XCTAssertEqual(read.done.count, 3, "the broken file is read too and can be deleted")
    let store = try ActivityStore(location: .memory)
    let r = recorder(store)
    for e in read.events { r.record(e) }
    r.flush()
    XCTAssertEqual(try store.count(ActivityQuery(tiers: [.system])), 2)
    let share = try XCTUnwrap(try store.page(ActivityQuery(kinds: ["sys.share.add"])).first)
    XCTAssertEqual(share.device, store.deviceID, "the app adds its device id")
    XCTAssertEqual(ActivityProps.dictionary(share.props)["has_url"] as? Bool, true)
    ActivityOutbox.remove(read.done)
    XCTAssertTrue(ActivityOutbox.pendingFiles(in: folder).isEmpty)
  }

  func testOutboxEventsFollowThePauseSetting() async throws {
    var s = ActivitySettings()
    s.tiers.remove(.system)
    let store = SpyStore()
    let r = recorder(store, settings: s)
    var e = ev("sys.share.add")
    e.tier = 4
    XCTAssertFalse(r.record(e), "an imported system event is dropped when that category is off")
  }

  func testOutboxIsCappedAndUnavailableGroupIsHandled() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "outbox-cap-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    XCTAssertFalse(
      ActivityOutbox.append(kind: "sys.x", actor: "system", in: nil),
      "no App Group → false, no crash")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for i in 0..<ActivityOutbox.maxFiles {
      FileManager.default.createFile(
        atPath: folder.appendingPathComponent("\(i).jsonl").path, contents: Data())
    }
    XCTAssertFalse(
      ActivityOutbox.append(kind: "sys.x", actor: "system", in: folder),
      "a full outbox drops new events")
  }
}
