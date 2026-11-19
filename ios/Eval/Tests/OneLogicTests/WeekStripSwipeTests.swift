import Foundation
import Testing
import TodayCore

@Suite struct WeekStripSwipeTests {
  @Test func previewFollowsTravelAndCanReverseBeforeRelease() {
    var swipe = WeekStripSwipe()
    swipe.touchDown(at: 0)
    let previewTick = swipe.drag(-0.55, at: 0.1)
    #expect(previewTick)
    #expect(swipe.offset(at: 0.1) == -0.55)
    #expect(swipe.offset(at: 0.2) == -0.55)
    _ = swipe.drag(-0.05, at: 0.3)
    #expect(swipe.offset(at: 0.3) == -0.05)
    let cancelledTurn = swipe.release(-0.05, cancelled: false, animated: true, at: 0.3)
    #expect(cancelledTurn == 0)
    let settle = swipe.settle
    #expect(settle?.turned == false)
    #expect(swipe.offset(at: 0.5) == 0)
  }

  @Test func releaseTurnsOneAdjacentWeekAndKeepsVisiblePosition() throws {
    var swipe = WeekStripSwipe()
    swipe.touchDown(at: 0)
    _ = swipe.drag(-0.4, at: 0.1)
    let forwardTurn = swipe.release(-0.4, cancelled: false, animated: true, at: 0.2)
    #expect(forwardTurn == 1)
    let landing = try #require(swipe.settle)
    #expect(swipe.offset(at: 0.2) == 0.6)
    #expect(swipe.offset(at: 0.4) == 0)
    let duplicateTurn = swipe.release(-3, cancelled: false, animated: true, at: 0.3)
    #expect(duplicateTurn == 0)
    let firstLanding = swipe.complete(landing)
    #expect(firstLanding)
    let duplicateLanding = swipe.complete(landing)
    #expect(!duplicateLanding)
    swipe.touchDown(at: 0.5)
    let backwardTurn = swipe.release(2, cancelled: false, animated: true, at: 0.6)
    #expect(backwardTurn == -1)
  }

  @Test func touchDownTakesOverAtThePresentedOffsetAndCancelsStaleLanding() throws {
    var swipe = WeekStripSwipe()
    swipe.touchDown(at: 0)
    let forwardTurn = swipe.release(-0.4, cancelled: false, animated: true, at: 0.1)
    #expect(forwardTurn == 1)
    let old = try #require(swipe.settle)
    let exposed = swipe.offset(at: 0.16)
    #expect(exposed > 0 && exposed < 0.6)
    swipe.touchDown(at: 0.16)
    #expect(swipe.offset(at: 0.17) == exposed)
    let staleLanding = swipe.complete(old)
    #expect(!staleLanding)
    _ = swipe.drag(0.35, at: 0.18)
    #expect(swipe.offset(at: 0.18) == exposed + 0.35)
    let reverseTurn = swipe.release(0.35, cancelled: false, animated: true, at: 0.20)
    #expect(reverseTurn == -1)
    #expect(abs(swipe.offset(at: 0.20) + 1 - (exposed + 0.35)) < 0.0001)
  }

  @Test func detentsFilterJitterAndDoNotQueueRapidCrossings() {
    var swipe = WeekStripSwipe()
    swipe.touchDown(at: 0)
    let beforeFirst = swipe.drag(-0.12, at: 0.05)
    #expect(!beforeFirst)
    let first = swipe.drag(-0.15, at: 0.10)
    #expect(first)
    let jitterBack = swipe.drag(-0.14, at: 0.17)
    #expect(!jitterBack)
    let jitterForward = swipe.drag(-0.15, at: 0.24)
    #expect(!jitterForward)
    let second = swipe.drag(-0.31, at: 0.30)
    #expect(second)
    let rapidCrossing = swipe.drag(-0.19, at: 0.31)
    #expect(!rapidCrossing)
    let lateSample = swipe.drag(-0.19, at: 0.42)
    #expect(!lateSample)
    let reversed = swipe.drag(0.18, at: 0.50)
    #expect(reversed)
  }

  @Test func cancelledGestureReturnsWithoutTurningAndReduceMotionKeepsTheDecision() throws {
    var swipe = WeekStripSwipe()
    swipe.touchDown(at: 0)
    _ = swipe.drag(0.6, at: 0.1)
    let cancelledTurn = swipe.release(0.6, cancelled: true, animated: true, at: 0.11)
    #expect(cancelledTurn == 0)
    #expect(swipe.offset(at: 0.11) == 0.6)
    let cancelled = try #require(swipe.settle)
    let cancelledLanding = swipe.complete(cancelled)
    #expect(!cancelledLanding)
    swipe.touchDown(at: 0.2)
    let reduceMotionTick = swipe.drag(-0.5, at: 0.3)
    #expect(reduceMotionTick)
    let reduceMotionTurn = swipe.release(-0.5, cancelled: false, animated: false, at: 0.31)
    #expect(reduceMotionTurn == 1)
    #expect(swipe.offset(at: 0.31) == 0)
    #expect(!swipe.needsFrames)
    let spacedLanding = try #require(swipe.settle)
    #expect(abs(spacedLanding.time + spacedLanding.duration - 0.355) < 0.0001)
    let reduceMotionLanding = swipe.complete(spacedLanding)
    #expect(reduceMotionLanding)
  }
}
