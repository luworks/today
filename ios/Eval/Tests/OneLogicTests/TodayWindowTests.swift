import Foundation
import Testing

@testable import TodayCore

struct TodayWindowTests {
  typealias Item = TodayWindow.Item
  let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()
  let heights = TodayWindow.Heights(row: 44, now: 22, free: 32)
  let small: CGFloat = 341
  let large: CGFloat = 554
  var midnight: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)) }
  var dayEnd: Date { midnight.addingTimeInterval(24 * 3600) }
  var now: Date { at(8, 3) }

  func at(_ hour: Int, _ minute: Int = 0) -> Date {
    midnight.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
  }

  func reminder(_ hour: Int, _ minute: Int = 0, done: Bool = false) -> Item {
    Item(start: at(hour, minute), kind: .reminder, isDone: done)
  }

  func event(_ hour: Int, _ minute: Int, minutes: Int) -> Item {
    Item(
      start: at(hour, minute), end: at(hour, minute).addingTimeInterval(TimeInterval(minutes * 60)),
      kind: .event)
  }

  var dataset: [Item] {
    [
      reminder(7, 30),
      Item(start: at(7, 40), kind: .alarm),
      event(8, 0, minutes: 30),
      event(8, 0, minutes: 10),
      reminder(8, 30),
      reminder(9, 0),
      reminder(10, 21),
      reminder(12, 1),
      reminder(12, 30),
      event(18, 5, minutes: 30),
      reminder(18, 30),
      reminder(19, 0),
      reminder(19, 30),
      reminder(20, 0),
      reminder(20, 30),
      reminder(21, 0),
      reminder(21, 30),
    ]
  }

  func layout(
    _ items: [Item], start: Date? = nil, available: CGFloat, free: [DateInterval] = [],
    now: Date? = nil, today: Bool = true
  ) -> TodayWindow.Layout {
    let current = today ? (now ?? self.now) : nil
    return TodayWindow.layout(
      items: items, free: free, now: current, start: start ?? current ?? midnight,
      heights: heights, available: available, dayEnd: dayEnd)
  }

  @Test func aSmallScreenShowsTheNextFewHoursAndNamesTheNextMeeting() {
    let result = layout(dataset, available: small)
    #expect(result.pinned == [0])
    #expect(result.shown == [2, 3, 4, 5, 6, 7])
    #expect(result.later == [8, 9, 10, 11, 12, 13, 14, 15, 16])
    #expect(result.commitment == 9)
    #expect(!result.overflows)
    #expect(!result.scrolls)
    #expect(result.height <= small)
    #expect(result.windowEnd == at(12, 30))
  }

  @Test func aLargeScreenFitsMoreAndNamesNoMeetingWhenLaterHasNone() {
    let result = layout(dataset, available: large)
    #expect(result.pinned == [0])
    #expect(result.shown.count == 11)
    #expect(result.later == [13, 14, 15, 16])
    #expect(result.commitment == nil)
    #expect(result.height <= large)
  }

  @Test func theNowLineSitsBelowOngoingEventsAndAboveWhatComesNext() {
    let result = layout(dataset, available: small)
    #expect(
      result.rows == [
        .item(0), .item(2), .item(3), .now, .item(4), .item(5), .item(6), .item(7),
      ])
  }

  @Test func endedItemsAndDoneRemindersStayOffTheListAtNow() {
    var items = dataset
    items.append(reminder(7, 50, done: true))
    items.append(reminder(9, 30, done: true))
    let result = layout(items, available: 2000)
    #expect(!result.shown.contains(1))
    #expect(!result.shown.contains(17))
    #expect(!result.shown.contains(18))
    #expect(!result.pinned.contains(17))
  }

  @Test func openPastRemindersAreNeverLater() {
    let open = (0..<6).map { reminder(6, $0 * 5) }
    let items = open + dataset
    for available: CGFloat in [100, small, large, 2000] {
      let result = layout(items, available: available)
      #expect(Set(result.pinned) == Set(0...6))
      #expect(result.later.allSatisfy { !TodayWindow.isOpenPast(items[$0], now: now) })
      #expect(result.rows.filter { if case .item = $0 { true } else { false } }.count >= 7)
    }
  }

  @Test func scrubbingBackListsEndedAndDoneItemsInTimeOrder() {
    var items = dataset
    items.append(reminder(7, 50, done: true))
    let result = layout(items, start: at(7), available: small)
    #expect(result.pinned == [0])
    #expect(result.shown == [1, 17, 2, 3, 4, 5])
    #expect(
      result.rows == [
        .item(0), .item(1), .item(17), .item(2), .item(3), .now, .item(4), .item(5),
      ])
    #expect(result.later.first == 6)
  }

  @Test func aWindowWhollyInThePastHasNoNowLine() {
    let items = (0..<10).map { reminder(1, $0 * 5, done: true) } + dataset
    let result = layout(items, start: at(1), available: small)
    #expect(!result.rows.contains(.now))
    #expect(result.pinned == [10])
    #expect(result.later.contains(12))
  }

  @Test func aFutureWindowKeepsOpenPastOnTopAndDropsTheNowLine() {
    let result = layout(dataset, start: at(18), available: small)
    #expect(result.pinned == [0])
    #expect(result.shown == [9, 10, 11, 12, 13, 14])
    #expect(result.later == [15, 16])
    #expect(result.rows.first == .item(0))
    #expect(!result.rows.contains(.now))
    #expect(result.commitment == nil)
  }

  @Test func openPastThatFillsTheScreenTurnsOnOverflowAndNamesTheMeetingNow() {
    let open = (0..<7).map { reminder(6, $0 * 5) }
    let items = open + dataset
    let result = layout(items, available: small)
    #expect(result.overflows)
    #expect(result.scrolls)
    #expect(result.pinned.count == 8)
    #expect(result.shown.count == 7)
    #expect(result.commitment == 9)
    #expect(result.rows.contains(.now))
  }

  @Test func laterNamesTheFirstAlarmOrEventNotAReminder() {
    let items = [
      reminder(9), reminder(10), reminder(11), reminder(12),
      Item(start: at(13), kind: .alarm), event(14, 0, minutes: 60),
    ]
    let result = layout(items, available: 2 * 44 + 22)
    #expect(result.shown == [0, 1])
    #expect(result.commitment == 4)
  }

  @Test func everythingFitsSoNothingIsLater() {
    let result = layout(dataset, available: 2000)
    #expect(result.later.isEmpty)
    #expect(result.commitment == nil)
    #expect(result.windowEnd == dayEnd)
  }

  @Test func atLeastOneItemShowsEvenWhenNothingFits() {
    let result = layout([reminder(9)], available: 10)
    #expect(result.shown == [0])
  }

  @Test func freeRowsYieldWhenSpaceIsTight() {
    let gaps = [
      DateInterval(start: at(10, 30), duration: 5400),
      DateInterval(start: at(13), duration: 3600 * 5),
    ]
    let loose = layout(dataset, available: 2000, free: gaps)
    #expect(loose.rows.contains(.free(0)))
    #expect(loose.rows.contains(.free(1)))
    let tight = layout(dataset, available: small, free: gaps)
    #expect(!tight.rows.contains(.free(0)))
    #expect(tight.shown == [2, 3, 4, 5, 6, 7])
    let room = layout(dataset, available: small + 32, free: gaps)
    #expect(room.rows.contains(.free(0)))
    #expect(!room.rows.contains(.free(1)))
  }

  @Test func otherDaysHaveNoPinsAndNoNowLine() {
    let result = layout(dataset, start: at(7, 30), available: small, today: false)
    #expect(result.pinned.isEmpty)
    #expect(!result.rows.contains(.now))
    #expect(result.shown.first == 0)
  }

  @Test func snapTargetsSkipOpenPastAndIncludeNow() {
    let targets = TodayWindow.snapTargets(items: dataset, now: now)
    #expect(!targets.contains(at(7, 30)))
    #expect(targets.contains(at(7, 40)))
    #expect(targets.contains(now))
    #expect(targets == targets.sorted())
    #expect(Set(targets).count == targets.count)
    #expect(TodayWindow.nearest(at(8, 20), in: targets) == at(8, 30))
    #expect(TodayWindow.nearest(at(8, 1), in: targets) == at(8))
    #expect(TodayWindow.step(from: now, by: 1, in: targets) == at(8, 30))
    #expect(TodayWindow.step(from: now, by: -1, in: targets) == at(8))
    #expect(TodayWindow.step(from: at(21, 30), by: 1, in: targets) == nil)
  }

  @Test func theRibbonOpensAtSixUnlessSomethingStartsEarlier() {
    let usual = TodayWindow.ribbonRange(items: dataset, day: midnight, calendar: calendar)
    #expect(usual.start == at(6))
    #expect(usual.end == dayEnd)
    let early = TodayWindow.ribbonRange(
      items: [reminder(5, 20)] + dataset, day: midnight, calendar: calendar)
    #expect(early.start == at(5))
    let overnight = TodayWindow.ribbonRange(
      items: [Item(start: midnight.addingTimeInterval(-3600), kind: .event)], day: midnight,
      calendar: calendar)
    #expect(overnight.start == midnight)
    #expect(TodayWindow.clamp(at(23, 50), in: usual) == at(23, 30))
    #expect(TodayWindow.clamp(at(2), in: usual) == at(6))
  }

  @Test func scrubTicksOncePerStartCrossedAndCoalescesFastDrags() {
    let targets = [at(8), at(9), at(10)]
    var scrub = TodayRibbonScrub()
    let ticks = [
      scrub.move(to: at(7, 30), targets: targets, at: 0),
      scrub.move(to: at(7, 50), targets: targets, at: 0.1),
      scrub.move(to: at(8, 10), targets: targets, at: 0.2),
      scrub.move(to: at(8, 20), targets: targets, at: 0.3),
      scrub.move(to: at(9, 10), targets: targets, at: 0.21),
      scrub.move(to: at(10, 10), targets: targets, at: 0.4),
    ]
    #expect(ticks == [false, false, true, false, false, true])
    let early = scrub.release(at: 0.42)
    let late = scrub.release(at: 1)
    #expect(!early)
    #expect(late)
  }
}
