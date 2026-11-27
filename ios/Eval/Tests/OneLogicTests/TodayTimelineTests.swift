import CoreGraphics
import Foundation
import Testing

@testable import TodayCore

struct TodayTimelineTests {
  typealias Item = TodayTimeline.Item
  let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()
  var midnight: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)) }

  func at(_ hour: Int, _ minute: Int = 0) -> Date {
    midnight.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
  }

  func event(_ hour: Int, _ minute: Int, minutes: Int) -> Item {
    Item(start: at(hour, minute), end: at(hour, minute + minutes), kind: .event)
  }

  @Test func finishedItemsLeaveTodayAndOpenOverdueRemindersStay() {
    let now = at(12)
    #expect(TodayTimeline.isFinished(event(8, 0, minutes: 30), now: now))
    #expect(!TodayTimeline.isFinished(event(11, 30, minutes: 60), now: now))
    #expect(TodayTimeline.isFinished(Item(start: at(8), kind: .alarm), now: now))
    #expect(!TodayTimeline.isFinished(Item(start: at(13), kind: .alarm), now: now))
    #expect(!TodayTimeline.isFinished(Item(start: at(8), kind: .reminder), now: now))
    #expect(TodayTimeline.isFinished(Item(start: at(8), kind: .reminder, isDone: true), now: now))
    #expect(TodayTimeline.isFinished(Item(start: at(15), kind: .reminder, isDone: true), now: now))
  }

  @Test func otherDaysKeepEveryItem() {
    #expect(!TodayTimeline.isFinished(event(8, 0, minutes: 30), now: nil))
    #expect(!TodayTimeline.isFinished(Item(start: at(8), kind: .reminder, isDone: true), now: nil))
  }

  @Test func onlyOpenPastRemindersAreLate() {
    let now = at(12)
    #expect(TodayTimeline.isOpenPast(Item(start: at(8), kind: .reminder), now: now))
    #expect(!TodayTimeline.isOpenPast(Item(start: at(8), kind: .reminder, isDone: true), now: now))
    #expect(!TodayTimeline.isOpenPast(Item(start: at(13), kind: .reminder), now: now))
    #expect(!TodayTimeline.isOpenPast(event(8, 0, minutes: 30), now: now))
    #expect(!TodayTimeline.isOpenPast(Item(start: at(8), kind: .reminder), now: nil))
  }

  @Test func rowsKeepTimeOrderWithFreeAfterItemsAndNowInPlace() {
    let items = [
      Item(start: at(14), kind: .reminder), event(9, 0, minutes: 60),
      Item(start: at(7), kind: .reminder),
    ]
    let free = [DateInterval(start: at(10), end: at(14)), DateInterval(start: at(9), end: at(9))]
    let rows = TodayTimeline.rows(items: items, free: free, now: at(11))
    #expect(rows == [.item(2), .free(1), .free(0), .now, .item(0)])
  }

  @Test func nowIsALineBeforeTheGapStartingNow() {
    let items = [event(14, 0, minutes: 60)]
    let free = [DateInterval(start: at(13), end: at(14)), DateInterval(start: at(15), end: at(16))]
    #expect(
      TodayTimeline.rows(items: items, free: free, now: at(13))
        == [.now, .free(0), .item(0), .free(1)])
    #expect(
      TodayTimeline.rows(items: items, free: free, now: at(14))
        == [.free(0), .now, .item(0), .free(1)])
    #expect(
      TodayTimeline.rows(items: items, free: free, now: nil)
        == [.free(0), .item(0), .free(1)])
  }

  @Test func nowGoesLastWhenTheDayIsOverAndIsAbsentOnOtherDays() {
    let items = [Item(start: at(7), kind: .reminder)]
    #expect(
      TodayTimeline.rows(items: items, free: [], now: at(23)) == [.item(0), .now])
    #expect(TodayTimeline.rows(items: items, free: [], now: nil) == [.item(0)])
  }

  @Test func rowsDropFinishedItemsAtOnce() {
    let items = [
      event(8, 0, minutes: 30), Item(start: at(8), kind: .reminder),
      Item(start: at(9), kind: .reminder, isDone: true),
      Item(start: at(11), kind: .reminder, isDone: true),
    ]
    #expect(TodayTimeline.rows(items: items, free: [], now: at(10)) == [.item(1), .now])
  }

  @Test func viewportSpansTheVisibleRows() {
    let frames = [
      TodayTimeline.Frame(span: DateInterval(start: at(7), end: at(7)), minY: 0, maxY: 44),
      TodayTimeline.Frame(span: DateInterval(start: at(9), end: at(10)), minY: 44, maxY: 88),
      TodayTimeline.Frame(span: DateInterval(start: at(12), end: at(12)), minY: 88, maxY: 132),
      TodayTimeline.Frame(span: DateInterval(start: at(18), end: at(19)), minY: 400, maxY: 444),
    ]
    #expect(
      TodayTimeline.viewport(frames, top: 40, bottom: 200)
        == DateInterval(start: at(9), end: at(12)))
    #expect(TodayTimeline.viewport(frames, top: 500, bottom: 600) == nil)
    #expect(
      TodayTimeline.viewport(frames, top: 0, bottom: 500)
        == DateInterval(start: at(7), end: at(19)))
  }

  @Test func viewportUsesStrictEdgesAndKeepsTheLatestEndOfOverlappingEvents() {
    let frames = [
      TodayTimeline.Frame(span: DateInterval(start: at(14), end: at(15)), minY: 140, maxY: 180),
      TodayTimeline.Frame(span: DateInterval(start: at(6), end: at(7)), minY: 0, maxY: 48),
      TodayTimeline.Frame(span: DateInterval(start: at(17), end: at(19)), minY: 192, maxY: 230),
      TodayTimeline.Frame(span: DateInterval(start: at(9), end: at(16)), minY: 50, maxY: 90),
    ]
    #expect(
      TodayTimeline.viewport(frames.lazy, top: 40, bottom: 200)
        == DateInterval(start: at(9), end: at(16)))
  }

  @Test func scrollTargetIsTheFirstRowStillRunningAtThatTime() {
    let spans = [
      DateInterval(start: at(7), end: at(7)), DateInterval(start: at(9), end: at(10)),
      DateInterval(start: at(12), end: at(12)),
    ]
    #expect(TodayTimeline.scrollTarget(for: at(6), in: spans) == 0)
    #expect(TodayTimeline.scrollTarget(for: at(9, 30), in: spans) == 1)
    #expect(TodayTimeline.scrollTarget(for: at(11), in: spans) == 2)
    #expect(TodayTimeline.scrollTarget(for: at(22), in: spans) == 2)
    #expect(TodayTimeline.scrollTarget(for: at(9), in: []) == nil)
  }

  @Test func ribbonStartsAtSixOrTheEarliestHour() {
    let day = at(12)
    #expect(
      TodayTimeline.ribbonRange(items: [], day: day, calendar: calendar)
        == DateInterval(start: at(6), end: at(24)))
    #expect(
      TodayTimeline.ribbonRange(
        items: [Item(start: at(4, 30), kind: .alarm)], day: day, calendar: calendar)
        == DateInterval(start: at(4), end: at(24)))
    #expect(
      TodayTimeline.ribbonRange(
        items: [Item(start: at(-2), kind: .event)], day: day, calendar: calendar
      ).start == at(0))
  }

  @Test func ribbonFractionIsClamped() {
    let range = DateInterval(start: at(6), end: at(24))
    #expect(TodayTimeline.date(at: 0.5, in: range) == at(15))
    #expect(TodayTimeline.date(at: -1, in: range) == at(6))
    #expect(TodayTimeline.date(at: 2, in: range) == at(24))
  }

  func sweep(
    reservesFooter: Bool, offsets: some Sequence<CGFloat>
  ) -> [CGFloat: TodayTimeline.Continuation?] {
    let rows = 12
    let rowHeight: CGFloat = 44
    let height: CGFloat = 300
    let footer = TodayTimeline.continuationHeight
    var showsFooter = false
    var seen: [CGFloat: TodayTimeline.Continuation?] = [:]
    for offset in offsets {
      let bottom = reservesFooter || showsFooter ? height - footer : height
      let frames = (0..<rows).map { index -> (minY: CGFloat, maxY: CGFloat)? in
        let minY = CGFloat(index) * rowHeight - offset
        return (minY: minY, maxY: minY + rowHeight)
      }
      let more = TodayTimeline.continuation(frames, top: 0, bottom: bottom)
      showsFooter = more != nil
      seen[offset] = more
    }
    return seen
  }

  @Test func continuationFooterThatResizesTheListDependsOnScrollDirection() {
    let offsets = stride(from: CGFloat(0), through: 260, by: 2)
    let down = sweep(reservesFooter: false, offsets: offsets)
    let up = sweep(reservesFooter: false, offsets: offsets.reversed())
    #expect(down != up)
  }

  @Test func continuationWithReservedFooterDependsOnlyOnOffset() {
    let offsets = stride(from: CGFloat(0), through: 260, by: 2)
    let down = sweep(reservesFooter: true, offsets: offsets)
    let up = sweep(reservesFooter: true, offsets: offsets.reversed())
    #expect(down == up)
    #expect(down[0] == TodayTimeline.Continuation(index: 6, count: 6))
    #expect(down[260] == .some(nil))
  }
}
