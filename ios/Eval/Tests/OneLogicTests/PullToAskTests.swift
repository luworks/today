import Foundation
import Testing
import TodayCore

@Suite struct PullToAskTests {
  @Test func releaseWhileArmedOpensChatOnce() {
    var pull = PullToAsk()
    #expect(pull.update(pullDistance: 80, isTracking: true) == [.armed])
    #expect(pull.isArmed)
    #expect(pull.update(pullDistance: 80, isTracking: false) == [.open])
    // The rubber band settling afterwards must not open a second time.
    #expect(pull.update(pullDistance: 40, isTracking: false).isEmpty)
    #expect(pull.update(pullDistance: 0, isTracking: false).isEmpty)
    #expect(!pull.isArmed)
  }

  @Test func releaseBelowThresholdStaysOnTheCalendar() {
    var pull = PullToAsk()
    #expect(pull.update(pullDistance: 40, isTracking: true).isEmpty)
    #expect(!pull.isArmed)
    #expect(pull.progress < 1)
    #expect(pull.update(pullDistance: 40, isTracking: false).isEmpty)
  }

  @Test func slidingBackBelowTheDisarmBandCancels() {
    var pull = PullToAsk()
    #expect(pull.update(pullDistance: 90, isTracking: true) == [.armed])
    #expect(pull.update(pullDistance: 50, isTracking: true).isEmpty)
    #expect(!pull.isArmed)
    #expect(pull.update(pullDistance: 50, isTracking: false).isEmpty)
  }

  @Test func hysteresisKeepsTheArmNearTheBoundaryAndRearmingTicksAgain() {
    var pull = PullToAsk()
    #expect(pull.update(pullDistance: 64, isTracking: true) == [.armed])
    // Inside the band between disarm and threshold: still armed, no new tick.
    #expect(pull.update(pullDistance: 60, isTracking: true).isEmpty)
    #expect(pull.isArmed)
    #expect(pull.update(pullDistance: 70, isTracking: true).isEmpty)
    // Out of the band and back over the threshold arms (and ticks) again.
    #expect(pull.update(pullDistance: 40, isTracking: true).isEmpty)
    #expect(pull.update(pullDistance: 70, isTracking: true) == [.armed])
    #expect(pull.update(pullDistance: 70, isTracking: false) == [.open])
  }

  @Test func aFlickBouncingAtTheTopNeverOpens() {
    var pull = PullToAsk()
    // Finger down mid-list and flicking up: no overscroll while tracking.
    #expect(pull.update(pullDistance: 0, isTracking: true).isEmpty)
    // Released, then the deceleration bounces far past the top.
    #expect(pull.update(pullDistance: 0, isTracking: false).isEmpty)
    #expect(pull.update(pullDistance: 120, isTracking: false).isEmpty)
    #expect(!pull.isArmed)
    #expect(pull.update(pullDistance: 0, isTracking: false).isEmpty)
  }

  @Test func progressClampsAndNegativePullIsRest() {
    var pull = PullToAsk()
    _ = pull.update(pullDistance: -30, isTracking: true)
    #expect(pull.pull == 0)
    #expect(pull.progress == 0)
    _ = pull.update(pullDistance: 200, isTracking: true)
    #expect(pull.progress == 1)
  }

  @Test func aSecondPullAfterOpeningArmsAgain() {
    var pull = PullToAsk()
    _ = pull.update(pullDistance: 80, isTracking: true)
    #expect(pull.update(pullDistance: 80, isTracking: false) == [.open])
    _ = pull.update(pullDistance: 0, isTracking: false)
    #expect(pull.update(pullDistance: 70, isTracking: true) == [.armed])
    #expect(pull.update(pullDistance: 70, isTracking: false) == [.open])
  }
}
